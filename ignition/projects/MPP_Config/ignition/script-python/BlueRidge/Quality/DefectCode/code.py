# =============================================================================
# Project Library:  BlueRidge.Quality.DefectCode
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read + mutation surface for the Defect Codes Configuration Tool
#   screen (FDS-08-016 / FDS-08-017). Routes every DB call through
#   BlueRidge.Common.Db.* helpers.
#
# Public surface:
#   getAll(includeDeprecated=False, areaLocationId=None) -> list[dict]
#   getOne(defectCodeId) -> dict | None
#   add(data) -> {Status, Message, NewId}
#   update(data) -> {Status, Message}
#   deprecate(defectCodeId) -> {Status, Message}
#   derivePrefix(areaName) -> str    -- helper for Code auto-suggest
#   filterAndMapRows(allRows, searchText) -> list[dict]
#                                    -- helper for flex-repeater binding
#
# Layer:
#   View -> BlueRidge.Quality.DefectCode (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-19 - 1.0 - Initial version: full CRUD + derivePrefix +
#                      filterAndMapRows helpers.
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getAll(includeDeprecated=False, areaLocationId=None):
    """List defect codes, optionally including deprecated and/or filtered
    by area. SQL ORDER BY guarantees (AreaName, Code)."""
    BlueRidge.Common.Util.log("includeDeprecated=%s areaLocationId=%s"
                              % (includeDeprecated, areaLocationId))
    try:
        return BlueRidge.Common.Db.execList(
            "quality/DefectCode_List",
            {
                "includeDeprecated": 1 if includeDeprecated else 0,
                "areaLocationId":    areaLocationId,
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load defect codes", str(e), "error")
        return []


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
    """Insert. data: {Code, Description, AreaLocationId, IsExcused}.
    Returns {Status, Message, NewId}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Create",
        {
            "code":           data.get("Code"),
            "description":    data.get("Description"),
            "areaLocationId": data.get("AreaLocationId"),
            "isExcused":      bool(data.get("IsExcused")),
            "appUserId":      BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update existing row. data: {Id, Description, AreaLocationId, IsExcused}.
    Code is immutable on update (per the underlying proc)."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "quality/DefectCode_Update",
        {
            "id":             data.get("Id"),
            "description":    data.get("Description"),
            "areaLocationId": data.get("AreaLocationId"),
            "isExcused":      bool(data.get("IsExcused")),
            "appUserId":      BlueRidge.Common.Util._currentAppUserId(),
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


def derivePrefix(areaName):
    """Code prefix suggestion from area name.
    - 'Die Cast'         -> 'DC-'
    - 'Machine Shop'     -> 'MS-'
    - 'HSP'              -> 'HSP-'  (single ALL-CAPS word kept whole)
    - 'Production Control' -> 'PC-'
    - '' or None         -> ''"""
    if not areaName:
        return ""
    words = areaName.strip().split()
    if not words:
        return ""
    if len(words) == 1 and words[0].isupper() and len(words[0]) <= 4:
        return words[0] + "-"
    prefix = "".join(w[0].upper() for w in words)
    return prefix + "-"


def filterAndMapRows(allRows, searchText):
    """Flex-repeater instances transform.

    Filters allRows by case-insensitive substring match on Code or
    Description against searchText. Maps DB column names to the
    DefectCodeRow view-param shape. Returns list[dict] ready for
    Repeater.props.instances.
    """
    allRows = _u(allRows) or []
    s = (_u(searchText) or "").strip().lower()
    out = []
    for r in allRows:
        code        = r.get("Code") or ""
        description = r.get("Description") or ""
        if s and s not in code.lower() and s not in description.lower():
            continue
        out.append({
            "id":             r.get("Id"),
            "code":           code,
            "description":    description,
            "area":           r.get("AreaName") or "",
            "areaLocationId": r.get("AreaLocationId"),
            "excused":        bool(r.get("IsExcused")),
            "selected":       False,
        })
    return out
