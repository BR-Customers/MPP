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

   SIM / HARDWARE-GATED: no networked Zebra in dev, so transport dispatch fails fast; the
   worker records the failure lifecycle. Real-print certification is a deployment gate.

   2026-08-20: the per-attempt transport used to be a private raw-TCP-only _dispatchZpl
   here, predating BlueRidge.Lots.LabelTransport and never migrated -- a Hardwired
   (print-queue) printer endpoint would fail every attempt with UnknownHostException
   (same bug fixed in BlueRidge.Lots.LotLabel same day). Now delegates to LabelTransport,
   the one place ZPL bytes are meant to leave the Gateway (see that module's header).
"""

import java.lang
import time

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
            outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
            BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "Shipping label")
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
