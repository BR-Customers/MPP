# =============================================================================
# Project Library:  BlueRidge.Location.Location
#
# Author:           Blue Ridge Automation
# Created:          2026-05-12
# Version:          1.2
#
# Description:
#   Entity-script for Location.Location and its attribute values.
#
#   Read surface (Phase 1):
#       get(locationId)                  -> dict | None
#       getAttributesByLocation(locId)   -> list[dict]
#
#   Write surface (sort-order actions):
#       handleMoveUp(selected, userId=None, ...)   -> dict | None
#       handleMoveDown(selected, userId=None, ...) -> dict | None
#
#       On success the move handlers return {"tree": [...], "selectedPath": "..."} —
#       the freshly-rebuilt tree plus the new path of the moved entity. The
#       view event applies both to view.custom.tree and view.custom.selectedPath
#       so the visual selection follows the entity through the swap.
#
#   Remaining write-side (add / update / deprecate / setAttribute) is still
#   out of scope here — those arrive with the JSON-payload save proc planned
#   for Phase 2. They will follow the same refresh-and-reanchor return shape.
#
# Layer:
#   View -> BlueRidge.Location.Location (this module)
#        -> BlueRidge.Common.Action.runMutation  (status-row + toast wrapper)
#        -> BlueRidge.Location.Tree.buildTree    (post-mutation tree rebuild)
#        -> BlueRidge.Location.Tree.findPathById (entity -> path re-anchor)
#        -> system.db.execQuery                  (Ignition NQ engine)
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-12 - 1.0 - Initial read-only version (get, getAttributesByLocation)
#   2026-05-13 - 1.1 - Added handleMoveUp / handleMoveDown via Common.Action
#   2026-05-13 - 1.2 - Move handlers return {tree, selectedPath} so the view
#                      re-anchors selection on the entity instead of the path
#   2026-05-13 - 1.3 - Return also includes "selected" (the new entity dict)
#                      because Tree bidirectional writeback to view.custom.selected
#                      doesn't fire reliably on programmatic items updates
# =============================================================================

logger = system.util.getLogger("BlueRidge.Location.Location")


def _rowsToDicts(ds):
    """Ignition Dataset -> list of {columnName: value} dicts."""
    if ds is None or ds.getRowCount() == 0:
        return []
    headers = list(ds.getColumnNames())
    return [dict(zip(headers, row)) for row in ds]


def get(locationId):
    """
    Returns a single Location row by Id, joined to its type-definition / type
    names. Result is a dict with the fields the PlantHierarchy detail panel
    binds against, plus the raw DB columns for any future write path.

    Args:
        locationId (long): PK of the Location to retrieve. None / 0 -> None.

    Returns:
        dict or None.

    Result keys:
        id, code, name, description, sortOrder, parentLocationId,
        locationTypeDefinitionId, typeBadge, schemaName, parent,
        icon, deprecatedAt.
    """
    if locationId is None or locationId == 0:
        return None

    ds = system.db.runNamedQuery("location/Get", {"id": locationId})
    rows = _rowsToDicts(ds)
    if not rows:
        logger.debugf("get(%s) not found", locationId)
        return None

    r = rows[0]
    # Composite labels the view binds to directly.
    typeBadge   = "%s • %s" % (r.get("LocationTypeName"),
                                    r.get("LocationTypeDefinitionName"))
    schemaName  = r.get("LocationTypeDefinitionName") or ""

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
        list[dict] — empty list if no attributes (or no selection).
    """
    if locationId is None or locationId == 0:
        return []

#    ds = system.db.runNamedQuery("location/getLocationAttributes",
#                                 {"LocationId": locationId})
    ds = system.db.execQuery("location/getLocationAttributes", {"LocationID": locationId})
    print ds
    rows = _rowsToDicts(ds)
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

    Wraps the location/MoveSortOrderUp NQ via Common.Action so the standard
    toast feedback fires automatically based on the proc's status row.

    Args:
        selected (dict): The view's selected-location dict. Must carry
                         keys 'id' and 'name'.
        userId (long):   Override for the AppUser.Id attribution. Defaults
                         to BlueRidge.Common.Session.getCurrentUserId().
        treeRootId,
        treeExpandDepth,
        treeDefaultIcon: buildTree args used for the post-mutation rebuild.
                         Defaults match the PlantHierarchy view's binding;
                         override if a different view consumes this helper.

    Returns:
        dict or None:
            On success: {"tree": [...], "selectedPath": "0/0/0"} for the
                        view to apply atomically.
            On validation failure or exception: None — toast already fired,
                                                view leaves its state alone.
    """
    if userId is None:
        userId = BlueRidge.Common.Session.getCurrentUserId()
    success = BlueRidge.Common.Action.runMutation(
        "location/MoveSortOrderUp",
        {"LocationID": selected.get("id"), "UserID": userId},
        successTitle = "Moved up",
        successMsg   = "Reordered " + (selected.get("name") or ""),
        errorTitle   = "Move failed",
    )
    if not success:
        return None
    return _refreshAfterMutation(selected.get("id"),
                                 treeRootId, treeExpandDepth, treeDefaultIcon)


def handleMoveDown(selected, userId=None,
                   treeRootId=1, treeExpandDepth=2, treeDefaultIcon="mpp/factory"):
    """
    Move a Location down one position among its active siblings. Sibling
    of handleMoveUp; see that function for argument / return semantics.
    """
    if userId is None:
        userId = BlueRidge.Common.Session.getCurrentUserId()
    success = BlueRidge.Common.Action.runMutation(
        "location/MoveSortOrderDown",
        {"LocationID": selected.get("id"), "UserID": userId},
        successTitle = "Moved down",
        successMsg   = "Reordered " + (selected.get("name") or ""),
        errorTitle   = "Move failed",
    )
    if not success:
        return None
    return _refreshAfterMutation(selected.get("id"),
                                 treeRootId, treeExpandDepth, treeDefaultIcon)


def _refreshAfterMutation(targetId, rootId, expandDepth, defaultIcon):
    """Re-build the location tree post-mutation, find the new path for the
       given location id, and look up the entity's fresh data at that path.

       Returns {"tree": [...], "selectedPath": str|None, "selected": dict|None}.

       The view applies all three writes (custom.tree, custom.selectedPath,
       custom.selected) so the tree, the selection cursor, and the Location
       Details panel stay aligned. The selected dict is the source of truth
       for the deep bindings (sortOrder, name, code, ...) — the Tree
       component's bidirectional writeback to custom.selected doesn't fire
       reliably on programmatic items updates, so we push it directly."""
    items       = BlueRidge.Location.Tree.buildTree(rootId, expandDepth, defaultIcon)
    newPath     = BlueRidge.Location.Tree.findPathById(items, targetId)
    newSelected = BlueRidge.Location.Tree.getNodeData(items, newPath)
    return {"tree": items, "selectedPath": newPath, "selected": newSelected}
