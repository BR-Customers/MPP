# =============================================================================
# BlueRidge.Workorder.ScaleStation -- the By Weight scale station's reads and
# its running-part override.
#
# Spec: docs/superpowers/specs/2026-10-19-assembly-out-scale-station-design.md
#
# Thin wrappers only. Which part a scale closes, which parts may run, and what
# a press log row means are all decided in SQL (Workorder.ScaleStation_* and
# Workorder.ufn_ScaleStationEligibleParts); nothing here re-derives them.
#
#   getRunningPartOrEmpty(terminalLocationId, _token)  -> dict, always full shape
#   listEligibleParts(terminalLocationId, _token)      -> list of dicts
#   setRunningPart(terminalLocationId, itemId, appUserId) -> {Status, Message}
#   getPressLog(terminalLocationId, top, _token)       -> list of dicts, newest first
#   getShiftTallyOrEmpty(terminalLocationId, _token)   -> dict, always full shape
#   getRecentBoxes(terminalLocationId, top, _token)    -> list of dicts
#
# _token is ignored: runScript bindings pass a bumped token to force a re-read.
#
# Change Log:
#   2026-10-19 - 1.0 - Initial version.
# =============================================================================

import java.lang


def _u(value):
    """Deep-unwrap shorthand for QualifiedValue / Java Map containers."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


# Every column Workorder.ScaleStation_GetRunningPart returns, so a binding
# that reads {view.custom.runningPart.X} never traverses a missing key.
_RUNNING_PART_SHAPE = {
    "ItemId": None, "PartNumber": "", "Description": "", "Source": "None",
    "PartsPerTray": 0, "TraysPerContainer": 0, "TargetWeight": None, "ToleranceWeight": None,
    "LowLimit": None, "HighLimit": None, "EligibleCount": 0, "Message": "",
    "OverrideItemId": None, "OverrideSetBy": "", "OverrideSetAtEt": None,
    "OpenContainerId": None, "OpenTraysClosed": 0, "OpenPartsClosed": 0,
}


def getRunningPartOrEmpty(terminalLocationId, _token=None):
    """The part the next press will close (Workorder.ScaleStation_GetRunningPart),
       as a dict carrying every key. Source 'None' and an explanatory Message
       when nothing can run; the full empty shape when there is no terminal."""
    out = dict(_RUNNING_PART_SHAPE)
    tid = _u(terminalLocationId)
    if tid is None:
        return out
    row = BlueRidge.Common.Db.execOne("workorder/ScaleStation_GetRunningPart",
                                      {"terminalLocationId": tid})
    if row:
        for k in out.keys():
            if row.get(k) is not None:
                out[k] = row.get(k)
    return out


def listEligibleParts(terminalLocationId, _token=None):
    """Every finished good this station may run now, closest to ready first
       (Workorder.ScaleStation_ListEligibleParts). [] when none."""
    tid = _u(terminalLocationId)
    if tid is None:
        return []
    return BlueRidge.Common.Db.execList("workorder/ScaleStation_ListEligibleParts",
                                        {"terminalLocationId": tid}) or []


def setRunningPart(terminalLocationId, itemId, appUserId=None):
    """Set (itemId) or clear (itemId None) the station's running-part override
       through Location.Terminal_SetScaleRunningPart, which refuses an
       ineligible part, another part's open box, and a no-op, and audits the
       change. appUserId is the caller's (a view passes
       BlueRidge.Common.Session.currentAppUserId(self.session)).
       Returns {Status, Message}."""
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation(
        "location/Terminal_SetScaleRunningPart",
        {"terminalLocationId": _u(terminalLocationId), "itemId": _u(itemId),
         "appUserId": appUserId})


def getPressLog(terminalLocationId, top=20, _token=None):
    """Every press at this station, newest first, refusals included
       (Workorder.ScaleStation_GetPressLog). Row 1 is the last-press card.
       [] when there is no terminal or no press."""
    tid = _u(terminalLocationId)
    if tid is None:
        return []
    return BlueRidge.Common.Db.execList("workorder/ScaleStation_GetPressLog",
                                        {"terminalLocationId": tid, "top": _u(top) or 20}) or []


_TALLY_SHAPE = {
    "ShiftName": "", "ShiftStartEt": None, "ShiftEndEt": None,
    "TraysClosed": 0, "PartsPacked": 0, "BoxesCompleted": 0,
    "Refused": 0, "RefusedUnder": 0, "RefusedOver": 0, "RefusedOther": 0,
}


def getShiftTallyOrEmpty(terminalLocationId, _token=None):
    """This shift at this scale (Workorder.ScaleStation_GetShiftTally), always
       carrying every key (zeros with no terminal or no covering shift)."""
    out = dict(_TALLY_SHAPE)
    tid = _u(terminalLocationId)
    if tid is None:
        return out
    row = BlueRidge.Common.Db.execOne("workorder/ScaleStation_GetShiftTally",
                                      {"terminalLocationId": tid})
    if row:
        for k in out.keys():
            if row.get(k) is not None:
                out[k] = row.get(k)
    return out


def getRecentBoxes(terminalLocationId, top=5, _token=None):
    """Completed boxes at this station, newest first, with label status
       (Workorder.ScaleStation_GetRecentBoxes). [] when none."""
    tid = _u(terminalLocationId)
    if tid is None:
        return []
    return BlueRidge.Common.Db.execList("workorder/ScaleStation_GetRecentBoxes",
                                        {"terminalLocationId": tid, "top": _u(top) or 5}) or []
