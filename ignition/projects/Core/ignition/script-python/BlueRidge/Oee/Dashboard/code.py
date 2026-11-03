"""BlueRidge.Oee.Dashboard - reads for the OEE dashboard pages
   (/shop-floor/oee, /shop-floor/oee/area/:areaKey, /shop-floor/oee/unit/:locationId).
   OEE dashboard spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
   v0.3.2 sec 5, 8.

   Thin: each function calls one named query and returns its rows. No
   arithmetic, no thresholds, no bands -- all of that is SQL (the bands come
   back from Oee.ufn_OeeBand). Never None and never raises: a list function
   returns [] and period() returns the fully-shaped _EMPTY_PERIOD, so a
   binding that reads a nested key cannot go Quality-Bad (CLAUDE.md
   "Pre-declare every binding-referenced custom property").

   zoom       'Shift' | 'Day' | 'Week'
   areaFamily 'diecast' | 'trim' | 'ma' | None
   groupBy    'Defect' | 'Part' | 'Line'"""
import java.lang

_EMPTY_PERIOD = {
    "AnchorShiftId":    None,
    "Zoom":             "",
    "PeriodLabel":      "",
    "IsInProgress":     False,
    "HasNext":          False,
    "IsRecentlyClosed": False,
}


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _list(fn, nq, params):
    try:
        return BlueRidge.Common.Db.execList(nq, params) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("%s failed: %s" % (fn, e), level="warn")
        return []


def period(zoom, anchorShiftId=None, step=0):
    """The period header: anchor shift, label, in-progress / next / recently-closed flags."""
    rows = _list("period", "oee/Dashboard_GetPeriod", {
        "zoom": _u(zoom), "anchorShiftId": _u(anchorShiftId), "step": _u(step) or 0})
    if not rows:
        return dict(_EMPTY_PERIOD)
    out = dict(_EMPTY_PERIOD)
    out.update(rows[0])
    return out


def unitSummary(zoom, anchorShiftId, areaFamily=None, readLive=False):
    """Unit / Station / Group / Area / Plant rows for the period, pooled.
    readLive: at Shift zoom compute the anchor shift live even when it is stored
    (the unit drill-down, so an edit shows before the next refresh)."""
    return _list("unitSummary", "oee/Dashboard_GetUnitSummary", {
        "zoom": _u(zoom), "anchorShiftId": _u(anchorShiftId), "areaFamily": _u(areaFamily),
        "readLive": bool(_u(readLive))})


def trend(anchorShiftId, areaFamily=None, locationId=None):
    """Seven production days ending at the anchor's, oldest first."""
    return _list("trend", "oee/Dashboard_GetTrend", {
        "anchorShiftId": _u(anchorShiftId), "areaFamily": _u(areaFamily), "locationId": _u(locationId)})


def breakdown(zoom, anchorShiftId, locationId=None):
    """Day -> one row per shift; Week -> seven day rows; Shift -> []."""
    return _list("breakdown", "oee/Dashboard_GetBreakdown", {
        "zoom": _u(zoom), "anchorShiftId": _u(anchorShiftId), "locationId": _u(locationId)})


def downtimeByReason(zoom, anchorShiftId, areaFamily=None, locationId=None):
    """Downtime by reason, Pareto order; no-reason entries as one IsNoReason row."""
    return _list("downtimeByReason", "oee/Dashboard_GetDowntimeByReason", {
        "zoom": _u(zoom), "anchorShiftId": _u(anchorShiftId),
        "areaFamily": _u(areaFamily), "locationId": _u(locationId)})


def scrap(zoom, anchorShiftId, areaFamily=None, locationId=None, groupBy="Defect"):
    """Scrap by defect / part / line, charged by defect code."""
    return _list("scrap", "oee/Dashboard_GetScrap", {
        "zoom": _u(zoom), "anchorShiftId": _u(anchorShiftId), "areaFamily": _u(areaFamily),
        "locationId": _u(locationId), "groupBy": _u(groupBy) or "Defect"})


def downtimeEntries(anchorShiftId, locationId):
    """One shift's downtime entries at a location and its stations."""
    return _list("downtimeEntries", "oee/Dashboard_GetDowntimeEntries", {
        "anchorShiftId": _u(anchorShiftId), "locationId": _u(locationId)})


