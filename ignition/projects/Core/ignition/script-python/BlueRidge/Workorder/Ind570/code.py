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
   applySetpoint chains four of them (~12s worst case). It must therefore NOT
   be called on a Perspective session thread -- see the project's
   gateway-script-async idiom (FDS-01-014), BlueRidge.Lots.ShippingDispatcher
   being the reference. Task 5's ScaleWatcher.loadSetpointForItem is the
   intended caller and owns that dispatch decision.
"""

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
}

# FP Indicator values (Table B-2) that carry meaning for us.
FP_GROSS = 0
FP_NET = 1
FP_CMD_OK = 30
FP_INVALID = 31

_POLL_MS = 100


def parkLiveCommand(instancePath):
    """Park 'report net weight' in slot 1. MUST be re-run on every device
       reconnect -- a terminal power cycle clears the command register to 0,
       and command 0 reports GROSS weight (Table B-4 note 1). The failure is
       silent: plausible, well-formed, wrong numbers."""
    W = BlueRidge.Workorder.PlcWatcher
    W.writeMember(instancePath, "Protocol/Live/Command", CMD["REPORT_NET"])


def sendCommand(instancePath, code, value=None, timeoutMs=3000):
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
        if value is not None and abs(float(echo) - float(value)) > 0.0001:
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

       BLOCKS for up to ~4x sendCommand's timeout (~12s). Caller must run it
       off the session thread (see module header)."""
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

    W.writeMember(instancePath, "Setpoint/ActiveTarget", float(target))
    W.writeMember(instancePath, "Setpoint/State", "Active")
    W.logInterface(device, "Setpoint load",
                   requestPayload="target=%s tol=%s" % (target, tolerance),
                   ok=True)
    return {"ok": True, "message": "Setpoint active"}


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
