"""BlueRidge.Workorder.Ind570 - METTLER TOLEDO IND570 Modbus TCP protocol layer.

   Spec: docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md
   Manual: reference/IND570_PLC_Interface_Manual.md (doc 30205335 rev 12),
           Appendix B for the command table and status-bit layout.

   Two independent flows, mirroring the legacy OmniServer shape:

     Flow B (capture) has NO protocol step. Slot 1 sits parked on command 11
     and the terminal refreshes net weight every interface update cycle, so
     the value is simply THERE. captureGate() decides whether to trust it.

     Flow A (setpoint) is a 4-command sequence through slot 2. Each command
     waits for the acknowledgement to rotate before the next is sent -- the
     manual is explicit that the client must wait for the ack.

   There is no send-message pulse. For a value-bearing command the FP value
   is written FIRST, then the command; the echoed value coming back equal to
   what was sent IS the acknowledgement (Table B-4 note 6).

   BLOCKING: sendCommand polls with time.sleep for up to timeoutMs, and
   applySetpoint chains four of them (~6s worst case at the 1.5s per-command
   timeout). It must therefore NOT be called on a Perspective session thread --
   use applySetpointAsync, which is this module's gateway-script-async
   (FDS-01-014) wrapper, shaped after BlueRidge.Lots.ShippingDispatcher (the
   project's reference for that idiom). The synchronous applySetpoint stays
   public for gateway-scope callers and for script-console commissioning.

   Timing note (spec rev 2 Sec 6.5): the sequence cost is dominated by the
   Protocol/* tag group's poll rate, because observing the ack rotate costs one
   poll interval per command. At the specified 100ms group a normal 4-command
   sequence is ~0.6s; at Ignition's usual 1000ms default it is ~4.2s. If the
   sequence feels slow, check the tag group before suspecting this module.
"""

import java.lang
import time

# ---- command codes (standard target control; Fill-570 NOT licensed) --------
# With Fill-570 installed these are illegal and become 170/173/174/119.
CMD = {
    "REPORT_NET":       11,
    "SET_TARGET":      110,
    "SET_TOL_PLUS":    131,
    "SET_TOL_MINUS":   112,
    "START_COMPARE":   114,
    "ABORT_COMPARE":   115,
    "TARGET_USE_NET":  117,
    "LATCH_DISABLE":   122,
    "REPORT_UNITS":     30,
    # Table B-4: "Reset (clear) ENTER key". The ENTER-key status bit (HR4.8)
    # LATCHES on a physical press; without this the latch never drops and the
    # next press is invisible. ScaleWatcher sends it AFTER the tray-close proc
    # returns, so a press consumed by a capture that then failed is not
    # silently swallowed.
    "CLEAR_ENTER_KEY":  75,
}

# FP Indicator values (Table B-2) that carry meaning for us.
FP_GROSS = 0
FP_NET = 1
FP_CMD_OK = 30
FP_INVALID = 31

_POLL_MS = 100

# Per-command ack timeout. 1.5s, not 3s (spec rev 2 Sec 6.5): at the specified
# 100ms Protocol tag group a healthy command acks in ~150ms, so 1.5s is still
# 10x headroom, while the dead-link worst case for the 4-command sequence plus
# its ABORT drops from ~15s to ~6s.
_CMD_TIMEOUT_MS = 1500

# Echo-comparison tolerance. The echoed value has been round-tripped through a
# Modbus float32, which carries ~7 significant digits (relative ulp ~6e-8), so
# a fixed absolute threshold necessarily fails at large magnitudes: the old
# flat 1e-4 breaks for any target above ~1000 lb from encoding alone, and the
# resulting message blames byte order -- sending commissioning down entirely
# the wrong path.
#
#   _ECHO_ABS_EPS   floor, identical to the old absolute threshold, so nothing
#                   below ~10 lb is loosened by this change at all; it also
#                   keeps the test meaningful when value is 0.
#   _ECHO_REL_EPS   1e-5 relative -- ~165 float32 ulps, wide enough to absorb
#                   encoding and terminal-side rounding at any magnitude, and
#                   still tiny next to the fault it is looking for: a
#                   word-swapped float mangles the exponent and comes back
#                   orders of magnitude wrong, never a few ulps wrong.
_ECHO_ABS_EPS = 1e-4
_ECHO_REL_EPS = 1e-5


