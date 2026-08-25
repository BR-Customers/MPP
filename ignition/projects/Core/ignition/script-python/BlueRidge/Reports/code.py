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
         "desc": "Full traceability sheet for a scanned LOT.", "available": True,
         "project": "MPP", "reportPath": "Lot Detail",
         "params": [{"id": "LotId", "label": "LOT", "kind": "lot", "required": True}]},
        {"key": "shot_count", "title": "Die Cast Shot Count",
         "desc": "Shots per die vs. shot-limit.", "available": True,
         "project": "MPP", "reportPath": "Die Cast Shot Count", "params": []},
        {"key": "line_perf", "title": "Production Line Performance",
         "desc": "Weekly output, scrap and downtime by process line.", "available": True,
         "project": "MPP", "reportPath": "Production Line Performance", "params": []},
        {"key": "inventory", "title": "Current Inventory",
         "desc": "Plantwide WIP snapshot by item and location.", "available": True,
         "project": "MPP", "reportPath": "Inventory", "params": []},

        # ---- FDS-12-006 / 010 / 011 aggregate reports ----
        # FDS-12-006 is ONE requirement but the legacy PD delivers rejects at
        # three altitudes and MPP uses all three, so it lands as three reports.
        {"key": "rejects_detail", "title": "Rejects - Transaction Detail",
         "desc": "Every reject record in the window, with defect and charge-to.",
         "available": True, "project": "MPP", "reportPath": "Rejects Transaction Detail",
         "params": [{"id": "StartDate", "label": "Start", "kind": "dateRange"},
                    {"id": "EndDate", "label": "End", "kind": "dateRange"}]},
        {"key": "rejects_summary", "title": "Rejects - Plant Summary",
         "desc": "Departmental scrap and reject % across the plant.",
         "available": True, "project": "MPP", "reportPath": "Rejects Plant Summary",
         "params": [{"id": "StartDate", "label": "Start", "kind": "dateRange"},
                    {"id": "EndDate", "label": "End", "kind": "dateRange"}]},
        {"key": "rejects_matrix", "title": "Rejects - Part Matrix",
         "desc": "Per part: department split and defect detail.",
         "available": True, "project": "MPP", "reportPath": "Rejects Part Matrix",
         "params": [{"id": "StartDate", "label": "Start", "kind": "dateRange"},
                    {"id": "EndDate", "label": "End", "kind": "dateRange"}]},
        {"key": "hold_status", "title": "Hold Status",
         "desc": "Every LOT and container currently on hold, oldest first.",
         "available": True, "project": "MPP", "reportPath": "Hold Status", "params": []},
        {"key": "shipping_history", "title": "Shipping History",
         "desc": "Shipped containers, dated by container closure.",
         "available": True, "project": "MPP", "reportPath": "Shipping History",
         "params": [{"id": "StartDate", "label": "Start", "kind": "dateRange"},
                    {"id": "EndDate", "label": "End", "kind": "dateRange"}]},
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


def lotOptions():
    """Dropdown options for the LOT picker (label + LotId value), newest first.
    Wraps the Core NQ reports/Lot_ListForPicker. Safe [] on any DB/JDBC error."""
    try:
        ds = system.db.runNamedQuery("reports/Lot_ListForPicker", {})
        out = []
        for r in range(ds.getRowCount()):
            out.append({"label": ds.getValueAt(r, "label"), "value": ds.getValueAt(r, "value")})
        return out
    except (Exception, _JavaThrowable) as e:
        logger.warn("lotOptions failed: %s" % str(e))
        return []


def composeParams(selectedKey, shiftId, startDate, endDate, lotId=None):
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
        if selectedKey == "lot_detail":
            return {"LotId": lotId}
        if selectedKey == "line_perf":
            return {"WeeksBack": 8}
        # The date-ranged aggregate reports. These MUST be listed explicitly:
        # the fallback below hands back a ShiftId, which none of them declares.
        if selectedKey in ("rejects_detail", "rejects_summary", "rejects_matrix",
                           "shipping_history"):
            # Fall back to a 14-day window when the pickers are empty. A blank
            # date does NOT render an unfiltered report -- the Reporting module
            # fails the parameter expression outright ("Error executing query
            # parameter expression {StartDate}"), so the viewer shows nothing
            # and the operator gets no clue why.
            e = endDate or system.date.now()
            s = startDate or system.date.addDays(e, -14)
            return {"StartDate": s, "EndDate": e}
        if selectedKey == "hold_status":
            # Current holds -- no window. Declares one harmless parameter because
            # the Report Viewer rejects an empty params dict.
            return {"MinHours": 0}
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
