"""BlueRidge.Lots.LabelTransport - the ONE place ZPL bytes leave the Gateway.

   Two transports, selected by the SYNTAX of the printer Endpoint string
   (design 2026-07-28 sec 2 / 3.1):

     10.20.30.40:9100                 -> raw TCP        (port MANDATORY)
     \\\\FLXWAPSRV1\\5A2 Machining Out  -> Windows queue   (UNC)
     Zebra GX420d (RAW)               -> Windows queue   (local to the Gateway)

   Requiring the port on TCP is what removes the ambiguity the old code had:
   it treated any colon-less string as hostname:9100, so a bare 'printer01'
   could equally have been a queue name and the code silently guessed.

   Deliberately dependency-free: no DB, no other BlueRidge module. The grammar
   is pure and testable on its own (tools/script-console-demos/
   label_transport_grammar.py). Java imports are lazy, inside the senders.

   Also owns dispatch LOGGING (logDispatch), so the LTT and shipping dispatchers do
   not carry near-identical copies that differ by one string. The grammar functions
   stay pure -- only logDispatch touches the DB.

   HARDWARE-GATED. TCP reaches a networked Zebra or a terminal running
   zebraPrinter/usb_tcp_bridge.py. The queue transport requires the queue to be
   installed on the GATEWAY host under the Gateway service account -- naming a
   UNC path is not by itself enough. Real-print certification is a deployment gate."""
import re

_SYSTEM_NAME = "Zebra"
_TIMEOUT_MS = 4000            # bounded connect + write (spec: 3-5 s)
# (.*) NOT (.+): an empty host must still MATCH here so the "host missing before
# port" guard below can reject ':9100'. With (.+) that input falls through to the
# rule-4 catch-all and is silently accepted as a print-QUEUE named ':9100', which
# then fails much later with a baffling "print queue not found" error.
_TCP_RE = re.compile(r"^(.*):(\d+)$")


def _parseEndpoint(endpoint):
    """Pure grammar. Returns {kind: 'tcp'|'queue'|'invalid', host, port, queue, reason}."""
    ep = (endpoint or "").strip()
    if not ep:
        return {"kind": "invalid", "host": None, "port": None, "queue": None,
                "reason": "empty endpoint"}
    # Rule 2 before rule 3: a UNC path is a queue even if it somehow ends in digits.
    if ep.startswith("\\\\"):
        return {"kind": "queue", "host": None, "port": None, "queue": ep, "reason": None}
    m = _TCP_RE.match(ep)
    if m:
        host = m.group(1).strip()
        port = int(m.group(2))
        if not host:
            return {"kind": "invalid", "host": None, "port": None, "queue": None,
                    "reason": "host missing before port in '%s'" % ep}
        if port < 1 or port > 65535:
            return {"kind": "invalid", "host": None, "port": None, "queue": None,
                    "reason": "port out of range in '%s'" % ep}
        return {"kind": "tcp", "host": host, "port": port, "queue": None, "reason": None}
    return {"kind": "queue", "host": None, "port": None, "queue": ep, "reason": None}


def describeEndpoint(endpoint):
    """Config-time validator. Pure, no side effects -- answers 'what will this string do?'
       from the Script Console before a printer is ever wired.
       Returns {transport, target, valid, reason}."""
    p = _parseEndpoint(endpoint)
    if p["kind"] == "tcp":
        return {"transport": "tcp", "target": "%s:%d" % (p["host"], p["port"]),
                "valid": True, "reason": None}
    if p["kind"] == "queue":
        return {"transport": "queue", "target": p["queue"], "valid": True, "reason": None}
    return {"transport": None, "target": None, "valid": False, "reason": p["reason"]}


def _unquote(text):
    """Undo PROTOCOL.md's value quoting: strip the single quotes, undouble any
       embedded quote. Self-contained -- no imports, so the tests can exec it."""
    t = (text or "").strip()
    if len(t) >= 2 and t[0] == "'" and t[-1] == "'":
        t = t[1:-1]
    return t.replace("''", "'")


