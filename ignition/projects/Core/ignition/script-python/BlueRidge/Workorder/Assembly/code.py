"""BlueRidge.Workorder.Assembly - thin access to the Phase 6 Assembly IN proc.

   Wrappers only; no business logic. Arc 2 Phase 6 (FDS-06-008 uncoupled path:
   the operator scans a machined component LOT into an Assembly Cell's queue so it
   can be consumed at the fill). Entry logs at default INFO. Routes through
   BlueRidge.Common.Db.execMutation; appUserId defaults to the current operator
   when None."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


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
