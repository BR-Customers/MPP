"""BlueRidge.Workorder.SerializedMipWatcher - serialized-line MIP handshake (5G0).

   Rising edge on DataReady / PartComplete (spec Sec 5 archetype):
     set TransInProc -> read PartSN + HardwareInterlockEnforced -> resolve the
     active LOT at the terminal (assembly-out FIFO front) -> SerializedPart_Mint
     (@SerialNumber = PartSN; proc dedups + auto-generates a blank serial) ->
     write PartValid = mint Status -> reset TransInProc + the consumed trigger.

   Pure choreography: dedup + auto-gen live in SerializedPart_Mint. The
   len>=6 / interlock-enforced serial rule is a proc-level decision deferred to
   commissioning (spec Sec 5.2 item 4 flags HardwareInterlockEnforced semantics).
   ContainerCount echo + HMI display members (PartType/alarms) are gated / display
   (spec Sec 5.1/5.3). All mutations attribute to the system AppUser.
"""

import BlueRidge.Common.Util
import BlueRidge.Workorder.PlcWatcher
import BlueRidge.Lots.SerializedPart
import BlueRidge.Lots.Lot

_TRIGGERS = ("DataReady", "PartComplete")


def handleEdge(instancePath, terminalLocationId, member):
    if member not in _TRIGGERS:
        return
    W = BlueRidge.Workorder.PlcWatcher
    appUserId = BlueRidge.Common.Util.systemAppUserId()
    device = instancePath.rsplit("/", 1)[-1]

    W.writeMember(instancePath, "TransInProc", True)
    vals = W.readMembers(instancePath, ["PartSN", "HardwareInterlockEnforced"])
    partSN = ("%s" % (vals.get("PartSN") or "")).strip()
    interlock = bool(vals.get("HardwareInterlockEnforced"))

    front = _frontLot(terminalLocationId)
    if front is None:
        _finish(W, instancePath, device, member, False,
                "No active LOT in the assembly queue", "PartSN=%s" % partSN)
        return

    itemId = front.get("ItemId")
    lotId = front.get("Id")
    serialArg = partSN if partSN else None   # None => proc auto-generates

    result = BlueRidge.Lots.SerializedPart.mint(
        itemId, lotId, appUserId=appUserId,
        terminalLocationId=terminalLocationId, serialNumber=serialArg)
    ok = bool(result and result.get("Status"))
    msg = (result or {}).get("Message")
    _finish(W, instancePath, device, member, ok,
            None if ok else msg,
            "PartSN=%s interlock=%s lot=%s" % (partSN, interlock, lotId),
            responsePayload=str(result))
    # ContainerCount write-back + container close on the configured limit are
    # scale-coupled (ContainerConfig closure) -- commissioning fill-in.


def _frontLot(terminalLocationId):
    q = BlueRidge.Lots.Lot.getWipQueueByLocation(terminalLocationId, includeDescendants=True)
    return q[0] if q else None


def _finish(W, instancePath, device, member, ok, errorReason, requestPayload,
            responsePayload=None):
    """Write PartValid, log the handshake, reset TransInProc + the trigger, and
       surface an alarm (HMI-gated) on failure."""
    W.writeMember(instancePath, "PartValid", ok)
    W.logInterface(device, "Serialized MIP add", requestPayload=requestPayload,
                   responsePayload=responsePayload, ok=ok, errorDescription=errorReason)
    if not ok:
        BlueRidge.Common.Util.log(
            "serialized handshake rejected %s: %s" % (instancePath, errorReason),
            level="warn")
        W.writeDisplay(instancePath, {"MESAlarmType": 1, "MESAlarmText": errorReason or "Rejected"})
    W.writeMembers(instancePath, {member: False, "TransInProc": False})
