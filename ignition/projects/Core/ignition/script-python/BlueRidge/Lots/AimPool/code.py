"""BlueRidge.Lots.AimPool - thin access to the Phase 6 AIM shipper-ID pool procs.

   Wrappers only; no business logic. Arc 2 Phase 6 (AIM shipper-ID pooling).
   topup/claim route through BlueRidge.Common.Db.execMutation (status-row procs);
   getDepth routes through execList. claim's appUserId defaults to the current
   operator when None. topup is system-driven (the AIM fetch loop), so it carries
   no appUserId."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def topup(partNumber, aimShipperId, fetchedInterfaceLogId=None):
    """Add a fetched AIM shipper ID to the pool for a part number, optionally
       linked to the Audit.InterfaceLog row that fetched it. Returns
       {Status, Message, NewId (AimShipperIdPoolId)}."""
    BlueRidge.Common.Util.log(
        "topup partNumber=%s aimShipperId=%s fetchedInterfaceLogId=%s"
        % (partNumber, aimShipperId, fetchedInterfaceLogId))
    params = {"partNumber": partNumber, "aimShipperId": aimShipperId,
              "fetchedInterfaceLogId": fetchedInterfaceLogId}
    return BlueRidge.Common.Db.execMutation("lots/AimShipperIdPool_Topup", params)


def claim(partNumber, containerId, appUserId=None):
    """Claim the next available AIM shipper ID from the pool for a part number,
       binding it to a container. Returns {Status, Message, AimShipperId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "claim partNumber=%s containerId=%s appUserId=%s"
        % (partNumber, containerId, appUserId))
    params = {"partNumber": partNumber, "containerId": containerId,
              "appUserId": appUserId}
    return BlueRidge.Common.Db.execMutation("lots/AimShipperIdPool_Claim", params)


def getDepth(partNumber=None):
    """Read the un-consumed pool depth per part number. partNumber=None returns
       every part. Returns list[dict] of {PartNumber, Depth} (empty list = no
       available IDs)."""
    BlueRidge.Common.Util.log("getDepth partNumber=%s" % partNumber)
    params = {"partNumber": partNumber}
    return BlueRidge.Common.Db.execList("lots/AimShipperIdPool_GetDepth", params)
