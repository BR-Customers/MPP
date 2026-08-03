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


def getForPost(aimShipperId):
    """Read one pool row's AIM post-back payload. Returns list[dict] (empty = not found).
       CustomerPartNumber is COALESCEd against the live item, so a row completed before
       the item had an AIM customer part picks the value up once it is configured."""
    BlueRidge.Common.Util.log("getForPost aimShipperId=%s" % aimShipperId, level="debug")
    return BlueRidge.Common.Db.execList(
        "lots/AimShipperIdPool_GetForPost", {"aimShipperId": aimShipperId})


def recordPostResult(poolId, success, error=None):
    """Record one AIM post attempt's outcome. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "recordPostResult poolId=%s success=%s" % (poolId, success), level="debug")
    return BlueRidge.Common.Db.execMutation(
        "lots/AimShipperIdPool_RecordPostResult",
        {"id": poolId, "success": 1 if success else 0, "error": error})


def listUnposted(top=50):
    """Rows owed to AIM (consumed, not yet posted), oldest first. Returns list[dict]."""
    return BlueRidge.Common.Db.execList("lots/AimShipperIdPool_ListUnposted", {"top": top})


def markPosted(poolId, note, appUserId=None):
    """Human-confirmed resolution for a row AIM already has but never acknowledged.
       Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "lots/AimShipperIdPool_MarkPosted",
        {"id": poolId, "appUserId": appUserId, "note": note})
