"""BlueRidge.Lots.ShippingDispatcher - container shipping-label ZPL dispatch (Arc 2 Phase 6).

   Renders a shipping-label ZPL from the claimed Honda AIM Shipper ID + synchronously
   dispatches it to the terminal's Zebra (raw TCP 9100), logging every attempt to
   Audit.InterfaceLog. Mirrors the LotLabel LTT dispatcher transport.

   SIM / HARDWARE-GATED: there is no networked Zebra in dev, so dispatch fails-fast +
   logs (it never rolls back the completed container -- complete + print are separate
   steps). The ShippingLabel.PrintedAt / PrintFailedAt write-back + the stranded-print
   safety sweep + reprint/void are the Phase 7 print-failure lifecycle.
"""
import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Location.Terminal

from java.net import Socket, InetSocketAddress
from java.lang import String as JString

_SYSTEM_NAME = "Zebra"
_DEFAULT_PORT = 9100
_TIMEOUT_MS = 4000


def _sessionPrinter():
    try:
        custom = system.perspective.getSessionInfo()["custom"]
        return custom.get("printer") or {}
    except Exception as e:
        BlueRidge.Common.Util.log("_sessionPrinter failed: %s" % str(e), level="debug")
        return {}


def _renderZpl(aimShipperId):
    """Minimal container shipping label: Honda AIM Shipper ID as a Code-128 barcode."""
    sid = aimShipperId or ""
    return ("^XA^CF0,40^FO40,40^FDHonda AIM Shipper^FS"
            "^FO40,110^BY3^BCN,140,Y,N,N^FD%s^FS^XZ" % sid)


def _dispatchZpl(endpoint, zpl):
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
    except Exception as e:
        BlueRidge.Common.Util.log("_logDispatch failed: %s" % str(e), level="debug")


def dispatch(aimShipperId, terminalLocationId=None):
    """Render + synchronously dispatch a container shipping label for a claimed AIM
       Shipper ID. Returns {Status, Message}. Fails-fast (no container rollback) when no
       printer is configured for the terminal."""
    BlueRidge.Common.Util.log("dispatch aimShipperId=%s" % aimShipperId)
    printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    if not endpoint and terminalLocationId is not None:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId) or {}
        endpoint = (printer.get("endpoint") or "").strip()

    zpl = _renderZpl(aimShipperId)
    if not endpoint:
        return {"Status": 0, "Message": "This terminal has no printer configured."}

    outcome = _dispatchZpl(endpoint, zpl)
    _logDispatch(endpoint, zpl, outcome)
    if outcome.get("ok"):
        return {"Status": 1, "Message": "Shipping label printed."}
    return {"Status": 0, "Message": "Print failed: %s." % (outcome.get("error") or "unknown")}
