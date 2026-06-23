"""BlueRidge.Lots.AimPoolConfig - thin access to the Phase 7 AIM pool config procs.

   Wrappers only; no business logic. Arc 2 Phase 7 (AIM pool threshold admin;
   AD-elevated). get routes through BlueRidge.Common.Db.execList (single-row read);
   update routes through execMutation (status-row proc). appUserId defaults to the
   current operator via BlueRidge.Common.Util._currentAppUserId() when None. Logs at
   default INFO."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def get(_refreshToken=None):
    """Read the single-row AIM pool config (thresholds + last-updated attribution).
       Returns list[dict] (empty list = unconfigured)."""
    BlueRidge.Common.Util.log("get")
    return BlueRidge.Common.Db.execList("lots/AimPoolConfig_Get")


def update(targetBufferDepth, topupThreshold, alarmWarningDepth, alarmCriticalDepth, appUserId=None):
    """Update the AIM pool thresholds (upserts the single config row). Returns
       {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "update targetBufferDepth=%s topupThreshold=%s alarmWarningDepth=%s alarmCriticalDepth=%s appUserId=%s"
        % (targetBufferDepth, topupThreshold, alarmWarningDepth, alarmCriticalDepth, appUserId))
    params = {"targetBufferDepth": targetBufferDepth, "topupThreshold": topupThreshold,
              "alarmWarningDepth": alarmWarningDepth, "alarmCriticalDepth": alarmCriticalDepth,
              "appUserId": appUserId}
    return BlueRidge.Common.Db.execMutation("lots/AimPoolConfig_Update", params)
