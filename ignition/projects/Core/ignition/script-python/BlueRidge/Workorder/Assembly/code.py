"""BlueRidge.Workorder.Assembly - thin access to the Phase 6 Assembly IN proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (FDS-06-008 uncoupled path:
   the operator scans a machined component LOT into an Assembly Cell's queue so it
   can be consumed at the fill). Entry logs at default INFO. Routes through
   BlueRidge.Common.Db.execMutation; appUserId defaults to the current operator
   when None."""

import system.perspective
import java.lang


def scanIn(cellLocationId, lotName=None, lotId=None, appUserId=None, terminalLocationId=None):
    """Move a machined component LOT into an Assembly Cell's queue (no rename).
       The operator typically scans an LTT barcode -> pass it as lotName; lotId is
       accepted too. Validates the LOT's Item is a BOM component of an assembly
       produced at the cell; a non-component LOT rejects. Returns {Status, Message,
       NewId (LotMovementId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "scanIn lotName=%s lotId=%s cellLocationId=%s appUserId=%s"
        % (lotName, lotId, cellLocationId, appUserId))
    params = {"lotId": lotId, "lotName": lotName, "cellLocationId": cellLocationId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("workorder/Assembly_ScanIn", params)


def completeTray(finishedGoodItemId, pieceCount, cellLocationId,
                 closureMethod=None, appUserId=None, terminalLocationId=None):
    """Complete an assembly tray = mint the finished-good LOT (tray = LOT), consume
       BOM x PieceCount FIFO from component stock at the cell INTO that LOT, and attach
       the tray to the cell's open Container (auto-open). Returns {Status, Message,
       FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull}. When
       ContainerFull is 1 the caller (view) should complete the container via
       BlueRidge.Lots.Container.complete (AIM claim + ShippingLabel) - this proc does
       NOT complete the container (Spec 2 delegation)."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "completeTray finishedGoodItemId=%s pieceCount=%s cellLocationId=%s appUserId=%s"
        % (finishedGoodItemId, pieceCount, cellLocationId, appUserId))
    params = {"finishedGoodItemId": finishedGoodItemId, "pieceCount": pieceCount,
              "cellLocationId": cellLocationId, "closureMethod": closureMethod,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("workorder/Assembly_CompleteTray", params)


def _asId(value):
    """A BIGINT id from whatever a binding/runScript hands over (QualifiedValue, Long,
       int, numeric string), or None."""
    v = BlueRidge.Common.Util.extractQualifiedValues(value)
    if v is None or ("%s" % v).strip() == "":
        return None
    try:
        return long(v)
    except (ValueError, TypeError):
        return None


def getStationContainerRows(cellLocationId, terminalLocationId, closureMethod,
                            selectedFinishedGoodItemId=None, _refreshToken=None):
    """The assembly screen's box, as a list the view's transform takes [0] of.

       Open boxes at the line this STATION may fill (its own + unowned, migration
       0078) for the terminal's closure method; narrowed to the selected finished
       good when one is chosen, so the part dropdown decides which box is shown and
       filled. Own boxes sort before unowned ones -- the same order
       Workorder.Assembly_CompleteTray v1.4 resolves in, so what the screen shows is
       the box the next tray lands in. Empty = no box yet for that part (the first
       tray opens one). `_refreshToken` is the ignored runScript re-read arg."""
    tid = _asId(terminalLocationId)
    rows = BlueRidge.Lots.Container.listOpenForStation(cellLocationId, tid, closureMethod) or []
    fg = _asId(selectedFinishedGoodItemId)
    if fg is not None:
        rows = [r for r in rows if _asId(r.get("ItemId")) == fg]
    rows.sort(key=lambda r: 0 if (tid is not None and _asId(r.get("StationLocationId")) == tid) else 1)
    return rows


def getStationOpenBoxesText(cellLocationId, terminalLocationId, closureMethod, _refreshToken=None):
    """One line naming every open box this station may fill, with its fill, so an
       operator switching parts can see which partial boxes are waiting:
       'Open boxes: 12231-6MAA-J000 5/10 | 12241-6MAA-J000 2/10 (unclaimed)'.
       '' when there are none. ASCII-only."""
    tid = _asId(terminalLocationId)
    rows = getStationContainerRows(cellLocationId, tid, closureMethod)
    if not rows:
        return ""
    parts = []
    for r in rows:
        text = "%s %s/%s" % (r.get("ItemPartNumber") or "?",
                             r.get("AccumulatedParts") or 0, r.get("TargetParts") or 0)
        if tid is not None and _asId(r.get("StationLocationId")) != tid:
            text += " (unclaimed)"
        parts.append(text)
    return "Open boxes: " + " | ".join(parts)


def getDefaultFinishedGoodId(cellLocationId, terminalLocationId=None, closureMethod=None):
    """The part to pre-select when the assembly screen loads: the part of this
       station's oldest open box, so a returning operator lands on the box they were
       filling; with no box of its own, the recommended finished good."""
    tid = _asId(terminalLocationId)
    if tid is not None:
        for r in getStationContainerRows(cellLocationId, tid, closureMethod):
            if _asId(r.get("StationLocationId")) == tid:
                return r.get("ItemId")
    return getRecommendedFinishedGoodId(cellLocationId)


def handleTrayComplete(container, draft, selectedFinishedGoodItemId, cellLocationId, closureMethod=None,
                       terminalLocationId=None):
    """View helper for the assembly tray-complete button. Resolves the finished-good
       Item, validates the parts count, and mints the FG LOT via completeTray.
       closureMethod is the terminal's active mode (session.custom.closureMethod) - it
       selects the part's per-method ContainerConfig and is REQUIRED by the proc.
       Returns the completeTray result dict, or a Status-0 dict on a validation miss
       (surfaced by notifyResult).

       2026-09-11 (migration 0078): the SELECTED part decides -- the screen's box is
       derived from the selection (getStationContainerRows), so the two agree, and an
       operator switching parts switches boxes instead of being forced into the
       oldest open box on the line. The open box's part is only the fallback when
       nothing is selected. terminalLocationId is the TERMINAL (it scopes the box to
       this station and is what the shipping label, CRT switch and audit are stamped
       with); the line id was passed here before, which silently kept boxes
       line-wide. None keeps that old behaviour for any caller not yet passing it.

       Backlog: "for a by-count completion, if the tray count is one tray per
       container it should also complete the container so they don't have to
       complete the tray and then the container." When ContainerFull and
       TraysPerContainer == 1 there is no ambiguity -- the tray the operator just
       closed IS the whole container, so this auto-chains into
       Lots.Container.complete the same way plcCompleteTray already does for
       ByWeight/ByVision (operatorConfirmed=True: the operator DID just take an
       explicit action, unlike the PLC path's plcCompletionConfirmed). Any
       TraysPerContainer > 1 still requires the separate manual Complete button
       (the container-24 incident this proc's header documents is exactly why a
       multi-tray container is never auto-completed here)."""
    cnt = BlueRidge.Common.Util.toIntOrNone(draft.get("partsCount")) if draft else None
    closureMethod = BlueRidge.Common.Util.extractQualifiedValues(closureMethod)
    fgItem = _asId(selectedFinishedGoodItemId)
    if fgItem is None and container and container.get("Id") is not None:
        fgItem = container.get("ItemId")
    if fgItem is None:
        return {"Status": False, "Message": "Select a finished good (or open a container) first."}
    if cnt is None:
        return {"Status": False, "Message": "Enter the parts count for the tray."}
    if not closureMethod:
        return {"Status": False, "Message": "No closure mode set for this terminal."}
    term = _asId(terminalLocationId)
    if term is None:
        term = cellLocationId
    result = completeTray(fgItem, cnt, cellLocationId, closureMethod=closureMethod,
                          terminalLocationId=term)
    if (result and result.get("Status") and result.get("ContainerFull")
            and result.get("ContainerId") is not None and result.get("TraysPerContainer") == 1):
        result["ContainerComplete"] = BlueRidge.Lots.Container.complete(
            result.get("ContainerId"), operatorConfirmed=True, terminalLocationId=term)
    if result and result.get("Status"):
        warnLowInventory(cellLocationId, fgItem, closureMethod)
    return result


def resolvePlcCloseContext(terminalLocationId, closureMethod):
    """Headless resolution of everything a PLC-triggered tray close needs, from just
       the terminal + closure method -- mirrors the operator AssemblyNonSerialized
       flow so a PLC line and an operator line mint identically:
         cellLocationId    = the terminal's zone cell (Terminal_List.ZoneId);
         finishedGoodItemId= the OPEN container's item, else the recommended FG;
         pieceCount        = the (item, method) ContainerConfig.PartsPerTray;
         containerId       = the open container's Id, or None (proc auto-opens).
       Returns that dict, or {"error": <str>} on any missing input -- never a faked
       default, so the caller logs + alarms instead of minting a wrong LOT.

       2026-09-11 (migration 0078): scoped to THIS terminal and closure method. The
       6MA line carries METTs A/B (ByCount) and the vision cell on one line; reading
       "the first open box on the line" let a camera tray resolve to a METTs box, and
       with no box the ranked list could pick a single METTs part (its one-line BOM
       ties the set and sorts first). Now: this station's own box (else an unowned
       one) with a pack-out for closureMethod, else the top-ranked finished good that
       HAS a closureMethod pack-out."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    if tid is None:
        return {"error": "No terminal bound to the PLC device."}
    term = BlueRidge.Location.Terminal.findById(BlueRidge.Location.Terminal.listAll(), tid)
    cell = (term or {}).get("ZoneId")
    if cell is None:
        return {"error": "Terminal %s has no zone cell." % tid}
    containerId = None
    openRows = getStationContainerRows(cell, tid, closureMethod)
    if openRows:
        fgItem = openRows[0].get("ItemId")
        containerId = openRows[0].get("Id")
    else:
        fgItem = _recommendedWithPackout(cell, closureMethod)
    if fgItem is None:
        return {"error": "No open %s box and no eligible finished good with a %s pack-out at cell %s."
                % (closureMethod, closureMethod, cell)}
    cfg = BlueRidge.Parts.ContainerConfig.getByItemAndMethod(fgItem, closureMethod) or {}
    ppt = cfg.get("PartsPerTray")
    try:
        ppt = int(ppt) if ppt is not None else None
    except (ValueError, TypeError):
        ppt = None
    if not ppt or ppt <= 0:
        return {"error": "No %s pack-out (PartsPerTray) configured for finished good %s."
                % (closureMethod, fgItem)}
    return {"cellLocationId": cell, "finishedGoodItemId": fgItem,
            "pieceCount": ppt, "containerId": containerId}


def notifyInventoryChanged(cellLocationId, terminalLocationId):
    """Best-effort live-refresh push after a lights-out PLC completion. Public --
       called by plcCompleteTray (ByWeight/ByVision) and the MIP watchers
       (NonSerializedMipWatcher, SerializedMipWatcher) after a successful mint /
       tray close. The close
       runs in GATEWAY scope (tag-change script) with no session, so the operator
       terminal never hears about it -- unlike the operator ByCount path, which
       refreshes in-session. Send the same 'inventoryChanged' page-scoped message
       the InventoryManager sends, but carry the event's cellLocationId so each
       terminal's handler refreshes ONLY when it matches its own cell (the
       InventoryManager payload has no cellLocationId -> those handlers still
       refresh unconditionally, preserving manual-move behavior).

       system.perspective.sendMessage in GATEWAY scope REQUIRES an explicit
       sessionId + pageId (it cannot default to "the current session" -- there is
       none), so there is no true broadcast: enumerate every open session/page via
       getSessionInfo() and target each. Non-terminal pages simply have no
       'inventoryChanged' handler and ignore it. Never raises into the completion
       path -- a failed UI nudge must not undo a committed tray close.

       Routes through PlcWatcher.broadcastPageMessage -- the shared, hardened
       enumeration (skips non-UUID-shaped session/page entries; one such entry
       threw java.lang.IllegalArgumentException on every single call before this
       was factored out, 2026-08-20)."""
    payload = {"cellLocationId": cellLocationId,
               "terminalLocationId": terminalLocationId,
               "source": "plc"}
    BlueRidge.Workorder.PlcWatcher.broadcastPageMessage("inventoryChanged", payload)


def warnLowInventory(cellLocationId, finishedGoodItemId, closureMethod):
    """Backlog: "when an inventory is low, all terminals on the line should get a
       warning." Called after a tray close (both the operator ByCount path and
       plcCompleteTray) to re-check the SAME IsLow flag already computed for the
       Assembly OUT sidebar (Workorder.Assembly_GetComponentProjection -- on-hand
       vs what is still needed to finish the CURRENT container), and if anything
       is low, broadcast a 'lowInventoryWarning' toast to every terminal on the
       same line (Location.Terminal_ListByLineOf: every Terminal sharing the
       triggering cell's ancestor WorkCenter), not just the terminal that
       happened to close the tray.

       v1 fires every time IsLow is true after a close, not only on the
       false->true transition -- simple, and a repeated non-blocking toast while
       genuinely low is a lesser risk than a missed one; revisit with session-level
       dedup if it proves noisy in practice.

       Best-effort, mirrors notifyInventoryChanged: never raises into the
       completion path, enumerates every open session/page (GATEWAY-scope
       sendMessage has no "current session" to default to), and terminals with no
       'lowInventoryWarning' handler simply ignore it."""
    try:
        rows = getComponentProjection(cellLocationId, finishedGoodItemId, closureMethod) or []
        low = [r for r in rows if r.get("IsLow")]
        if not low:
            return
        terminalIds = [t.get("TerminalLocationId") for t in
                      (BlueRidge.Location.Terminal.listByLineOf(cellLocationId) or [])]
        if not terminalIds:
            return
        parts = [r.get("PartNumber") or r.get("ItemPartNumber") or "?" for r in low]
        payload = {"terminalIds": terminalIds, "cellLocationId": cellLocationId, "parts": parts}
        for s in (system.perspective.getSessionInfo() or []):
            sid = s["id"]
            for pid in (s["pageIds"] or []):
                try:
                    system.perspective.sendMessage(
                        "lowInventoryWarning", payload=payload,
                        scope="page", sessionId=sid, pageId=pid)
                except (Exception, java.lang.Exception) as e:
                    BlueRidge.Common.Util.log(
                        "warnLowInventory send failed sid=%s pid=%s: %s"
                        % (sid, pid, e), level="warn")
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("warnLowInventory failed: %s" % e, level="warn")


def plcCompleteTray(terminalLocationId, closureMethod):
    """Shared PLC-triggered tray close for ByWeight / ByVision. Resolves the close
       context headlessly, then mints the FG LOT + consumes BOM via the SAME
       Assembly_CompleteTray proc the operator ByCount path uses (identical
       genealogy). PLC lines run lights-out, so on ContainerFull it auto-completes
       the container -- AIM claim + label print via Container_Complete with
       plcCompletionConfirmed=True. Returns the completeTray result dict (with a
       "ContainerComplete" sub-result when the container was completed), or a
       {"Status": 0, "Message": <resolution error>} dict with NO LOT minted."""
    ctx = resolvePlcCloseContext(terminalLocationId, closureMethod)
    if ctx.get("error"):
        return {"Status": 0, "Message": ctx["error"]}
    appUserId = BlueRidge.Common.Util.systemAppUserId()
    result = completeTray(ctx["finishedGoodItemId"], ctx["pieceCount"], ctx["cellLocationId"],
                          closureMethod=closureMethod, appUserId=appUserId,
                          terminalLocationId=terminalLocationId)
    if result and result.get("Status") and result.get("ContainerFull") and result.get("ContainerId") is not None:
        result["ContainerComplete"] = BlueRidge.Lots.Container.complete(
            result.get("ContainerId"), plcCompletionConfirmed=True,
            appUserId=appUserId, terminalLocationId=terminalLocationId)
    # Live-refresh the operator terminal at this cell (gateway scope -> no session
    # unless we push). Best-effort; only fires on a real close.
    if result and result.get("Status"):
        notifyInventoryChanged(ctx.get("cellLocationId"), terminalLocationId)
        warnLowInventory(ctx.get("cellLocationId"), ctx.get("finishedGoodItemId"), closureMethod)
    return result


def _rankedFinishedGoods(cellLocationId):
    """Ranked eligible finished goods at the cell (terminal-mint decision 6/B5):
       ordered by BOM-satisfiability against ready line inventory, recommended-first.
       Each row: {Id, PartNumber, Description, LinesSatisfied, IsRecommended}."""
    if cellLocationId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "parts/Item_ListEligibleFinishedGoodsRanked", {"locationId": cellLocationId}) or []
    except Exception as e:
        BlueRidge.Common.Util.log("_rankedFinishedGoods failed: %s" % str(e), level="warn")
        return []


def getEligibleFinishedGoodsForDropdown(cellLocationId):
    """Returns [{label, value}, ...] of the finished-good Items eligible at the assembly
       cell, for the persistent finished-good dropdown -- RANKED so the recommended FG
       (best BOM match against ready line inventory) is first. Value is Parts.Item.Id;
       label is 'PartNumber - Description'."""
    out = []
    for r in _rankedFinishedGoods(cellLocationId):
        part = r.get("PartNumber") or ""
        desc = r.get("Description") or ""
        label = ("%s - %s" % (part, desc)) if desc else part
        out.append({"label": label, "value": r.get("Id")})
    return out


def _recommendedWithPackout(cellLocationId, closureMethod):
    """The highest-ranked eligible finished good at the cell that has a pack-out
       for closureMethod (ranking is SQL -- Item_ListEligibleFinishedGoodsRanked;
       this only skips parts that cannot be packed this way), or None."""
    for r in _rankedFinishedGoods(cellLocationId):
        cfg = BlueRidge.Parts.ContainerConfig.getByItemAndMethod(r.get("Id"), closureMethod) or {}
        if cfg.get("PartsPerTray"):
            return r.get("Id")
    return None


def getRecommendedFinishedGoodId(cellLocationId):
    """The Item.Id of the recommended finished good to pre-select at the cell (the
       IsRecommended=1 row, i.e. the top of the ranked list), or None if none eligible.
       The Assembly OUT view binds the dropdown's default to this."""
    for r in _rankedFinishedGoods(cellLocationId):
        if r.get("IsRecommended"):
            return r.get("Id")
    return None


def getComponentProjection(cellLocationId, finishedGoodItemId, closureMethod=None, _refreshToken=None):
    """DISPLAY-ONLY: per active-BOM component of the finished good, how many will be consumed
       to COMPLETE the current container + a low-stock flag, for the Assembly OUT line-inventory
       panel. NOT a gate -- the authoritative sufficiency check is in Assembly_CompleteTray.
       Thin glue: all math lives in Workorder.Assembly_GetComponentProjection. Returns
       list[dict] (empty = nothing to show). `_refreshToken` is the ignored runScript re-read
       arg, consistent with getComponentsAtCell / getOpenByCell."""
    cellLocationId = BlueRidge.Common.Util.extractQualifiedValues(cellLocationId)
    finishedGoodItemId = BlueRidge.Common.Util.extractQualifiedValues(finishedGoodItemId)
    closureMethod = BlueRidge.Common.Util.extractQualifiedValues(closureMethod)
    if cellLocationId is None or finishedGoodItemId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "workorder/Assembly_GetComponentProjection",
        {"locationId": cellLocationId, "finishedGoodItemId": finishedGoodItemId,
         "closureMethod": closureMethod})


