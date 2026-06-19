# =============================================================================
# Project Library:  BlueRidge.Location.LocationTypeDefinition
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.2
#
# Description:
#   Entity-script for Location.LocationTypeDefinition. Provides the read
#   surface for the LocationTypeEditor popup view and two write action
#   handlers (saveAll / deprecate).
#
#   saveAll wraps Location.LocationTypeDefinition_SaveAll which atomically
#   persists the definition meta AND reconciles its child
#   LocationAttributeDefinition rows in one transaction. On success the
#   handler also refreshes the parent view's definitions list and the
#   bottom table so the UI lands on a coherent post-save state in one
#   atomic write.
#
#   deprecate wraps Location.LocationTypeDefinition_Deprecate which
#   soft-deletes the definition and cascades to all active children.
#
# Public surface:
#   getAll(locationTypeId)                  -> list[dict]
#   handleSaveAll(meta, attributes, userId=None)  -> dict | None
#   handleDeprecate(definitionId, locationTypeId, userId=None) -> dict | None
#
#   Plus factories used by view-side state initialization:
#     emptyMeta(locationTypeId)              -> dict
#     emptyAttributeRow()                    -> dict
#     metaFromDefinition(definition)         -> dict | None
#
# Layer:
#   View -> BlueRidge.Location.LocationTypeDefinition (this module)
#        -> BlueRidge.Common.Db.execList / execMutation
#        -> BlueRidge.Common.Ui.notifyResult
#        -> BlueRidge.Location.LocationAttributeDefinition.getAll
#
# Change Log:
#   2026-05-13 - 1.0 - Initial version (listByType, handleSaveAll,
#                      handleDeprecate via Common.Action.runMutation)
#   2026-05-14 - 1.1 - Rename listByType -> getAll; route mutations
#                      through explicit Common.Db.execMutation +
#                      Common.Ui.notifyResult (Common.Action is gone);
#                      drop local _rowsToDicts; replace per-module logger;
#                      NQ params camelCased.
#   2026-05-18 - 1.2 - metaFromDefinition coalesces nullable string fields
#                      (Icon, Description) from None -> '' so the bound
#                      text-fields don't render the literal "null" string;
#                      handleSaveAll inverts that for nullable fields ('' ->
#                      None) before forwarding to the proc, preserving the
#                      DB-side NULL-means-no-value semantic. emptyAttributeRow
#                      already returned '' for the same fields; no change
#                      there, only on the read + save round-trip.
# =============================================================================


def _emptyToNone(value):
    """Map '' -> None for nullable string columns. Pass-through for any
       non-empty value (including 0 / False, which are valid)."""
    if value is None:
        return None
    if isinstance(value, basestring) and value == "":
        return None
    return value


def _cleanAttributeRow(row):
    """Normalize a row before sending to SaveAll: empty strings -> None for
       the nullable string columns (DefaultValue, Uom, Description).
       Required columns (AttributeName, DataType) and BIT (IsRequired)
       pass through unchanged."""
    cleaned = dict(row)
    cleaned["DefaultValue"] = _emptyToNone(cleaned.get("DefaultValue"))
    cleaned["Uom"]          = _emptyToNone(cleaned.get("Uom"))
    cleaned["Description"]  = _emptyToNone(cleaned.get("Description"))
    return cleaned


def emptyAttributeRow():
    """Returns a blank attribute-row dict suitable for appending to
       view.custom.editDraft.attributes when the user clicks +Add Attribute."""
    return {
        "Id":            None,
        "AttributeName": "",
        "DataType":      "NVARCHAR",
        "IsRequired":    False,
        "DefaultValue":  "",
        "Uom":           "",
        "Description":   "",
    }


def emptyMeta(locationTypeId):
    """Returns a blank meta dict suitable for view.custom.editDraft.meta
       when the user clicks +Add Definition. LocationTypeId is the
       currently selected tier so the new definition is created at the
       right tier."""
    return {
        "Id":             None,
        "LocationTypeId": locationTypeId,
        "Code":           "",
        "Name":           "",
        "Icon":           "",
        "Description":    "",
    }


def metaFromDefinition(definition):
    """Project a LocationTypeDefinition dict (as returned by getAll)
       into the meta shape used by view.custom.editDraft.meta. Pulls
       only the fields the SaveAll proc accepts.

       Nullable string fields (Icon, Description) coalesce from None to
       '' so the bound text-field props.text doesn't render the literal
       string "null". The inverse '' -> None mapping happens in
       handleSaveAll on the way back to the proc."""
    if not definition:
        return None
    return {
        "Id":             definition.get("Id"),
        "LocationTypeId": definition.get("LocationTypeId"),
        "Code":           definition.get("Code"),
        "Name":           definition.get("Name"),
        "Icon":           definition.get("Icon")        or "",
        "Description":    definition.get("Description") or "",
    }


