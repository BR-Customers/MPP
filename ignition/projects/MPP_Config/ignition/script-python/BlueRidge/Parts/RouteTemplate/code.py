# =============================================================================
# Project Library:  BlueRidge.Parts.RouteTemplate
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.0
#
# Description:
#   Read surface for the Item Master Routes tab. Returns the active
#   RouteTemplate for a given Item plus its ordered RouteStep children
#   in one entity-script call, shaped for direct binding to view.custom.data.
#
# Public surface:
#   getActiveForItem(itemId) -> dict | None
#     Returns: {
#       Id, ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt,
#       publishedVersion,  # alias of VersionNumber, view-friendly
#       effectiveFrom,     # ISO date string, view-friendly
#       steps: [           # list of {seq, areaName, templateLabel, isRequired, dataFields}
#         ...
#       ]
#     }
#     Returns None when no active route exists.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (read paths only).
# =============================================================================


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _isoDate(d):
    """Render a date-like value as an ISO date string. Tolerant of None /
    Java date / Python date / already-string inputs."""
    if d is None:
        return ""
    try:
        return str(d)[:10]
    except Exception:
        return ""


def _mapSteps(rows):
    out = []
    for r in rows or []:
        opCode = r.get("OperationCode") or ""
        opName = r.get("OperationName") or ""
        if opCode and opName:
            templateLabel = "%s — %s" % (opCode, opName)
        else:
            templateLabel = opCode or opName
        out.append({
            "seq":           r.get("SequenceNumber"),
            "areaName":      "",
            "templateLabel": templateLabel,
            "isRequired":    bool(r.get("IsRequired")),
            "dataFields":    r.get("Description") or "",
        })
    return out


_EMPTY_ROUTE = {"publishedVersion": 0, "effectiveFrom": "", "steps": []}


def getActiveForItem(itemId):
    """Returns the active RouteTemplate + steps for the given Item.
    Single entity-script call → one binding on view.custom.data.
    Always returns a dict — empty shape when no published route exists
    or itemId is missing, so view bindings never traverse into None."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if not itemId:
        return dict(_EMPTY_ROUTE)
    try:
        header = BlueRidge.Common.Db.execOne(
            "parts/RouteTemplate_GetActiveForItem",
            {"itemId": itemId},
        )
        if header is None:
            return dict(_EMPTY_ROUTE)
        steps = BlueRidge.Common.Db.execList(
            "parts/RouteStep_ListByRoute",
            {"routeTemplateId": header.get("Id")},
        )
        result = dict(header)
        result["publishedVersion"] = header.get("VersionNumber")
        result["effectiveFrom"]    = _isoDate(header.get("EffectiveFrom"))
        result["steps"]            = _mapSteps(steps)
        return result
    except Exception as e:
        BlueRidge.Common.Util.log("getActiveForItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load route", str(e), "error")
        return dict(_EMPTY_ROUTE)
