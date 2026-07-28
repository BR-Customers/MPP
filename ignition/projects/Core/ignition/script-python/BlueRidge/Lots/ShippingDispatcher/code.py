"""BlueRidge.Lots.ShippingDispatcher - container shipping-label ZPL dispatch (Arc 2 Phase 6).

   Renders a shipping-label ZPL from the claimed Honda AIM Shipper ID + synchronously
   dispatches it to the terminal's printer, logging every attempt to Audit.InterfaceLog.

   This module owns ORCHESTRATION only. Transport lives in BlueRidge.Lots.LabelTransport
   -- shared with the LotLabel LTT path -- which picks raw TCP or a Windows print queue
   from the endpoint's syntax (design 2026-07-28). A networked Zebra and a USB printer
   shared from a terminal PC are both reachable; neither is named here.

   HARDWARE-GATED: with no printer configured, dispatch fails-fast + logs (it never rolls
   back the completed container -- complete + print are separate steps). The
   ShippingLabel.PrintedAt / PrintFailedAt write-back + the stranded-print safety sweep +
   reprint/void are the Phase 7 print-failure lifecycle.
"""
import BlueRidge.Common.Db
import BlueRidge.Common.Util
import BlueRidge.Lots.LabelTransport
import BlueRidge.Location.Terminal


def _sessionPrinter():
    try:
        custom = system.perspective.getSessionInfo()["custom"]
        return custom.get("printer") or {}
    except Exception as e:
        BlueRidge.Common.Util.log("_sessionPrinter failed: %s" % str(e), level="debug")
        return {}


def _renderZpl(aimShipperId):
    """LEGACY minimal container shipping label: Honda AIM Shipper ID as a Code-128
       barcode. Kept for the bare dispatch() path; real labels use dispatchContainer()."""
    sid = aimShipperId or ""
    return ("^XA^CF0,40^FO40,40^FDHonda AIM Shipper^FS"
            "^FO40,110^BY3^BCN,140,Y,N,N^FD%s^FS^XZ" % sid)


def _renderContainerLabel(fields):
    """Render the Honda container shipping label from a fields dict
       (Lots.Container_GetLabelData shape). The ZPL body comes from the ACTIVE
       'Container' Lots.LabelTemplate row -- NOT a Python constant (FDS sec 2064:
       templates SHALL be configurable). Honda-specific tokens (PartExt, PartLevel,
       Auditor) render blank until sourced. Returns the ZPL, or None when no active
       Container template exists."""
    f = BlueRidge.Common.Util.extractQualifiedValues(fields) or {}
    template = None
    for r in (BlueRidge.Common.Db.execList("lots/LabelTemplate_GetActiveByTypeCode",
                                           {"labelTypeCode": "Container"}) or []):
        template = r.get("ZplBody")
        break
    if not template:
        return None
    subs = {
        "PartNumber":      f.get("PartNumber") or "",
        "PartExt":         f.get("PartExt") or "",
        "Description":     f.get("Description") or "",
        "MfgLotNumber":    f.get("MfgLotNumber") or "",
        "MfgDate":         f.get("MfgDate") or "",
        "Auditor":         f.get("Auditor") or "",
        "PartLevel":       f.get("PartLevel") or "",
        "Quantity":        "%s" % (f.get("Quantity") or ""),
        "Serial":          f.get("Serial") or "",
        "CountryOfOrigin": f.get("CountryOfOrigin") or "",
    }
    zpl = template
    for k, v in subs.items():
        zpl = zpl.replace("{%s}" % k, v)
    return zpl


def dispatch(aimShipperId, terminalLocationId=None):
    """Render + synchronously dispatch a container shipping label for a claimed AIM
       Shipper ID. Returns {Status, Message}. Fails-fast (no container rollback) when no
       printer is configured for the terminal."""
    BlueRidge.Common.Util.log("dispatch aimShipperId=%s" % aimShipperId)
    printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId, "Container") or {}
    if not (printer.get("endpoint") or "").strip():
        printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()

    zpl = _renderZpl(aimShipperId)
    if not endpoint:
        return {"Status": 0, "Message": "This terminal has no printer configured."}

    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "Shipping label")
    if outcome.get("ok"):
        return {"Status": 1, "Message": "Shipping label printed."}
    return {"Status": 0, "Message": "Print failed: %s." % (outcome.get("error") or "unknown")}


def dispatchContainer(containerId, terminalLocationId=None, shippingLabelId=None):
    """Render the Honda container shipping label from the container's data and
       synchronously dispatch it. Fields resolve via Lots.Container_GetLabelData;
       Honda-specific fields render blank until sourced. When shippingLabelId is
       given, the outcome is written back via Lots.ShippingLabel_RecordDispatch.
       Returns {Status, Message}. Fails-fast (NO container rollback) when the
       terminal has no printer -- complete and print are separate steps."""
    BlueRidge.Common.Util.log("dispatchContainer containerId=%s" % containerId)

    def _writeBack(ok, errorText):
        if shippingLabelId is None:
            return
        try:
            BlueRidge.Common.Db.execMutation(
                "lots/ShippingLabel_RecordDispatch",
                {"shippingLabelId": shippingLabelId, "success": ok, "errorText": errorText})
        except:
            pass

    from java.lang import Throwable

    try:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId, "Container") or {}
        if not (printer.get("endpoint") or "").strip():
            printer = _sessionPrinter()
        endpoint = (printer.get("endpoint") or "").strip()
        if not endpoint:
            msg = "This terminal has no printer configured."
            _writeBack(False, msg)
            return {"Status": 0, "Message": msg}

        fields = BlueRidge.Common.Db.execOne("lots/Container_GetLabelData", {"containerId": containerId})
        if not fields:
            msg = "Container %s not found." % containerId
            _writeBack(False, msg)
            return {"Status": 0, "Message": msg}

        zpl = _renderContainerLabel(fields)
        if not zpl:
            msg = "No active Container label template."
            _writeBack(False, msg)
            return {"Status": 0, "Message": msg}

        outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
        BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "Shipping label")
        if outcome.get("ok"):
            _writeBack(True, None)
            return {"Status": 1, "Message": "Container label printed."}
        err = outcome.get("error") or "unknown"
        _writeBack(False, err)
        return {"Status": 0, "Message": "Print failed: %s." % err}
    except Throwable as t:
        msg = t.getMessage() or str(t)
        _writeBack(False, msg)
        return {"Status": 0, "Message": "Print failed: %s." % msg}
    except Exception as e:
        _writeBack(False, str(e))
        return {"Status": 0, "Message": "Print failed: %s." % str(e)}
