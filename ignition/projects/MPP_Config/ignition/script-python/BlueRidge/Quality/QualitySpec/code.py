# =============================================================================
# Project Library:  BlueRidge.Quality.QualitySpec
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          2.0
#
# Description:
#   Read + mutation surface for the Item Master Quality Specs tab AND the
#   standalone Quality Spec Config Tool. listForItem remains the Item Master
#   tab read; the Config Tool adds a library list, header/version reads, and
#   the full versioned-entity lifecycle (Draft -> Published -> Deprecated).
#   All DB access routes through BlueRidge.Common.Db.
#
# Public surface:
#   Item Master tab:
#     listForItem(itemId)                 -> list[dict] {id, specName,
#                                            activeVersion, statusLabel}
#   Config Tool reads:
#     getAllForList(filter)               -> list[dict] library rows (filtered
#                                            client-side by searchText + type)
#     getSpecHeader(specId)               -> header dict | empty shape
#     listVersions(specId, includeDep)    -> list[dict] version summary rows
#     getVersionFull(versionId)           -> {version header + attributes[]
#                                            + derived status} | empty shape
#     listUoms()                          -> list[dict] for UOM dropdown
#     emptyAttribute()                    -> {} skeleton for a new draft attr
#   Config Tool mutations:
#     createSpec(data)
#     updateSpecHeader(data)              -- passes itemId + operationTemplateId
#                                            through so the proc does not wipe
#                                            the spec's links
#     deprecateSpec(specId)
#     createNewVersion(specId)            -- v1 create or clone-latest router
#     saveDraft(versionId, effectiveFrom, attributes)
#     publish(versionId, effectiveFrom, attributes)   -- save-then-publish
#     discardDraft(versionId)
#     deprecateVersion(versionId)
#
# Note:
#   listForItem.activeVersion is left blank in Phase 2 — populating it requires
#   a per-spec lookup of the active QualitySpecVersion.VersionNumber. statusLabel
#   is derived from the proc's ActiveVersionCount.
#
#   getSpecHeader.deprecatedAt: Quality.QualitySpec_Get does NOT currently
#   select DeprecatedAt, so this resolves to None until the proc is extended.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (read paths only).
#   2026-05-29 - 2.0 - Quality Spec Config Tool: reads + version mutations.
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


def _statusFor(activeCount, totalCount):
    if activeCount and activeCount > 0:
        return "Active"
    if totalCount and totalCount > 0:
        return "Draft"
    return "None"


