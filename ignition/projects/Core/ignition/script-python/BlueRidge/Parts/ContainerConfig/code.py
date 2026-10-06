# =============================================================================
# Project Library:  BlueRidge.Parts.ContainerConfig
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.4
#
# Description:
#   Read + mutation surface for the Item Master Container Config tab.
#   Routes through BlueRidge.Common.Db.*.
#
# Public surface:
#   getByItem(itemId) -> dict | None
#   add(data)         -> {Status, Message, NewId}
#   update(data)      -> {Status, Message}
#   getDraftForItem(itemId)              -> {ByCount, ByWeight, ByVision} edit shape
#   saveDraft(itemId, draft, appUserId)  -> {Status, Message}
#   getHistoryForItem(itemId)            -> {options, rows} past pack-outs to reload
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (getByItem only).
#   2026-05-26 - 1.1 - Phase 4: add() + update() mutation surface.
#   2026-08-27 - 1.2 - ToleranceWeight threaded through the shape + add/update.
#   2026-10-06 - 1.3 - judgeWeight(): the SQL checkweigh verdict (EPrint scales).
#   2026-10-06 - 1.4 - getDraftForItem() + saveDraft(): the per-method edit shape and
#                      its save, for the shop-floor Pack-Out popup.
#                      getHistoryForItem(): past value sets (Parts.ContainerConfig_ListHistory).
# =============================================================================

import java.lang


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getByItem(itemId):
    """Returns the active ContainerConfig row for the Item.
    Always returns a dict (possibly empty) so view bindings on
    view.custom.data.<field> never traverse into None."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if not itemId:
        return {}
    try:
        row = BlueRidge.Common.Db.execOne(
            "parts/ContainerConfig_GetByItem",
            {"itemId": itemId},
        )
        return row if row is not None else {}
    except Exception as e:
        BlueRidge.Common.Util.log("getByItem failed: %s" % str(e), level="warn")
        BlueRidge.Common.Notify.toast(
            "Could not load container config", str(e), "error")
        return {}


_CONFIG_SHAPE = {
    "Id": None, "ItemId": None,
    "TraysPerContainer": 0, "PartsPerTray": 0,
    "IsSerialized": False,
    "DunnageCode": "", "CustomerCode": "",
    "ClosureMethod": "", "TargetWeight": None, "ToleranceWeight": None,
}


def getByItemOrEmpty(itemId, _refreshToken=None):
    """Binding-safe getByItem: ALWAYS returns the full ContainerConfig key
       shape (zeros/blanks when the item has no config) so nested binding
       reads like {view.custom.fgConfig.PartsPerTray} never traverse a
       missing key (pre-declared-bound-props rule). Used by the assembly
       screens to surface/prefill the selected finished good's container
       config before any container is open (2026-07-08).
       _refreshToken is ignored - runScript bindings pass a bumped token."""
    out = dict(_CONFIG_SHAPE)
    row = getByItem(itemId)
    if row:
        for k in out.keys():
            if row.get(k) is not None:
                out[k] = row.get(k)
    return out


def getByItemAll(itemId, _refreshToken=None):
    """All active ContainerConfigs for an Item -- one per closure method,
       ordered by method (ByCount/ByWeight/ByVision). Always returns a list
       (never None) so a runScript-bound list prop is never overwritten with
       null. Used by the per-method Item Master ContainerConfig editor and by
       assembly capability resolution.
       _refreshToken is ignored - runScript bindings pass a bumped token."""
    itemId = _u(itemId)
    if not itemId:
        return []
    return BlueRidge.Common.Db.execList(
        "parts/ContainerConfig_GetByItem", {"itemId": itemId}) or []


def getByItemAndMethod(itemId, method):
    """The single active ContainerConfig for (Item, closure method), or {}.
       This is the assembly-out resolver: the terminal's CurrentClosureMethod
       selects which of the part's per-method pack-outs applies."""
    itemId = _u(itemId)
    method = _u(method)
    if not itemId or not method:
        return {}
    row = BlueRidge.Common.Db.execOne(
        "parts/ContainerConfig_GetByItemAndMethod",
        {"itemId": itemId, "closureMethod": method})
    return row if row is not None else {}


def judgeWeight(itemId, method, weight):
    """The checkweigh verdict for one tray, computed in SQL
       (Parts.ContainerConfig_JudgeWeight) against the part's TargetWeight +/-
       ToleranceWeight. Returns the proc's single row:
         {Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit}
       Verdict is Ok | Under | Over | NoConfig | NoTolerance | NoWeight.

       No comparison happens here. A caller acts on Verdict == 'Ok' and shows
       Message otherwise; it never re-derives the window. Returns None only if
       the query itself returned nothing, which the caller must treat as a
       refusal, not a pass."""
    return BlueRidge.Common.Db.execOne(
        "parts/ContainerConfig_JudgeWeight",
        {"itemId": _u(itemId), "closureMethod": _u(method), "weight": _u(weight)})


