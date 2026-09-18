"""BlueRidge.Oee.Downtime - terminal-scoped downtime CRUD wrappers (Increment 1).

   Thin wrappers over the oee/* named queries. Scope resolves a cell/terminal
   location to its downtime "unit" (line for M&A, press for die cast). The existing
   BlueRidge.Oee.DowntimeEvent module keeps Start/End/Assign (live + PLC late-bind);
   this module adds the manager reads + edits. ET datetimes are passed as
   'yyyy-MM-dd HH:mm:ss' wall-clock strings (the proc converts ET->UTC).

   Change Log:
       2026-09-09 - Add listScopesForTerminal / getScopeOptionsForTerminal /
                    getDefaultScopeForTerminal / getDefaultScopeIdForTerminal
                    over oee/DowntimeScope_ListForTerminal. resolveScope stays
                    for callers that already hold a cell; the new pair is what a
                    screen with NO cell context (trim) and a shared terminal
                    serving many machines (die cast) must use.
       2026-09-17 - Add getScopeForPick: honours an operator's deliberate PICK
                    of a line in the Downtime Manager, distinct from the
                    DEFAULT rule (which refuses to preselect a split line).
                    resolveScope/getDefaultScopeIdForTerminal docstrings
                    corrected -- IsOeeEnabled locations, not "WorkCenter
                    line"/AppHeader-specific."""


def _u(v):
    return BlueRidge.Common.Util.extractQualifiedValues(v)


def resolveScope(cellLocationId):
    """Cell/terminal location -> downtime scope (nearest OEE-enabled location,
       Location.IsOeeEnabled, at or above the cell; else the cell itself).
       Returns a BIGINT id or None."""
    if cellLocationId is None:
        return None
    row = BlueRidge.Common.Db.execOne("oee/ResolveDowntimeScope", {"cellLocationId": _u(cellLocationId)})
    return row.get("ScopeLocationId") if row else None


_EMPTY_SCOPE = {"ScopeLocationId": None, "Code": "", "Name": "", "Kind": "", "IsDefault": False}


def listScopesForTerminal(terminalLocationId, activeCellLocationId=None):
    """The downtime units an operator at this terminal may log against
       (Oee.DowntimeScope_ListForTerminal). Die cast -> one row per press in the
       area; trim -> the trim shop; M&A -> the line; fallback terminal -> [].
       `activeCellLocationId` (session.custom.cell.locationId) only decides
       which row comes back IsDefault=1. Returns list[dict]; always a list, so a
       runScript-bound view.custom default of [] is never overwritten with null.

       The scoping rule itself lives entirely in the proc -- do NOT branch on
       process/screen here."""
    if _u(terminalLocationId) is None:
        return []
    return BlueRidge.Common.Db.execList("oee/DowntimeScope_ListForTerminal", {
        "terminalLocationId":   _u(terminalLocationId),
        "activeCellLocationId": _u(activeCellLocationId),
    })


def getScopeOptionsForTerminal(terminalLocationId, activeCellLocationId=None):
    """listScopesForTerminal shaped for ia.input.dropdown:
       [{label: '<Code> - <Name>', value: ScopeLocationId}]. Always a list."""
    out = []
    for r in (listScopesForTerminal(terminalLocationId, activeCellLocationId) or []):
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        out.append({"label": ("%s - %s" % (code, name)).strip(" -"),
                    "value": r.get("ScopeLocationId")})
    return out


def getDefaultScopeForTerminal(terminalLocationId, activeCellLocationId=None):
    """The single scope row the proc flagged IsDefault, as a FULLY SHAPED dict
       (never None / {}) so a binding that traverses .Name / .ScopeLocationId
       cannot go Quality-Bad. ScopeLocationId is None when there is no default:
       a fallback terminal (no scopes at all) or a shared die cast terminal
       where the operator has not picked a press yet -- guessing one would file
       downtime against the wrong machine."""
    for r in (listScopesForTerminal(terminalLocationId, activeCellLocationId) or []):
        if r.get("IsDefault"):
            d = dict(_EMPTY_SCOPE)
            d.update(r)
            return d
    return dict(_EMPTY_SCOPE)