# ---------------------------------------------------------------------------
# View shaping for the dashboard pages. Formatting and picking rows for
# display only: every ratio, band and count comes from the reads above, so
# nothing here decides what a number is. Each returns a fully-shaped value
# (never None) so a bound view.custom / repeater cannot go Quality-Bad. The
# trailing _refreshToken lets a view force a re-read by bumping a counter.
# ---------------------------------------------------------------------------

_DOT = u" · "

_FAMILIES = [("diecast", "Die Cast"), ("trim", "Trim"), ("ma", "Machining & Assembly")]

_EMPTY_AREA_CARD = {
    "family": "", "title": "", "subtitle": "", "hasData": False,
    "availability": None, "availabilityBand": None,
    "quality": None, "qualityBand": None,
    "downMinutes": "0 min", "noReasonCount": 0, "noReasonText": "0 no reason",
    "scrap": 0, "foundDownstreamText": "",
}


def _f(v):
    try:
        return None if v is None else float(v)
    except (Exception, java.lang.Exception):
        return None


def _i(v):
    f = _f(v)
    return 0 if f is None else int(round(f))


def pct(ratio, decimals=0):
    """'84%' / '96.4%' for a 0-1 ratio; '--' for None."""
    r = _f(_u(ratio))
    if r is None:
        return "--"
    return ("%." + str(int(decimals)) + "f%%") % (r * 100.0)


def _count(v):
    return "{:,}".format(_i(v))


def _scopeRow(rows, areaFamily=None):
    """The Plant row, or the Area row of one family."""
    for r in rows:
        if areaFamily is None and r.get("RowKind") == "Plant":
            return r
        if areaFamily is not None and r.get("RowKind") == "Area" and r.get("AreaFamily") == areaFamily:
            return r
    return {}


def familyTitle(areaFamily):
    """'Die Cast' / 'Trim' / 'Machining & Assembly'; '' for an unknown key."""
    for k, t in _FAMILIES:
        if k == _u(areaFamily):
            return t
    return ""


def kpiInstances(zoom, anchorShiftId, areaFamily=None, _refreshToken=None):
    """The three live KPI cards (availability, quality, no-reason) for the plant or one area."""
    fam = _u(areaFamily) or None
    row = _scopeRow(unitSummary(zoom, anchorShiftId, fam), fam)
    prefix = "Plant " if fam is None else ""
    nr = _i(row.get("NoReasonCount"))
    return [
        {"title": prefix + "availability", "value": pct(row.get("Availability"), 0),
         "band": row.get("AvailabilityBand"), "tone": "",
         "sub": "%s min unplanned downtime" % _count(row.get("UnplannedDowntimeMinutes"))},
        {"title": prefix + "quality", "value": pct(row.get("Quality"), 1),
         "band": row.get("QualityBand"), "tone": "",
         "sub": "%s good%s%s scrap" % (_count(row.get("Good")), _DOT, _count(row.get("Scrap")))},
        {"title": "Downtime with no reason", "value": str(nr), "band": None,
         "tone": "warn" if nr > 0 else "",
         "sub": "entries%s%s min" % (_DOT, _count(row.get("NoReasonMinutes")))},
    ]


def areaCard(zoom, anchorShiftId, areaFamily, _refreshToken=None):
    """One site-page area card: gauges, downtime, no-reason, scrap."""
    fam = _u(areaFamily)
    out = dict(_EMPTY_AREA_CARD)
    out["family"] = fam or ""
    out["title"] = familyTitle(fam)
    rows = unitSummary(zoom, anchorShiftId, fam)
    row = _scopeRow(rows, fam)
    units = len([r for r in rows if r.get("RowKind") == "Unit" and r.get("AreaFamily") == fam])
    groups = len([r for r in rows if r.get("RowKind") == "Group" and r.get("AreaFamily") == fam])
    noun = {"diecast": "presses", "trim": "trim presses", "ma": "lines"}.get(fam, "units")
    out["subtitle"] = "%d %s" % (units, noun) + ((_DOT + "%d shops" % groups) if fam == "trim" else "")
    if not row:
        return out
    nr = _i(row.get("NoReasonCount"))
    fd = _i(row.get("FoundDownstreamScrap"))
    out.update({
        "hasData": bool(row.get("HasProduction")),
        "availability": _f(row.get("Availability")), "availabilityBand": row.get("AvailabilityBand"),
        "quality": _f(row.get("Quality")), "qualityBand": row.get("QualityBand"),
        "downMinutes": "%s min" % _count(row.get("DowntimeMinutes")),
        "noReasonCount": nr, "noReasonText": "%d no reason" % nr,
        "scrap": _i(row.get("Scrap")),
        "foundDownstreamText": ("incl. %s found downstream" % _count(fd)) if fd else "",
    })
    return out


