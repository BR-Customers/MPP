# =============================================================================
# Project Library:  BlueRidge.Audit.LogSeverity
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read-side helper for Audit.LogSeverity. Drives the Severity dropdown
#   on the AuditLog Browser page (FailureLog doesn't have severity).
#
# Public surface:
#   list() -> list[dict]
# =============================================================================


def list():
    """Returns all LogSeverity rows (Info / Warning / Error). Empty list on failure."""
    BlueRidge.Common.Util.log("loading log severities")
    try:
        return BlueRidge.Common.Db.execList("audit/LogSeverity_List")
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load severities", str(e), "error")
        return []