def getScopeForPick(terminalLocationId, pickedLocationId):
    """The scope row for a location the operator PICKED in the Downtime Manager,
       as a FULLY SHAPED dict (never None / {}). The pick is honoured only if it
       is one of the units this terminal may log against
       (Oee.DowntimeScope_ListForTerminal); anything else returns the empty
       shape (ScopeLocationId None).

       Distinct from getDefaultScopeForTerminal on purpose: the DEFAULT rule
       refuses to preselect a line that has station units under it (so a
       one-side jam is not silently charged to the whole line), but an operator
       who deliberately picks that line must get it.

       ScopeLocationId comes back from the NQ as a Java Long/BIGINT and
       pickedLocationId may arrive as a Long or a plain int (dropdown
       props.value) -- Jython's == across those is not reliable, so both
       sides are compared as long()."""
    picked = _u(pickedLocationId)
    if picked is None:
        return dict(_EMPTY_SCOPE)
    pickedLong = long(picked)
    for r in (listScopesForTerminal(terminalLocationId) or []):
        rowId = r.get("ScopeLocationId")
        if rowId is not None and long(rowId) == pickedLong:
            d = dict(_EMPTY_SCOPE)
            d.update(r)
            return d
    return dict(_EMPTY_SCOPE)


def getDefaultScopeIdForTerminal(terminalLocationId, activeCellLocationId=None):
    """Scalar form of getDefaultScopeForTerminal for a plain id binding.
       BIGINT id or None."""
    return getDefaultScopeForTerminal(terminalLocationId, activeCellLocationId).get("ScopeLocationId")


def getByScope(scopeLocationId, includeDescendants=True, shiftId=None):
    """Downtime events in scope (+descendants) for a shift (None = current open).
       Returns list[dict]."""
    return BlueRidge.Common.Db.execList("oee/DowntimeEvent_GetByScope", {
        "scopeLocationId":    _u(scopeLocationId),
        "includeDescendants": bool(includeDescendants),
        "shiftId":            _u(shiftId),
    })


def updateReason(downtimeEventId, downtimeReasonCodeId, terminalLocationId=None, appUserId=None):
    """Change/clear a reason (allows overwrite, unlike B7 assign). {Status, Message}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_UpdateReason", {
        "downtimeEventId":      _u(downtimeEventId),
        "downtimeReasonCodeId": _u(downtimeReasonCodeId),
        "appUserId":            BlueRidge.Common.Util.requireAppUserId(appUserId),
        "terminalLocationId":   _u(terminalLocationId),
    })


def updateTimes(downtimeEventId, startedAtEt, endedAtEt=None, remarks=None, terminalLocationId=None, appUserId=None):
    """Retroactive time correction (+ optional remarks). ET wall-clock strings
       'yyyy-MM-dd HH:mm:ss'. {Status, Message}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_UpdateTimes", {
        "downtimeEventId":    _u(downtimeEventId),
        "startedAtEt":        _u(startedAtEt),
        "endedAtEt":          _u(endedAtEt),
        "remarks":            _u(remarks),
        "appUserId":          BlueRidge.Common.Util.requireAppUserId(appUserId),
        "terminalLocationId": _u(terminalLocationId),
    })


def recordHistorical(scopeLocationId, startedAtEt, endedAtEt, downtimeReasonCodeId=None,
                     remarks=None, terminalLocationId=None, appUserId=None):
    """Enter a fully-past closed event. ET wall-clock strings. {Status, Message, NewId}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_RecordHistorical", {
        "scopeLocationId":      _u(scopeLocationId),
        "startedAtEt":          _u(startedAtEt),
        "endedAtEt":            _u(endedAtEt),
        "downtimeReasonCodeId": _u(downtimeReasonCodeId),
        "remarks":              _u(remarks),
        "appUserId":            BlueRidge.Common.Util.requireAppUserId(appUserId),
        "terminalLocationId":   _u(terminalLocationId),
    })


def recordApproximate(scopeLocationId, durationMinutes, shiftId=None, downtimeReasonCodeId=None,
                      remarks=None, terminalLocationId=None, appUserId=None):
    """Enter a duration-only ('approximate') past event -- operator knows the
       duration but not the exact window. shiftId None -> current open shift.
       {Status, Message, NewId}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_RecordApproximate", {
        "scopeLocationId":      _u(scopeLocationId),
        "durationMinutes":      _u(durationMinutes),
        "shiftId":              _u(shiftId),
        "downtimeReasonCodeId": _u(downtimeReasonCodeId),
        "remarks":              _u(remarks),
        "appUserId":            BlueRidge.Common.Util.requireAppUserId(appUserId),
        "terminalLocationId":   _u(terminalLocationId),
    })


def void(downtimeEventId, voidReason=None, terminalLocationId=None, appUserId=None):
    """Soft-void (closes if open). {Status, Message}."""
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_Void", {
        "downtimeEventId":    _u(downtimeEventId),
        "voidReason":         _u(voidReason),
        "appUserId":          BlueRidge.Common.Util.requireAppUserId(appUserId),
        "terminalLocationId": _u(terminalLocationId),
    })
