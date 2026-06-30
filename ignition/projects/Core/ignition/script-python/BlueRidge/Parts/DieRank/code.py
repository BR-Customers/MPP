# =============================================================================
# Project Library:  BlueRidge.Parts.DieRank
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          1.0
#
# Description:
#   Read + mutation surface for the Die Ranks modal. Routes every DB call
#   through BlueRidge.Common.Db.* helpers.
#
#   The compatibility matrix UI presents a symmetric rank-vs-rank grid,
#   but the underlying Tools.DieRankCompatibility row stores the pair
#   canonicalised to (smaller Id, larger Id) with a single CanMix BIT.
#   This module hides that canonicalisation -- callers work in rank
#   Codes ("A", "B", ...) and the proc resolves the canonical order.
#
# Public surface:
#   getAllForList()                 -> list[dict]
#   getOne(dieRankId)               -> dict | None
#   getForDropdown()                -> [{label, value}, ...]
#   getInstancesForFlexRepeater()   -> [{rank: <row>}, ...]
#   getCompatibilityMatrix()        -> {fromCode: {toCode: bool}}
#   getMatrixHeaderInstances()      -> [{header: {code, label}}, ...]
#   getMatrixRowInstances()         -> [{row: {...}}, ...]
#   add(data)                       -> {Status, Message, NewId}
#   update(data)                    -> {Status, Message}
#   deprecate(dieRankId)            -> {Status, Message}
#   setCompatibility(fromCode, toCode, compatible) -> {Status, Message}
#
# Layer:
#   View -> BlueRidge.Parts.DieRank (this module)
#        -> BlueRidge.Common.Db.execList / execOne / execMutation
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-05-26 - 0.3 - Initial scaffold backed by in-memory dummies.
#   2026-06-01 - 1.0 - Replace dummies with real NQ calls
#                      (Tools.DieRank_* and Tools.DieRankCompatibility_*).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getAllForList():
    """Returns active DieRank rows ordered by SortOrder, Code. Empty list
    on failure (errors toast and log; we do not propagate)."""
    BlueRidge.Common.Util.log("call")
    try:
        return BlueRidge.Common.Db.execList(
            "parts/DieRank_List",
            {"includeDeprecated": 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAllForList failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load die ranks", str(e), "error")
        return []


def getOne(dieRankId):
    """Single-row lookup. Returns dict or None."""
    dieRankId = _u(dieRankId)
    BlueRidge.Common.Util.log("dieRankId=%s" % dieRankId)
    if dieRankId is None:
        return None
    return BlueRidge.Common.Db.execOne(
        "parts/DieRank_Get",
        {"id": dieRankId},
    )


def getByCode(dieCode):
    # Noah's exact implementation (Die Rank compatibility save path).
    BlueRidge.Common.Util.log("dieCode=%s" % dieCode)
    return BlueRidge.Common.Db.execOne(
        "parts/DieRank_GetByCode",
        {"code": dieCode}
    )


def getForDropdown():
    """Returns [{label:'A - Premium', value:'A'}, ...] for the Die Rank
    dropdown on Add Die / Tool detail header. Plain hyphen separator --
    em-dashes do not survive Jython 2 source decoding."""
    ranks = getAllForList()
    return [
        {"label": "%s - %s" % (r.get("Code") or "", r.get("Name") or ""),
         "value": r.get("Code")}
        for r in ranks
    ]


def getInstancesForFlexRepeater():
    """Composes the flex-repeater instances payload for the rank list.
    Each instance is {'rank': <row>}. SQL ORDER BY already sorts by
    (SortOrder, Code) so we pass rows through unchanged."""
    ranks = getAllForList()
    return [{"rank": dict(r)} for r in ranks]


def getMatrixHeaderInstances():
    """Flex-repeater instances for the matrix column headers.
    Each instance is {'header': {code, label}}."""
    ranks = getAllForList()
    return [
        {"header": {
            "code":  r.get("Code"),
            "label": "%s - %s" % (r.get("Code") or "", r.get("Name") or ""),
        }}
        for r in ranks
    ]


def getMatrixRowInstances():
    """Flex-repeater instances for the matrix body rows.
    Each instance is {'row': {fromCode, label, cells: [...]}} where the
    inner cells list is wrapped for the per-row CellRepeater:
    [{cell: {fromCode, toCode, compatible, mirror}}, ...]."""
    ranks = getAllForList()
    rankCodes = [r.get("Code") for r in ranks]
    matrix = getCompatibilityMatrix()
    # Precompute code -> ordinal once (was O(N^3) list.index() per cell, and
    # list.index() raises on a null Code).
    codeIndex = {code: i for i, code in enumerate(rankCodes)}
    rowInstances = []
    for r in ranks:
        fromCode = r.get("Code")
        cellInstances = []
        for toCode in rankCodes:
            isMirror = codeIndex.get(fromCode, -1) > codeIndex.get(toCode, -1)
            compatible = bool(matrix.get(fromCode, {}).get(toCode, False))
            cellInstances.append({
                "cell": {
                    "fromCode":   fromCode,
                    "toCode":     toCode,
                    "compatible": compatible,
                    "mirror":     isMirror,
                }
            })
        rowInstances.append({
            "row": {
                "fromCode": fromCode,
                "label":    "%s - %s" % (fromCode or "", r.get("Name") or ""),
                "cells":    cellInstances,
            }
        })
    return rowInstances


def getCompatibilityMatrix():
    """Returns a nested dict {fromCode: {toCode: bool}} representing the
    full pairwise compatibility matrix. Symmetric -- matrix[a][b] always
    equals matrix[b][a]. Same-code pairs default to True (a rank is
    trivially compatible with itself) unless an explicit row overrides.
    Cells with no row stored default to False (incompatible)."""
    ranks = getAllForList()
    rankCodes = [r.get("Code") for r in ranks]

    matrix = {}
    for fromCode in rankCodes:
        matrix[fromCode] = {}
        for toCode in rankCodes:
            matrix[fromCode][toCode] = (fromCode == toCode)

    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/DieRankCompatibility_List",
        )
    except Exception as e:
        BlueRidge.Common.Util.log("compat list failed: %s" % str(e))
        return matrix

    for row in rows:
        a = row.get("RankACode")
        b = row.get("RankBCode")
        canMix = bool(row.get("CanMix"))
        if a in matrix and b in matrix[a]:
            matrix[a][b] = canMix
        if b in matrix and a in matrix[b]:
            matrix[b][a] = canMix
    return matrix


def saveCompatibilityMatrix(data, appUserId=None):
    # Noah's exact bulk-save logic (jsonEncode the raw view data directly -- do
    # NOT extractQualifiedValues first, that altered the payload shape the proc
    # parses). The ONE fix: the DieRanks view passes session.custom.appUserId,
    # which is empty in dev (login flow not wired), and DieRankCompatibility_SaveAll
    # REJECTS a NULL @AppUserId ("Required parameter missing") -- that is what broke
    # the save. Resolve via _currentAppUserId() (the standard helper, with a dev
    # fallback) when the caller's value is empty, like the sibling mutations do.
    jsonData = system.util.jsonEncode(data)
    if not data:
        return
    if not appUserId:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/DieRankCompatibility_SaveAll",
        {"rowsJson": jsonData, "appUserId": appUserId},
    )


