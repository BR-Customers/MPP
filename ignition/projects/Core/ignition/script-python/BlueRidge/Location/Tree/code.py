# =============================================================================
# Project Library:  BlueRidge.Location.Tree
#
# Author:           Blue Ridge Automation
# Created:          2026-04-13
# Version:          1.3
#
# Description:
#   Helpers for the PlantHierarchy view's Perspective Tree component.
#
#   buildLauncherTree(rootId, expandDepth)
#       buildTree(...) overlaid with terminal launch data for the Dev
#       Launcher. Every node that is a Terminal gets data.isTerminal /
#       data.target (DefaultScreen) / data.terminal (session payload) and
#       a play_arrow icon so it reads as launchable. Non-terminal nodes
#       are left untouched (browse-only). Reuses buildTree + Terminal.listAll.
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
#   expandToTarget(items, targetId)
#       Force-expand every ancestor of the target. Used after Create or
#       any tree-mutating action that lands a node deeper than the
#       default expandDepth -- without this, the new node would exist
#       in the data tree but be hidden inside collapsed ancestors.
#
#   injectDraftNode(items, parentLocationId, draftLabel, ...)
#       Insert a synthetic draft child under the parent. Used by the
#       +Add Location flow to show the operator where the new Location
#       will land in the tree before Save commits it. Draft node carries
#       data.id=None and data.isDraft=True; replaced by the real row
#       on the next tree refresh after Save.
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
#   2026-05-18 - 1.2 - buildTree surfaces HierarchyLevel into node.data
#                      (already returned by Location_GetTree) so the
#                      LocationEditor's eligibleTypes helper can filter
#                      by parent level. Add expandToTarget(items, targetId)
#                      to walk a path and force-expand its ancestors --
#                      used after Create to ensure the new node is
#                      visible even when default expandDepth doesn't
#                      cover that depth. Add injectDraftNode(...) for
#                      the +Add Location flow's transient draft tile.
#   2026-07-07 - 1.3 - Add buildLauncherTree(rootId, expandDepth) for the
#                      Dev Launcher: overlay terminal launch payload +
#                      play_arrow icon onto Terminal nodes (view-assembly
#                      over buildTree + Terminal.listAll; no new SQL).
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
                "id":              locId,
                "code":            r.get("Code"),
                "name":            r.get("Name"),
                "definitionName":  r.get("DefinitionName"),
                "definitionId":    r.get("LocationTypeDefinitionId"),
                "typeName":        r.get("TypeName"),
                "hierarchyLevel":  r.get("HierarchyLevel"),
                "depth":           depth,
                "description":     r.get("Description"),
                "sortOrder":       r.get("SortOrder"),
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

def getTree(rootId):
    rows = BlueRidge.Common.Db.execList("location/GetTree", {"rootId": rootId})
    if not rows:
        return []

    return rows

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


def expandToTarget(items, targetId):
    """Walk the tree depth-first; when the target is found, set
       expanded=True on every ancestor (and the target itself).
       Mutates items in place; returns True when found, False otherwise.

       Idempotent -- calling on an already-expanded path is a no-op.
       Use after Create / re-anchor flows to guarantee the target is
       visible even when buildTree's default expandDepth doesn't cover
       its depth in the tree.

       Args:
           items (list):    Tree's props.items (list returned by buildTree).
           targetId (long): data.id to expand to.

       Returns:
           bool: True when the target was found and the path expanded,
                 False otherwise.
    """
    if not items or targetId is None:
        return False

    def walk(nodes):
        for node in nodes:
            if not isinstance(node, dict):
                continue
            data = node.get("data")
            if data and data.get("id") == targetId:
                node["expanded"] = True
                return True
            children = node.get("items")
            if children and walk(children):
                node["expanded"] = True
                return True
        return False

    return walk(items)


