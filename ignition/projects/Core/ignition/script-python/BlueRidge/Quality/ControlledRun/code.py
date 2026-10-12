"""BlueRidge.Quality.ControlledRun - super-lots (Quality.ControlledRun).

   A super-lot is a stored list of LOTs and containers placed on a Controlled
   Run Tag for one reason. THIN WRAPPERS ONLY: eligibility, folding a tray LOT
   to its container, the rolling window, the close rules and the label render
   all live in the Quality.ControlledRun_* procs.

   Elevation (FDS-04-007) is the calling view's concern; every mutation takes
   the already-resolved appUserId as attribution and never defaults it.

   Times: the procs take WALL-CLOCK EASTERN strings for the selection window
   and convert in SQL. _toEastern formats whatever the view hands over (a
   date-time input yields a java.util.Date, an absolute instant) as Eastern
   wall-clock text, so the gateway's own timezone never leaks into the window.

   Spec: docs/superpowers/specs/2026-10-12-controlled-run-super-lot-design.md

   Public surface:
     listRuns(statusCode, text, _refreshToken=None)        -> list[dict]
     getRun(runId, _refreshToken=None)                     -> dict | None
     getRunOrEmpty(runId, _refreshToken=None)              -> dict (always shaped)
     listMembers(runId, _refreshToken=None)                -> list[dict]
     findByScan(text)                                      -> {runId, message}
     preview(criteria)                                     -> list[dict]
     open(criteria, memberRows, appUserId, terminalLocationId)
     addByScan(runId, text, appUserId, terminalLocationId)
     removeMember(memberId, remarks, appUserId, terminalLocationId)
     setAutoJoin(runId, enabled, appUserId, terminalLocationId)
     close(runId, remarks, appUserId, terminalLocationId)
     cancel(runId, remarks, appUserId, terminalLocationId)
     sync(runId, appUserId) / syncTick()
     printLabels(runId, appUserId, terminalLocationId)"""

_EMPTY_RUN = {
    "Id": None, "RunNumber": "", "StatusCode": "", "Reason": "",
    "AnchorLotId": None, "AnchorLotName": "", "SelectionItemId": None, "PartNumber": "",
    "SelectionLocationId": None, "LocationName": "", "SelectionFromAt": None, "SelectionToAt": None,
    "IncludeDescendants": False, "AutoJoinEnabled": False, "AutoJoinEndedAt": None,
    "OpenedByInitials": "", "OpenedAt": None, "ClosedByInitials": "", "ClosedAt": None,
    "CloseRemarks": "", "MemberCount": 0, "ClearedCount": 0, "PieceCount": 0, "CriteriaText": "",
}


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _toEastern(value):
    """A date/time from a view -> 'yyyy-MM-dd HH:mm:ss' Eastern wall-clock text,
       or None. A string is passed through untouched (already wall-clock)."""
    v = _u(value)
    if v is None or v == "":
        return None
    if isinstance(v, basestring):
        return v
    from java.text import SimpleDateFormat
    from java.util import TimeZone
    fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss")
    fmt.setTimeZone(TimeZone.getTimeZone("America/New_York"))
    return fmt.format(v)


def listRuns(statusCode, text, _refreshToken=None):
    """Super-lots for the left-hand list. statusCode 'Open' | 'Closed' |
       'Cancelled' | 'All'. _refreshToken is ignored (runScript re-read arg)."""
    return BlueRidge.Common.Db.execList(
        "quality/ControlledRun_List",
        {"statusCode": _u(statusCode) or "Open", "text": (_u(text) or None)}) or []


def getRun(runId, _refreshToken=None):
    """One super-lot header, or None."""
    runId = _u(runId)
    if not runId:
        return None
    return BlueRidge.Common.Db.execOne("quality/ControlledRun_Get", {"id": runId})


def getRunOrEmpty(runId, _refreshToken=None):
    """Binding-only twin of getRun: always the full shape, never None, so a
       binding that traverses view.custom.run.<field> stays Quality-Good."""
    out = dict(_EMPTY_RUN)
    row = getRun(runId)
    if row:
        out.update(row)
    return out


