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


# =============================================================================
# Plant-floor tap-to-select scrap grid (Trim OUT)
#
#   getForTiles()          -> the operation-scoped defect-code catalog, one dict
#                             per code, richer than getForDropdown's {label,value}
#   applyScrapChange()     -> id-keyed mutation of the operator's running scrap
#                             lines (tap = +1, stepper = +/-1, typed = set)
#   buildScrapEntryModel() -> merges catalog + running lines into the grid tiles,
#                             the entered-lines list, and the running total
#
# The wire shape the recorder consumes is UNCHANGED: view.custom.scrapLines is
# still [{"defectCodeId": <bigint>, "quantity": <int>}, ...] handed straight to
# BlueRidge.Workorder.TrimOut.record -> workorder/TrimOut_Record.
# =============================================================================

_EMPTY_SCRAP_MODEL = {"tiles": [], "lines": [], "total": 0, "moreCount": 0}


def _field(row, key, default=None):
    """Tolerant field read. Works for dict, java.util.Map AND Perspective's
    ImmutableMap -- the last of which extractQualifiedValues does NOT unwrap and
    which AttributeErrors on .get(). Bracket access is the only form all three
    honour (see feedback_ignition_immutable_map_unwrap)."""
    if row is None:
        return default
    try:
        value = row[key]
    except Exception:
        try:
            value = row.get(key)
        except Exception:
            return default
    return default if value is None else value


def getForTiles(operationTypeCode=None):
    """Active defect codes shaped for the plant-floor tap-to-select scrap grid,
    scoped to the terminal's operation category (+ plant-wide) when a type code
    is given -- same DefectCode_List read getForDropdown uses, richer row shape.

    Returns [] or a list of:
        {defectCodeId, code, description, isPrimary, excused}

    isPrimary is True for codes carrying the requested OperationCategory and
    False for the plant-wide (NULL category) long tail. The grid shows the
    primaries by default and hides the long tail behind a 'show all' toggle.
    Sort order: primaries first, then plant-wide, Code-ascending within each."""
    try:
        rows = BlueRidge.Common.Db.execList(
            "quality/DefectCode_List",
            {"includeDeprecated": 0, "operationCategoryId": None,
             "operationTypeCode": operationTypeCode},
        ) or []
    except Exception as e:
        BlueRidge.Common.Util.log("getForTiles failed: %s" % str(e))
        return []
    out = []
    for r in rows:
        out.append({
            "defectCodeId": r.get("Id"),
            "code":         r.get("Code") or "",
            "description":  r.get("Description") or "",
            "isPrimary":    r.get("OperationCategoryId") is not None,
            "excused":      bool(r.get("IsExcused")),
        })
    out.sort(key=lambda t: (0 if t["isPrimary"] else 1, t["code"]))
    return out


def applyScrapChange(scrapLines, defectCodeId, delta=None, quantity=None, maxTotal=None):
    """Id-keyed mutation of the running scrap lines. ONE code == ONE line, so a
    double-tap increments instead of creating a duplicate row.

        delta    -- add to the code's current quantity (tap-to-count, +/- stepper)
        quantity -- set the code's quantity outright (typed override)

    A resulting quantity of 0 or less drops the line. When maxTotal is given
    (the LOT's piece count) the change is clamped so the running total can never
    exceed it -- the submit-time guard in submitTrimOut stays authoritative.

    Returns {"lines": [{defectCodeId, quantity}, ...], "clamped": bool}. Line
    order is first-tapped-first, so the entered list does not reshuffle."""
    defectCodeId = BlueRidge.Common.Util.toIntOrNone(defectCodeId)
    if defectCodeId is None:
        return {"lines": _normalizeScrapLines(scrapLines), "clamped": False}

    rows = _normalizeScrapLines(scrapLines)
    current = 0
    for r in rows:
        if r["defectCodeId"] == defectCodeId:
            current = r["quantity"]
            break

    if quantity is not None:
        target = BlueRidge.Common.Util.toIntOrNone(quantity) or 0
    else:
        target = current + (BlueRidge.Common.Util.toIntOrNone(delta) or 0)
    if target < 0:
        target = 0

    clamped = False
    cap = BlueRidge.Common.Util.toIntOrNone(maxTotal)
    if cap is not None:
        others = sum(r["quantity"] for r in rows if r["defectCodeId"] != defectCodeId)
        headroom = cap - others
        if headroom < 0:
            headroom = 0
        if target > headroom:
            target = headroom
            clamped = True

    out = []
    seen = False
    for r in rows:
        if r["defectCodeId"] != defectCodeId:
            out.append(r)
            continue
        seen = True
        if target > 0:
            out.append({"defectCodeId": defectCodeId, "quantity": target})
    if not seen and target > 0:
        out.append({"defectCodeId": defectCodeId, "quantity": target})
    return {"lines": out, "clamped": clamped}


