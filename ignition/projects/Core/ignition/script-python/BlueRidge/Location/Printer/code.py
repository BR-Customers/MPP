"""BlueRidge.Location.Printer - Printer Location helpers.

   validateEndpoint(endpoint, connectionKind) performs a gateway-side
   reachability probe of a networked printer's Endpoint, surfaced as a
   "valid endpoint" notification in the config app (FAT #14).

   Design:
     - Hardwired printers (Endpoint is an OS/print-queue NAME, not an
       IP:port) are NOT reachable from the config app -> return a neutral
       "cannot validate here" result. A hardwired printer is NEVER reported
       invalid.
     - Networked printers are probed with a short TCP connect to the
       Endpoint host:port (default 9100 = Zebra RAW/ZPL). A successful
       connect means the print server is accepting connections.

   This is an infrastructure probe (socket IO), not domain logic.

   Change Log:
       2026-08-05 - Initial version (FAT #14 printer endpoint validation)."""

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


def validateEndpoint(endpoint, connectionKind=None):
    """Probe a printer Endpoint for reachability.

       connectionKind: 'Networked' | 'Hardwired' | None/'' (treated as the
                       'Networked' default, matching the attribute DefaultValue).

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
        return {"status": None, "level": "warning", "title": "No endpoint",
                "message": "Set the Endpoint (IP:port) before validating."}

    host, port = _parseHostPort(ep)
    if not host:
        return {"status": False, "level": "error", "title": "Invalid endpoint",
                "message": "Could not parse a host from '%s'. Expected IP:port." % ep}

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
    endpoint = ""
    kind = ""
    for r in rows:
        r = r or {}
        name = r.get("name")
        if name == "Endpoint":
            endpoint = r.get("value") or r.get("defaultValue") or ""
        elif name == "ConnectionKind":
            kind = r.get("value") or r.get("defaultValue") or ""
    return validateEndpoint(endpoint, kind)


def getById(printerLocationId):
    """Resolve one Printer (by its own LocationId) + Endpoint/Model/ConnectionKind.
       Returns a dict, or {} when the id is not an active printer."""
    pid = BlueRidge.Common.Util.extractQualifiedValues(printerLocationId)
    if pid is None:
        return {}
    return BlueRidge.Common.Db.execOne("location/Printer_GetById", {"printerLocationId": pid}) or {}