def listMembers(runId, _refreshToken=None):
    """Current members of a super-lot, in the order they joined."""
    runId = _u(runId)
    if not runId:
        return []
    return BlueRidge.Common.Db.execList(
        "quality/ControlledRun_ListMembers", {"id": runId, "includeEnded": 0}) or []


def _resolveScan(text):
    """A scan is a super-lot label, an LTT, or a container id. Returns
       {"kind": 'run'|'lot'|'container'|None, "id": int|None}. Resolve BY TYPE,
       never int() first: an LTT and a container id can both look numeric."""
    t = (_u(text) or "").strip()
    if not t:
        return {"kind": None, "id": None}
    run = BlueRidge.Common.Db.execOne("quality/ControlledRun_GetByNumber", {"runNumber": t})
    if run:
        return {"kind": "run", "id": run.get("Id")}
    lot = BlueRidge.Lots.Lot.getByName(t)
    if lot and lot.get("Id"):
        return {"kind": "lot", "id": lot.get("Id")}
    cid = BlueRidge.Common.Util.toIntOrNone(t)
    if cid is not None:
        return {"kind": "container", "id": cid}
    return {"kind": None, "id": None}


def findByScan(text):
    """Which super-lot does this scan belong to? {"runId", "message"}."""
    hit = _resolveScan(text)
    if hit["kind"] == "run":
        return {"runId": hit["id"], "message": ""}
    if hit["kind"] in ("lot", "container"):
        row = BlueRidge.Common.Db.execOne("quality/ControlledRun_GetOpenByMember", {
            "lotId":       hit["id"] if hit["kind"] == "lot" else None,
            "containerId": hit["id"] if hit["kind"] == "container" else None})
        if row:
            return {"runId": row.get("Id"), "message": ""}
        return {"runId": None, "message": "That is not in an open super-lot."}
    return {"runId": None, "message": "Scan not recognised."}


def preview(criteria):
    """Candidate list for a selection; nothing is written. criteria keys:
       anchorLotId, itemId, locationId, fromAtEastern, toAtEastern,
       includeDescendants."""
    c = _u(criteria) or {}
    return BlueRidge.Common.Db.execList("quality/ControlledRun_PreviewSelection", {
        "anchorLotId":        c.get("anchorLotId"),
        "itemId":             c.get("itemId"),
        "locationId":         c.get("locationId"),
        "fromAtEastern":      _toEastern(c.get("fromAtEastern")),
        "toAtEastern":        _toEastern(c.get("toAtEastern")),
        "includeDescendants": 1 if c.get("includeDescendants") else 0,
    }) or []


def _membersJson(rows):
    """Preview/selection rows -> the [{lotId}|{containerId}] the procs take."""
    out = []
    for r in (_u(rows) or []):
        if r.get("ContainerId"):
            out.append({"containerId": r.get("ContainerId")})
        elif r.get("LotId"):
            out.append({"lotId": r.get("LotId")})
    return system.util.jsonEncode(out)


