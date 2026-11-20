# =============================================================================
# Project Library:  BlueRidge.Parts.ContainerConfig
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          2.0
#
# Description:
#   Pack-outs (migration 0136, named pack-outs). A part has several NAMED
#   pack-outs per closure method (Parts.PackOut), one of them the default; each
#   pack-out's values live in immutable versions (Parts.ContainerConfig). A
#   terminal picks which one it runs (Location.TerminalPackOutSelection).
#
#   The rules live in SQL. This module only routes: no validation, no
#   resolution, no defaults are decided here. "Which pack-out is in force"
#   is Parts.ufn_PackOutInForce (open box's own version > terminal pick >
#   default), reached through getByItemAndMethod / judgeWeight /
#   listForItem with the caller's terminal.
#
# Public surface:
#   getByItemAndMethod(itemId, method, terminalLocationId=None)      -> dict | {}
#   getByItemAndMethodOrEmpty(itemId, method, _refreshToken=None,
#                             terminalLocationId=None)               -> full-shape dict
#   judgeWeight(itemId, method, weight, scaleFlags=None,
#               terminalLocationId=None)                             -> dict | None
#   listForItem(itemId, terminalLocationId=None, _refreshToken=None) -> {ByCount:[..], ByWeight:[..], ByVision:[..]}
#   save(packOut, appUserId)            -> {Status, Message, NewId}
#   setDefault(packOutId, appUserId)    -> {Status, Message}
#   deprecate(packOutId, appUserId)     -> {Status, Message}
#   select(terminalLocationId, packOutId, appUserId) -> {Status, Message}
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (getByItem only).
#   2026-05-26 - 1.1 - Phase 4: add() + update() mutation surface.
#   2026-08-27 - 1.2 - ToleranceWeight threaded through the shape + add/update.
#   2026-10-06 - 1.3 - judgeWeight(): the SQL checkweigh verdict (EPrint scales).
#   2026-10-06 - 1.4 - getDraftForItem() + saveDraft() + getHistoryForItem().
#   2026-10-19 - 1.5 - judgeWeight(scaleFlags=).
#   2026-11-20 - 2.0 - Named pack-outs (0136). getByItemAndMethod / judgeWeight
#                      take the caller's terminal and return the pack-out IN
#                      FORCE. New listForItem / save / setDefault / deprecate
#                      (by PackOutId) / select. Removed getByItem, getByItemOrEmpty,
#                      getByItemAll, add, update, getDraftForItem, saveDraft,
#                      getHistoryForItem (their procs are dropped).
# =============================================================================

import java.lang

METHODS = ("ByCount", "ByWeight", "ByVision")


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


_CONFIG_SHAPE = {
    "Id": None, "ItemId": None,
    "TraysPerContainer": 0, "PartsPerTray": 0,
    "IsSerialized": False,
    "DunnageCode": "", "CustomerCode": "",
    "ClosureMethod": "", "TargetWeight": None, "ToleranceWeight": None,
    "PackOutId": None, "PackOutName": "", "PackOutSource": "", "VersionNumber": None,
}


def getByItemAndMethod(itemId, method, terminalLocationId=None):
    """The pack-out IN FORCE for (Item, closure method) at the terminal, or {}:
       the open box's own version when the next tray goes into an open box,
       else the terminal's pick, else the part's default (SQL decides --
       Parts.ContainerConfig_GetByItemAndMethod v1.2). No terminal = default.
       Returns the proc row: Id (the version's ContainerConfig Id), PartsPerTray,
       TraysPerContainer, TargetWeight, ToleranceWeight, ..., PackOutId,
       PackOutName, PackOutSource ('OpenBox'|'Selected'|'Default'), VersionNumber."""
    itemId = _u(itemId)
    method = _u(method)
    if not itemId or not method:
        return {}
    row = BlueRidge.Common.Db.execOne(
        "parts/ContainerConfig_GetByItemAndMethod",
        {"itemId": itemId, "closureMethod": method,
         "terminalLocationId": _u(terminalLocationId) or None})
    return row if row is not None else {}


def getByItemAndMethodOrEmpty(itemId, method, _refreshToken=None, terminalLocationId=None):
    """Binding-safe getByItemAndMethod: ALWAYS the full key shape (zeros/blanks
       when there is no pack-out), so nested reads like
       {view.custom.fgConfig.PartsPerTray} never traverse a missing key.
       _refreshToken is ignored - runScript bindings pass a bumped token. The
       terminal is the LAST argument so older bindings keep working."""
    out = dict(_CONFIG_SHAPE)
    row = getByItemAndMethod(itemId, method, terminalLocationId)
    if row:
        for k in out.keys():
            if row.get(k) is not None:
                out[k] = row.get(k)
    return out


