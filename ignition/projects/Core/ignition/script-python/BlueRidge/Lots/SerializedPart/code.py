"""BlueRidge.Lots.SerializedPart - thin access to the Phase 6 serialized-part
   mint proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (Assembly / Container). Entry
   logs at default INFO. Routes through BlueRidge.Common.Db.execMutation;
   appUserId defaults to the current operator when None."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def mint(itemId, producingLotId, appUserId=None, terminalLocationId=None):
    """Mint a new serialized part for an item, attributed to its producing LOT.
       Allocates the next identifier-sequence serial. Returns
       {Status, Message, NewId (SerializedPartId), SerialNumber}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "mint itemId=%s producingLotId=%s appUserId=%s"
        % (itemId, producingLotId, appUserId))
    params = {"itemId": itemId, "producingLotId": producingLotId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/SerializedPart_Mint", params)
