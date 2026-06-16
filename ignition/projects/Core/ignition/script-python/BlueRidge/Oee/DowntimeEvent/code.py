"""BlueRidge.Oee.DowntimeEvent - downtime lifecycle + end-of-shift entry + shift-end summary (Arc 2 Phase 8)."""
import BlueRidge.Common.Db
import BlueRidge.Common.Util


def start(locationId, downtimeSourceCodeId=None, downtimeReasonCodeId=None, shotCount=None, appUserId=None, terminalLocationId=None):
    """Open a downtime event at a machine/Cell. downtimeSourceCodeId None => 'Operator'
    (manual entry); the PLC watcher passes its 'PLC' code explicitly. Returns {Status, Message, NewId}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"locationId": locationId, "downtimeReasonCodeId": downtimeReasonCodeId,
              "downtimeSourceCodeId": downtimeSourceCodeId, "shotCount": shotCount,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_Start", params)


def end(downtimeEventId, remarks=None, appUserId=None, terminalLocationId=None):
    """Close an open downtime event. Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"downtimeEventId": downtimeEventId, "remarks": remarks,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/DowntimeEvent_End", params)


def assignReason(downtimeEventId, downtimeReasonCodeId, appUserId=None, terminalLocationId=None):
    """Late-bind a reason to an open event (B7 - refuses overwrite). Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"downtimeEventId": downtimeEventId, "downtimeReasonCodeId": downtimeReasonCodeId,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Assign", params)


def getOpenByLocation(locationId):
    """Open downtime events at a Location, oldest-first (StartedAt in ET). list[dict]."""
    return BlueRidge.Common.Db.execList("oee/DowntimeEvent_GetOpenByLocation", {"locationId": locationId})


def submitEndOfShift(shiftId, cellLocationId, breaksSelectedJson, appUserId=None, terminalLocationId=None):
    """End-of-shift time entry (FDS-09-013). breaksSelectedJson is a JSON array of
    DowntimeReasonCode ids, e.g. '[3,4]'. Returns {Status, Message, EventCountInserted}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {"shiftId": shiftId, "cellLocationId": cellLocationId,
              "breaksSelectedJson": breaksSelectedJson, "appUserId": appUserId,
              "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("oee/EndOfShiftEntry_Submit", params)


def getEndOfShiftSummary(cellLocationId):
    """Three read lists for the Shift-end Summary view (FDS-09-015): open downtime,
    open LOT pauses, and in-process LOTs at the operator's Cell."""
    return {
        "openDowntime":  BlueRidge.Common.Db.execList("oee/DowntimeEvent_GetOpenByLocation", {"locationId": cellLocationId}),
        "openPauses":    BlueRidge.Common.Db.execList("lots/LotPause_GetByLocation", {"locationId": cellLocationId}),
        "inProcessLots": BlueRidge.Common.Db.execList("oee/Lot_GetInProcessByLocation", {"locationId": cellLocationId}),
    }
