"""BlueRidge.Workorder.RejectEvent - thin access to the die-cast reject proc.
   Wrappers only; the decrement + close-at-zero (D3) and the over-quantity / TOCTOU
   guards live in Workorder.RejectEvent_Record."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def record(data, appUserId=None, terminalLocationId=None):
    """Log a reject + decrement the LOT (D3). data: {lotId, defectCodeId, quantity,
       chargeToArea, productionEventId, remarks}. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log(
        "record data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              d.get("lotId"),
        "defectCodeId":       d.get("defectCodeId"),
        "quantity":           d.get("quantity"),
        "productionEventId":  d.get("productionEventId"),
        "chargeToArea":       d.get("chargeToArea"),
        "remarks":            d.get("remarks"),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/RejectEvent_Record", params)
