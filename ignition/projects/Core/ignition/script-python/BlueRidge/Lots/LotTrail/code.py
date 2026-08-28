"""BlueRidge.Lots.LotTrail - breadcrumb trail for LOT Detail genealogy hops.

   Presentation-layer only: no DB access, no domain rules. The trail lives in
   session.custom.lotTrail as an oldest-first list of {"id", "name"} dicts whose
   LAST entry is ALWAYS the LOT currently displayed by LOT Detail.

   That invariant is what the whole module rests on, and sync() maintains it.
   LOT Detail's load() calls sync() on every load: if the tail already matches
   the LOT being loaded the operator got here by a genealogy hop or a crumb
   click, so the trail stands; if it does not match they arrived from LOT Search
   / Home / a report, so the trail resets to just this LOT. No entry-point flag
   has to be threaded through the navigation to tell those two cases apart.

   Because the tail IS the current LOT, a genealogy row click only has to name
   its TARGET - hopToParent / hopToChild are never told where they came from.

   Revisiting a LOT already in the trail TRUNCATES back to it rather than
   appending, so walking A -> B -> C -> B leaves "A > B", not "A > B > C > B".
   That is also what makes a crumb click self-healing: jump() truncates, then
   sync() finds a matching tail and leaves the truncated trail alone."""


MAX_CRUMBS = 5       # crumbs rendered in the header; older ones elide to "..."
MAX_STORED = 25      # hard cap on the stored trail, oldest dropped first

_DETAIL_ROUTE = "/shop-floor/lot-detail/"


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _plain(value, empty):
    """session.custom.lotTrail and view.params.row read back as QualifiedValue
       wrapping ImmutableMap. _u unwraps the QualifiedValue layer but NOT the
       ImmutableMap, so .get(...) raises AttributeError
       (feedback_ignition_immutable_map_unwrap). Round-trip through JSON for
       plain dicts. Mirrors BlueRidge.Lots.Lot._tallyRows."""
    unwrapped = _u(value)
    if not unwrapped:
        return empty
    try:
        return system.util.jsonDecode(system.util.jsonEncode(unwrapped)) or empty
    except:
        return unwrapped


def _rows(value):
    """Trail as list[dict] ([] on empty / None / undecodable)."""
    return _plain(value, [])


def _one(value):
    """Single row as dict ({} on empty / None / undecodable)."""
    return _plain(value, {})


def _asId(value):
    """LOT ids arrive as BIGINT -> Java Long -> Jython long, or as a string off a
       view param. Normalize so trail comparisons never miss on type alone.
       0 means 'no usable id' and is treated as absent everywhere below."""
    if value is None:
        return 0
    try:
        return int(value)
    except:
        return 0


def _label(name, lotId):
    """Crumb text. Falls back to the id when a name did not resolve, so a crumb
       is never blank and stays clickable."""
    return name or ("LOT " + str(lotId))


def sync(session, lotId, lot=None):
    """Reconcile the trail with the LOT now on screen. Called once per LOT Detail
       load(). Keeps the tail equal to the displayed LOT (see module docstring).

       lot is the view.custom.lot snapshot; only LotName is read from it."""
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    current = _asId(lotId)
    if current < 1:
        return
    name = _label((_one(lot) or {}).get("LotName"), current)
    trail = _rows(session.custom.lotTrail)
    if trail and _asId(trail[-1].get("id")) == current:
        # Same LOT re-loaded - a refresh after a hold / scrap / count change.
        # Keep the trail, but let a name that resolved late reach the crumb.
        if trail[-1].get("name") != name:
            trail[-1]["name"] = name
            session.custom.lotTrail = trail
        return
    session.custom.lotTrail = [{"id": current, "name": name}]


def _hop(session, lotId, lotName):
    """Extend-or-truncate the trail toward lotId, then navigate to it."""
    target = _asId(lotId)
    if target < 1:
        return
    trail = _rows(session.custom.lotTrail)
    for i, crumb in enumerate(trail):
        if _asId(crumb.get("id")) == target:
            trail = trail[:i + 1]                      # revisit -> unwind
            break
    else:
        trail.append({"id": target, "name": _label(lotName, target)})
        if len(trail) > MAX_STORED:
            trail = trail[len(trail) - MAX_STORED:]
    session.custom.lotTrail = trail
    system.perspective.navigate(_DETAIL_ROUTE + str(target))


def hopToParent(session, row):
    """ParentRow click on the LOT Detail genealogy tab - walk UP to that parent."""
    parent = _one(row)
    _hop(session, parent.get("ParentLotId"), parent.get("ParentLotName"))


def hopToChild(session, row):
    """ChildRow click on the LOT Detail genealogy tab - walk DOWN to that child."""
    child = _one(row)
    _hop(session, child.get("ChildLotId"), child.get("ChildLotName"))


def jump(session, lotId, clickable=True):
    """Breadcrumb crumb click. Truncates the trail back to that LOT and navigates.
       clickable comes straight off the chip's param so the current crumb and the
       elision chip are inert without the view needing an if-statement."""
    if not clickable:
        return
    _hop(session, lotId, None)


def crumbs(trail, currentLotId=None):
    """Flex-repeater instances for the LOT Detail header breadcrumb.

       Returns [] for a trail of 0 or 1 entries, so a LOT reached directly (no
       genealogy walk yet) renders no repeater instances and the breadcrumb takes
       no layout space. That is deliberately done here rather than with a
       position.display expression - it keeps the empty case out of the
       expression language entirely.

       Only the last MAX_CRUMBS entries render; an elided trail gets a leading
       inert "..." chip.

       Instances are FLAT dicts, not the {'row': {...}} wrapper ParentRow /
       ChildRow use - CrumbChip declares its params individually."""
    rows = _rows(trail)
    if len(rows) < 2:
        return []
    current = _asId(currentLotId)
    elided = len(rows) > MAX_CRUMBS
    if elided:
        rows = rows[len(rows) - MAX_CRUMBS:]
    out = []
    if elided:
        out.append({
            "lotId": 0,
            "label": "...",
            "isCurrent": False,
            "isFirst": True,
            "isClickable": False,
        })
    for i, crumb in enumerate(rows):
        crumbId = _asId(crumb.get("id"))
        if current > 0:
            isCurrent = (crumbId == current)
        else:
            isCurrent = (i == len(rows) - 1)
        out.append({
            "lotId": crumbId,
            "label": _label(crumb.get("name"), crumbId),
            "isCurrent": isCurrent,
            "isFirst": (i == 0 and not elided),
            "isClickable": (not isCurrent) and crumbId > 0,
        })
    return out