def _echoTolerance(value):
    """Absolute slack allowed between a value sent and the value echoed back."""
    return max(_ECHO_ABS_EPS, abs(float(value)) * _ECHO_REL_EPS)


def _valuesMatch(a, b):
    """Float compare at the echo tolerance. None never matches -- a bad-quality
       tag read is an unknown, not an equality."""
    if a is None or b is None:
        return False
    return abs(float(a) - float(b)) <= _echoTolerance(b)


def parkLiveCommand(instancePath, timeoutMs=_CMD_TIMEOUT_MS):
    """Park 'report net weight' in slot 1. MUST be re-run on every device
       reconnect -- a terminal power cycle clears the command register to 0,
       and command 0 reports GROSS weight (Table B-4 note 1). The failure is
       silent: plausible, well-formed, wrong numbers.

       Because that is the module's headline silent failure, the write is
       CONFIRMED rather than fired and forgotten: slot 1's FP Indicator must
       settle at FP_NET. The read-back is polled, not immediate -- the write
       goes to the device and the indicator only moves after the terminal
       processes it AND the Protocol tag group next polls (~100ms).

       Returns True when parked. On False the caller is reading GROSS, and the
       capture gate's Weight/SourceIsNet check will refuse every capture -- the
       loud failure this guarantees instead of the silent one."""
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]
    W.writeMember(instancePath, "Protocol/Live/Command", CMD["REPORT_NET"])

    waited = 0
    fp = None
    while waited < timeoutMs:
        time.sleep(_POLL_MS / 1000.0)
        waited += _POLL_MS
        fp = W.readMember(instancePath, "Protocol/Live/FpIndicator")
        if fp == FP_NET:
            W.logInterface(device, "Park live command",
                           requestPayload="command=%s" % CMD["REPORT_NET"],
                           responsePayload="FpIndicator=%s (net)" % fp, ok=True)
            return True

    msg = ("Slot 1 did not park on net weight after %sms: FpIndicator=%s "
           "(expected %s). The scale is reporting GROSS weight -- captures "
           "will be refused until this is resolved." % (timeoutMs, fp, FP_NET))
    W.logInterface(device, "Park live command",
                   requestPayload="command=%s" % CMD["REPORT_NET"],
                   responsePayload=msg, ok=False, errorDescription=msg)
    return False


def sendCommand(instancePath, code, value=None, timeoutMs=_CMD_TIMEOUT_MS):
    """Send one command through slot 2 and wait for the ack to rotate.

       Returns {"ok": bool, "message": str, "echo": float or None}.
       For value-bearing commands the FP value is written BEFORE the command
       (Table B-6 establishes that ordering) and the echo is verified.

       BLOCKS for up to timeoutMs. Do not call from a Perspective event
       handler; dispatch on a gateway-async thread (see module header)."""
    W = BlueRidge.Workorder.PlcWatcher
    before = W.readMember(instancePath, "Protocol/Command/CommandAck")

    if value is not None:
        W.writeMember(instancePath, "Protocol/Command/LoadValue", float(value))
    W.writeMember(instancePath, "Protocol/Command/Command", int(code))

    waited = 0
    while waited < timeoutMs:
        time.sleep(_POLL_MS / 1000.0)
        waited += _POLL_MS
        ack = W.readMember(instancePath, "Protocol/Command/CommandAck")
        if ack == before:
            continue

        fp = W.readMember(instancePath, "Protocol/Command/FpIndicator")
        if fp == FP_INVALID:
            return {"ok": False, "echo": None,
                    "message": "Command %s rejected as invalid. If this "
                               "persists the terminal has Fill-570 installed "
                               "and needs commands 170/173/174/119." % code}

        echo = W.readMember(instancePath, "Protocol/Command/EchoValue")
        if value is not None:
            # readMember returns None on bad tag quality. Handled explicitly,
            # not caught: float(None) raises TypeError straight out of this
            # function, and a Jython `except Exception` would not catch a Java
            # tag-subsystem throwable anyway, so a catch is the wrong tool.
            if echo is None:
                return {"ok": False, "echo": None,
                        "message": "Command %s: the echoed value read back at "
                                   "bad quality, so the write could not be "
                                   "confirmed. Check the device connection and "
                                   "the Protocol/Command/EchoValue address."
                                   % code}
            if abs(float(echo) - float(value)) > _echoTolerance(value):
                return {"ok": False, "echo": echo,
                        "message": "Echo mismatch on command %s: sent %s, got %s. "
                                   "Check terminal Byte Order = Double Word Swap."
                                   % (code, value, echo)}
        return {"ok": True, "echo": echo, "message": "OK"}

    return {"ok": False, "echo": None,
            "message": "Command %s timed out after %sms with no acknowledgement."
                       % (code, timeoutMs)}


