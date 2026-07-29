"""BlueRidge.Workorder.TrayInspectionWatcher - tray-inspection FIFO validation.

   The FIFO-validation core of the PLC integration (spec Sec 4.3/4.4, 5).

   TrayLocked rising edge -> recipe select:
     assembly-out FIFO front LOT (Lot_GetWipQueueByLocation) -> its Item ->
     Item_GetPlcId -> write that integer as PartNumber (the PLC selects the vision
     recipe before it inspects) + release-context members (gated).

   InspectionComplete rising edge -> vision validation:
     read VisionPartNumber -> compare to the expected LOT's Item.PlcId.
       mismatch -> LINE STOP: do NOT release the tray (OkToContinue stays false),
                   log a PlcLineStop event, raise the HMI alarm (gated).
       match    -> write OkToContinue = true (release). The tray CLOSE bookkeeping
                   (open container / tray position / passed-parts count from the
                   PartDisposition slots) is line-specific -> commissioning hook.

   The compare is the whole point of Item.PlcId; it is a data comparison of two
   PLC/DB integers, not a business rule. No thresholds/matrices in Python.
"""

import BlueRidge.Common.Util
import BlueRidge.Workorder.PlcWatcher
import BlueRidge.Workorder.Assembly
import BlueRidge.Lots.Lot
import BlueRidge.Parts.Item


def handleEdge(instancePath, terminalLocationId, member):
    if member == "TrayLocked":
        _onTrayLocked(instancePath, terminalLocationId)
    elif member == "InspectionComplete":
        _onInspectionComplete(instancePath, terminalLocationId)


def _expectedPlcId(terminalLocationId):
    """(frontLot, expectedPlcId) for the assembly-out FIFO front, or (None, None)."""
    q = BlueRidge.Lots.Lot.getWipQueueByLocation(terminalLocationId, includeDescendants=True)
    if not q:
        return (None, None)
    front = q[0]
    row = BlueRidge.Parts.Item.getPlcId(front.get("ItemId"))
    plcId = row.get("PlcId") if row else None
    return (front, plcId)


def _onTrayLocked(instancePath, terminalLocationId):
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]
    front, plcId = _expectedPlcId(terminalLocationId)
    if front is None:
        W.logInterface(device, "Tray locked (no active LOT)",
                       requestPayload="terminal=%s" % terminalLocationId, ok=False,
                       errorDescription="No active LOT in the assembly queue")
        return
    if plcId is None:
        W.logInterface(device, "Tray locked (LOT item has no PlcId)",
                       requestPayload="lot=%s item=%s" % (front.get("Id"), front.get("ItemId")),
                       ok=False, errorDescription="Item.PlcId is not set")
        BlueRidge.Common.Util.log(
            "tray %s: front LOT item %s has no PlcId -- cannot select recipe"
            % (instancePath, front.get("ItemId")), level="warn")
        return
    # Select the vision recipe in the PLC (control write, not display).
    W.writeMember(instancePath, "PartNumber", plcId)
    W.logInterface(device, "Tray locked -> recipe select",
                   requestPayload="lot=%s item=%s" % (front.get("Id"), front.get("ItemId")),
                   responsePayload="PartNumber=%s" % plcId, ok=True)


def _onInspectionComplete(instancePath, terminalLocationId):
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]
    front, expected = _expectedPlcId(terminalLocationId)
    vision = W.readMember(instancePath, "VisionPartNumber")

    if front is None or expected is None:
        W.logInterface(device, "Inspection complete (no expected recipe)",
                       requestPayload="vision=%s" % vision, ok=False,
                       errorDescription="No active LOT / Item.PlcId to validate against")
        return

    # Data comparison of two integers -- expected recipe vs. what vision read.
    if vision is None or int(vision) != int(expected):
        # LINE STOP -- leave the tray locked (do not release), alarm + record.
        reason = "Vision %s != expected recipe %s (lot %s)" % (vision, expected, front.get("Id"))
        W.logInterface(device, "Vision mismatch -> line stop",
                       requestPayload="lot=%s expected=%s vision=%s"
                       % (front.get("Id"), expected, vision),
                       ok=False, errorDescription=reason, logEventTypeCode="PlcLineStop")
        W.writeDisplay(instancePath, {"MESAlarmType": 2, "MESAlarmText": reason})
        BlueRidge.Common.Util.log("tray %s LINE STOP: %s" % (instancePath, reason), level="warn")
        return

    # Match -> release the tray (physical handshake first; the DB record follows).
    W.writeMember(instancePath, "OkToContinue", True)
    W.logInterface(device, "Inspection complete -> tray released",
                   requestPayload="lot=%s recipe=%s" % (front.get("Id"), expected),
                   responsePayload="OkToContinue=True", ok=True)
    # Record the tray close: mint the FG LOT + consume BOM via the shared PLC close
    # (the SAME Assembly_CompleteTray path the operator ByCount button uses). Piece
    # count = the finished good's configured ByVision PartsPerTray; the container
    # auto-completes (AIM + label) when full. A resolution/DB failure alarms the HMI
    # but leaves the tray released (the parts physically passed inspection).
    result = BlueRidge.Workorder.Assembly.plcCompleteTray(terminalLocationId, "ByVision")
    ok = bool(result and result.get("Status"))
    W.logInterface(device, "ByVision tray close",
                   requestPayload="terminal=%s recipe=%s" % (terminalLocationId, expected),
                   responsePayload=str(result), ok=ok,
                   errorDescription=None if ok else (result or {}).get("Message"))
    if not ok:
        W.writeDisplay(instancePath, {"MESAlarmType": 1,
                                      "MESAlarmText": (result or {}).get("Message") or "Tray close failed"})
