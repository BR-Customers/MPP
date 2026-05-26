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
