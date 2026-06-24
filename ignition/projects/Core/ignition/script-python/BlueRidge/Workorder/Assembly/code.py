"""BlueRidge.Workorder.Assembly - thin access to the Phase 6 Assembly IN proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (FDS-06-008 uncoupled path:
   the operator scans a machined component LOT into an Assembly Cell's queue so it
   can be consumed at the fill). Entry logs at default INFO. Routes through
   BlueRidge.Common.Db.execMutation; appUserId defaults to the current operator
   when None."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def scanIn(cellLocationId, lotName=None, lotId=None, appUserId=None, terminalLocationId=None):
    """Move a machined component LOT into an Assembly Cell's queue (no rename).
       The operator typically scans an LTT barcode -> pass it as lotName; lotId is
       accepted too. Validates the LOT's Item is a BOM component of an assembly
       produced at the cell; a non-component LOT rejects. Returns {Status, Message,
       NewId (LotMovementId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "scanIn lotName=%s lotId=%s cellLocationId=%s appUserId=%s"
        % (lotName, lotId, cellLocationId, appUserId))
    params = {"lotId": lotId, "lotName": lotName, "cellLocationId": cellLocationId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("workorder/Assembly_ScanIn", params)
