"""BlueRidge.Quality.QualitySample - thin access to the Phase 9 inspection procs
   (FDS-08-011/012/013/014). Wrappers only; pass/fail semantics, required-attribute
   checks and the no-auto-hold rule live in Quality.QualitySample_Record.

   Public surface:
     record(data, appUserId=None, terminalLocationId=None) -> {Status, Message, NewId}
     listByLot(lotId, _refreshToken=None)                  -> list[dict] (raw proc rows)
     listByLotInstances(lotId, _refreshToken=None)         -> SampleRow repeater instances
     listResults(qualitySampleId)                          -> list[dict]
     addAttachment(qualitySampleId, fileName, fileType, filePath, appUserId=None)
     listAttachments(qualitySampleId)                      -> list[dict]
     getTriggerOptions(_refreshToken=None)                 -> [{label, value}]"""

import system
import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def record(data, appUserId=None, terminalLocationId=None):
    """Record ONE inspection sample. data: {lotId, qualitySpecVersionId, locationId,
       sampleTriggerCodeId, results: [{qualitySpecAttributeId, measuredValue}, ...]}.
       results is JSON-encoded for the proc's @ResultsJson. A Fail result is still
       Status=1 (recorded); NO auto-hold fires (FDS-08-012) - the caller surfaces the
       proc Message and warns. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "record data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    results = _u(d.get("results")) or []
    params = {
        "lotId":                d.get("lotId"),
        "qualitySpecVersionId": d.get("qualitySpecVersionId"),
        "locationId":           d.get("locationId"),
        "sampleTriggerCodeId":  d.get("sampleTriggerCodeId"),
        "resultsJson":          BlueRidge.Common.Util.convertWrapperObjectToJson(results),
        "appUserId":            appUserId,
        "terminalLocationId":   terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("quality/QualitySample_Record", params)


def recordFromEntries(lot, spec, entries, triggerCodeId=None, appUserId=None,
                      terminalLocationId=None):
    """View-glue assembler for InspectionEntry: builds the full results list from the
       resolved lot dict + active-spec dict (QualitySpec.getActiveVersionForItemOrEmpty
       shape) + the view's entries map ({attributeId(str): measuredValue}), then calls
       record(). EVERY attribute of the version is submitted - missing entries go as
       empty strings so the proc's required-attribute check speaks (FDS-08-011).
       LocationId = the LOT's current location. Returns {Status, Message, NewId}."""
    lot = _u(lot) or {}
    spec = _u(spec) or {}
    entries = _u(entries) or {}
    if lot.get("Id") is None:
        return {"Status": 0, "Message": "No LOT selected.", "NewId": None}
    if spec.get("versionId") is None:
        return {"Status": 0, "Message": "No published quality spec for this part.", "NewId": None}
    results = []
    for a in (spec.get("attributes") or []):
        a = _u(a) or {}
        aid = a.get("qualitySpecAttributeId")
        results.append({
            "qualitySpecAttributeId": aid,
            "measuredValue": entries.get("%s" % aid) or "",
        })
    data = {
        "lotId":                lot.get("Id"),
        "qualitySpecVersionId": spec.get("versionId"),
        "locationId":           lot.get("CurrentLocationId"),
        "sampleTriggerCodeId":  _u(triggerCodeId),
        "results":              results,
    }
    return record(data, appUserId=appUserId, terminalLocationId=terminalLocationId)


def listByLot(lotId, _refreshToken=None):
    """Inspection history rows for a LOT, newest first (raw proc rows).
       _refreshToken is ignored - runScript bindings pass a bumped token to
       force a re-read after a record (runScript caches on args)."""
    lotId = _u(lotId)
    BlueRidge.Common.Util.log("listByLot lotId=%s" % lotId)
    if not lotId:
        return []
    return BlueRidge.Common.Db.execList(
        "quality/QualitySample_ListByLot", {"lotId": lotId})


def listByLotInstances(lotId, _refreshToken=None):
    """SampleRow flex-repeater instances for the Inspection history panel. Dates are
       PRE-FORMATTED here (mirrors Lot.mapHistoryInstances - dates do not survive
       repeater param hops). One flat param dict per sample:
       {sampleId, result, specLabel, trigger, inspector, sampledAt, counts}."""
    rows = listByLot(lotId, _refreshToken) or []
    out = []
    for r in rows:
        r = dict(r or {})
        sa = r.get("SampledAt")
        disp = ""
        if sa is not None:
            try:
                disp = system.date.format(sa, "MM/dd HH:mm")
            except:
                disp = ("%s" % sa)[:16]
        total = r.get("TotalResults") or 0
        passed = r.get("PassedResults") or 0
        out.append({
            "sampleId":  r.get("Id"),
            "result":    r.get("InspectionResultCode") or "",
            "specLabel": (r.get("SpecName") or "") + " v" + ("%s" % (r.get("VersionNumber") or "")),
            "trigger":   r.get("SampleTriggerCode") or "",
            "inspector": r.get("InspectorName") or "",
            "sampledAt": disp,
            "counts":    "%s/%s passed" % (passed, total),
        })
    return out


def listResults(qualitySampleId):
    """Per-attribute results for one sample (joined to the attribute definition),
       ordered by SortOrder. Returns list[dict]."""
    qualitySampleId = _u(qualitySampleId)
    BlueRidge.Common.Util.log("listResults qualitySampleId=%s" % qualitySampleId)
    if not qualitySampleId:
        return []
    return BlueRidge.Common.Db.execList(
        "quality/QualityResult_ListBySample", {"qualitySampleId": qualitySampleId})


def addAttachment(qualitySampleId, fileName, fileType, filePath, appUserId=None):
    """Record attachment METADATA for a sample (FDS-08-013). The file-upload UI is a
       Designer follow-up; this API surface is complete. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "addAttachment qualitySampleId=%s fileName=%s fileType=%s"
        % (qualitySampleId, fileName, fileType)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "qualitySampleId": _u(qualitySampleId),
        "fileName":        _u(fileName),
        "fileType":        _u(fileType),
        "filePath":        _u(filePath),
        "appUserId":       appUserId,
    }
    return BlueRidge.Common.Db.execMutation("quality/QualityAttachment_Add", params)


def listAttachments(qualitySampleId):
    """Attachment metadata rows for one sample, newest first. Returns list[dict]."""
    qualitySampleId = _u(qualitySampleId)
    BlueRidge.Common.Util.log("listAttachments qualitySampleId=%s" % qualitySampleId)
    if not qualitySampleId:
        return []
    return BlueRidge.Common.Db.execList(
        "quality/QualityAttachment_ListBySample", {"qualitySampleId": qualitySampleId})


def getTriggerOptions(_refreshToken=None):
    """[{label, value}] for the sample-trigger dropdown (Quality.SampleTriggerCode
       code table: FirstPiece/LastPiece/Hourly/Random + the FDS-08-014 additions).
       _refreshToken is ignored (runScript re-read arg)."""
    try:
        rows = BlueRidge.Common.Db.execList("quality/SampleTriggerCode_List") or []
    except Exception as e:
        BlueRidge.Common.Util.log("getTriggerOptions failed: %s" % str(e))
        return []
    return [{"label": r.get("Name") or r.get("Code") or "", "value": r.get("Id")}
            for r in rows]
