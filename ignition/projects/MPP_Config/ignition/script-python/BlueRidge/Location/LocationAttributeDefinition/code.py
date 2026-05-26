# =============================================================================
# Project Library:  BlueRidge.Location.LocationAttributeDefinition
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.1
#
# Description:
#   Read-side entity-script for Location.LocationAttributeDefinition.
#   Returns the attribute schema (definition rows) for a given
#   LocationTypeDefinition.
#
#   Write-side CRUD is NOT here -- it lives on the bundled
#   Location.LocationTypeDefinition.saveAll path, which reconciles the
#   parent definition and all its attribute-definition children in one
#   atomic transaction. Stand-alone Create/Update/Deprecate/MoveUp/
#   MoveDown procs exist in SQL and have their own tests, but this UI's
#   flow does not call them.
#
# Public surface:
#   getAll(definitionId) -> list[dict]
#
# Layer:
#   View -> BlueRidge.Location.LocationAttributeDefinition (this module)
#        -> BlueRidge.Common.Db.execList
#
# Change Log:
#   2026-05-13 - 1.0 - Initial version (listByDefinition + system.db direct)
#   2026-05-14 - 1.1 - Rename listByDefinition -> getAll; route through
#                      Common.Db.execList; drop local _rowsToDicts;
#                      replace per-module logger with Common.Util.log;
#                      NQ params camelCased.
# =============================================================================


def getAll(definitionId):
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
    BlueRidge.Common.Util.log("definitionId=%s" % definitionId)
    if definitionId is None or definitionId == 0:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "location/LocationAttributeDefinition_ListByDefinition",
            {"locationTypeDefinitionId": definitionId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll(%s) failed: %s" % (definitionId, str(e)))
        BlueRidge.Common.Notify.toast(
            "Could not load attributes",
            "Definition " + str(definitionId) + ": " + str(e),
            "error",
        )
        return []
