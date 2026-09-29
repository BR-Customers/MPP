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
    """Single global row:
    {OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, ElevationMaxSeconds, ...}.

    ElevationTimeoutSeconds is the ROLLING elevation window that activity pushes
    forward; ElevationMaxSeconds is the absolute ceiling it can never pass.

    Returns a shaped fallback (1800 / 300 / 1800 s) if the row is missing so callers
    never see None. The fallback ceiling equals the table default -- NOT the rolling
    timeout -- so a read failure degrades to the configured behaviour rather than
    silently reverting elevation to a fixed 5-minute window."""
    try:
        row = BlueRidge.Common.Db.execOne("location/SessionPolicy_Get", {})
        if row:
            return row
    except Exception as e:
        BlueRidge.Common.Util.log("getPolicy failed: %s" % str(e), level="warn")
    return {"OperatorPresenceTimeoutSeconds": 1800,
            "ElevationTimeoutSeconds": 300,
            "ElevationMaxSeconds": 1800}


def updatePolicy(data, appUserId=None):
    """data: {operatorPresenceTimeoutSeconds, elevationTimeoutSeconds,
    elevationMaxSeconds}. Returns {Status, Message}.

    appUserId SHOULD be supplied explicitly by the (AD-authenticated) config-app caller
    -- pass self.session.custom.appUserId. Falls back to the shared resolver only when
    omitted.

    OMITTING elevationMaxSeconds means "leave it as it is", NOT "use a default".
    The value is read back from the stored row and passed through unchanged. This
    is what lets the Configuration Tool's existing Session-timeouts panel -- which
    sends only the two timeouts -- keep working before it learns about the ceiling;
    without it every save there would hit the proc's required-parameter guard and
    report "Not saved".

    The distinction matters and is deliberate: a caller that omits the key gets the
    value already in force, never a widened one. The PROC stays strict (all three
    required, NULL refused) so nothing else in the system can write a policy row
    without stating the ceiling."""
    d = BlueRidge.Common.Util.extractQualifiedValues(data) or {}
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)

    elevationMax = BlueRidge.Common.Util.toIntOrNone(d.get("elevationMaxSeconds"))
    if elevationMax is None:
        elevationMax = BlueRidge.Common.Util.toIntOrNone((getPolicy() or {}).get("ElevationMaxSeconds"))

    return BlueRidge.Common.Db.execMutation(
        "location/SessionPolicy_Update",
        {
            "operatorPresenceTimeoutSeconds": BlueRidge.Common.Util.toIntOrNone(d.get("operatorPresenceTimeoutSeconds")),
            "elevationTimeoutSeconds":        BlueRidge.Common.Util.toIntOrNone(d.get("elevationTimeoutSeconds")),
            "elevationMaxSeconds":            elevationMax,
            "appUserId":                      appUserId,
        },
    )
