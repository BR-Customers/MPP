"""BlueRidge.Lots.LotLabel - LTT label render + SYNCHRONOUS ZPL dispatch.

   Arc 2 Phase 4 (Spec 2 sec 3/4). Orchestrates:
     SQL render (Lots.LotLabel_Print/_Reprint -> ZplContent)
       -> resolve the printer serving this label type (session.custom.printer as fallback)
       -> hand the bytes to BlueRidge.Lots.LabelTransport
       -> log EVERY attempt to Audit.InterfaceLog (LabelTransport.logDispatch)
       -> on success: Lots.LotLabel_RecordDispatch ack write-back.

   This module owns ORCHESTRATION only. Transport lives in LabelTransport, which
   picks raw TCP or a Windows print queue from the endpoint's syntax (design
   2026-07-28) -- so this path serves a networked Zebra and a USB printer shared
   from a terminal PC equally, and neither is named here.

   Print failure NEVER rolls back the LOT (mint + print are separate steps);
   the UI holds on the failed-print state and offers Reprint.

   NOTE: the public method is printLabel (NOT 'print' -- a Jython 2 keyword).
   HARDWARE-GATED: real-print certification is a deployment gate. Verify via a
   local socket listener / Labelary until hardware is available.

   Wrappers route View -> here -> BlueRidge.Common.Db -> system.db.*."""



def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _labelTypeIdByCode(code):
    """Resolve a Lots.LabelTypeCode Id by Code (default-resolution helper).
       Returns Id or None."""
    for r in (BlueRidge.Common.Db.execList("lots/LabelTypeCode_List") or []):
        if r.get("Code") == code:
            return r.get("Id")
    return None


def _labelTypeCodeById(labelTypeCodeId):
    """Resolve a Lots.LabelTypeCode Code by Id (routing needs the code, the procs
       take the id). Returns the Code or None."""
    if labelTypeCodeId is None:
        return None
    for r in (BlueRidge.Common.Db.execList("lots/LabelTypeCode_List") or []):
        if r.get("Id") == labelTypeCodeId:
            return r.get("Code")
    return None


def _printReasonIdByCode(code):
    """Resolve a Lots.PrintReasonCode Id by Code. Returns Id or None."""
    for r in (BlueRidge.Common.Db.execList("lots/PrintReasonCode_List") or []):
        if r.get("Code") == code:
            return r.get("Id")
    return None


def _firstNonInitialReasonId():
    """First PrintReasonCode whose Code != 'Initial' (reprint default)."""
    for r in (BlueRidge.Common.Db.execList("lots/PrintReasonCode_List") or []):
        if (r.get("Code") or "") != "Initial":
            return r.get("Id")
    return None


def _sessionPrinter():
    """Resolve session.custom.printer ({locationId, code, endpoint, model}).
       Empty dict when unset (no-printer / FALLBACK terminal)."""
    try:
        custom = system.perspective.getSessionInfo()["custom"]
        return custom.get("printer") or {}
    except Exception as e:
        BlueRidge.Common.Util.log("_sessionPrinter failed: %s" % str(e))
        return {}


def _dispatchAfterRender(res, appUserId, terminalLocationId, labelTypeCode=None):
    """Shared tail for printLabel/reprint: take a render result (Status, Message,
       NewId=LotLabelId, ZplContent), resolve the printer serving labelTypeCode,
       dispatch the ZPL, log the attempt, and ack on success. Returns a UI status dict.

       ONE resolve, ONE attempt, by design. The old re-resolve-and-retry existed to
       recover from a stale session.custom.printer endpoint; the resolve above now reads
       fresh from the DB, so there is nothing stale left to recover from. A route-aware
       retry would also be unreachable -- it would query identically and the
       endpoint-changed guard could never fire. On failure the UI offers Reprint."""
    if not res or not res.get("Status"):
        return res
    lotLabelId = res.get("NewId")
    zpl = res.get("ZplContent") or ""

    # Resolve by label type first (design sec 3.5): resolving fresh also sidesteps the
    # stale-session bug where a printer configured mid-session stays invisible until
    # a restart. Fall back to the session printer when the DB read yields nothing.
    printer = {}
    if terminalLocationId is not None:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId, labelTypeCode) or {}
    if not (printer.get("endpoint") or "").strip():
        printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    printerCode = printer.get("code") or ""

    # Fail-fast: genuinely no printer configured for this terminal. LOT/label already exist.
    if not endpoint:
        return {"Status": 0,
                "Message": "This terminal has no printer configured.",
                "NewId": lotLabelId}

    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "LTT")
    if outcome.get("ok"):
        BlueRidge.Common.Db.execMutation(
            "lots/LotLabel_RecordDispatch",
            {"lotLabelId": lotLabelId, "printerName": printerCode})
        return {"Status": 1, "Message": "Label printed.", "NewId": lotLabelId}

    return {"Status": 0,
            "Message": "Print failed: %s. Use Reprint to retry." % (outcome.get("error") or "unknown"),
            "NewId": lotLabelId}


def printLabel(data, appUserId=None, terminalLocationId=None):
    """Render + synchronously dispatch an LTT label. data carries lotId,
       labelTypeCodeId, printReasonCodeId. Returns {Status, Message, NewId}.
       (Named printLabel, not 'print' -- Jython 2 keyword.)"""
    BlueRidge.Common.Util.log("printLabel data=%s" % data)
    d = _u(data) or {}
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    printer = _sessionPrinter()
    # Default-resolve label type / reason when the caller (e.g. Receiving) omits them.
    labelTypeCodeId = d.get("labelTypeCodeId") or _labelTypeIdByCode("Primary")
    printReasonCodeId = d.get("printReasonCodeId") or _printReasonIdByCode("Initial")
    res = BlueRidge.Common.Db.execMutation("lots/LotLabel_Print", {
        "lotId":              d.get("lotId"),
        "labelTypeCodeId":    labelTypeCodeId,
        "printReasonCodeId":  printReasonCodeId,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "printerName":        printer.get("code") or None,
    })
    return _dispatchAfterRender(res, appUserId, terminalLocationId,
                                _labelTypeCodeById(labelTypeCodeId))


def reprint(lotId, printReasonCodeId, appUserId=None, terminalLocationId=None):
    """Re-render (non-Initial reason) + synchronously dispatch. Same dispatch tail
       as printLabel. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("reprint lotId=%s printReasonCodeId=%s" % (lotId, printReasonCodeId))
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    printer = _sessionPrinter()
    reasonId = _u(printReasonCodeId) or _firstNonInitialReasonId()
    res = BlueRidge.Common.Db.execMutation("lots/LotLabel_Reprint", {
        "lotId":              _u(lotId),
        "printReasonCodeId":  reasonId,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "printerName":        printer.get("code") or None,
    })
    return _dispatchAfterRender(res, appUserId, terminalLocationId, "Primary")
