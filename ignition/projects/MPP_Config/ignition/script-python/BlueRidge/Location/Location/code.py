# =============================================================================
# Project Library:  BlueRidge.Location.Location
#
# Author:           Blue Ridge Automation
# Created:          2026-05-12
# Version:          1.6
#
# Description:
#   Entity-script for Location.Location and its attribute values.
#
#   Read surface:
#       getOne(locationId)               -> dict | None
#       getAttributesByLocation(locId)   -> list[dict]
#       getAllAreas(includeAll=False)     -> list[{label, value}]
#       listByTier(tierCode)             -> list[dict]
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
#   Write surface (editor: Save + Deprecate + +Add Location):
#       emptyMeta(parentLocationId)                -> dict
#       metaFromLocation(location)                 -> dict
#       eligibleTypes(parentHierarchyLevel)        -> list[dict] (LocationType rows)
#       eligibleDefinitions(locationTypeId)        -> list[dict] (LocationTypeDefinition rows)
#       buildAttributesForType(defId, locationId=None) -> list[dict]
#       beginCreate(parentLocationId, parentHierarchyLevel, currentTree,
#                   rootId, expandDepth, defaultIcon)
#                                                  -> dict
#       handleSaveAll(meta, attributes, userId=None, ...) -> dict | None
#       handleDeprecate(locationId, userId=None, ...)     -> dict | None
#
#   handleSaveAll wraps the bundled Location.Location_SaveAll proc
#   (FDS-02-002a-compliant -- ParentLocationId + LocationTypeDefinitionId
#   immutable on update). On success returns the {tree, selectedPath,
#   selected} re-anchor payload via _refreshAfterMutation, which now
#   also expands the path to the saved row so newly-created deep nodes
#   are immediately visible.
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
#   2026-05-19 - 1.5 - Add getAllAreas(includeAll=False) for Area-tier dropdown;
#                      filters HierarchyLevel==2 client-side from GetTree flat result.
#   2026-05-19 - 1.6 - Add listByTier(tierCode) — generic tier-scoped read via
#                      location/Location_ListByTier NQ; first consumer: Defect
#                      Codes Area dropdown.
#   2026-05-18 - 1.4 - Editor write surface: emptyMeta, metaFromLocation,
#                      eligibleTypes, eligibleDefinitions, buildAttributesForType,
#                      beginCreate, handleSaveAll, handleDeprecate. Wraps
#                      the new Location.Location_SaveAll bundled proc.
#                      _refreshAfterMutation now also expands the path to
#                      the target so deep new nodes are visible.
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


def getAllAreas(includeAll=False):
    """Returns Area-tier Locations (HierarchyLevel == 2) as [{label, value}] for dropdowns.

       Seeded Areas: Die Cast / Machine Shop / Quality Control / Trim Shop. Downtime
       codes today only target DC/MS/TS but the dropdown surfaces all 4 -- callers
       can choose to ignore the empty-QC case. Client-side filter off GetTree's
       flat result is fine at this scale (full tree is ~20 rows).

       includeAll: prepends {label: 'All Areas', value: None}
         for filter sidebars; editor popup calls with default (False)."""
    BlueRidge.Common.Util.log("loading areas")
    rows = BlueRidge.Common.Db.execList("location/GetTree", {"rootId": 1}) or []
    areas = [r for r in rows if r.get("HierarchyLevel") == 2]
    out = [{"label": r.get("Name") or "", "value": r.get("Id")} for r in areas]
    if includeAll:
        out.insert(0, {"label": "All Areas", "value": None})
    return out


def listByTier(tierCode):
    """Returns active Locations whose LocationType.Code matches tierCode.
    Used by tier-scoped dropdowns (Area dropdown on Defect Codes,
    Cell dropdown on Tool Assignment, etc.).

    Args:
        tierCode (str): one of 'Enterprise', 'Site', 'Area', 'WorkCenter',
                         'Cell', 'Workstation' (per Location.LocationType seed).

    Returns:
        list[dict]: rows with Id, Code, Name, LocationTypeDefinitionId,
                    ParentLocationId, SortOrder, DeprecatedAt.
                    Empty if tierCode is unknown.
    """
    BlueRidge.Common.Util.log("tierCode=%s" % tierCode)
    if not tierCode:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "location/Location_ListByTier",
            {"tierCode": tierCode},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("listByTier failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load locations", str(e), "error")
        return []