def _topUnplannedReason(zoom, anchorShiftId, locationId):
    for r in downtimeByReason(zoom, anchorShiftId, None, locationId):
        if r.get("IsNoReason"):
            return "(no reason)"
        if not r.get("IsPlanned"):
            return r.get("ReasonDescription") or r.get("ReasonCode") or ""
    return ""


def worstUnits(zoom, anchorShiftId, areaFamily, _refreshToken=None):
    """The three lowest-availability units of an area that ran, each with its largest unplanned reason."""
    fam = _u(areaFamily)
    units = [r for r in unitSummary(zoom, anchorShiftId, fam)
             if r.get("RowKind") == "Unit" and r.get("AreaFamily") == fam
             and r.get("HasProduction") and _f(r.get("Availability")) is not None]
    units.sort(key=lambda r: (_f(r.get("Availability")), r.get("LocationName") or ""))
    out = []
    for r in units[:3]:
        out.append({
            "locationId": r.get("LocationId"),
            "name": r.get("LocationName") or "",
            "value": pct(r.get("Availability"), 0),
            "band": r.get("AvailabilityBand"),
            "reason": _topUnplannedReason(zoom, anchorShiftId, r.get("LocationId")),
        })
    return out


def trendInstances(anchorShiftId, areaFamily=None, locationId=None, _refreshToken=None):
    """Seven availability bars, oldest first; always seven (missing days are empty bars)."""
    rows = trend(anchorShiftId, _u(areaFamily) or None, _u(locationId) or None)
    out = []
    for i, r in enumerate(rows[-7:]):
        a = _f(r.get("Availability"))
        label = r.get("DayLabel") or ""
        out.append({
            "label": label.split(" ")[0],
            "heightPct": 0 if a is None else max(2, int(round(a * 100))),
            "band": r.get("AvailabilityBand"),
            "isLast": i == len(rows[-7:]) - 1,
            "tooltip": "%s: %s" % (label, pct(a, 0)),
        })
    while len(out) < 7:
        out.insert(0, {"label": "", "heightPct": 0, "band": None, "isLast": False, "tooltip": ""})
    return out


def periodNote(isInProgress, isRecentlyClosed):
    """The period header's right-hand note."""
    if _u(isInProgress):
        return "In progress -- downtime not yet entered"
    if _u(isRecentlyClosed):
        return "Shift just closed -- entries may still be arriving"
    return ""


def go(session, zoom, anchorShiftId, step=0):
    """Point the session's OEE period at (zoom, anchor) moved by step; a step past the end is ignored."""
    p = period(zoom, anchorShiftId, step)
    if p.get("AnchorShiftId") is None:
        return
    session.custom.oeePeriod = {"zoom": p.get("Zoom") or _u(zoom), "anchorShiftId": p.get("AnchorShiftId")}


def reset(session):
    """Open the dashboard on the last completed shift (the site page's default, spec 5.1)."""
    session.custom.oeePeriod = {"zoom": "Shift", "anchorShiftId": None}


# ---- Area page (/shop-floor/oee/area/:areaKey) ----------------------------

_TILE_W = "23%"       # four tiles to a row, so a group's height is known
_TILE_ROW_H = 20      # one tile line
_TILE_HEAD_H = 74     # tile name + big number + padding


def _id(v):
    v = _u(v)
    try:
        return None if v in (None, "") else long(str(v))
    except (Exception, java.lang.Exception):
        return None