def open(criteria, memberRows, appUserId, terminalLocationId):
    """Open a super-lot. criteria as preview() plus reason, autoJoinEnabled.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("open criteria=%s members=%s" % (criteria, len(_u(memberRows) or [])))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    c = _u(criteria) or {}
    return BlueRidge.Common.Db.execMutation("quality/ControlledRun_Open", {
        "reason":                 c.get("reason"),
        "anchorLotId":            c.get("anchorLotId"),
        "selectionItemId":        c.get("itemId"),
        "selectionLocationId":    c.get("locationId"),
        "selectionFromAtEastern": _toEastern(c.get("fromAtEastern")),
        "selectionToAtEastern":   _toEastern(c.get("toAtEastern")),
        "includeDescendants":     1 if c.get("includeDescendants") else 0,
        "autoJoinEnabled":        1 if c.get("autoJoinEnabled") else 0,
        "membersJson":            _membersJson(memberRows),
        "appUserId":              appUserId,
        "terminalLocationId":     _u(terminalLocationId),
    })


def addByScan(runId, text, appUserId, terminalLocationId):
    """Add the scanned LOT or container to an open super-lot."""
    BlueRidge.Common.Util.log("addByScan runId=%s text=%s" % (runId, text))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    hit = _resolveScan(text)
    if hit["kind"] == "lot":
        members = [{"lotId": hit["id"]}]
    elif hit["kind"] == "container":
        members = [{"containerId": hit["id"]}]
    else:
        return {"Status": 0, "Message": "Scan a LOT ticket or a container label."}
    return BlueRidge.Common.Db.execMutation("quality/ControlledRun_AddMembers", {
        "id": _u(runId), "membersJson": system.util.jsonEncode(members),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def removeMember(memberId, remarks, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("removeMember memberId=%s" % memberId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("quality/ControlledRun_RemoveMember", {
        "memberId": _u(memberId), "remarks": _u(remarks),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def setAutoJoin(runId, enabled, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("setAutoJoin runId=%s enabled=%s" % (runId, enabled))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("quality/ControlledRun_SetAutoJoin", {
        "id": _u(runId), "enabled": 1 if _u(enabled) else 0,
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def close(runId, remarks, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("close runId=%s" % runId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("quality/ControlledRun_Close", {
        "id": _u(runId), "remarks": _u(remarks),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def cancel(runId, remarks, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("cancel runId=%s" % runId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("quality/ControlledRun_Cancel", {
        "id": _u(runId), "remarks": _u(remarks),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def sync(runId, appUserId):
    """Record membership for anything already tagged for this super-lot."""
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation(
        "quality/ControlledRun_SyncAutoJoin", {"id": _u(runId), "appUserId": appUserId})


def syncTick():
    """Gateway timer entry: sweep every open super-lot. The whole tick is
       guarded - a timer must never throw. The CRT BLOCK does not depend on
       this; only how soon a new LOT appears in the member list."""
    from java.lang import Throwable
    try:
        return BlueRidge.Common.Db.execMutation("quality/ControlledRun_SyncAutoJoin", {
            "id": None, "appUserId": BlueRidge.Common.Util.systemAppUserId()})
    except (Exception, Throwable) as e:
        BlueRidge.Common.Util.log("ControlledRun.syncTick failed: %s" % e, level="error")
        return {"Status": 0, "Message": "sync failed"}


def printLabels(runId, appUserId, terminalLocationId):
    """Render four super-lot labels and send them to this terminal's printer.
       Same transport as LTT labels (BlueRidge.Lots.LabelTransport - the one
       place ZPL leaves the gateway). A failed print never undoes anything:
       the request is logged and the operator presses Print again.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("printLabels runId=%s terminalLocationId=%s" % (runId, terminalLocationId))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    tid = _u(terminalLocationId)
    printer = (BlueRidge.Location.Terminal.getPrinter(tid) or {}) if tid is not None else {}
    res = BlueRidge.Common.Db.execMutation("quality/ControlledRunLabel_Print", {
        "id": _u(runId), "appUserId": appUserId, "terminalLocationId": tid,
        "printerName": printer.get("code") or None})
    if not res or not res.get("Status"):
        return res
    endpoint = (printer.get("endpoint") or "").strip()
    BlueRidge.Lots.LabelTransport.logResolve(endpoint, "terminal-printer", "SUPERLOT")
    if not endpoint:
        return {"Status": 0, "Message": "This terminal has no printer configured.",
                "NewId": res.get("NewId")}
    zpl = res.get("ZplContent") or ""
    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "SUPERLOT")
    if outcome.get("ok"):
        return {"Status": 1, "Message": "4 super-lot labels printed.", "NewId": res.get("NewId")}
    return {"Status": 0,
            "Message": "Print failed: %s. Press Print again to retry." % (outcome.get("error") or "unknown"),
            "NewId": res.get("NewId")}
