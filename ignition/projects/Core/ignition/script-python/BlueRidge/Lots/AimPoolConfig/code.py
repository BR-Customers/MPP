"""BlueRidge.Lots.AimPoolConfig - thin access to the Phase 7 AIM pool config procs.

   Wrappers only; no business logic. Arc 2 Phase 7 (AIM pool threshold admin;
   AD-elevated). get routes through BlueRidge.Common.Db.execList (single-row read);
   update routes through execMutation (status-row proc). appUserId defaults to the
   current operator via BlueRidge.Common.Util._currentAppUserId() when None. Logs at
   default INFO."""


def get(_refreshToken=None):
    """Read the single-row AIM pool config (thresholds + last-updated attribution).
       Returns list[dict] (empty list = unconfigured)."""
    BlueRidge.Common.Util.log("get")
    return BlueRidge.Common.Db.execList("lots/AimPoolConfig_Get")


def update(targetBufferDepth, topupThreshold, alarmWarningDepth, alarmCriticalDepth,
           aimBaseUrl=None, aimCompanyCode=None, aimPathToken=None,
           postWarningAgeMinutes=None, postCriticalAgeMinutes=None,
           aimPostingEnabled=None, appUserId=None):
    """Update the AIM pool thresholds and (optionally) the AIM connection settings /
       post-backlog escalation ages / posting-enabled gate (upserts the single config
       row). Returns {Status, Message}.

       The six new params ALL default to None so existing four-argument callers
       (the pre-existing threshold-only save path) keep working unchanged. The
       proc's Lots.AimPoolConfig_Update COALESCEs each omitted param against the
       stored value (preserve-on-omit) -- passing None here never blanks a
       connection setting or flips the posting gate, it only leaves it untouched.
       Corollary: this wrapper has no way to CLEAR a connection setting to blank,
       or toggle aimPostingEnabled, without passing an explicit value.

       aimPostingEnabled is the transport-layer gate BlueRidge.Lots.AimHttp._config()
       reads before making any AIM network call (Migration 0050) -- it defaults to 0
       (off) in the database and must be explicitly flipped True here to arm real
       AIM traffic in an environment."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    BlueRidge.Common.Util.log(
        "update targetBufferDepth=%s topupThreshold=%s alarmWarningDepth=%s alarmCriticalDepth=%s "
        "aimBaseUrl=%s aimCompanyCode=%s aimPathToken=%s postWarningAgeMinutes=%s "
        "postCriticalAgeMinutes=%s aimPostingEnabled=%s appUserId=%s"
        % (targetBufferDepth, topupThreshold, alarmWarningDepth, alarmCriticalDepth,
           aimBaseUrl, aimCompanyCode, aimPathToken, postWarningAgeMinutes,
           postCriticalAgeMinutes, aimPostingEnabled, appUserId))
    params = {"targetBufferDepth": targetBufferDepth, "topupThreshold": topupThreshold,
              "alarmWarningDepth": alarmWarningDepth, "alarmCriticalDepth": alarmCriticalDepth,
              "aimBaseUrl": aimBaseUrl, "aimCompanyCode": aimCompanyCode,
              "aimPathToken": aimPathToken, "postWarningAgeMinutes": postWarningAgeMinutes,
              "postCriticalAgeMinutes": postCriticalAgeMinutes,
              "aimPostingEnabled": aimPostingEnabled, "appUserId": appUserId}
    return BlueRidge.Common.Db.execMutation("lots/AimPoolConfig_Update", params)
