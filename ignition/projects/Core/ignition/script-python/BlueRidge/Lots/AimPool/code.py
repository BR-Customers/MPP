"""BlueRidge.Lots.AimPool - thin access to the Phase 6 AIM shipper-ID pool procs.

   Wrappers only; no business logic. Arc 2 Phase 6 (AIM shipper-ID pooling).
   topup/claim route through BlueRidge.Common.Db.execMutation (status-row procs);
   getDepth routes through execList. claim's appUserId defaults to the current
   operator when None. topup is system-driven (the AIM fetch loop), so it carries
   no appUserId."""


def topup(aimShipperId, fetchedInterfaceLogId=None):
    """Add a fetched AIM shipper ID to the pool, optionally linked to the
       Audit.InterfaceLog row that fetched it. Returns
       {Status, Message, NewId (AimShipperIdPoolId)}."""
    BlueRidge.Common.Util.log(
        "topup aimShipperId=%s fetchedInterfaceLogId=%s"
        % (aimShipperId, fetchedInterfaceLogId))
    params = {"aimShipperId": aimShipperId,
              "fetchedInterfaceLogId": fetchedInterfaceLogId}
    return BlueRidge.Common.Db.execMutation("lots/AimShipperIdPool_Topup", params)


def claim(containerId, appUserId=None):
    """Claim the next available AIM shipper ID from the pool, binding it to a
       container. Returns {Status, Message, AimShipperId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "claim containerId=%s appUserId=%s"
        % (containerId, appUserId))
    params = {"containerId": containerId, "appUserId": appUserId}
    return BlueRidge.Common.Db.execMutation("lots/AimShipperIdPool_Claim", params)


def getDepth():
    """Read the un-consumed pool depth across the whole pool. Returns a
       single-row list[dict] of {Depth, OldestAvailableAt}."""
    BlueRidge.Common.Util.log("getDepth")
    return BlueRidge.Common.Db.execList("lots/AimShipperIdPool_GetDepth", {})
