"""BlueRidge.Quality.Crt - Controlled Run Tag surface (Arc 2 Phase 9,
   FDS-10-011/012). Wrappers only; the Closed-LOT guard, idempotence guards and
   the LotEventLog audit routing live in the procs. CRT enforcement is SURFACED,
   not proc-gated, in v1 - views render the 200% prompt off getRequiredInspections;
   production procs do not consume it.

   Clearance elevation (FDS-04-007) is the calling view's concern - the procs take
   appUserId as attribution only.

   Public surface:
     setCrt(lotId, appUserId=None, terminalLocationId=None)   -> {Status, Message}
     clearCrt(lotId, appUserId=None, terminalLocationId=None) -> {Status, Message}
     getRequiredInspections(locationId, _refreshToken=None)   -> list[dict]
     flagMissed(lotId, remarks, appUserId=None, terminalLocationId=None)"""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def setCrt(lotId, appUserId=None, terminalLocationId=None):
    """Activate the Controlled Run Tag on a LOT (CrtActive 0 -> 1).
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "setCrt lotId=%s appUserId=%s terminalLocationId=%s"
        % (lotId, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              _u(lotId),
        "appUserId":          appUserId,
        "terminalLocationId": _u(terminalLocationId),
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_SetCrt", params)


def clearCrt(lotId, appUserId=None, terminalLocationId=None):
    """Clear the Controlled Run Tag on a LOT (CrtActive 1 -> 0). Supervisor-elevated
       release per FDS-04-007 - elevation is the calling view's concern.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "clearCrt lotId=%s appUserId=%s terminalLocationId=%s"
        % (lotId, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              _u(lotId),
        "appUserId":          appUserId,
        "terminalLocationId": _u(terminalLocationId),
    }
    return BlueRidge.Common.Db.execMutation("lots/Lot_ClearCrt", params)


def getRequiredInspections(locationId, _refreshToken=None):
    """CRT-active, non-Closed LOTs at/under a location with their inspection tallies
       (SampleCount, LastSampledAt ET, LastResultCode) - the 200% inspection prompt
       read. Never-sampled LOTs sort first (most overdue). _refreshToken is ignored
       (runScript re-read arg). Returns list[dict]."""
    locationId = _u(locationId)
    BlueRidge.Common.Util.log("getRequiredInspections locationId=%s" % locationId)
    if not locationId:
        return []
    return BlueRidge.Common.Db.execList(
        "quality/Crt_GetRequiredInspections", {"locationId": locationId})


def flagMissed(lotId, remarks, appUserId=None, terminalLocationId=None):
    """Flag a MISSED required CRT (200%) inspection on a CRT-active LOT. Writes only
       the MissedCrtInspect audit row (Warning severity, 20-yr LotEventLog) - no
       table mutation. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "flagMissed lotId=%s remarks=%s appUserId=%s terminalLocationId=%s"
        % (lotId, remarks, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "lotId":              _u(lotId),
        "remarks":            _u(remarks),
        "appUserId":          appUserId,
        "terminalLocationId": _u(terminalLocationId),
    }
    return BlueRidge.Common.Db.execMutation("quality/Crt_FlagMissedInspection", params)
