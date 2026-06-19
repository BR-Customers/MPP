"""BlueRidge.Workorder.Machining - thin access to the Phase 5 Machining procs.

   Wrappers only; no business logic. Arc 2 Phase 5 (FDS-05-033 / FDS-06-008 /
   FDS-05-009). Each entry logs at default INFO (these are meaningful shop-floor
   events, not debug noise)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def pickAndConsume(sourceLotId, cellLocationId, queueOverrideReason=None, appUserId=None, terminalLocationId=None):
    """Machining IN: FIFO pick of a whole cast/trim LOT + BOM-driven rename
       (FDS-05-033). Mints the machined LOT, consumes the source, writes genealogy +
       checkpoint, closes the source. Returns {Status, Message, NewId (machined
       LotId), NewMachinedLotName, ConsumptionEventId, ProductionEventId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "pickAndConsume sourceLotId=%s cellLocationId=%s appUserId=%s"
        % (sourceLotId, cellLocationId, appUserId))
    params = {"sourceLotId": sourceLotId, "cellLocationId": cellLocationId,
              "queueOverrideReason": queueOverrideReason, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("workorder/MachiningIn_PickAndConsume", params)


def autoComplete(lotId, cellLocationId, appUserId=None, terminalLocationId=None):
    """Machining OUT (PLC-driven, non-sublotting line, FDS-06-008): closing
       checkpoint + coupled auto-move (or no move when uncoupled). Returns
       {Status, Message, ProductionEventId, AutoMoved, ToLocationId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "autoComplete lotId=%s cellLocationId=%s appUserId=%s"
        % (lotId, cellLocationId, appUserId))
    params = {"lotId": lotId, "cellLocationId": cellLocationId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("workorder/MachiningOut_AutoComplete", params)


def recordSplit(parentLotId, operationTemplateId, splitChildrenJson, appUserId=None, terminalLocationId=None):
    """Machining OUT (operator-driven sub-LOT split, sublotting line, FDS-05-009).
       splitChildrenJson is a JSON array of {pieceCount, destinationLocationId}.
       The proc returns a MULTI-ROW result (header Status/Message/ProductionEventId
       repeated on every row + per-child ChildLotId/ChildLotName/
       DestinationLocationId/PieceCount), so this uses execList. Returns a dict:
         {Status, Message, ProductionEventId, children: [ {ChildLotId, ChildLotName,
          DestinationLocationId, PieceCount}, ... ]}.
       On failure the proc returns a single row with NULL child columns -> children
       is []."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "recordSplit parentLotId=%s operationTemplateId=%s appUserId=%s"
        % (parentLotId, operationTemplateId, appUserId))
    params = {"parentLotId": parentLotId, "operationTemplateId": operationTemplateId,
              "splitChildrenJson": splitChildrenJson, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    rows = BlueRidge.Common.Db.execList("workorder/MachiningOut_RecordSplit", params)
    if not rows:
        return {"Status": 0, "Message": "No status returned from proc", "ProductionEventId": None, "children": []}
    head = rows[0]
    children = [
        {"ChildLotId": r.get("ChildLotId"), "ChildLotName": r.get("ChildLotName"),
         "DestinationLocationId": r.get("DestinationLocationId"), "PieceCount": r.get("PieceCount")}
        for r in rows if r.get("ChildLotId") is not None
    ]
    return {"Status": head.get("Status"), "Message": head.get("Message"),
            "ProductionEventId": head.get("ProductionEventId"), "children": children}
