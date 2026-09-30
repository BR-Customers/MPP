"""BlueRidge.Location.Printer - Printer Location helpers.

   validateEndpoint(endpoint, connectionKind) performs a gateway-side
   reachability probe of a networked printer's Endpoint, surfaced as a
   "valid endpoint" notification in the config app (FAT #14).

   Design:
     - Hardwired printers (Endpoint is an OS/print-queue NAME, not an
       IP:port) are NOT reachable from the config app -> return a neutral
       "cannot validate here" result. A hardwired printer is NEVER reported
       invalid.
     - Networked printers are probed with a short TCP connect that sends ZERO
       bytes (PROTOCOL.md's "(no bytes at all)" request), so the check can never
       consume a label on a real Zebra. A successful connect means the print
       server is accepting connections.
     - UsbBridge printers get the full ?STATUS probe, so the result names the
       Windows queue the bridge is actually BOUND to. A connect alone cannot see
       that, and a wrong queue binding is a real failure mode: on 2026-09-29 the
       bridge was started with no argument, bound the default queue, passed a
       connect test, and no label ever printed.

   This module derives NOTHING. A UsbBridge printer's endpoint is composed by
   Location.ufn_PrinterEndpoint from the parent terminal's IpAddress and arrives
   already resolved in Printer_GetById's Endpoint column. Keeping the rule in one
   SQL function is why ShippingDispatcher, LotLabel and Terminal.applyToSession
   needed no change at all.

   This is an infrastructure probe (socket IO), not domain logic.

   Change Log:
       2026-08-05 - Initial version (FAT #14 printer endpoint validation).
       2026-09-30 - UsbBridge branch issues ?STATUS; testPrinter /
                    testFromSelection added for the Config Tool button."""

import java.lang
import java.net as _jnet


_DEFAULT_ZEBRA_PORT = 9100      # Zebra RAW/ZPL listener
_CONNECT_TIMEOUT_MS = 2000


def _parseHostPort(endpoint):
    """Split 'host:port' -> (host, port). Bare 'host' -> (host, 9100).
       Returns (None, None) when no host can be parsed. IPv6 in [..]:port
       form is supported (bracketed host)."""
    s = ("%s" % (endpoint or "")).strip()
    if not s:
        return (None, None)
    # Bracketed IPv6: [::1]:9100  or  [::1]
    if s.startswith("["):
        close = s.find("]")
        if close == -1:
            return (None, None)
        host = s[1:close]
        rest = s[close + 1:]
        if rest.startswith(":"):
            try:
                return (host, int(rest[1:]))
            except (ValueError, TypeError):
                return (host, _DEFAULT_ZEBRA_PORT)
        return (host, _DEFAULT_ZEBRA_PORT)
    # host:port (split on the LAST colon so bare IPv6 without a port still works)
    if s.count(":") == 1:
        host, _, port = s.rpartition(":")
        try:
            return (host, int(port))
        except (ValueError, TypeError):
            return (s, _DEFAULT_ZEBRA_PORT)
    # no colon, or multiple colons (bare IPv6) -> host only, default port
    return (s, _DEFAULT_ZEBRA_PORT)


def _kindOrDefault(kind):
    """Normalize a ConnectionKind. An absent value reads as 'Networked', which is
       the attribute's own DefaultValue -- the same default Location.
       ufn_PrinterEndpoint and Location.Location_SaveAll apply, so the three
       layers agree. Self-contained so the tests can exec it."""
    k = ("%s" % (kind or "")).strip()
    return k or "Networked"


def _draftPrinterFields(rows):
    """Pull (Endpoint, ConnectionKind) out of already-decoded plain attribute
       dicts. Takes PLAIN dicts, not the view wrapper, so it is self-contained
       and testable; callers do the unwrap. Missing keys read as ''. Returns the
       RAW values (no default applied) so a caller can tell 'unset' from
       'Networked'."""
    endpoint = ""
    kind = ""
    for r in (rows or []):
        r = r or {}
        name = r.get("name")
        if name == "Endpoint":
            endpoint = r.get("value") or r.get("defaultValue") or ""
        elif name == "ConnectionKind":
            kind = r.get("value") or r.get("defaultValue") or ""
    return ("%s" % endpoint, "%s" % kind)


