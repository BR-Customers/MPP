# =============================================================================
# Project Library:  BlueRidge.Audit.FailureLog
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.1
#
# Description:
#   Read surface for the FailureLog Browser page (FDS-11-004), plus the ONE
#   Ignition-side writer (v1.1, 2026-10-29, migration 0116):
#
#   search(filter)                  -> {rows, totalCount, topReasons, topProcs}
#   getByEntity(typeCode, entityId) -> list[dict]
#   distinctProcedures()            -> list[dict]
#   record(...)                     -> status dict | None   (never raises)
#
#   search() bundles 3 NQ calls (List + GetTopReasons + GetTopProcs) so
#   the view's Apply handler stays a one-liner. The List proc returns
#   TOP 1000 with COUNT(*) OVER() as TotalCount in every row -- search()
#   strips that column out of the body rows and surfaces it once at the
#   top level.
#
#   The filter dict is deep-unwrapped at entry via Common.Util
#   .extractQualifiedValues to defend against any future caller (tile
#   click, bidirectional binding) handing in QualifiedValue-wrapped
#   fields.
#
# Layer:
#   View -> BlueRidge.Audit.FailureLog (this module)
#        -> BlueRidge.Common.Db.execList
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filter):
    """
    Bundled search for the FailureLog Browser. Issues 3 NQ calls and
    returns a single result dict the view writes atomically into
    view.custom.{rows, totalCount, topReasons, topProcs}.

    Args:
        filter (dict): startDate, endDate, entityTypeCode, procedureName,
                       appUserId, searchText.

    Returns:
        dict: {
            "rows":        list[dict] -- up to 1000 FailureLog rows
            "totalCount":  int        -- full unbounded count for banner
            "topReasons":  list[dict] -- top 5 by FailureReason
            "topProcs":    list[dict] -- top 5 by ProcedureName
        }
    """
    f = _u(filter) or {}
    BlueRidge.Common.Util.log("search filter=%s" % f)

    try:
        listParams = {
            "startDate":         f.get("startDate"),
            "endDate":           f.get("endDate"),
            "logEntityTypeCode": f.get("entityTypeCode"),
            "appUserId":         f.get("appUserId"),
            "procedureName":     f.get("procedureName"),
            "failureReasonLike": (f.get("searchText") or None),
            "locationId":        f.get("locationId"),
            "lotNameLike":       (f.get("lotName") or None),
        }
        rows = BlueRidge.Common.Db.execList("audit/FailureLog_List", listParams)

        totalCount = rows[0]["TotalCount"] if rows else 0
        for r in rows:
            if "TotalCount" in r:
                del r["TotalCount"]

        tileParams = {
            "startDate":         f.get("startDate"),
            "endDate":           f.get("endDate"),
            "logEntityTypeCode": f.get("entityTypeCode"),
        }
        topReasons = BlueRidge.Common.Db.execList(
            "audit/FailureLog_GetTopReasons", tileParams
        )
        topProcs = BlueRidge.Common.Db.execList(
            "audit/FailureLog_GetTopProcs",
            {"startDate": f.get("startDate"), "endDate": f.get("endDate")},
        )

        return {
            "rows":       rows,
            "totalCount": totalCount,
            "topReasons": topReasons,
            "topProcs":   topProcs,
        }
    except Exception as e:
        BlueRidge.Common.Util.log("search failed: %s" % str(e), level="warn")
        BlueRidge.Common.Notify.toast("Search failed", str(e), "error")
        return {"rows": [], "totalCount": 0, "topReasons": [], "topProcs": []}


def getByEntity(typeCode, entityId):
    """Every FailureLog row for a specific entity (drill-down support)."""
    typeCode = _u(typeCode)
    entityId = _u(entityId)
    BlueRidge.Common.Util.log("typeCode=%s entityId=%s" % (typeCode, entityId))
    if not typeCode or entityId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "audit/FailureLog_GetByEntity",
            {"logEntityTypeCode": typeCode, "entityId": entityId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getByEntity failed: %s" % str(e), level="warn")
        BlueRidge.Common.Notify.toast("Lookup failed", str(e), "error")
        return []


def distinctProcedures():
    """All-time distinct ProcedureName values for the Procedure dropdown."""
    BlueRidge.Common.Util.log("loading distinct procedures")
    try:
        return BlueRidge.Common.Db.execList("audit/FailureLog_DistinctProcedures")
    except Exception as e:
        BlueRidge.Common.Util.log("distinctProcedures failed: %s" % str(e), level="warn")
        BlueRidge.Common.Notify.toast("Could not load procedures", str(e), "error")
        return []


def record(procedureName, failureReason, entityTypeCode, eventTypeCode, appUserId,
           entityId=None, locationId=None, lotId=None, meta=None):
    """
    Write one Audit.FailureLog row for a failure that happened OUTSIDE a
    mutation proc (e.g. AIM refused a post). Goes through Audit.FailureLog_Record
    -- the status-row twin of the silent Audit_LogFailure -- via a Query NQ.

    NEVER RAISES. The caller is a container completion, a CRT validation or a
    gateway timer; a failure to log a failure must not change what they do.
    A refusal (Status 0) or an exception is written to the gateway log at
    ERROR, naming the procedure and the reason, and None is returned.

    Args:
        procedureName (str):  the script function / proc that failed.
        failureReason (str):  why (truncated to 500 in SQL).
        entityTypeCode (str): Audit.LogEntityType.Code, e.g. 'Container'.
        eventTypeCode (str):  Audit.LogEventType.Code, e.g. 'AimPostFailed'.
        appUserId (long):     REQUIRED, supplied by the caller -- the operator,
                              or Common.Util.systemAppUserId() from gateway scope.
                              No fallback (the 2026-09-18 attribution rule).
        entityId, locationId, lotId: optional ids.
        meta (dict|None):     JSON-encoded into AttemptedParameters. Callers must
                              never put the AIM path token in it.
    Returns:
        dict {Status, Message, NewId} on success, else None.
    """
    from java.lang import Exception as JavaException
    try:
        appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
        metaJson = None
        if meta is not None:
            metaJson = system.util.jsonEncode(BlueRidge.Common.Util.extractQualifiedValues(meta))
        res = BlueRidge.Common.Db.execMutation("audit/FailureLog_Record", {
            "appUserId":           appUserId,
            "logEntityTypeCode":   entityTypeCode,
            "entityId":            _u(entityId),
            "logEventTypeCode":    eventTypeCode,
            "failureReason":       failureReason,
            "procedureName":       procedureName,
            "attemptedParameters": metaJson,
            "locationId":          _u(locationId),
            "lotId":               _u(lotId),
        })
        if res and res.get("Status"):
            return res
        BlueRidge.Common.Util.log(
            "FailureLog not written for %s (%s): %s"
            % (procedureName, failureReason, (res or {}).get("Message")), level="error")
    except (Exception, JavaException), e:
        BlueRidge.Common.Util.log(
            "FailureLog write raised for %s (%s): %s" % (procedureName, failureReason, e),
            level="error")
    return None
