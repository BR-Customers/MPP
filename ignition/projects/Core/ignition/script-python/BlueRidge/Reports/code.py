"""BlueRidge.Reports - registry + PDF generation for the Reports landing page.

The registry is the single source of truth for what reports exist and what
parameters each takes; the landing-page view renders its list + param inputs from
it, so adding a report later is a registry entry + its data.bin. generatePdf renders
a report to PDF bytes via the Reporting module (gateway scope); the calling
component event hands the bytes to system.perspective.download for the session.

Every binding-facing function is guarded: on any failure it logs and returns a SAFE,
correctly-shaped fallback (never None / never an empty params dict), so a data or
gateway hiccup degrades gracefully instead of breaking the view's bindings.

This is UI/integration glue, not domain logic - no business rules live here.
"""
from java.lang import Throwable as _JavaThrowable

logger = system.util.getLogger("BlueRidge.Reports")


def registry():
    """All reports, in list order. `available` gates the ones not yet built.
    `params` drives the landing page's parameter inputs."""
    return [
        {
            "key": "downtime_shift",
            "title": "Downtime by Shift",
            "desc": "Loss analysis for one shift, by machine and reason.",
            "project": "MPP",
            "reportPath": "Downtime Report",
            "available": True,
            "params": [
                {"id": "ShiftId", "label": "Shift", "kind": "shift", "required": True},
            ],
        },
        {"key": "downtime_range", "title": "Downtime by Date Range",
         "desc": "Downtime across a start/end period, by area.", "available": True,
         "project": "MPP", "reportPath": "Downtime by Date Range",
         "params": [{"id": "StartDate", "label": "Start", "kind": "dateRange"},
                    {"id": "EndDate", "label": "End", "kind": "dateRange"}]},
        {"key": "lot_detail", "title": "Lot Detail",
         "desc": "Full traceability sheet for a scanned LOT.", "available": False,
         "params": [{"id": "LotId", "label": "LOT", "kind": "lot", "required": True}]},
        {"key": "shot_count", "title": "Die Cast Shot Count",
         "desc": "Shots per die vs. shot-limit.", "available": True,
         "project": "MPP", "reportPath": "Die Cast Shot Count", "params": []},
        {"key": "line_perf", "title": "Production Line Performance",
         "desc": "Output, scrap and downtime by line, per shift/week.", "available": False,
         "params": [{"id": "Period", "label": "Period", "kind": "period"}]},
        {"key": "inventory", "title": "Current Inventory",
         "desc": "Plantwide WIP snapshot by item and location.", "available": True,
         "project": "MPP", "reportPath": "Inventory", "params": []},
    ]


def _find(key):
    for r in registry():
        if r["key"] == key:
            return r
    raise ValueError("unknown report '%s'" % key)


def reportOptions():
    """Dropdown options for the report picker (built reports only). Safe [] on error."""
    try:
        return [{"label": r["title"], "value": r["reportPath"]}
                for r in registry() if r.get("available") and r.get("reportPath")]
    except (Exception, _JavaThrowable) as e:
        logger.warn("reportOptions failed: %s" % str(e))
        return []


def shiftOptions():
    """Dropdown options for the shift picker (label + ShiftId value), newest first.
    Wraps the Core NQ reports/Shift_ListForPicker. Safe [] on any DB/JDBC error."""
    try:
        ds = system.db.runNamedQuery("reports/Shift_ListForPicker", {})
        out = []
        for r in range(ds.getRowCount()):
            out.append({"label": ds.getValueAt(r, "label"), "value": ds.getValueAt(r, "value")})
        return out
    except (Exception, _JavaThrowable) as e:
        logger.warn("shiftOptions failed: %s" % str(e))
        return []


def composeParams(selectedKey, shiftId, startDate, endDate):
    """Build the report-parameter dict for the Report Viewer from the landing page's
    inputs, keyed by which report is selected. Bound (runScript) to view.custom.reportParams.
    NEVER returns an empty dict (the Report Viewer rejects a report given empty params)."""
    try:
        if selectedKey == "downtime_range":
            return {"StartDate": startDate, "EndDate": endDate}
        if selectedKey == "inventory":
            return {"MinPieces": 0}
        if selectedKey == "shot_count":
            return {"MinShots": 0}
        return {"ShiftId": shiftId if shiftId is not None else ""}
    except (Exception, _JavaThrowable) as e:
        logger.warn("composeParams failed for '%s': %s" % (selectedKey, str(e)))
        return {"ShiftId": ""}


def generatePdf(reportKey, params):
    """Render a report to PDF bytes via the Reporting module. Gateway scope.
    Raises on an unknown/unbuilt report or a render failure; the caller (the view's
    printPdf) catches and toasts. params: dict keyed by the report's parameter names."""
    r = _find(reportKey)
    if not r.get("available"):
        raise ValueError("report '%s' is not built yet" % reportKey)
    return system.report.executeReport(r["reportPath"], r["project"], dict(params or {}), "pdf")
