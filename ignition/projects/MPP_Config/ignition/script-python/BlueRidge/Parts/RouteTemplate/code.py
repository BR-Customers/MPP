# =============================================================================
# Project Library:  BlueRidge.Parts.RouteTemplate
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          2.0
#
# Description:
#   Read + mutation surface for the Item Master Routes tab.
#
#   v1 (2026-05-20) shipped only `getActiveForItem` for the published-only
#   read used by the Phase 4 partId-only embed. Phase 5 extends this module
#   to the full Draft -> Published -> Deprecated workflow:
#       - listVersions / getHeader / getSteps               (read)
#       - getOperationTemplatesByArea                       (cascading dropdown)
#       - createNewVersion / saveAll / publish / publishWithSave (mutation)
#       - discardDraft / deprecate                          (lifecycle)
#
#   All DB I/O routes through BlueRidge.Common.Db.{execList, execOne,
#   execMutation}. Every public function deep-unwraps inputs via
#   BlueRidge.Common.Util.extractQualifiedValues at entry, so callers can
#   pass Perspective QualifiedValue wrappers without unwrapping themselves.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (getActiveForItem only).
#   2026-05-20 - 2.0 - Phase 5: listVersions, getHeader, getSteps,
#                      getOperationTemplatesByArea, createNewVersion,
#                      saveAll, publish, discardDraft, deprecate,
#                      publishWithSave (chained save+publish).
# =============================================================================

import json


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _isoDate(d):
    """Render a date-like value as an ISO date string. Tolerant of None /
    Java date / Python date / already-string inputs."""
    if d is None:
        return ""
    try:
        return str(d)[:10]
    except Exception:
        return ""


def _mapSteps(rows):
    out = []
    for r in rows or []:
        opCode = r.get("OperationCode") or ""
        opName = r.get("OperationName") or ""
        if opCode and opName:
            templateLabel = "%s — %s" % (opCode, opName)
        else:
            templateLabel = opCode or opName
        out.append({
            "seq":           r.get("SequenceNumber"),
            "areaName":      r.get("OperationAreaName") or "",
            "templateLabel": templateLabel,
            "isRequired":    bool(r.get("IsRequired")),
            "dataFields":    r.get("DataCollectionSummary") or "",
        })
    return out


_EMPTY_ROUTE = {"publishedVersion": 0, "effectiveFrom": "", "steps": []}


def getActiveForItem(itemId):
    """Returns the active Published RouteTemplate + steps for the given Item.
    Single entity-script call -> one binding on view.custom.data. Always
    returns a dict -- empty shape when no published route exists or itemId
    is missing, so view bindings never traverse into None.

    This is the partId-only embed read path (Phase 4). Phase 5 Routes tab
    uses `listVersions` + `getHeader` + `getSteps` for the full Draft /
    Published / Deprecated workflow instead.
    """
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if not itemId:
        return dict(_EMPTY_ROUTE)
    try:
        header = BlueRidge.Common.Db.execOne(
            "parts/RouteTemplate_GetActiveForItem",
            {"itemId": itemId},
        )
        if header is None:
            return dict(_EMPTY_ROUTE)
        steps = BlueRidge.Common.Db.execList(
            "parts/RouteStep_ListByRoute",
            {"routeTemplateId": header.get("Id")},
        )
        result = dict(header)
        result["publishedVersion"] = header.get("VersionNumber")
        result["effectiveFrom"]    = _isoDate(header.get("EffectiveFrom"))
        result["steps"]            = _mapSteps(steps)
        return result
    except Exception as e:
        BlueRidge.Common.Util.log("getActiveForItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load route", str(e), "error")
        return dict(_EMPTY_ROUTE)


# =============================================================================
# Phase 5: full versioning surface
# =============================================================================

def listVersions(itemId, includeDeprecated=False):
    """Returns the list of RouteTemplate versions for the given Item,
    newest first. Each dict carries Id, ItemId, VersionNumber, Name,
    EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId,
    CreatedByDisplayName, CreatedAt.
    """
    itemId = _u(itemId)
    includeDeprecated = _u(includeDeprecated)
    if not itemId:
        return []
    activeOnly = 0 if includeDeprecated else 1
    return BlueRidge.Common.Db.execList(
        "parts/RouteTemplate_ListByItem",
        {"itemId": itemId, "activeOnly": activeOnly},
    )


def getHeader(id):
    """Returns the RouteTemplate header dict for a single version, or None.
    Joined to Parts.Item for PartNumber and Location.AppUser for
    CreatedByDisplayName.
    """
    id = _u(id)
    if not id:
        return None
    return BlueRidge.Common.Db.execOne(
        "parts/RouteTemplate_Get",
        {"id": id},
    )


def getSteps(routeTemplateId):
    """Returns the ordered step rows for the given RouteTemplate, with the
    Phase-5 projections (OperationAreaName, DataCollectionSummary,
    OperationVersionNumber, OperationAreaLocationId).
    """
    routeTemplateId = _u(routeTemplateId)
    if not routeTemplateId:
        return []
    return BlueRidge.Common.Db.execList(
        "parts/RouteStep_ListByRoute",
        {"routeTemplateId": routeTemplateId},
    )