def _tileRows(r, fam, stations):
    """The lines under a tile's big number: (label, value, band, indent)."""
    if not r.get("HasProduction"):
        return [("No production", "", None, False)]
    rows = []
    if fam != "trim":
        rows.append(("Quality", pct(r.get("Quality"), 1), r.get("QualityBand"), False))
    if fam == "ma":
        rows.append(("Good / scrap", "%s / %s" % (_count(r.get("Good")), _count(r.get("Scrap"))), None, False))
    else:
        rows.append(("Down", "%s min" % _count(r.get("DowntimeMinutes")), None, False))
    if fam == "diecast" and r.get("LastToolCode"):
        rows.append(("Die", r.get("LastToolCode"), None, False))
    for st in stations:
        rows.append((st.get("LocationName") or "", pct(st.get("Availability"), 0), st.get("AvailabilityBand"), True))
    return rows


def _tile(r, fam, stations):
    rows = _tileRows(r, fam, stations)
    return {
        "locationId": r.get("LocationId"),
        "name": r.get("LocationName") or "",
        "value": pct(r.get("Availability"), 0) if r.get("HasProduction") else "--",
        "band": r.get("AvailabilityBand") if r.get("HasProduction") else None,
        "dim": not r.get("HasProduction"),
        "noReason": _i(r.get("NoReasonCount")) > 0,
        "rowsJson": system.util.jsonEncode([{"label": a, "value": b, "band": c, "indent": d} for a, b, c, d in rows]),
        "rowCount": len(rows),
    }


def areaGroups(zoom, anchorShiftId, areaKey, _refreshToken=None):
    """One instance per ProductionArea of the family that has units: header figures plus
    its tiles (as JSON for the group's own repeater) and, for a trim shop, its id for
    the shop-scrap-by-part table. instancePosition carries the group's height."""
    fam = _u(areaKey)
    if not familyTitle(fam):
        return []
    rows = unitSummary(zoom, anchorShiftId, fam)
    out = []
    for g in [r for r in rows if r.get("RowKind") == "Group" and r.get("AreaFamily") == fam]:
        gid = g.get("ProductionAreaId")
        units = [r for r in rows if r.get("RowKind") == "Unit" and r.get("ProductionAreaId") == gid]
        if not units:
            continue
        tiles = []
        for u in units:
            st = [r for r in rows if r.get("RowKind") == "Station" and r.get("ParentLocationId") == u.get("LocationId")]
            tiles.append(_tile(u, fam, st))
        tileH = _TILE_HEAD_H + _TILE_ROW_H * max([t["rowCount"] for t in tiles])
        tileRowsN = (len(tiles) + 3) // 4
        q = ("Shop quality " if fam == "trim" else "Quality ") + pct(g.get("Quality"), 1)
        h = 44 + tileRowsN * (tileH + 10)
        if fam == "trim":
            h += 44 + 36 * (1 + max(1, len(scrap(zoom, anchorShiftId, None, gid, "Part"))))
        out.append({
            "groupId": gid, "name": g.get("ProductionAreaName") or "", "family": fam,
            "zoom": _u(zoom), "anchorShiftId": _u(anchorShiftId),
            "summary": "Avail %s%s%s" % (pct(g.get("Availability"), 0), _DOT, q),
            "tilesJson": system.util.jsonEncode([dict(t, tileH=tileH) for t in tiles]),
            "instancePosition": {"basis": "%dpx" % h, "shrink": 0},
        })
    return out


def tileInstances(tilesJson):
    """Flex-repeater instances from an AreaGroup's tiles (JSON, since a list cannot pass runScript)."""
    try:
        tiles = system.util.jsonDecode(_u(tilesJson) or "[]") or []
    except (Exception, java.lang.Exception):
        return []
    for t in tiles:
        t["instancePosition"] = {"basis": _TILE_W, "shrink": 0, "grow": 0}
        t["instanceStyle"] = {"height": "%dpx" % int(t.get("tileH") or 100), "marginBottom": "10px"}
    return tiles


def rowInstances(rowsJson):
    """A tile's lines, from JSON."""
    try:
        return system.util.jsonDecode(_u(rowsJson) or "[]") or []
    except (Exception, java.lang.Exception):
        return []


# ---- Panels: Pareto, scrap tables, breakdown --------------------------------

def _kind(r):
    return "noreason" if r.get("IsNoReason") else ("planned" if r.get("IsPlanned") else "unplanned")


