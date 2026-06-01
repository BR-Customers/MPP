# =============================================================================
# Project Library:  BlueRidge.Parts.Bom
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          2.0
#
# Description:
#   Read + mutation surface for the Item Master BOMs tab. Routes through
#   BlueRidge.Common.Db. The BOMs tab is a versioned-entity editor
#   (Draft -> Published -> Deprecated) with a per-line bundled SaveAll.
#
# Public surface:
#   Reads:
#     getActiveForItem(itemId)            -> {publishedVersion, effectiveFrom, lines[]}
#                                             | empty shape. Kept for Phase 1 shell binding.
#     listByParentItem(itemId, includeDep) -> list[dict] of version summary rows
#     getOneFull(bomId)                   -> {header, lines: [...]} bundle (UI shape)
#     listAvailableItems(itemId, search)  -> list[dict] for ChildItem dropdown
#     listUoms()                          -> list[dict] for UOM dropdown
#   Mutations:
#     handleCreateOrCloneVersion(parentItemId)
#                                         -> "+ New Version" router:
#                                              no existing Bom -> Bom_Create v1 Draft
#                                              else clone latest non-deprecated
#     handleSaveDraft(bomId, effectiveFrom, lines)
#     handlePublish(bomId, effectiveFrom, lines)
#     handleDeprecate(bomId)
#     handleDiscardDraft(bomId)
#   Helpers:
#     emptyLine() -> {} skeleton for adding a draft row in the UI
#
# Change Log:
#   2026-05-20 - 1.0 - getActiveForItem only (Phase 1 shell read)
#   2026-05-26 - 2.0 - Phase 6 BOMs editor — adds listByParentItem,
#                      getOneFull, listAvailableItems, listUoms,
#                      handleCreateOrCloneVersion, handleSaveDraft,
#                      handlePublish, handleDeprecate, handleDiscardDraft,
#                      emptyLine.
# =============================================================================

import system


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _isoDate(d):
    if d is None:
        return ""
    try:
        return str(d)[:10]
    except Exception:
        return ""


def _mapLines(rows):
    """Phase 1 read shape: minimal display fields, lowercase keys."""
    out = []
    for r in rows or []:
        out.append({
            "seq":           r.get("SortOrder"),
            "componentName": r.get("ChildDescription") or "",
            "partNumber":    r.get("ChildPartNumber") or "",
            "qtyPer":        r.get("QtyPer"),
            "uom":           r.get("UomCode") or "",
        })
    return out


def _mapEditorLines(rows):
    """Editor shape: full set of fields the BOMs editor needs (id for
    Save reconciliation, both lowercase aliases for display, and the
    raw foreign keys for dropdown bidi-bindings)."""
    out = []
    for r in rows or []:
        out.append({
            "id":            r.get("Id"),
            "bomId":         r.get("BomId"),
            "childItemId":   r.get("ChildItemId"),
            "partNumber":    r.get("ChildPartNumber") or "",
            "componentName": r.get("ChildDescription") or "",
            "qtyPer":        r.get("QtyPer"),
            "uomId":         r.get("UomId"),
            "uomCode":       r.get("UomCode") or "",
            "sortOrder":     r.get("SortOrder"),
        })
    return out


_EMPTY_BOM = {"publishedVersion": 0, "effectiveFrom": "", "lines": []}


# ---------- Phase 1 read (kept for current static shell binding) ----------

