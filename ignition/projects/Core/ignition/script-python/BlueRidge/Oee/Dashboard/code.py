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


def unitSummary(zoom, anchorShiftId, areaFamily=None):
    """Unit / Station / Group / Area / Plant rows for the period, pooled."""
    return _list("unitSummary", "oee/Dashboard_GetUnitSummary", {
        "zoom": _u(zoom), "anchorShiftId": _u(anchorShiftId), "areaFamily": _u(areaFamily)})


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
