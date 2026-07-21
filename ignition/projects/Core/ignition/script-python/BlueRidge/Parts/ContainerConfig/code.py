# =============================================================================
# Project Library:  BlueRidge.Parts.ContainerConfig
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.1
#
# Description:
#   Read + mutation surface for the Item Master Container Config tab.
#   Routes through BlueRidge.Common.Db.*.
#
# Public surface:
#   getByItem(itemId) -> dict | None
#   add(data)         -> {Status, Message, NewId}
#   update(data)      -> {Status, Message}
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (getByItem only).
#   2026-05-26 - 1.1 - Phase 4: add() + update() mutation surface.
# =============================================================================


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
        BlueRidge.Common.Util.log("getByItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load container config", str(e), "error")
        return {}


_CONFIG_SHAPE = {
    "Id": None, "ItemId": None,
    "TraysPerContainer": 0, "PartsPerTray": 0,
    "IsSerialized": False,
    "DunnageCode": "", "CustomerCode": "",
    "ClosureMethod": "", "TargetWeight": None,
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


def add(data):
    """Create a new active ContainerConfig for an Item.

    data: {ItemId, TraysPerContainer, PartsPerTray, IsSerialized,
           ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
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
            "appUserId":         BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def deprecate(configId):
    """Soft-delete (deprecate) one active ContainerConfig row by Id. Used by the
       per-method Item Master editor to REMOVE a pack-out (e.g. clear ByVision so
       a part is only ByCount + ByWeight). Returns {Status, Message}."""
    configId = _u(configId)
    BlueRidge.Common.Util.log("deprecate configId=%s" % configId)
    return BlueRidge.Common.Db.execMutation(
        "parts/ContainerConfig_Deprecate",
        {"id": configId, "appUserId": BlueRidge.Common.Util._currentAppUserId()},
    )


def update(data):
    """Update an existing active ContainerConfig in place. ItemId is
    immutable per the proc -- to re-associate with a different Item,
    deprecate this one and add a new one.

    data: {Id, TraysPerContainer, PartsPerTray, IsSerialized,
           ClosureMethod, TargetWeight, DunnageCode, CustomerCode}
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
            "appUserId":         BlueRidge.Common.Util._currentAppUserId(),
        },
    )
