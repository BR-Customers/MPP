# =============================================================================
# Project Library:  BlueRidge.Quality.DefectCode
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.1
#
# Description:
#   Read + mutation surface for the Defect Codes Configuration Tool
#   screen (FDS-08-016 / FDS-08-017). Routes every DB call through
#   BlueRidge.Common.Db.* helpers.
#
# Public surface:
#   search(filter)        -> list[dict]   -- one-shot DB + filter + map
#                                            for the list view binding
#   getAll(includeDeprecated=False, areaLocationId=None) -> list[dict]
#   getOne(defectCodeId)  -> dict | None
#   add(data)             -> {Status, Message, NewId}
#   update(data)          -> {Status, Message}
#   deprecate(defectCodeId) -> {Status, Message}
#   derivePrefix(areaName)-> str          -- helper for Code auto-suggest
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
#                      Single-binding architecture (one expr binding ->
#                      one runScript call -> ready-to-render rows)
#                      sidesteps the chained-binding runtime failure
#                      that blocked Task 8 with the prior two-binding
#                      design (query+transform feeding a runScript expr).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filter=None):
    """One-shot list view feed. Runs the DB query, applies the client-side
    search-text filter, maps rows to the DefectCodeRow shape, returns
    the list ready to be assigned to a flex-repeater's props.instances.

    filter keys (all optional):
        includeDeprecated  bool, default False (server-side via proc)
        areaLocationId     BIGINT or None      (server-side via proc)
        searchText         string or None      (client-side filter here)
    """
    BlueRidge.Common.Util.log("filter=%s" % filter)
    f = _u(filter) or {}
    rows = getAll(
        bool(f.get("includeDeprecated", False)),
        f.get("areaLocationId"),
    )
    needle = (f.get("searchText") or "").strip().lower()
    out = []
    for r in rows:
        code        = r.get("Code") or ""
        description = r.get("Description") or ""
        if needle and needle not in code.lower() and needle not in description.lower():
            continue
        out.append({
            "id":             r.get("Id"),
            "code":           code,
            "description":    description,
            "area":           r.get("AreaName") or "",
            "areaLocationId": r.get("AreaLocationId"),
            "excused":        bool(r.get("IsExcused")),
            "deprecated":     r.get("DeprecatedAt") is not None,
            "selected":       False,
        })
    return out


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
