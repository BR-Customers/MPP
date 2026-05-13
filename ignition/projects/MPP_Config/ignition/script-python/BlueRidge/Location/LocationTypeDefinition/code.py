# =============================================================================
# Project Library:  BlueRidge.Location.LocationTypeDefinition
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.0
#
# Description:
#   Entity-script for Location.LocationTypeDefinition. Provides the read
#   surface for the LocationTypeEditor popup view and the two write
#   action handlers (save / deprecate).
#
#   The save action wraps the bundled SQL proc
#   Location.LocationTypeDefinition_SaveAll which atomically persists
#   the definition meta AND reconciles its child LocationAttributeDefinition
#   rows in one transaction. On success the handler also refreshes the
#   parent view's chip list (definitions for the tier) and the bottom
#   table (attributes for the saved definition) so the UI lands on a
#   coherent post-save state in one atomic write.
#
#   The deprecate action wraps Location.LocationTypeDefinition_Deprecate
#   which soft-deletes the definition and cascades to all active children.
#
# Public surface:
#   listByType(locationTypeId)           -> list[dict]
#   handleSaveAll(meta, attributes, userId=None)  -> dict | None
#   handleDeprecate(definitionId, userId=None)    -> dict | None
#
# Layer:
#   View -> BlueRidge.Location.LocationTypeDefinition (this module)
#        -> BlueRidge.Common.Action.runMutation  (status-row + toast wrapper)
#        -> BlueRidge.Location.LocationAttributeDefinition.listByDefinition
#        -> system.db.execQuery (Ignition NQ engine)
#
# Change Log:
#   2026-05-13 - 1.0 - Initial version
# =============================================================================

logger = system.util.getLogger("BlueRidge.Location.LocationTypeDefinition")


def _rowsToDicts(ds):
    """Ignition Dataset -> list of {columnName: value} dicts."""
    if ds is None or ds.getRowCount() == 0:
        return []
    headers = list(ds.getColumnNames())
    return [dict(zip(headers, row)) for row in ds]


def emptyAttributeRow():
    """Returns a blank attribute-row dict suitable for appending to
       view.custom.attributesDraft when the user clicks +Add Attribute."""
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
    """Returns a blank meta dict suitable for view.custom.meta when the
       user clicks +Add Definition. LocationTypeId is the currently
       selected tier so the new definition is created at the right tier."""
    return {
        "Id":             None,
        "LocationTypeId": locationTypeId,
        "Code":           "",
        "Name":           "",
        "Icon":           "",
        "Description":    "",
    }


def metaFromDefinition(definition):
    """Project a LocationTypeDefinition dict (as returned by listByType)
       into the meta shape used by view.custom.meta. Pulls only the fields
       the SaveAll proc accepts."""
    if not definition:
        return None
    return {
        "Id":             definition.get("Id"),
        "LocationTypeId": definition.get("LocationTypeId"),
        "Code":           definition.get("Code"),
        "Name":           definition.get("Name"),
        "Icon":           definition.get("Icon"),
        "Description":    definition.get("Description"),
    }


def listByType(locationTypeId):
    """
    Returns all active LocationTypeDefinition rows for a given tier
    (LocationType), ordered by HierarchyLevel then Code. Drives the
    definitions flex-repeater inside the LocationTypeEditor popup.

    On DB / NQ failure, fires an error toast and returns []. Empty result
    is distinguishable from failure only via the toast + gateway log.

    Args:
        locationTypeId (long): LocationType.Id (NULL/0 returns []).

    Returns:
        list[dict]: rows from Location.LocationTypeDefinition_List filtered
                    to that tier and to active definitions only. Columns:
                    Id, LocationTypeId, LocationTypeName, Code, Name,
                    Description, Icon, CreatedAt, DeprecatedAt.
                    Empty list on failure.
    """
    if locationTypeId is None or locationTypeId == 0:
        return []
    try:
        ds = system.db.execQuery("location/LocationTypeDefinition_List",
                                 {"LocationTypeId": locationTypeId})
        return _rowsToDicts(ds)
    except Exception as e:
        logger.errorf("listByType(%s) failed: %s", locationTypeId, str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load definitions",
            "Tier " + str(locationTypeId) + ": " + str(e),
            "error",
        )
        return []


