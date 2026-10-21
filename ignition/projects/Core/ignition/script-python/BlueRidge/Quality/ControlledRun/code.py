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
     printLabels(runId, appUserId, terminalLocationId)

   Display shaping for the Quality view (no rules - rows SQL already judged):
     partOptions() / locationOptions()
     cardInstances(statusCode, text, selectedRunId, _refreshToken=None)
     memberInstances(runId, selectedMemberId, _refreshToken=None)
     previewEncode(rows) / previewInstances(rowsJson) / previewTotals(rowsJson)
     previewToggle(rowsJson, index) / previewSetAll(rowsJson, ticked)
     previewTicked(rowsJson)

   Pieces 2 + 3 (results, signed release, deviation) - see the section at the
   end of this module:
     listMemberResults / listResults / listDeviations / listSignatures
     recordResults / acceptRemaining / voidResult
     raiseDeviation / release (both take THE SIGNER, never the session user)
     resultItems (accordion) / resultLogInstances
     entryCatalog / entryModel / entryChange / entryAcceptRest / entryToResults
     releaseInstances / tickToggle / tickAllReady / tickSummary
     deviationInstances / signatureInstances

   Piece 5 (trim rework + return to vendor):
     memberRework(controlledRunId)   -> {str(memberId): {startedAt, approvedBy}}
     memberOrigin(controlledRunId)   -> {str(memberId): {origin, canReturn}}
     Rework is no longer a result entry (a supervisor override move back into
     trim starts it, the Trim OUT ends it); the Return to vendor tile is shown
     only where SQL says the member can be returned (CanReturnToVendor).

   Piece 6 (visibility - reads only; every label and state comes from SQL):
     listByLot(lotId) / listByLotInstances(lotId)   LOT Detail Super-lots tab
     openForLotOrEmpty(lotId)                       -> {Id, RunNumber} (Id None = none)
     markers(lotIdsCsv, containerIdsCsv)            -> genealogy marker rows
     historyInstances(runId)                        super-lot History tab
     openSummaryOrEmpty()                           dashboard tile
     getRunByNumber(runNumber)                      -> dict | None"""

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
    from java.util import TimeZone, Date
    if isinstance(v, (int, long, float)):
        v = Date(long(v))      # a date-time input can hand over epoch millis
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
       place ZPL leaves the gateway).

       The two things that make a print impossible - nobody signed in, no
       printer on this terminal - are checked BEFORE the proc runs, so a print
       that could never happen is not logged as a print request. A failed send
       never undoes anything: the request is logged and the operator presses
       Print again. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("printLabels runId=%s terminalLocationId=%s" % (runId, terminalLocationId))
    if not _u(appUserId):
        return {"Status": 0, "Message": "Sign in at this terminal before printing super-lot labels.", "NewId": None}
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    tid = _u(terminalLocationId)
    printer = (BlueRidge.Location.Terminal.getPrinter(tid) or {}) if tid is not None else {}
    endpoint = (printer.get("endpoint") or "").strip()
    BlueRidge.Lots.LabelTransport.logResolve(endpoint, "terminal-printer", "SUPERLOT")
    if not endpoint:
        return {"Status": 0, "Message": "This terminal has no printer configured.", "NewId": None}
    res = BlueRidge.Common.Db.execMutation("quality/ControlledRunLabel_Print", {
        "id": _u(runId), "appUserId": appUserId, "terminalLocationId": tid,
        "printerName": printer.get("code") or None})
    if not res or not res.get("Status"):
        return res
    zpl = res.get("ZplContent") or ""
    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "SUPERLOT")
    if outcome.get("ok"):
        return {"Status": 1, "Message": "4 super-lot labels printed.", "NewId": res.get("NewId")}
    return {"Status": 0,
            "Message": "Print failed: %s. Press Print again to retry." % (outcome.get("error") or "unknown"),
            "NewId": res.get("NewId")}


# =============================================================================
# Display shaping for the Quality view. Nothing below decides anything: every
# row was already resolved, folded and judged eligible in SQL. These only turn
# rows into flex-repeater instances and count what the operator has ticked.
#
# The wizard keeps its preview rows as a JSON STRING in a view custom property.
# A list of dicts held in view.custom and fed to a repeater transform renders
# nothing, and a list passed to runScript arrives as a QualifiedValue[] and
# throws - a scalar string avoids both.
# =============================================================================

_EMPTY_TOTALS = {"lots": 0, "containers": 0, "pieces": 0, "ineligible": 0, "ticked": 0}


def _fmt(value, pattern):
    """Format a timestamp the procs already returned in Eastern. '' for None."""
    v = _u(value)
    if v is None or v == "":
        return ""
    try:
        return system.date.format(v, pattern)
    except:
        return "%s" % v


def partOptions():
    """[{label, value}] of parts for the wizard's Part dropdown."""
    return [{"label": o.get("label"), "value": o.get("value")}
            for o in (BlueRidge.Parts.Item.getForDropdown() or [])]


