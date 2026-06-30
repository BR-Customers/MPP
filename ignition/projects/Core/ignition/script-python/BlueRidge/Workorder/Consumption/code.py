"""BlueRidge.Workorder.Consumption - thin access to the Phase 6 consumption proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (Assembly consumption with
   BOM validation). Entry logs at default INFO. Routes through
   BlueRidge.Common.Db.execMutation; appUserId defaults to the current operator
   when None."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def recordWithBomCheck(sourceLotId, producingLotId, cellLocationId, consumedPieceCount,
                       containerSerialId=None, overrideAppUserId=None, overrideAuthorized=False,
                       appUserId=None, terminalLocationId=None):
    """Record a consumption event at a Cell, validating the source LOT's item is
       on the producing LOT's active BOM. overrideAuthorized + overrideAppUserId
       carry a supervisor's elevation when the BOM check is bypassed.
       containerSerialId optionally ties the consumption to a serialized part.
       Returns {Status, Message, NewId (ConsumptionEventId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "recordWithBomCheck sourceLotId=%s producingLotId=%s cellLocationId=%s consumedPieceCount=%s appUserId=%s"
        % (sourceLotId, producingLotId, cellLocationId, consumedPieceCount, appUserId))
    params = {"sourceLotId": sourceLotId, "producingLotId": producingLotId,
              "cellLocationId": cellLocationId, "consumedPieceCount": consumedPieceCount,
              "containerSerialId": containerSerialId, "overrideAppUserId": overrideAppUserId,
              "overrideAuthorized": overrideAuthorized, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("workorder/ConsumptionEvent_RecordWithBomCheck", params)
