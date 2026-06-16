"""BlueRidge.Lots.Lot - thin access to LOT create / read / status / move procs.

   Wrappers only; no business logic. Mutation attribution defaults appUserId to
   the session-resolved current user when the caller passes None; the plant
   floor passes appUserId / terminalLocationId explicitly."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def create(data, appUserId=None, terminalLocationId=None, lotName=None, cavityNote=None):
    """Mint a new LOT. data carries every Lot_Create field (itemId,
       lotOriginTypeId, currentLocationId, pieceCount, weight, weightUomId,
       toolId, toolCavityId, vendorLotNumber, minSerialNumber, maxSerialNumber).
       lotName (D4): None = server mint (default); a value = use it verbatim (the
       pre-printed LTT). cavityNote (D2): free-text cavity when no active ToolCavity.
       Returns {Status, Message, NewId, MintedLotName}."""
    BlueRidge.Common.Util.log(
        "create data=%s appUserId=%s terminalLocationId=%s lotName=%s cavityNote=%s"
        % (data, appUserId, terminalLocationId, lotName, cavityNote)
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
        "lotName":            _u(lotName),
        "cavityNote":         _u(cavityNote),
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_Create", params)


def getOriginTypeIdByCode(code):
    """Resolve a Lots.LotOriginType Id by Code (e.g. 'Manufactured', 'Received'), or
    None. Used by the die-cast entry screen to stamp the LOT origin. Wraps the
    existing lots/LotOriginType_List read."""
    try:
        rows = BlueRidge.Common.Db.execList("lots/LotOriginType_List", {}) or []
    except Exception as e:
        BlueRidge.Common.Util.log("getOriginTypeIdByCode failed: %s" % str(e))
        return None
    for r in rows:
        if r.get("Code") == code:
            return r.get("Id")
    return None


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


def getParents(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetParents", {"lotId": lotId})


def getChildren(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetChildren", {"lotId": lotId})


def getHistory(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/Lot_GetAttributeHistory", {"lotId": lotId})


def getPauses(lotId):
    BlueRidge.Common.Util.log("lotId=%s" % lotId)
    return BlueRidge.Common.Db.execList("lots/LotPause_GetByLot", {"lotId": lotId})


def getGenealogyTree(lotId, direction="Both"):
    BlueRidge.Common.Util.log("lotId=%s direction=%s" % (lotId, direction))
    return BlueRidge.Common.Db.execList("lots/Lot_GetGenealogyTree", {"lotId": lotId, "direction": direction})


def search(query=None, lotStatusId=None, lotOriginTypeId=None, limitRows=100):
    BlueRidge.Common.Util.log("query=%s statusId=%s originId=%s limit=%s" % (query, lotStatusId, lotOriginTypeId, limitRows))
    params = {"query": query, "lotStatusId": lotStatusId, "lotOriginTypeId": lotOriginTypeId, "limitRows": limitRows}
    return BlueRidge.Common.Db.execList("lots/Lot_Search", params)


def moveToValidated(lotId, toLocationId, appUserId=None, terminalLocationId=None):
    """Arc 2 Phase 4. Server-authoritative validated inbound move (the Movement
       Scan commit). The proc re-checks eligibility (FDS-02-012) + MaxParts (OI-12)
       + not-blocked (B2) and performs the move atomically. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "lotId=%s toLocationId=%s appUserId=%s terminalLocationId=%s"
        % (lotId, toLocationId, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              _u(lotId),
        "toLocationId":       _u(toLocationId),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_MoveToValidated", params)


def getCellLineQuantity(locationId, itemId):
    """Arc 2 Phase 4. Sum of open-LOT PieceCount for an Item at a location.
       Returns {ExistingPieceCount} or None."""
    BlueRidge.Common.Util.log("locationId=%s itemId=%s" % (locationId, itemId))
    return BlueRidge.Common.Db.execOne(
        "lots/Lot_GetCellLineQuantity",
        {"locationId": _u(locationId), "itemId": _u(itemId)},
    )


def getWipQueueByLocation(locationId, includeDescendants=False):
    """Arc 2 Phase 4 / Phase 5. The FIFO WIP queue at a location (open LOTs in
       arrival order). Returns list[dict]."""
    BlueRidge.Common.Util.log("locationId=%s includeDescendants=%s" % (locationId, includeDescendants))
    return BlueRidge.Common.Db.execList(
        "lots/Lot_GetWipQueueByLocation",
        {"locationId": _u(locationId), "includeDescendants": bool(includeDescendants)},
    )


def getByName(lotName):
    """Convenience alias: fetch one LOT by its LTT name. Returns a dict or None."""
    return get(lotName=_u(lotName))


def getStatusOptions():
    return [{"label": r["Name"], "value": r["Id"]} for r in BlueRidge.Common.Db.execList("lots/LotStatusCode_List")]


def getOriginOptions():
    return [{"label": r["Name"], "value": r["Id"]} for r in BlueRidge.Common.Db.execList("lots/LotOriginType_List")]
