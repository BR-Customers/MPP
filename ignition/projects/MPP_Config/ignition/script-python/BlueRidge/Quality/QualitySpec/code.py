# =============================================================================
# Project Library:  BlueRidge.Quality.QualitySpec
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.0
#
# Description:
#   Read surface for the Item Master Quality Specs tab. Returns the list
#   of quality specs linked to a given Item, shaped for the tab's table
#   (specName, activeVersion, statusLabel).
#
# Public surface:
#   listForItem(itemId) -> list[dict]
#     Each row: {specName, activeVersion, statusLabel, id}
#
# Note:
#   activeVersion is left blank in Phase 2 — populating it requires a
#   per-spec lookup of the active QualitySpecVersion.VersionNumber that
#   Phase 7 (Quality Specs cross-link) will add. statusLabel is derived
#   from the proc's ActiveVersionCount.
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (read paths only).
# =============================================================================


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


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
