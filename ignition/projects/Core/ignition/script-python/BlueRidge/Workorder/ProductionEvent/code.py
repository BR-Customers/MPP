"""BlueRidge.Workorder.ProductionEvent - thin access to the die-cast checkpoint
   procs. Wrappers only; no business logic (the cumulative-counter + required-field
   rules live in Workorder.ProductionEvent_Record). Reconciled to the as-built proc
   signature: NO eventAt param (the proc stamps SYSUTCDATETIME()), and the JSON
   children param is @FieldValuesJson (mapped from the dcValues dict)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def record(data, appUserId=None, terminalLocationId=None):
    """Record one die-cast checkpoint. data: {lotId, operationTemplateId, shotCount,
       scrapCount, scrapSourceId, weightValue, weightUomId, workOrderOperationId,
       remarks, dcValues (dict keyed by DataCollectionFieldId)}.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "record data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":                d.get("lotId"),
        "operationTemplateId":  d.get("operationTemplateId"),
        "shotCount":            d.get("shotCount"),
        "scrapCount":           d.get("scrapCount"),
        "scrapSourceId":        d.get("scrapSourceId"),
        "weightValue":          d.get("weightValue"),
        "weightUomId":          d.get("weightUomId"),
        "workOrderOperationId": d.get("workOrderOperationId"),
        "remarks":              d.get("remarks"),
        "fieldValuesJson":
            BlueRidge.Common.Util.convertWrapperObjectToJson(d.get("dcValues") or {}),
        "appUserId":            appUserId,
        "terminalLocationId":   terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/ProductionEvent_Record", params)


def listByLot(lotId):
    """Checkpoints for one LOT (cumulative-cavity card + last-shot hint).
       Returns list[dict] (header rows, chronological). Empty = no checkpoints."""
    BlueRidge.Common.Util.log("listByLot lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList(
        "workorder/ProductionEvent_ListByLot", {"lotId": _u(lotId)})


def getLatestForLot(lotId):
    """The most-recent checkpoint for a LOT (the cumulative-cavity card reads its
       ShotCount/ScrapCount/EventAt), or None. Data-shaping only."""
    rows = listByLot(lotId) or []
    return rows[-1] if rows else None


def getLatestForLotOrEmpty(lotId):
    """Binding-safe variant: a fully-shaped dict (never None) so the cumulative-cavity
       card's nested-path bindings never Component-Error (pre-declare-bound-props
       rule). Returns the shaped empty dict when there is no LOT / no checkpoint."""
    if lotId is None:
        return {"ShotCount": None, "ScrapCount": None, "EventAt": None}
    row = getLatestForLot(lotId)
    if row is None:
        return {"ShotCount": None, "ScrapCount": None, "EventAt": None}
    return row
