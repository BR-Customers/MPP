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
import BlueRidge.Lots.LabelTransport
import BlueRidge.Location.Terminal

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
    """LEGACY minimal container shipping label: Honda AIM Shipper ID as a Code-128
       barcode. Kept for the bare dispatch() path; real labels use dispatchContainer()."""
    sid = aimShipperId or ""
    return ("^XA^CF0,40^FO40,40^FDHonda AIM Shipper^FS"
            "^FO40,110^BY3^BCN,140,Y,N,N^FD%s^FS^XZ" % sid)


# Honda container shipping label -- first pass (flattened from
# zebraPrinter/Label Template - Container.zpl; positions/fonts/lines preserved).
# The 10 mappable {tokens} are filled from Lots.Container_GetLabelData; the Honda-
# specific fields (part-# extension, D/C part level, auditor) render blank, and their
# un-sourced barcodes (2D DataMatrix, part-ext, part-level) are omitted for now.
# ^PQ2 = 2 copies per the source label.
_CONTAINER_TEMPLATE = (
    "^XA^POI"
    "^A0R,24,26^FO740,20^FDPART NO. (P)^FS"
    "^A0R,86,86^FO690,200^FD{PartNumber}^FS"
    "^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS"
    "^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS"
    "^A0R,72,72^FO480,70^FD{PartExt}^FS"
    "^A0R,24,24^FO550,670^FDDESCRIPTION^FS"
    "^A0R,45,36^FO500,670^FD{Description}^FS"
    "^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS"
    "^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS"
    "^A0R,24,24^FO460,1070^FDMFG DATE^FS"
    "^A0R,45,36^FO410,1070^FD{MfgDate}^FS"
    "^A0R,24,24^FO460,940^FDAUDIT^FS"
    "^A0R,45,36^FO420,940^FD{Auditor}^FS"
    "^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS"
    "^A0R,72,72^FO300,70^FD{PartLevel}^FS"
    "^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS"
    "^A0R,72,72^FO240,720^FD{Quantity}^FS"
    "^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS"
    "^A0R,24,24^FO190,20^FDSERIAL (1S)^FS"
    "^A0R,72,72^FO140,200^FD{Serial}^FS"
    "^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS"
    "^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS"
    "^A0R,24,24^FO20,220^FD{CountryOfOrigin}^FS"
    "^FO580,10^GB0,1300,3^FS"
    "^FO490,650^GB0,905,3^FS"
    "^FO400,10^GB0,1300,3^FS"
    "^FO220,10^GB0,1300,3^FS"
    "^FO220,650^GB360,0,3^FS"
    "^PQ2"
    "^XZ"
)


def _renderContainerLabel(fields):
    """Render the real container shipping label from a fields dict (Container_GetLabelData
       shape). Honda-specific tokens (PartExt, PartLevel, Auditor) default to blank."""
    f = BlueRidge.Common.Util.extractQualifiedValues(fields) or {}
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
    zpl = _CONTAINER_TEMPLATE
    for k, v in subs.items():
        zpl = zpl.replace("{%s}" % k, v)
    return zpl


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

    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "Shipping label")
    if outcome.get("ok"):
        return {"Status": 1, "Message": "Shipping label printed."}
    return {"Status": 0, "Message": "Print failed: %s." % (outcome.get("error") or "unknown")}


def dispatchContainer(containerId, terminalLocationId=None):
    """Render the REAL Honda container shipping label (first pass) from the container's
       data and synchronously dispatch it. Fields resolve via Lots.Container_GetLabelData;
       Honda-specific fields render blank until sourced. Returns {Status, Message}.
       Fails-fast (no rollback) when no printer is configured for the terminal."""
    BlueRidge.Common.Util.log("dispatchContainer containerId=%s" % containerId)
    printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    if not endpoint and terminalLocationId is not None:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId) or {}
        endpoint = (printer.get("endpoint") or "").strip()
    if not endpoint:
        return {"Status": 0, "Message": "This terminal has no printer configured."}

    fields = BlueRidge.Common.Db.execOne("lots/Container_GetLabelData", {"containerId": containerId})
    if not fields:
        return {"Status": 0, "Message": "Container %s not found." % containerId}

    zpl = _renderContainerLabel(fields)
    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "Shipping label")
    if outcome.get("ok"):
        return {"Status": 1, "Message": "Container label printed."}
    return {"Status": 0, "Message": "Print failed: %s." % (outcome.get("error") or "unknown")}
