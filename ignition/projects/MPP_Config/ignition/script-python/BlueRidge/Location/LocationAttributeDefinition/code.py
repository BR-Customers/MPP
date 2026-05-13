# =============================================================================
# Project Library:  BlueRidge.Location.LocationAttributeDefinition
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.0
#
# Description:
#   Read-side entity-script for Location.LocationAttributeDefinition.
#   Returns the attribute schema (definition rows) for a given
#   LocationTypeDefinition.
#
#   Write-side CRUD is NOT here — it lives on the bundled
#   Location.LocationTypeDefinition.handleSaveAll path, which reconciles
#   the parent definition and all its attribute-definition children in
#   one atomic transaction. Stand-alone Create/Update/Deprecate/MoveUp/
#   MoveDown procs exist in SQL and have their own tests, but this UI's
#   flow doesn't call them.
#
# Public surface:
#   listByDefinition(definitionId) -> list[dict]
#
# Layer:
#   View -> BlueRidge.Location.LocationAttributeDefinition (this module)
#        -> system.db.execQuery (Ignition NQ engine)
#
# Change Log:
#   2026-05-13 - 1.0 - Initial version
# =============================================================================

logger = system.util.getLogger("BlueRidge.Location.LocationAttributeDefinition")


def _rowsToDicts(ds):
    """Ignition Dataset -> list of {columnName: value} dicts."""
    if ds is None or ds.getRowCount() == 0:
        return []
    headers = list(ds.getColumnNames())
    return [dict(zip(headers, row)) for row in ds]


def listByDefinition(definitionId):
    """
    Returns all active LocationAttributeDefinition rows for a given
    LocationTypeDefinition, ordered by SortOrder ASC. Shape matches the
    columns Location.LocationAttributeDefinition_ListByDefinition emits:
    Id, LocationTypeDefinitionId, AttributeName, DataType, IsRequired,
    DefaultValue, Uom, SortOrder, Description, CreatedAt, DeprecatedAt.

    On DB / NQ failure, fires an error toast and returns [].

    Args:
        definitionId (long): LocationTypeDefinition.Id. None / 0 -> [].

    Returns:
        list[dict]: empty when not found, no children, null/zero input,
                    or on failure.
    """
    if definitionId is None or definitionId == 0:
        return []
    try:
        ds = system.db.execQuery("location/LocationAttributeDefinition_ListByDefinition",
                                 {"LocationTypeDefinitionId": definitionId})
        return _rowsToDicts(ds)
    except Exception as e:
        logger.errorf("listByDefinition(%s) failed: %s", definitionId, str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load attributes",
            "Definition " + str(definitionId) + ": " + str(e),
            "error",
        )
        return []
