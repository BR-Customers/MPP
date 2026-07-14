"""BlueRidge.Lots.SerializedPart - thin access to the Phase 6 serialized-part
   mint proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (Assembly / Container). Entry
   logs at default INFO. Routes through BlueRidge.Common.Db.execMutation;
   appUserId defaults to the current operator when None."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def mint(itemId, producingLotId, appUserId=None, terminalLocationId=None,
         serialNumber=None):
    """Mint a new serialized part for an item, attributed to its producing LOT.
       serialNumber: PLC/etch-supplied serial; None/empty => auto-generate from
       the identifier sequence (FDS-06-012 NoRead bypass). Returns
       {Status, Message, NewId (SerializedPartId), SerialNumber}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "mint itemId=%s producingLotId=%s serialNumber=%s appUserId=%s"
        % (itemId, producingLotId, serialNumber, appUserId))
    params = {"itemId": itemId, "producingLotId": producingLotId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId,
              "serialNumber": serialNumber}
    return BlueRidge.Common.Db.execMutation("lots/SerializedPart_Mint", params)


def getBySerial(serialNumber):
    """Look up a serialized part by its serial number (uniqueness/dedup check
       for the MIP watcher). Returns dict or None."""
    BlueRidge.Common.Util.log("serialNumber=%s" % serialNumber)
    return BlueRidge.Common.Db.execOne(
        "lots/SerializedPart_GetBySerial", {"serialNumber": serialNumber})
