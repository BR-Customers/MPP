# =============================================================================
# Project Library:  BlueRidge.Location.Location
#
# Author:           Blue Ridge Automation
# Created:          2026-05-12
# Version:          1.0
#
# Description:
#   Read-side entity-script for Location.Location and its attribute values.
#   Wraps the location/Get and location/AttributesByLocation named queries,
#   shaping datasets into UI-friendly list[dict] / dict results.
#
#   Write-side (add / update / deprecate / moveUp / moveDown / setAttribute)
#   is intentionally out of scope for the Phase 1 read-only slice — those
#   will be added with the JSON-payload save proc planned for Phase 2.
#
# Layer:
#   View -> BlueRidge.Location.Location (this module)
#        -> system.db.execQuery (Ignition NQ engine)
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-12 - 1.0 - Initial read-only version (get, getAttributesByLocation)
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