def getFilteredList(nameFilter):
	"""
    Gets a list of all locations filtered by their names

    Args:
    	nameFilter (string): the text that the results must include

    Returns:
        A list of objects of location data.
    """
	BlueRidge.Common.Util.log("nameFilter=%s" % nameFilter)
	rows = BlueRidge.Common.Db.execList(
		"location/Location_List",
		{"filter": nameFilter}
	)
	
	nodes = []
	for r in rows:
		node = {"label": r.get("Name"), "icon": {"path":  r.get("Icon") or "mpp/factory", "color": "--mpp-text-primary", "style": {} } }
		nodes.append(node)
            
	return nodes



def _u(value):
    """Local shorthand for extractQualifiedValues. View-side bidirectional
       writebacks (Tree.props.selectionData[0].value especially) hand us
       Java Maps with BasicQualifiedValue-wrapped fields; raw int/long
       coercion fails on those. Every public handler here unwraps its
       inputs at entry so callers don't have to remember."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


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
    selected = _u(selected)
    BlueRidge.Common.Util.log("selected=%s" % selected)
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    result = BlueRidge.Common.Db.execMutation(
        "location/MoveSortOrderUp",
        {"locationId": selected.get("id"), "userId": userId},
    )
    # Removed for being unnecessary
    #BlueRidge.Common.Ui.notifyResult(
    #    result,
    #    successTitle = "Moved up",
    #    successMsg   = "Reordered " + (selected.get("name") or ""),
    #    errorTitle   = "Move failed",
    #)
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
    selected = _u(selected)
    BlueRidge.Common.Util.log("selected=%s" % selected)
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    result = BlueRidge.Common.Db.execMutation(
        "location/MoveSortOrderDown",
        {"locationId": selected.get("id"), "userId": userId},
    )
    # Removed for being unnecessary
    #BlueRidge.Common.Ui.notifyResult(
    #    result,
    #    successTitle = "Moved down",
    #    successMsg   = "Reordered " + (selected.get("name") or ""),
    #    errorTitle   = "Move failed",
    #)
    if not result.get("Status"):
        return None
    return _refreshAfterMutation(selected.get("id"),
                                 treeRootId, treeExpandDepth, treeDefaultIcon)


def _refreshAfterMutation(targetId, rootId, expandDepth, defaultIcon):
    """Re-build the location tree post-mutation, find the new path for the
       given location id, look up the entity's fresh data at that path.
       Expands every ancestor of the target so deep new nodes (e.g., a
       freshly-created Cell at depth 4 when default expandDepth=2) are
       visible without a separate operator click.

       Returns {"tree": [...], "selectedPath": str|None, "selected": dict|None}.

       The view applies all three writes (custom.tree, custom.selectedPath,
       custom.selected) so the tree, the selection cursor, and the Location
       Details panel stay aligned. The selected dict is the source of truth
       for the deep bindings (sortOrder, name, code, ...) -- the Tree
       component's bidirectional writeback to custom.selected does not fire
       reliably on programmatic items updates, so we push it directly."""
    items = BlueRidge.Location.Tree.buildTree(rootId, expandDepth, defaultIcon)
    BlueRidge.Location.Tree.expandToTarget(items, targetId)
    newPath     = BlueRidge.Location.Tree.findPathById(items, targetId)
    newSelected = BlueRidge.Location.Tree.getNodeData(items, newPath)
    return {"tree": items, "selectedPath": newPath, "selected": newSelected}


# ============================================================================
# Editor surface: Save / Deprecate / +Add Location
# ============================================================================


def emptyMeta(parentLocationId):
    """Blank meta dict for a new Location under the given parent.
       LocationTypeDefinitionId starts None; the operator picks it via the
       cascading Type -> Definition dropdowns. Empty strings (not None) for
       NVARCHAR fields so the bound text-fields don't render "null"."""
    return {
        "id":                       None,
        "parentLocationId":         parentLocationId,
        "locationTypeDefinitionId": None,
        "code":                     "",
        "name":                     "",
        "description":              "",
        "sortOrder":                None,
    }


