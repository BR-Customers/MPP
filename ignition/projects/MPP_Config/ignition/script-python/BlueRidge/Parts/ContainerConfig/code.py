# =============================================================================
# Project Library:  BlueRidge.Parts.ContainerConfig
#
# Author:           Blue Ridge Automation
# Created:          2026-05-20
# Version:          1.0
#
# Description:
#   Read surface for the Item Master Container Config tab (Phase 2).
#   Save lands in Phase 4. Routes through BlueRidge.Common.Db.*.
#
# Public surface:
#   getByItem(itemId) -> dict | None
#
# Change Log:
#   2026-05-20 - 1.0 - Initial version (getByItem only).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getByItem(itemId):
    """Returns the active ContainerConfig row for the Item, or None.
    Multiple active rows shouldn't exist (filtered unique index), but the
    underlying execOne logs a warning if they do."""
    itemId = _u(itemId)
    BlueRidge.Common.Util.log("itemId=%s" % itemId)
    if itemId is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne(
            "parts/ContainerConfig_GetByItem",
            {"itemId": itemId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getByItem failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load container config", str(e), "error")
        return None
