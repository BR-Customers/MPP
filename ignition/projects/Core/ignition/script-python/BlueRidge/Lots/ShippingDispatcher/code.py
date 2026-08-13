"""BlueRidge.Lots.ShippingDispatcher - container shipping-label ZPL dispatch (Arc 2 Phase 6/7; Brief D).

   The shipping-label ZPL is RENDERED + PERSISTED in SQL at container-complete time
   (Lots.Container_Complete -> Lots.ufn_ShippingLabelZpl -> ShippingLabel.ZplContent).
   This module only DISPATCHES the persisted payload:

     resolve endpoint (printer-card override / session / terminal)
       -> read persisted ShippingLabel.ZplContent (lots/ShippingLabel_GetById)
       -> GATEWAY-ASYNC worker: 3 attempts w/ ~2s backoff, raw-TCP write to the Zebra,
          log EVERY attempt to Audit.InterfaceLog
       -> record the outcome on the row (lots/ShippingLabel_MarkDispatch):
             success -> PrintedAt ; exhausted -> PrintFailedAt + LastPrintError.

   Async (FDS-01-014 external-interface idiom, like AIM): the 3x/backoff never blocks
   the Perspective session thread -- dispatch() returns immediately and the ShippingLabel
   state + PrintFailureGateway banner reflect the result. A Gateway restart between the
   Container_Complete commit and the dispatch leaves a stranded row (ZplContent already
   persisted) that PrintFailureGateway.sweepTick re-dispatches.

   SIM / HARDWARE-GATED: no networked Zebra in dev, so _dispatchZpl fails fast; the worker
   records the failure lifecycle. Real-print certification is a deployment gate.
"""

from java.net import Socket, InetSocketAddress
from java.lang import String as JString
import java.lang
import time

_SYSTEM_NAME  = "Zebra"
_DEFAULT_PORT = 9100
_TIMEOUT_MS   = 4000
_MAX_ATTEMPTS = 3       # ENV-170/LBL-150: 3 attempts ...
_BACKOFF_MS   = 2000    # ... with a ~2s gap


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _sessionPrinter():
    try:
        custom = system.perspective.getSessionInfo()["custom"]
        return custom.get("printer") or {}
    except Exception as e:
        BlueRidge.Common.Util.log("_sessionPrinter failed: %s" % str(e), level="debug")
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
    """Log one dispatch attempt to Audit.InterfaceLog (every attempt: success/failure)."""
    ok = bool(outcome and outcome.get("ok"))
    params = {
        "systemName":       _SYSTEM_NAME,
        "direction":        "Outbound",
        "logEventTypeCode": "LabelDispatched",
        "description":      "Shipping label dispatch to %s" % (endpoint or "(none)"),
        "requestPayload":   "%s | %s" % (endpoint or "", (zpl or "")[:200]),
        "responsePayload":  "OK" if ok else None,
        "errorCondition":   None if ok else "DispatchFailed",
        "errorDescription": None if ok else (outcome.get("error") if outcome else "unknown"),
        "isHighFidelity":   True,
    }
    try:
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall", params)
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("_logDispatch failed: %s" % str(e), level="debug")


def _resolveShippingLabel(shippingLabelId):
    """Fetch the ShippingLabel row (incl persisted ZplContent) to dispatch, or None."""
    if shippingLabelId is None:
        return None
    return BlueRidge.Common.Db.execOne("lots/ShippingLabel_GetById",
                                       {"shippingLabelId": shippingLabelId})


def _resolveEndpoint(terminalLocationId, printerLocationId):
    """Resolve the Zebra endpoint: printer-card override first, else session printer,
       else the terminal's configured printer. Runs synchronously in dispatch() (caller
       scope) so the async worker only needs the resolved string."""
    pid = _u(printerLocationId)
    if pid is not None:
        printer = BlueRidge.Location.Printer.getById(pid) or {}
        return (printer.get("endpoint") or printer.get("Endpoint") or "").strip()
    printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    if not endpoint and terminalLocationId is not None:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId) or {}
        endpoint = (printer.get("endpoint") or "").strip()
    return endpoint


def _dispatchWorker(shippingLabelId, endpoint, zpl):
    """GATEWAY-ASYNC: the FULL retry policy for one dispatch = _MAX_ATTEMPTS socket writes
       w/ ~2s backoff (the FAT '3 attempts / 2s gap'), log each, then record the outcome.
       A worker cycle that exhausts all transport attempts IS terminal, so MarkDispatch is
       called with maxAttempts=1 -> a failed cycle stamps PrintFailedAt immediately (the
       operator sees the banner now, not after N stranded-sweep passes). The sweep only
       re-fires rows that never ran a cycle (a Gateway restart -- PrintFailedAt still NULL).
       Never throws (runs detached on a gateway thread)."""
    outcome = {"ok": False, "error": "not attempted"}
    try:
        for attempt in range(_MAX_ATTEMPTS):
            outcome = _dispatchZpl(endpoint, zpl)
            _logDispatch(endpoint, zpl, outcome)
            if outcome.get("ok"):
                break
            if attempt < _MAX_ATTEMPTS - 1:
                time.sleep(_BACKOFF_MS / 1000.0)
        BlueRidge.Common.Db.execMutation("lots/ShippingLabel_MarkDispatch", {
            "shippingLabelId": shippingLabelId,
            "success":         1 if outcome.get("ok") else 0,
            "errorText":       None if outcome.get("ok") else (outcome.get("error") or "unknown"),
            "maxAttempts":     1,
        })
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("_dispatchWorker failed for label %s: %s" % (shippingLabelId, str(e)), level="debug")


def dispatch(shippingLabelId=None, terminalLocationId=None, printerLocationId=None):
    """Dispatch a persisted container shipping label. Resolves the endpoint + reads the
       persisted ZplContent synchronously, then fires the 3x/backoff transport on a
       gateway-async thread so the UI never blocks. Returns {Status, Message} immediately;
       the ShippingLabel state (PrintedAt / PrintFailedAt) reflects the real outcome."""
    sid = _u(shippingLabelId)
    BlueRidge.Common.Util.log("dispatch shippingLabelId=%s printerLocationId=%s" % (sid, printerLocationId))
    row = _resolveShippingLabel(sid)
    if not row:
        return {"Status": 0, "Message": "Shipping label not found for dispatch."}
    sid = row.get("Id")
    zpl = row.get("ZplContent") or ""
    if not zpl:
        return {"Status": 0, "Message": "Shipping label has no rendered ZPL."}

    endpoint = _resolveEndpoint(terminalLocationId, printerLocationId)
    if not endpoint:
        return {"Status": 0, "Message": "No printer endpoint resolved for this label."}

    system.util.invokeAsynchronous(lambda: _dispatchWorker(sid, endpoint, zpl))
    return {"Status": 1, "Message": "Shipping label sent to printer."}
