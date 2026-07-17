"""BlueRidge.Lots.Lot - thin access to LOT create / read / status / move procs.

   Wrappers only; no business logic. Mutation attribution defaults appUserId to
   the session-resolved current user when the caller passes None; the plant
   floor passes appUserId / terminalLocationId explicitly."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _tallyRows(tally):
    """The die-cast shift tally is cached in view.custom.shiftTally and read back
       by the card's display bindings as an array of QualifiedValue wrapping
       ImmutableMap rows. extractQualifiedValues (_u) unwraps the QualifiedValue
       layer but NOT ImmutableMap, so r.get(...) raises AttributeError
       (feedback_ignition_immutable_map_unwrap). Round-trip the unwrapped rows
       through JSON to get plain dicts. Returns list[dict] ([] on empty/None)."""
    rows = _u(tally) or []
    if not rows:
        return []
    try:
        return system.util.jsonDecode(system.util.jsonEncode(rows)) or []
    except:
        return rows


def shiftTallyCavityIds(tally):
    """ToolCavityId list from the shift tally (plain values), for the card's
       cavity-selection guard. Robust to the view.custom ImmutableMap wrapping."""
    return [r.get("ToolCavityId") for r in _tallyRows(tally)]


def create(data, appUserId=None, terminalLocationId=None, lotName=None, cavityNote=None):
    """Mint a new LOT. data carries every Lot_Create field (itemId,
       lotOriginTypeId, currentLocationId, pieceCount, weight, weightUomId,
       toolId, toolCavityId, vendorLotNumber, minSerialNumber, maxSerialNumber).
       lotName (D4): None = server mint (default); a value = use it verbatim (the
       pre-printed LTT). cavityNote (D2): free-text cavity when no active ToolCavity.
       Returns {Status, Message, NewId, MintedLotName}."""
    BlueRidge.Common.Util.log(
        "create data=%s appUserId=%s terminalLocationId=%s lotName=%s cavityNote=%s"
        % (data, appUserId, terminalLocationId, lotName, cavityNote)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "itemId":             d.get("itemId"),
        "lotOriginTypeId":    d.get("lotOriginTypeId"),
        "currentLocationId":  d.get("currentLocationId"),
        "pieceCount":         d.get("pieceCount"),
        "weight":             d.get("weight"),
        "weightUomId":        d.get("weightUomId"),
        "toolId":             d.get("toolId"),
        "toolCavityId":       d.get("toolCavityId"),
        "vendorLotNumber":    d.get("vendorLotNumber"),
        "minSerialNumber":    d.get("minSerialNumber"),
        "maxSerialNumber":    d.get("maxSerialNumber"),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "lotName":            _u(lotName),
        "cavityNote":         _u(cavityNote),
        # Die-cast opt-in: after birth at the machine, the proc auto-moves the LOT to
        # the Warehouse (storage). 0/1 -> BIT. Absent/false = no deposit (other origins).
        "depositToStorage":   1 if d.get("depositToStorage") else 0,
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_Create", params)


def getOriginTypeIdByCode(code):
    """Resolve a Lots.LotOriginType Id by Code (e.g. 'Manufactured', 'Received'), or
    None. Used by the die-cast entry screen to stamp the LOT origin. Wraps the
    existing lots/LotOriginType_List read."""
    try:
        rows = BlueRidge.Common.Db.execList("lots/LotOriginType_List", {}) or []
    except Exception as e:
        BlueRidge.Common.Util.log("getOriginTypeIdByCode failed: %s" % str(e))
        return None
    for r in rows:
        if r.get("Code") == code:
            return r.get("Id")
    return None


def get(lotId=None, lotName=None):
    """Fetch one LOT by Id or by name. Returns a dict or None."""
    BlueRidge.Common.Util.log("lotId=%s lotName=%s" % (lotId, lotName))
    return BlueRidge.Common.Db.execOne(
        "lots/Lot_Get",
        {"lotId": lotId, "lotName": lotName},
    )


def list(itemId=None, currentLocationId=None, lotStatusId=None, limitRows=100):
    """List LOTs with optional filters. Returns list[dict]."""
    BlueRidge.Common.Util.log(
        "itemId=%s currentLocationId=%s lotStatusId=%s limitRows=%s"
        % (itemId, currentLocationId, lotStatusId, limitRows)
    )
    params = {
        "itemId":            itemId,
        "currentLocationId": currentLocationId,
        "lotStatusId":       lotStatusId,
        "limitRows":         limitRows,
    }
    return BlueRidge.Common.Db.execList("lots/Lot_List", params)


def updateStatus(data, appUserId=None, terminalLocationId=None):
    """Transition a LOT's status. data carries lotId, newLotStatusId, reason,
       rowVersion. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "updateStatus data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              d.get("lotId"),
        "newLotStatusId":     d.get("newLotStatusId"),
        "reason":             d.get("reason"),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "rowVersion":         d.get("rowVersion"),
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_UpdateStatus", params)


