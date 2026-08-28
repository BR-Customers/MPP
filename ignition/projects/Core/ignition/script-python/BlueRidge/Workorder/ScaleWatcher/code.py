"""BlueRidge.Workorder.ScaleWatcher - assembly checkweigh scales (IND570 / Modbus TCP).

   Spec: docs/superpowers/specs/2026-08-27-ind570-scale-udt-modbus-tcp-design.md (rev 2)

   DUAL-TRIGGER. The scale no longer pushes -- net weight is continuously
   present in the polled register -- but the operator PHYSICAL button is still
   the signal, and it survives as a latched status bit:

     physical button -> Trigger/EnterKey (HR4.8) -> tag-change -> onTriggerEdge
     screen button   -> Perspective handler ------------------> captureAndClose

   Both converge on captureAndClose. Nothing is latched in tags; the handler
   reads live, gates, and hands straight to SQL.

   The ENTER latch is acknowledged with command 75 AFTER the proc returns, not
   before -- acknowledging first would silently swallow a press consumed by a
   capture that then failed.
"""

import java.lang
import system.util
import threading


# The trigger member as PlcWatcher.dispatch reports it: the member is the WHOLE
# path below the UDT instance, so a folder-grouped trigger arrives as
# "Trigger/EnterKey", not "EnterKey". See PlcWatcher._splitCandidates -- the old
# flat NET_DataReady split naively on the last "/", which for this nested member
# would have handed resolveInstance ".../<device>/Trigger" and dropped the edge
# entirely with nothing but a "no TerminalPlcDevice mapping" warn.
#
# If commissioning finds the button is wired to a discrete input rather than the
# ENTER key (spec Sec 5.1.2 -- it is the highest-risk unknown in rev 2), this
# becomes "Trigger/Input1" (or 2/3) and the matching path list changes with it:
# ignition/tags/plc_trigger_tag_paths.txt AND the live gateway subscription in
# ignition/projects/MPP/ignition/tag-change/TrayDataReady/resource.json.
_TRIGGERS = ("Trigger/EnterKey",)

# Per-instance re-entrancy guard (spec rev 2 Sec 5.1.1). Two triggers means a
# press can land while a capture is still running (a double-press, or a screen
# tap racing the physical button). A second entry must not close a second tray
# against one weighing.
#
# The two triggers arrive on genuinely different threads -- a gateway tag-change
# thread and a Perspective session thread -- so the test-and-claim needs the
# lock. `if p in _inFlight` followed by `_inFlight.add(p)` is two operations at
# the Python level however atomic the underlying set is, and both threads
# passing the test is exactly the double-close the guard exists to prevent.
_inFlight = set()
_inFlightLock = threading.Lock()


def _toFloat(value):
    """float() that survives a JDBC java.math.BigDecimal.

       ContainerConfig.TargetWeight / .ToleranceWeight are DECIMAL(10,4), and a
       decimal column can reach us as a java.math.BigDecimal, which Jython's
       float() rejects outright -- "float() argument must be a string or a
       number", verified directly against the gateway's own jython-ia-2.7.3.5.
       str() round-trips a BigDecimal exactly, so it is the fallback.

       Returns None when the value is not numeric at all, which the caller
       reports as a configuration error rather than letting a TypeError escape
       into a Perspective event handler."""
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        pass
    try:
        return float(str(value))
    except (TypeError, ValueError):
        return None


def onTriggerEdge(instancePath, terminalLocationId, member):
    """Rising edge on the physical button. Routed here by PlcWatcher.dispatch."""
    if member not in _TRIGGERS:
        return
    captureAndClose(instancePath, terminalLocationId)


def _ackTriggerLatch(instancePath):
    """Clear the latched ENTER bit (command 75) once the capture is finished.

       DISPATCHED OFF-THREAD, per spec rev 2 Sec 5.1 step 8, which puts command
       75 "async, off the critical path". It matters: captureAndClose is called
       straight from a Perspective session thread by the screen button, and
       Ind570.sendCommand BLOCKS until the slot-2 ack rotates or 1.5s elapses.
       Against the simulator, which never rotates the ack, a synchronous call
       would add the full 1.5s to EVERY capture.

       Ordering is unaffected -- this is still only reached after the tray-close
       proc has returned, so a press consumed by a failed capture is not
       silently swallowed.

       Never raises. It runs inside captureAndClose's finally, where an escaping
       exception would replace the real return value; and a Jython
       `except Exception` alone would not catch a Java tag-subsystem throwable."""
    try:
        system.util.invokeAsynchronous(
            lambda: BlueRidge.Workorder.Ind570.sendCommand(
                instancePath,
                BlueRidge.Workorder.Ind570.CMD["CLEAR_ENTER_KEY"]))
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log(
            "ENTER-latch ack dispatch failed for %s: %s" % (instancePath, e),
            level="warn")