def injectDraftNode(items, parentLocationId, draftLabel, draftIcon="mpp/add_circle",
                    draftData=None):
    """Insert a synthetic draft child node under the parent (resolved by
       parentLocationId). Used by the +Add Location flow so the operator
       sees where the new Location will land in the tree before Save.

       The draft node carries data.id=None and an italic-ish label that
       reads as 'new' to the operator. The parent's expanded flag is
       forced to True so the draft is visible. The draft itself is a
       leaf (no children).

       Mutates items in place. Returns (path, drafted) where path is
       the slash-separated path string to the draft (e.g. '0/1/2/4'),
       or (None, False) when parent not found.

       Args:
           items (list):           Tree's props.items.
           parentLocationId (long): Location.Id of the parent.
           draftLabel (str):       Display label for the draft.
           draftIcon (str):        Icon path for the draft node.
           draftData (dict|None):  Extra fields merged into the draft's
                                   data dict (e.g. type hints). All
                                   draft data dicts carry id=None so
                                   selection logic can distinguish.

       Returns:
           tuple: (pathStr|None, foundParent bool).
    """
    BlueRidge.Common.Util.log(
        "parentLocationId=%s items(type=%s len=%s)"
        % (parentLocationId,
           type(items).__name__ if items is not None else "None",
           len(items) if items is not None else "-")
    )
    if not items or parentLocationId is None:
        return (None, False)

    draftNode = {
        "label":    draftLabel,
        "expanded": False,
        "icon":     {"path": draftIcon, "color": "--mpp-accent-50", "style": {}},
        "data":     dict(draftData) if draftData else {},
        "items":    [],
    }
    draftNode["data"]["id"] = None
    draftNode["data"]["isDraft"] = True

    def walk(nodes, prefix):
        for i, node in enumerate(nodes):
            if not isinstance(node, dict):
                continue
            data = node.get("data")
            if data and data.get("id") == parentLocationId:
                children = node.setdefault("items", [])
                children.append(draftNode)
                node["expanded"] = True
                return prefix + [i, len(children) - 1]
            grandchildren = node.get("items")
            if grandchildren:
                found = walk(grandchildren, prefix + [i])
                if found is not None:
                    node["expanded"] = True
                    return found
        return None

    pathList = walk(items, [])
    if pathList is None:
        return (None, False)
    return ("/".join(str(i) for i in pathList), True)


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


def buildLauncherTree(rootId=1, expandDepth=2):
    """
    Dev Launcher tree: buildTree(...) overlaid with terminal launch data.

    Composes two existing read sources (buildTree + Terminal.listAll) so the
    Dev Launcher can browse the full plant hierarchy exactly like the Config
    app's Plant Hierarchy and act ONLY on Terminal nodes. This is
    view-assembly, not business logic -- terminal identity and default screens
    still originate in SQL via Location.Terminal_List.

    For every node whose data.id matches a terminal LocationId, overlays:
        data.isTerminal = True
        data.target     = <DefaultScreen>   (navigation path; "" when none)
        data.terminal   = {terminalLocationId, terminalCode, terminalName,
                           zoneLocationId, zoneName, defaultScreen, isFallback}
                          -- exact mirror of the session.custom.terminal payload
                          set by ShopFloor/TerminalSelector.selectTerminal
        icon            = mpp/play_arrow (accent) so terminals read as launchable

    Non-terminal nodes keep their buildTree data untouched (data.isTerminal
    absent), so the launcher's click handler no-ops on them.

    Args:
        rootId (long):     Location.Id root (default 1 = Enterprise, same as
                           Plant Hierarchy).
        expandDepth (int): Nodes at depth < expandDepth start expanded.

    Returns:
        list: buildTree's list shape with terminal overlays; [] on empty.
    """
    BlueRidge.Common.Util.log("rootId=%s expandDepth=%s" % (rootId, expandDepth))

    items = buildTree(rootId, expandDepth, "mpp/factory")
    if not items:
        return []

    # {TerminalId (== Location.Id) -> Terminal_List row}
    byId = {}
    for row in (BlueRidge.Location.Terminal.listAll() or []):
        row = row or {}
        tid = row.get("TerminalId")
        if tid is not None:
            byId[tid] = row

    def overlay(nodes):
        for node in nodes:
            if not isinstance(node, dict):
                continue
            data = node.get("data") or {}
            row = byId.get(data.get("id"))
            if row is not None:
                data["isTerminal"] = True
                data["target"] = row.get("DefaultScreen") or ""
                data["terminal"] = {
                    "terminalLocationId": row.get("TerminalId"),
                    "terminalCode":       row.get("TerminalCode"),
                    "terminalName":       row.get("TerminalName"),
                    "zoneLocationId":     row.get("ZoneId"),
                    "zoneName":           row.get("ZoneName"),
                    "defaultScreen":      row.get("DefaultScreen") or "",
                    "isFallback":         bool(row.get("IsFallback")),
                }
                node["data"] = data
                node["icon"] = {
                    "path":  "mpp/play_arrow",
                    "color": "--mpp-accent-50",
                    "style": {},
                }
            children = node.get("items")
            if children:
                overlay(children)

    overlay(items)
    return items
