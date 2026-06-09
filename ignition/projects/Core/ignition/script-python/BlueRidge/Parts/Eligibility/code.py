# =============================================================================
# Project Library:  BlueRidge.Parts.Eligibility
#
# Author:           Blue Ridge Automation
# Created:          2026-05-27
# Version:          1.0
#
# Description:
#   Read + write surface for the Item Master Eligibility editor (Phase 8).
#   Reads the per-Item ItemLocation rows + the tier-grouped Location
#   picker options; writes via the bundled SaveAll proc.
#
# Public surface:
#   listByItem(itemId)            -> list[dict] of active ItemLocation rows
#                                    with joined Location + tier metadata
#   listLocationOptions()         -> list[dict] for the picker dropdown
#   handleSaveAll(itemId, rows)   -> {Status, Message, NewId}
#
# Layer:
#   Entity script -- routes all DB calls through BlueRidge.Common.Db.*.
#
# Change Log:
#   2026-05-27 - 1.0 - Initial (Phase 8 Eligibility editor).
# =============================================================================


def listByItem(itemId):
    """Return active ItemLocation rows for the Item, sorted by
    (TierOrdinal, LocationCode). Empty list when none."""
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    itemId = BlueRidge.Common.Util.extractQualifiedValues(itemId)
    if not itemId:
        return []
    return BlueRidge.Common.Db.execList(
        "parts/ItemLocation_ListByItem",
        {"itemId": itemId},
    ) or []


def listLocationOptions():
    """Return all non-deprecated Locations across all tiers, sorted
    (TierOrdinal, Code), shaped for the editor's dropdown.

    Each row carries: Id, Code, Name, TierName, TierOrdinal, DisplayLabel.
    The Eligibility view uses DisplayLabel as the dropdown option label
    and Id as the value."""
    BlueRidge.Common.Util.log("running")
    return BlueRidge.Common.Db.execList(
        "location/Location_ListForEligibilityPicker",
        {"includeDeprecated": False},
    ) or []


def handleSaveAll(itemId, rows):
    """Submit the editor's full editDraft.rows list to the SaveAll proc.

    `rows` is a list of dicts with keys:
        Id (BIGINT or None), LocationId (BIGINT),
        IsConsumptionPoint (bool),
        MinQuantity, MaxQuantity, DefaultQuantity (int or None each)

    Returns the proc's status dict {Status, Message, NewId}.
    """
    BlueRidge.Common.Util.log("itemId=%s rows=%d" % (itemId, len(rows or [])))
    itemId = BlueRidge.Common.Util.extractQualifiedValues(itemId)
    if not itemId:
        return {"Status": 0,
                "Message": "No item selected.",
                "NewId": None}
    # Coerce to plain Python primitives -- editDraft.rows may contain
    # BasicQualifiedValue wrappers via the bidi binding path.
    cleaned = []
    for r in (rows or []):
        r = BlueRidge.Common.Util.extractQualifiedValues(r) or {}
        cleaned.append({
            "Id":                 r.get("id"),
            "LocationId":         r.get("locationId"),
            "IsConsumptionPoint": bool(r.get("isConsumptionPoint")),
            "MinQuantity":        r.get("minQuantity"),
            "MaxQuantity":        r.get("maxQuantity"),
            "DefaultQuantity":    r.get("defaultQuantity"),
        })
    params = {
        "itemId":    itemId,
        "rowsJson":  BlueRidge.Common.Util.convertWrapperObjectToJson(cleaned),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation(
        "parts/ItemLocation_SaveAllForItem",
        params,
    )
