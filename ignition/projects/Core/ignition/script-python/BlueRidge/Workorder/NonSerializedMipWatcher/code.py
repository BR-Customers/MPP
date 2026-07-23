"""BlueRidge.Workorder.NonSerializedMipWatcher - non-serialized line MIP (5A2).

   Rising edge on DataReady (spec Sec 5 archetype):
     set TransInProc -> Workorder.Assembly_CompleteTray (mint FG LOT + consume
     BOM FIFO) -> write PartValid -> reset TransInProc / DataReady.

   Assembly_CompleteTray requires @FinishedGoodItemId + @PieceCount + the
   @CellLocationId. Which finished good the line produces and the tray piece
   count are line configuration that is NOT derivable headlessly (the operator
   AssemblyNonSerialized view resolves them via dropdown + input). Resolving them
   for a PLC-driven line is a COMMISSIONING fill-in -- so this watcher edge-guards,
   acknowledges the handshake, and logs; the completeTray call is wired but skipped
   until the line->FG/PieceCount resolution is supplied (mirrors the established
   AssemblyPlc skeleton). No business logic here -- the proc owns BOM/mint.
   PartType + alarm writes are HMI-display (gated, spec Sec 5.1/5.3).
"""

import BlueRidge.Common.Util
import BlueRidge.Workorder.PlcWatcher
import BlueRidge.Workorder.Assembly
import BlueRidge.Location.Terminal

_TRIGGERS = ("DataReady",)


def handleEdge(instancePath, terminalLocationId, member):
    if member not in _TRIGGERS:
        return
    W = BlueRidge.Workorder.PlcWatcher
    device = instancePath.rsplit("/", 1)[-1]
    W.writeMember(instancePath, "TransInProc", True)

    line = _resolveLineConfig(terminalLocationId)
    if line is None:
        # Commissioning: no FG/PieceCount mapping for this line yet. Acknowledge
        # the edge, log, and reset -- do NOT fake a completion.
        W.logInterface(device, "Non-serialized tray complete (no line config)",
                       requestPayload="terminal=%s" % terminalLocationId, ok=False,
                       errorDescription="No FG/PieceCount line config (commissioning)")
        BlueRidge.Common.Util.log(
            "non-serialized line config missing for terminal %s -- ack only"
            % terminalLocationId, level="warn")
        W.writeMembers(instancePath, {member: False, "TransInProc": False})
        return

    appUserId = BlueRidge.Common.Util.systemAppUserId()
    # closureMethod is REQUIRED by Assembly_CompleteTray (NOT NULL). Resolve the
    # terminal's active mode (defaults ByCount) so this call is valid the moment
    # _resolveLineConfig is supplied at commissioning.
    cc = BlueRidge.Location.Terminal.getClosureContext(terminalLocationId) or {}
    closureMethod = cc.get("CurrentClosureMethod") or "ByCount"
    result = BlueRidge.Workorder.Assembly.completeTray(
        line["finishedGoodItemId"], line["pieceCount"], line["cellLocationId"],
        closureMethod=closureMethod, appUserId=appUserId, terminalLocationId=terminalLocationId)
    ok = bool(result and result.get("Status"))
    W.writeMember(instancePath, "PartValid", ok)
    W.logInterface(device, "Non-serialized tray complete",
                   requestPayload="fg=%s count=%s cell=%s"
                   % (line["finishedGoodItemId"], line["pieceCount"], line["cellLocationId"]),
                   responsePayload=str(result), ok=ok,
                   errorDescription=None if ok else (result or {}).get("Message"))
    if ok:
        # Live-refresh the operator terminal at this cell (gateway scope -> no
        # session unless we push). Best-effort; only on a real close.
        BlueRidge.Workorder.Assembly.notifyInventoryChanged(
            line["cellLocationId"], terminalLocationId)
    else:
        W.writeDisplay(instancePath, {"MESAlarmType": 1,
                                      "MESAlarmText": (result or {}).get("Message") or "Tray complete failed"})
    W.writeMembers(instancePath, {member: False, "TransInProc": False})


def _resolveLineConfig(terminalLocationId):
    """The finished good + tray piece count this line produces. COMMISSIONING:
       returns None until the line->FG/PieceCount mapping exists (an Item
       attribute, a per-line config row, or the active WO -- MPP decision). When
       that source lands, return {finishedGoodItemId, pieceCount, cellLocationId}."""
    return None
