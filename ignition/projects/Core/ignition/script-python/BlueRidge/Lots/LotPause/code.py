"""BlueRidge.Lots.LotPause - thin access to the LOT pause lifecycle reads + resume."""


def getCountByLocation(locationId):
    """Open-pause count for the indicator badge. Returns dict {LocationId, OpenPauseCount} or None."""
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    return BlueRidge.Common.Db.execOne("lots/LotPause_GetCountsByLocation", {"locationId": locationId})


def getOpenCount(locationId=None, _refreshToken=None):
    """Open-pause COUNT as a plain int. locationId None -> PLANT-WIDE, which is what
       the Supervisor Dashboard's Paused-LOTs tile needs (the per-Cell indicator badge
       keeps using getCountByLocation).

       Binding-safe: always an int, never None, so a label expression can render it
       without a coalesce and a read failure shows 0 rather than a Quality-Bad tile.
       _refreshToken is accepted and ignored -- runScript caches on its argument list,
       so a caller that wants a re-read must pass a changing token as an ARG."""
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    try:
        row = BlueRidge.Common.Db.execOne(
            "lots/LotPause_GetCountsByLocation", {"locationId": locationId})
    except Exception, e:
        BlueRidge.Common.Util.log("getOpenCount failed: %s" % e, level="error")
        return 0
    if not row:
        return 0
    return int(row.get("OpenPauseCount") or 0)


def getByLocation(locationId):
    """Open pauses at a Cell, oldest-first (indicator detail list). list[dict]."""
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    return BlueRidge.Common.Db.execList("lots/LotPause_GetByLocation", {"locationId": locationId})


def resume(pauseEventId, resumedRemarks=None, appUserId=None):
    """Close an open pause. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("pauseEventId=%s" % pauseEventId)
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"pauseEventId": pauseEventId, "resumedRemarks": resumedRemarks, "appUserId": appUserId}
    return BlueRidge.Common.Db.execMutation("lots/LotPause_Resume", params)
