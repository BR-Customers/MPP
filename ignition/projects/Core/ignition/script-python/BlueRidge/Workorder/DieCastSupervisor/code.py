"""BlueRidge.Workorder.DieCastSupervisor - read-only access for the Die Cast
   supervisor dashboard (backlog 3.5): registered production for the CURRENT and
   PREVIOUS shift, broken down by press / die / part.

   Two procs back this module, and the split is deliberate:

     Workorder.DieCastSupervisor_GetShiftContext  - the ONLY place that decides
         which shift is 'Current' and which is 'Previous'. Per-equipment shift
         overrides (backlog 6.1) change that decision and nothing else, so they
         land in that proc alone. `cellLocationId` is already on the signature as
         the seam; it is accepted and ignored today.

     Workorder.DieCastSupervisor_GetShiftTotals   - takes an explicit shiftId and
         aggregates Workorder.DieCastContribution.PieceDelta on the stamped
         ShiftId FK, never on a time window. A changed shift WINDOW therefore
         cannot re-bucket production that was already registered.

   AUTHORITATIVE SOURCE for a die-cast shift total is
   Workorder.DieCastContribution.PieceDelta filtered on ShiftId:
     * it is the only die-cast table carrying a ShiftId FK;
     * Workorder.ProductionEvent is never written by any die-cast proc (it would
       report zero);
     * Tools.Tool.ShotCount is a cumulative lifetime counter with no shift
       attribution and no history;
     * Lots.Lot.PieceCount is a running total on the BASKET, so a basket that
       spans two shifts cannot be split by it.

   SCRAP IS NOT REPORTED HERE. Workorder.RejectEvent has no ShiftId and no
   operation discriminator, so die-cast scrap for a shift could only be guessed
   from a RecordedAt time window plus a free-text Remarks match -- both wrong
   often enough to be worse than showing nothing. Adding RejectEvent.ShiftId
   (stamped by DieCastShiftOutput_Record / DieCastLot_Release) turns this into a
   two-line addition on both sides.

   Public surface:
     getShiftContext(cellLocationId=None)                    -> list[dict]
     getShiftTotals(shiftId, areaLocationId=None)            -> list[dict]
     mapPressInstances(rows)                                 -> list[dict]
     getDashboard(areaLocationId=None, _refreshToken=None)   -> dict (never None)
     getAreaOptions(_refreshToken=None)                      -> [{label, value}]
"""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


# --- binding-safe empty shapes -------------------------------------------------
# Every view.custom.* a binding reads must be fully shaped on the EMPTY path too,
# or a nested read renders the component as a Quality-Bad Component Error. These
# are what getDashboard returns when there is no shift / no production.

_EMPTY_PANEL = {
    "slot":        "",
    "shiftId":     None,
    "scheduleName": "",
    "isOpen":      False,
    "windowEt":    "",
    "goodTotal":   0,
    "lotTotal":    0,
    "pressTotal":  0,
    "rowCount":    0,
    "rows":        [],
}

_EMPTY_DASHBOARD = {
    "current":       dict(_EMPTY_PANEL),
    "previous":      dict(_EMPTY_PANEL),
    "currentLabel":  "Current shift",
    "previousLabel": "Previous shift",
    "deltaGood":     0,
    "deltaText":     "--",
    "deltaLabel":    "no previous shift",
    "deltaTone":     "",
    "hasData":       False,
}


def _fmt(ts, pattern="MM/dd HH:mm"):
    """Timestamp -> display string. Repeater params serialize dates to strings and
       dateFormat/dateDiff misrender inside child views, so every date that ends
       up in a repeater instance is formatted HERE, in Python."""
    if ts is None:
        return ""
    try:
        return system.date.format(ts, pattern)
    except:
        return ("%s" % ts)[:16]


# --- thin proc wrappers --------------------------------------------------------

def getShiftContext(cellLocationId=None):
    """The Current + Previous shift instances (at most two rows, Current first).
       Returns list[dict]; [] when the DB holds no Oee.Shift rows at all."""
    cellLocationId = _u(cellLocationId)
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastSupervisor_GetShiftContext",
        {"cellLocationId": cellLocationId},
    )


def getShiftTotals(shiftId, areaLocationId=None):
    """Registered die-cast production for one shift, one row per press x die x
       part. Returns list[dict] ([] for an unknown/None shift, which is the
       'not found' contract -- never an error)."""
    shiftId = _u(shiftId)
    areaLocationId = _u(areaLocationId)
    if shiftId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastSupervisor_GetShiftTotals",
        {"shiftId": shiftId, "areaLocationId": areaLocationId},
    )


# --- presentation --------------------------------------------------------------

