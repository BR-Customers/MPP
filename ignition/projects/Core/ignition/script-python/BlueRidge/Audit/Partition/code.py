"""BlueRidge.Audit.Partition - thin access to the sliding-window partition
   maintenance proc. Wrappers only; no business logic. Defaults appUserId to the
   session-resolved current user when None; callers may pass it explicitly."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def maintain(asOfUtc, retentionMonths=None, appUserId=None, terminalLocationId=None):
    """Roll the monthly partition window forward as of the given UTC moment.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "asOfUtc=%s retentionMonths=%s appUserId=%s terminalLocationId=%s"
        % (asOfUtc, retentionMonths, appUserId, terminalLocationId)
    )
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    params = {
        "asOfUtc":            asOfUtc,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "retentionMonths":    retentionMonths,
    }
    return BlueRidge.Common.Db.execMutation("audit/Partition_MaintainWindow", params)