def _describeBridgeResult(host, port, probe):
    """Turn a LabelTransport.probeStatus result into the toast shape.
       Self-contained (no BlueRidge.*, no java) so the tests can exec it.

       The four failures are DELIBERATELY different sentences, because each sends
       a person to a different place. Collapsing them into one 'printer offline'
       is what cost most of 2026-09-29: 'Connect timed out' (firewall) and
       'Connection refused' (service down) are the distinction that found the
       real fault, and a bridge that ANSWERED proves the network, so a wrong
       queue name must not read as a connectivity problem."""
    target = "%s:%d" % (host, port)
    if not probe.get("reached"):
        return {"status": False, "level": "error", "title": "Bridge unreachable",
                "message": "Nothing answered at %s (%s). Check MesZebraBridge is running "
                           "on the terminal PC and that its inbound rule for TCP %d allows "
                           "the Gateway. 'Connection refused' means the service is down; "
                           "'Connect timed out' means packets are being dropped."
                           % (target, probe.get("error") or "unknown", port)}
    if not probe.get("isBridge"):
        return {"status": False, "level": "warning", "title": "Not the bridge",
                "message": "%s accepted the connection but did not answer ?STATUS. That is "
                           "a raw printer or another service on this port, not "
                           "MesZebraBridge -- a connect test passes in this state and a "
                           "label still never prints." % target}
    if probe.get("error"):
        return {"status": False, "level": "error", "title": "Bridge refused",
                "message": "The bridge at %s answered: %s. The network is fine and the "
                           "queue name is wrong -- fix it on that PC, not here."
                           % (target, probe.get("error"))}
    if not probe.get("ready"):
        return {"status": False, "level": "error", "title": "Queue not ready",
                "message": "Bridge %s at %s is bound to queue '%s', which reports NOT ready "
                           "(%s job(s) queued). Check the queue exists on that PC and is "
                           "online." % (probe.get("bridge") or "?", target,
                                        probe.get("queue") or "(none)", probe.get("jobs"))}
    return {"status": True, "level": "success", "title": "Printer ready",
            "message": "Bridge %s at %s, bound to queue '%s', ready, %s job(s) queued. "
                       "No label was consumed." % (probe.get("bridge") or "?", target,
                                                   probe.get("queue") or "(none)",
                                                   probe.get("jobs"))}


def _withSource(message, row):
    """Append where the endpoint came from. Self-contained so the tests can exec it.

       This line is not decoration. A UsbBridge printer stores NO endpoint, so
       without it the message names a host that appears nowhere on the printer
       row and nobody typed -- which is exactly the confusion the derivation is
       meant to remove."""
    r = row or {}
    src = r.get("EndpointSource") or ""
    if src == "derived-terminal-ip":
        return "%s  Endpoint derived from the parent terminal's IpAddress (%s) plus port 9100." % (
            message, r.get("TerminalIpAddress") or "?")
    if src == "unresolved":
        return "%s  No endpoint could be resolved: ConnectionKind '%s', stored endpoint '%s', terminal IpAddress '%s'." % (
            message, r.get("ConnectionKind") or "(unset)",
            r.get("StoredEndpoint") or "", r.get("TerminalIpAddress") or "")
    return "%s  Endpoint is stored on the printer." % message


def validateEndpoint(endpoint, connectionKind=None):
    """Probe a printer Endpoint for reachability.

       connectionKind: 'Networked' | 'Hardwired' | 'UsbBridge' | None/'' (treated
                       as the 'Networked' default, matching the attribute
                       DefaultValue).

       Networked  -- bare TCP connect, sends ZERO bytes (PROTOCOL.md's "(no bytes
                     at all)" request), so it can never consume a label.
       Hardwired  -- never reported invalid; a queue name is not reachable here.
       UsbBridge  -- connect and issue ?STATUS, so the result names the queue the
                     bridge is actually BOUND to. The endpoint arrives already
                     derived from the parent terminal's IpAddress by
                     Location.ufn_PrinterEndpoint; this function derives nothing.

       Returns a dict {status, level, title, message}:
         status True  -> reachable        (level 'success')
         status False -> not reachable    (level 'error')
         status None  -> not validated    (level 'info' / 'warning')
       The shape maps 1:1 onto Common.Notify.toast(title, message, level)."""
    ep   = "%s" % (BlueRidge.Common.Util.extractQualifiedValues(endpoint) or "")
    kind = ("%s" % (BlueRidge.Common.Util.extractQualifiedValues(connectionKind) or "")).strip()
    ep   = ep.strip()
    BlueRidge.Common.Util.log("endpoint=%r kind=%r" % (ep, kind))

    # Hardwired printers cannot be reached from the config app -> never fail them.
    if kind == "Hardwired":
        return {"status": None, "level": "info", "title": "Cannot validate here",
                "message": "Hardwired printer '%s' is a print-queue name; reachability "
                           "cannot be checked from the config app." % (ep or "(unset)")}

    if not ep:
        # For a UsbBridge printer the endpoint should have been DERIVED by SQL, so
        # an empty one is a different fault from a Networked printer nobody has
        # addressed yet -- and it is fixed on the TERMINAL, not here.
        if kind == "UsbBridge":
            return {"status": False, "level": "error", "title": "No endpoint derived",
                    "message": "This USB-bridge printer has no endpoint. Its host comes from "
                               "the parent terminal's IpAddress attribute -- set that on the "
                               "TERMINAL as a bare address (no http://), then test again."}
        return {"status": None, "level": "warning", "title": "No endpoint",
                "message": "Set the Endpoint (IP:port) before validating."}

    host, port = _parseHostPort(ep)
    if not host:
        return {"status": False, "level": "error", "title": "Invalid endpoint",
                "message": "Could not parse a host from '%s'. Expected IP:port." % ep}

    # A UsbBridge endpoint is OUR service, so ask it what it is bound to. A connect
    # alone proves something answered; on 2026-09-29 the bridge was started with no
    # argument and bound the DEFAULT queue -- a connect test passes in that state and
    # a label still never prints (design sec 1 / 9).
    if kind == "UsbBridge":
        probe = BlueRidge.Lots.LabelTransport.probeStatus(host, port)
        return _describeBridgeResult(host, port, probe)

    # Networked: bare connect, sending ZERO bytes. That is PROTOCOL.md's
    # "(no bytes at all)" request and it is why this check has never wasted a
    # label. A real Zebra on raw 9100 would receive any bytes we wrote, so the
    # probe is deliberately NOT used here.
    sock = None
    try:
        sock = _jnet.Socket()
        sock.connect(_jnet.InetSocketAddress(host, port), _CONNECT_TIMEOUT_MS)
        return {"status": True, "level": "success", "title": "Valid endpoint",
                "message": "Reachable: %s:%d is accepting connections." % (host, port)}
    except (Exception, java.lang.Exception) as e:
        return {"status": False, "level": "error", "title": "Endpoint unreachable",
                "message": "Could not connect to %s:%d (%s)." % (host, port, type(e).__name__)}
    finally:
        try:
            if sock is not None:
                sock.close()
        except (Exception, java.lang.Exception):
            pass


