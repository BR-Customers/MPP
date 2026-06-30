"""BlueRidge.Lots.SortCage - thin access to the Phase 7 Sort Cage proc.

   Wrappers only; no business logic. Arc 2 Phase 7 (Sort Cage re-containerize,
   UJ-05). migrateSerial routes through BlueRidge.Common.Db.execMutation (status-row
   proc). appUserId defaults to the current operator via
   BlueRidge.Common.Util._currentAppUserId() when None. Logs at default INFO."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


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