def metaFromLocation(location):
    """Project a Location row (as getOne returns) into editor-meta shape.
       Nullable string fields coalesce None -> '' so bound text-fields don't
       render the literal string 'null'. Mirrors the LocationTypeDefinition
       editor's metaFromDefinition convention."""
    if not location:
        return None
    return {
        "id":                       location.get("id"),
        "parentLocationId":         location.get("parentLocationId"),
        "locationTypeDefinitionId": location.get("locationTypeDefinitionId"),
        "code":                     location.get("code") or "",
        "name":                     location.get("name") or "",
        "description":              location.get("description") or "",
        "sortOrder":                location.get("sortOrder"),
    }


def eligibleTypes(parentHierarchyLevel):
    """Return LocationType rows compatible with the given parent's
       HierarchyLevel -- those at level >= parent. Drives the first
       cascading dropdown on Location Details (create mode only).

       Args:
           parentHierarchyLevel (int): The selected parent's level.
                                       NULL -> empty list (no parent
                                       context, can't pick a child type).

       Returns:
           list[dict]: LocationType rows (Id, Code, Name, HierarchyLevel,
                       Description) filtered by HierarchyLevel >= parent's
                       and sorted by HierarchyLevel ASC.
    """
    if parentHierarchyLevel is None:
        return []
    types = BlueRidge.Location.LocationType.getAll() or []
    return [
        t for t in types
        if t.get("HierarchyLevel") is not None
        and t.get("HierarchyLevel") >= parentHierarchyLevel
    ]


def eligibleDefinitions(locationTypeId):
    """Return LocationTypeDefinition rows for the chosen Type. Thin call-site
       wrapper around LocationTypeDefinition.getAll(typeId) so the view binds
       through one stable name. Drives the second cascading dropdown."""
    if locationTypeId is None:
        return []
    return BlueRidge.Location.LocationTypeDefinition.getAll(locationTypeId) or []


def buildAttributesForType(locationTypeDefinitionId, locationId=None):
    """Build the editDraft.attributes list for a Location.

       Two modes:
       - existing Location (locationId provided): call the LEFT-JOIN proc
         LocationAttribute_GetByLocation which returns one row per active
         schema definition with the value column NULL when no value is
         persisted yet.
       - new Location (locationId None or 0): call
         LocationAttributeDefinition.getAll(defId) to get the schema,
         emit one editor row per definition with blank value.

       Output shape matches the editor's attribute-row binding:
           {id, definitionId, name, value, dataType, uom, required,
            description, sortOrder, defaultValue}

       index/totalRows are added by the view-side transform on the
       flex-repeater binding (same pattern AttributeRow uses today).
    """
    if locationTypeDefinitionId is None:
        return []

    if locationId is not None and locationId != 0:
        # Existing Location -- schema + values from the LEFT-JOIN proc
        rows = BlueRidge.Common.Db.execList(
            "location/getLocationAttributes",
            {"locationId": locationId},
        )
        return [
            {
                "id":           r.get("Id"),
                "definitionId": r.get("LocationAttributeDefinitionId"),
                "name":         r.get("AttributeName") or "",
                "value":        r.get("AttributeValue") or "",
                "dataType":     r.get("DataType") or "",
                "uom":          r.get("Uom") or "",
                "required":     bool(r.get("IsRequired")),
                "description":  r.get("Description") or "",
                "sortOrder":    r.get("SortOrder"),
                "defaultValue": r.get("DefaultValue") or "",
            }
            for r in (rows or [])
        ]

    # New Location -- pure schema, all values blank
    defs = BlueRidge.Location.LocationAttributeDefinition.getAll(
        locationTypeDefinitionId
    ) or []
    return [
        {
            "id":           None,
            "definitionId": d.get("Id"),
            "name":         d.get("AttributeName") or "",
            "value":        d.get("DefaultValue") or "",
            "dataType":     d.get("DataType") or "",
            "uom":          d.get("Uom") or "",
            "required":     bool(d.get("IsRequired")),
            "description":  d.get("Description") or "",
            "sortOrder":    d.get("SortOrder"),
            "defaultValue": d.get("DefaultValue") or "",
        }
        for d in defs
    ]


