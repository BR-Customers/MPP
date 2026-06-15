"""BlueRidge.Lots.Lot - thin access to LOT create / read / status / move procs.

   Wrappers only; no business logic. Mutation attribution defaults appUserId to
   the session-resolved current user when the caller passes None; the plant
   floor passes appUserId / terminalLocationId explicitly."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def create(data, appUserId=None, terminalLocationId=None):
    """Mint a new LOT. data carries every Lot_Create field (itemId,
       lotOriginTypeId, currentLocationId, pieceCount, weight, weightUomId,
       toolId, toolCavityId, vendorLotNumber, minSerialNumber, maxSerialNumber).
       Returns {Status, Message, NewId, MintedLotName}."""
    BlueRidge.Common.Util.log(
        "create data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
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
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_Create", params)


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
