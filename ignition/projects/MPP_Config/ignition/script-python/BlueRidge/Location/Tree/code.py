# =============================================================================
# Project Library:  BlueRidge.Location.Tree
#
# Author:           Blue Ridge Automation
# Created:          2026-04-13
# Version:          1.1
#
# Description:
#   Helpers for the PlantHierarchy view's Perspective Tree component.
#
#   buildTree(rootId, expandDepth, defaultIcon)
#       Builds the Tree.props.items JSON structure from the
#       Location.Location_GetTree stored proc result, in one forward
#       pass (the proc returns rows in depth-first order via its SortPath
#       column, so each row's parent is already in the working dict by
#       the time it is processed).
#
#   findPathById(items, targetId)
#       Walk the tree depth-first; return the slash-separated path string
#       (e.g. "0/0/1") of the node whose data.id equals targetId. Used
#       after tree-mutating actions to re-anchor selection on the entity
#       even when its path shifted.
#
#   getNodeData(items, pathStr)
#       Resolve a path string into the items tree and return that node's
#       data dict. Paired with findPathById to push the moved entity's
#       fresh data into view.custom.selected.
#
#   resolveSelectedId(items, selection)
#       Convert the Tree component's path-based selection (list of paths
#       or path strings) to the underlying Location.Id stored in
#       data.id of the selected node.
#
# Dependencies:
#   - NQ at "location/GetTree" wrapping EXEC Location.Location_GetTree
#       Parameter: rootId (Long)
#
# Layer:
#   View -> BlueRidge.Location.Tree (this module)
#        -> BlueRidge.Common.Db.execList
#
# Change Log:
#   2026-04-13 - 1.0 - Initial version
#   2026-05-14 - 1.1 - Route buildTree through Common.Db.execList;
#                      header rewritten to standard module shape;
#                      default-icon docstring corrected to mpp/factory.
# =============================================================================


def buildTree(rootId, expandDepth=2, defaultIcon="mpp/factory"):
    """
    Build a Perspective Tree component JSON structure from the
    Location.Location_GetTree stored procedure.

    Relies on the GetTree proc returning rows in depth-first order (via its
    SortPath column), so each row's parent is guaranteed to have been
    processed already -- enabling a single forward pass.

    Args:
        rootId (long):     Location.Id to use as the tree root.
        expandDepth (int): Nodes at depth < expandDepth start expanded.
                           Default 2 (Enterprise + Site expanded; Areas
                           and below collapsed).
        defaultIcon (str): Fallback icon path when
                           LocationTypeDefinition.Icon is NULL.

    Returns:
        list: A list containing the root node dict (Perspective Tree expects
              a list at top level). Returns [] on missing rootId or empty
              result.
    """
    BlueRidge.Common.Util.log("rootId=%s expandDepth=%s" % (rootId, expandDepth))
    if rootId is None:
        return []

    rows = BlueRidge.Common.Db.execList("location/GetTree", {"rootId": rootId})
    if not rows:
        return []

    nodes = {}        # locationId -> node dict
    rootNode = None

    for r in rows:
        locId    = r.get("Id")
        parentId = r.get("ParentLocationId")
        depth    = r.get("Depth")
        iconPath = r.get("Icon") or defaultIcon

        node = {
            "label": r.get("Name"),
            "expanded": depth < expandDepth,
            "icon": {
                "path":  iconPath,
                "color": "--mpp-text-primary",
                "style": {},
            },
            "data": {
                "id":             locId,
                "code":           r.get("Code"),
                "name":           r.get("Name"),
                "definitionName": r.get("DefinitionName"),
                "typeName":       r.get("TypeName"),
                "depth":          depth,
                "description":    r.get("Description"),
                "sortOrder":      r.get("SortOrder"),
            },
            "items": [],
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
    bidirectional writeback to view.custom.selected does not reliably fire
    when items are replaced from script (only on user-click selection
    changes), so the caller pushes the new entity dict explicitly.

    Args:
        items (list):  Tree's props.items (list returned by buildTree).
        pathStr (str): Slash-separated path string ("0/0/1").

    Returns:
        dict or None: node.data at the path, or None when the path does
                      not resolve. Shape matches what the Tree component
                      would have placed in selectionData[0].value.
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