def locationOptions():
    """[{label, value}] for 'Made at': production lines, then die cast presses.
       (A Cell-tier location is a terminal here, not a line - see
       Location.getProductionLinesForDropdown.)"""
    out, seen = [], set()
    lines = BlueRidge.Location.Location.getProductionLinesForDropdown() or []
    presses = BlueRidge.Location.Location.getDieCastPressDropdown() or []
    for o in list(lines) + list(presses):
        v = o.get("value")
        if v is None or v in seen:
            continue
        seen.add(v)
        out.append({"label": o.get("label"), "value": v})
    return out


def cardInstances(statusCode, text, selectedRunId, _refreshToken=None):
    """Flex-repeater instances for the left-hand super-lot list."""
    sel = _u(selectedRunId)
    out = []
    for r in listRuns(statusCode, text):
        members = int(r.get("MemberCount") or 0)
        cleared = int(r.get("ClearedCount") or 0)
        where = " - ".join([x for x in (r.get("PartNumber"), r.get("LocationName")) if x]) or "Hand-picked"
        out.append({
            "runId":       r.get("Id"),
            "runNumber":   r.get("RunNumber") or "",
            "reason":      r.get("Reason") or "",
            "where":       where,
            "statusCode":  r.get("StatusCode") or "",
            "windowOpen":  bool(r.get("WindowOpen")),
            "progress":    "%d of %d cleared" % (cleared, members),
            "pct":         (100.0 * cleared / members) if members else 0.0,
            "selected":    r.get("Id") == sel,
        })
    return out


def memberInstances(runId, selectedMemberId, _refreshToken=None):
    """Flex-repeater instances for the member table."""
    sel = _u(selectedMemberId)
    rework = memberRework(runId)
    out = []
    for r in listMembers(runId):
        out.append({
            "memberId": r.get("MemberId"),
            "kind":     (r.get("Kind") or "").upper(),
            "lotId":    r.get("LotId"),
            "containerId": r.get("ContainerId"),      # piece 4: a container row gets a Repack button
            "name":     r.get("DisplayName") or "",
            "part":     r.get("PartNumber") or "",
            "where":    r.get("CurrentLocationName") or "",
            "pieces":   int(r.get("PieceCount") or 0),
            "tagged":   bool(r.get("CrtActive")),
            "joined":   r.get("JoinMethodName") or "",
            "added":    _fmt(r.get("AddedAt"), "EEE HH:mm"),
            "selected": r.get("MemberId") == sel,
            "rework":   _reworkText(rework.get(str(r.get("MemberId")))),   # piece 5; "" when none
        })
    return out


def previewEncode(rows):
    """Preview rows -> the JSON string the wizard keeps. Every eligible row
       starts ticked."""
    out = []
    for r in (_u(rows) or []):
        out.append({
            "LotId":            r.get("LotId"),
            "ContainerId":      r.get("ContainerId"),
            "Kind":             r.get("Kind") or "",
            "DisplayName":      r.get("DisplayName") or "",
            "PartNumber":       r.get("PartNumber") or "",
            "Where":            r.get("CurrentLocationName") or "",
            "StatusCode":       r.get("StatusCode") or "",
            "PieceCount":       int(r.get("PieceCount") or 0),
            "Made":             _fmt(r.get("ProducedAt"), "EEE HH:mm"),
            "FoundBy":          r.get("FoundBy") or "",
            "Eligible":         bool(r.get("Eligible")),
            "IneligibleReason": r.get("IneligibleReason") or "",
            "Ticked":           bool(r.get("Eligible")),
        })
    return system.util.jsonEncode(out)


def _previewRows(rowsJson):
    t = _u(rowsJson)
    if not t:
        return []
    try:
        return list(system.util.jsonDecode(t) or [])
    except:
        return []


def previewInstances(rowsJson):
    """Flex-repeater instances for the wizard's preview list."""
    out = []
    for i, r in enumerate(_previewRows(rowsJson)):
        out.append({
            "index":    i,
            "ticked":   bool(r.get("Ticked")),
            "eligible": bool(r.get("Eligible")),
            "kind":     (r.get("Kind") or "").upper(),
            "name":     r.get("DisplayName") or "",
            "part":     r.get("PartNumber") or "",
            "where":    r.get("Where") or "",
            "status":   r.get("StatusCode") or "",
            "pieces":   int(r.get("PieceCount") or 0),
            "made":     r.get("Made") or "",
            "foundBy":  r.get("FoundBy") or "",
            "note":     r.get("IneligibleReason") or "",
        })
    return out


def previewTotals(rowsJson):
    """Counts of what is ticked. Always the full shape."""
    t = dict(_EMPTY_TOTALS)
    for r in _previewRows(rowsJson):
        if not r.get("Eligible"):
            t["ineligible"] += 1
            continue
        if not r.get("Ticked"):
            continue
        t["ticked"] += 1
        t["pieces"] += int(r.get("PieceCount") or 0)
        if r.get("Kind") == "Container":
            t["containers"] += 1
        else:
            t["lots"] += 1
    return t


def previewToggle(rowsJson, index):
    """Flip one row's tick (eligible rows only). Returns the new JSON string."""
    rows = _previewRows(rowsJson)
    i = BlueRidge.Common.Util.toIntOrNone(_u(index))
    if i is not None and 0 <= i < len(rows) and rows[i].get("Eligible"):
        rows[i]["Ticked"] = not rows[i].get("Ticked")
    return system.util.jsonEncode(rows)