def beginCreate(parentLocationId, parentHierarchyLevel, currentTree,
                draftLabel="(new Location)", draftIcon="mpp/add_circle",
                treeRootId=1, treeExpandDepth=2, treeDefaultIcon="mpp/factory"):
    """Initialise create-mode state for +Add Location.

       Injects a synthetic draft node into the current tree under the
       selected parent, returns the path to it plus a blank editDraft.

       The view applies the returned dict's keys atomically:
           view.custom.tree         = result['tree']
           view.custom.draftPath    = result['draftPath']
           view.custom.selectedPath = result['draftPath']
           view.custom.selected     = {'meta': None, 'attributes': []}
           view.custom.editDraft    = {'meta': result['meta'],
                                       'attributes': []}
           view.custom.mode         = 'create'

       Note: parentHierarchyLevel is captured up front so the Type
       dropdown can filter without an extra DB round-trip.

       Args:
           parentLocationId (long):    The currently-selected Location.id.
           parentHierarchyLevel (int): Parent's HierarchyLevel.
           currentTree (list):         view.custom.tree at the moment of click.

       Returns:
           dict: {tree, draftPath, meta}. tree is mutated in place but
                 returned so the view writes it explicitly. meta carries
                 parentLocationId for the proc; locationTypeDefinitionId
                 starts None pending the operator's dropdown choice.
    """
    parentLocationId     = _u(parentLocationId)
    parentHierarchyLevel = _u(parentHierarchyLevel)
    currentTree          = _u(currentTree)
    BlueRidge.Common.Util.log(
        "parentLocationId=%s parentHierarchyLevel=%s"
        % (parentLocationId, parentHierarchyLevel)
    )
    if parentLocationId is None:
        BlueRidge.Common.Notify.toast(
            "Pick a parent first",
            "Select a Location in the tree, then click +Add Location.",
            "warning",
        )
        return None

    # Rebuild from DB instead of trusting view.custom.tree's read-back shape
    # -- Ignition coerces stored Python list/dicts to Java ArrayList/HashMap
    # at the binding boundary, and isinstance(node, dict) is False on
    # HashMaps so the injectDraftNode walk would skip everything. Building
    # fresh keeps the walk in pure-Python land.
    tree = BlueRidge.Location.Tree.buildTree(
        treeRootId, treeExpandDepth, treeDefaultIcon
    )
    # Make sure the path from root down to the parent is expanded so the
    # operator can see where the draft will land.
    BlueRidge.Location.Tree.expandToTarget(tree, parentLocationId)

    draftPath, found = BlueRidge.Location.Tree.injectDraftNode(
        tree, parentLocationId, draftLabel, draftIcon
    )
    if not found:
        BlueRidge.Common.Notify.toast(
            "Draft failed",
            "Parent " + str(parentLocationId) + " not found in tree.",
            "error",
        )
        return None

    return {
        "tree":       tree,
        "draftPath":  draftPath,
        "meta":       emptyMeta(parentLocationId),
    }