def add(data):
    """Insert. data: {Code, Name, Description}.
    Returns {Status, Message, NewId}."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/DieRank_Create",
        {
            "code":        data.get("Code"),
            "name":        data.get("Name"),
            "description": data.get("Description"),
            "appUserId":   BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def update(data):
    """Update existing row. data: {Id, Name, Description}. Code is
    immutable per the underlying proc."""
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    if data.get("Id") is None:
        return {"Status": 0, "Message": "Id is required for update."}
    return BlueRidge.Common.Db.execMutation(
        "parts/DieRank_Update",
        {
            "id":          data.get("Id"),
            "name":        data.get("Name"),
            "description": data.get("Description"),
            "appUserId":   BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(dieRankId):
    """Soft-delete. Returns {Status, Message}. Proc rejects if any
    active Tool or DieRankCompatibility row references this rank."""
    dieRankId = _u(dieRankId)
    BlueRidge.Common.Util.log("dieRankId=%s" % dieRankId)
    if dieRankId is None:
        return {"Status": 0, "Message": "dieRankId is required."}
    return BlueRidge.Common.Db.execMutation(
        "parts/DieRank_Deprecate",
        {
            "id":        dieRankId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def setCompatibility(fromCode, toCode, compatible):
    """Toggle a single matrix cell. View passes rank Codes; the proc
    takes Ids and canonicalises the pair, so we resolve Codes -> Ids
    from the current rank list before dispatching.

    Returns {Status, Message}."""
    fromCode = _u(fromCode)
    toCode   = _u(toCode)
    compatible = _u(compatible)
    BlueRidge.Common.Util.log("fromCode=%s toCode=%s compatible=%s"
                              % (fromCode, toCode, compatible))

    ranks = getAllForList()
    codeToId = {r.get("Code"): r.get("Id") for r in ranks}
    rankAId = codeToId.get(fromCode)
    rankBId = codeToId.get(toCode)
    if rankAId is None or rankBId is None:
        return {"Status": 0,
                "Message": "Unknown rank code(s): %s, %s" % (fromCode, toCode)}

    return BlueRidge.Common.Db.execMutation(
        "parts/DieRankCompatibility_Upsert",
        {
            "rankA":     rankAId,
            "rankB":     rankBId,
            "canMix":    1 if compatible else 0,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )
