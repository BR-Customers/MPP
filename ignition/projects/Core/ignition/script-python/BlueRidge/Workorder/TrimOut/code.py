"""BlueRidge.Workorder.TrimOut - thin access to the Trim OUT whole-LOT move proc.

   Wrappers only; no business logic. Arc 2 Phase 4 (FDS-06-006)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def record(data, appUserId=None, terminalLocationId=None):
    """Trim OUT: closing checkpoint + whole-LOT move into a Machining FIFO queue.
       data carries parentLotId, operationTemplateId, shotCount, scrapCount,
       destinationCellLocationId. Returns {Status, Message, NewId} (NewId =
       ProductionEventId)."""
    BlueRidge.Common.Util.log(
        "record data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "parentLotId":               d.get("parentLotId"),
        "operationTemplateId":       d.get("operationTemplateId"),
        "shotCount":                 d.get("shotCount"),
        "scrapCount":                d.get("scrapCount"),
        "destinationCellLocationId": d.get("destinationCellLocationId"),
        "appUserId":                 appUserId,
        "terminalLocationId":        terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/TrimOut_Record", params)
