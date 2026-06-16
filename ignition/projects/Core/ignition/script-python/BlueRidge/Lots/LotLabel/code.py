"""BlueRidge.Lots.LotLabel - LTT label render + SYNCHRONOUS ZPL dispatch.

   Arc 2 Phase 4 (Spec 2 sec 3/4). Orchestrates:
     SQL render (Lots.LotLabel_Print/_Reprint -> ZplContent)
       -> resolve printer endpoint from session.custom.printer
       -> synchronous raw-TCP socket write to the networked Zebra
       -> log EVERY attempt to Audit.InterfaceLog (Audit_LogInterfaceCall)
       -> on success: Lots.LotLabel_RecordDispatch ack write-back.

   Print failure NEVER rolls back the LOT (mint + print are separate steps);
   the UI holds on the failed-print state and offers Reprint.

   NOTE: the public method is printLabel (NOT 'print' -- a Jython 2 keyword).
   HARDWARE-GATED: raw TCP 9100 reaches NETWORKED Zebra printers only; real-print
   certification is a deployment gate. Verify via a local socket listener / Labelary
   until hardware is available.

   Wrappers route View -> here -> BlueRidge.Common.Db -> system.db.*."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Location.Terminal

from java.net import Socket, InetSocketAddress
from java.lang import String as JString

_SYSTEM_NAME = "Zebra"
_DEFAULT_PORT = 9100
_TIMEOUT_MS = 4000   # bounded connect + write timeout (spec: 3-5 s)


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _sessionPrinter():
    """Resolve session.custom.printer ({locationId, code, endpoint, model}).
       Empty dict when unset (no-printer / FALLBACK terminal)."""
    try:
        custom = system.perspective.getSessionInfo()["custom"]
        return custom.get("printer") or {}
    except Exception as e:
        BlueRidge.Common.Util.log("_sessionPrinter failed: %s" % str(e))
        return {}


def _dispatchZpl(endpoint, zpl):
    """Pure transport: raw-TCP write of the ZPL bytes to host:port (default 9100),
       bounded timeout. Returns {ok, error}. No business logic."""
    s = None
    try:
        ep = (endpoint or "").strip()
        if ":" in ep:
            host, portStr = ep.rsplit(":", 1)
            port = int(portStr)
        else:
            host, port = ep, _DEFAULT_PORT
        if not host:
            return {"ok": False, "error": "empty endpoint"}
        s = Socket()
        s.connect(InetSocketAddress(host, port), _TIMEOUT_MS)
        s.setSoTimeout(_TIMEOUT_MS)
        out = s.getOutputStream()
        out.write(JString(zpl or "").getBytes("US-ASCII"))
        out.flush()
        return {"ok": True, "error": None}
    except Exception as e:
        return {"ok": False, "error": str(e)}
    finally:
        try:
            if s is not None:
                s.close()
        except Exception:
            pass


def _logDispatch(endpoint, zpl, outcome):
    """Log one dispatch attempt to Audit.InterfaceLog (every attempt: success,
       failure, retry). High-fidelity so endpoint + ZPL head persist."""
    ok = bool(outcome and outcome.get("ok"))
    head = (zpl or "")[:200]
    params = {
        "systemName":       _SYSTEM_NAME,
        "direction":        "Outbound",
        "logEventTypeCode": "LabelDispatched",
        "description":      "LTT dispatch to %s" % (endpoint or "(none)"),
        "requestPayload":   "%s | %s" % (endpoint or "", head),
        "responsePayload":  "OK" if ok else None,
        "errorCondition":   None if ok else "DispatchFailed",
        "errorDescription": None if ok else (outcome.get("error") if outcome else "unknown"),
        "isHighFidelity":   True,
    }
    try:
        BlueRidge.Common.Db.execList("audit/Audit_LogInterfaceCall", params)
    except Exception as e:
        BlueRidge.Common.Util.log("_logDispatch failed: %s" % str(e))


def _dispatchAfterRender(res, appUserId, terminalLocationId):
    """Shared tail for printLabel/reprint: take a render result (Status, Message,
       NewId=LotLabelId, ZplContent), dispatch the ZPL, log, ack on success, with
       one endpoint re-resolve + retry on failure. Returns a UI status dict."""
    if not res or not res.get("Status"):
        return res
    lotLabelId = res.get("NewId")
    zpl = res.get("ZplContent") or ""

    printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    printerCode = printer.get("code") or ""

    # Fail-fast: no printer configured for this terminal. LOT/label already exist.
    if not endpoint:
        return {"Status": 0,
                "Message": "This terminal has no printer configured.",
                "NewId": lotLabelId}

    outcome = _dispatchZpl(endpoint, zpl)
    _logDispatch(endpoint, zpl, outcome)
    if outcome.get("ok"):
        BlueRidge.Common.Db.execMutation(
            "lots/LotLabel_RecordDispatch",
            {"lotLabelId": lotLabelId, "printerName": printerCode})
        return {"Status": 1, "Message": "Label printed.", "NewId": lotLabelId}

    # One re-resolve of the endpoint from the DB (covers a stale session value)
    # + retry, logged.
    fresh = BlueRidge.Location.Terminal.getPrinter(terminalLocationId) or {}
    freshEndpoint = (fresh.get("endpoint") or "").strip()
    if freshEndpoint and freshEndpoint != endpoint:
        outcome = _dispatchZpl(freshEndpoint, zpl)
        _logDispatch(freshEndpoint, zpl, outcome)
        if outcome.get("ok"):
            BlueRidge.Common.Db.execMutation(
                "lots/LotLabel_RecordDispatch",
                {"lotLabelId": lotLabelId, "printerName": fresh.get("code") or printerCode})
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
    res = BlueRidge.Common.Db.execMutation("lots/LotLabel_Print", {
        "lotId":              d.get("lotId"),
        "labelTypeCodeId":    d.get("labelTypeCodeId"),
        "printReasonCodeId":  d.get("printReasonCodeId"),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "printerName":        printer.get("code") or None,
    })
    return _dispatchAfterRender(res, appUserId, terminalLocationId)


def reprint(lotId, printReasonCodeId, appUserId=None, terminalLocationId=None):
    """Re-render (non-Initial reason) + synchronously dispatch. Same dispatch tail
       as printLabel. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("reprint lotId=%s printReasonCodeId=%s" % (lotId, printReasonCodeId))
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    printer = _sessionPrinter()
    res = BlueRidge.Common.Db.execMutation("lots/LotLabel_Reprint", {
        "lotId":              _u(lotId),
        "printReasonCodeId":  _u(printReasonCodeId),
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "printerName":        printer.get("code") or None,
    })
    return _dispatchAfterRender(res, appUserId, terminalLocationId)
