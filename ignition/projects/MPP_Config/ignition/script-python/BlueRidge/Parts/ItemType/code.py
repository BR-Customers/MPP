# =============================================================================
# Project Library:  BlueRidge.Parts.ItemType
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          1.0
#
# Description:
#   Read surface for the ItemType lookup table. Backs the ItemType
#   dropdown in the AddItem popup. Routes through BlueRidge.Common.Db.*.
#
# Public surface:
#   getAll(includeDeprecated=False)              -> list[dict]
#   getForDropdown(includeSelectPrompt=True)     -> list[{label, value}]
#
# Change Log:
#   2026-05-26 - 1.0 - Initial version (Phase 3 -- ItemType dropdown).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getAll(includeDeprecated=False):
    """List ItemTypes ordered by Name. Returns list[dict] with keys
    {Id, Name, Description, DeprecatedAt}."""
    BlueRidge.Common.Util.log("includeDeprecated=%s" % includeDeprecated)
    try:
        return BlueRidge.Common.Db.execList(
            "parts/ItemType_List",
            {"includeDeprecated": 1 if includeDeprecated else 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load item types", str(e), "error")
        return []


def getForDropdown(includeSelectPrompt=True):
    """Returns [{label, value}] for the ItemType dropdown. Optional
    'Select...' first entry with value=None when includeSelectPrompt=True."""
    rows = getAll(False)
    options = [{"label": r.get("Name", ""), "value": r.get("Id")} for r in rows]
    if _u(includeSelectPrompt):
        options.insert(0, {"label": u"Select...", "value": None})
    return options
