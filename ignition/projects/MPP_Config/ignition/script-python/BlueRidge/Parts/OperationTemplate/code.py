# =============================================================================
# Project Library:  BlueRidge.Parts.OperationTemplate
#
# Author:           Blue Ridge Automation
# Created:          2026-06-03
# Version:          1.0
#
# Description:
#   Read + mutation surface for the Operation Templates Config Tool screen.
#   Routes every DB call through BlueRidge.Common.Db.* helpers.
#
#   Lifecycle reminder: OperationTemplate has NO Draft/Published state.
#   Each (Code, VersionNumber) row is "live" the moment it's inserted.
#   CreateNewVersion clones an existing row into VersionNumber+1; the
#   parent stays active until Deprecate is called.
#
# Public surface:
#   search(filter)                       -> list[dict]  (grouped instances)
#   getOne(id)                           -> dict | None
#   getVersionsForCode(code)             -> [{version: <row>}, ...]
#   getFieldsForTemplate(templateId)     -> [{field: <row>}, ...]
#   getAreasForDropdown()                -> [{label, value}, ...]
#   getAvailableDataCollectionFields(templateId) -> [{label, value}, ...]
#   add(data)                            -> {Status, Message, NewId}
#   update(data)                         -> {Status, Message}
#   deprecate(id)                        -> {Status, Message}
#   createNewVersion(parentId)           -> {Status, Message, NewId}
#   addField(templateId, dcfId, isRequired) -> {Status, Message, NewId}
#   removeField(junctionId)              -> {Status, Message}
#
# Layer:
#   View -> BlueRidge.Parts.OperationTemplate (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-06-03 - 1.0 - Initial version.
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

def _toRailRow(meta):
    """Slim full OperationTemplate meta down to the TemplateRow shape consumed
    by the left-rail flex-repeater."""
    return {
        "id":            meta.get("Id"),
        "code":          meta.get("Code"),
        "name":          meta.get("Name"),
        "version":       meta.get("VersionNumber"),
        "area":          meta.get("AreaName"),
        "deprecated":    meta.get("DeprecatedAt") is not None,
    }


# -----------------------------------------------------------------------------
# List feeds
# -----------------------------------------------------------------------------