def getByItemAndMethodOrEmpty(itemId, method, _refreshToken=None):
    """Binding-safe getByItemAndMethod: ALWAYS returns the full ContainerConfig key
       shape (zeros/blanks when the item has no pack-out for that closure method) so
       nested header/prefill reads like {view.custom.fgConfig.PartsPerTray} never
       traverse a missing key (pre-declared-bound-props rule). Method-aware sibling
       of getByItemOrEmpty -- the assembly-out header shows the ACTIVE closure
       method's pack-out (e.g. the ByWeight 12/6), not the part's first config.
       _refreshToken is ignored - runScript bindings pass a bumped token."""
    out = dict(_CONFIG_SHAPE)
    row = getByItemAndMethod(itemId, method)
    if row:
        for k in out.keys():
            if row.get(k) is not None:
                out[k] = row.get(k)
    return out


def add(data, appUserId=None):
    """Create a new active ContainerConfig for an Item.

    data: {ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
           ClosureMethod, TargetWeight, ToleranceWeight,
           DunnageCode, CustomerCode}
    Returns {Status, Message, NewId}.

    The proc enforces at-most-one-active-config-per-Item via a filtered
    unique index. Attempting to add a second active config for the same
    Item returns Status=0 with a descriptive message.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Create",
        {
            "itemId":            data.get("ItemId"),
            "traysPerContainer": data.get("TraysPerContainer"),
            "partsPerTray":      data.get("PartsPerTray"),
            "isSerialized":      bool(data.get("IsSerialized", False)),
            "dunnageCode":       data.get("DunnageCode"),
            "customerCode":      data.get("CustomerCode"),
            "closureMethod":     data.get("ClosureMethod"),
            "targetWeight":      data.get("TargetWeight"),
            "toleranceWeight":   data.get("ToleranceWeight"),
            "appUserId":         BlueRidge.Common.Util.requireAppUserId(appUserId),
        },
    )


def deprecate(configId, appUserId=None):
    """Soft-delete (deprecate) one active ContainerConfig row by Id. Used by the
       per-method Item Master editor to REMOVE a pack-out (e.g. clear ByVision so
       a part is only ByCount + ByWeight). Returns {Status, Message}."""
    configId = _u(configId)
    BlueRidge.Common.Util.log("deprecate configId=%s" % configId)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Deprecate",
        {"id": configId, "appUserId": BlueRidge.Common.Util.requireAppUserId(appUserId)},
    )


def update(data, appUserId=None):
    """Update an existing active ContainerConfig in place. ItemId is
    immutable per the proc -- to re-associate with a different Item,
    deprecate this one and add a new one.

    data: {Id, TraysPerContainer, PartsPerTray, IsSerialized,
           ClosureMethod, TargetWeight, ToleranceWeight,
           DunnageCode, CustomerCode}
    Returns {Status, Message}.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Update",
        {
            "id":                data.get("Id"),
            "traysPerContainer": data.get("TraysPerContainer"),
            "partsPerTray":      data.get("PartsPerTray"),
            "isSerialized":      bool(data.get("IsSerialized", False)),
            "dunnageCode":       data.get("DunnageCode"),
            "customerCode":      data.get("CustomerCode"),
            "closureMethod":     data.get("ClosureMethod"),
            "targetWeight":      data.get("TargetWeight"),
            "toleranceWeight":   data.get("ToleranceWeight"),
            "appUserId":         BlueRidge.Common.Util.requireAppUserId(appUserId),
        },
    )


_METHODS = ("ByCount", "ByWeight", "ByVision")


def _blankBlock(itemId, method, configId=None):
    return {
        "Id": configId, "ItemId": itemId, "ClosureMethod": method,
        "Active": False,
        "PartsPerTray": "", "TraysPerContainer": "",
        "DunnageCode": "", "CustomerCode": "",
        "IsSerialized": False, "TargetWeight": "", "ToleranceWeight": "",
    }


def getDraftForItem(itemId):
    """The per-method edit shape for an Item's pack-outs: one block per closure
       method, every key always present, numbers as strings so text inputs can
       bind them. Active = the Item has an active config for that method.
       Mirrors the Item Master ContainerConfig tab's load(); used by the
       shop-floor Pack-Out popup."""
    itemId = _u(itemId)
    def _s(v):
        return "" if v is None else (v if isinstance(v, basestring) else unicode(v))
    byMethod = {}
    for r in (getByItemAll(itemId) if itemId else []):
        if r.get("ClosureMethod"):
            byMethod[r.get("ClosureMethod")] = r
    out = {}
    for m in _METHODS:
        block = _blankBlock(itemId, m)
        r = byMethod.get(m)
        if r:
            block.update({
                "Id":                r.get("Id"),
                "Active":            True,
                "PartsPerTray":      _s(r.get("PartsPerTray")),
                "TraysPerContainer": _s(r.get("TraysPerContainer")),
                "DunnageCode":       _s(r.get("DunnageCode")),
                "CustomerCode":      _s(r.get("CustomerCode")),
                "IsSerialized":      bool(r.get("IsSerialized", False)),
                "TargetWeight":      _s(r.get("TargetWeight")),
                "ToleranceWeight":   _s(r.get("ToleranceWeight")),
            })
        out[m] = block
    return out


