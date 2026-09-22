"""BlueRidge.Workorder.TrimPartial - thin access to the trim partial checkpoint.

   Wrappers only; every rule lives in Workorder.TrimPartial_Record.
   Spec docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md."""


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def record(data, appUserId=None, terminalLocationId=None):
    """Partial trim at shift end: one cumulative checkpoint on the LOT, which
       stays where it is. data carries lotId, operationTemplateId (the route's
       TrimIn template), shotCount (TOTAL trimmed so far on the LOT), scrapLines
       (list of {defectCodeId, quantity}), shiftId (picked by the operator --
       never defaulted), sourceLocationId (the terminal's trim zone).
       Returns {Status, Message, NewId} (NewId = ProductionEventId)."""
    BlueRidge.Common.Util.log(
        "record data=%s appUserId=%s terminalLocationId=%s"
        % (data, appUserId, terminalLocationId)
    )
    d = _u(data) or {}
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    params = {
        "lotId":               d.get("lotId"),
        "operationTemplateId": d.get("operationTemplateId"),
        "shotCount":           d.get("shotCount"),
        "scrapLinesJson":      BlueRidge.Common.Util.convertWrapperObjectToJson(d.get("scrapLines") or []),
        "shiftId":             d.get("shiftId"),
        "sourceLocationId":    d.get("sourceLocationId"),
        "appUserId":           appUserId,
        "terminalLocationId":  terminalLocationId,
    }
    return BlueRidge.Common.Db.execMutation("workorder/TrimPartial_Record", params)


def getLatestCheckpoint(lotId, _refreshToken=None):
    """The LOT's newest trim checkpoint as a dict, or None when there is none."""
    lotId = _u(lotId)
    if lotId in (None, ""):
        return None
    return BlueRidge.Common.Db.execOne("workorder/TrimCheckpoint_GetLatestForLot", {"lotId": lotId})


def latestCheckpointLabel(lotId, _refreshToken=None):
    """Binding source: 'Already recorded: 700 trimmed (2nd Shift - 09/21, JP)',
       or '' when the LOT has no trim count yet. Always a string."""
    r = getLatestCheckpoint(lotId)
    if not r or r.get("ShotCount") is None:
        return ""
    who = r.get("Initials") or "?"
    shift = r.get("ShiftLabel") or ""
    tail = ("%s, %s" % (shift, who)) if shift else who
    return "Already recorded: %s trimmed (%s)" % (r.get("ShotCount"), tail)
