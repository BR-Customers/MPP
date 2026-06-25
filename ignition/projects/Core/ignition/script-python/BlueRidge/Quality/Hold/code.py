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


def listOpen(filterText=None, filterTypeId=None, _refreshToken=None):
    """List open holds for the Hold Management open-holds panels (FDS-08-007a).
       Optional filterText (substring over LOT name / container part / reason /
       container id) and filterTypeId (hold type). Returns list[dict] (empty =
       none). _refreshToken lets a view binding force a re-read."""
    BlueRidge.Common.Util.log("listOpen filterText=%s filterTypeId=%s" % (filterText, filterTypeId))
    params = {"filterText": filterText, "filterTypeId": filterTypeId}
    return BlueRidge.Common.Db.execList("quality/Hold_ListOpen", params)


def placeBulk(lotIds, holdTypeCodeId, reason=None, appUserId=None, terminalLocationId=None):
    """Place a hold on each LOT id in lotIds in one operator action (FDS-08-006).
       Loops place() per LOT (each its own status-row call -- no nested INSERT-EXEC).
       Returns {Status, Message, Placed, Failed}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    placed = 0
    failed = 0
    errs = []
    for lid in (lotIds or []):
        if lid is None:
            continue
        res = place(holdTypeCodeId, lotId=int(lid), reason=reason,
                    appUserId=appUserId, terminalLocationId=terminalLocationId)
        if res and res.get("Status"):
            placed += 1
        else:
            failed += 1
            errs.append("LOT %s: %s" % (lid, (res or {}).get("Message") or "failed"))
    BlueRidge.Common.Util.log("placeBulk placed=%d failed=%d" % (placed, failed))
    ok = failed == 0 and placed > 0
    if ok:
        msg = "Placed %d hold(s)." % placed
    elif placed == 0 and failed == 0:
        msg = "No LOTs selected."
    else:
        msg = "Placed %d, %d failed. %s" % (placed, failed, " | ".join(errs[:5]))
    return {"Status": (1 if ok else 0), "Message": msg, "Placed": placed, "Failed": failed}