def paretoInstances(zoom, anchorShiftId, areaFamily=None, locationId=None, mode="reason", _refreshToken=None):
    """Downtime by reason (or by reason type) as bars: unplanned, planned, no-reason.
    'type' only re-groups the reason rows SQL returned."""
    rows = downtimeByReason(zoom, anchorShiftId, _u(areaFamily) or None, _id(locationId))
    items = []
    if _u(mode) == "type":
        acc = {}
        order = []
        for r in rows:
            kind = _kind(r)
            label = "Downtime with no reason" if kind == "noreason" else (r.get("ReasonTypeName") or "(no type)")
            key = (label, kind)
            if key not in acc:
                acc[key] = 0.0
                order.append(key)
            acc[key] += _f(r.get("Minutes")) or 0.0
        items = [(k[0], acc[k], k[1]) for k in order]
        items.sort(key=lambda x: -x[1])
    else:
        for r in rows:
            kind = _kind(r)
            label = r.get("ReasonDescription") or r.get("ReasonCode") or ""
            if kind == "planned":
                label += " (planned)"
            items.append((label, _f(r.get("Minutes")) or 0.0, kind))
    top = max([m for _, m, _ in items] or [0])
    return [{"label": l, "minutes": _count(m), "kind": k,
             "widthPct": 0 if not top else max(2, int(round(100.0 * m / top)))} for l, m, k in items]


_COL = {
    "align": "center", "boolean": "checkbox", "dateFormat": "MM/DD/YYYY", "editable": False, "field": "",
    "filter": {"boolean": {"condition": ""}, "date": {"condition": "", "value": ""}, "enabled": False,
               "number": {"condition": "", "value": ""}, "string": {"condition": "", "value": ""}, "visible": "on-hover"},
    "footer": {"align": "center", "justify": "left", "style": {"classes": ""}, "title": ""},
    "header": {"align": "center", "justify": "left", "style": {"classes": ""}, "title": ""},
    "justify": "auto", "nullFormat": {"includeNullStrings": False, "nullFormatValue": "", "strict": False},
    "number": "value", "numberFormat": "0,0.##",
    "progressBar": {"bar": {"color": "", "style": {"classes": ""}}, "max": 100, "min": 0,
                    "track": {"color": "", "style": {"classes": ""}},
                    "value": {"enabled": True, "format": "0,0.##", "justify": "center", "style": {"classes": ""}}},
    "render": "auto", "resizable": True, "sort": "none", "sortable": False, "strictWidth": False,
    "style": {"classes": ""}, "toggleSwitch": {"color": {"selected": "", "unselected": ""}},
    "viewParams": {}, "viewPath": "", "visible": True, "width": "",
}

_TABLES = {
    "Defect":    [("c1", "Defect", ""), ("c2", "Part", 120), ("c3", "Qty", 72), ("c4", "Note", "")],
    "Line":      [("c1", "Line", ""), ("c2", "Top defect", ""), ("c3", "Qty", 72)],
    "Part":      [("c1", "Part", ""), ("c2", "Top defect", ""), ("c3", "Good", 70), ("c4", "Scrap", 72), ("c5", "Quality", 70)],
    "Breakdown": [("c1", "Period", ""), ("c2", "Availability", 100), ("c3", "Quality", 90),
                  ("c4", "Downtime", 90), ("c5", "Good", 80), ("c6", "Scrap", 70),
                  ("childZoom", "", None), ("childAnchorShiftId", "", None)],
}


def tableColumns(kind):
    """Full-schema ia.display.table columns for one of the dashboard's tables."""
    import copy
    out = []
    for field, title, width in _TABLES.get(_u(kind), []):
        c = copy.deepcopy(_COL)
        c["field"] = field
        c["header"]["title"] = title
        c["width"] = "" if width in ("", None) else width
        c["visible"] = width is not None
        out.append(c)
    return out


_GREY = {"color": "#697A98"}
_BAND_FG = {"green": "#50C878", "amber": "#F4B343", "red": "#DC5050"}


def _cell(v, grey=False, band=None):
    st = dict(_GREY) if grey else ({"color": _BAND_FG[band]} if band in _BAND_FG else {})
    return {"value": v, "style": st} if st else v


