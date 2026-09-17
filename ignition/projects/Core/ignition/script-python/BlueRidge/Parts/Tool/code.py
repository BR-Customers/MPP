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
#       Also runs Tools.Tool_CorrectShotCount when the header's Current
#       Shots differs from the loaded count (note required).
#   deprecate(toolId)                            -> {Status, Message}
#   getDuplicateSummary(toolId)                  -> dict | None
#   getDuplicateSummaryOrEmpty(toolId)           -> dict (binding-safe)
#       Display-ready preview of what a duplicate would carry over.
#   handleDuplicate(sourceToolId, code, name)    -> {Status, Message, NewId}
#       Clones a die's configuration onto a new Code / Name.
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

import java.lang


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
        BlueRidge.Common.Util.log("getAllForList failed: %s" % str(e), level="warn")
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


# -----------------------------------------------------------------------------
# Shot-field helpers (pure -- exec'd by ignition/tests/test_tool_shot_inputs.py)
#
# Both shot fields are text-fields so the die manager can type "1,000,000".
# Values are seeded as formatted strings (a text-field writes strings back,
# so an int baseline would latch the dirty flag) and parsed on save. Bad
# input is an error -- never a silent NULL.
# -----------------------------------------------------------------------------

def _parseShots(value, label):
    """(int, None) for a whole number (commas/spaces allowed), (None, None)
    for blank, (None, message) for anything else."""
    if value is None:
        return (None, None)
    if isinstance(value, bool):
        return (None, "%s must be a whole number of shots (got '%s')." % (label, value))
    try:
        integerTypes = (int, long)  # Jython 2.7
    except NameError:
        integerTypes = (int,)       # CPython 3 (pytest)
    if isinstance(value, integerTypes):
        return (int(value), None)
    text = ("%s" % value).strip()
    if text == "":
        return (None, None)
    digits = text.replace(",", "").replace(" ", "")
    if not digits.isdigit():
        return (None, "%s must be a whole number of shots (got '%s')." % (label, text))
    return (int(digits), None)


def _formatShots(value):
    """850000 -> '850,000'; None / '' -> ''."""
    if value is None or value == "":
        return ""
    return "{:,}".format(int(value))


def _metaForEditor(row):
    """Tool_Get row -> the meta dict the Tools header binds to."""
    meta = dict(row)
    meta["deprecated"] = meta.get("DeprecatedAt") is not None
    # Nullable text renders as literal "null" in a bidi text-field; seed "".
    if meta.get("Description") is None:
        meta["Description"] = ""
    meta["ShotLimit"] = _formatShots(meta.get("ShotLimit"))
    loaded = meta.get("ShotCount")
    meta["ShotCountLoaded"] = int(loaded) if loaded is not None else 0
    meta["ShotCount"] = _formatShots(meta["ShotCountLoaded"])
    meta["ShotCountNote"] = ""
    return meta