def previewSetAll(rowsJson, ticked):
    """Tick or untick every eligible row. Returns the new JSON string."""
    rows = _previewRows(rowsJson)
    want = bool(_u(ticked))
    for r in rows:
        if r.get("Eligible"):
            r["Ticked"] = want
    return system.util.jsonEncode(rows)


def previewTicked(rowsJson):
    """The rows to send to open(): ticked AND eligible."""
    return [r for r in _previewRows(rowsJson) if r.get("Ticked") and r.get("Eligible")]


# =============================================================================
# Pieces 2 + 3: inspection results, signed release, deviation.
# Spec: docs/superpowers/specs/2026-10-12-controlled-run-results-and-signoff-design.md
#
# THIN WRAPPERS. What an entry does (real scrap on a LOT, recorded-only on a
# container), what may be voided, whether a member is ready to release and why
# not, are all decided in the Quality.ControlledRun* procs and returned as
# columns (LeftOver, HasResult, ReleaseBlockReason, CanVoid, IsApplied).
#
# WHO: results / void take the Quality sign-in user (the view passes
# session.custom.appUserId inside an elevation window). release() and
# raiseDeviation() take THE SIGNER -- the id AppUser.elevate() just returned
# for a password typed at that moment. Never the session user.
# =============================================================================

_OUTCOMES = [                      # (key = Quality.DispositionCode.Code, tile label)
    ("Accepted",         "Accepted"),
    # "Rework" removed (piece 5): a rework is the supervisor override move back
    # into trim plus its Trim OUT, so a typed count would count the pieces twice.
    # ControlledRunResult_Record refuses it.
    ("ReturnToSupplier", "Return to vendor"),
    ("UseAsIs",          "Use as is"),
]
_OUTCOME_LABEL = dict(_OUTCOMES)
_OUTCOME_SUB = {"ReturnToSupplier": "takes pieces off now"}
_RETURN_KEY = "ReturnToSupplier"     # tile shown only where memberOrigin() says canReturn

_EMPTY_ENTRY_MODEL = {"outcomeTiles": [], "reasonTiles": [], "lines": [], "total": 0,
                      "moreCount": 0, "scrap": 0, "summary": "", "canSave": False}


def listMemberResults(runId, _refreshToken=None):
    """Current members with what the inspection has recorded against each."""
    runId = _u(runId)
    if not runId:
        return []
    return BlueRidge.Common.Db.execList("quality/ControlledRun_ListMemberResults", {"id": runId}) or []


def listResults(runId, includeVoided=False, _refreshToken=None):
    runId = _u(runId)
    if not runId:
        return []
    return BlueRidge.Common.Db.execList(
        "quality/ControlledRunResult_ListByRun",
        {"id": runId, "includeVoided": 1 if _u(includeVoided) else 0}) or []


