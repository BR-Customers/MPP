"""BlueRidge.Quality.Hold - thin access to the Phase 7 Hold procs.

   Wrappers only; no business logic. Arc 2 Phase 7 (Hold / FDS-08-007a). place +
   release route through BlueRidge.Common.Db.execMutation (status-row procs); the
   getOpen* reads route through execList. appUserId defaults to the current
   operator via BlueRidge.Common.Util._currentAppUserId() when None. Each entry
   logs at default INFO."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def place(holdTypeCodeId, lotId=None, containerId=None, reason=None, appUserId=None, terminalLocationId=None):
    """Place a hold on exactly one of a LOT or a Container. Rejects if an open hold
       already exists for the target. Returns {Status, Message, NewId (HoldEventId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "place holdTypeCodeId=%s lotId=%s containerId=%s appUserId=%s"
        % (holdTypeCodeId, lotId, containerId, appUserId))
    params = {"lotId": lotId, "containerId": containerId,
              "holdTypeCodeId": holdTypeCodeId, "reason": reason,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("quality/Hold_Place", params)


def release(holdEventId, releaseRemarks=None, appUserId=None, terminalLocationId=None):
    """Release a single open hold -- restores the LOT to its prior status / a
       Container to Complete. Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "release holdEventId=%s appUserId=%s" % (holdEventId, appUserId))
    params = {"holdEventId": holdEventId, "releaseRemarks": releaseRemarks,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("quality/Hold_Release", params)


def getOpenByLot(lotId):
    """Read the open hold for a LOT (with HoldTypeCode). Returns list[dict]
       (empty list = no open hold)."""
    BlueRidge.Common.Util.log("getOpenByLot lotId=%s" % lotId)
    params = {"lotId": lotId}
    return BlueRidge.Common.Db.execList("quality/Hold_GetOpenByLot", params)


def getOpenByContainer(containerId):
    """Read the open hold for a Container (with HoldTypeCode). Returns list[dict]
       (empty list = no open hold)."""
    BlueRidge.Common.Util.log("getOpenByContainer containerId=%s" % containerId)
    params = {"containerId": containerId}
    return BlueRidge.Common.Db.execList("quality/Hold_GetOpenByContainer", params)


def listOpen(_refreshToken=None):
    """List all open holds for the Hold Management open-holds panels. Returns
       list[dict] (empty = none). _refreshToken lets a view binding force a re-read
       after a place/release (pass it as a runScript arg)."""
    BlueRidge.Common.Util.log("listOpen")
    return BlueRidge.Common.Db.execList("quality/Hold_ListOpen")