def _shotEdits(data):
    """Validate the header's shot fields. Returns
    {error, shotLimit, shotCount, shotCountChanged, note}."""
    out = {"error": None, "shotLimit": None, "shotCount": None,
           "shotCountChanged": False, "note": None}
    shotLimit, err = _parseShots(data.get("ShotLimit"), "Shot Limit")
    if err:
        out["error"] = err
        return out
    shotCount, err = _parseShots(data.get("ShotCount"), "Current Shots")
    if err:
        out["error"] = err
        return out
    if shotCount is None:
        out["error"] = "Current Shots cannot be blank."
        return out
    loaded = data.get("ShotCountLoaded")
    loaded = int(loaded) if loaded is not None else 0
    note = ("%s" % (data.get("ShotCountNote") or "")).strip()
    out["shotLimit"] = shotLimit
    out["shotCount"] = shotCount
    out["shotCountChanged"] = shotCount != loaded
    if out["shotCountChanged"]:
        if not note:
            out["error"] = "Enter a note explaining the shot count change."
            return out
        out["note"] = note
    return out


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
    return _metaForEditor(row)


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
    """Update an existing Tool. data: the header meta -- {Id, Name,
    Description, DieRankCode, StatusCode, ShotLimit, ShotCount,
    ShotCountLoaded, ShotCountNote}. Code is immutable per the proc.

    Legs, each its own proc/transaction, short-circuiting on failure:
      1. Tools.Tool_Update            Name / Description / DieRank / ShotLimit
      2. Tools.Tool_CorrectShotCount  only when ShotCount != ShotCountLoaded
      3. Tools.Tool_UpdateStatus      when a StatusCode is passed
    Shot fields are validated first (_shotEdits) so a bad number or a
    missing note writes nothing. After any failure the screen reloads the
    tool, which shows the true state.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)

    toolId = data.get("Id")
    if toolId is None:
        return {"Status": 0, "Message": "Id is required for update"}

    shots = _shotEdits(data)
    if shots["error"]:
        return {"Status": 0, "Message": shots["error"]}

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
            "shotLimit":   shots["shotLimit"],
            "appUserId":   appUserId,
        },
    )
    if not updateResult.get("Status"):
        return updateResult

    if shots["shotCountChanged"]:
        shotResult = BlueRidge.Common.Db.execMutation(
            "parts/Tool_CorrectShotCount",
            {
                "id":                toolId,
                "shotCount":         shots["shotCount"],
                "expectedShotCount": int(data.get("ShotCountLoaded") or 0),
                "note":              shots["note"],
                "appUserId":         appUserId,
            },
        )
        if not shotResult.get("Status"):
            return shotResult

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
# Duplicate Die
#   Clones a die's CONFIGURATION onto a new Code / Name. What copies and what
#   resets is decided in SQL (Tools.Tool_Duplicate) -- this layer only prompts,
#   previews and dispatches. Keep the preview text in sync with that proc's
#   header if the contract ever changes.
# -----------------------------------------------------------------------------

_EMPTY_DUPLICATE_SUMMARY = {
    "SourceId":        None,
    "SourceCode":      "",
    "SourceName":      "",
    "SourceLabel":     "",
    "Description":     "",
    "DescriptionLabel": "(none)",
    "DieRankLabel":    "None",
    "ShotLimitLabel":  "Not set",
    "CavityCount":     0,
    "AttributeCount":  0,
    "CavityLabel":     "0 cavities",
    "AttributeLabel":  "0 attributes",
    "ResetLabel":      "",
    "IsLoaded":        False,
}


def getDuplicateSummary(toolId):
    """Preview of what a duplicate of `toolId` would carry over, or None when
    the tool cannot be read.

    Reuses the existing Tool_Get / ToolCavity_ListByTool / ToolAttribute_ListByTool
    reads -- no new SQL surface. Every value is returned display-ready so the
    popup's labels bind straight through with no expression formatting."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None:
        return None

    meta = getOne(toolId)
    if meta is None:
        return None

    cavities = getCavityInstancesForTool(toolId)
    attrs    = getAttributeInstancesForTool(toolId)
    nCav     = len(cavities)
    nAttr    = len(attrs)

    code = meta.get("Code") or ""
    name = meta.get("Name") or ""
    label = ("%s - %s" % (code, name)) if code and name else (code or name)

    shotLimit = meta.get("ShotLimit")
    if shotLimit is None or shotLimit == "":
        shotLimitLabel = "Not set"
    else:
        shotLimitLabel = "%s shots" % shotLimit

    description = meta.get("Description") or ""

    return {
        "SourceId":        meta.get("Id"),
        "SourceCode":      code,
        "SourceName":      name,
        "SourceLabel":     label,
        "Description":     description,
        "DescriptionLabel": description or "(none)",
        "DieRankLabel":    meta.get("DieRankCode") or "None",
        "ShotLimitLabel": shotLimitLabel,
        "CavityCount":    nCav,
        "AttributeCount": nAttr,
        "CavityLabel":    "%d %s" % (nCav, "cavity" if nCav == 1 else "cavities"),
        "AttributeLabel": "%d %s" % (nAttr, "attribute" if nAttr == 1 else "attributes"),
        "ResetLabel":     "Shot count, status and mount history start clean",
        "IsLoaded":       True,
    }


def getDuplicateSummaryOrEmpty(toolId, _refreshToken=None):
    """Binding-safe variant of getDuplicateSummary: always a fully-shaped dict
    (never None) so the popup's nested-path bindings never Component-Error
    (pre-declare-bound-props rule). _refreshToken is ignored -- it exists so a
    runScript binding can force a re-read (runScript caches on args)."""
    row = getDuplicateSummary(toolId)
    if row is None:
        return dict(_EMPTY_DUPLICATE_SUMMARY)
    return row