def _parseAck(line):
    """Parse one bridge response line (PROTOCOL.md v1.0.0).

       Returns {acked, ok, queue, job, bytes, error}. acked is False when the
       far end said nothing -- a real networked Zebra never replies, and that
       is NOT a failure, so callers must not treat it as one."""
    out = {"acked": False, "ok": False, "queue": None,
           "job": None, "bytes": None, "error": None}
    text = (line or "").strip()
    if not text:
        return out
    out["acked"] = True
    if text[:4] == "ERR ":
        out["error"] = text[4:].strip()
        return out
    if text[:3] != "OK ":
        out["error"] = "unparseable bridge response: %s" % text
        return out
    out["ok"] = True
    rest = text[3:]
    # Split on spaces that are not inside a quoted value.
    parts, buf, inq = [], "", False
    for ch in rest:
        if ch == "'":
            inq = not inq
            buf += ch
        elif ch == " " and not inq:
            if buf:
                parts.append(buf)
            buf = ""
        else:
            buf += ch
    if buf:
        parts.append(buf)
    for p in parts:
        if "=" not in p:
            continue
        k, v = p.split("=", 1)
        if k == "queue":
            out["queue"] = _unquote(v)
        elif k in ("job", "bytes"):
            try:
                out[k] = int(v)
            except (TypeError, ValueError):
                out[k] = None
    return out


def _sendTcp(host, port, zpl):
    """Raw-TCP write of the ZPL bytes, bounded timeout. Returns {ok, error}.
       Catches Throwable FIRST: a socket failure is java.net.ConnectException, and
       Jython's `except Exception` does NOT catch java.lang.Throwable."""
    from java.net import Socket, InetSocketAddress
    from java.io import BufferedReader, InputStreamReader
    from java.lang import String as JString
    from java.lang import Throwable
    s = None
    try:
        s = Socket()
        s.connect(InetSocketAddress(host, port), _TIMEOUT_MS)
        s.setSoTimeout(_TIMEOUT_MS)
        out = s.getOutputStream()
        out.write(JString(zpl or "").getBytes("US-ASCII"))
        out.flush()
        # PROTOCOL.md "Framing": half-close so the bridge's read returns at once
        # instead of waiting out its idle timeout. Then read exactly one line.
        # A real networked Zebra never replies -- readLine() returns None on
        # timeout or EOF, which _parseAck reports as acked=False, NOT an error.
        try:
            s.shutdownOutput()
        except Throwable:
            pass
        line = None
        try:
            reader = BufferedReader(InputStreamReader(s.getInputStream(), "US-ASCII"))
            line = reader.readLine()
        except Throwable:
            line = None
        ack = _parseAck(line)
        if ack["acked"] and not ack["ok"]:
            return {"ok": False, "error": ack["error"], "ack": ack}
        return {"ok": True, "error": None, "ack": ack}
    except Throwable as t:
        return {"ok": False, "error": t.getMessage() or str(t), "ack": _parseAck(None)}
    except Exception as e:
        return {"ok": False, "error": str(e), "ack": _parseAck(None)}
    finally:
        try:
            if s is not None:
                s.close()
        except Throwable:
            pass
        except Exception:
            pass


def _sendQueue(queueName, zpl):
    """Write the ZPL bytes to a Windows print queue via javax.print, AUTOSENSE flavor
       so the ZPL passes through un-transformed. Returns {ok, error}.

       javax.print enumerates queues visible to the account running the JVM -- i.e.
       the Gateway service account. The not-found error names the queue AND lists what
       IS visible, because that is the error commissioning will read most often."""
    from javax.print import PrintServiceLookup, DocFlavor, SimpleDoc
    from javax.print.attribute import HashPrintRequestAttributeSet
    from java.lang import String as JString
    from java.lang import Throwable
    try:
        services = PrintServiceLookup.lookupPrintServices(None, None) or []
        target = None
        for svc in services:
            if svc.getName() == queueName:
                target = svc
                break
        if target is None:
            visible = ", ".join([svc.getName() for svc in services]) or "(none)"
            return {"ok": False,
                    "error": ("print queue not found: '%s'. The queue must be installed on the "
                              "Gateway host under the Gateway service account. Visible queues: %s"
                              % (queueName, visible)),
                    "ack": _parseAck(None)}
        doc = SimpleDoc(JString(zpl or "").getBytes("US-ASCII"),
                        DocFlavor.BYTE_ARRAY.AUTOSENSE, None)
        job = target.createPrintJob()
        # getattr because `print` is a Jython 2 keyword -- job.print(...) will not parse.
        getattr(job, "print")(doc, HashPrintRequestAttributeSet())
        return {"ok": True, "error": None, "ack": _parseAck(None)}
    except Throwable as t:
        return {"ok": False, "error": t.getMessage() or str(t), "ack": _parseAck(None)}
    except Exception as e:
        return {"ok": False, "error": str(e), "ack": _parseAck(None)}


