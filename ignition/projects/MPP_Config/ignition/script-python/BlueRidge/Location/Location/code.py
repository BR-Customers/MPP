# =============================================================================
# Project Library:  BlueRidge.Location.Location
#
# Author:           Blue Ridge Automation
# Created:          2026-05-12
# Version:          1.3
#
# Description:
#   Entity-script for Location.Location and its attribute values.
#
#   Read surface:
#       getOne(locationId)               -> dict | None
#       getAttributesByLocation(locId)   -> list[dict]
#
#   Write surface (sort-order actions):
#       handleMoveUp(selected, userId=None, ...)   -> dict | None
#       handleMoveDown(selected, userId=None, ...) -> dict | None
#
#       On success the move handlers return
#           {"tree": [...], "selectedPath": "0/0/1", "selected": {...}}
#       so the view can write all three view.custom props atomically.
#       The Tree component's bidirectional writeback to view.custom.selected
#       does not fire reliably when items are replaced programmatically,
#       so the caller pushes the new entity dict explicitly.
#
#   Remaining write-side (add / update / deprecate / setAttribute) is
#   still out of scope here.
#
# Layer:
#   View -> BlueRidge.Location.Location (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#        -> BlueRidge.Common.Ui.notifyResult
#        -> BlueRidge.Location.Tree.buildTree / findPathById / getNodeData
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-12 - 1.0 - Initial read-only version
#   2026-05-13 - 1.1 - Added handleMoveUp / handleMoveDown via Common.Action
#   2026-05-13 - 1.2 - Move handlers return {tree, selectedPath} for re-anchor
#   2026-05-13 - 1.3 - Return also includes "selected" (entity dict)
#   2026-05-14 - 1.4 - Rename get -> getOne; route through Common.Db.*
#                      and Common.Ui.notifyResult (Common.Action removed);
#                      drop local _rowsToDicts; replace per-module logger;
#                      strip debug `print ds`; NQ params camelCased.
# =============================================================================


def getOne(locationId):
    """
    Returns a single Location row by Id, joined to its type-definition /
    type names. Result is a dict with the fields the PlantHierarchy detail
    panel binds against, plus the raw DB columns for any future write path.

    Args:
        locationId (long): PK of the Location to retrieve. None / 0 -> None.

    Returns:
        dict or None.

    Result keys:
        id, code, name, description, sortOrder, parentLocationId,
        locationTypeDefinitionId, typeBadge, schemaName, parent,
        icon, deprecatedAt.
    """
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    if locationId is None or locationId == 0:
        return None

    r = BlueRidge.Common.Db.execOne("location/Get", {"id": locationId})
    if not r:
        return None

    typeBadge  = "%s • %s" % (r.get("LocationTypeName"),
                                   r.get("LocationTypeDefinitionName"))
    schemaName = r.get("LocationTypeDefinitionName") or ""

    return {
        "id":                       r.get("Id"),
        "code":                     r.get("Code"),
        "name":                     r.get("Name"),
        "description":              r.get("Description"),
        "sortOrder":                r.get("SortOrder"),
        "parentLocationId":         r.get("ParentLocationId"),
        "locationTypeDefinitionId": r.get("LocationTypeDefinitionId"),
        "typeBadge":                typeBadge,
        "schemaName":               schemaName,
        "parent":                   None,  # filled by caller from tree if needed
        "icon":                     r.get("LocationTypeDefinitionIcon"),
        "deprecatedAt":             r.get("DeprecatedAt"),
    }