def _toNum(v):
    if v is None or v == "":
        return None
    try:
        return int(v)
    except (ValueError, TypeError):
        try:
            return float(v)
        except (ValueError, TypeError):
            return None


def saveDraft(itemId, draft, appUserId=None):
    """Save a getDraftForItem()-shaped draft: a block with a positive
       PartsPerTray is created (no Id) or updated (Id); a block with an Id and
       no PartsPerTray is deprecated. Mirrors the Item Master ContainerConfig
       tab's handleSave(); the procs stay authoritative for validation + audit.
       Returns {Status, Message} -- Status False with every failure joined in
       Message when any row was refused, and nothing is written when a
       required field is missing."""
    itemId = _u(itemId)
    draft = system.util.jsonDecode(
        BlueRidge.Common.Util.convertWrapperObjectToJson(draft)) or {}
    if not itemId:
        return {"Status": False, "Message": "No part selected."}
    toSave = []
    toDeprecate = []
    for m in _METHODS:
        block = draft.get(m) or {}
        priorId = block.get("Id")
        partsPerTray = _toNum(block.get("PartsPerTray"))
        if partsPerTray is not None and partsPerTray > 0:
            trays = _toNum(block.get("TraysPerContainer"))
            if trays is None or trays <= 0:
                return {"Status": False, "Message": "Enter a positive trays per container for the %s pack-out." % m}
            targetWeight = None
            toleranceWeight = None
            if m == "ByWeight":
                targetWeight = _toNum(block.get("TargetWeight"))
                if targetWeight is None or targetWeight <= 0:
                    return {"Status": False, "Message": "The By Weight pack-out requires a positive target weight."}
                toleranceWeight = _toNum(block.get("ToleranceWeight"))
                if toleranceWeight is None or toleranceWeight <= 0:
                    return {"Status": False, "Message": "The By Weight pack-out requires a positive tolerance - a zero-width window rejects every tray."}
            toSave.append({
                "Id": priorId, "ItemId": itemId, "ClosureMethod": m,
                "TraysPerContainer": trays, "PartsPerTray": partsPerTray,
                "TargetWeight": targetWeight, "ToleranceWeight": toleranceWeight,
                "DunnageCode": block.get("DunnageCode"),
                "CustomerCode": block.get("CustomerCode"),
                "IsSerialized": bool(block.get("IsSerialized", False)),
            })
        elif priorId:
            toDeprecate.append({"Id": priorId, "ClosureMethod": m})
    if not toSave and not toDeprecate:
        return {"Status": False, "Message": "Nothing to save - add at least one pack-out."}
    failures = []
    for payload in toSave:
        if payload.get("Id"):
            result = update(payload, appUserId=appUserId)
        else:
            result = add(payload, appUserId=appUserId)
        if not (result and result.get("Status")):
            failures.append("%s - %s" % (payload["ClosureMethod"], (result or {}).get("Message") or "Unknown error"))
    for dep in toDeprecate:
        result = deprecate(dep["Id"], appUserId=appUserId)
        if not (result and result.get("Status")):
            failures.append("%s - %s" % (dep["ClosureMethod"], (result or {}).get("Message") or "Unknown error"))
    if failures:
        return {"Status": False, "Message": "; ".join(failures)}
    return {"Status": True, "Message": "Pack-out configuration saved."}


def getHistoryForItem(itemId):
    """Past pack-out value sets for an Item (Parts.ContainerConfig_ListHistory),
       shaped for the Pack-Out popup's per-method "load a previous pack-out"
       dropdowns. ALWAYS returns the full shape:
         {"options": {ByCount: [{label, value}], ByWeight: [...], ByVision: [...]},
          "rows":    {"<HistoryKey>": {<draft-block value fields, as strings>}}}
       Which sets exist, their order and their labels are decided in SQL; this
       only regroups the rows. A failed read yields the empty shape -- history
       is a convenience and must never stop the editor opening."""
    itemId = _u(itemId)
    out = {"options": dict((m, []) for m in _METHODS), "rows": {}}
    if not itemId:
        return out
    def _s(v):
        return "" if v is None else (v if isinstance(v, basestring) else unicode(v))
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/ContainerConfig_ListHistory", {"itemId": itemId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("getHistoryForItem failed: %s" % str(e), level="warn")
        return out
    for r in rows:
        m = r.get("ClosureMethod")
        if m not in out["options"]:
            continue
        key = "%s" % r.get("HistoryKey")
        out["options"][m].append({"label": _s(r.get("Label")), "value": key})
        out["rows"][key] = {
            "PartsPerTray":      _s(r.get("PartsPerTray")),
            "TraysPerContainer": _s(r.get("TraysPerContainer")),
            "DunnageCode":       _s(r.get("DunnageCode")),
            "CustomerCode":      _s(r.get("CustomerCode")),
            "IsSerialized":      bool(r.get("IsSerialized", False)),
            "TargetWeight":      _s(r.get("TargetWeight")),
            "ToleranceWeight":   _s(r.get("ToleranceWeight")),
        }
    return out
