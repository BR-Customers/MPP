"""BlueRidge.Oee.Shift - thin access to shift start/end + active/open lookups.

   Wrappers only; no business logic. Mutation attribution defaults appUserId to
   the session-resolved current user when the caller passes None; the plant
   floor passes appUserId / terminalLocationId explicitly."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def start(shiftScheduleId, actualStart=None, remarks=None, appUserId=None,
          terminalLocationId=None):
    """Open a shift instance for the given schedule.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "shiftScheduleId=%s actualStart=%s appUserId=%s terminalLocationId=%s"
        % (shiftScheduleId, actualStart, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "shiftScheduleId":    shiftScheduleId,
        "actualStart":        actualStart,
        "remarks":            remarks,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("oee/Shift_Start", params)


def end(actualEnd=None, remarks=None, appUserId=None, terminalLocationId=None):
    """Close the single currently-open shift. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "actualEnd=%s appUserId=%s terminalLocationId=%s"
        % (actualEnd, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "actualEnd":          actualEnd,
        "remarks":            remarks,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("oee/Shift_End", params)


def getActive(atMoment=None):
    """Resolve the active shift schedule at a moment (default: now).
       Returns a dict or None."""
    BlueRidge.Common.Util.log("atMoment=%s" % atMoment)
    return BlueRidge.Common.Db.execOne(
        "oee/Shift_GetActive",
        {"atMoment": atMoment},
    )


def getOpen():
    """Return the single currently-open shift instance, or None."""
    BlueRidge.Common.Util.log("getting open shift")
    return BlueRidge.Common.Db.execOne("oee/Shift_GetOpen")