def recordResults(runId, entries, appUserId, terminalLocationId):
    """entries: [{memberId, dispositionCode, quantity, defectCodeId, remarks}].
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("recordResults runId=%s entries=%s" % (runId, len(_u(entries) or [])))
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("quality/ControlledRunResult_Record", {
        "controlledRunId": _u(runId), "resultsJson": system.util.jsonEncode(_u(entries) or []),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def remainingCount(runId, _refreshToken=None):
    """How many current members have nothing recorded yet (the number on the
       'Mark the rest as all accepted' button). HasResult comes from SQL."""
    # Same test as acceptRemaining(), so the number on the button is the number it acts on.
    return len([r for r in listMemberResults(runId)
                if not r.get("HasResult") and int(r.get("LeftOver") or 0) > 0])


def acceptRemaining(runId, appUserId, terminalLocationId):
    """One Accepted entry, for everything left over, on every member SQL reports
       as having no result yet. One call, all or nothing."""
    entries = []
    for r in listMemberResults(runId):
        left = int(r.get("LeftOver") or 0)
        if not r.get("HasResult") and left > 0:
            entries.append({"memberId": r.get("MemberId"), "dispositionCode": "Accepted", "quantity": left})
    if not entries:
        return {"Status": 0, "Message": "Every member already has a result.", "NewId": None}
    return recordResults(runId, entries, appUserId, terminalLocationId)


def voidResult(resultId, remarks, appUserId, terminalLocationId):
    BlueRidge.Common.Util.log("voidResult resultId=%s" % resultId)
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    return BlueRidge.Common.Db.execMutation("quality/ControlledRunResult_Void", {
        "resultId": _u(resultId), "remarks": _u(remarks),
        "appUserId": appUserId, "terminalLocationId": _u(terminalLocationId)})


def signatureStatement(meaningCode):
    """The exact words shown before signing ('' if unknown). The signing procs
       store this same text on Quality.Signature."""
    row = BlueRidge.Common.Db.execOne("quality/SignatureMeaning_Get", {"code": _u(meaningCode)})
    return (row or {}).get("Statement") or ""


def raiseDeviation(runId, data, signerAppUserId, terminalLocationId):
    """data: {description, justification, defectCodeId, affectedQuantity,
       externalReference}. signerAppUserId is the user who just typed a password."""
    BlueRidge.Common.Util.log("raiseDeviation runId=%s" % runId)
    signerAppUserId = BlueRidge.Common.Util.requireAppUserId(signerAppUserId)
    d = _u(data) or {}
    return BlueRidge.Common.Db.execMutation("quality/ControlledRunDeviation_Raise", {
        "controlledRunId":   _u(runId),
        "description":       d.get("description"),
        "justification":     d.get("justification"),
        "defectCodeId":      BlueRidge.Common.Util.toIntOrNone(d.get("defectCodeId")),
        "affectedQuantity":  BlueRidge.Common.Util.toIntOrNone(d.get("affectedQuantity")),
        "externalReference": d.get("externalReference") or None,
        "appUserId":         signerAppUserId,
        "terminalLocationId": _u(terminalLocationId)})


def release(runId, memberIds, inspectionConfirmed, remarks, signerAppUserId, terminalLocationId):
    """Signed bulk release. memberIds: list of member ids, or the JSON string the
       Sign-off tab keeps. No AIM call here on purpose: clearing the tags returns
       a held serial to the owed-to-AIM list and the existing sweep posts it."""
    BlueRidge.Common.Util.log("release runId=%s" % runId)
    signerAppUserId = BlueRidge.Common.Util.requireAppUserId(signerAppUserId)
    ids = _u(memberIds)
    if isinstance(ids, basestring):
        ids = _tickIds(ids)
    return BlueRidge.Common.Db.execMutation("quality/ControlledRun_Release", {
        "id": _u(runId), "memberIdsJson": system.util.jsonEncode(list(ids or [])),
        "inspectionConfirmed": 1 if _u(inspectionConfirmed) else 0, "remarks": _u(remarks) or None,
        "appUserId": signerAppUserId, "terminalLocationId": _u(terminalLocationId)})


def listDeviations(runId, _refreshToken=None):
    runId = _u(runId)
    if not runId:
        return []
    return BlueRidge.Common.Db.execList("quality/ControlledRunDeviation_ListByRun", {"id": runId}) or []


def listSignatures(runId, _refreshToken=None):
    runId = _u(runId)
    if not runId:
        return []
    return BlueRidge.Common.Db.execList("quality/ControlledRun_ListSignatures", {"id": runId}) or []


def defectOptions():
    """[{label, value}] of defect reasons for the deviation form."""
    return [{"label": o.get("label"), "value": o.get("value")}
            for o in (BlueRidge.Quality.DefectCode.getForDropdown() or [])]


# ---- Results tab: the accordion ---------------------------------------------

_RESULT_HEADER_VIEW = "BlueRidge/Components/PlantFloor/ControlledRunResultHeader"
_RESULT_BODY_VIEW   = "BlueRidge/Components/PlantFloor/ControlledRunResultEntry"


def _expandedIds(currentItems):
    """Member ids whose accordion item is open right now. The component's own
       toggle writes props.items[i].expanded; a reload must carry that over
       instead of resetting it (spec D10). currentItems arrives as a live
       property wrapper, so it is read defensively and never kept."""
    out = set()
    try:
        for it in (currentItems or []):
            try:
                if it["expanded"]:
                    out.add(int(it["body"]["viewParams"]["memberId"]))
            except:
                pass
    except:
        pass
    return out


def resultItems(runId, currentItems, runOpen, token):
    """props.items for the Results accordion: one item per current member.
       header = the summary row view, body = the entry form view. `token` is
       passed into the body so a saved result reloads its numbers."""
    keep = _expandedIds(currentItems)
    isOpen = bool(_u(runOpen))
    rework = memberRework(runId)
    origin = memberOrigin(runId)
    items = []
    for r in listMemberResults(runId):
        mid = r.get("MemberId")
        left = int(r.get("LeftOver") or 0)
        org = origin.get(str(mid)) or {}
        row = {
            "memberId": mid,
            "name":     r.get("DisplayName") or "",
            "part":     r.get("PartNumber") or "",
            "pieces":   int(r.get("PieceCount") or 0),
            "accepted": int(r.get("AcceptedQty") or 0),
            "scrap":    int(r.get("ScrapQty") or 0),
            "rework":   int(r.get("ReworkQty") or 0),
            "atTrim":   _reworkSince(rework.get(str(mid))),     # piece 5; "" when not at trim
            "returned": int(r.get("ReturnQty") or 0),
            "useAsIs":  int(r.get("UseAsIsQty") or 0),
            "leftOver": left,
            "hasResult": bool(r.get("HasResult")),
        }
        items.append({
            "expanded": mid in keep,
            "header": {
                "content": {"type": "view", "text": "", "viewPath": _RESULT_HEADER_VIEW,
                            "viewParams": {"row": row},
                            "useDefaultViewHeight": False, "useDefaultViewWidth": False,
                            "style": {"classes": ""}},
                # The accordion ships with a light header; without these the row text
                # (light, for the dark plant-floor theme) is invisible on white.
                # reverse = toggle arrow on the RIGHT, under the column header's spacer
                "height": "52px", "reverse": True,
                "style": {"classes": "", "backgroundColor": "var(--mpp-surface-raised)",
                          "color": "var(--mpp-text-primary)",
                          "borderBottom": "1px solid var(--mpp-border-subtle)"},
                "toggle": {"enabled": True,
                           "collapsedIcon": {"path": "material/expand_more", "color": "var(--mpp-text-secondary)", "style": {"classes": ""}},
                           "expandedIcon":  {"path": "material/expand_less", "color": "var(--mpp-accent-60)", "style": {"classes": ""}}},
            },
            "body": {
                "viewPath": _RESULT_BODY_VIEW,
                "viewParams": {
                    "runId": _u(runId), "memberId": mid, "name": row["name"],
                    "isContainer": (r.get("Kind") == "Container"),
                    "canReturn": bool(org.get("canReturn")),
                    "origin": org.get("origin") or "",
                    "pieces": row["pieces"], "leftOver": left,
                    "rankLocationId": r.get("RankLocationId"),
                    "runOpen": isOpen, "token": _u(token) or 0,
                },
                "height": "auto", "useDefaultViewHeight": True, "useDefaultViewWidth": False,
                "style": {"classes": "", "margin": "0px", "backgroundColor": "var(--mpp-surface-raised)",
                          "borderBottom": "2px solid var(--mpp-accent-60)"},
            },
        })
    return items


def resultLogInstances(runId, _refreshToken=None):
    """Flex-repeater instances for the entry log under the accordion."""
    out = []
    for r in listResults(runId, False):
        defect = " ".join([x for x in (r.get("DefectCode"), r.get("DefectDescription")) if x])
        if r.get("DispositionCode") == "Scrap":
            state = "Applied" if r.get("IsApplied") else "Not yet applied"
        else:
            state = ""
        out.append({
            "resultId": r.get("ResultId"),
            "when":     _fmt(r.get("RecordedAt"), "EEE HH:mm"),
            "member":   r.get("DisplayName") or "",
            "outcome":  _OUTCOME_LABEL.get(r.get("DispositionCode"), r.get("DispositionName") or ""),
            "quantity": int(r.get("Quantity") or 0),
            "defect":   defect,
            "by":       r.get("RecordedByInitials") or "",
            "remarks":  r.get("Remarks") or "",
            "state":    state,
            "canVoid":  bool(r.get("CanVoid")),
        })
    return out


# ---- Results tab: one member's entry form -----------------------------------
# The draft is a JSON STRING in the body view's custom props (a list of dicts in
# view.custom fed to a repeater renders nothing): {"lines": [{"key", "quantity"}]}.
# key = a disposition code for a count, or "D<defectCodeId>" for a scrap reason.
# One key == one line, so a second tap adds to the line instead of duplicating it.

def _draftLines(draftJson):
    t = _u(draftJson)
    if not t:
        return []
    try:
        d = system.util.jsonDecode(t) or {}
        out = []
        for l in (d.get("lines") or []):
            q = BlueRidge.Common.Util.toIntOrNone(l.get("quantity")) or 0
            if l.get("key") and q > 0:
                out.append({"key": "%s" % l.get("key"), "quantity": q})
        return out
    except:
        return []


def _draftJson(lines):
    return system.util.jsonEncode({"lines": lines})


def _plain(value):
    """A list of dicts read back out of view.custom arrives as wrapper objects
       (ImmutableMap elements have no .get()). A JSON round trip turns it into
       plain lists and dicts; anything that will not encode yields []."""
    v = _u(value)
    if not v:
        return []
    try:
        return list(system.util.jsonDecode(system.util.jsonEncode(v)) or [])
    except:
        return []


def entryChange(draftJson, key, delta=None, quantity=None):
    """Tile tap / stepper (delta) or keyed quantity / remove (quantity). Returns
       the new draft JSON. A quantity of 0 or less drops the line."""
    key = _u(key)
    lines = _draftLines(draftJson)
    if not key:
        return _draftJson(lines)
    key = "%s" % key
    cur = 0
    for l in lines:
        if l["key"] == key:
            cur = l["quantity"]
    if _u(quantity) is not None and _u(quantity) != "":
        target = BlueRidge.Common.Util.toIntOrNone(_u(quantity)) or 0
    else:
        target = cur + (BlueRidge.Common.Util.toIntOrNone(_u(delta)) or 0)
    target = max(0, min(target, 99999))
    out, seen = [], False
    for l in lines:
        if l["key"] != key:
            out.append(l)
            continue
        seen = True
        if target > 0:
            out.append({"key": key, "quantity": target})
    if not seen and target > 0:
        out.append({"key": key, "quantity": target})
    return _draftJson(out)


def entryAcceptRest(draftJson, leftOver):
    """Put whatever is not yet accounted for into Accepted."""
    lines = _draftLines(draftJson)
    entered = sum(l["quantity"] for l in lines)
    rest = (BlueRidge.Common.Util.toIntOrNone(_u(leftOver)) or 0) - entered
    if rest <= 0:
        return _draftJson(lines)
    cur = 0
    for l in lines:
        if l["key"] == "Accepted":
            cur = l["quantity"]
    return entryChange(_draftJson(lines), "Accepted", None, cur + rest)


def entryCatalog(rankLocationId):
    """Scrap reasons for the tiles, most used at that location first. No
       operation filter: an inspection is not an operation."""
    return BlueRidge.Quality.DefectCode.getForTilesRanked(_u(rankLocationId), None)


def entryModel(memberId, catalog, draftJson, showAll, leftOver, isContainer, canReturn=False):
    """Everything the entry form renders, in one pass. Always fully shaped.
       canReturn is SQL's CanReturnToVendor for the member (memberOrigin); the
       Return to vendor tile is left out when it is false (unless a line for it
       is already in the draft, so it can still be seen and removed)."""
    m = dict(_EMPTY_ENTRY_MODEL)
    mid = _u(memberId)
    lines = _draftLines(draftJson)
    counts = dict((l["key"], l["quantity"]) for l in lines)
    showAll = bool(_u(showAll))
    left = BlueRidge.Common.Util.toIntOrNone(_u(leftOver)) or 0

    showReturn = bool(_u(canReturn))
    m["outcomeTiles"] = [{
        "memberId": mid, "key": k, "label": label, "sub": _OUTCOME_SUB.get(k, ""),
        "quantity": counts.get(k, 0), "selected": counts.get(k, 0) > 0,
    } for (k, label) in _OUTCOMES if (k != _RETURN_KEY or showReturn or counts.get(k, 0) > 0)]

    names, reasonTiles, more = {}, [], 0
    for t in _plain(catalog):
        did = BlueRidge.Common.Util.toIntOrNone(t.get("defectCodeId"))
        if did is None:
            continue
        key = "D%d" % did
        names[key] = (t.get("code") or "", t.get("description") or "")
        primary = bool(t.get("isPrimary"))
        if not primary:
            more += 1
        q = counts.get(key, 0)
        if not (showAll or primary or q > 0):
            continue
        reasonTiles.append({"memberId": mid, "key": key, "label": t.get("description") or "",
                            "sub": t.get("code") or "", "quantity": q, "selected": q > 0})
    m["reasonTiles"] = reasonTiles
    m["moreCount"] = more

    outLines, scrap = [], 0
    for l in lines:
        k = l["key"]
        if k in _OUTCOME_LABEL:
            title, sub = _OUTCOME_LABEL[k], ("needs a signed deviation" if k == "UseAsIs" else "")
        else:
            code, desc = names.get(k, (k, ""))
            title, sub = code, desc
            scrap += l["quantity"]
        outLines.append({"memberId": mid, "key": k, "title": title, "sub": sub, "quantity": l["quantity"]})
    m["lines"] = outLines
    total = sum(l["quantity"] for l in lines)
    m["total"] = total
    m["scrap"] = scrap
    m["canSave"] = total > 0

    bits = ["%d entered, %d left over" % (total, left - total)]
    if scrap > 0:
        bits.append("%d scrap is recorded but stays in the container until it is repacked" % scrap
                    if _u(isContainer) else "%d scrap comes off this LOT when you save" % scrap)
    returned = counts.get(_RETURN_KEY, 0)
    if returned > 0:
        bits.append("%d to return to the vendor comes off this LOT when you save" % returned)
    m["summary"] = ". ".join(bits) + "."
    return m


def entryToResults(memberId, draftJson, remarks):
    """Draft -> the entries recordResults() takes."""
    out = []
    rem = (_u(remarks) or "").strip() or None
    for l in _draftLines(draftJson):
        k = l["key"]
        if k in _OUTCOME_LABEL:
            out.append({"memberId": _u(memberId), "dispositionCode": k, "quantity": l["quantity"], "remarks": rem})
        else:
            out.append({"memberId": _u(memberId), "dispositionCode": "Scrap", "quantity": l["quantity"],
                        "defectCodeId": BlueRidge.Common.Util.toIntOrNone(k[1:]), "remarks": rem})
    return out


def entryLineLabel(draftJson, key, catalog):
    """Label for the number pad: what is being keyed."""
    for l in entryModel(None, catalog, draftJson, True, 0, False)["lines"]:
        if l["key"] == _u(key):
            return ("%s %s" % (l["title"], l["sub"])).strip()
    k = _u(key)
    return _OUTCOME_LABEL.get(k, "")


# ---- Sign-off tab -----------------------------------------------------------
# The ticked members are kept as a JSON STRING of ids in the tab's custom props.

def _tickIds(tickedJson):
    t = _u(tickedJson)
    if not t:
        return []
    try:
        return [int(x) for x in (system.util.jsonDecode(t) or [])]
    except:
        return []


def _resultText(r):
    parts = []
    for label, col in (("accepted", "AcceptedQty"), ("scrap", "ScrapQty"), ("rework", "ReworkQty"),
                       ("return", "ReturnQty"), ("use as is", "UseAsIsQty")):
        q = int(r.get(col) or 0)
        if q:
            parts.append("%d %s" % (q, label))
    return ", ".join(parts) or "-"


def releaseInstances(runId, tickedJson, _refreshToken=None):
    """Flex-repeater instances for the release list. 'ready' is SQL's verdict
       (ReleaseBlockReason IS NULL); a tick on a member that is not ready is
       dropped here so the count can never include one."""
    ticked = set(_tickIds(tickedJson))
    out = []
    for r in listMemberResults(runId):
        reason = r.get("ReleaseBlockReason") or ""
        ready = not reason
        out.append({
            "memberId": r.get("MemberId"),
            "kind":     (r.get("Kind") or "").upper(),
            "name":     r.get("DisplayName") or "",
            "pieces":   int(r.get("PieceCount") or 0),
            "results":  _resultText(r),
            "leftOver": int(r.get("LeftOver") or 0),
            "ready":    ready,
            "reason":   reason,
            "tagged":   bool(r.get("CrtActive")),
            "ticked":   ready and r.get("MemberId") in ticked,
        })
    return out


def tickToggle(runId, tickedJson, memberId):
    """Flip one member's tick; only a ready member can be ticked."""
    mid = BlueRidge.Common.Util.toIntOrNone(_u(memberId))
    ids = _tickIds(tickedJson)
    if mid in ids:
        ids.remove(mid)
    else:
        for r in listMemberResults(runId):
            if r.get("MemberId") == mid and not r.get("ReleaseBlockReason"):
                ids.append(mid)
    return system.util.jsonEncode(ids)


