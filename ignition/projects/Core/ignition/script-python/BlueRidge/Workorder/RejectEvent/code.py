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
       Machining terminals). data: {itemId, locationId, defectCodeId, quantity,
       remarks, operationTypeCode}. The proc charges the oldest LOT of the part
       first, spills into the next, writes one reject row per LOT touched, and
       REFUSES (recording nothing) when quantity exceeds what is on hand.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "recordByPartFifo data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    params = {
        "itemId":             d.get("itemId"),
        "locationId":         d.get("locationId"),
        "defectCodeId":       d.get("defectCodeId"),
        "quantity":           d.get("quantity"),
        "remarks":            d.get("remarks"),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "operationTypeCode":  d.get("operationTypeCode"),
    }
    return BlueRidge.Common.Db.execMutation("workorder/RejectEvent_RecordByPartFifo", params)
