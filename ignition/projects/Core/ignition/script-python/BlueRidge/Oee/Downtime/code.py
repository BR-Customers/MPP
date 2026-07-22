"""BlueRidge.Oee.Downtime - terminal-scoped downtime CRUD wrappers (Increment 1).

   Thin wrappers over the oee/* named queries. Scope resolves a cell/terminal
   location to its downtime "unit" (line for M&A, press for die cast). The existing
   BlueRidge.Oee.DowntimeEvent module keeps Start/End/Assign (live + PLC late-bind);
   this module adds the manager reads + edits. ET datetimes are passed as
   'yyyy-MM-dd HH:mm:ss' wall-clock strings (the proc converts ET->UTC)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(v):
    return BlueRidge.Common.Util.extractQualifiedValues(v)


def _uid():
    return BlueRidge.Common.Util._currentAppUserId()


def resolveScope(cellLocationId):
    """Cell/terminal location -> downtime scope (nearest WorkCenter line, or self).
       Returns a BIGINT id or None."""
    if cellLocationId is None:
        return None
    row = BlueRidge.Common.Db.execOne("oee/ResolveDowntimeScope", {"cellLocationId": _u(cellLocationId)})
    return row.get("ScopeLocationId") if row else None


def getByScope(scopeLocationId, includeDescendants=True, shiftId=None):
    """Downtime events in scope (+descendants) for a shift (None = current open).
       Returns list[dict]."""
    return BlueRidge.Common.Db.execList("oee/DowntimeEvent_GetByScope", {
        "scopeLocationId":    _u(scopeLocationId),
        "includeDescendants": bool(includeDescendants),
        "shiftId":            _u(shiftId),
    })


def updateReason(downtimeEventId, downtimeReasonCodeId, terminalLocationId=None):
    """Change/clear a reason (allows overwrite, unlike B7 assign). {Status, Message}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_UpdateReason", {
        "downtimeEventId":      _u(downtimeEventId),
        "downtimeReasonCodeId": _u(downtimeReasonCodeId),
        "appUserId":            _uid(),
        "terminalLocationId":   _u(terminalLocationId),
    })


def updateTimes(downtimeEventId, startedAtEt, endedAtEt=None, remarks=None, terminalLocationId=None):
    """Retroactive time correction (+ optional remarks). ET wall-clock strings
       'yyyy-MM-dd HH:mm:ss'. {Status, Message}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_UpdateTimes", {
        "downtimeEventId":    _u(downtimeEventId),
        "startedAtEt":        _u(startedAtEt),
        "endedAtEt":          _u(endedAtEt),
        "remarks":            _u(remarks),
        "appUserId":          _uid(),
        "terminalLocationId": _u(terminalLocationId),
    })


def recordHistorical(scopeLocationId, startedAtEt, endedAtEt, downtimeReasonCodeId=None,
                     remarks=None, terminalLocationId=None):
    """Enter a fully-past closed event. ET wall-clock strings. {Status, Message, NewId}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_RecordHistorical", {
        "scopeLocationId":      _u(scopeLocationId),
        "startedAtEt":          _u(startedAtEt),
        "endedAtEt":            _u(endedAtEt),
        "downtimeReasonCodeId": _u(downtimeReasonCodeId),
        "remarks":              _u(remarks),
        "appUserId":            _uid(),
        "terminalLocationId":   _u(terminalLocationId),
    })


def void(downtimeEventId, voidReason=None, terminalLocationId=None):
    """Soft-void (closes if open). {Status, Message}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_Void", {
        "downtimeEventId":    _u(downtimeEventId),
        "voidReason":         _u(voidReason),
        "appUserId":          _uid(),
        "terminalLocationId": _u(terminalLocationId),
    })
