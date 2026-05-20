# =============================================================================
# Project Library:  BlueRidge.Parts.Bom
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.0
#
# Description:
#   Read surface for the Item Master BOMs tab. Returns the active BOM for
#   a given parent Item plus its ordered BomLine children in one
#   entity-script call, shaped for direct binding to view.custom.data.
#
# Public surface:
#   getActiveForItem(itemId) -> dict | None
#     Returns: {
#       Id, ParentItemId, VersionNumber, EffectiveFrom, PublishedAt,
#       publishedVersion,  # alias of VersionNumber, view-friendly
#       effectiveFrom,     # ISO date string, view-friendly
#       lines: [           # list of {seq, componentName, partNumber, qtyPer, uom}
#         ...
#       ]
#     }
#     Returns None when no active BOM exists.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (read paths only).
# =============================================================================


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _isoDate(d):
    if d is None:
        return ""
    try:
        return str(d)[:10]
    except Exception:
        return ""


def _mapLines(rows):
    out = []
    for r in rows or []:
        out.append({
            "seq":           r.get("SortOrder"),
            "componentName": r.get("ChildDescription") or "",
            "partNumber":    r.get("ChildPartNumber") or "",
            "qtyPer":        r.get("QtyPer"),
            "uom":           r.get("UomCode") or "",
        })
    return out


def getActiveForItem(itemId):
    """Returns the active BOM + lines for the given parent Item.
    Single entity-script call → one binding on view.custom.data."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if not itemId:
        return None
    try:
        header = BlueRidge.Common.Db.execOne(
            "parts/Bom_GetActiveForItem",
            {"parentItemId": itemId},
        )
        if header is None:
            return None
        lines = BlueRidge.Common.Db.execList(
            "parts/BomLine_ListByBom",
            {"bomId": header.get("Id")},
        )
        result = dict(header)
        result["publishedVersion"] = header.get("VersionNumber")
        result["effectiveFrom"]    = _isoDate(header.get("EffectiveFrom"))
        result["lines"]            = _mapLines(lines)
        return result
    except Exception as e:
        BlueRidge.Common.Util.log("getActiveForItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load BOM", str(e), "error")
        return None
