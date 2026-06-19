# =============================================================================
# Project Library:  BlueRidge.Parts.Tool
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          1.0
#
# Description:
#   Read + mutation surface for the Tools Configuration Tool screen.
#   Routes every DB call through BlueRidge.Common.Db.* helpers per the
#   three-layer rule (View -> Entity script -> Common.Db). Views never
#   call system.db.* directly.
#
# Public surface:
#   getAllForList(searchText, statusCode)        -> list[dict]
#       Slim ToolRow dicts for the list flex-repeater
#       (id, code, name, rank, deprecated).
#   getInstancesForFlexRepeater(searchText,
#                               statusCode,
#                               selectedId)      -> list[dict]
#   getOne(toolId)                               -> dict | None
#       Full meta record with display keys the DetailHeader binds to.
#   add(data)                                    -> {Status, Message, NewId}
#   update(data)                                 -> {Status, Message}
#   deprecate(toolId)                            -> {Status, Message}
#   getAttributeInstancesForTool(toolId)         -> list[dict]
#   getCavityInstancesForTool(toolId)            -> list[dict]
#   getAssignmentInstancesForTool(toolId)        -> list[dict]
#   getActiveAssignmentForTool(toolId)           -> dict | None
#
# Layer:
#   View -> BlueRidge.Parts.Tool (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#
# Lookup resolution notes:
#   - ToolTypeId  - resolved once via parts/ToolType_List, cached per call.
#                   add() defaults to the 'Die' ToolType.
#   - DieRankId   - resolved from DieRankCode via parts/DieRank_List.
#   - StatusCodeId- resolved from StatusCode via parts/ToolStatusCode_List.
#                   add() defaults to the 'Active' status.
#   Tool_Update does NOT accept StatusCodeId (status changes go through
#   Tools.Tool_UpdateStatus, a separate proc). update() therefore only
#   calls Tool_Update; if a StatusCode change is detected, it follows up
#   with a Tool_UpdateStatus mutation. The combined return reflects
#   whichever leg failed (Update leg first).
#
# Encoding:
#   Source is pure ASCII (no em-dashes; Jython 2 source decoding is
#   strict). Display strings use plain hyphens.
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


# -----------------------------------------------------------------------------
# Code-table lookups (read-mostly; resolved per-call -- the underlying NQs
# are cheap and ToolStatusCode / ToolType have <10 rows each).
# -----------------------------------------------------------------------------

def _lookupToolTypeIdByCode(code):
    """Resolve ToolType.Id from ToolType.Code (e.g. 'Die'). Returns None
    if not found."""
    rows = BlueRidge.Common.Db.execList("parts/ToolType_List", None) or []
    for r in rows:
        if r.get("Code") == code:
            return r.get("Id")
    return None


def _lookupStatusCodeIdByCode(code):
    """Resolve ToolStatusCode.Id from its Code (e.g. 'Active'). Returns
    None if not found."""
    rows = BlueRidge.Common.Db.execList("parts/ToolStatusCode_List", None) or []
    for r in rows:
        if r.get("Code") == code:
            return r.get("Id")
    return None


def _lookupDieRankIdByCode(code):
    """Resolve DieRank.Id from DieRank.Code (e.g. 'A'). Returns None for
    missing input or unmatched code."""
    if not code:
        return None
    rows = BlueRidge.Common.Db.execList(
        "parts/DieRank_List",
        {"includeDeprecated": 0},
    ) or []
    for r in rows:
        if r.get("Code") == code:
            return r.get("Id")
    return None


# -----------------------------------------------------------------------------
# Row shape helpers
# -----------------------------------------------------------------------------

def _toListRow(meta):
    """Slim full Tool meta down to the ToolRow shape consumed by the list
    flex-repeater (id, code, name, rank, deprecated)."""
    return {
        "id":         meta.get("Id"),
        "code":       meta.get("Code"),
        "name":       meta.get("Name"),
        "rank":       meta.get("DieRankCode"),
        "deprecated": meta.get("DeprecatedAt") is not None,
    }


# -----------------------------------------------------------------------------
# Tool list / detail reads
# -----------------------------------------------------------------------------