def captureAndClose(instancePath, terminalLocationId):
    """Shared entry point for BOTH triggers. Gate the live reading, then close
       the tray through the SAME Assembly_CompleteTray path the ByCount button
       uses (identical genealogy).

       Returns {"Status": 1|0, "Message": str, "ContainerId": id or None}."""
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]

    _inFlightLock.acquire()
    try:
        if instancePath in _inFlight:
            return {"Status": 0, "Message": "A capture is already in progress.",
                    "ContainerId": None}
        _inFlight.add(instancePath)
    finally:
        _inFlightLock.release()

    try:
        gate = BlueRidge.Workorder.Ind570.captureGate(instancePath)
        if not gate["ok"]:
            W.logInterface(device, "Scale capture refused",
                           responsePayload=gate["reason"], ok=False,
                           errorDescription=gate["reason"])
            return {"Status": 0, "Message": gate["reason"], "ContainerId": None}

        vals = W.readMembers(instancePath,
                             ["Weight/Net", "Weight/Uom", "Verdict/State"])
        weight = vals.get("Weight/Net")
        uom = vals.get("Weight/Uom")
        verdict = vals.get("Verdict/State")

        if verdict != "Ok":
            msg = "Tray is %s target - not within tolerance." % (verdict or "outside")
            W.logInterface(device, "Scale capture",
                           requestPayload="weight=%s uom=%s verdict=%s"
                                          % (weight, uom, verdict),
                           ok=False, errorDescription=msg)
            return {"Status": 0, "Message": msg, "ContainerId": None}

        result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId,
                                                              "ByWeight")
        ok = bool(result and result.get("Status"))
        W.logInterface(device, "ByWeight tray close",
                       requestPayload="terminal=%s weight=%s uom=%s"
                                      % (terminalLocationId, weight, uom),
                       responsePayload=str(result), ok=ok,
                       errorDescription=None if ok else (result or {}).get("Message"))

        if not ok:
            msg = (result or {}).get("Message") or "Tray close failed"
            W.notifyAlarm(terminalLocationId, "ByWeight tray close failed", msg)
            return {"Status": 0, "Message": msg, "ContainerId": None}

        return {"Status": 1, "Message": "Tray closed",
                "ContainerId": result.get("ContainerId")}
    finally:
        # Acknowledge the ENTER latch only now, and only off-thread.
        _ackTriggerLatch(instancePath)
        _inFlight.discard(instancePath)


def loadSetpointForItem(instancePath, terminalLocationId, itemId):
    """Flow A entry point. Resolves config SYNCHRONOUSLY (those failures are
       worth returning inline for a toast), then dispatches the command
       sequence asynchronously so it never blocks a session thread.

       A missing tolerance is a configuration error, not a zero -- a zero-width
       window would reject every tray.

       Returns {"ok": bool, "message": str}. On the dispatch path the message is
       applySetpointAsync's own, which distinguishes "Setpoint loading" from
       "Setpoint already active on this scale" -- both are worth showing."""
    # The Python wrapper, NOT system.db.runNamedQuery directly: the named query
    # parameters/config.json declares its identifiers lowercase-initial
    # (itemId, closureMethod), so a hand-rolled {"ItemId": ...} call fails at
    # runtime. getByItemAndMethod returns a plain dict, or {} when there is no
    # such config -- it is NOT a dataset, so there is no getRowCount().
    cfg = BlueRidge.Parts.ContainerConfig.getByItemAndMethod(itemId, "ByWeight")
    if not cfg:
        return {"ok": False,
                "message": "No ByWeight container config for this item."}

    target = _toFloat(cfg.get("TargetWeight"))
    tolerance = _toFloat(cfg.get("ToleranceWeight"))
    if target is None or tolerance is None:
        return {"ok": False,
                "message": "ByWeight config is missing TargetWeight or "
                           "ToleranceWeight. Set both in Item Master before "
                           "running this part."}

    return BlueRidge.Workorder.Ind570.applySetpointAsync(
        instancePath, terminalLocationId, target, tolerance)


def onDeviceReconnect(instancePath):
    """Re-park the live command. A terminal power cycle clears the command
       register to 0, and command 0 reports GROSS weight -- silently. Call
       from the device-connection-state handler and at gateway startup."""
    return BlueRidge.Workorder.Ind570.parkLiveCommand(instancePath)
