# =============================================================================
# Project Library:  BlueRidge.Parts.Uom
#
# Author:           Blue Ridge Automation
# Created:          2026-05-26
# Version:          1.0
#
# Description:
#   Read surface for the Uom lookup table. Backs the UOM + Weight UOM
#   dropdowns in the AddItem popup and the Identity embed.
#
# Public surface:
#   getAll(includeDeprecated=False)                 -> list[dict]
#   getForDropdown(includeBlank=False, blankLabel)  -> list[{label, value}]
#
# Change Log:
#   2026-05-26 - 1.0 - Initial version (Phase 3 -- UOM dropdowns).
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def getAll(includeDeprecated=False):
    """List UOMs ordered by Code. Returns list[dict] with keys
    {Id, Code, Name, DeprecatedAt}."""
    BlueRidge.Common.Util.log("includeDeprecated=%s" % includeDeprecated)
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Uom_List",
            {"includeDeprecated": 1 if includeDeprecated else 0},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast(
            "Could not load UOMs", str(e), "error")
        return []


def getForDropdown(includeBlank=False, blankLabel=u"-"):
    """Returns [{label, value}] for a UOM dropdown.

    - includeBlank=False (default) -- counting UOM (required field). No
      blank entry; first option is the first real UOM.
    - includeBlank=True -- Weight UOM (optional field). Inserts a blank
      entry at index 0 with value=None and label=blankLabel."""
    rows = getAll(False)
    options = [{"label": r.get("Code", ""), "value": r.get("Id")} for r in rows]
    if _u(includeBlank):
        options.insert(0, {"label": _u(blankLabel) or u"-", "value": None})
    return options
