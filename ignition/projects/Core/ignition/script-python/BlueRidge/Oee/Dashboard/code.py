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