def listForItem(itemId):
    """List Quality Specs linked to the given Item. Empty list when none."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if not itemId:
        return []
    try:
        rows = BlueRidge.Common.Db.execList(
            "quality/QualitySpec_ListForItem",
            {"itemId": itemId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("listForItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load quality specs", str(e), "error")
        return []
    out = []
    for r in rows or []:
        out.append({
            "id":            r.get("Id"),
            "specName":      r.get("Name") or "",
            "activeVersion": "",
            "statusLabel":   _statusFor(
                r.get("ActiveVersionCount"),
                r.get("VersionCount"),
            ),
        })
    return out


# ---------- Config Tool reads ----------

def getAllForList(filter=None):
    """Library list rows. filter = {searchText, type} where type in
    All|Item-Linked|Op-Linked|Unlinked. Returns list[dict] with a
    derived state badge resolved client-side, plus link sublines."""
    f = _u(filter) or {}
    rows = BlueRidge.Common.Db.execList("quality/QualitySpec_List",
        {"itemId": None, "operationTemplateId": None}) or []
    search = (f.get("searchText") or "").strip().lower()
    typ = f.get("type") or "All"
    out = []
    for r in rows:
        name = (r.get("Name") or "")
        itemId = r.get("ItemId")
        opId = r.get("OperationTemplateId")
        if typ == "Item-Linked" and not itemId: continue
        if typ == "Op-Linked" and not opId: continue
        if typ == "Unlinked" and (itemId or opId): continue
        if search and search not in name.lower(): continue
        out.append({
            "id": r.get("Id"), "name": name,
            "itemId": itemId, "itemCode": r.get("ItemCode") or "",
            "operationTemplateId": opId, "opCode": r.get("OperationTemplateCode") or "",
            "versionCount": r.get("VersionCount") or 0,
            "activeVersionCount": r.get("ActiveVersionCount") or 0,
        })
    return out


def getSpecHeader(specId):
    """Header dict (name, description, link display) or empty shape."""
    specId = _u(specId)
    empty = {"id": None, "name": "", "description": "",
             "itemId": None, "itemCode": "", "itemDesc": "",
             "operationTemplateId": None, "opCode": "", "deprecatedAt": None}
    if not specId:
        return empty
    h = BlueRidge.Common.Db.execOne("quality/QualitySpec_Get", {"id": specId})
    if h is None:
        return empty
    return {
        "id": h.get("Id"), "name": h.get("Name") or "",
        "description": h.get("Description") or "",
        "itemId": h.get("ItemId"), "itemCode": h.get("ItemCode") or "",
        "itemDesc": h.get("ItemName") or "",
        "operationTemplateId": h.get("OperationTemplateId"),
        "opCode": h.get("OperationTemplateCode") or "",
        "deprecatedAt": h.get("DeprecatedAt"),
    }


def listVersions(specId, includeDeprecated=True):
    specId = _u(specId)
    if not specId:
        return []
    rows = BlueRidge.Common.Db.execList("quality/QualitySpecVersion_ListBySpec",
        {"qualitySpecId": specId}) or []
    out = []
    for r in rows:
        d = dict(r)
        d["effectiveFromDisplay"] = _isoDate(r.get("EffectiveFrom"))
        out.append(d)
    return out


def getVersionFull(versionId):
    """{version header + attributes[] + derived status} or empty shape."""
    versionId = _u(versionId)
    empty = {"id": None, "specId": None, "versionNumber": None,
             "effectiveFrom": None, "effectiveFromDisplay": "",
             "publishedAt": None, "deprecatedAt": None, "status": None,
             "attributes": []}
    if not versionId:
        return empty
    h = BlueRidge.Common.Db.execOne("quality/QualitySpecVersion_Get", {"id": versionId})
    if h is None:
        return empty
    attrs = BlueRidge.Common.Db.execList("quality/QualitySpecAttribute_ListByVersion",
        {"qualitySpecVersionId": versionId}) or []
    pub, dep = h.get("PublishedAt"), h.get("DeprecatedAt")
    status = "Deprecated" if dep is not None else ("Draft" if pub is None else "Published")
    return {
        "id": h.get("Id"), "specId": h.get("QualitySpecId"),
        "versionNumber": h.get("VersionNumber"),
        "effectiveFrom": h.get("EffectiveFrom"),
        "effectiveFromDisplay": _isoDate(h.get("EffectiveFrom")),
        "publishedAt": pub, "deprecatedAt": dep, "status": status,
        "attributes": _mapAttrs(attrs),
    }


def _mapAttrs(rows):
    out = []
    for r in rows or []:
        out.append({
            "id": r.get("Id"),
            "attributeName": r.get("AttributeName") or "",
            "dataType": r.get("DataType") or "Numeric",
            "uomId": r.get("UomId"), "uomCode": r.get("UomCode") or "",
            "targetValue": r.get("TargetValue"),
            "lowerLimit": r.get("LowerLimit"), "upperLimit": r.get("UpperLimit"),
            "isRequired": bool(r.get("IsRequired")),
            "sortOrder": r.get("SortOrder"),
        })
    return out


def listUoms():
    try:
        return BlueRidge.Common.Db.execList("parts/Uom_List", {"includeDeprecated": False}) or []
    except Exception as e:
        BlueRidge.Common.Util.log("listUoms failed: %s" % str(e))
        return []


def emptyAttribute():
    return {"id": None, "attributeName": "", "dataType": "Numeric",
            "uomId": None, "uomCode": "", "targetValue": None,
            "lowerLimit": None, "upperLimit": None, "isRequired": True,
            "sortOrder": None}


# ---------- mutations ----------

def createSpec(data):
    data = _u(data) or {}
    return BlueRidge.Common.Db.execMutation("quality/QualitySpec_Create", {
        "name": data.get("name"), "itemId": data.get("itemId"),
        "operationTemplateId": data.get("operationTemplateId"),
        "description": data.get("description"),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})


def updateSpecHeader(data):
    # Quality.QualitySpec_Update does SET ItemId=@ItemId,
    # OperationTemplateId=@OperationTemplateId (both default NULL). Pass the
    # current itemId + operationTemplateId through so a name/description edit
    # does not WIPE the spec's Item/Op links. getSpecHeader returns both.
    data = _u(data) or {}
    return BlueRidge.Common.Db.execMutation("quality/QualitySpec_Update", {
        "id": data.get("id"), "name": data.get("name"),
        "itemId": data.get("itemId"),
        "operationTemplateId": data.get("operationTemplateId"),
        "description": data.get("description"),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})


def deprecateSpec(specId):
    return BlueRidge.Common.Db.execMutation("quality/QualitySpec_Deprecate", {
        "qualitySpecId": _u(specId),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})


def createNewVersion(specId):
    """Routes: no versions -> QualitySpecVersion_Create (v1); else clone
    latest non-deprecated via _CreateNewVersion. Refuses if a Draft exists."""
    specId = _u(specId)
    if not specId:
        return {"Status": False, "Message": "No spec selected.", "NewId": None}
    vers = listVersions(specId, True)
    if len(vers) == 0:
        return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_Create",
            {"qualitySpecId": specId, "effectiveFrom": None,
             "appUserId": BlueRidge.Common.Util._currentAppUserId()})
    for v in vers:
        if v.get("PublishedAt") is None and v.get("DeprecatedAt") is None:
            return {"Status": False, "Message":
                    "A draft already exists for this spec. Open or discard it first.",
                    "NewId": None}
    nonDep = [v for v in vers if v.get("DeprecatedAt") is None]
    source = (nonDep[0] if nonDep else vers[0]).get("Id")
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_CreateNewVersion",
        {"sourceVersionId": source, "effectiveFrom": None,
         "appUserId": BlueRidge.Common.Util._currentAppUserId()})


def saveDraft(versionId, effectiveFrom, attributes):
    payload = []
    for a in (_u(attributes) or []):
        a = _u(a) or {}
        payload.append({
            "Id": a.get("id"), "AttributeName": a.get("attributeName"),
            "DataType": a.get("dataType"), "UomId": a.get("uomId"),
            "TargetValue": a.get("targetValue"), "LowerLimit": a.get("lowerLimit"),
            "UpperLimit": a.get("upperLimit"),
            "IsRequired": 1 if a.get("isRequired") else 0})
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_SaveDraft", {
        "qualitySpecVersionId": _u(versionId),
        "effectiveFrom": _u(effectiveFrom),
        "attributesJson": system.util.jsonEncode(payload),
        "appUserId": BlueRidge.Common.Util._currentAppUserId()})


def publish(versionId, effectiveFrom, attributes):
    """Save-then-publish (the proc _Publish takes only @Id). Saves draft
    first so attribute + EffectiveFrom edits commit, then flips state."""
    saved = saveDraft(versionId, effectiveFrom, attributes)
    if not saved.get("Status"):
        return saved
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_Publish", {
        "id": _u(versionId), "appUserId": BlueRidge.Common.Util._currentAppUserId()})


def discardDraft(versionId):
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_DiscardDraft", {
        "id": _u(versionId), "appUserId": BlueRidge.Common.Util._currentAppUserId()})


def deprecateVersion(versionId):
    return BlueRidge.Common.Db.execMutation("quality/QualitySpecVersion_Deprecate", {
        "id": _u(versionId), "appUserId": BlueRidge.Common.Util._currentAppUserId()})
