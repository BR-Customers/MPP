# =============================================================================
# Project Library:  BlueRidge.Audit.ConfigLog
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read surface for the AuditLog Browser page (FDS-11-002). Parallel
#   to BlueRidge.Audit.FailureLog but ConfigLog has no equivalent of the
#   Top Reasons / Top Procs aggregations -- it only logs successes, so
#   "top rejection reasons" wouldn't make sense. search() therefore
#   returns just {rows, totalCount}.
#
#   The proc returns columns LoggedAt + UserId (table-native names);
#   downstream UI keys mirror those exactly.
#
# Public surface:
#   search(filter)                  -> {rows, totalCount}
#   getByEntity(typeCode, entityId) -> list[dict]
# =============================================================================


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filter):
    """
    Args:
        filter (dict): startDate, endDate, entityTypeCode, logSeverityCode,
                       appUserId, searchText.

    Returns:
        dict: {"rows": list[dict], "totalCount": int}. Empty rows + 0
              count on exception (toast fires). Each row has columns
              Id, LoggedAt, UserId, UserDisplayName, LogEntityTypeCode,
              LogEntityTypeName, EntityId, LogEventTypeId, LogEventTypeCode,
              LogSeverityId, LogSeverityCode, Description, OldValue, NewValue.
    """
    f = _u(filter) or {}
    BlueRidge.Common.Util.log("search filter=%s" % f)
    try:
        params = {
            "startDate":         f.get("startDate"),
            "endDate":           f.get("endDate"),
            "logEntityTypeCode": f.get("entityTypeCode"),
            "appUserId":         f.get("appUserId"),
            "logSeverityCode":   f.get("logSeverityCode"),
            "descriptionLike":   (f.get("searchText") or None),
        }
        rows = BlueRidge.Common.Db.execList("audit/ConfigLog_List", params)
        totalCount = rows[0]["TotalCount"] if rows else 0
        for r in rows:
            if "TotalCount" in r:
                del r["TotalCount"]
        return {"rows": rows, "totalCount": totalCount}
    except Exception as e:
        BlueRidge.Common.Util.log("search failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Search failed", str(e), "error")
        return {"rows": [], "totalCount": 0}


def getByEntity(typeCode, entityId):
    """Every ConfigLog row for a specific entity (drill-down support)."""
    typeCode = _u(typeCode)
    entityId = _u(entityId)
    BlueRidge.Common.Util.log("typeCode=%s entityId=%s" % (typeCode, entityId))
    if not typeCode or entityId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "audit/ConfigLog_GetByEntity",
            {"logEntityTypeCode": typeCode, "entityId": entityId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getByEntity failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Lookup failed", str(e), "error")
        return []
