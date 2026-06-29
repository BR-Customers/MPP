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
    BlueRidge.Common.Util.log("atMoment=%s" % atMoment, level="debug")
    return BlueRidge.Common.Db.execOne(
        "oee/Shift_GetActive",
        {"atMoment": atMoment},
    )


def getOpen():
    """Return the single currently-open shift instance, or None."""
    BlueRidge.Common.Util.log("getting open shift", level="debug")
    return BlueRidge.Common.Db.execOne("oee/Shift_GetOpen")


def acknowledgeHandover(shiftId, cellLocationId=None, appUserId=None, terminalLocationId=None):
    """Record that the operator reviewed the shift-end summary (FDS-09-015).
       Audit-only; the shift-time data is already committed. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("shiftId=%s cellLocationId=%s" % (shiftId, cellLocationId))
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "shiftId":            shiftId,
        "cellLocationId":     cellLocationId,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("oee/ShiftHandover_Acknowledge", params)


def tickShiftBoundary(nowUtc=None):
    """Called every 60s by the ShiftBoundaryTicker gateway timer.

       Singleton shift model: at most one active schedule + one open shift.
       - active schedule = getActive(nowUtc)  (active.Id IS the ShiftScheduleId)
       - open shift      = getOpen()
       Starts/ends shifts on boundary crossings. No auto-carryover of open
       downtime/pause events (UJ-10) - the procs own that. Returns a small
       dict describing what it did (for logging/testing). The body is fully
       guarded; a gateway timer must never throw uncaught."""
    BlueRidge.Common.Util.log("tick nowUtc=%s" % nowUtc, level="debug")
    try:
        active = getActive(nowUtc)      # dict|None; active.Id is the ShiftScheduleId
        openShift = getOpen()           # dict|None
        if active is None:
            # No schedule active right now (gap between shifts). Do nothing -
            # leave any open shift open; boundary handling happens when the
            # next schedule becomes active. Phase 1: no gap auto-close.
            return {"action": "none", "reason": "no active schedule"}
        activeScheduleId = active.get("Id")
        if openShift is None:
            return {"action": "start",
                    "result": start(activeScheduleId, actualStart=nowUtc)}
        if openShift.get("ShiftScheduleId") != activeScheduleId:
            endResult = end(actualEnd=nowUtc)
            startResult = start(activeScheduleId, actualStart=nowUtc)
            return {"action": "boundary", "end": endResult, "start": startResult}
        return {"action": "none", "reason": "open shift matches active schedule"}
    except Exception as e:
        BlueRidge.Common.Util.log("tickShiftBoundary error: %s" % e, level="error")
        return {"action": "error", "error": str(e)}
