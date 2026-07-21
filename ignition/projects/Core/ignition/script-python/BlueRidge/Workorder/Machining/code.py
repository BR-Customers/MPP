"""BlueRidge.Workorder.Machining - thin access to the Machining procs.

   Thin proc wrappers (no domain logic). Terminal-mint model (spec 2026-07-07):
   Machining IN is a pure advance (recordPick); Machining OUT is a consume-mint
   (mint) that additionally auto-prints the new sublot's LTT label after a
   successful mint. Each entry logs at default INFO (meaningful shop-floor events)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Common.Notify
import BlueRidge.Lots.LotLabel


def recordPick(lotId, lineLocationId, appUserId=None, terminalLocationId=None):
    """Machining IN (advance): pick a LOT checked into the line to START machining.
       Records ONE MachiningIn checkpoint ProductionEvent against the SAME LOT and
       stops -- no new LOT, no consumption, no BOM rename, no close. The event
       satisfies the LOT's MachiningIn route step so the route-driven queue advances
       it to its next terminal. Returns {Status, Message, NewId (ProductionEventId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "recordPick lotId=%s lineLocationId=%s appUserId=%s terminalLocationId=%s"
        % (lotId, lineLocationId, appUserId, terminalLocationId))
    params = {"lotId": lotId, "lineLocationId": lineLocationId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("workorder/MachiningIn_RecordPick", params)


def mint(sourceLotId, operationTemplateId, pieceCount, producedItemId=None,
         appUserId=None, terminalLocationId=None, allowPartial=False):
    """Machining OUT (consume-mint, terminal-mint model). Mints a SubAssembly LOT by
       consuming castings across the FIFO queue (strict oldest-first) of the same part
       at sourceLotId's cell -- one machined LOT may draw from several castings, never
       driving any casting negative. sourceLotId is the FIFO handle (its cell + part).
       The produced part is derived from the BOM whose child = the casting AND is
       direct-eligible at the line; pass producedItemId to override when a line builds
       more than one. Flexible qty. Line-resident: the minted LOT is born at the
       source's location (no destination). On shortfall: allowPartial=False rejects
       with Available=max producible; allowPartial=True mints all available. Returns
       {Status, Message, NewId (the minted SubAssembly LotId), Available}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "mint sourceLotId=%s operationTemplateId=%s pieceCount=%s producedItemId=%s appUserId=%s allowPartial=%s"
        % (sourceLotId, operationTemplateId, pieceCount, producedItemId, appUserId, allowPartial))
    params = {"sourceLotId": sourceLotId, "operationTemplateId": operationTemplateId,
              "pieceCount": pieceCount, "producedItemId": producedItemId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId,
              "allowPartial": bool(allowPartial)}
    result = BlueRidge.Common.Db.execMutation("workorder/MachiningOut_Mint", params)
    # Auto-print the new sublot's LTT label so the basket is scannable downstream.
    # printLabel does NOT raise on a print failure -- it RETURNS {Status:0,...} for the
    # common shop-floor cases (no printer configured / dispatch failed). So check the
    # returned Status AND catch genuine exceptions; either way never lose the committed
    # mint -- log + warn the operator (basket is created but unlabeled), return the mint.
    if result and result.get("Status") and result.get("NewId"):
        try:
            printRes = BlueRidge.Lots.LotLabel.printLabel(
                {"lotId": result.get("NewId")}, appUserId, terminalLocationId)
        except Exception as e:
            printRes = {"Status": 0, "Message": "print raised: %s" % e}
        if not (printRes and printRes.get("Status")):
            BlueRidge.Common.Util.log(
                "MachiningOut sublot label print failed: %s" % (printRes or {}).get("Message"))
            BlueRidge.Common.Notify.toast(
                "Label not printed",
                "The machined LOT was created but its LTT label did not print. Reprint from the LOT.",
                "warning")
    return result