def applySetpoint(instancePath, target, tolerance):
    """Flow A. Load target + both tolerances, then start target comparison.

       A partial application is worse than no change -- a new target paired
       with stale tolerances silently validates against the wrong window. On
       any step failure this aborts comparison and leaves ActiveTarget at its
       previous value, so Target != ActiveTarget stays visible as the signal
       that the line is on a stale setpoint.

       BLOCKS for up to ~4x sendCommand's timeout (~6s at the 1.5s per-command
       timeout, plus the ABORT on the failing step). Caller must run it off the
       session thread -- applySetpointAsync is that wrapper."""
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]
    W.writeMember(instancePath, "Setpoint/State", "Loading")

    steps = [
        (CMD["SET_TARGET"],    target),
        (CMD["SET_TOL_PLUS"],  tolerance),
        (CMD["SET_TOL_MINUS"], tolerance),
        (CMD["START_COMPARE"], None),
    ]

    for code, value in steps:
        result = sendCommand(instancePath, code, value)
        if not result["ok"]:
            sendCommand(instancePath, CMD["ABORT_COMPARE"])
            W.writeMember(instancePath, "Setpoint/State", "Failed")
            W.logInterface(device, "Setpoint load",
                           requestPayload="target=%s tol=%s" % (target, tolerance),
                           responsePayload=result["message"], ok=False,
                           errorDescription=result["message"])
            return {"ok": False, "message": result["message"]}

    # ActiveTarget/ActiveTolerance are written ONLY here, on the success path.
    # They are the record of what the terminal is confirmed to be enforcing --
    # which is exactly what applySetpointAsync's skip-if-unchanged test needs,
    # and why a failed load must leave them alone.
    W.writeMember(instancePath, "Setpoint/ActiveTarget", float(target))
    W.writeMember(instancePath, "Setpoint/ActiveTolerance", float(tolerance))
    W.writeMember(instancePath, "Setpoint/State", "Active")
    W.logInterface(device, "Setpoint load",
                   requestPayload="target=%s tol=%s" % (target, tolerance),
                   ok=True)
    return {"ok": True, "message": "Setpoint active"}


def _applySetpointWorker(instancePath, terminalLocationId, target, tolerance):
    """GATEWAY-ASYNC: run the whole 4-command sequence off-thread and surface
       the outcome to the ONE operator sitting at this terminal.

       applySetpoint already stamps Setpoint/State and writes Audit.InterfaceLog
       on every branch, so this adds only the operator-visible half. Never
       throws -- it runs detached on a gateway thread, where an escaping
       exception goes nowhere but the logs."""
    try:
        result = applySetpoint(instancePath, target, tolerance)
        if not result.get("ok"):
            BlueRidge.Workorder.PlcWatcher.notifyAlarm(
                terminalLocationId, "Scale setpoint load failed",
                result.get("message") or "Setpoint load failed.")
    except (Exception, java.lang.Exception) as e:
        # Jython's `except Exception` does NOT catch a Java throwable, and the
        # tag subsystem raises those -- hence the pair.
        msg = "Setpoint load failed unexpectedly: %s" % str(e)
        BlueRidge.Common.Util.log(
            "_applySetpointWorker failed for %s: %s" % (instancePath, str(e)),
            level="debug")
        try:
            # applySetpoint leaves State at "Loading" if it died mid-sequence;
            # a stuck "Loading" would keep the capture button disabled forever
            # with nothing on screen to explain it.
            BlueRidge.Workorder.PlcWatcher.writeMember(
                instancePath, "Setpoint/State", "Failed")
            BlueRidge.Workorder.PlcWatcher.notifyAlarm(
                terminalLocationId, "Scale setpoint load failed", msg)
        except (Exception, java.lang.Exception):
            pass