def _normalizeScrapLines(scrapLines):
    """Coerce whatever Perspective handed back (ImmutableList of ImmutableMap,
    QualifiedValue-wrapped dicts, plain list) into a clean id-keyed
    [{defectCodeId:int, quantity:int}] with positive quantities, duplicates
    merged, and first-seen order preserved."""
    rows = scrapLines or []
    merged = []
    index = {}
    for ln in rows:
        d = BlueRidge.Common.Util.toIntOrNone(_field(ln, "defectCodeId"))
        q = BlueRidge.Common.Util.toIntOrNone(_field(ln, "quantity")) or 0
        if d is None or q <= 0:
            continue
        if d in index:
            merged[index[d]]["quantity"] += q
        else:
            index[d] = len(merged)
            merged.append({"defectCodeId": d, "quantity": q})
    return merged


def buildScrapEntryModel(tiles, scrapLines, showAll=False):
    """Everything the Trim OUT scrap block renders, in one pass.

    tiles      -- getForTiles() output (view.custom.defectCodeTiles)
    scrapLines -- the operator's running lines (view.custom.scrapLines)
    showAll    -- False shows the operation-scoped codes only; True adds the
                  plant-wide long tail

    Returns a FULLY-SHAPED dict on every path (never None / partial), because
    the view's repeater + label bindings read every key:

        {"tiles":     [{defectCodeId, code, description, quantity,
                        isSelected, isPrimary, badge}],
         "lines":     [{defectCodeId, code, description, quantity}],
         "total":     <int running scrap total>,
         "moreCount": <int plant-wide codes behind the 'show all' toggle>}

    A long-tail code the operator has ALREADY used stays in the collapsed grid
    so its count badge never vanishes when the toggle is closed again."""
    catalog = tiles or []
    rows    = _normalizeScrapLines(scrapLines)
    showAll = bool(BlueRidge.Common.Util.extractQualifiedValues(showAll))

    counts = {}
    for r in rows:
        counts[r["defectCodeId"]] = r["quantity"]

    outTiles  = []
    moreCount = 0
    byId      = {}
    for t in catalog:
        d = BlueRidge.Common.Util.toIntOrNone(_field(t, "defectCodeId"))
        if d is None:
            continue
        code    = _field(t, "code", "") or ""
        desc    = _field(t, "description", "") or ""
        primary = bool(_field(t, "isPrimary", False))
        byId[d] = {"code": code, "description": desc}
        if not primary:
            moreCount += 1
        qty = counts.get(d, 0)
        if not (showAll or primary or qty > 0):
            continue
        outTiles.append({
            "defectCodeId": d,
            "code":         code,
            "description":  desc,
            "quantity":     qty,
            "isSelected":   qty > 0,
            "isPrimary":    primary,
            "badge":        (u"\u00d7%d" % qty) if qty > 0 else u"",
        })

    outLines = []
    for r in rows:
        meta = byId.get(r["defectCodeId"]) or {}
        outLines.append({
            "defectCodeId": r["defectCodeId"],
            "code":         meta.get("code") or ("#%s" % r["defectCodeId"]),
            "description":  meta.get("description") or "",
            "quantity":     r["quantity"],
        })

    return {"tiles":     outTiles,
            "lines":     outLines,
            "total":     sum(counts.values()),
            "moreCount": moreCount}