def handleDuplicate(sourceToolId, code, name):
    """Clone a die's configuration onto a new Code / Name.

    COPIES  ToolType, Description, DieRank, ShotLimit, every non-deprecated
            cavity WHOLE (number, description AND status), and every attribute
            value whose definition is still active.
    RESETS  Code / Name (operator-supplied), Status ('Active'), ShotCount (0),
            and mount history (not copied at all).

    Validation is deliberately thin here -- Tools.Tool_Duplicate is the
    authority on Code uniqueness, blank checks and the source lookup ("rules
    live in SQL"). These guards only spare a round-trip on obviously empty
    input, matching add().

    Returns {Status, Message, NewId}.
    """
    sourceToolId = _u(sourceToolId)
    code = (_u(code) or "").strip()
    name = (_u(name) or "").strip()
    BlueRidge.Common.Util.log("sourceToolId=%s code=%s name=%s"
                              % (sourceToolId, code, name))

    if sourceToolId is None:
        return {"Status": 0, "Message": "No source tool selected", "NewId": None}
    if not code:
        return {"Status": 0, "Message": "Code is required", "NewId": None}
    if not name:
        return {"Status": 0, "Message": "Name is required", "NewId": None}

    return BlueRidge.Common.Db.execMutation(
        "parts/Tool_Duplicate",
        {
            "sourceToolId": sourceToolId,
            "code":         code,
            "name":         name,
            "appUserId":    BlueRidge.Common.Util._currentAppUserId(),
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
        BlueRidge.Common.Util.log("getAttributeInstancesForTool failed: %s" % str(e), level="warn")
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
        Id, Code, StatusCode, Description, ItemId, ItemPartNumber
    Mapped from the proc's CavityCode + StatusCode columns. ItemId is the
    0072 cavity-to-part map (family dies); it is NULLable, so ItemPartNumber
    comes back None for an unmapped cavity and the row must render that."""
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
        BlueRidge.Common.Util.log("getCavityInstancesForTool failed: %s" % str(e), level="warn")
        return []

    out = []
    for r in rows:
        out.append({
            "cavity": {
                "Id":             r.get("Id"),
                "Code":           r.get("CavityCode"),
                "StatusCode":     r.get("StatusCode"),
                "Description":    r.get("Description"),
                "ItemId":         r.get("ItemId"),
                "ItemPartNumber": r.get("ItemPartNumber"),
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
        BlueRidge.Common.Util.log("getAssignmentInstancesForTool failed: %s" % str(e), level="warn")
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
        BlueRidge.Common.Util.log("getStatusCodesForDropdown failed: %s" % str(e), level="warn")
        return []
    return [{"label": r.get("Name") or r.get("Code"), "value": r.get("Code")} for r in rows or []]


def getToolTypesForDropdown():
    """Returns [{label, value}, ...] for a Tool Type dropdown.
    Value is the ToolType.Code string."""
    try:
        rows = BlueRidge.Common.Db.execList("parts/ToolType_List", None)
    except Exception as e:
        BlueRidge.Common.Util.log("getToolTypesForDropdown failed: %s" % str(e), level="warn")
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
        BlueRidge.Common.Util.log("getAttributeDefinitionsForToolType failed: %s" % str(e), level="warn")
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
        BlueRidge.Common.Util.log("getAttributeDefinitionOptions failed: %s" % str(e), level="warn")
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
        BlueRidge.Common.Util.log("getCellsForDropdown failed: %s" % str(e), level="warn")
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

def createCavity(toolId, cavityCode, description=None, itemId=None):
    """Insert a new ToolCavity. Returns {Status, Message, NewId}.

       itemId is the OPTIONAL cavity-to-part map for family dies (0072).
       Omit it on a die whose cavities all cut the same part. Supplying it
       matters on a family die: cavity codes are unique per PART, so four
       cavities called 'a' are legal only if each carries its own itemId."""
    toolId = _u(toolId)
    cavityCode = _u(cavityCode)
    description = _u(description)
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("toolId=%s cavityCode=%s" % (toolId, cavityCode))
    if toolId is None:
        return {"Status": 0, "Message": "ToolId is required", "NewId": None}
    if not cavityCode:
        return {"Status": 0, "Message": "CavityCode is required", "NewId": None}
    return BlueRidge.Common.Db.execMutation(
        "parts/ToolCavity_Create",
        {
            "toolId":      toolId,
            "cavityCode":  ("%s" % cavityCode).strip().lower(),
            "description": description,
            "itemId":      itemId,
            "appUserId":   BlueRidge.Common.Util._currentAppUserId(),
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
    cavityCode (str), description (string|None), statusCode (str),
    itemId (BIGINT|None -- the 0072 cavity-to-part map, optional).
    Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s rows=%d" % (toolId, len(rows or [])))
    if toolId is None:
        return {"Status": 0, "Message": "No tool selected.", "NewId": None}
    cleaned = []
    for r in (rows or []):
        r = _u(r) or {}
        code = r.get("cavityCode")
        code = None if code is None else ("%s" % code).strip().lower()
        # itemId is genuinely optional: an unmapped cavity, and a cleared
        # dropdown, must both send null rather than 0 -- the proc treats NULL
        # as "no mapping" and would reject 0 as a non-existent part.
        iid = r.get("itemId")
        if iid is None or iid == "":
            iid = None
        else:
            iid = int(iid)
        cleaned.append({
            "Id":           r.get("id"),
            "CavityCode":   code,
            "Description":  r.get("description"),
            "StatusCode":   r.get("statusCode") or "Active",
            "ItemId":       iid,
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
    dropdown (label = 'Cavity N - <Description>', or just 'Cavity N' when the
    cavity has no description; value = ToolCavity.Id). Empty list = no active
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
        BlueRidge.Common.Util.log("getCavitiesForDropdown failed: %s" % str(e), level="warn")
        return []
    out = []
    for r in (rows or []):
        code = r.get("CavityCode")
        desc = (r.get("Description") or "").strip()
        label = ("Cavity %s - %s" % (code, desc)) if desc else ("Cavity %s" % code)
        out.append({"label": label, "value": r.get("Id")})
    return out


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
        BlueRidge.Common.Util.log("getMountedToolForCell failed: %s" % str(e), level="warn")
        return None
    return rows[0] if rows else None


def getMountedToolForCellOrEmpty(cellLocationId, _refreshToken=None):
    """Binding-safe variant: a fully-shaped dict (never None) so the Tool card's
    nested-path bindings never Component-Error (pre-declare-bound-props rule). Shape
    mirrors Tools.ToolAssignment_ListActiveByCell's columns.
    _refreshToken is ignored - the Die Cast refresh button bumps a token that
    runScript bindings pass here to force a re-read (runScript caches on args)."""
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

def getCellMountContextOrEmpty(cellLocationId, _refreshToken=None):
    """Single-row mount context for a Cell, for the Plant Hierarchy Cell Mount
    Card and the plant-floor Die Mount popup.

    _refreshToken is ignored -- it lets a runScript binding force a re-read
    after a mount / release (runScript caches on its args). Existing one-arg
    callers are unaffected. Always a fully-shaped dict (never None) so the card's nested-path
    bindings never Component-Error (pre-declare-bound-props rule). Wraps
    Tools.ToolAssignment_GetCellContext. IsMountTarget is coerced to a bool;
    nullable text columns coerced to '' for clean binding render.

    OpenBasketCount (proc v1.1) is how the Die Mount popup disables Release
    and states the reason inline instead of firing a mutation to be told no.
    It is coerced to an int because a NULL here would make the popup's
    'count > 0' test silently false and re-enable a button the proc will
    refuse."""
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log("getCellMountContextOrEmpty cellLocationId=%s" % cellLocationId)
    empty = {"IsMountTarget": False, "ToolAssignmentId": None, "ToolId": None,
             "ToolCode": "", "ToolName": "", "ToolTypeCode": "",
             "AssignedAt": None, "AssignedBy": "", "OpenBasketCount": 0}
    if cellLocationId is None:
        return empty
    try:
        row = BlueRidge.Common.Db.execOne(
            "parts/ToolAssignment_GetCellContext", {"cellLocationId": cellLocationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getCellMountContextOrEmpty failed: %s" % str(e), level="warn")
        return empty
    if row is None:
        return empty
    row["IsMountTarget"] = bool(row.get("IsMountTarget"))
    for k in ("ToolCode", "ToolName", "ToolTypeCode", "AssignedBy"):
        if row.get(k) is None:
            row[k] = ""
    if row.get("OpenBasketCount") is None:
        row["OpenBasketCount"] = 0
    else:
        row["OpenBasketCount"] = int(row["OpenBasketCount"])
    return row


def getShotStatusForCell(cellLocationId):
    """Shot status (count / limit / remaining / percent / near / over) of the die
    currently mounted on a Cell, for the die-cast station badge. Returns a dict,
    or None when nothing is mounted. Wraps Tools.Tool_GetShotStatusForCell."""
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log("getShotStatusForCell cellLocationId=%s" % cellLocationId)
    if cellLocationId is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne(
            "parts/Tool_GetShotStatusForCell", {"cellLocationId": cellLocationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getShotStatusForCell failed: %s" % str(e), level="warn")
        return None


def getShotStatusForCellOrEmpty(cellLocationId, _refreshToken=None):
    """Binding-safe variant: a fully-shaped dict (never None) so the badge's
    nested-path bindings never Component-Error (pre-declare-bound-props rule).
    _refreshToken lets a runScript binding force a re-read (runScript caches on args)."""
    row = getShotStatusForCell(cellLocationId)
    if row is None:
        return {"ToolId": None, "ToolCode": "", "ToolName": "",
                "ShotCount": 0, "ShotLimit": None, "ShotsRemaining": None,
                "PercentOfLimit": None, "IsNearLimit": False, "IsOverLimit": False}
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
        BlueRidge.Common.Util.log("getMountableToolsForCell failed: %s" % str(e), level="warn")
        return []
    out = []
    for r in (rows or []):
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        label = ("%s - %s" % (code, name)) if code and name else (code or name)
        out.append({"label": label, "value": r.get("Id")})
    return out


# -----------------------------------------------------------------------------
# Plant-floor Die Mount popup (mount-at-the-press).
# See spec 2026-09-14-plant-floor-die-mount-popup-design.md.
# -----------------------------------------------------------------------------

_EMPTY_PICKER = {"options": [], "isFallback": False, "count": 0}


def getEligibleToolPicker(cellLocationId, _refreshToken=None):
    """The Die Mount popup's whole dropdown state in one read.

    Returns {"options": [{label, value}...], "isFallback": bool, "count": int}
    -- ALWAYS that exact shape, on every path including the exception path, so
    the binding can never overwrite the view's shaped default with None and
    Component-Error a nested read (pre-declare-bound-props rule).

    isFallback is True when the rowset is non-empty and EVERY row came back
    IsEligible = 0 -- i.e. the press carries no machine-tier Parts.ItemLocation
    row and Tools.Tool_ListEligibleForCell fell back to every compatible
    unmounted die. That decision is the PROC'S; this function only reports it.
    The proc is all-or-nothing by construction (one COUNT(*), not a per-row
    test), so 'every row is 0' is a faithful reading and never a mixed rowset.

    NO ELIGIBILITY LOGIC LIVES HERE. Type compatibility, the part-to-press
    match, the fallback decision and the not-already-mounted rule are all in
    SQL. This shapes rows into {label, value} and nothing more.

    The eligibility flag deliberately does NOT ride inside an option: dropdown
    options are {label, value} and nothing else. It surfaces as the muted line
    above the dropdown, driven by isFallback.

    _refreshToken is ignored -- it exists so a runScript binding can force a
    re-read after a mount / release (runScript caches on its args)."""
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log("getEligibleToolPicker cellLocationId=%s" % cellLocationId)
    if cellLocationId is None:
        return dict(_EMPTY_PICKER)
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/Tool_ListEligibleForCell", {"cellLocationId": cellLocationId})
    except (Exception, java.lang.Exception) as e:
        # A bare 'except Exception' does not catch a Java exception, and a
        # throw here would leave the popup with no dropdown and no message.
        BlueRidge.Common.Util.log(
            "getEligibleToolPicker failed: %s" % str(e), level="warn")
        return dict(_EMPTY_PICKER)

    rows = rows or []
    options = []
    eligible = 0
    for r in rows:
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        label = ("%s - %s" % (code, name)) if code and name else (code or name)
        options.append({"label": label, "value": r.get("Id")})
        if r.get("IsEligible"):
            eligible += 1

    return {"options": options,
            "isFallback": bool(rows) and eligible == 0,
            "count": len(options)}
