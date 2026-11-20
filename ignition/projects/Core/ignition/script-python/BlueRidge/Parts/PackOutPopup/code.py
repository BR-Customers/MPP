# =============================================================================
# Project Library:  BlueRidge.Parts.PackOutPopup
#
# Author:           Blue Ridge Automation
# Created:          2026-11-20
# Version:          1.0
#
# Description:
#   Glue for the station Pack-Out popup (MPP Popups/PackOutEdit) and its
#   per-pack-out buttons (named pack-outs, migration 0136). Shapes rows into
#   the popup's edit blocks and back; decides NOTHING about pack-outs -- every
#   rule (which one runs, validation, versioning, the open-box refusal) is SQL,
#   reached through BlueRidge.Parts.ContainerConfig.
#
#   The popup keeps one edit block per closure method:
#     {PackOutId, ItemId, ClosureMethod, Name, Active, IsDefault, VersionNumber,
#      PartsPerTray, TraysPerContainer, TargetWeight, ToleranceWeight,
#      DunnageCode, CustomerCode, IsSerialized}
#   Numbers are TEXT in a block (the keypad types characters).
#
# Public surface:
#   blankBlock(itemId, method)                       -> block (Active False)
#   blockFromRow(itemId, row)                         -> block (Active True)
#   draftForItem(itemId, packOuts)                    -> {ByCount, ByWeight, ByVision}
#   buttonInstances(itemId, method, terminalLocationId, _token=None) -> repeater instances
#   saveDraft(itemId, draft, loaded, appUserId)       -> {Status, Message, Saved}
#
# Change Log:
#   2026-11-20 - 1.0 - Initial version (named pack-outs).
# =============================================================================

import java.lang

_FIELDS = ("PartsPerTray", "TraysPerContainer", "TargetWeight", "ToleranceWeight",
           "DunnageCode", "CustomerCode")


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _s(v):
    """Text for a block field: '' for None, numbers without trailing zeros."""
    if v is None:
        return ""
    if isinstance(v, basestring):
        return v
    return BlueRidge.Parts.ContainerConfig._fmt(v)


def blankBlock(itemId, method):
    """An empty edit block for a method (no pack-out loaded, form hidden)."""
    return {"PackOutId": None, "ItemId": _u(itemId), "ClosureMethod": method,
            "Name": "", "Active": False, "IsDefault": False, "VersionNumber": None,
            "PartsPerTray": "", "TraysPerContainer": "", "TargetWeight": "",
            "ToleranceWeight": "", "DunnageCode": "", "CustomerCode": "",
            "IsSerialized": False}


def blockFromRow(itemId, row):
    """A Parts.PackOut_ListByItem row as an edit block (form shown)."""
    row = _u(row) or {}
    b = blankBlock(itemId, row.get("ClosureMethod"))
    b.update({"PackOutId": row.get("PackOutId"), "Name": row.get("Name") or "",
              "Active": True, "IsDefault": bool(row.get("IsDefault")),
              "VersionNumber": row.get("VersionNumber"),
              "IsSerialized": bool(row.get("IsSerialized"))})
    for f in _FIELDS:
        b[f] = _s(row.get(f))
    return b


def draftForItem(itemId, packOuts):
    """Initial edit blocks: per method, the pack-out RUNNING at this terminal
       (SQL's IsRunning) loaded into the form, else a blank block."""
    packOuts = _u(packOuts) or {}
    out = {}
    for m in BlueRidge.Parts.ContainerConfig.METHODS:
        running = [r for r in (packOuts.get(m) or []) if r.get("IsRunning")]
        out[m] = blockFromRow(itemId, running[0]) if running else blankBlock(itemId, m)
    return out


def buttonInstances(itemId, method, terminalLocationId, _token=None):
    """flex-repeater instances for one method's pack-out buttons: one per
       active pack-out, in SQL's order. _token is ignored (bumped to refresh)."""
    rows = BlueRidge.Parts.ContainerConfig.listForItem(itemId, terminalLocationId).get(method) or []
    out = []
    for r in rows:
        out.append({"packOutId": r.get("PackOutId"), "method": method,
                    "name": r.get("Name") or "", "summary": r.get("Summary") or "",
                    "isDefault": bool(r.get("IsDefault")), "isRunning": bool(r.get("IsRunning"))})
    return out


def _same(a, b):
    keys = ("Name", "IsSerialized") + _FIELDS
    for k in keys:
        x, y = a.get(k), b.get(k)
        if k == "IsSerialized":
            if bool(x) != bool(y):
                return False
        elif ("%s" % (x if x is not None else "")).strip() != ("%s" % (y if y is not None else "")).strip():
            return False
    return True


def saveDraft(itemId, draft, loaded, appUserId):
    """Saves every ACTIVE block that differs from what was loaded (an
       untouched block is not re-sent, so SQL's 'No changes' refusal never
       shows for it). Each save is Parts.PackOut_Save; a value change there
       becomes a new version. Returns {Status, Message, Saved} -- Status False
       with every refusal joined when any block was refused."""
    itemId = _u(itemId)
    draft = system.util.jsonDecode(BlueRidge.Common.Util.convertWrapperObjectToJson(draft)) or {}
    loaded = system.util.jsonDecode(BlueRidge.Common.Util.convertWrapperObjectToJson(loaded)) or {}
    if not itemId:
        return {"Status": False, "Message": "No part selected.", "Saved": 0}
    failures, saved = [], 0
    for m in BlueRidge.Parts.ContainerConfig.METHODS:
        b = draft.get(m) or {}
        if not b.get("Active"):
            continue
        if b.get("PackOutId") and _same(b, loaded.get(m) or {}):
            continue
        payload = dict(b)
        payload["ItemId"] = itemId
        payload["ClosureMethod"] = m
        res = BlueRidge.Parts.ContainerConfig.save(payload, appUserId) or {}
        if res.get("Status"):
            saved += 1
        else:
            failures.append("%s - %s" % (m, res.get("Message") or "Unknown error"))
    if failures:
        return {"Status": False, "Message": "; ".join(failures), "Saved": saved}
    if saved == 0:
        return {"Status": False, "Message": "Nothing to save - no pack-out was changed.", "Saved": 0}
    return {"Status": True, "Message": "Pack-out saved.", "Saved": saved}