def send(endpoint, zpl):
    """Dispatch ZPL to whichever transport the endpoint grammar selects.
       Returns {ok, error, transport}. NEVER raises -- an unusable endpoint comes
       back as {ok: False} so callers can log + surface it without a try block."""
    p = _parseEndpoint(endpoint)
    if p["kind"] == "tcp":
        out = _sendTcp(p["host"], p["port"], zpl)
        out["transport"] = "tcp"
        return out
    if p["kind"] == "queue":
        out = _sendQueue(p["queue"], zpl)
        out["transport"] = "queue"
        return out
    return {"ok": False, "error": p["reason"], "transport": None}


def _resolveLogParams(endpoint, via, labelKind):
    """Build the Audit.InterfaceLog row for the RESOLVE stage.

       Self-contained (no BlueRidge.* calls) so the tests can exec it.

       An unresolved endpoint used to write nothing at all: the dispatch worker
       never ran, so no transport row was ever attempted, and the label sat with
       PrintedAt and PrintFailedAt both NULL. A stage that can fail silently is
       worse than one that fails loudly."""
    ep = (endpoint or "").strip()
    if ep:
        return {
            "systemName":       _SYSTEM_NAME,
            "direction":        "Outbound",
            "logEventTypeCode": "LabelDispatched",
            "description":      "%s endpoint resolved via %s" % (labelKind, via or "unknown"),
            "requestPayload":   None,
            "responsePayload":  "Resolved %s via %s" % (ep, via or "unknown"),
            "errorCondition":   None,
            "errorDescription": None,
            "isHighFidelity":   False,
        }
    return {
        "systemName":       _SYSTEM_NAME,
        "direction":        "Outbound",
        "logEventTypeCode": "LabelDispatched",
        "description":      "%s endpoint could not be resolved" % labelKind,
        "requestPayload":   None,
        "responsePayload":  None,
        "errorCondition":   "EndpointUnresolved",
        "errorDescription": "No printer endpoint for this terminal (tried: %s)" % (via or "unknown"),
        "isHighFidelity":   True,
    }


def _dispatchLogParams(endpoint, zpl, outcome, labelKind):
    """Build the Audit.InterfaceLog row for ONE dispatch attempt.

       Self-contained (no BlueRidge.* calls) so the tests can exec it.

       The stage reached goes in responsePayload on success and in
       errorCondition on failure, so 'where did it stop' is one column and not
       a cross-reference. A bridge that ANSWERED with ERR is QueueRejected, not
       DispatchFailed -- the network was fine and the queue was wrong, and
       conflating those sends whoever is diagnosing it to the wrong place."""
    ok = bool(outcome and outcome.get("ok"))
    transport = (outcome or {}).get("transport") or "unknown"
    ack = (outcome or {}).get("ack") or {}
    if ok:
        if ack.get("acked") and ack.get("ok"):
            response = "Spooled queue='%s' job=%s bytes=%s" % (
                ack.get("queue"), ack.get("job"), ack.get("bytes"))
        else:
            response = "Sent, no ack (raw 9100)"
        condition, detail = None, None
    else:
        response = None
        if ack.get("acked"):
            condition = "QueueRejected"
        else:
            condition = "DispatchFailed"
        detail = (outcome or {}).get("error") or "unknown"
    return {
        "systemName":       _SYSTEM_NAME,
        "direction":        "Outbound",
        "logEventTypeCode": "LabelDispatched",
        "description":      "%s dispatch via %s to %s" % (labelKind, transport, endpoint or "(none)"),
        "requestPayload":   "%s | %s" % (endpoint or "", (zpl or "")[:200]),
        "responsePayload":  response,
        "errorCondition":   condition,
        "errorDescription": detail,
        "isHighFidelity":   True,
    }


def logResolve(endpoint, via, labelKind):
    """Log the resolve stage. Bare except for the same reason logDispatch has
       one: logging must never break a print."""
    try:
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall",
                                         _resolveLogParams(endpoint, via, labelKind))
    except:
        pass


def logDispatch(endpoint, zpl, outcome, labelKind):
    """Log ONE dispatch attempt to Audit.InterfaceLog -- every attempt: success,
       failure, retry (FDS-01-014). labelKind is the human label for the description,
       e.g. 'LTT' or 'Shipping label'. High-fidelity so endpoint, transport and the
       ZPL head persist; the transport name is what distinguishes a TCP failure from
       a queue failure in the audit trail without re-parsing the endpoint."""
    params = _dispatchLogParams(endpoint, zpl, outcome, labelKind)
    # audit/Audit_LogInterfaceCall is "UpdateQuery"-typed (the proc emits no result set),
    # so it MUST go through execNonQuery -- execList would hand _rowsToDicts an Integer
    # row count and throw. Bare except (not `except Exception`) because Jython's
    # `except Exception` does NOT catch java.lang.Throwable; logging must never
    # break dispatch.
    try:
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall", params)
    except:
        pass