def tickAllReady(runId):
    return system.util.jsonEncode(
        [r.get("MemberId") for r in listMemberResults(runId) if not r.get("ReleaseBlockReason")])


def tickSummary(runId, tickedJson, _refreshToken=None):
    """{count, pieces, names, ready} for the ticked members that are STILL ready.
       Always the full shape."""
    out = {"count": 0, "pieces": 0, "names": "", "ready": 0, "idsJson": "[]"}
    ticked = set(_tickIds(tickedJson))
    names, ids = [], []
    for r in listMemberResults(runId):
        if r.get("ReleaseBlockReason"):
            continue
        out["ready"] += 1
        if r.get("MemberId") in ticked:
            ids.append(r.get("MemberId"))
            out["count"] += 1
            out["pieces"] += int(r.get("PieceCount") or 0)
            names.append(r.get("DisplayName") or "")
    out["names"] = ", ".join(names[:8]) + (" and %d more" % (len(names) - 8) if len(names) > 8 else "")
    out["idsJson"] = system.util.jsonEncode(ids)
    return out


def deviationInstances(runId, _refreshToken=None):
    out = []
    for d in listDeviations(runId):
        meta = "Signed by %s, %s" % (d.get("SignedByInitials") or "?", _fmt(d.get("RaisedAt"), "EEE MM/dd HH:mm"))
        if d.get("ExternalReference"):
            meta += " - MPP ref %s" % d.get("ExternalReference")
        title = d.get("DeviationNumber") or ""
        if d.get("AffectedQuantity"):
            title += "  (%d pcs)" % int(d.get("AffectedQuantity"))
        out.append({"title": title, "text": d.get("Description") or "", "meta": meta})
    return out


