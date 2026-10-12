"""BlueRidge.Workorder.RejectEvent - thin access to the die-cast reject proc.
   Wrappers only; the decrement + close-at-zero (D3) and the over-quantity / TOCTOU
   guards live in Workorder.RejectEvent_Record."""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def record(data, appUserId=None, terminalLocationId=None, allowHeldLot=False):
    """Log a reject. data: {lotId, defectCodeId, quantity, chargeToArea,
       productionEventId, remarks, operationTypeCode}. The proc derives additive-vs-
       subtractive from Parts.OperationType.ScrapIsAdditive for operationTypeCode
       (0042): die-cast scrap is additive (LOT NOT decremented); downstream scrap
       decrements + closes-at-zero (D3). allowHeldLot=True permits scrap directly
       against a HELD LOT (FAT-QH-150: no split, no hold release; Hold status only,
       the LOT stays held). Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "record data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    params = {
        "lotId":              d.get("lotId"),
        "defectCodeId":       d.get("defectCodeId"),
        "quantity":           d.get("quantity"),
        "productionEventId":  d.get("productionEventId"),
        "chargeToArea":       d.get("chargeToArea"),
        "remarks":            d.get("remarks"),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "operationTypeCode":  d.get("operationTypeCode"),
        "allowHeldLot":       (1 if allowHeldLot else 0),
    }
    return BlueRidge.Common.Db.execMutation("workorder/RejectEvent_Record", params)


def recordByPartFifo(data, appUserId=None, terminalLocationId=None):
    """Scrap by PART at a line, consumed FIFO (Scrap Entry popup, Assembly +
       Machining terminals). data: {itemId, locationId, remarks,
       operationTypeCode} plus EITHER lines: [{defectCodeId, quantity}, ...]
       (the tile-entry popup: every reason tapped, one call, one transaction)
       OR a single defectCodeId + quantity. The proc charges the oldest LOT of
       the part first, spills into the next, writes one reject row per
       (LOT, reason) touched, stamps the terminal on each, and REFUSES
       (recording nothing) when the total exceeds what is on hand.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "recordByPartFifo data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    linesJson = None
    if d.get("lines") is not None:
        linesJson = system.util.jsonEncode(
            [{"defectCodeId": ln.get("defectCodeId"), "quantity": ln.get("quantity")}
             for ln in (d.get("lines") or [])])
    params = {
        "itemId":             d.get("itemId"),
        "locationId":         d.get("locationId"),
        "defectCodeId":       d.get("defectCodeId"),
        "quantity":           d.get("quantity"),
        "linesJson":          linesJson,
        "remarks":            d.get("remarks"),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "operationTypeCode":  d.get("operationTypeCode"),
    }
    return BlueRidge.Common.Db.execMutation("workorder/RejectEvent_RecordByPartFifo", params)


SCRAP_ENTRY_POPUP_ID = "mpp-scrap-entry"


def openScrapEntry(cellLocationId, operationTypeCode, replyMessage="inventoryChanged"):
    """Open the Scrap Entry popup (Popups/ScrapEntry) for a line. ONE opener for
       every terminal's Scrap button so the popup's placement lives in one place:
       pinned to the top half of the screen, full width, so nothing an operator
       needs sits under an on-screen keyboard. replyMessage is the page message
       sent after a successful record (the host refreshes its inventory on it)."""
    system.perspective.openPopup(
        SCRAP_ENTRY_POPUP_ID,
        "BlueRidge/Components/Popups/ScrapEntry",
        params={"cellLocationId": _u(cellLocationId), "operationTypeCode": operationTypeCode,
                "popupId": SCRAP_ENTRY_POPUP_ID, "replyMessage": replyMessage},
        position={"left": 0, "top": 0, "width": "100%", "height": "50%"},
        modal=True, showCloseIcon=False, draggable=False, resizable=False, overlayDismiss=False)


def submitScrapEntry(data, appUserId=None, terminalLocationId=None):
    """The Scrap Entry popup's Record Scrap button. data: {itemId, locationId,
       lines: [{defectCodeId, quantity}], remarks, operationTypeCode}.

       Reads the part's scrappable stock fresh first: the popup caps the entry
       against the count it loaded, and line inventory can move while the
       operator is tapping. The proc is still the guard (SHORT = REFUSE); this
       only turns that refusal into a plain message before the call.

       Toasts the outcome itself. Returns {"ok": bool, "available": int} -- the
       caller closes on ok, and otherwise shows the fresh on-hand number."""
    d = _u(data) or {}
    itemId = d.get("itemId")
    locationId = d.get("locationId")
    lines = BlueRidge.Quality.DefectCode.applyScrapChange(d.get("lines"), None)["lines"]
    total = sum(ln["quantity"] for ln in lines)
    stock = {"available": 0, "partNumber": ""}
    if itemId is not None:
        stock = BlueRidge.Lots.Lot.getScrappableStock(locationId, itemId)
    available = stock.get("available") or 0
    if itemId is None or total <= 0:
        BlueRidge.Common.Notify.toast("Nothing to record", "Pick a part and tap at least one reason.", "warning")
        return {"ok": False, "available": available}
    if total > available:
        BlueRidge.Common.Notify.toast(
            "Inventory changed",
            "Only %d of %s on hand at this line now. Adjust the entry and try again."
            % (available, stock.get("partNumber") or "this part"), "warning")
        return {"ok": False, "available": available}
    remarks = d.get("remarks")
    if remarks is not None and unicode(remarks).strip() == "":
        remarks = None
    result = recordByPartFifo(
        {"itemId": itemId, "locationId": locationId, "lines": lines, "remarks": remarks,
         "operationTypeCode": d.get("operationTypeCode")},
        appUserId, terminalLocationId)
    BlueRidge.Common.Ui.notifyResult(result, successTitle="Scrap recorded")
    if result and result.get("Status"):
        return {"ok": True, "available": available - total}
    fresh = BlueRidge.Lots.Lot.getScrappableStock(locationId, itemId)
    return {"ok": False, "available": fresh.get("available") or 0}