def getAllForList(searchText="", statusCode="All"):
    """Returns ToolRow-shaped rows (id/code/name/rank/deprecated), filtered
    server-side by StatusCode and client-side by searchText (Code or Name,
    case-insensitive substring)."""
    BlueRidge.Common.Util.log("searchText=%s statusCode=%s"
                              % (searchText, statusCode))
    searchText = _u(searchText) or ""
    statusCode = _u(statusCode) or "All"

    # StatusCode 'All' / None / empty means no server-side filter.
    statusParam = None
    if statusCode and statusCode != "All":
        statusParam = statusCode

    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/Tool_List",
            {
                "toolTypeId":        None,
                "statusCode":        statusParam,
                "includeDeprecated": 1,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAllForList failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load tools", str(e), "error")
        return []

    needle = (searchText or "").strip().lower()
    out = []
    for r in rows:
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        if needle and needle not in code.lower() and needle not in name.lower():
            continue
        out.append(_toListRow(r))
    return out


def getInstancesForFlexRepeater(searchText="", statusCode="All", selectedId=0):
    """Composes the flex-repeater instances payload for the tools list.
    Each instance is {'tool': <row>, 'selectedId': <int>} -- matches the
    BlueRidge.Parts.Item.getInstancesForFlexRepeater pattern."""
    searchText = _u(searchText) or ""
    statusCode = _u(statusCode) or "All"
    selectedId = _u(selectedId) or 0
    rows = getAllForList(searchText, statusCode)
    return [{"tool": r, "selectedId": selectedId} for r in rows]


def getOne(toolId):
    """Returns the full meta record for a single tool, or None.

    Adds a derived 'deprecated' bool alongside the raw DeprecatedAt
    timestamp the DetailHeader uses for chip styling."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return None
    row = BlueRidge.Common.Db.execOne("parts/Tool_Get", {"id": toolId})
    if row is None:
        return None
    row["deprecated"] = row.get("DeprecatedAt") is not None
    # Coerce nullable text to "" so the bidi-bound Description text-field
    # renders empty instead of the literal "null". update() converts the
    # empty string back to NULL on save, so the DB keeps its NULL semantics.
    if row.get("Description") is None:
        row["Description"] = ""
    return row


# -----------------------------------------------------------------------------
# Tool mutations
# -----------------------------------------------------------------------------

def add(data):
    """Insert a new Tool. data: {Code, Name, Description, DieRankCode, ...}.

    Resolution rules:
      * ToolTypeId defaults to the 'Die' ToolType -- the Tools screen is
        currently Die-only (the only ToolType with HasCavities=true and
        the only one the screen renders forms for).
      * StatusCodeId defaults to 'Active' for newly added Tools.
      * DieRankId is resolved from DieRankCode (nullable).

    Returns {Status, Message, NewId}.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)

    code = (data.get("Code") or "").strip()
    name = (data.get("Name") or "").strip()
    if not code:
        return {"Status": 0, "Message": "Code is required", "NewId": None}
    if not name:
        return {"Status": 0, "Message": "Name is required", "NewId": None}

    toolTypeId = _lookupToolTypeIdByCode("Die")
    if toolTypeId is None:
        return {"Status": 0,
                "Message": "ToolType 'Die' not found in DB",
                "NewId":   None}

    statusCodeId = _lookupStatusCodeIdByCode("Active")
    if statusCodeId is None:
        return {"Status": 0,
                "Message": "ToolStatusCode 'Active' not found in DB",
                "NewId":   None}

    dieRankId = _lookupDieRankIdByCode(data.get("DieRankCode"))
    description = (data.get("Description") or "").strip() or None

    return BlueRidge.Common.Db.execMutation(
        "parts/Tool_Create",
        {
            "toolTypeId":   toolTypeId,
            "code":         code,
            "name":         name,
            "description":  description,
            "dieRankId":    dieRankId,
            "statusCodeId": statusCodeId,
            "appUserId":    BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update an existing Tool. data: {Id, Name, Description, DieRankCode,
    StatusCode}. Code is immutable per the underlying proc.

    Tools.Tool_Update covers Name / Description / DieRankId only. Status
    transitions go through the separate Tools.Tool_UpdateStatus proc, so
    this function dispatches both in sequence when the caller passes a
    StatusCode. If the Update leg fails it short-circuits and returns
    that result; if the Status leg fails its message bubbles up.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)

    toolId = data.get("Id")
    if toolId is None:
        return {"Status": 0, "Message": "Id is required for update"}

    dieRankId = _lookupDieRankIdByCode(data.get("DieRankCode"))
    appUserId = BlueRidge.Common.Util._currentAppUserId()
    description = (data.get("Description") or "").strip() or None

    updateResult = BlueRidge.Common.Db.execMutation(
        "parts/Tool_Update",
        {
            "id":          toolId,
            "name":        data.get("Name"),
            "description": description,
            "dieRankId":   dieRankId,
            "appUserId":   appUserId,
        },
    )

    if not updateResult.get("Status"):
        return updateResult

    statusCode = data.get("StatusCode")
    if statusCode:
        statusResult = BlueRidge.Common.Db.execMutation(
            "parts/Tool_UpdateStatus",
            {
                "id":         toolId,
                "statusCode": statusCode,
                "appUserId":  appUserId,
            },
        )
        if not statusResult.get("Status"):
            return statusResult

    return updateResult


def deprecate(toolId):
    """Soft-delete. Returns {Status, Message}."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    return BlueRidge.Common.Db.execMutation(
        "parts/Tool_Deprecate",
        {
            "id":        toolId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


# -----------------------------------------------------------------------------
# Per-tab reads (Attributes / Cavities / Assignments)
# Each returns the flex-repeater instances shape the corresponding tab binds.
# -----------------------------------------------------------------------------

def getAttributeInstancesForTool(toolId):
    """Flex-repeater instances for the Attributes tab.
    Each instance is {'attr': <row>}. Returns [] for missing tool ids
    or load failures.

    Row shape consumed by AttributeRow:
        Id, AttrName, Value, DataType, ToolAttributeDefinitionId
    The proc emits AttributeName / AttributeCode -- AttrName is the
    repeater-facing alias and is set from AttributeName here."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolAttribute_ListByTool",
            {"toolId": toolId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAttributeInstancesForTool failed: %s" % str(e))
        return []

    out = []
    for r in rows:
        out.append({
            "attr": {
                "Id":                        r.get("Id"),
                "AttrName":                  r.get("AttributeName"),
                "Value":                     r.get("Value"),
                "DataType":                  r.get("DataType"),
                "ToolAttributeDefinitionId": r.get("ToolAttributeDefinitionId"),
            }
        })
    return out


def getCavityInstancesForTool(toolId):
    """Flex-repeater instances for the Cavities tab.
    Each instance is {'cavity': <row>}. Returns [] for missing tool ids
    or load failures.

    Row shape consumed by CavityRow:
        Id, Number, StatusCode, Description
    Mapped from the proc's CavityNumber + StatusCode columns."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolCavity_ListByTool",
            {"toolId": toolId, "includeDeprecated": 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getCavityInstancesForTool failed: %s" % str(e))
        return []

    out = []
    for r in rows:
        out.append({
            "cavity": {
                "Id":          r.get("Id"),
                "Number":      r.get("CavityNumber"),
                "StatusCode":  r.get("StatusCode"),
                "Description": r.get("Description"),
            }
        })
    return out


def getAssignmentInstancesForTool(toolId):
    """Flex-repeater instances for the Assignments tab history table.
    Each instance is {'assignment': <row>}. Returns [] for missing tool
    ids or load failures.

    Row shape consumed by AssignmentRow:
        Id, CellName, AssignedAt, ReleasedAt, AssignedByInitials,
        ReleasedByInitials, Notes, IsActive
    IsActive is derived (ReleasedAt is None). AssignedByInitials /
    ReleasedByInitials are not on the proc yet -- left as None until the
    join is added; the view shows a fallback string."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolAssignment_ListByTool",
            {"toolId": toolId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAssignmentInstancesForTool failed: %s" % str(e))
        return []

    out = []
    for r in rows:
        releasedAt = r.get("ReleasedAt")
        out.append({
            "assignment": {
                "Id":                 r.get("Id"),
                "CellName":           r.get("CellName"),
                "AssignedAt":         r.get("AssignedAt"),
                "ReleasedAt":         releasedAt,
                "AssignedByInitials": r.get("AssignedByInitials"),
                "ReleasedByInitials": r.get("ReleasedByInitials"),
                "Notes":              r.get("Notes"),
                "IsActive":           releasedAt is None,
            }
        })
    return out


def getActiveAssignmentForTool(toolId):
    """Returns the currently-active assignment dict for the tool, or None.
    Used to populate the 'Currently mounted on...' banner. Filters the
    full assignment list for IsActive=True (server-side ORDER BY DESC
    means the first match is the most recent active row)."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    instances = getAssignmentInstancesForTool(toolId)
    for inst in instances:
        row = inst.get("assignment") or {}
        if row.get("IsActive"):
            return dict(row)
    return None


def getActiveAssignmentForToolOrEmpty(toolId):
    """Binding-safe variant of getActiveAssignmentForTool: returns a fully
    shaped dict (never None) so nested-path bindings never Component-Error."""
    row = getActiveAssignmentForTool(toolId)
    if row is None:
        return {"Id": None, "CellName": "", "AssignedAt": None,
                "AssignedByInitials": "", "ReleasedByInitials": "",
                "Notes": "", "ReleasedAt": None, "IsActive": False}
    return row


# -----------------------------------------------------------------------------
# Dropdown lookups (for DetailHeader Status + DieRank dropdowns)
# -----------------------------------------------------------------------------

def getStatusCodesForDropdown():
    """Returns [{label, value}, ...] for the Tool Status dropdown.
    Value is the StatusCode string; label is the StatusName."""
    try:
        rows = BlueRidge.Common.Db.execList("parts/ToolStatusCode_List", None)
    except Exception as e:
        BlueRidge.Common.Util.log("getStatusCodesForDropdown failed: %s" % str(e))
        return []
    return [{"label": r.get("Name") or r.get("Code"), "value": r.get("Code")} for r in rows or []]


def getToolTypesForDropdown():
    """Returns [{label, value}, ...] for a Tool Type dropdown.
    Value is the ToolType.Code string."""
    try:
        rows = BlueRidge.Common.Db.execList("parts/ToolType_List", None)
    except Exception as e:
        BlueRidge.Common.Util.log("getToolTypesForDropdown failed: %s" % str(e))
        return []
    return [{"label": r.get("Name") or r.get("Code"), "value": r.get("Code")} for r in rows or []]


# -----------------------------------------------------------------------------
# Tools detail-tab objects (dirty-gating).
#   Mirrors BlueRidge.Parts.Item.itemMasterTabObjects: the parent Tools view
#   binds props.tabs to this so non-active tabs lock while a draft section is
#   dirty. Assignments is non-draft -- it never reports dirty, so it is only
#   ever disabled when ANOTHER tab is mid-edit (same rule as the rest).
# -----------------------------------------------------------------------------
_TOOL_TAB_LABELS = [
    ("attributes",  "Attributes"),
    ("cavities",    "Cavities"),
    ("assignments", "Assignments"),
]


def toolTabObjects(sectionDirty, activeTab):
    """Returns the 3 tab objects for the Tools detail ia.container.tab.

    - text:           label with leading bullet when its section is dirty
    - runWhileHidden: True (keep each embed's local editDraft across switches)
    - disabled:       True when any section is dirty AND this isn't the active
                      tab (locks navigation until the user saves or discards)

    sectionDirty: dict { section_key: bool } from view.custom.sectionDirty
    activeTab:    string section-key from view.custom.activeTab
    Assignments never reports dirty so it is excluded from anyDirty naturally.
    """
    d = _u(sectionDirty) or {}
    activeTab = _u(activeTab)
    anyDirty = any(d.get(k, False) for k, _ in _TOOL_TAB_LABELS)
    out = []
    for key, label in _TOOL_TAB_LABELS:
        out.append({
            "text":           (u"● " + label) if d.get(key, False) else label,
            "runWhileHidden": True,
            "disabled":       bool(anyDirty and key != activeTab),
        })
    return out


def addAttributeDefinition(toolTypeId, code, name, dataType, isRequired=False):
    """Insert a new ToolAttributeDefinition row scoped to a ToolType.
    Returns {Status, Message, NewId}."""
    toolTypeId = _u(toolTypeId)
    code       = (_u(code) or "").strip()
    name       = (_u(name) or "").strip()
    dataType   = (_u(dataType) or "").strip()
    isRequired = bool(_u(isRequired))
    BlueRidge.Common.Util.log("toolTypeId=%s code=%s dataType=%s"
                              % (toolTypeId, code, dataType))
    if toolTypeId is None:
        return {"Status": 0, "Message": "ToolTypeId is required", "NewId": None}
    if not code:
        return {"Status": 0, "Message": "Code is required", "NewId": None}
    if not name:
        return {"Status": 0, "Message": "Name is required", "NewId": None}
    # DataType is validated against the allowed set by
    # ToolAttributeDefinition_Create (the proc is authoritative); no Python
    # allowlist here per the "rules live in SQL" convention.
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolAttributeDefinition_Create",
        {
            "toolTypeId": toolTypeId,
            "code":       code,
            "name":       name,
            "dataType":   dataType,
            "isRequired": 1 if isRequired else 0,
            "appUserId":  BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def getAttributeDefinitionsForToolType(toolTypeId):
    """Returns [{label, value}, ...] for an Add-Attribute dropdown.
    Value is the ToolAttributeDefinition.Id (BIGINT); label is the
    AttributeName. Filters out attributes already deprecated."""
    toolTypeId = _u(toolTypeId)
    BlueRidge.Common.Util.log("toolTypeId=%s" % toolTypeId)
    if toolTypeId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolAttributeDefinition_ListByType",
            {"toolTypeId": toolTypeId, "includeDeprecated": 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAttributeDefinitionsForToolType failed: %s" % str(e))
        return []
    return [{"label": r.get("Name") or r.get("Code"), "value": r.get("Id")} for r in rows or []]


def getAttributeDefinitionOptions(toolId):
    """Available + already-present attribute definitions for a tool, each
    carrying its DataType so the row can pick a type-aware value input.

    Returns list[dict]: {value: <defId>, label: <name>, code, dataType}.
    The Attributes editor uses this to (a) populate the new-row Definition
    dropdown (filtering out defs already on the tool happens in the view)
    and (b) resolve DataType for existing rows."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return []
    toolTypeId = None
    row = BlueRidge.Common.Db.execOne("parts/Tool_Get", {"id": toolId})
    if row is not None:
        toolTypeId = row.get("ToolTypeId")
    if toolTypeId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolAttributeDefinition_ListByType",
            {"toolTypeId": toolTypeId, "includeDeprecated": 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAttributeDefinitionOptions failed: %s" % str(e))
        return []
    return [{"value": r.get("Id"),
             "label": r.get("Name") or r.get("Code"),
             "code":  r.get("Code"),
             "dataType": r.get("DataType")} for r in rows or []]


def getCellsForDropdown(toolId=None):
    """Returns [{label, value}, ...] for the Mount-to-Cell dropdown.
    Value is the Cell Location.Id (BIGINT); label is Name (Code).

    Filtered to cells the tool's ToolType can mount on, via
    parts/Tool_ListCompatibleCells (proc Tools.Tool_ListCompatibleCells).
    The compatibility rule lives in SQL: a tool type with a
    CompatibleLocationTypeDefinitionId restricts the list to that cell kind
    (Die -> Die Cast Machine); an unmapped tool type falls back to all
    Cell-tier Locations. Returns [] when no toolId is supplied (the proc
    needs the tool to resolve its type)."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/Tool_ListCompatibleCells",
            {"toolId": toolId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getCellsForDropdown failed: %s" % str(e))
        return []
    out = []
    for r in rows or []:
        if r.get("DeprecatedAt") is not None:
            continue
        name = r.get("Name") or ""
        code = r.get("Code") or ""
        label = ("%s (%s)" % (name, code)) if name and code else (name or code)
        out.append({"label": label, "value": r.get("Id")})
    return out


# -----------------------------------------------------------------------------
# Per-tab mutations (Cavity / Attribute / Assignment)
# -----------------------------------------------------------------------------

def createCavity(toolId, cavityNumber, description=None):
    """Insert a new ToolCavity. Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    cavityNumber = _u(cavityNumber)
    description = _u(description)
    BlueRidge.Common.Util.log("toolId=%s cavityNumber=%s" % (toolId, cavityNumber))
    if toolId is None:
        return {"Status": 0, "Message": "ToolId is required", "NewId": None}
    if cavityNumber is None:
        return {"Status": 0, "Message": "CavityNumber is required", "NewId": None}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolCavity_Create",
        {
            "toolId":       toolId,
            "cavityNumber": int(cavityNumber),
            "description":  description,
            "appUserId":    BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def updateCavityStatus(cavityId, statusCode):
    """Set the StatusCode on a ToolCavity (Active / Closed / Scrapped).
    Returns {Status, Message}."""
    cavityId = _u(cavityId)
    statusCode = _u(statusCode)
    BlueRidge.Common.Util.log("cavityId=%s statusCode=%s" % (cavityId, statusCode))
    if cavityId is None or not statusCode:
        return {"Status": 0, "Message": "cavityId and statusCode are required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolCavity_UpdateStatus",
        {
            "id":         cavityId,
            "statusCode": statusCode,
            "appUserId":  BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecateCavity(cavityId):
    """Soft-delete a ToolCavity. Returns {Status, Message}."""
    cavityId = _u(cavityId)
    BlueRidge.Common.Util.log("cavityId=%s" % cavityId)
    if cavityId is None:
        return {"Status": 0, "Message": "cavityId is required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolCavity_Deprecate",
        {
            "id":        cavityId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def upsertAttribute(toolId, defId, value):
    """Insert or update a ToolAttribute row. Returns {Status, Message}."""
    toolId = _u(toolId)
    defId  = _u(defId)
    value  = _u(value)
    BlueRidge.Common.Util.log("toolId=%s defId=%s value=%s"
                              % (toolId, defId, value))
    if toolId is None or defId is None:
        return {"Status": 0, "Message": "toolId and defId are required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolAttribute_Upsert",
        {
            "toolId":    toolId,
            "defId":     defId,
            "value":     "" if value is None else unicode(value),
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def removeAttribute(toolId, defId):
    """Remove a ToolAttribute row. Returns {Status, Message}."""
    toolId = _u(toolId)
    defId  = _u(defId)
    BlueRidge.Common.Util.log("toolId=%s defId=%s" % (toolId, defId))
    if toolId is None or defId is None:
        return {"Status": 0, "Message": "toolId and defId are required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolAttribute_Remove",
        {
            "toolId":    toolId,
            "defId":     defId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def saveAttributesAll(toolId, rows):
    """Bundled SaveAll for the Attributes section. `rows` is the editDraft
    rows list with keys: id (BIGINT|None), toolAttributeDefinitionId (BIGINT),
    value (string). Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s rows=%d" % (toolId, len(rows or [])))
    if toolId is None:
        return {"Status": 0, "Message": "No tool selected.", "NewId": None}
    cleaned = []
    for r in (rows or []):
        r = _u(r) or {}
        v = r.get("value")
        cleaned.append({
            "Id":                        r.get("id"),
            "ToolAttributeDefinitionId": r.get("toolAttributeDefinitionId"),
            "Value":                     u"" if v is None else unicode(v),
        })
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolAttribute_SaveAll",
        {
            "toolId":    toolId,
            "rowsJson":  BlueRidge.Common.Util.convertWrapperObjectToJson(cleaned),
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def saveCavitiesAll(toolId, rows):
    """Bundled SaveAll for the Cavities section. `rows` keys: id (BIGINT|None),
    cavityNumber (int), description (string|None), statusCode (str).
    Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s rows=%d" % (toolId, len(rows or [])))
    if toolId is None:
        return {"Status": 0, "Message": "No tool selected.", "NewId": None}
    cleaned = []
    for r in (rows or []):
        r = _u(r) or {}
        num = r.get("cavityNumber")
        cleaned.append({
            "Id":           r.get("id"),
            "CavityNumber": None if num is None else int(num),
            "Description":  r.get("description"),
            "StatusCode":   r.get("statusCode") or "Active",
        })
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolCavity_SaveAll",
        {
            "toolId":    toolId,
            "rowsJson":  BlueRidge.Common.Util.convertWrapperObjectToJson(cleaned),
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def assignToCell(toolId, cellLocationId, notes=None):
    """Open a ToolAssignment to the named cell. Proc enforces single-active
    invariant. Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    cellLocationId = _u(cellLocationId)
    notes = _u(notes)
    BlueRidge.Common.Util.log("toolId=%s cellLocationId=%s"
                              % (toolId, cellLocationId))
    if toolId is None or cellLocationId is None:
        return {"Status": 0,
                "Message": "toolId and cellLocationId are required",
                "NewId":   None}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolAssignment_Assign",
        {
            "toolId":         toolId,
            "cellLocationId": cellLocationId,
            "notes":          notes,
            "appUserId":      BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def releaseAssignment(toolId, notes=None):
    """Close the currently-active ToolAssignment for this tool.
    Returns {Status, Message}."""
    toolId = _u(toolId)
    notes  = _u(notes)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return {"Status": 0, "Message": "toolId is required"}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolAssignment_Release",
        {
            "toolId":    toolId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
            "notes":     notes,
        },
    )


# -----------------------------------------------------------------------------
# Die-cast operator station helpers (Phase 3 front-end)
# -----------------------------------------------------------------------------

def getCavitiesForDropdown(toolId):
    """Active cavities for the mounted tool, as [{label, value}] for the cavity
    dropdown (label = 'Cavity N', value = ToolCavity.Id). Empty list = no active
    cavities (the FE then enters free-entry / manual-cavity mode, D2). Wraps
    Tools.ToolCavity_ListActiveByTool."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("getCavitiesForDropdown toolId=%s" % toolId)
    if toolId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolCavity_ListActiveByTool", {"toolId": toolId})
    except Exception as e:
        BlueRidge.Common.Util.log("getCavitiesForDropdown failed: %s" % str(e))
        return []
    return [{"label": "Cavity %s" % r.get("CavityNumber"), "value": r.get("Id")}
            for r in (rows or [])]


def getMountedToolForCell(cellLocationId):
    """The Tool currently mounted on a Cell (or None). Drives the Die Cast Entry
    Tool auto-populate. Wraps Tools.ToolAssignment_ListActiveByCell (0 or 1 row)."""
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log("getMountedToolForCell cellLocationId=%s" % cellLocationId)
    if cellLocationId is None:
        return None
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ToolAssignment_ListActiveByCell", {"cellLocationId": cellLocationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getMountedToolForCell failed: %s" % str(e))
        return None
    return rows[0] if rows else None


def getMountedToolForCellOrEmpty(cellLocationId):
    """Binding-safe variant: a fully-shaped dict (never None) so the Tool card's
    nested-path bindings never Component-Error (pre-declare-bound-props rule). Shape
    mirrors Tools.ToolAssignment_ListActiveByCell's columns."""
    row = getMountedToolForCell(cellLocationId)
    if row is None:
        return {"Id": None, "ToolId": None, "ToolCode": "", "ToolName": "",
                "ToolTypeCode": "", "CellLocationId": None, "AssignedAt": None,
                "AssignedByUserId": None, "Notes": None}
    return row


# -----------------------------------------------------------------------------
# Cell Mount Card (mount-from-location, Plant Hierarchy) -- inverse of the
# Tool-side Assignments tab. See spec 2026-06-16-cell-mount-card-design.md.
# -----------------------------------------------------------------------------

def getCellMountContextOrEmpty(cellLocationId):
    """Single-row mount context for a Cell, for the Plant Hierarchy Cell Mount
    Card. Always a fully-shaped dict (never None) so the card's nested-path
    bindings never Component-Error (pre-declare-bound-props rule). Wraps
    Tools.ToolAssignment_GetCellContext. IsMountTarget is coerced to a bool;
    nullable text columns coerced to '' for clean binding render."""
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log("getCellMountContextOrEmpty cellLocationId=%s" % cellLocationId)
    empty = {"IsMountTarget": False, "ToolAssignmentId": None, "ToolId": None,
             "ToolCode": "", "ToolName": "", "ToolTypeCode": "",
             "AssignedAt": None, "AssignedBy": ""}
    if cellLocationId is None:
        return empty
    try:
        row = BlueRidge.Common.Db.execOne(
            "parts/ToolAssignment_GetCellContext", {"cellLocationId": cellLocationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getCellMountContextOrEmpty failed: %s" % str(e))
        return empty
    if row is None:
        return empty
    row["IsMountTarget"] = bool(row.get("IsMountTarget"))
    for k in ("ToolCode", "ToolName", "ToolTypeCode", "AssignedBy"):
        if row.get(k) is None:
            row[k] = ""
    return row


def getMountableToolsForCell(cellLocationId):
    """Active, currently-unmounted tools compatible with this Cell, as
    [{label, value}] for the Mount dropdown (label = 'Code - Name',
    value = Tool.Id). Empty list when the cell is not a mount target or has
    no available tools. Wraps Tools.Tool_ListMountableForCell."""
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log("getMountableToolsForCell cellLocationId=%s" % cellLocationId)
    if cellLocationId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/Tool_ListMountableForCell", {"cellLocationId": cellLocationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getMountableToolsForCell failed: %s" % str(e))
        return []
    out = []
    for r in (rows or []):
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        label = ("%s - %s" % (code, name)) if code and name else (code or name)
        out.append({"label": label, "value": r.get("Id")})
    return out