def signatureInstances(runId, _refreshToken=None):
    out = []
    for s in listSignatures(runId):
        out.append({"title": s.get("Summary") or "",
                    "text":  s.get("Statement") or "",
                    "meta":  "%s, %s" % (s.get("SignedByInitials") or "?", _fmt(s.get("SignedAt"), "EEE MM/dd HH:mm"))})
    return out


def memberRework(controlledRunId, _refreshToken=None):
    """Members whose LOT is in an open rework: {memberId(str): {startedAt, approvedBy}}.
       Keys are strings so the dict survives the Perspective property tree / JSON
       unchanged; a view looks a member up with str(memberId). {} when none."""
    rid = BlueRidge.Common.Util.toIntOrNone(_u(controlledRunId))
    if rid is None:
        return {}
    out = {}
    for r in (BlueRidge.Common.Db.execList(
            "quality/ControlledRun_ListMemberRework", {"controlledRunId": rid}) or []):
        out[str(r.get("MemberId"))] = {
            "startedAt":  _fmt(r.get("StartedAt"), "EEE HH:mm"),
            "approvedBy": r.get("ApprovedByInitials") or "",
        }
    return out


def _reworkSince(entry):
    """'since Mon 13:05 - DS' for a memberRework() entry, '' for none."""
    e = _u(entry) or {}
    if not e:
        return ""
    since = "since %s" % (e.get("startedAt") or "")
    who = e.get("approvedBy") or ""
    return (u"%s \u00b7 %s" % (since, who)) if who else since