def validateFromAttributes(attributes):
    """Config-app entry point: pull Endpoint + ConnectionKind out of a Location
       editDraft.attributes list (as edited in the Plant Hierarchy) and validate.

       `attributes` arrives view-wrapped; round-trip through the project JSON
       helper to plain dicts (extractQualifiedValues alone does not unwrap every
       wrapper type). Returns the validateEndpoint result dict, ready to hand
       straight to Common.Notify.toast(title, message, level)."""
    rows = system.util.jsonDecode(
        BlueRidge.Common.Util.convertWrapperObjectToJson(attributes)) or []
    endpoint, kind = _draftPrinterFields(rows)
    return validateEndpoint(endpoint, kind)


def getById(printerLocationId):
    """Resolve one Printer (by its own LocationId) + Endpoint/Model/ConnectionKind.
       Returns a dict, or {} when the id is not an active printer."""
    pid = BlueRidge.Common.Util.extractQualifiedValues(printerLocationId)
    if pid is None:
        return {}
    return BlueRidge.Common.Db.execOne("location/Printer_GetById", {"printerLocationId": pid}) or {}


def testPrinter(printerLocationId):
    """Config Tool 'Test printer' (design sec 9 step 1). Reads the SAVED printer
       row and probes it.

       Location.Printer_GetById already resolves the endpoint -- deriving it from
       the parent terminal's IpAddress for ConnectionKind = UsbBridge -- so this
       function derives NOTHING and holds no knowledge of what UsbBridge means.
       That is the point: one resolver, in SQL, and every caller reads the same
       answer.

       Proves route, firewall, service AND queue binding in one call with no
       label consumed. Without it the only test is manufacturing a real
       container, which on 2026-09-29 took ten component LOTs, two purchased-part
       LOTs and a temporarily shrunk container configuration -- per printer.

       Returns {status, level, title, message}, ready for
       Common.Notify.toast(title, message, level)."""
    row = getById(printerLocationId)
    if not row:
        return {"status": False, "level": "error", "title": "Printer not found",
                "message": "No active Printer location with that id."}
    res = validateEndpoint(row.get("Endpoint"), row.get("ConnectionKind"))
    return {"status":  res["status"],
            "level":   res["level"],
            "title":   res["title"],
            "message": _withSource(res["message"], row)}


def testFromSelection(printerLocationId, attributes):
    """Plant Hierarchy button entry point: the selected Location's id plus the
       open editDraft attribute rows.

       The test reads the SAVED row, because that is what the Gateway will dial.
       So an unsaved edit to Endpoint or ConnectionKind would test something the
       operator is not looking at -- which is worse than refusing, because it
       reads as a pass. Say so plainly instead."""
    pid = BlueRidge.Common.Util.extractQualifiedValues(printerLocationId)
    if pid is None:
        return {"status": None, "level": "info", "title": "Save first",
                "message": "Save this printer before testing -- the test reads the saved "
                           "configuration."}
    row = getById(pid)
    if not row:
        return {"status": False, "level": "error", "title": "Printer not found",
                "message": "No active Printer location with id %s." % pid}

    rows = system.util.jsonDecode(
        BlueRidge.Common.Util.convertWrapperObjectToJson(attributes)) or []
    draftEndpoint, draftKind = _draftPrinterFields(rows)
    savedEndpoint = "%s" % (row.get("StoredEndpoint") or "")
    savedKind     = "%s" % (row.get("ConnectionKind") or "")
    if (draftEndpoint.strip() != savedEndpoint.strip()
            or _kindOrDefault(draftKind) != _kindOrDefault(savedKind)):
        return {"status": None, "level": "info", "title": "Unsaved changes",
                "message": "Save your changes first. A test reads the saved configuration, "
                           "which is currently %s / %s."
                           % (_kindOrDefault(savedKind),
                              savedEndpoint or "no stored endpoint")}
    return testPrinter(pid)