def getActiveForItem(itemId):
    """Returns the active BOM + lines for the given parent Item.
    Single entity-script call -> one binding on view.custom.data.
    Always returns a dict — empty shape when no published BOM exists
    or itemId is missing, so view bindings never traverse into None."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if not itemId:
        return dict(_EMPTY_BOM)
    try:
        header = BlueRidge.Common.Db.execOne(
            "parts/Bom_GetActiveForItem",
            {"parentItemId": itemId},
        )
        if header is None:
            return dict(_EMPTY_BOM)
        lines = BlueRidge.Common.Db.execList(
            "parts/BomLine_ListByBom",
            {"bomId": header.get("Id")},
        )
        result = dict(header)
        result["publishedVersion"] = header.get("VersionNumber")
        result["effectiveFrom"]    = _isoDate(header.get("EffectiveFrom"))
        result["lines"]            = _mapLines(lines)
        return result
    except Exception as e:
        BlueRidge.Common.Util.log("getActiveForItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load BOM", str(e), "error")
        return dict(_EMPTY_BOM)


# ---------- Phase 6 reads ----------

def listByParentItem(parentItemId, includeDeprecated=False):
    """Returns list[dict] of every Bom version for the parent Item,
    each annotated with LineCount + Status string. Used to populate the
    version dropdown."""
    parentItemId = _u(parentItemId)
    if not parentItemId:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/Bom_ListByParentItem",
            {
                "parentItemId":      parentItemId,
                "includeDeprecated": bool(_u(includeDeprecated)),
            },
        )
        out = []
        for r in rows or []:
            d = dict(r)
            d["effectiveFromDisplay"] = _isoDate(r.get("EffectiveFrom"))
            out.append(d)
        return out
    except Exception as e:
        BlueRidge.Common.Util.log("listByParentItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load BOM versions", str(e), "error")
        return []


def getOneFull(bomId):
    """Returns {header: {...}, lines: [...]} bundle for the BOMs editor.
    Always returns a dict — empty shape when bomId is missing/invalid
    so view bindings never traverse into None.

    The shape matches what the BOMs embed sets into view.custom.selected
    and seeds into view.custom.editDraft on item-id change."""
    bomId = _u(bomId)
    empty = {
        "id":               None,
        "parentItemId":     None,
        "versionNumber":    None,
        "effectiveFrom":    None,
        "effectiveFromDisplay": "",
        "publishedAt":      None,
        "deprecatedAt":     None,
        "status":           None,
        "lines":            [],
    }
    if not bomId:
        return empty
    try:
        header = BlueRidge.Common.Db.execOne(
            "parts/Bom_Get",
            {"id": bomId},
        )
        if header is None:
            return empty
        lines = BlueRidge.Common.Db.execList(
            "parts/BomLine_ListByBom",
            {"bomId": bomId},
        )
        pub = header.get("PublishedAt")
        dep = header.get("DeprecatedAt")
        if dep is not None:
            status = "Deprecated"
        elif pub is None:
            status = "Draft"
        else:
            status = "Published"
        return {
            "id":               header.get("Id"),
            "parentItemId":     header.get("ParentItemId"),
            "versionNumber":    header.get("VersionNumber"),
            "effectiveFrom":    header.get("EffectiveFrom"),
            "effectiveFromDisplay": _isoDate(header.get("EffectiveFrom")),
            "publishedAt":      pub,
            "deprecatedAt":     dep,
            "status":           status,
            "lines":            _mapEditorLines(lines),
        }
    except Exception as e:
        BlueRidge.Common.Util.log("getOneFull failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load BOM", str(e), "error")
        return empty


def listAvailableItems(parentItemId, searchText=None):
    """Returns list[dict] of Items eligible to be added as a BomLine
    component (excludes parent + deprecated)."""
    parentItemId = _u(parentItemId)
    if not parentItemId:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "parts/Item_ListAvailableForBom",
            {
                "parentItemId": parentItemId,
                "searchText":   _u(searchText),
            },
        )
        return rows or []
    except Exception as e:
        BlueRidge.Common.Util.log("listAvailableItems failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load component list", str(e), "error")
        return []


def listUoms():
    """Returns list[dict] of all active UOM rows."""
    try:
        rows = BlueRidge.Common.Db.execList("parts/Uom_List", {"includeDeprecated": False})
        return rows or []
    except Exception as e:
        BlueRidge.Common.Util.log("listUoms failed: %s" % str(e))
        return []


# ---------- Phase 6 mutations ----------

def handleCreateOrCloneVersion(parentItemId):
    """Routes '+ New Version' to either Bom_Create (no Bom exists yet
    for this Item) or Bom_CreateNewVersion (clone latest non-deprecated
    source). Both produce a Draft. Returns {Status, Message, NewId}."""
    parentItemId = _u(parentItemId)
    if not parentItemId:
        return {"Status": False,
                "Message": "No parent item selected.",
                "NewId": None}
    try:
        existing = BlueRidge.Common.Db.execList(
            "parts/Bom_ListByParentItem",
            {"parentItemId": parentItemId, "includeDeprecated": True},
        ) or []

        # If no Bom at all -> create v1 Draft via Bom_Create
        if len(existing) == 0:
            return BlueRidge.Common.Db.execMutation(
                "parts/Bom_Create",
                {
                    "parentItemId":  parentItemId,
                    "effectiveFrom": None,
                    "appUserId":     BlueRidge.Common.Util._currentAppUserId(),
                },
            )

        # If any Draft exists, refuse (UI should hide the button, but
        # surface a clean message just in case)
        anyDraft = False
        for r in existing:
            if r.get("PublishedAt") is None and r.get("DeprecatedAt") is None:
                anyDraft = True
                break
        if anyDraft:
            return {"Status": False,
                    "Message": "A draft BOM already exists for this Item. "
                               "Open it or discard it before creating a new version.",
                    "NewId": None}

        # Otherwise clone the latest non-deprecated (Published) version.
        # ListByParentItem orders Draft-first then Published DESC by
        # EffectiveFrom; with no Drafts present, [0] is the most-recent
        # Published.
        nonDep = [r for r in existing if r.get("DeprecatedAt") is None]
        sourceBomId = None
        if nonDep:
            sourceBomId = nonDep[0].get("Id")
        else:
            # All previous versions are deprecated — clone the most
            # recent deprecated (rare; engineering re-spinning an
            # archived BOM).
            sourceBomId = existing[0].get("Id")

        return BlueRidge.Common.Db.execMutation(
            "parts/Bom_CreateNewVersion",
            {
                "parentBomId":   sourceBomId,
                "effectiveFrom": None,
                "appUserId":     BlueRidge.Common.Util._currentAppUserId(),
            },
        )
    except Exception as e:
        BlueRidge.Common.Util.log("handleCreateOrCloneVersion failed: %s" % str(e))
        return {"Status": False,
                "Message": "Create version failed: " + str(e),
                "NewId": None}


def handleSaveDraft(bomId, effectiveFrom, lines):
    """Bundled save of a Draft BOM. `lines` is list[dict] in display
    shape; this serializes the proc-relevant fields to JSON and calls
    Bom_SaveDraft."""
    bomId = _u(bomId)
    effectiveFrom = _u(effectiveFrom)
    lines = _u(lines) or []
    payload = []
    for ln in lines:
        ln = _u(ln) or {}
        payload.append({
            "Id":          ln.get("id"),
            "ChildItemId": ln.get("childItemId"),
            "QtyPer":      ln.get("qtyPer"),
            "UomId":       ln.get("uomId"),
        })
    linesJson = system.util.jsonEncode(payload)
    return BlueRidge.Common.Db.execMutation(
        "parts/Bom_SaveDraft",
        {
            "id":            bomId,
            "effectiveFrom": effectiveFrom,
            "linesJson":     linesJson,
            "appUserId":     BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def handlePublish(bomId, effectiveFrom=None, lines=None):
    """Publish a Draft. Optionally also reconciles lines in the same
    atomic (save-and-publish). Pass `lines` None to publish without
    saving line edits."""
    bomId = _u(bomId)
    effectiveFrom = _u(effectiveFrom)
    lines = _u(lines)
    linesJson = None
    if lines is not None:
        payload = []
        for ln in lines:
            ln = _u(ln) or {}
            payload.append({
                "Id":          ln.get("id"),
                "ChildItemId": ln.get("childItemId"),
                "QtyPer":      ln.get("qtyPer"),
                "UomId":       ln.get("uomId"),
            })
        linesJson = system.util.jsonEncode(payload)
    return BlueRidge.Common.Db.execMutation(
        "parts/Bom_Publish",
        {
            "id":            bomId,
            "effectiveFrom": effectiveFrom,
            "linesJson":     linesJson,
            "appUserId":     BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def handleDeprecate(bomId):
    """Deprecate a Published BOM."""
    bomId = _u(bomId)
    return BlueRidge.Common.Db.execMutation(
        "parts/Bom_Deprecate",
        {
            "id":        bomId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


def handleDiscardDraft(bomId):
    """Physically delete a Draft BOM + cascade BomLines."""
    bomId = _u(bomId)
    return BlueRidge.Common.Db.execMutation(
        "parts/Bom_DiscardDraft",
        {
            "id":        bomId,
            "appUserId": BlueRidge.Common.Util._currentAppUserId(),
        },
    )


# ---------- Helpers ----------

def emptyLine():
    """Returns a blank BomLine skeleton for the UI to append on
    '+ Add Component' click. Id NULL signals the SaveDraft proc to
    INSERT this as a new row."""
    return {
        "id":            None,
        "bomId":         None,
        "childItemId":   None,
        "partNumber":    "",
        "componentName": "",
        "qtyPer":        1,
        "uomId":         None,
        "uomCode":       "",
        "sortOrder":     None,
    }