def _reworkText(entry):
    """The member row's status line: 'At trim rework since Mon 13:05 - DS', '' for none."""
    since = _reworkSince(entry)
    return (u"At trim rework " + since) if since else ""


def memberOrigin(controlledRunId, _refreshToken=None):
    """Where each current member's material came from:
       {memberId(str): {"origin": LotOriginCode or "", "canReturn": bool}}.
       canReturn is SQL's CanReturnToVendor (a Received / ReceivedOffsite LOT,
       never a container). It only decides whether the Return to vendor tile is
       shown; ControlledRunResult_Record stays the authority. {} when none."""
    rid = BlueRidge.Common.Util.toIntOrNone(_u(controlledRunId))
    if rid is None:
        return {}
    out = {}
    for r in (BlueRidge.Common.Db.execList(
            "quality/ControlledRun_ListMemberOrigin", {"controlledRunId": rid}) or []):
        out[str(r.get("MemberId"))] = {
            "origin":    r.get("LotOriginCode") or "",
            "canReturn": bool(r.get("CanReturnToVendor")),
        }
    return out


# ---------------------------------------------------------------------------
# Piece 6 -- visibility reads (LOT Detail tab, genealogy markers, History tab,
# dashboard tile). Thin wrappers: the procs return Eastern times, kind labels,
# membership states and CanClose; this only formats times for repeaters.
# ---------------------------------------------------------------------------