def judgeWeight(itemId, method, weight, scaleFlags=None, terminalLocationId=None):
    """The checkweigh verdict for one tray, computed in SQL
       (Parts.ContainerConfig_JudgeWeight v1.2) against the pack-out IN FORCE at
       the terminal -- the box the tray goes into. Returns the proc's single row:
         {Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit,
          ScaleVerdict, FlagsAgree, FlagsMessage, PackOutName}
       Verdict is Ok | Under | Over | NoConfig | NoTolerance | NoWeight.

       scaleFlags is the scale's own printed {"under", "over", "ok"} (each an
       int), or None. SQL classifies and compares them; they never change
       Verdict. No comparison happens here. Returns None only if the query
       itself returned nothing, which the caller must treat as a refusal."""
    flags = scaleFlags or {}
    return BlueRidge.Common.Db.execOne(
        "parts/ContainerConfig_JudgeWeight",
        {"itemId": _u(itemId), "closureMethod": _u(method), "weight": _u(weight),
         "scaleUnder": flags.get("under"), "scaleOver": flags.get("over"),
         "scaleOk": flags.get("ok"),
         "terminalLocationId": _u(terminalLocationId) or None})


def _fmt(v):
    """Display text for a number (no trailing .0000)."""
    if v is None:
        return ""
    try:
        f = float(v)
    except (ValueError, TypeError):
        return unicode(v)
    s = ("%.2f" % f).rstrip("0").rstrip(".")
    return s


def listForItem(itemId, terminalLocationId=None, _refreshToken=None):
    """The part's active named pack-outs (Parts.PackOut_ListByItem), grouped by
       closure method. ALWAYS the full shape {ByCount: [], ByWeight: [], ByVision: []}
       (a binding never sees None). Each row is the proc's row plus:
         Summary - display text, e.g. "6/tray x 1 - 15 lb +/- 1.35"
       IsRunning / IsSelected are SQL's (with a terminal); order is SQL's.
       A failed read yields the empty shape -- the popup must still open."""
    out = dict((m, []) for m in METHODS)
    itemId = _u(itemId)
    if not itemId:
        return out
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/PackOut_ListByItem",
            {"itemId": itemId, "terminalLocationId": _u(terminalLocationId) or None}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("listForItem failed: %s" % str(e), level="warn")
        return out
    for r in rows:
        m = r.get("ClosureMethod")
        if m not in out:
            continue
        row = dict(r)
        summary = "%s/tray x %s" % (_fmt(r.get("PartsPerTray")), _fmt(r.get("TraysPerContainer")))
        if r.get("TargetWeight") is not None:
            summary += " - %s lb +/- %s" % (_fmt(r.get("TargetWeight")), _fmt(r.get("ToleranceWeight")))
        row["Summary"] = summary
        out[m].append(row)
    return out


def save(packOut, appUserId):
    """Create (no PackOutId) or edit one named pack-out through
       Parts.PackOut_Save. A value change saves a new version; SQL validates
       everything (name, positive counts, By Weight target/tolerance).
       packOut: {PackOutId?, ItemId, ClosureMethod, Name, TraysPerContainer,
                 PartsPerTray, IsSerialized, DunnageCode, CustomerCode,
                 TargetWeight, ToleranceWeight}
       Numbers may arrive as text from a keypad; blank text is sent as NULL and
       SQL refuses what it must. Returns {Status, Message, NewId}."""
    p = _u(packOut) or {}

    def _n(v):
        if v is None:
            return None
        if isinstance(v, basestring):
            v = v.strip()
            if v == "":
                return None
        return v

    def _s(v):
        v = _n(v)
        return None if v is None else unicode(v)

    return BlueRidge.Common.Db.execMutation(
        "parts/PackOut_Save",
        {
            "packOutId":         _n(p.get("PackOutId")),
            "itemId":            _n(p.get("ItemId")),
            "closureMethod":     _s(p.get("ClosureMethod")),
            "name":              _s(p.get("Name")),
            "traysPerContainer": _n(p.get("TraysPerContainer")),
            "partsPerTray":      _n(p.get("PartsPerTray")),
            "isSerialized":      bool(p.get("IsSerialized") or False),
            "dunnageCode":       _s(p.get("DunnageCode")),
            "customerCode":      _s(p.get("CustomerCode")),
            "targetWeight":      _n(p.get("TargetWeight")),
            "toleranceWeight":   _n(p.get("ToleranceWeight")),
            "appUserId":         BlueRidge.Common.Util.requireAppUserId(appUserId),
        },
    )


def setDefault(packOutId, appUserId):
    """Make the pack-out its part's default for its closure method.
       Returns {Status, Message}."""
    return BlueRidge.Common.Db.execMutation(
        "parts/PackOut_SetDefault",
        {"packOutId": _u(packOutId), "appUserId": BlueRidge.Common.Util.requireAppUserId(appUserId)})


def deprecate(packOutId, appUserId):
    """Remove a named pack-out (SQL refuses the default while others exist).
       Returns {Status, Message}."""
    return BlueRidge.Common.Db.execMutation(
        "parts/PackOut_Deprecate",
        {"packOutId": _u(packOutId), "appUserId": BlueRidge.Common.Util.requireAppUserId(appUserId)})


def select(terminalLocationId, packOutId, appUserId):
    """The terminal runs this pack-out for its part from the next box on
       (Location.Terminal_SetPackOut). SQL refuses while a box is open, for a
       non-terminal, and a no-op; the Message says which. Returns {Status, Message}."""
    return BlueRidge.Common.Db.execMutation(
        "location/Terminal_SetPackOut",
        {"terminalLocationId": _u(terminalLocationId), "packOutId": _u(packOutId),
         "appUserId": BlueRidge.Common.Util.requireAppUserId(appUserId)})
