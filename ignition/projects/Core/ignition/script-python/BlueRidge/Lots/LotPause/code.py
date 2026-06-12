"""BlueRidge.Lots.LotPause - thin access to the LOT pause lifecycle reads + resume."""
import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getCountByLocation(locationId):
    """Open-pause count for the indicator badge. Returns dict {LocationId, OpenPauseCount} or None."""
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    return BlueRidge.Common.Db.execOne("lots/LotPause_GetCountsByLocation", {"locationId": locationId})


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