_EMPTY_OPEN_FOR_LOT = {"Id": None, "RunNumber": ""}
_EMPTY_OPEN_SUMMARY = {"OpenCount": 0, "OldestOpenedAt": None, "OldestAgeDays": None,
                       "MembersStillTagged": 0}


def listByLot(lotId, _refreshToken=None):
    """Every super-lot membership a LOT has had, newest first (open and ended).
       [] for a LOT that was never in a super-lot or an empty id."""
    lotId = BlueRidge.Common.Util.toIntOrNone(_u(lotId))
    if lotId is None:
        return []
    return BlueRidge.Common.Db.execList("quality/ControlledRun_ListByLot", {"lotId": lotId}) or []


def listByLotInstances(lotId, _refreshToken=None):
    """Repeater instances for LOT Detail's Super-lots tab: one {'row': {...}} per
       membership, the ListByLot columns plus JoinedAtDisplay / LeftAtDisplay /
       ReleasedAtDisplay ('MM/dd HH:mm', '' when none) pre-formatted here."""
    out = []
    for r in listByLot(lotId):
        r = dict(r or {})
        r["JoinedAtDisplay"] = _fmt(r.get("JoinedAt"), "MM/dd HH:mm")
        r["LeftAtDisplay"] = _fmt(r.get("LeftAt"), "MM/dd HH:mm")
        r["ReleasedAtDisplay"] = _fmt(r.get("ReleasedAt"), "MM/dd HH:mm")
        out.append({"row": r})
    return out


def openForLotOrEmpty(lotId, _refreshToken=None):
    """The open super-lot a LOT is in: {'Id', 'RunNumber'}. Always shaped:
       {'Id': None, 'RunNumber': ''} when the LOT is in none."""
    out = dict(_EMPTY_OPEN_FOR_LOT)
    lotId = BlueRidge.Common.Util.toIntOrNone(_u(lotId))
    if lotId is None:
        return out
    row = BlueRidge.Common.Db.execOne("quality/ControlledRun_GetOpenByMember",
                                      {"lotId": lotId, "containerId": None})
    if row:
        out["Id"] = row.get("Id")
        out["RunNumber"] = row.get("RunNumber") or ""
    return out


def markers(lotIdsCsv, containerIdsCsv, _refreshToken=None):
    """Super-lot markers for genealogy nodes: ControlledRun_ListMarkers rows
       (NodeKind, NodeId, RunNumber, ControlledRunId, MembershipState).
       Ids arrive as comma-separated strings (a list argument to runScript
       arrives as QualifiedValue[] and throws). [] when both are empty."""
    lots = _u(lotIdsCsv) or ""
    cons = _u(containerIdsCsv) or ""
    if not (lots or cons):
        return []
    return BlueRidge.Common.Db.execList(
        "quality/ControlledRun_ListMarkers",
        {"lotIdsCsv": lots, "containerIdsCsv": cons}) or []


def historyInstances(runId, _refreshToken=None):
    """Repeater instances for the super-lot History tab, newest first:
       {'row': {EventAt, Kind, Detail, ByInitials, EventAtDisplay}}.
       EventAtDisplay is 'EEE MM/dd HH:mm' (the proc's times are Eastern)."""
    runId = BlueRidge.Common.Util.toIntOrNone(_u(runId))
    if runId is None:
        return []
    out = []
    for r in (BlueRidge.Common.Db.execList("quality/ControlledRun_ListHistory", {"id": runId}) or []):
        r = dict(r or {})
        r["EventAtDisplay"] = _fmt(r.get("EventAt"), "EEE MM/dd HH:mm")
        out.append({"row": r})
    return out


def openSummaryOrEmpty(_refreshToken=None):
    """Dashboard tile: {OpenCount, OldestOpenedAt, OldestAgeDays, MembersStillTagged}.
       Always shaped (zeros / None when nothing is open)."""
    out = dict(_EMPTY_OPEN_SUMMARY)
    row = BlueRidge.Common.Db.execOne("quality/ControlledRun_GetOpenSummary", None)
    if row:
        out.update(row)
    return out


def getRunByNumber(runNumber):
    """One super-lot header by its number (ControlledRun_GetByNumber), or None."""
    t = _u(runNumber)
    if not t:
        return None
    return BlueRidge.Common.Db.execOne("quality/ControlledRun_GetByNumber", {"runNumber": t})


def openSummaryText(openCount, oldestAgeDays, membersStillTagged):
    """Dashboard tile sub-text from the openSummaryOrEmpty() numbers. Presentation
       only: 'none open' or 'oldest <n> d <dot> <m> members still CRT <dot> tap to open'."""
    dot = u" \u00b7 "
    n = BlueRidge.Common.Util.toIntOrNone(_u(openCount)) or 0
    if n <= 0:
        return u"none open"
    age = BlueRidge.Common.Util.toIntOrNone(_u(oldestAgeDays)) or 0
    m = BlueRidge.Common.Util.toIntOrNone(_u(membersStillTagged)) or 0
    return u"oldest %d d%s%d members still CRT%stap to open" % (age, dot, m, dot)