def getAllForList(includeDeprecated=False, areaLocationId=None):
    """Returns all OperationTemplate rows joined with AreaName. Empty list
    on failure (errors toast and log; we do not propagate)."""
    BlueRidge.Common.Util.log("includeDeprecated=%s areaLocationId=%s"
                              % (includeDeprecated, areaLocationId))
    try:
        return BlueRidge.Common.Db.execList(
            "parts/OperationTemplate_List",
            {
                "areaLocationId": areaLocationId,
                "activeOnly":     0 if includeDeprecated else 1,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAllForList failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load templates", str(e), "error")
        return []


def search(filter=None):
    """One-shot list-view feed mirroring BlueRidge.Quality.DefectCode.search.
    Runs the DB query + client-side searchText filter + grouping into a
    flat heterogeneous list of header + row instances:

        [
            {sectionHeader: {label: 'Die Cast'}},
            {templateRow:   {id, code, name, version, area, deprecated}},
            {templateRow:   {...}},
            {sectionHeader: {label: 'Trim Shop'}},
            ...
        ]

    The TemplateRow embedded view reads both params and conditionally
    renders header or row.

    Each (Code, VersionNumber) row appears, BUT the rail only shows the
    HIGHEST-VersionNumber active row per Code (versions are visible in
    the Version History sub-panel on the detail side).

    filter keys (all optional):
        searchText      string  -- case-insensitive substring on Code or Name
        areaLocationId  BIGINT  -- or None for All Areas
        includeDeprecated bool  -- default False
    """
    BlueRidge.Common.Util.log("filter=%s" % filter)
    f = _u(filter) or {}
    searchText        = (f.get("searchText") or "").strip().lower()
    areaLocationId    = f.get("areaLocationId")
    includeDeprecated = bool(f.get("includeDeprecated", False))

    rows = getAllForList(includeDeprecated, areaLocationId)

    # Keep only the highest-version row per Code (mockup pattern).
    latestByCode = {}
    for r in rows:
        code = r.get("Code")
        ver  = r.get("VersionNumber") or 0
        existing = latestByCode.get(code)
        if existing is None or (existing.get("VersionNumber") or 0) < ver:
            latestByCode[code] = r

    # Client-side searchText filter on Code or Name.
    visible = []
    for r in latestByCode.values():
        if searchText:
            code = (r.get("Code") or "").lower()
            name = (r.get("Name") or "").lower()
            if searchText not in code and searchText not in name:
                continue
        visible.append(r)

    # Group by AreaName (preserve a deterministic order: alpha by area).
    byArea = {}
    for r in visible:
        area = r.get("AreaName") or "(no area)"
        byArea.setdefault(area, []).append(r)

    instances = []
    for area in sorted(byArea.keys()):
        instances.append({"sectionHeader": {"label": area}, "templateRow": None})
        # Sort within area by Code.
        rowsInArea = sorted(byArea[area], key=lambda r: (r.get("Code") or ""))
        for r in rowsInArea:
            instances.append({"sectionHeader": None, "templateRow": _toRailRow(r)})
    return instances


def getOne(operationTemplateId):
    """Returns the full meta record for a single template, or None.
    Adds a derived 'deprecated' bool for view convenience."""
    operationTemplateId = _u(operationTemplateId)
    BlueRidge.Common.Util.log("id=%s" % operationTemplateId)
    if operationTemplateId is None:
        return None
    row = BlueRidge.Common.Db.execOne(
        "parts/OperationTemplate_Get",
        {"id": operationTemplateId},
    )
    if row is None:
        return None
    out = dict(row)
    out["deprecated"] = row.get("DeprecatedAt") is not None
    return out


def getVersionsForCode(code, includeDeprecated=True):
    """Returns all versions of a Code as a flat list, newest version first:
        [{Id, VersionNumber, Name, CreatedAt, Deprecated, IsActive}, ...]
    where Deprecated is true if DeprecatedAt is set, and IsActive is true
    for the highest-version non-deprecated row (the rail-visible one).

    Consumed by the Version Dropdown via a script-transform that formats
    labels like 'v3 -- Die Cast 5G0 (Active)'."""
    code = _u(code)
    BlueRidge.Common.Util.log("code=%s" % code)
    if not code:
        return []
    try:
        # Hit the full list with ActiveOnly=0 to include deprecated rows.
        rows = BlueRidge.Common.Db.execList(
            "parts/OperationTemplate_List",
            {"areaLocationId": None, "activeOnly": 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getVersionsForCode failed: %s" % str(e))
        return []

    matches = [r for r in rows if r.get("Code") == code]
    # Identify the rail-visible "active" row: highest version, not deprecated.
    activeId = None
    activeVer = -1
    for r in matches:
        if r.get("DeprecatedAt") is None:
            ver = r.get("VersionNumber") or 0
            if ver > activeVer:
                activeId = r.get("Id")
                activeVer = ver

    # Order newest version first.
    matches.sort(key=lambda r: r.get("VersionNumber") or 0, reverse=True)

    out = []
    for r in matches:
        if not includeDeprecated and r.get("DeprecatedAt") is not None:
            continue
        out.append({
            "Id":            r.get("Id"),
            "VersionNumber": r.get("VersionNumber"),
            "Name":          r.get("Name"),
            "CreatedAt":     r.get("CreatedAt"),
            "Deprecated":    r.get("DeprecatedAt") is not None,
            "IsActive":      r.get("Id") == activeId,
        })
    return out


def formatVersionDropdownOptions(versions, showDeprecated=False):
    """Maps the flat versions list to [{label, value}, ...] for the version
    dropdown on the Operation Templates detail panel. Mirrors the
    Routes/BOMs dropdown label convention: 'v3 -- Die Cast 5G0 (Active)'.

    Filters out deprecated versions unless showDeprecated is True."""
    versions = _u(versions) or []
    showDep  = bool(_u(showDeprecated))
    out = []
    for v in versions:
        if not showDep and v.get("Deprecated"):
            continue
        vnum = v.get("VersionNumber") or 0
        name = v.get("Name") or ""
        state = "Deprecated" if v.get("Deprecated") else "Active"
        label = "v%d -- %s (%s)" % (vnum, name, state)
        out.append({"label": label, "value": v.get("Id")})
    return out


def getFieldsForTemplate(operationTemplateId):
    """Flex-repeater instances for the Fields panel.
    Each instance is {'field': <row>}. Returns [] for missing template
    ids or load failures.

    Row shape consumed by FieldRow:
        Id, Code, Name, IsRequired
    """
    operationTemplateId = _u(operationTemplateId)
    BlueRidge.Common.Util.log("templateId=%s" % operationTemplateId)
    if operationTemplateId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/OperationTemplateField_ListByTemplate",
            {"operationTemplateId": operationTemplateId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getFieldsForTemplate failed: %s" % str(e))
        return []
    out = []
    for r in rows:
        out.append({
            "field": {
                "Id":         r.get("Id"),
                "Code":       r.get("DataCollectionFieldCode"),
                "Name":       r.get("DataCollectionFieldName"),
                "IsRequired": bool(r.get("IsRequired")),
            }
        })
    return out


# -----------------------------------------------------------------------------
# Dropdown lookups
# -----------------------------------------------------------------------------

def getAreasForDropdown():
    """Returns [{label, value}, ...] for the Area filter + Detail Area
    dropdowns. Value is the Area Location.Id (BIGINT)."""
    try:
        rows = BlueRidge.Location.Location.listByTier("Area")
    except Exception as e:
        BlueRidge.Common.Util.log("getAreasForDropdown failed: %s" % str(e))
        return []
    out = []
    for r in rows or []:
        if r.get("DeprecatedAt") is not None:
            continue
        out.append({"label": r.get("Name") or r.get("Code"), "value": r.get("Id")})
    return out


def getAvailableDataCollectionFields(operationTemplateId):
    """Returns [{label, value}, ...] for the Add-Field dropdown on the
    Fields panel. Filters out DCFs already attached to this template."""
    operationTemplateId = _u(operationTemplateId)
    try:
        allDcfs = BlueRidge.Common.Db.execList(
            "parts/DataCollectionField_List",
            {"includeDeprecated": 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAvailableDataCollectionFields failed: %s" % str(e))
        return []

    taken = set()
    if operationTemplateId is not None:
        for inst in getFieldsForTemplate(operationTemplateId):
            f = inst.get("field") or {}
            # The junction row carries the DCF Code -- compare against DCF rows' Code below.
            if f.get("Code"):
                taken.add(f.get("Code"))

    out = []
    for r in allDcfs or []:
        if r.get("Code") in taken:
            continue
        label = "%s - %s" % (r.get("Code") or "", r.get("Name") or "")
        out.append({"label": label, "value": r.get("Id")})
    return out


# -----------------------------------------------------------------------------
# Mutations
# -----------------------------------------------------------------------------

def add(data):
    """Insert a new OperationTemplate (version 1 of a new Code). data:
    {Code, Name, AreaLocationId, Description}.
    Returns {Status, Message, NewId}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)

    code = (data.get("Code") or "").strip()
    name = (data.get("Name") or "").strip()
    if not code:
        return {"Status": 0, "Message": "Code is required", "NewId": None}
    if not name:
        return {"Status": 0, "Message": "Name is required", "NewId": None}

    areaLocationId = data.get("AreaLocationId")
    if areaLocationId is None:
        return {"Status": 0,
                "Message": "Area is required",
                "NewId":   None}

    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplate_Create",
        {
            "code":           code,
            "name":           name,
            "areaLocationId": areaLocationId,
            "description":    data.get("Description"),
            "appUserId":      BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update an existing OperationTemplate. data: {Id, Name,
    AreaLocationId, Description}. Code + VersionNumber are immutable.
    Returns {Status, Message}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)

    templateId = data.get("Id")
    if templateId is None:
        return {"Status": 0, "Message": "Id is required for update"}

    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplate_Update",
        {
            "id":             templateId,
            "name":           data.get("Name"),
            "areaLocationId": data.get("AreaLocationId"),
            "description":    data.get("Description"),
            "appUserId":      BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(operationTemplateId):
    """Soft-delete. Returns {Status, Message}."""
    operationTemplateId = _u(operationTemplateId)
    BlueRidge.Common.Util.log("id=%s" % operationTemplateId)
    if operationTemplateId is None:
        return {"Status": 0, "Message": "id is required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplate_Deprecate",
        {
            "id":        operationTemplateId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def createNewVersion(parentOperationTemplateId):
    """Clone the parent template into VersionNumber+1, replicating all
    active OperationTemplateField rows. Returns {Status, Message, NewId}."""
    parentOperationTemplateId = _u(parentOperationTemplateId)
    BlueRidge.Common.Util.log("parentId=%s" % parentOperationTemplateId)
    if parentOperationTemplateId is None:
        return {"Status": 0, "Message": "parentOperationTemplateId is required", "NewId": None}
    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplate_CreateNewVersion",
        {
            "parentOperationTemplateId": parentOperationTemplateId,
            "appUserId":                 BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def addField(operationTemplateId, dataCollectionFieldId, isRequired=True):
    """Attach a DataCollectionField to this template. Returns
    {Status, Message, NewId}."""
    operationTemplateId   = _u(operationTemplateId)
    dataCollectionFieldId = _u(dataCollectionFieldId)
    isRequired            = bool(_u(isRequired))
    BlueRidge.Common.Util.log("templateId=%s dcfId=%s isRequired=%s"
                              % (operationTemplateId, dataCollectionFieldId, isRequired))
    if operationTemplateId is None or dataCollectionFieldId is None:
        return {"Status": 0,
                "Message": "templateId and dataCollectionFieldId are required",
                "NewId":   None}
    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplateField_Add",
        {
            "operationTemplateId":   operationTemplateId,
            "dataCollectionFieldId": dataCollectionFieldId,
            "isRequired":            1 if isRequired else 0,
            "appUserId":             BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def removeField(junctionId):
    """Soft-delete the junction row by its Id. Returns {Status, Message}."""
    junctionId = _u(junctionId)
    BlueRidge.Common.Util.log("junctionId=%s" % junctionId)
    if junctionId is None:
        return {"Status": 0, "Message": "junctionId is required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplateField_Remove",
        {
            "id":        junctionId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def setFieldRequired(junctionId, isRequired):
    """Flip the IsRequired flag on a junction row. Returns {Status, Message}."""
    junctionId = _u(junctionId)
    isRequired = bool(_u(isRequired))
    BlueRidge.Common.Util.log("junctionId=%s isRequired=%s"
                              % (junctionId, isRequired))
    if junctionId is None:
        return {"Status": 0, "Message": "junctionId is required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplateField_SetRequired",
        {
            "id":         junctionId,
            "isRequired": 1 if isRequired else 0,
            "appUserId":  BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def saveFieldsAll(operationTemplateId, rows):
    """Bundled SaveAll for the Fields panel. `rows` keys: id (BIGINT|None),
    dataCollectionFieldId (BIGINT), isRequired (bool).
    Returns {Status, Message, NewId}."""
    operationTemplateId = _u(operationTemplateId)
    BlueRidge.Common.Util.log("templateId=%s rows=%d" % (operationTemplateId, len(rows or [])))
    if operationTemplateId is None:
        return {"Status": 0, "Message": "No template selected.", "NewId": None}
    cleaned = []
    for r in (rows or []):
        r = _u(r) or {}
        cleaned.append({
            "Id":                    r.get("id"),
            "DataCollectionFieldId": r.get("dataCollectionFieldId"),
            "IsRequired":            bool(r.get("isRequired")),
        })
    return BlueRidge.Common.Db.execMutation(
        "parts/OperationTemplateField_SaveAll",
        {
            "operationTemplateId": operationTemplateId,
            "rowsJson":            BlueRidge.Common.Util.convertWrapperObjectToJson(cleaned),
            "appUserId":           BlueRidge.Common.Util._currentAppUserId(),
        },
    )