def scrapRows(zoom, anchorShiftId, areaFamily=None, locationId=None, groupBy="Defect", unitView=False, _refreshToken=None):
    """Scrap table rows. Non-reject scrap is greyed (excluded from quality). Area view: scrap
    charged here but found elsewhere is a 'Found downstream at ...' row. Unit view: scrap found
    here but charged to another area is greyed and tagged with that area."""
    gb = _u(groupBy) or "Defect"
    unit = bool(_u(unitView))
    out = []
    for r in scrap(zoom, anchorShiftId, _u(areaFamily) or None, _id(locationId), gb):
        if gb == "Line":
            out.append({"c1": r.get("LocationName") or "", "c2": r.get("DefectDescription") or "--",
                        "c3": _i(r.get("Quantity"))})
            continue
        if gb == "Part":
            out.append({"c1": r.get("PartNumber") or "", "c2": r.get("DefectDescription") or "--",
                        "c3": _i(r.get("Good")), "c4": _i(r.get("Quantity")), "c5": pct(r.get("Quality"), 1)})
            continue
        nonReject = bool(r.get("IsNonReject"))
        downstream = bool(r.get("IsFoundDownstream"))
        if nonReject:
            note = "non-reject (excluded)"
        elif downstream and unit:
            note = "charged to " + (familyTitle(r.get("ChargedToFamily")) or "another area")
        elif downstream:
            note = "Found downstream at " + (r.get("FoundAtLocationName") or "?")
        else:
            note = ""
        grey = nonReject or (downstream and unit)
        out.append({"c1": _cell(r.get("DefectDescription") or r.get("DefectCode") or "", grey),
                    "c2": _cell(r.get("PartNumber") or "--", grey),
                    "c3": _cell(_i(r.get("Quantity")), grey),
                    "c4": _cell(note, grey)})
    return out


def breakdownRows(zoom, anchorShiftId, locationId, _refreshToken=None):
    """The unit drill-down's breakdown table (Day -> shifts, Week -> days); a row zooms in."""
    out = []
    for r in breakdown(zoom, anchorShiftId, _id(locationId)):
        out.append({
            "c1": r.get("Label") or "",
            "c2": _cell(pct(r.get("Availability"), 0), band=r.get("AvailabilityBand")),
            "c3": _cell(pct(r.get("Quality"), 1), band=r.get("QualityBand")),
            "c4": "%s min" % _count(r.get("DowntimeMinutes")),
            "c5": _i(r.get("Good")), "c6": _i(r.get("Scrap")),
            "childZoom": r.get("ChildZoom"), "childAnchorShiftId": r.get("ChildAnchorShiftId"),
        })
    return out


def zoomInto(session, selection):
    """A breakdown row tap: open that shift / day."""
    sel = _u(selection) or []
    if not sel:
        return
    row = sel[0]
    if row.get("childAnchorShiftId") is not None:
        session.custom.oeePeriod = {"zoom": row.get("childZoom"), "anchorShiftId": row.get("childAnchorShiftId")}


# ---- Unit page (/shop-floor/oee/unit/:locationId) ---------------------------

_EMPTY_UNIT = {
    "locationId": None, "found": False, "name": "", "family": "", "familyTitle": "",
    "groupId": None, "groupName": "", "isTrim": False, "isDieCast": False, "hasStations": False,
    "hasProduction": False,
    "availability": None, "availabilityBand": None, "quality": None, "qualityBand": None,
    "downText": "0 min", "downSub": "", "shopLinkText": "",
    "foundDownstreamNote": "", "unplacedNote": "",
}


