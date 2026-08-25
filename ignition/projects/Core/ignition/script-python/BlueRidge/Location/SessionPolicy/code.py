# =============================================================================
# Project Library:  BlueRidge.Location.SessionPolicy
#
# Global plant-floor session-timeout policy accessors (single global row):
#   operator-presence idle timeout + elevation idle timeout, in seconds.
#
# Public surface:
#   getPolicy()                    -> dict  (shaped fallback if the row is missing)
#   updatePolicy(data, appUserId)  -> {Status, Message}
#
# Layer: View -> this module -> BlueRidge.Common.Db.* -> system.db.*
# =============================================================================


def getPolicy():
    """Single global row: {OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, ...}.
    Returns a shaped fallback (1800/300 s = 30 min / 5 min) if the row is missing so
    callers never see None."""
    try:
        row = BlueRidge.Common.Db.execOne("location/SessionPolicy_Get", {})
        if row:
            return row
    except Exception as e:
        BlueRidge.Common.Util.log("getPolicy failed: %s" % str(e))
    return {"OperatorPresenceTimeoutSeconds": 1800, "ElevationTimeoutSeconds": 300}


def updatePolicy(data, appUserId=None):
    """data: {operatorPresenceTimeoutSeconds, elevationTimeoutSeconds}. Returns {Status, Message}.

    appUserId SHOULD be supplied explicitly by the (AD-authenticated) config-app caller
    -- pass self.session.custom.appUserId. Falls back to the shared resolver only when
    omitted."""
    d = BlueRidge.Common.Util.extractQualifiedValues(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "location/SessionPolicy_Update",
        {
            "operatorPresenceTimeoutSeconds": BlueRidge.Common.Util.toIntOrNone(d.get("operatorPresenceTimeoutSeconds")),
            "elevationTimeoutSeconds":        BlueRidge.Common.Util.toIntOrNone(d.get("elevationTimeoutSeconds")),
            "appUserId":                      appUserId,
        },
    )