def getOperationTemplatesByArea(areaLocationId, includeDeprecated=False):
    """Returns active OperationTemplate rows in the given Area, ordered by
    Code + VersionNumber. Powers the per-step Area -> OpTemplate
    cascading dropdown on the Draft step editor.
    """
    areaLocationId = _u(areaLocationId)
    includeDeprecated = _u(includeDeprecated)
    if not areaLocationId:
        return []
    activeOnly = 0 if includeDeprecated else 1
    return BlueRidge.Common.Db.execList(
        "parts/OperationTemplate_ListByArea",
        {"areaLocationId": areaLocationId, "activeOnly": activeOnly},
    )


def createNewVersion(parentRouteTemplateId, effectiveFrom=None, appUserId=None):
    """Clones the parent RouteTemplate into a new Draft, copying every
    RouteStep. Rejects if any active Draft already exists for the parent's
    Item.
    """
    parentRouteTemplateId = _u(parentRouteTemplateId)
    effectiveFrom         = _u(effectiveFrom)
    appUserId             = appUserId or BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "parts/RouteTemplate_CreateNewVersion",
        {
            "parentRouteTemplateId": parentRouteTemplateId,
            "effectiveFrom":         effectiveFrom,
            "appUserId":             appUserId,
        },
    )


def saveAll(id, name, effectiveFrom, stepsList, appUserId=None):
    """Bundled save: persists header (Name, EffectiveFrom) + step
    reconciliation in one atomic call. Only accepts active Drafts.

    stepsList is a Python list of step dicts. Each step needs:
        Id (BIGINT or None for new), OperationTemplateId (BIGINT),
        IsRequired (bool), Description (str or None).
    Display caches (OperationCode, AreaName, etc.) are stripped before
    serialization; only the persisted-shape fields are forwarded.
    """
    id            = _u(id)
    name          = _u(name)
    effectiveFrom = _u(effectiveFrom)
    stepsList     = _u(stepsList)
    appUserId     = appUserId or BlueRidge.Common.Util._currentAppUserId()

    payload = []
    for s in (stepsList or []):
        s = s or {}
        payload.append({
            "Id":                  s.get("Id"),
            "OperationTemplateId": s.get("OperationTemplateId"),
            "IsRequired":          1 if s.get("IsRequired") else 0,
            "Description":         s.get("Description"),
        })

    return BlueRidge.Common.Db.execMutation(
        "parts/RouteTemplate_SaveAll",
        {
            "id":            id,
            "name":          name,
            "effectiveFrom": effectiveFrom,
            "appUserId":     appUserId,
            "stepsJson":     json.dumps(payload),
        },
    )


def publish(id, effectiveFrom=None, name=None, appUserId=None):
    """Flips a Draft to Published. Optional @EffectiveFrom and @Name
    overrides; NULL preserves the row's existing values. Rejects on
    already-published, deprecated, or zero-step Drafts.
    """
    id            = _u(id)
    effectiveFrom = _u(effectiveFrom)
    name          = _u(name)
    appUserId     = appUserId or BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "parts/RouteTemplate_Publish",
        {
            "id":            id,
            "appUserId":     appUserId,
            "effectiveFrom": effectiveFrom,
            "name":          name,
        },
    )


def discardDraft(id, appUserId=None):
    """Hard-deletes an unpublished Draft + its RouteStep children.
    Rejects on Published, Deprecated, or non-existent rows.
    """
    id        = _u(id)
    appUserId = appUserId or BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "parts/RouteTemplate_DiscardDraft",
        {"id": id, "appUserId": appUserId},
    )


def deprecate(id, appUserId=None):
    """Soft-deletes a RouteTemplate (sets DeprecatedAt). No FK guard --
    production rows reference the immutable per-LOT snapshot, not the
    template, so deprecation does not break in-flight work.
    """
    id        = _u(id)
    appUserId = appUserId or BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "parts/RouteTemplate_Deprecate",
        {"id": id, "appUserId": appUserId},
    )


def publishWithSave(id, name, effectiveFrom, stepsList, appUserId=None):
    """Chained Save -> Publish behind a single Publish click on the Routes
    tab (Phase 5 UX detail per spec section 6.9). Runs saveAll first;
    if that succeeds, runs publish. Publish receives the just-saved Name
    + EffectiveFrom as explicit overrides, but the SaveAll already
    committed those, so the publish UPDATE is a no-op for those fields.

    Returns the publish result on success or the SaveAll failure result if
    SaveAll bails. The narrow window between the two calls (SaveAll
    committed, Publish failed) leaves the Draft up-to-date but unpublished
    -- recoverable by clicking Publish again.
    """
    saveRes = saveAll(
        id            = id,
        name          = name,
        effectiveFrom = effectiveFrom,
        stepsList     = stepsList,
        appUserId     = appUserId,
    )
    if not saveRes or not saveRes.get("Status"):
        return saveRes
    return publish(
        id            = id,
        effectiveFrom = effectiveFrom,
        name          = name,
        appUserId     = appUserId,
    )
