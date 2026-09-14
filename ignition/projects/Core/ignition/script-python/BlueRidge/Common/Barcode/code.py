# =============================================================================
# Project Library:  BlueRidge.Common.Barcode
#
# Author:           Blue Ridge Automation
# Created:          2026-09-13
# Version:          1.0
#
# Description:
#   Router for the Perspective SESSION barcode event. A camera scan on a mobile
#   device does NOT come back to the component that asked for it -- Perspective
#   fires ONE session-level event for the whole project:
#
#       MPP/com.inductiveautomation.perspective/barcode/onBarcodeDataReceived.py
#
#   so every scanning screen in the app lands in the same function. This module
#   is the dispatcher that gets each scan back to the field that asked for it.
#
# How a scan reaches here (verified against the 8.3.5 client bundle + a real
# scan on 2026-09-13):
#   1. A component carries a "native/barcode" EVENT ACTION. Its config is
#      {"config": {cameraPreference, type, backgroundColor, uuid},
#       "context": {... anything you like ...}}.
#   2. Firing it calls window.__mobileInterface.launchAction(...). That bridge
#      exists ONLY in the Ignition Perspective App -- in a plain mobile browser
#      the client logs "Native mobile action requested in non-mobile client.
#      Action request ignored!" and nothing happens. Camera scanning is an
#      App-only capability; a browser needs a keyboard-wedge scanner instead.
#   3. The App returns the scan to the session event as
#      data    = {"barcodeType": "qrcode", "text": "<the payload>",
#                 "timestamp": 1789351139952}
#      context = whatever the action's "context" carried, echoed back verbatim.
#
#   CONTEXT IS THE ROUTING KEY. It is the only thing that distinguishes "the
#   operator scanned an LTT on the cutover screen" from any other scan in the
#   app, so every native/barcode action SHALL carry:
#
#       {"screen": "<screen key>", "field": "<field key>"}
#
#   An action with no context is not an error -- it is logged and dropped,
#   because silently writing a stray scan into whatever field happened to be
#   last is worse than ignoring it.
#
# Public surface:
#   onScan(session, data, context) -> {"Status", "Message"}
#
# Layer:
#   session barcode event (one-liner)
#     -> BlueRidge.Common.Barcode.onScan          (this module: routing only)
#       -> BlueRidge.<Screen>.<Module>.applyScan  (per-screen state write)
#   No domain logic here -- this module decides WHERE a scan goes, never what
#   it means.
#
# Change Log:
#   2026-09-13 - 1.0 - Initial version.
# =============================================================================

import java.lang


# screen key -> the function that applies a scan for that screen.
# Resolved lazily inside onScan (a module-level reference would bind at import
# time, before the target module is loaded).
_SCREENS = ("cutover",)


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def _text(data):
    """The scanned payload. `data` arrives as a mapping with barcodeType / text
       / timestamp; tolerate a bare string in case a future client or a
       simulate() call hands one over."""
    d = _u(data)
    if d is None:
        return ""
    if isinstance(d, basestring):
        return d.strip()
    try:
        return (d.get("text") or "").strip()
    except (Exception, java.lang.Exception):
        return ""


def _ctx(context):
    """(screen, field) off the echoed-back context, both lowercased-safe
       strings. ('', '') when the action carried no context."""
    c = _u(context)
    if c is None:
        return "", ""
    try:
        return (c.get("screen") or ""), (c.get("field") or "")
    except (Exception, java.lang.Exception):
        return "", ""


def onScan(session, data, context):
    """Route one native/barcode scan. Called as a one-liner from the session
       barcode event. Never raises: a throw here happens on the gateway with no
       UI attached, so it would be invisible to the operator and would leave
       the scan silently lost."""
    try:
        text = _text(data)
        screen, field = _ctx(context)
        BlueRidge.Common.Util.log(
            "scan screen=%s field=%s len=%d" % (screen, field, len(text)))

        if not text:
            return {"Status": 0, "Message": "Empty scan ignored."}
        if not screen:
            # Almost always a native/barcode action authored without a context
            # object. Say so explicitly -- the symptom otherwise is "scanning
            # does nothing" with a perfectly healthy-looking log line.
            BlueRidge.Common.Util.log(
                "scan DROPPED: the action carried no context.screen. Give the "
                "native/barcode action a context of "
                "{\"screen\": \"...\", \"field\": \"...\"}.", level="warn")
            return {"Status": 0, "Message": "Scan had no routing context."}

        if screen == "cutover":
            return BlueRidge.Cutover.Scan.applyScan(session, text, field)

        BlueRidge.Common.Util.log(
            "scan DROPPED: no handler for screen '%s' (known: %s)"
            % (screen, ", ".join(_SCREENS)), level="warn")
        return {"Status": 0, "Message": "No handler for screen '%s'." % screen}
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("onScan FAILED: %s" % str(e), level="warn")
        return {"Status": 0, "Message": "Scan handling failed: %s" % str(e)}
