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
        description = ds.getValueAt(r, colIdx['Description']) 
        sortOrder = ds.getValueAt(r, colIdx["SortOrder"])

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
                "depth":          depth,
                "description":	  description,
                "sortOrder":	  sortOrder
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


def findPathById(items, targetId):
    """
    Walk the tree depth-first; return the path-string of the node whose
    data.id equals targetId. Path format matches the Perspective Tree
    component's selection (slash-separated indices, e.g. "0/0/1").

    Use when a tree-mutating action (move, add, deprecate, parent-change)
    needs to keep the same logical entity selected even though its position
    in the tree has shifted. Pair with the freshly-rebuilt items returned
    by buildTree; do NOT call this against a stale `view.custom.tree` after
    `refreshBinding` because the binding refresh is async.

    Args:
        items (list):    Tree's props.items (list returned by buildTree).
        targetId (long): data.id to search for.

    Returns:
        str or None: Path string ("0/0/1"), or None when not found.
    """
    if not items or targetId is None:
        return None

    def walk(nodes, prefix):
        for i, node in enumerate(nodes):
            currentPath = prefix + [i]
            data = node.get("data") if isinstance(node, dict) else None
            if data and data.get("id") == targetId:
                return currentPath
            children = node.get("items") if isinstance(node, dict) else None
            if children:
                found = walk(children, currentPath)
                if found is not None:
                    return found
        return None

    pathList = walk(items, [])
    return "/".join(str(i) for i in pathList) if pathList is not None else None


def getNodeData(items, pathStr):
    """
    Resolve a slash-separated path string ("0/0/1") into the items tree
    and return the matching node's `data` dict.

    Used together with findPathById after a tree-mutating action to extract
    the entity's fresh data for view.custom.selected. The Tree component's
    bidirectional writeback to view.custom.selected doesn't reliably fire
    when items are replaced from script (only on user-click selection
    changes), so the caller pushes the new entity dict explicitly.

    Args:
        items (list):  Tree's props.items (list returned by buildTree).
        pathStr (str): Slash-separated path string ("0/0/1").

    Returns:
        dict or None: node.data at the path, or None when the path doesn't
                      resolve. Shape matches what the Tree component would
                      have placed in selectionData[0].value.
    """
    if not items or not pathStr:
        return None
    node = {"items": items}
    try:
        for idx in pathStr.split("/"):
            node = node["items"][int(idx)]
    except (IndexError, KeyError, TypeError, ValueError):
        return None
    if isinstance(node, dict):
        return node.get("data")
    return None


def resolveSelectedId(items, selection):
    """
    Resolve the Tree component's path-based selection to the underlying
    Location.Id stored in each node's data.id. Used from the Tree's
    onSelectionChange event to set view.custom.selectedId, which then
    drives the location/Get and location/AttributesByLocation bindings.

    The Tree component's props.selection is a list of paths; each path is
    typically a list of integer indices (e.g. [0, 0, 0]) walking down the
    tree. A string form ("0/0/0") is also tolerated.

    Args:
        items (list):     Tree's props.items (list returned by buildTree).
        selection (list): Tree's props.selection (list of paths).

    Returns:
        long, or None when nothing is selected or the path is unreachable.
    """
    if not items or not selection:
        return None

    path = selection[0]
    if isinstance(path, str):
        try:
            path = [int(p) for p in path.split("/") if p != ""]
        except ValueError:
            return None
    if not path:
        return None

    node = {"items": items}
    try:
        for idx in path:
            node = node["items"][idx]
    except (IndexError, KeyError, TypeError):
        return None

    data = node.get("data") if isinstance(node, dict) else None
    return data.get("id") if isinstance(data, dict) else None


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