# =============================================================================
# Project Library:  BlueRidge.Audit.LogEntityType
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read-side helper for Audit.LogEntityType. Drives the EntityType
#   dropdown on the AuditLog + FailureLog Browser pages.
#
# Public surface:
#   list() -> list[dict]
# =============================================================================


def list():
    """
    Returns all LogEntityType rows, ordered by Name. Used to populate
    the EntityType dropdown.

    Returns:
        list[dict]: rows with keys Id, Code, Name. Empty list on failure.
    """
    BlueRidge.Common.Util.log("loading log-entity types")
    try:
        return BlueRidge.Common.Db.execList("audit/LogEntityType_List")
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load entity types", str(e), "error")
        return []