def handleSaveAll(meta, attributes, userId=None):
    """
    Bundled save: persist the LocationTypeDefinition meta AND its full
    attribute schema in one atomic call, then return the refreshed UI
    state for the view to apply.

    Args:
        meta (dict): Required keys per save mode.
            Create (no Id): {LocationTypeId, Code, Name, Icon, Description}
            Update (Id):    {Id, LocationTypeId, Code, Name, Icon, Description}
                            (Code + LocationTypeId must match the existing row;
                             they're immutable post-create. Mismatched values
                             come back as a Status=0 from the proc with a
                             friendly Message.)
        attributes (list[dict]): Desired-state list of attribute rows. Each:
            {Id: long|None, AttributeName, DataType, IsRequired, DefaultValue,
             Uom, Description}
            SortOrder is derived from the array index (1-based).
        userId (long): Override for AppUser.Id attribution; defaults to
                       BlueRidge.Common.Session.getCurrentUserId().

    Returns:
        dict or None:
            On success: {
                "NewId":       <long>,           # the saved definition's Id
                "definitions": list[dict],       # refreshed chip list for the tier
                "attributes":  list[dict],       # refreshed bottom-table for the def
            }
            On validation failure or exception: None. Toast already fired
            by Common.Action.runMutation; view leaves state alone.
    """
    if userId is None:
        userId = BlueRidge.Common.Session.getCurrentUserId()

    isCreate = meta.get("Id") is None
    attrsJson = system.util.jsonEncode(attributes or [])

    successTitle = "Created definition" if isCreate else "Saved definition"
    successMsg   = (meta.get("Name") or "")

    result = BlueRidge.Common.Action.runMutation(
        "location/LocationTypeDefinition_SaveAll",
        {
            "Id":              meta.get("Id"),
            "LocationTypeId":  meta.get("LocationTypeId"),
            "Code":            meta.get("Code"),
            "Name":            meta.get("Name"),
            "Icon":            meta.get("Icon"),
            "Description":     meta.get("Description"),
            "AppUserId":       userId,
            "AttributesJson":  attrsJson,
        },
        successTitle = successTitle,
        successMsg   = successMsg,
        errorTitle   = "Save failed",
    )
    if not result:
        return None

    newId = result.get("NewId")
    refreshedDefinitions = listByType(meta.get("LocationTypeId"))
    refreshedAttributes  = BlueRidge.Location.LocationAttributeDefinition.listByDefinition(newId)

    return {
        "NewId":       newId,
        "definitions": refreshedDefinitions,
        "attributes":  refreshedAttributes,
    }


def handleDeprecate(definitionId, locationTypeId, userId=None):
    """
    Soft-delete a LocationTypeDefinition (with child cascade in the proc).
    On success, returns the refreshed chip list for the parent view to apply.

    Args:
        definitionId (long):  LocationTypeDefinition.Id to deprecate.
        locationTypeId (long): The current tier (so we can refresh the chip
                               list after the deprecate lands). Caller already
                               has this in view scope.
        userId (long):        Override; defaults to Common.Session.getCurrentUserId().

    Returns:
        dict or None:
            On success: {"definitions": list[dict]} -- chip list for the tier,
                        the deprecated definition removed.
            On failure: None (toast already fired).
    """
    if userId is None:
        userId = BlueRidge.Common.Session.getCurrentUserId()

    result = BlueRidge.Common.Action.runMutation(
        "location/LocationTypeDefinition_Deprecate",
        {
            "Id":        definitionId,
            "AppUserId": userId,
        },
        successTitle = "Deprecated",
        successMsg   = "Definition removed from active list",
        errorTitle   = "Deprecate failed",
    )
    if not result:
        return None

    return {"definitions": listByType(locationTypeId)}
