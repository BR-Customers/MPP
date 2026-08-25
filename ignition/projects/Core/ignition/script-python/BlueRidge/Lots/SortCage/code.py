"""BlueRidge.Lots.SortCage - thin access to the Phase 7 Sort Cage proc.

   Wrappers only; no business logic. Arc 2 Phase 7 (Sort Cage re-containerize,
   UJ-05). migrateSerial routes through BlueRidge.Common.Db.execMutation (status-row
   proc); getContainerSerial/getSourceHold route through execList. appUserId
   defaults to the current operator via BlueRidge.Common.Util._currentAppUserId()
   when None. Logs at default INFO."""


def getContainerSerial(containerSerialId):
    """Read a ContainerSerial row (Id, ContainerId, ContainerTrayId, TrayPosition,
       SerializedPartId) by Id. Returns None when not found."""
    BlueRidge.Common.Util.log("getContainerSerial containerSerialId=%s" % containerSerialId)
    rows = BlueRidge.Common.Db.execList("lots/ContainerSerial_Get", {"id": containerSerialId})
    return rows[0] if rows else None


# Binding-safe empty shape for the Sort Cage "Source Container" KPI panel. Every
# key a view binding traverses must exist here, or the not-yet-scanned first paint
# renders the panel Quality-Bad.
_EMPTY_SOURCE = {
    "ContainerSerialId": None, "ContainerId": None, "ContainerTrayId": None,
    "TrayPosition": None, "SerialNumber": "", "ItemId": None, "PartNumber": "",
    "ItemDescription": "", "AimShipperId": "", "SerialCount": 0, "TrayCount": 0,
    "ContainerStatusCode": "", "CurrentLocationId": None, "CurrentLocationName": "",
    "OpenedAt": None, "CompletedAt": None, "HasSource": False,
}


def getSourceSummaryOrEmpty(containerSerialId, _refreshToken=None):
    """Source-container summary for the Sort Cage KPI panel: container, part,
       serial, AIM Shipper ID and the container's serial/tray counts.

       ALWAYS returns a fully-shaped dict, never None, so the panel's bindings can
       traverse {custom.source.PartNumber} before anything is scanned. Callers
       detect "nothing scanned yet" via HasSource, not isNull() on the object --
       the getHeaderOrEmpty convention.

       _refreshToken is accepted and ignored: runScript caches on its argument
       list, so a caller wanting a re-read passes a changing token as an ARG."""
    BlueRidge.Common.Util.log("getSourceSummaryOrEmpty containerSerialId=%s" % containerSerialId)
    csId = BlueRidge.Common.Util.toIntOrNone(containerSerialId)
    if csId is None:
        return dict(_EMPTY_SOURCE)
    try:
        rows = BlueRidge.Common.Db.execList(
            "lots/ContainerSerial_GetSourceSummary", {"containerSerialId": csId})
    except Exception, e:
        BlueRidge.Common.Util.log("getSourceSummaryOrEmpty failed: %s" % e, level="error")
        return dict(_EMPTY_SOURCE)
    if not rows:
        return dict(_EMPTY_SOURCE)
    out = dict(_EMPTY_SOURCE)
    out.update(rows[0])
    out["HasSource"] = True
    return out


def getSourceHold(containerSerialId):
    """HoldPill binding: the open-hold state (shaped IsHeld dict) of the Container
       the given ContainerSerialId currently sits in. Shaped-empty (not held) when
       the id is blank or not found -- keeps the bound custom prop safe per the
       pre-declared-props rule."""
    EMPTY = {"IsHeld": False, "Id": None, "HoldTypeCode": None, "Reason": None,
             "PlacedByInitials": None, "PlacedAt": None}
    containerSerialId = BlueRidge.Common.Util.toIntOrNone(containerSerialId)
    if containerSerialId is None:
        return EMPTY
    cs = getContainerSerial(containerSerialId)
    if cs is None:
        return EMPTY
    return BlueRidge.Quality.Hold.getOpenByContainerOne(cs.get("ContainerId"))


def migrateSerial(containerSerialId, newContainerId, newTrayPosition=None,
                  migrationReasonCode="SortCage", appUserId=None, terminalLocationId=None):
    """Re-containerize a serialized part at the Sort Cage -- writes a history row +
       updates ContainerSerial in place. Destination container must be Open.
       Returns {Status, Message, NewId (ContainerSerialHistoryId)}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "migrateSerial containerSerialId=%s newContainerId=%s newTrayPosition=%s reason=%s appUserId=%s"
        % (containerSerialId, newContainerId, newTrayPosition, migrationReasonCode, appUserId))
    params = {"containerSerialId": containerSerialId, "newContainerId": newContainerId,
              "newTrayPosition": newTrayPosition, "migrationReasonCode": migrationReasonCode,
              "appUserId": appUserId, "terminalLocationId": terminalLocationId}
    return BlueRidge.Common.Db.execMutation("lots/SortCage_MigrateSerial", params)
