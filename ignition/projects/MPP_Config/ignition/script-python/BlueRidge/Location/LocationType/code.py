# =============================================================================
# Project Library:  BlueRidge.Location.LocationType
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.2
#
# Description:
#   Read-only entity-script for Location.LocationType (the 5 ISA-95 tiers:
#   Enterprise / Site / Area / WorkCenter / Cell). Seeded in migration
#   0002 and never CRUD'd at runtime -- this module exists only to back
#   UI dropdowns and chip-list selectors.
#
# Public surface:
#   getAll()                    -> list[dict]
#   nameForTier(tiers, tierId)  -> str  (display helper for runScript bindings)
#
# Layer:
#   View -> BlueRidge.Location.LocationType (this module)
#        -> BlueRidge.Common.Db.execList
#
# Change Log:
#   2026-05-13 - 1.0 - Initial version
#   2026-05-13 - 1.1 - Rename list() -> listAll() to avoid shadowing the
#                      Python builtin in module scope
#   2026-05-14 - 1.2 - Rename listAll -> getAll per Common entity surface;
#                      route through Common.Db.execList; drop local
#                      _rowsToDicts; replace per-module logger.
# =============================================================================


def getAll():
    """
    Returns all LocationType rows, ordered by HierarchyLevel (Enterprise=1
    ... Cell=5). Used to populate the Location Type tier dropdown.

    On DB / NQ failure, fires an error toast and returns []. Empty result
    is distinguishable from failure only via the toast + gateway log --
    both are emitted so the operator sees something AND a postmortem
    trail lands in the log.

    Returns:
        list[dict]: keys per column from Location.LocationType_List.
                    Typical: Id, Code, Name, Description, HierarchyLevel.
                    Empty list on failure.
    """
    BlueRidge.Common.Util.log("loading tiers")
    try:
        return BlueRidge.Common.Db.execList("location/LocationType_List")
    except Exception as e:
        BlueRidge.Common.Util.log("getAll failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load tiers", str(e), "error")
        return []


def nameForTier(tiers, tierId):
    """
    Return the Name of the LocationType row whose Id matches tierId, or
    '' when not found. Drives the LocationTypeEditor popup's TypeBadge
    text binding via runScript -- which works against the list[dict]
    shape getAll() returns. The expression-language lookup() function
    requires a Dataset and is therefore not usable here.

    Args:
        tiers (list[dict]):    The view.custom.tiers list (as getAll returns).
        tierId (long | None):  The currently-selected LocationType.Id.

    Returns:
        str: The tier's Name (e.g. "Cell"), or "" when no match.
    """
    if tierId is None:
        return ""
    for t in (tiers or []):
        if t.get("Id") == tierId:
            return t.get("Name") or ""
    return ""