def applySetpointAsync(instancePath, terminalLocationId, target, tolerance):
    """Flow A, dispatched. The gateway-script-async idiom (FDS-01-014), shaped
       after BlueRidge.Lots.ShippingDispatcher.dispatch -- the project's
       reference for it: do the cheap checks on the calling thread and return a
       status immediately, run the slow loop under invokeAsynchronous, and
       report the real outcome through PlcWatcher.notifyAlarm, which
       BlueRidge/Components/NotifyHost already filters per terminal.

       Returns {"ok": bool, "message": str} IMMEDIATELY. `ok` here means
       "accepted for dispatch", NOT "the terminal took it" -- the only inline
       failure is the skip test reading bad quality, which it survives by
       pushing anyway. Watch Setpoint/State for the real answer.

       SKIP-IF-UNCHANGED (spec rev 2 Sec 6.5 item 4): re-selecting the part
       already running must cost nothing. The test is against ActiveTarget AND
       ActiveTolerance -- comparing target alone would silently skip a
       tolerance-only change and leave the line validating against a stale
       window. State must also be Active: after a failed load ActiveTarget
       still describes the last SUCCESSFUL push, but the sequence sent
       ABORT_COMPARE, so the terminal is not enforcing anything and the retry
       must go through."""
    W = BlueRidge.Workorder.PlcWatcher
    active = W.readMembers(instancePath, [
        "Setpoint/ActiveTarget", "Setpoint/ActiveTolerance", "Setpoint/State",
    ])
    if (active.get("Setpoint/State") == "Active"
            and _valuesMatch(active.get("Setpoint/ActiveTarget"), target)
            and _valuesMatch(active.get("Setpoint/ActiveTolerance"), tolerance)):
        return {"ok": True, "message": "Setpoint already active on this scale."}

    # Record the REQUESTED values before dispatching. Nothing else writes these
    # -- without them applySetpoint's "Target != ActiveTarget is the visible
    # signal that the line is on a stale setpoint" is a signal that can never
    # fire, because Target would sit at its 0.0 default forever.
    W.writeMember(instancePath, "Setpoint/Target", float(target))
    W.writeMember(instancePath, "Setpoint/Tolerance", float(tolerance))
    system.util.invokeAsynchronous(
        lambda: _applySetpointWorker(instancePath, terminalLocationId,
                                     float(target), float(tolerance)))
    return {"ok": True, "message": "Setpoint loading"}


def captureGate(instancePath):
    """All five conditions must hold before a reading may be trusted.
       Returns {"ok": bool, "reason": str or None}."""
    W = BlueRidge.Workorder.PlcWatcher
    v = W.readMembers(instancePath, [
        "Weight/InMotion", "Weight/IsValid", "Weight/SourceIsNet",
        "Protocol/Live/Integrity1", "Protocol/Live/Integrity2",
        "Setpoint/State",
    ])

    if v.get("Weight/InMotion"):
        return {"ok": False, "reason": "Scale is still in motion."}
    if not v.get("Weight/IsValid"):
        return {"ok": False,
                "reason": "Scale reports data not OK -- in setup, over "
                          "capacity, or under zero."}
    if not v.get("Weight/SourceIsNet"):
        return {"ok": False,
                "reason": "Scale is reporting GROSS weight, not net. The "
                          "command register was cleared -- re-park it."}
    if bool(v.get("Protocol/Live/Integrity1")) != bool(v.get("Protocol/Live/Integrity2")):
        return {"ok": False,
                "reason": "Scale data integrity bits disagree -- reading is "
                          "mid-update."}
    if v.get("Setpoint/State") != "Active":
        return {"ok": False,
                "reason": "No target is active on this scale. Load a setpoint "
                          "before validating a tray."}
    return {"ok": True, "reason": None}