def unitHeader(zoom, anchorShiftId, locationId, _refreshToken=None):
    """The unit drill-down's header and KPI figures. At Shift zoom the anchor shift is read
    live, so an edit made from this page shows at once (stored rows lag by one refresh)."""
    lid = _id(locationId)
    out = dict(_EMPTY_UNIT)
    out["locationId"] = lid
    if lid is None:
        return out
    rows = unitSummary(zoom, anchorShiftId, None, _u(zoom) == "Shift")
    unit = None
    for r in rows:
        if r.get("RowKind") in ("Unit", "Station") and r.get("LocationId") == lid:
            unit = r
            break
    if unit is None:
        return out
    fam = unit.get("AreaFamily") or ""
    grp = {}
    for r in rows:
        if r.get("RowKind") == "Group" and r.get("ProductionAreaId") == unit.get("ProductionAreaId"):
            grp = r
            break
    area = _scopeRow(rows, fam)
    plant = _scopeRow(rows, None)
    nr = _i(unit.get("NoReasonCount"))
    fd = _i(area.get("FoundDownstreamScrap"))
    up = _i(plant.get("UnplacedScrap"))
    out.update({
        "found": True, "name": unit.get("LocationName") or "", "family": fam, "familyTitle": familyTitle(fam),
        "groupId": unit.get("ProductionAreaId"), "groupName": unit.get("ProductionAreaName") or "",
        "isTrim": fam == "trim" and unit.get("RowKind") == "Unit",
        "isDieCast": fam == "diecast",
        "hasStations": len([r for r in rows if r.get("RowKind") == "Station" and r.get("ParentLocationId") == lid]) > 0,
        "hasProduction": bool(unit.get("HasProduction")),
        "availability": _f(unit.get("Availability")), "availabilityBand": unit.get("AvailabilityBand"),
        "quality": _f(unit.get("Quality")), "qualityBand": unit.get("QualityBand"),
        "downText": "%s min" % _count(unit.get("DowntimeMinutes")),
        "downSub": "unplanned %s%splanned %s%s%d with no reason" % (
            _count(unit.get("UnplannedDowntimeMinutes")), _DOT, _count(unit.get("PlannedDowntimeMinutes")), _DOT, nr),
        "shopLinkText": (u"Shop level -- %s %s ›" % (grp.get("ProductionAreaName") or "", pct(grp.get("Quality"), 1))) if grp else "",
        "foundDownstreamNote": ("Die Cast area: %s scrapped downstream and charged to Die Cast, not traced to a press." % _count(fd))
                               if fam == "diecast" and fd else "",
        "unplacedNote": ("%s Non-Specific rejects with no cell are left out of dashboard quality." % _count(up)) if up else "",
    })
    return out


def stationInstances(zoom, anchorShiftId, locationId, _refreshToken=None):
    """A line's OEE-enabled stations: availability and downtime."""
    lid = _id(locationId)
    out = []
    for r in unitSummary(zoom, anchorShiftId, None, _u(zoom) == "Shift"):
        if r.get("RowKind") == "Station" and r.get("ParentLocationId") == lid:
            out.append({"name": r.get("LocationName") or "",
                        "value": pct(r.get("Availability"), 0) if r.get("HasProduction") else "--",
                        "band": r.get("AvailabilityBand"),
                        "downText": "%s min down" % _count(r.get("DowntimeMinutes"))})
    return out


def _fmt(d):
    try:
        return None if d is None else system.date.format(d, "yyyy-MM-dd HH:mm:ss")
    except (Exception, java.lang.Exception):
        return None


def entryInstances(anchorShiftId, locationId, _refreshToken=None):
    """The anchor shift's downtime entries at the unit and its stations; '~' marks a duration
    entered without clock times."""
    lid = _id(locationId)
    out = []
    for r in downtimeEntries(anchorShiftId, lid):
        reason = r.get("ReasonDescription") or r.get("ReasonCode")
        out.append({
            "minutes": ("~" if r.get("IsApproximate") else "") + _count(r.get("Minutes")) + " min",
            "reason": reason or "-- no reason --",
            "noReason": reason is None,
            "type": r.get("ReasonTypeName") or "",
            "by": r.get("ByInitials") or "",
            "station": (r.get("LocationName") or "") if r.get("IsStation") else "",
            "editor": {
                "mode": "update", "editId": r.get("DowntimeEventId"), "scopeLocationId": r.get("LocationId"),
                "reasonCodeId": r.get("ReasonCodeId"),
                "startedAtEtStr": _fmt(r.get("StartedAtEt")), "endedAtEtStr": _fmt(r.get("EndedAtEt")),
                "remarks": r.get("Remarks"), "shiftId": None,
            },
        })
    return out


def editEntry(session, editorParams):
    """Open Popups/DowntimeEditor on one entry. Supervisor-only, as in the Downtime Manager:
    without elevation the ElevationModal opens and replays 'dtEditRequested' to this page."""
    p = _u(editorParams) or {}
    if not p.get("editId"):
        return
    if not BlueRidge.Common.Session.isElevated(session):
        BlueRidge.Common.Session.requireElevation(session, "DowntimeEdit", "Edit downtime event", {"oeeEditor": p})
        return
    system.perspective.openPopup(id="mpp-downtime-editor", view="BlueRidge/Components/Popups/DowntimeEditor",
                                 modal=True, showCloseIcon=False, params=p)