def moveTo(lotId, toLocationId, appUserId=None, terminalLocationId=None):
    """Move a LOT to a new location. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "lotId=%s toLocationId=%s appUserId=%s terminalLocationId=%s"
        % (lotId, toLocationId, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              lotId,
        "toLocationId":       toLocationId,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_MoveTo", params)


def assertNotBlocked(lotId):
    """Check whether a LOT is blocked (hold). Returns a dict
       {IsBlocked, Message} or None."""
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execOne(
        "lots/Lot_AssertNotBlocked",
        {"lotId": lotId},
    )


def getParents(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetParents", {"lotId": lotId})


def getChildren(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetChildren", {"lotId": lotId})


def getHistory(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetAttributeHistory", {"lotId": lotId})


def mapHistoryInstances(rows):
    """LOT Detail history repeater instances: one {'row': {...}} per history row
       with EventAtDisplay ('MM/dd HH:mm') and EventAgo ('3h ago') precomputed in
       Python. The HistoryRow view consumes the precomputed strings verbatim --
       date math in expression bindings proved unreliable for repeater params
       (the Date serializes to a string on the param hop; dateFormat/dateDiff
       then pass the raw value through), which surfaced as over-precise
       timestamps on the 2026-07-07 smoke."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    out = []
    for r in rows:
        r = dict(r or {})
        ev = r.get("EventAt")
        disp = ""
        ago = ""
        if ev is not None:
            try:
                disp = system.date.format(ev, "MM/dd HH:mm")
                mins = system.date.minutesBetween(ev, system.date.now())
                if mins < 1:
                    ago = "just now"
                elif mins < 60:
                    ago = "%dm ago" % mins
                elif mins < 1440:
                    ago = "%dh ago" % (mins // 60)
                else:
                    ago = "%dd ago" % (mins // 1440)
            except:
                # ev arrived as a pre-serialized string -- truncate to the same
                # 'yyyy-MM-dd HH:mm' precision rather than showing millis.
                disp = ("%s" % ev)[:16]
        r["EventAtDisplay"] = disp
        r["EventAgo"] = ago
        out.append({"row": r})
    return out


def mapTrimInventoryInstances(rows, selectable=False, selectedLotId=None):
    """TrimBody 'Currently in Trim' card-repeater instances (machining QueueRow
       styling, Jacques 2026-07-07). One instance per Lot_GetWipQueueByLocation
       row with the arrival display + FIFO position precomputed in Python.
       selectable=True renders the Select action (the Trim OUT pick list);
       selectedLotId highlights the active pick. Property-binding transform
       callers re-run this via the refreshToken bump on selection."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    selectable = bool(BlueRidge.Common.Util.extractQualifiedValues(selectable))
    selectedLotId = BlueRidge.Common.Util.extractQualifiedValues(selectedLotId)
    out = []
    pos = 0
    for r in rows:
        r = r or {}
        pos += 1
        arr = r.get("LastMovementAt")
        arrival = ""
        if arr is not None:
            try:
                arrival = system.date.format(arr, "MM/dd HH:mm")
            except:
                arrival = ("%s" % arr)[:16]
        out.append({
            "lotId":         r.get("Id"),
            "lotName":       r.get("LotName") or "",
            "item":          r.get("ItemPartNumber") or "",
            "pieceCount":    r.get("PieceCount") or 0,
            "arrival":       arrival,
            "position":      pos,
            "lotStatusCode": r.get("LotStatusCode") or "",
            "isSelected":    (selectedLotId is not None and r.get("Id") == selectedLotId),
            "selectable":    selectable,
        })
    return out


def mapMachiningOutQueue(rows, selectedLotId=None):
    """Machining OUT FIFO pick-list instances for MachiningOutSplit. One instance
       per Lot_GetWipQueueByLocation row (castings whose next route step is the
       MachiningOut consume-mint), oldest-first. selectedLotId highlights the
       operator's pick; when it is None or has drained out of the queue, the
       FIRST (oldest) row is selected by default so the terminal always opens on
       the next casting to work. Shape mirrors mapTrimInventoryInstances so the
       OutQueueRow sub-view is a drop-in."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(rows) or []
    selectedLotId = BlueRidge.Common.Util.extractQualifiedValues(selectedLotId)
    out = []
    pos = 0
    for r in rows:
        r = r or {}
        pos += 1
        arr = r.get("LastMovementAt")
        arrival = ""
        if arr is not None:
            try:
                arrival = system.date.format(arr, "MM/dd HH:mm")
            except:
                arrival = ("%s" % arr)[:16]
        out.append({
            "lotId":         r.get("Id"),
            "lotName":       r.get("LotName") or "",
            "item":          r.get("ItemPartNumber") or "",
            "pieceCount":    r.get("PieceCount") or 0,
            "arrival":       arrival,
            "position":      pos,
            "lotStatusCode": r.get("LotStatusCode") or "",
            "selectable":    True,
        })
    # Default-to-first: honour the operator pick while still queued, else fall
    # back to the oldest row (covers first load + a casting draining fully out).
    ids = [x["lotId"] for x in out]
    effective = selectedLotId if selectedLotId in ids else (out[0]["lotId"] if out else None)
    for x in out:
        x["isSelected"] = (x["lotId"] == effective)
    return out

def getLatestForToolCavityOrEmpty(toolId, toolCavityId, _refreshToken=None):
    """The cavity-scoped reject target (Jacques 2026-07-06): the newest open
       LOT cast on (tool, cavity). Always returns the fully-shaped dict
       {Id, LotName, PieceCount, InventoryAvailable, CavityNumber} with None/0
       values when nothing resolves (pre-declared-bound-props rule).
       _refreshToken is ignored - runScript bindings pass a bumped token to
       force a re-read after a create/reject."""
    toolId = _u(toolId)
    toolCavityId = _u(toolCavityId)
    BlueRidge.Common.Util.log("toolId=%s toolCavityId=%s" % (toolId, toolCavityId))
    empty = {"Id": None, "LotName": "", "PieceCount": 0,
             "InventoryAvailable": 0, "CavityNumber": None}
    if not toolId or not toolCavityId:
        return empty
    row = BlueRidge.Common.Db.execOne(
        "lots/Lot_GetLatestForToolCavity",
        {"toolId": toolId, "toolCavityId": toolCavityId},
    )
    return row if row else empty


def getScrapSummaryOrEmpty(lotId):
    """LOT Detail Total Scrap card (Jacques 2026-07-06). Always returns the
       fully-shaped dict {RejectedTotal, CounterScrap, TotalScrap} (zeros when
       no scrap / no lot) per the pre-declared-bound-props rule."""
    lotId = _u(lotId)
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    empty = {"RejectedTotal": 0, "CounterScrap": 0, "TotalScrap": 0}
    if lotId is None or lotId == "":
        return empty
    row = BlueRidge.Common.Db.execOne("lots/Lot_GetScrapSummary", {"lotId": lotId})
    return row if row else empty


def getPauses(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/LotPause_GetByLot", {"lotId": lotId})


def getGenealogyTree(lotId, direction="Both"):
    BlueRidge.Common.Util.log("lotId=%s direction=%s" % (lotId, direction))
    return BlueRidge.Common.Db.execList("lots/Lot_GetGenealogyTree", {"lotId": lotId, "direction": direction})


def search(query=None, lotStatusId=None, lotOriginTypeId=None, limitRows=100):
    BlueRidge.Common.Util.log("query=%s statusId=%s originId=%s limit=%s" % (query, lotStatusId, lotOriginTypeId, limitRows))
    params = {"query": query, "lotStatusId": lotStatusId, "lotOriginTypeId": lotOriginTypeId, "limitRows": limitRows}
    return BlueRidge.Common.Db.execList("lots/Lot_Search", params)


def moveToValidated(lotId, toLocationId, appUserId=None, terminalLocationId=None):
    """Arc 2 Phase 4. Server-authoritative validated inbound move (the Movement
       Scan commit). The proc re-checks eligibility (FDS-02-012) + MaxParts (OI-12)
       + not-blocked (B2) and performs the move atomically. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "lotId=%s toLocationId=%s appUserId=%s terminalLocationId=%s"
        % (lotId, toLocationId, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              _u(lotId),
        "toLocationId":       _u(toLocationId),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_MoveToValidated", params)


def getCellLineQuantity(locationId, itemId):
    """Arc 2 Phase 4. Sum of open-LOT PieceCount for an Item at a location.
       Returns {ExistingPieceCount} or None."""
    BlueRidge.Common.Util.log("locationId=%s itemId=%s" % (locationId, itemId))
    return BlueRidge.Common.Db.execOne(
        "lots/Lot_GetCellLineQuantity",
        {"locationId": _u(locationId), "itemId": _u(itemId)},
    )


def getWipQueueByLocation(locationId, includeDescendants=False, _refreshToken=None, operationTypeCode=None):
    """Route-driven WIP queue at a location (terminal-mint spec §3.2): open LOTs whose
       next PENDING route step carries operationTypeCode (the terminal's OperationType
       role, e.g. 'MachiningIn' / 'MachiningOut' / 'AssemblyOut'), in arrival order.
       When operationTypeCode is empty/None every open LOT at the location is returned
       with its resolved next-step role (NextOperationTypeCode / NextSequenceNumber) so
       the caller can slice by role in a transform.

       operationTypeCode is the LAST arg so existing positional bindings
       (locationId, includeDescendants, refreshToken) keep working; pass a 4th arg to
       filter by role. Returns list[dict]."""
    otc = _u(operationTypeCode)
    otc = otc if otc else None   # "" (from an expression binding) -> None -> all roles
    BlueRidge.Common.Util.log("locationId=%s includeDescendants=%s operationTypeCode=%s"
                              % (locationId, includeDescendants, otc))
    return BlueRidge.Common.Db.execList(
        "lots/Lot_GetWipQueueByLocation",
        {"locationId": _u(locationId), "operationTypeCode": otc,
         "includeDescendants": bool(includeDescendants)},
    )


def getComponentsAtCell(locationId, includeDescendants=True, _refreshToken=None):
    """'Components at this cell' read for the assembly screens
       (Lots.Lot_GetComponentsAtCell): the UNION of route-driven WIP (LOTs whose next
       pending route step is here) AND routeless components that are BomDerived-eligible
       here (a BOM child of a finished good eligible at this cell). Fixes routeless
       received/purchased components being dropped by getWipQueueByLocation's route
       INNER JOIN. Same column shape as getWipQueueByLocation (routeless rows carry NULL
       NextOperationTypeCode). _refreshToken is an ignored runScript re-read arg."""
    if locationId is None:
        return []
    BlueRidge.Common.Util.log("getComponentsAtCell locationId=%s includeDescendants=%s"
                              % (locationId, includeDescendants))
    return BlueRidge.Common.Db.execList(
        "lots/Lot_GetComponentsAtCell",
        {"locationId": _u(locationId), "includeDescendants": bool(includeDescendants)},
    )


def getLineInventoryCards(locationId, _refreshToken=None):
    """Flex-repeater instances for the line-inventory popup's on-hand list, rendered
       with the Trim InventoryRow card (display-only, selectable=False). Fetches
       getLineInventoryByPart and maps each row to the card's params; ArrivedAt is
       precomputed to a display string (repeater-param date rule). Scalar args only
       (fetch inside) per the ImmutableList re-eval rule. Returns list[dict]."""
    locationId = _u(locationId)
    if locationId is None:
        return []
    rows = getLineInventoryByPart(locationId) or []
    out = []
    pos = 0
    for r in rows:
        r = r or {}
        pos += 1
        arr = r.get("ArrivedAt")
        arrival = ""
        if arr is not None:
            try:
                arrival = system.date.format(arr, "MM/dd HH:mm")
            except:
                arrival = ("%s" % arr)[:16]
        out.append({
            "lotId":         r.get("LotId"),
            "lotName":       r.get("LotName") or "",
            "item":          r.get("PartNumber") or "",
            "pieceCount":    r.get("InventoryAvailable") or 0,
            "arrival":       arrival,
            "position":      pos,
            "lotStatusCode": "Good",
            "isSelected":    False,
            "selectable":    False,
        })
    return out


def getByName(lotName):
    """Convenience alias: fetch one LOT by its LTT name. Returns a dict or None."""
    return get(lotName=_u(lotName))


_EMPTY_LOT = {
    "Id": None, "LotName": "", "ItemId": None, "ItemPartNumber": "",
    "PieceCount": 0, "MaxPieceCount": 0, "InventoryAvailable": 0,
    "TotalInProcess": 0, "LotStatusCode": "", "LotStatusName": "",
    "LotOriginTypeCode": "", "CurrentLocationId": None,
    "CurrentLocationName": "", "CrtActive": None, "ToolId": None,
    "ToolCode": "", "ToolCavityNumber": "",
}


def getOrEmpty(lotId=None, lotName=None, _refreshToken=None):
    """Binding/summary-safe variant of get(): ALWAYS returns a fully-shaped LOT dict
       (pre-declared-bound-props rule) so nested-path bindings never Component-Error.
       Not-found / blank input -> the _EMPTY_LOT shape (Id None). A found row is
       merged OVER the empty shape, so every display key exists either way.
       _refreshToken is ignored (runScript re-read arg)."""
    lotId = _u(lotId)
    lotName = _u(lotName)
    if lotName is not None and ("%s" % lotName).strip() == "":
        lotName = None
    if lotId is None and lotName is None:
        return dict(_EMPTY_LOT)
    row = get(lotId=lotId, lotName=lotName)
    if not row:
        return dict(_EMPTY_LOT)
    out = dict(_EMPTY_LOT)
    out.update(row)
    return out


def getLineInventoryByPart(locationId, _refreshToken=None):
    """Spec 2 Task I2. On-hand open LOTs at a line location, grouped by part then
       FIFO by arrival, for the inventory check-in popup. Returns list[dict] with
       ItemId, PartNumber, Description, LotId, LotName, InventoryAvailable, ArrivedAt.
       _refreshToken is unused server-side; it lets a view's expression binding
       re-run the read after a check-in by referencing a bumped token."""
    if locationId is None:
        return []
    BlueRidge.Common.Util.log("getLineInventoryByPart locationId=%s" % locationId)
    return BlueRidge.Common.Db.execList(
        "lots/Lot_GetLineInventoryByPart", {"locationId": _u(locationId)})


def getStatusOptions():
    return [{"label": r["Name"], "value": r["Id"]} for r in BlueRidge.Common.Db.execList("lots/LotStatusCode_List")]


def getOriginOptions():
    return [{"label": r["Name"], "value": r["Id"]} for r in BlueRidge.Common.Db.execList("lots/LotOriginType_List")]


def getShiftCavityTally(toolId, _refreshToken=None):
    """Arc 2 Phase 3 die-cast right rail. One row per active (configured) cavity of
       the mounted die: PieceSum = sum of as-cast pieces this OEE shift (live
       PieceCount + rejected qty added back, v1.1 2026-07-06), RejectSum = the
       per-cavity scrapped qty, ShiftShots = max(PieceSum) across cavities (all
       computed in SQL). Returns list[dict]; [] when no die is mounted.
       _refreshToken is ignored - runScript bindings pass a bumped token to force
       a re-read (runScript caches on args)."""
    toolId = _u(toolId)
    BlueRidge.Common.Util.log("toolId=%s" % toolId)
    if toolId is None or toolId == "":
        return []
    return BlueRidge.Common.Db.execList("lots/Lot_GetShiftCavityTally", {"toolId": toolId})


def shiftCavityOptions(tally):
    """[{label, value}] for the right-rail cavity dropdown, built from a tally list
       so every configured cavity appears (value = ToolCavityId). Presentation only."""
    rows = _tallyRows(tally)
    return [{"label": r.get("CavityLabel") or ("Cavity %s" % r.get("CavityNumber")),
             "value": r.get("ToolCavityId")} for r in rows]


def shiftSumForCavity(tally, toolCavityId):
    """The selected cavity's shift piece sum from a tally list. Int (0 if absent)."""
    rows = _tallyRows(tally)
    cid = _u(toolCavityId)
    for r in rows:
        if r.get("ToolCavityId") == cid:
            return r.get("PieceSum") or 0
    return 0


def shiftScrapForCavity(tally, toolCavityId):
    """The selected cavity's shift scrapped quantity (RejectSum) from a tally
       list. Int (0 if absent). Jacques 2026-07-06: the shift card surfaces scrap."""
    rows = _tallyRows(tally)
    cid = _u(toolCavityId)
    for r in rows:
        if r.get("ToolCavityId") == cid:
            return r.get("RejectSum") or 0
    return 0


def shiftShotsFromTally(tally):
    """ShiftShots (the busiest cavity's as-cast piece total this shift) from a
       tally list - identical on every row, so read the first. Int (0 when
       empty). This is the actual 'Shots this shift' number for the card; it was
       computed in SQL but never displayed before 2026-07-06."""
    rows = _tallyRows(tally)
    for r in rows:
        return r.get("ShiftShots") or 0
    return 0


def shiftShotsForTool(toolId, _refreshToken=None):
    """'Shots this shift' KPI value, fetched-and-computed from SCALAR args only
       (toolId + ignored refresh token). runScript expression bindings must not
       pass container props -- re-evaluations receive them as ImmutableList,
       which neither extractQualifiedValues nor the JSON round-trip survive
       (feedback_ignition_immutable_map_unwrap). The tally query is cheap."""
    return shiftShotsFromTally(getShiftCavityTally(toolId))


def shiftSumForCavityOnTool(toolId, toolCavityId, _refreshToken=None):
    """'Pieces this shift (selected cavity)' KPI value from scalar args --
       see shiftShotsForTool for why the tally is fetched here."""
    return shiftSumForCavity(getShiftCavityTally(toolId), toolCavityId)


def shiftScrapForCavityOnTool(toolId, toolCavityId, _refreshToken=None):
    """'Scrap this shift (selected cavity)' KPI value from scalar args --
       see shiftShotsForTool for why the tally is fetched here."""
    return shiftScrapForCavity(getShiftCavityTally(toolId), toolCavityId)


def defaultShiftCavityId(tally):
    """ToolCavityId of the busiest cavity this shift (highest PieceSum) -> the
       default right-rail selection so the card opens on the most accurate shot
       count. None when the tally is empty."""
    rows = _tallyRows(tally)
    best = None
    bestSum = -1
    for r in rows:
        s = r.get("PieceSum") or 0
        if s > bestSum:
            bestSum = s
            best = r.get("ToolCavityId")
    return best
