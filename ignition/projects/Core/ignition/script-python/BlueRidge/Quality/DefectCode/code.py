# =============================================================================
# Project Library:  BlueRidge.Quality.DefectCode
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          2.0
#
# Description:
#   Read + mutation surface for the Defect Codes Configuration Tool
#   screen (FDS-08-016 / FDS-08-017) and the plant-floor reject panels.
#   Routes every DB call through BlueRidge.Common.Db.* helpers.
#
#   Defect codes are scoped by Parts.OperationCategory (nullable = plant-wide).
#   The OperationType -> OperationCategory resolution lives in SQL
#   (Quality.DefectCode_List), NOT here -- this module is a thin passthrough.
#
# Public surface:
#   search(filter)        -> list[dict]   -- one-shot DB + filter + map
#                                            for the list view binding
#   getAll(includeDeprecated=False, operationCategoryId=None) -> list[dict]
#   getForDropdown(operationTypeCode=None) -> list[{label, value}]
#   getOne(defectCodeId)  -> dict | None
#   add(data)             -> {Status, Message, NewId}
#   update(data)          -> {Status, Message}
#   deprecate(defectCodeId) -> {Status, Message}
#   derivePrefix(name)    -> str          -- helper for Code auto-suggest
#
# Layer:
#   View -> BlueRidge.Quality.DefectCode (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-19 - 1.0 - Initial version: full CRUD + derivePrefix +
#                      filterAndMapRows helpers.
#   2026-05-20 - 1.1 - Replace filterAndMapRows with search(filter)
#                      following DowntimeReasonCode.search pattern.
#   2026-08-04 - 2.0 - Scope by Parts.OperationCategory instead of
#                      AreaLocationId. getAll/search key on operationCategoryId;
#                      getForDropdown(operationTypeCode) resolves scope in SQL;
#                      add/update read data["OperationCategoryId"]. Row maps
#                      expose category + operationCategoryId.
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filter=None):
    """One-shot list view feed. Runs the DB query, applies the client-side
    search-text filter, maps rows to the DefectCodeRow shape, returns
    the list ready to be assigned to a flex-repeater's props.instances.

    filter keys (all optional):
        includeDeprecated    bool, default False (server-side via proc)
        operationCategoryId  BIGINT or None      (server-side via proc)
        searchText           string or None      (client-side filter here)
    """
    f = _u(filter) or {}
    rows = getAll(
        bool(f.get("includeDeprecated", False)),
        f.get("operationCategoryId"),
    )
    needle = (f.get("searchText") or "").strip().lower()
    out = []
    for r in rows:
        code        = r.get("Code") or ""
        description = r.get("Description") or ""
        if needle and needle not in code.lower() and needle not in description.lower():
            continue
        out.append({
            "id":                  r.get("Id"),
            "code":                code,
            "description":         description,
            "category":            r.get("CategoryName") or "Plant-wide",
            "operationCategoryId": r.get("OperationCategoryId"),
            "excused":             bool(r.get("IsExcused")),
            "deprecated":          r.get("DeprecatedAt") is not None,
            "selected":            False,
        })
    return out


def getAll(includeDeprecated=False, operationCategoryId=None):
    """List defect codes, optionally including deprecated and/or filtered by
    OperationCategory. SQL ORDER BY guarantees (plant-wide last, CategoryName, Code)."""
    BlueRidge.Common.Util.log("includeDeprecated=%s operationCategoryId=%s"
                              % (includeDeprecated, operationCategoryId))
    try:
        return BlueRidge.Common.Db.execList(
            "quality/DefectCode_List",
            {
                "includeDeprecated": 1 if includeDeprecated else 0,
                "operationCategoryId": operationCategoryId,
                "operationTypeCode":   None,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load defect codes", str(e), "error")
        return []


def getForDropdown(operationTypeCode=None):
    """Active defect codes as [{label, value}] for a reject panel dropdown,
    scoped to the terminal's operation category (+ plant-wide) when a type code
    is given. label = 'CODE - Description', value = DefectCode.Id."""
    try:
        rows = BlueRidge.Common.Db.execList(
            "quality/DefectCode_List",
            {"includeDeprecated": 0, "operationCategoryId": None,
             "operationTypeCode": operationTypeCode},
        ) or []
    except Exception as e:
        BlueRidge.Common.Util.log("getForDropdown failed: %s" % str(e))
        return []
    out = []
    for r in rows:
        code = r.get("Code") or ""
        desc = r.get("Description") or ""
        label = ("%s - %s" % (code, desc)) if desc else code
        out.append({"label": label, "value": r.get("Id")})
    return out


def getCategoryOptions(nullLabel=None):
    """OperationCategory dropdown options for the defect-code editor + list filter:
    [{label, value}] of the 3 process categories (value = OperationCategory.Id).
    When nullLabel is given, a leading {label: nullLabel, value: None} option is
    prepended -- 'Plant-wide (all areas)' in the editor, 'All areas' in the filter."""
    try:
        cats = BlueRidge.Parts.OperationTemplate.getOperationCategoriesForDropdown() or []
    except Exception as e:
        BlueRidge.Common.Util.log("getCategoryOptions failed: %s" % str(e))
        cats = []
    out = []
    if nullLabel is not None:
        out.append({"label": nullLabel, "value": None})
    out.extend(cats)
    return out


def getOne(defectCodeId):
    """Single-row lookup. Returns dict or None."""
    defectCodeId = _u(defectCodeId)
    BlueRidge.Common.Util.log("defectCodeId=%s" % defectCodeId)
    if defectCodeId is None:
        return None
    return BlueRidge.Common.Db.execOne(
        "quality/DefectCode_Get",
        {"id": defectCodeId},
    )


def add(data):
    """Insert. data: {Code, Description, OperationCategoryId, IsExcused}.
    A missing/None OperationCategoryId is a valid plant-wide code.
    Returns {Status, Message, NewId}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Create",
        {
            "code":                data.get("Code"),
            "description":         data.get("Description"),
            "operationCategoryId": data.get("OperationCategoryId"),
            "isExcused":           bool(data.get("IsExcused")),
            "appUserId":           BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update existing row. data: {Id, Description, OperationCategoryId, IsExcused}.
    Code is immutable on update (per the underlying proc). A missing/None
    OperationCategoryId is a valid plant-wide code."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Update",
        {
            "id":                  data.get("Id"),
            "description":         data.get("Description"),
            "operationCategoryId": data.get("OperationCategoryId"),
            "isExcused":           bool(data.get("IsExcused")),
            "appUserId":           BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(defectCodeId):
    """Soft-delete. Returns {Status, Message}."""
    defectCodeId = _u(defectCodeId)
    BlueRidge.Common.Util.log("defectCodeId=%s" % defectCodeId)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Deprecate",
        {
            "id":        defectCodeId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def derivePrefix(name):
    """Code prefix suggestion from a scope name (now the category name).
    - 'Die Cast'         -> 'DC-'
    - 'Machine Shop'     -> 'MS-'
    - 'HSP'              -> 'HSP-'  (single ALL-CAPS word kept whole)
    - 'Production Control' -> 'PC-'
    - '' or None         -> ''"""
    if not name:
        return ""
    words = name.strip().split()
    if not words:
        return ""
    if len(words) == 1 and words[0].isupper() and len(words[0]) <= 4:
        return words[0] + "-"
    prefix = "".join(w[0].upper() for w in words)
    return prefix + "-"
