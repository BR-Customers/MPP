"""BlueRidge.Audit.Partition - thin access to the sliding-window partition
   maintenance proc. Wrappers only; no business logic. appUserId is the caller's;
   the gateway timer passes Common.Util.systemAppUserId() (SYS)."""


def maintain(asOfUtc, retentionMonths=None, appUserId=None, terminalLocationId=None):
    """Roll the monthly partition window forward as of the given UTC moment.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "asOfUtc=%s retentionMonths=%s appUserId=%s terminalLocationId=%s"
        % (asOfUtc, retentionMonths, appUserId, terminalLocationId)
    )
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    params = {
        "asOfUtc":            asOfUtc,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "retentionMonths":    retentionMonths,
    }
    return BlueRidge.Common.Db.execMutation("audit/Partition_MaintainWindow", params)