def completeBoxToPrinter(containerId, terminalLocationId, printerLocationId, appUserId=None):
    """Card 'Complete (box)': complete the container, then print its shipping label
       to the card's printer. Container.complete claims the AIM shipper + generates
       the ShippingLabel; the dispatch (routed to printerLocationId) does the ZPL.
       Returns {Status, Message}. On a completed-but-unprinted box the ShippingLabel
       row persists (re-dispatchable), so a print miss is never a lost record."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    cid = BlueRidge.Common.Util.extractQualifiedValues(containerId)
    res = BlueRidge.Lots.Container.complete(cid, operatorConfirmed=True,
                                            appUserId=appUserId, terminalLocationId=terminalLocationId)
    if not res or not res.get("Status"):
        return res or {"Status": 0, "Message": "Container complete failed."}
    # Brief D: dispatch the persisted shipping label (rendered + stored by Container_Complete)
    # by its row id -- the dispatcher reads ShippingLabel.ZplContent and prints async.
    slId = res.get("ShippingLabelId")
    if slId is None:
        # SuppressAimAndLabel terminal (parallel run, Container_Complete v1.2): the box
        # completed with no AIM serial and no label row -- nothing to print.
        return {"Status": 1, "Message": res.get("Message") or "Box completed; label suppressed at this terminal."}
    disp = BlueRidge.Lots.ShippingDispatcher.dispatch(
        shippingLabelId=slId, terminalLocationId=terminalLocationId, printerLocationId=printerLocationId)
    if disp and disp.get("Status"):
        return {"Status": 1, "Message": "Box completed; shipping label sent to printer."}
    # Box IS complete; only the print missed -> surface the print message, not a hard failure.
    return {"Status": 1, "Message": "Box completed. " + ((disp or {}).get("Message") or "Label not printed - use Reprint.")}