def getAttributesByLocation(locationId):
    """
    Returns all attribute values for a Location, ordered by definition
    SortOrder ASC. Shape matches the BlueRidge/Components/AttributeRow
    embedded-view params (index, totalRows, name, value, dataType, uom,
    required), plus id / definitionId for future write path.

    Args:
        locationId (long): FK to Location. None / 0 -> [].

    Returns:
        list[dict] -- empty list if no attributes (or no selection).
    """
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    if locationId is None or locationId == 0:
        return []
    rows = BlueRidge.Common.Db.execList(
        "location/getLocationAttributes",
        {"locationId": locationId},
    )
    n = len(rows)
    return [
        {
            "index":        i,
            "totalRows":    n,
            "id":           r.get("Id"),
            "definitionId": r.get("LocationAttributeDefinitionId"),
            "name":         r.get("AttributeName") or "",
            "value":        r.get("AttributeValue") or "",
            "dataType":     r.get("DataType") or "",
            "uom":          r.get("Uom") or "",
            "required":     bool(r.get("IsRequired")),
        }
        for i, r in enumerate(rows)
    ]


def handleMoveUp(selected, userId=None,
                 treeRootId=1, treeExpandDepth=2, treeDefaultIcon="mpp/factory"):
    """
    Move a Location up one position among its active siblings, then return
    the freshly-rebuilt tree and the entity's new path so the view can
    re-anchor its selection on the entity rather than the (now-stale) path.

    Args:
        selected (dict): The view's selected-location dict. Must carry
                         keys 'id' and 'name'.
        userId (long):   Override for the AppUser.Id attribution. Defaults
                         to BlueRidge.Common.Util._currentAppUserId().
        treeRootId,
        treeExpandDepth,
        treeDefaultIcon: buildTree args used for the post-mutation rebuild.

    Returns:
        dict or None:
            On success: {"tree": [...], "selectedPath": "0/0/0", "selected": {...}}
                        for the view to apply atomically.
            On failure: None -- toast already fired by Common.Ui.notifyResult.
    """
    BlueRidge.Common.Util.log("selected=%s" % selected)
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    result = BlueRidge.Common.Db.execMutation(
        "location/MoveSortOrderUp",
        {"locationId": selected.get("id"), "userId": userId},
    )
    BlueRidge.Common.Ui.notifyResult(
        result,
        successTitle = "Moved up",
        successMsg   = "Reordered " + (selected.get("name") or ""),
        errorTitle   = "Move failed",
    )
    if not result.get("Status"):
        return None
    return _refreshAfterMutation(selected.get("id"),
                                 treeRootId, treeExpandDepth, treeDefaultIcon)


def handleMoveDown(selected, userId=None,
                   treeRootId=1, treeExpandDepth=2, treeDefaultIcon="mpp/factory"):
    """
    Move a Location down one position among its active siblings. Sibling
    of handleMoveUp; see that function for argument / return semantics.
    """
    BlueRidge.Common.Util.log("selected=%s" % selected)
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    result = BlueRidge.Common.Db.execMutation(
        "location/MoveSortOrderDown",
        {"locationId": selected.get("id"), "userId": userId},
    )
    BlueRidge.Common.Ui.notifyResult(
        result,
        successTitle = "Moved down",
        successMsg   = "Reordered " + (selected.get("name") or ""),
        errorTitle   = "Move failed",
    )
    if not result.get("Status"):
        return None
    return _refreshAfterMutation(selected.get("id"),
                                 treeRootId, treeExpandDepth, treeDefaultIcon)


def _refreshAfterMutation(targetId, rootId, expandDepth, defaultIcon):
    """Re-build the location tree post-mutation, find the new path for the
       given location id, look up the entity's fresh data at that path.

       Returns {"tree": [...], "selectedPath": str|None, "selected": dict|None}.

       The view applies all three writes (custom.tree, custom.selectedPath,
       custom.selected) so the tree, the selection cursor, and the Location
       Details panel stay aligned. The selected dict is the source of truth
       for the deep bindings (sortOrder, name, code, ...) -- the Tree
       component's bidirectional writeback to custom.selected does not fire
       reliably on programmatic items updates, so we push it directly."""
    items       = BlueRidge.Location.Tree.buildTree(rootId, expandDepth, defaultIcon)
    newPath     = BlueRidge.Location.Tree.findPathById(items, targetId)
    newSelected = BlueRidge.Location.Tree.getNodeData(items, newPath)
    return {"tree": items, "selectedPath": newPath, "selected": newSelected}
