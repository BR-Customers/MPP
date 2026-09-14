# =============================================================================
# Project Library:  BlueRidge.Tools.Tool
#
# Author:           Blue Ridge Automation
# Created:          2026-09-12
# Version:          1.1
#
# Description:
#   Read surface for the cutover scan screen -- resolving the die (Tool) and
#   die cavity for a given part. Distinct from BlueRidge.Parts.Tool (the
#   Tools Configuration Tool screen's full CRUD surface); this module is a
#   thin, read-only wrapper scoped to the Tools schema procs consumed by the
#   inventory cutover scan.
#
# Public surface:
#   listForItem(itemId)                -> list[dict] (Id, Code, Name)
#   listCavitiesForItemTool(itemId,
#                            toolId)    -> list[dict] (Id, CavityCode, Description)
#
# Layer:
#   View -> BlueRidge.Tools.Tool (this module)
#        -> BlueRidge.Common.Db.execList
#   Views never call system.db.* directly.
#
# Change Log:
#   2026-09-12 - 1.0 - Initial version: listForItem, listCavitiesForItemTool.
#   2026-09-12 - 1.1 - Unwrap QualifiedValue inputs, matching the sibling
#                      wrappers. A binding-supplied id is not a bare int and an
#                      `is None` guard does not catch it.
# =============================================================================

import java.lang


def _u(value):
    """Local shorthand for extractQualifiedValues. A value arriving from a
       Perspective binding (a dropdown's props.value, a table selection cell)
       is a QualifiedValue, not a bare int -- and an `is None` guard does not
       catch it. Unwrapped here so it cannot reach the named query wrapped,
       where the never-throw guard below would swallow the failure and return
       an empty list to a screen that shows no dies and no error."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)

def listForItem(itemId):
    """Dies that can run this part. One row means the cutover scan screen
       resolves the die with no operator input. Returns list[dict] with
       Id, Code, Name -- never None."""
    itemId = _u(itemId)
    if itemId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList("tools/Tool_ListForItem",
                                            {"itemId": itemId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("listForItem failed: %s" % str(e), level="warn")
        return []


def listCavitiesForItemTool(itemId, toolId):
    """The cavities of one die that produce one part. CavityCode is the per-part
       lowercase alphabetic code (migration 0076) -- exactly the lowercase letter
       the operator reads off the LTT. Returns list[dict], never None."""
    itemId, toolId = _u(itemId), _u(toolId)
    if itemId is None or toolId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList("tools/ToolCavity_ListForItemTool",
                                            {"itemId": itemId, "toolId": toolId}) or []
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("listCavitiesForItemTool failed: %s" % str(e), level="warn")
        return []
