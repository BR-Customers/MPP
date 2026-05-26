# =============================================================================
# Project Library:  BlueRidge.Parts.Item
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.0
#
# Description:
#   Read surface for the Item Master Configuration Tool screen
#   (Phase 2). Mutations (add/update/deprecate) land in Phase 3.
#   Routes every DB call through BlueRidge.Common.Db.* helpers.
#
# Public surface:
#   getAll(searchText=None, itemTypeId=None, includeDeprecated=False)
#     -> list[dict]
#   getOne(itemId) -> dict | None
#   mapItemRowsForList(rows, typeFilter='All Types') -> list[dict]
#   typeBadgeFor(itemTypeName) -> str
#   getAllForList(searchText='', typeFilter='All Types') -> list[dict]
#
# Layer:
#   View -> BlueRidge.Parts.Item (this module)
#        -> BlueRidge.Common.Db.execList / execOne
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (read paths only).
# =============================================================================


_TYPE_BADGE = {
    "Finished Good": "FG",
    "Component":     "COMP",
    "Sub-Assembly":  "SA",
    "Raw Material":  "RAW",
    "Pass-Through":  "PT",
}


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def typeBadgeFor(itemTypeName):
    """Returns short-form badge text (FG / COMP / SA / RAW / PT) for the
    given item-type name. Unknown names -> '' (no exception)."""
    return _TYPE_BADGE.get(itemTypeName or "", "")


def getAll(searchText=None, itemTypeId=None, includeDeprecated=False):
    """List items with optional server-side SearchText (PartNumber +
    Description LIKE) and ItemTypeId filter. Includes ItemType.Name and
    Uom.Code joins."""
    BlueRidge.Common.Util.log(
        "searchText=%s itemTypeId=%s includeDeprecated=%s"
        % (searchText, itemTypeId, includeDeprecated))
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Item_List",
            {
                "itemTypeId":        itemTypeId,
                "searchText":        searchText,
                "includeDeprecated": 1 if includeDeprecated else 0,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load items", str(e), "error")
        return []


def getOne(itemId):
    """Single-row Item lookup with ItemType + UOM joins. Returns dict or
    None."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if itemId is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne(
            "parts/Item_Get",
            {"id": itemId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getOne failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load item", str(e), "error")
        return None


def mapItemRowsForList(rows, typeFilter="All Types"):
    """Flex-repeater instances transform.

    - Filters by ItemTypeName when typeFilter != 'All Types'.
    - Maps DB columns to the ItemRow view-param shape.

    Defensive against Dataset input (Ignition custom-prop layer can coerce
    stored lists back to Dataset when read via expression). Returns
    list[dict] ready for Repeater.props.instances composition."""
    rows = _u(rows)
    if rows is None:
        return []
    if hasattr(rows, "getColumnNames") and hasattr(rows, "getRowCount"):
        headers = list(rows.getColumnNames())
        rows = [dict(zip(headers, row)) for row in rows]
    typeFilter = _u(typeFilter)
    keepAll = (not typeFilter) or typeFilter == "All Types"
    out = []
    for r in rows:
        itemTypeName = r.get("ItemTypeName") or ""
        if (not keepAll) and itemTypeName != typeFilter:
            continue
        out.append({
            "id":           r.get("Id"),
            "partNumber":   r.get("PartNumber") or "",
            "description": r.get("Description") or "",
            "itemTypeId":   r.get("ItemTypeId"),
            "itemTypeName": itemTypeName,
            "typeBadge":    typeBadgeFor(itemTypeName),
            "isDraft":      False,
        })
    return out


def getAllForList(searchText="", typeFilter="All Types"):
    """One-shot getAll + map composed for the expression binding on
    view.custom.items. Server-side filter on SearchText; client-side
    filter on type name."""
    searchText = _u(searchText) or ""
    typeFilter = _u(typeFilter) or "All Types"
    rows = getAll(
        searchText=searchText if searchText.strip() else None,
        itemTypeId=None,
        includeDeprecated=False,
    )
    return mapItemRowsForList(rows, typeFilter)


def getInstancesForFlexRepeater(searchText="", typeFilter="All Types", selectedId=0):
    """Composes the flex-repeater instances payload for the items list.
    Each instance is {'item': <row>, 'selectedId': <int>}. Replaces the
    forEach(...) expression Ignition's scanner rejected for nested
    reference paths inside the row-template dict literal."""
    selectedId = _u(selectedId) or 0
    rows = getAllForList(searchText, typeFilter)
    return [{"item": r, "selectedId": selectedId} for r in rows]
