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
# Presentation helpers the scale station views bind to (display text and a
# style class per row -- no rules):
#   trayCells, lastPressOrEmpty, pressLogInstances, boxInstances,
#   eligiblePartOptions, scaleInstancePath
#
# _token is ignored: runScript bindings pass a bumped token to force a re-read.
#
# Change Log:
#   2026-10-19 - 1.0 - Initial version.
# =============================================================================

import java.lang
import system.date


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


# ---- presentation helpers (views) ------------------------------------------

_VERDICT_TEXT = {"Ok": "OK", "Under": "UNDER", "Over": "OVER"}
_VERDICT_CLASS = {"Ok": "pf-pill pf-pill-good", "Under": "pf-pill pf-pill-warn",
                  "Over": "pf-pill pf-pill-bad"}
_LABEL_TEXT = {"Sent": "Label sent", "Failed": "Label failed", "Reprinted": "Label reprinted"}


def _g(value):
    """A DB number as short text: 18.3100 -> '18.31'. '' for None."""
    if value is None:
        return ""
    return "%g" % float("%s" % value)


def _fmtTime(d):
    return system.date.format(d, "h:mm:ss a") if d is not None else ""


def _pressDisplay(row):
    verdict = row.get("Verdict")
    outcome = row.get("Outcome")
    if outcome == "Closed":
        text = "Tray %s of %s closed, LOT %s" % (row.get("TrayPosition"), row.get("TraysPerContainer"),
                                                 row.get("LotName"))
        if row.get("TrayPosition") is not None and row.get("TrayPosition") == row.get("TraysPerContainer"):
            text += ", box complete"
            if row.get("LabelStatus"):
                text += ", " + _LABEL_TEXT.get(row.get("LabelStatus"), row.get("LabelStatus")).lower()
    elif outcome == "Refused":
        text = "Not closed: %s" % (row.get("Detail") or "refused")
    else:
        text = "Close failed: %s" % (row.get("Detail") or "see the interface log")
    sv = row.get("ScaleVerdict")
    agree = row.get("FlagsAgree")
    if sv is None:
        scale = ""
    elif agree is None:
        scale = sv
    else:
        scale = "%s, %s" % (_VERDICT_TEXT.get(sv, sv), "agrees" if agree else "differs")
    net = _g(row.get("Net"))
    return {"time": _fmtTime(row.get("LoggedAtEt")),
            "net": ("%s %s" % (net, row.get("Uom") or "")).strip() if net else "-",
            "verdict": _VERDICT_TEXT.get(verdict, verdict or "-"),
            "verdictClass": _VERDICT_CLASS.get(verdict, "pf-pill"),
            "outcome": text, "scale": scale,
            "window": ("%s - %s lb" % (_g(row.get("Low")), _g(row.get("High"))))
                      if row.get("Low") is not None else ""}


def pressLogInstances(terminalLocationId, top=10, _token=None):
    """Flex-repeater instances for the press log: one display dict per press."""
    return [_pressDisplay(r) for r in getPressLog(terminalLocationId, top)]


_LAST_PRESS_EMPTY = {"hasPress": False, "time": "", "net": "-", "verdict": "-",
                     "verdictClass": "pf-pill", "outcome": "No presses yet.", "scale": "", "window": ""}


def lastPressOrEmpty(terminalLocationId, _token=None):
    """The last-press card: row 1 of the press log, always the full shape."""
    rows = getPressLog(terminalLocationId, 1)
    if not rows:
        return dict(_LAST_PRESS_EMPTY)
    out = _pressDisplay(rows[0])
    out["hasPress"] = True
    return out


def trayCells(terminalLocationId, _token=None):
    """One cell per tray of the running part's box: closed / next / todo."""
    rp = getRunningPartOrEmpty(terminalLocationId)
    total = int(rp.get("TraysPerContainer") or 0)
    closed = int(rp.get("OpenTraysClosed") or 0) if rp.get("OpenContainerId") is not None else 0
    return [{"n": i, "state": "closed" if i <= closed else ("next" if i == closed + 1 else "todo")}
            for i in range(1, total + 1)]


def boxInstances(terminalLocationId, top=5, _token=None):
    """Flex-repeater instances for recent boxes."""
    out = []
    for b in getRecentBoxes(terminalLocationId, top):
        out.append({"containerId": b.get("ContainerId"),
                    "title": "Box #%s - %s pcs, %s trays" % (b.get("ContainerId"), b.get("Pieces"), b.get("Trays")),
                    "sub": "LOT %s - AIM %s" % (b.get("LotName") or "-", b.get("AimShipperId") or "-"),
                    "labelStatus": _LABEL_TEXT.get(b.get("LabelStatus"), "No label"),
                    "labelClass": "pf-pill pf-pill-bad" if b.get("LabelStatus") == "Failed" else "pf-pill pf-pill-good"})
    return out


def eligiblePartOptions(terminalLocationId, _token=None):
    """Dropdown options for the part picker, closest to ready first."""
    return [{"label": "%s  %s  (parts for %s trays)" % (p.get("PartNumber"), p.get("Description"), p.get("TraysCovered")),
             "value": p.get("ItemId")}
            for p in listEligibleParts(terminalLocationId)]


def scaleInstancePath(terminalLocationId):
    """The terminal's EPrint scale tag instance path, or '' when none is mapped."""
    for d in BlueRidge.Location.TerminalPlcDevice.getByTerminal(_u(terminalLocationId)) or []:
        if d.get("DeviceTypeCode") == "ScaleStationEPrint":
            return d.get("UdtInstancePath") or ""
    return ""


def applyPartChoice(session, terminalLocationId, itemId):
    """The part picker's Run / Use default buttons: set or clear the override
       as the signed-in operator, toast the result, and on success tell the
       Assembly Out screen (page-scoped scaleRunningPartChanged) and close."""
    result = setRunningPart(terminalLocationId, itemId,
                            appUserId=BlueRidge.Common.Session.currentAppUserId(session))
    BlueRidge.Common.Ui.notifyResult(result, "Running part changed")
    if result and result.get("Status"):
        system.perspective.sendMessage("scaleRunningPartChanged",
                                       payload={"terminalLocationId": _u(terminalLocationId)}, scope="page")
        system.perspective.closePopup(id="mpp-scale-part-picker")
