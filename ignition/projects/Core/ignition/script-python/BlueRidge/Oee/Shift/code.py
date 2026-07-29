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


def listRecent(shiftScheduleId=None, fromDate=None, toDate=None):
    """Recent shift instances (newest-first): Id, ScheduleName, ActualStart, ...
       All filters optional; no args = all shifts. Used by the Downtime Manager
       shift selector. Returns list[dict]."""
    return BlueRidge.Common.Db.execList("oee/Shift_List", {
        "shiftScheduleId": shiftScheduleId,
        "fromDate":        fromDate,
        "toDate":          toDate,
    })


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


# Binding-safe empty shape for getOpenOrEmpty (matches the Shift_GetOpen columns).
_EMPTY_SHIFT = {"Id": None, "ShiftScheduleId": None, "ScheduleName": "",
                "ActualStart": None, "ActualEnd": None, "Remarks": "", "CreatedAt": None}


def getOpenOrEmpty():
    """getOpen() that NEVER returns None -- always a fully-shaped dict -- so a view
       binding can traverse {custom.shift.Id} without a Quality-Bad on the no-open-
       shift path (EndOfShiftEntry's ShiftStatus label). Callers detect 'no open
       shift' via Id IS NULL, not isNull() on the whole object. Mirrors the
       RouteTemplate.getHeaderOrEmpty convention."""
    row = getOpen()
    return row if row else dict(_EMPTY_SHIFT)


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


def getRecentOptions(limitRows=20):
    """[{label, value}] for the die-cast shift-output entry's shift picker
       (Die-Cast Per-Cavity Lifecycle, Task 12): the most recent shift
       instances, newest first, label 'ScheduleName  MM/dd HH:mm-HH:mm' (or
       '-open' for the still-open shift). Display only -- ActualStart/End are
       shown as stored (UTC per Shift_List; not converted to ET here), same
       precision-only-no-TZ-conversion pattern already used by the arrival/
       history display helpers elsewhere in this module (mapTrimInventoryInstances
       et al) -- a full ET conversion sweep is tracked separately as OI-36."""
    rows = listRecent() or []
    out = []
    n = 0
    for r in rows:
        r = r or {}
        n += 1
        if n > limitRows:
            break
        start = r.get("ActualStart")
        end = r.get("ActualEnd")
        try:
            startTxt = system.date.format(start, "MM/dd HH:mm") if start is not None else "?"
        except:
            startTxt = ("%s" % start)[:16]
        if end is not None:
            try:
                endTxt = system.date.format(end, "HH:mm")
            except:
                endTxt = ("%s" % end)[:16]
        else:
            endTxt = "open"
        label = "%s  %s-%s" % (r.get("ScheduleName") or "Shift", startTxt, endTxt)
        out.append({"label": label, "value": r.get("Id")})
    return out


def defaultEntryShiftId():
    """Default shift for the die-cast shift-output entry screen (Task 12).

       SIMPLIFIED vs spec Sec 3.3: returns the currently open shift if one
       exists, else the most recently ended shift. Does NOT implement the
       'entry within the first hour of the new shift's ActualStart -> default
       to the just-ended (previous) shift' smart-default rule -- that needs a
       clock-vs-ActualStart comparison that's easy to get subtly wrong blind
       (shift-length assumptions, DST). Flagged as a documented follow-up for
       Jacques to refine; the operator can always override the shift picker,
       so this is a UX nicety, not a data-integrity gap."""
    open_ = getOpen()
    if open_ and open_.get("Id") is not None:
        return open_.get("Id")
    rows = listRecent() or []
    for r in rows:
        if r.get("Id") is not None:
            return r.get("Id")
    return None


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