def mapPressInstances(rows):
    """Repeater instances for the dashboard's PressRow sub-view: one instance per
       DieCastSupervisor_GetShiftTotals row, camelCased and with every date
       already rendered to a string (mirrors DieCast.mapBreakdownInstances /
       Lot.mapTrimInventoryInstances). Presentation only. Returns [] on
       empty/None."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    out = []
    for r in rows:
        r = r or {}
        out.append({
            "cell":   (r.get("CellCode") or "(unassigned die)"),
            "die":    (r.get("ToolCode") or ""),
            "part":   (r.get("PartNumber") or ""),
            "descr":  (r.get("ItemDescription") or ""),
            "good":   "{:,}".format(int(r.get("GoodPieces") or 0)),
            "lots":   str(int(r.get("LotCount") or 0)),
            "last":   _fmt(r.get("LastEntryEt")),
        })
    return out


def _panel(ctxRow, areaLocationId):
    """One shift panel (header figures + mapped rows) from a context row."""
    ctxRow = ctxRow or {}
    shiftId = ctxRow.get("ShiftId")
    rows = getShiftTotals(shiftId, areaLocationId)
    first = rows[0] if rows else {}
    startEt = _fmt(ctxRow.get("ActualStartEt"))
    endEt = _fmt(ctxRow.get("ActualEndEt"))
    isOpen = bool(ctxRow.get("IsOpen"))
    if not startEt:
        window = ""
    elif isOpen:
        window = "%s - in progress" % startEt
    else:
        window = "%s - %s" % (startEt, endEt or "?")
    return {
        "slot":         ctxRow.get("Slot") or "",
        "shiftId":      shiftId,
        "scheduleName": ctxRow.get("ScheduleName") or "",
        "isOpen":       isOpen,
        "windowEt":     window,
        "goodTotal":    int(first.get("ShiftGoodTotal") or 0),
        "lotTotal":     int(first.get("ShiftLotTotal") or 0),
        "pressTotal":   int(first.get("ShiftPressTotal") or 0),
        "rowCount":     len(rows),
        "rows":         mapPressInstances(rows),
    }


def getDashboard(areaLocationId=None, _refreshToken=None):
    """The whole dashboard payload in ONE binding: {current, previous, deltaGood,
       deltaLabel, hasData}. ALWAYS returns the full shape -- never None and never
       a partial dict -- so a binding may traverse
       {view.custom.dash.current.goodTotal} on the no-shift path without a
       Quality-Bad.

       _refreshToken is ignored; it exists so the view can pass
       {view.custom.refreshToken} as a runScript ARG (runScript caches on its
       args -- a token referenced only in the if() condition never re-executes)."""
    areaLocationId = _u(areaLocationId)
    try:
        ctx = getShiftContext() or []
    except:
        BlueRidge.Common.Util.log("getDashboard: shift context read failed", level="error")
        return dict(_EMPTY_DASHBOARD)

    bySlot = {}
    for r in ctx:
        r = r or {}
        if r.get("Slot"):
            bySlot[r.get("Slot")] = r

    current = _panel(bySlot.get("Current"), areaLocationId) if bySlot.get("Current") else dict(_EMPTY_PANEL)
    previous = _panel(bySlot.get("Previous"), areaLocationId) if bySlot.get("Previous") else dict(_EMPTY_PANEL)

    delta = int(current.get("goodTotal") or 0) - int(previous.get("goodTotal") or 0)
    # The delta is only meaningful once there IS a previous shift to compare to --
    # otherwise the tile would read "+6,450" against nothing. Both the number and
    # its caption are rendered here rather than in expression bindings so the
    # no-previous-shift case cannot leak a misleading figure onto the screen.
    if previous.get("shiftId") is None:
        deltaText, deltaLabel, deltaTone = "--", "no previous shift", ""
    elif delta > 0:
        deltaText, deltaLabel, deltaTone = "+{:,}".format(delta), "vs previous shift", "pf-kpi-value-good"
    elif delta < 0:
        deltaText, deltaLabel, deltaTone = "{:,}".format(delta), "vs previous shift", "pf-kpi-value-warn"
    else:
        deltaText, deltaLabel, deltaTone = "0", "level with previous shift", ""

    def _tileLabel(prefix, panel):
        name = panel.get("scheduleName") or ""
        return ("%s - %s" % (prefix, name)) if name else prefix

    return {
        "current":       current,
        "previous":      previous,
        "currentLabel":  _tileLabel("Current shift", current),
        "previousLabel": _tileLabel("Previous shift", previous),
        "deltaGood":     delta,
        "deltaText":     deltaText,
        "deltaLabel":    deltaLabel,
        "deltaTone":     deltaTone,
        "hasData":       bool(current.get("shiftId") or previous.get("shiftId")),
    }


def getAreaOptions(_refreshToken=None):
    """[{label, value}] for the Area filter: 'All Die Cast' (value None) plus every
       Area-tier Location whose Code starts 'DC' (MPP runs four -- DC1..DC4).
       Dev seed check 2026-08-19: Die Cast 1..4 sit directly under the Madison
       facility, so an Area-tier listing is the right source.

       Kept deliberately simple; if MPP ever renames the areas this should move to
       an explicit Area attribute rather than a Code prefix."""
    try:
        areas = BlueRidge.Location.Location.listByTier("Area") or []
    except:
        areas = []
    out = [{"label": "All Die Cast", "value": None}]
    for a in areas:
        a = a or {}
        code = a.get("Code") or ""
        if code.upper().startswith("DC"):
            out.append({"label": "%s - %s" % (code, a.get("Name") or ""), "value": a.get("Id")})
    return out
