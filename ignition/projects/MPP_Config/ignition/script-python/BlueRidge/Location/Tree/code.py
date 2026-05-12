# =============================================================================
# Project Library:  BlueRidge.Location.Tree.buildTree(rootId, expandDepth=2, defaultIcon="material/place")

# Author:           Blue Ridge Automation
# Created:          2026-04-13
# Version:          1.0
#
# Description:
#   Builds a Perspective Tree component JSON structure from the
#   Location.Location_GetTree stored procedure.
#
#   Called from a session property binding (or view custom property) that
#   feeds a Perspective Tree's `props.items`.
#
# Dependencies:
#   - Named Query at "Location/GetTree" wrapping EXEC Location.Location_GetTree
#       Parameter: rootId (Long)
#       Query text:
#           DECLARE @s BIT, @m NVARCHAR(500);
#           EXEC Location.Location_GetTree
#               @RootLocationId = :rootId
#
#   - The GetTree proc returns rows in depth-first order via its SortPath
#     column, which is what makes the single-pass assembly below correct.
#
# Change Log:
#   2026-04-13 - 1.0 - Initial version
# =============================================================================


def buildTree(rootId, expandDepth=2, defaultIcon="mpp/factory"):
    """
    Build a Perspective Tree component JSON structure from the
    Location.Location_GetTree stored procedure.

    Relies on the GetTree proc returning rows in depth-first order
    (via its SortPath column), so each row's parent is guaranteed
    to have been processed already - enabling a single forward pass.

    Args:
        rootId (long):     Location.Id to use as the tree root.
        expandDepth (int): Nodes at depth < expandDepth start expanded.
                           Default 2 (Enterprise + Site expanded, Areas
                           and below collapsed).
        defaultIcon (str): Fallback icon path when
                           LocationTypeDefinition.Icon is NULL.

    Returns:
        list: A list containing the root node dict (Perspective Tree expects
              a list at top level). Returns [] on missing rootId or empty result.
    """
    if rootId is None:
        return []

    ds = system.db.runNamedQuery("location/GetTree", {"rootId": rootId})
    if ds is None or ds.getRowCount() == 0:
        return []

    # Build column-name -> index map once (faster than name lookup per cell).
    colIdx = {}
    for i in range(ds.getColumnCount()):
        colIdx[ds.getColumnName(i)] = i

    nodes = {}        # locationId -> node dict
    rootNode = None

    for r in range(ds.getRowCount()):
        locId    = ds.getValueAt(r, colIdx["Id"])
        parentId = ds.getValueAt(r, colIdx["ParentLocationId"])
        name     = ds.getValueAt(r, colIdx["Name"])
        code     = ds.getValueAt(r, colIdx["Code"])
        depth    = ds.getValueAt(r, colIdx["Depth"])
        defName  = ds.getValueAt(r, colIdx["DefinitionName"])
        typeName = ds.getValueAt(r, colIdx["TypeName"])
        iconPath = ds.getValueAt(r, colIdx["Icon"]) or defaultIcon

        node = {
            "label": name,
            "expanded": depth < expandDepth,
            "icon": {
                "path":  iconPath,
                "color": "--mpp-text-primary",
                "style": {}
            },
            "data": {
                "id":             locId,
                "code":           code,
                "name":           name,
                "definitionName": defName,
                "typeName":       typeName,
                "depth":          depth
            },
            "items": []
        }
        nodes[locId] = node

        # Depth-first ordering guarantees parent is already in `nodes` by now.
        if depth == 0:
            rootNode = node
        else:
            nodes[parentId]["items"].append(node)

    return [rootNode] if rootNode else []


# =============================================================================
# Wiring notes (for the Perspective view, not part of the library):
#
# Option A - Binding transform on tree.props.items:
#     Bind tree.props.items to view.custom.rootLocationId with a Script Transform:
#
#         def transform(self, value, quality, timestamp):
#             return shared.locations.buildTree(value)
#
# Option B - Property change script on rootLocationId:
#
#         def valueChanged(self, previousValue, currentValue, origin, missedEvents):
#             self.getSibling("Tree").props.items = \
#                 shared.locations.buildTree(currentValue.value)
#
# Downstream: tree.props.selection[0].data.id is the selected Location.Id,
# ready to feed into Location.Get or any other per-location named query.
# =============================================================================