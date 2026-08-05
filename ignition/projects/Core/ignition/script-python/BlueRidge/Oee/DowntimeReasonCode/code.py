"""BlueRidge.Oee.DowntimeReasonCode - full CRUD for downtime reason codes.

   All public functions unwrap QualifiedValue wrappers at entry via _u() so
   bidirectional-bound view properties can be passed straight through."""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filters=None):
    """List DowntimeReasonCode rows filtered by the supplied dict.

       filters keys (all optional):
         operationCategoryId        BIGINT or None  (server-side filter via proc)
         downtimeReasonTypeId  BIGINT or None  (server-side filter via proc)
         includeDeprecated     bool, default False (server-side filter via proc)
         searchText            string or None  (CLIENT-side filter applied here;
                                                 the proc itself has no @SearchText)"""
    BlueRidge.Common.Util.log("filters=%s" % filters)
    f = _u(filters) or {}
    params = {
        "operationCategoryId":  f.get("operationCategoryId"),
        "operationTypeCode":    f.get("operationTypeCode"),
        "downtimeReasonTypeId": f.get("downtimeReasonTypeId"),
        "includeDeprecated":    bool(f.get("includeDeprecated", False)),
    }
    try:
        rows = BlueRidge.Common.Db.execList("oee/DowntimeReasonCode_List", params)
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load downtime codes", str(e), "error")
        return []

    # Client-side search filter (proc has no @SearchText param).
    # 353-row max set; in-process filter on Code + Description is trivial.
    # Row dict keys are PascalCase -- they mirror the proc's SELECT aliases
    # (drc.Code, drc.Description). If the proc ever renames those, this
    # filter silently no-ops and returns the unfiltered list.
    needle = (f.get("searchText") or "").strip().lower()
    if not needle:
        return rows
    return [
        r for r in rows
        if needle in (r.get("Code") or "").lower()
        or needle in (r.get("Description") or "").lower()
    ]


def getOne(id):
    """Single-row lookup by Id. Returns dict or None."""
    BlueRidge.Common.Util.log("id=%s" % id)
    if id is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne("oee/DowntimeReasonCode_Get", {"id": _u(id)})
    except Exception as e:
        BlueRidge.Common.Util.log("get failed: %s" % str(e))
        return None


def add(meta):
    """Create. meta = {code, description, operationCategoryId, downtimeReasonTypeId, isExcused}.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "code":                 m.get("code"),
        "description":          m.get("description"),
        "operationCategoryId":       m.get("operationCategoryId"),
        "downtimeReasonTypeId": m.get("downtimeReasonTypeId"),
        "isExcused":            bool(m.get("isExcused", False)),
        "appUserId":            BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Create", params)


def update(meta):
    """Update. meta = {id, description, operationCategoryId, downtimeReasonTypeId, isExcused}.
       Code is immutable post-create; proc rejects changes.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "id":                   m.get("id"),
        "description":          m.get("description"),
        "operationCategoryId":       m.get("operationCategoryId"),
        "downtimeReasonTypeId": m.get("downtimeReasonTypeId"),
        "isExcused":            bool(m.get("isExcused", False)),
        "appUserId":            BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Update", params)


def deprecate(id):
    """Soft-delete by Id. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("id=%s" % id)
    params = {
        "id":        _u(id),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Deprecate", params)


def getForDropdown(operationTypeCode=None):
    """Active downtime reason codes as [{label, value}] for the plant-floor downtime
    entry, scoped to the terminal's operation category (+ plant-wide) when a type
    code is given. label = 'CODE - Description', value = DowntimeReasonCode.Id."""
    try:
        rows = BlueRidge.Common.Db.execList(
            "oee/DowntimeReasonCode_List",
            {"operationCategoryId": None, "operationTypeCode": operationTypeCode,
             "downtimeReasonTypeId": None, "includeDeprecated": 0},
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
    """OperationCategory dropdown options for the downtime-code editor + list filter:
    the 3 process categories (value = OperationCategory.Id). When nullLabel is given, a
    leading {label: nullLabel, value: None} option is prepended -- 'Plant-wide (all
    areas)' in the editor, 'All areas' in the filter."""
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


def emptyMeta():
    """Blank meta dict for editor create-mode initialization."""
    return {
        "id":                   None,
        "code":                 "",
        "description":          "",
        "operationCategoryId":       None,
        "downtimeReasonTypeId": None,
        "isExcused":            False,
    }