def getAll(locationTypeId):
    """
    Returns all active LocationTypeDefinition rows for a given tier
    (LocationType), ordered by HierarchyLevel then Code. Drives the
    definitions list inside the LocationTypeEditor popup.

    On DB / NQ failure, fires an error toast and returns [].

    Args:
        locationTypeId (long): LocationType.Id (NULL/0 returns []).

    Returns:
        list[dict]: rows from Location.LocationTypeDefinition_List filtered
                    to that tier and to active definitions only. Columns:
                    Id, LocationTypeId, LocationTypeName, Code, Name,
                    Description, Icon, CreatedAt, DeprecatedAt.
                    Empty list on failure.
    """
    BlueRidge.Common.Util.log("locationTypeId=%s" % locationTypeId)
    if locationTypeId is None or locationTypeId == 0:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "location/LocationTypeDefinition_List",
            {"locationTypeId": locationTypeId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll(%s) failed: %s" % (locationTypeId, str(e)))
        BlueRidge.Common.Notify.toast(
            "Could not load definitions",
            "Tier " + str(locationTypeId) + ": " + str(e),
            "error",
        )
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
	return BlueRidge.Common.Db.execList(
		"location/Location_List",
		{"filter": nameFilter}
	)

def handleSaveAll(meta, attributes, userId=None):
    """
    Bundled save: persist the LocationTypeDefinition meta AND its full
    attribute schema in one atomic call, then return the refreshed UI
    state for the view to apply.

    Args:
        meta (dict): Required keys per save mode.
            Create (no Id): {LocationTypeId, Code, Name, Icon, Description}
            Update (Id):    {Id, LocationTypeId, Code, Name, Icon, Description}
                            (Code + LocationTypeId must match the existing
                             row; they are immutable post-create. Mismatched
                             values come back as Status=0 from the proc with
                             a friendly Message.)
        attributes (list[dict]): Desired-state list of attribute rows. Each:
            {Id: long|None, AttributeName, DataType, IsRequired, DefaultValue,
             Uom, Description}
            SortOrder is derived from the array index (1-based).
        userId (long): Override for AppUser.Id attribution; defaults to
                       BlueRidge.Common.Util._currentAppUserId().

    Returns:
        dict or None:
            On success: {
                "NewId":       <long>,           # the saved definition's Id
                "definitions": list[dict],       # refreshed list for the tier
                "attributes":  list[dict],       # refreshed bottom table for the def
            }
            On validation failure or exception: None. Toast already fired
            by Common.Ui.notifyResult; caller leaves view state alone.
    """
    BlueRidge.Common.Util.log("meta=%s attributes(n)=%d" % (meta, len(attributes or [])))
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    isCreate     = meta.get("Id") is None
    cleanedAttrs = [_cleanAttributeRow(a) for a in (attributes or [])]
    attrsJson    = BlueRidge.Common.Util.convertWrapperObjectToJson(cleanedAttrs)
    successTitle = "Created definition" if isCreate else "Saved definition"
    successMsg   = meta.get("Name") or ""
	
    result = BlueRidge.Common.Db.execMutation(
        "location/LocationTypeDefinition_SaveAll",
        {
            "id":             meta.get("Id"),
            "locationTypeId": meta.get("LocationTypeId"),
            "code":           meta.get("Code"),
            "name":           meta.get("Name"),
            "icon":           _emptyToNone(meta.get("Icon")),
            "description":    _emptyToNone(meta.get("Description")),
            "appUserId":      userId,
            "attributesJson": attrsJson,
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
	
	return result
    newId = result.get("NewId")
    return {
        "NewId":       newId,
        "definitions": getAll(meta.get("LocationTypeId")),
        "attributes":  BlueRidge.Location.LocationAttributeDefinition.getAll(newId),
    }


def handleDeprecate(definitionId, locationTypeId, userId=None):
    """
    Soft-delete a LocationTypeDefinition (with child cascade in the proc).
    On success, returns the refreshed definitions list for the parent view
    to apply.

    Args:
        definitionId (long):  LocationTypeDefinition.Id to deprecate.
        locationTypeId (long): The current tier (so we can refresh the list
                               after the deprecate lands). Caller already
                               has this in view scope.
        userId (long):        Override; defaults to Common.Util._currentAppUserId().

    Returns:
        dict or None:
            On success: {"definitions": list[dict]} -- list for the tier,
                        deprecated definition removed.
            On failure: None (toast already fired).
    """
    BlueRidge.Common.Util.log("definitionId=%s" % definitionId)
    if userId is None:
        userId = BlueRidge.Common.Util._currentAppUserId()

    result = BlueRidge.Common.Db.execMutation(
        "location/LocationTypeDefinition_Deprecate",
        {
            "id":        definitionId,
            "appUserId": userId,
        },
    )
    BlueRidge.Common.Ui.notifyResult(
        result,
        successTitle = "Deprecated",
        successMsg   = "Definition removed from active list",
        errorTitle   = "Deprecate failed",
    )
    if not result.get("Status"):
        return None

    return {"definitions": getAll(locationTypeId)}