def handleSaveAll(meta, attributes, userId=None,
                  treeRootId=1, treeExpandDepth=2,
                  treeDefaultIcon="mpp/factory"):
    """Bundled save: persist a Location + its LocationAttribute values in
       one atomic proc call, then return the refreshed tree + path payload
       for the view to apply.

       Args:
           meta (dict): editDraft.meta (see emptyMeta / metaFromLocation
                        for the shape). On create, id is None and
                        locationTypeDefinitionId + parentLocationId must
                        be set by the operator.
           attributes (list[dict]): editDraft.attributes shape from
                        buildAttributesForType. Only id/definitionId/value
                        are forwarded to the proc; the rest are display.
           userId (long): Override; defaults to Common.Util._currentAppUserId().
           treeRootId / treeExpandDepth / treeDefaultIcon: buildTree args
                        for the post-save tree refresh.

       Returns:
           dict or None:
               Success: {NewId, tree, selectedPath, selected} -- the view
                        writes tree / selectedPath / selected atomically
                        and uses NewId to seed view.custom.editDraft.meta.id.
               Failure: None -- toast already fired by Common.Ui.notifyResult.
    """
    meta       = _u(meta) or {}
    attributes = _u(attributes) or []
    BlueRidge.Common.Util.log(
        "meta=%s attributes(n)=%d" % (meta, len(attributes or []))
    )
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    # Project editor attribute rows into the proc's expected JSON shape:
    # {LocationAttributeDefinitionId, Value}. Empty Value collapses to ""
    # on the wire; the proc's NULLIF maps that to NULL (= delete on update,
    # skip on create).
    procRows = []
    for a in (attributes or []):
        defId = a.get("definitionId")
        if defId is None:
            continue
        procRows.append({
            "LocationAttributeDefinitionId": defId,
            "Value":                         (a.get("value") if a.get("value") is not None else ""),
        })
    attrsJson = BlueRidge.Common.Util.convertWrapperObjectToJson(procRows)

    isCreate     = meta.get("id") is None
    successTitle = "Created Location" if isCreate else "Saved Location"
    successMsg   = meta.get("name") or ""

    result = BlueRidge.Common.Db.execMutation(
        "location/Location_SaveAll",
        {
            "id":                       meta.get("id"),
            "parentLocationId":         meta.get("parentLocationId"),
            "locationTypeDefinitionId": meta.get("locationTypeDefinitionId"),
            "name":                     meta.get("name"),
            "code":                     meta.get("code"),
            "description":              (meta.get("description") if meta.get("description") else None),
            "sortOrder":                meta.get("sortOrder"),
            "appUserId":                userId,
            "attributeValuesJson":      attrsJson,
        },
    )
    BlueRidge.Common.Ui.notifyResult(
        result,
        successTitle = successTitle,
        successMsg   = successMsg,
        errorTitle   = "Save failed",
    )
    if not result.get("Status"):
        return None

    newId = result.get("NewId")
    refresh = _refreshAfterMutation(
        newId, treeRootId, treeExpandDepth, treeDefaultIcon
    )
    # Baseline the editor against the just-saved row so the dirty
    # indicator clears and a follow-on edit starts from a clean slate.
    # SortOrder may have been auto-assigned on create; pull from the
    # refreshed selected dict.
    newMeta = dict(meta)
    newMeta["id"] = newId
    if refresh.get("selected"):
        newMeta["sortOrder"] = refresh["selected"].get("sortOrder")
    newAttrs = buildAttributesForType(newMeta.get("locationTypeDefinitionId"), newId)
    refresh["editDraft"] = {"meta": newMeta, "attributes": newAttrs}
    refresh["mode"]      = "update"
    refresh["draftPath"] = None
    refresh["dirty"]     = False
    refresh["NewId"]     = newId
    return refresh


def handleDeprecate(locationId, userId=None,
                    treeRootId=1, treeExpandDepth=2,
                    treeDefaultIcon="mpp/factory"):
    """Soft-delete a Location. On success returns the refreshed tree
       payload with selectedPath / selected cleared (the row is no longer
       in the active tree).

       FK guards (active children, referencing Items, etc.) are enforced
       inside Location.Location_Deprecate; failures come back as
       Status=0 with a friendly message and the toast surfaces it."""
    locationId = _u(locationId)
    BlueRidge.Common.Util.log("locationId=%s" % locationId)
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    # Capture the parent BEFORE deprecating, so we can re-anchor the
    # tree refresh on it (operator keeps context; selection lands on
    # the parent, not on nothing). Reading after deprecate would also
    # work -- the row still exists with DeprecatedAt set -- but reading
    # before keeps the logic readable.
    existing = getOne(locationId)
    parentId = existing.get("parentLocationId") if existing else None

    result = BlueRidge.Common.Db.execMutation(
        "location/Location_Deprecate",
        {"id": locationId, "userId": userId},
    )
    BlueRidge.Common.Ui.notifyResult(
        result,
        successTitle = "Deprecated",
        successMsg   = "Location removed from active tree",
        errorTitle   = "Deprecate failed",
    )
    if not result.get("Status"):
        return None

    # Re-anchor on the parent: rebuild tree, expand the path down to the
    # parent so it's visible, find its new path + data for the view to
    # write atomically. Mirrors the post-save refresh pattern, just
    # targeting the parent instead of the saved-row itself. Avoids
    # leaving the Tree component with a stale path (which manifests as
    # Component Error when items rebuild but selection points at a node
    # that's now gone).
    if parentId is not None:
        return _refreshAfterMutation(
            parentId, treeRootId, treeExpandDepth, treeDefaultIcon
        )

    # No parent (deprecating root, or row lookup failed) -- fall back
    # to a fresh tree with no selection.
    items = BlueRidge.Location.Tree.buildTree(
        treeRootId, treeExpandDepth, treeDefaultIcon
    )
    return {
        "tree":         items,
        "selectedPath": None,
        "selected":     None,
    }
