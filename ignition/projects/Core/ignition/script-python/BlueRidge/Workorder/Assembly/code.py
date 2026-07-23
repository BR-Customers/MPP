"""BlueRidge.Workorder.Assembly - thin access to the Phase 6 Assembly IN proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (FDS-06-008 uncoupled path:
   the operator scans a machined component LOT into an Assembly Cell's queue so it
   can be consumed at the fill). Entry logs at default INFO. Routes through
   BlueRidge.Common.Db.execMutation; appUserId defaults to the current operator
   when None."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Location.Terminal
import BlueRidge.Lots.Container
import BlueRidge.Parts.ContainerConfig
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


def handleTrayComplete(container, draft, selectedFinishedGoodItemId, cellLocationId, closureMethod=None):
    """View helper for the assembly tray-complete button. Resolves the finished-good
       Item (the open container's Item, or the operator-selected FG when no container
       is open yet - completeTray auto-opens one), validates the parts count, and mints
       the FG LOT via completeTray. closureMethod is the terminal's active mode
       (session.custom.closureMethod) - it selects the part's per-method ContainerConfig
       and is REQUIRED by the proc. Returns the completeTray result dict, or a Status-0
       dict on a validation miss (surfaced by notifyResult)."""
    cnt = BlueRidge.Common.Util.toIntOrNone(draft.get("partsCount")) if draft else None
    closureMethod = BlueRidge.Common.Util.extractQualifiedValues(closureMethod)
    if container and container.get("Id") is not None:
        fgItem = container.get("ItemId")
    else:
        fgItem = selectedFinishedGoodItemId
    if fgItem is None:
        return {"Status": False, "Message": "Select a finished good (or open a container) first."}
    if cnt is None:
        return {"Status": False, "Message": "Enter the parts count for the tray."}
    if not closureMethod:
        return {"Status": False, "Message": "No closure mode set for this terminal."}
    return completeTray(fgItem, cnt, cellLocationId, closureMethod=closureMethod,
                        terminalLocationId=cellLocationId)


def resolvePlcCloseContext(terminalLocationId, closureMethod):
    """Headless resolution of everything a PLC-triggered tray close needs, from just
       the terminal + closure method -- mirrors the operator AssemblyNonSerialized
       flow so a PLC line and an operator line mint identically:
         cellLocationId    = the terminal's zone cell (Terminal_List.ZoneId);
         finishedGoodItemId= the OPEN container's item, else the recommended FG;
         pieceCount        = the (item, method) ContainerConfig.PartsPerTray;
         containerId       = the open container's Id, or None (proc auto-opens).
       Returns that dict, or {"error": <str>} on any missing input -- never a faked
       default, so the caller logs + alarms instead of minting a wrong LOT."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    if tid is None:
        return {"error": "No terminal bound to the PLC device."}
    term = BlueRidge.Location.Terminal.findById(BlueRidge.Location.Terminal.listAll(), tid)
    cell = (term or {}).get("ZoneId")
    if cell is None:
        return {"error": "Terminal %s has no zone cell." % tid}
    containerId = None
    openRows = BlueRidge.Lots.Container.getOpenByCell(cell) or []
    if openRows:
        fgItem = openRows[0].get("ItemId")
        containerId = openRows[0].get("Id")
    else:
        fgItem = getRecommendedFinishedGoodId(cell)
    if fgItem is None:
        return {"error": "No open container and no eligible finished good at cell %s." % cell}
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
       path -- a failed UI nudge must not undo a committed tray close. Catches
       java.lang.Exception too (Jython's `except Exception` does not catch Java
       throwables)."""
    payload = {"cellLocationId": cellLocationId,
               "terminalLocationId": terminalLocationId,
               "source": "plc"}
    try:
        for s in (system.perspective.getSessionInfo() or []):
            sid = s["id"]
            for pid in (s["pageIds"] or []):
                try:
                    system.perspective.sendMessage(
                        "inventoryChanged", payload=payload,
                        scope="page", sessionId=sid, pageId=pid)
                except (Exception, java.lang.Exception) as e:
                    BlueRidge.Common.Util.log(
                        "notifyInventoryChanged send failed sid=%s pid=%s: %s"
                        % (sid, pid, e), level="warn")
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("notifyInventoryChanged enumerate failed: %s" % e, level="warn")


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
        BlueRidge.Common.Util.log("_rankedFinishedGoods failed: %s" % str(e))
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


def getRecommendedFinishedGoodId(cellLocationId):
    """The Item.Id of the recommended finished good to pre-select at the cell (the
       IsRecommended=1 row, i.e. the top of the ranked list), or None if none eligible.
       The Assembly OUT view binds the dropdown's default to this."""
    for r in _rankedFinishedGoods(cellLocationId):
        if r.get("IsRecommended"):
            return r.get("Id")
    return None
