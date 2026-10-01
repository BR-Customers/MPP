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
   UNC path is not by itself enough. Real-print certification is a deployment gate.

   Also owns the ?STATUS PROBE (probeStatus), because it owns the socket and the
   ACK grammar. The probe prints nothing and is the basis of the Config Tool's
   Test printer action (design 2026-09-29 sec 4.2 / 9)."""
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

       Returns {acked, ok, queue, job, bytes, error, bridge, ready, jobs}.
       acked is False when the far end said nothing -- a real networked Zebra
       never replies, and that is NOT a failure, so callers must not treat it
       as one.

       ONE parser for both reply kinds. A print ACK sets job/bytes; a ?STATUS
       reply sets bridge/ready/jobs. They share this grammar, so a second copy
       would drift from the frozen protocol."""
    # bridge / ready / jobs are the ?STATUS keys (PROTOCOL.md section "?STATUS").
    # ready stays None when the line never stated it -- that is how a PRINT ack
    # ("OK queue=.. job=.. bytes=..") is told apart from a STATUS ack, and why it
    # is not defaulted to False.
    out = {"acked": False, "ok": False, "queue": None,
           "job": None, "bytes": None, "error": None,
           "bridge": None, "ready": None, "jobs": None}
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
        elif k == "bridge":
            out["bridge"] = _unquote(v)
        elif k == "ready":
            # PROTOCOL.md: "ready is true or false". Anything else is not ready,
            # which is the honest read of a value we do not understand.
            out["ready"] = (_unquote(v).strip().lower() == "true")
        elif k in ("job", "bytes", "jobs"):
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


def _describeProbe(outcome):
    """Classify one ?STATUS exchange. Self-contained (no BlueRidge.*, no java)
       so the tests can exec it.

       reached  -- the socket connected and the write completed
       isBridge -- the far end answered at all, so it speaks this protocol

       The three failure shapes are kept apart on purpose, because each sends
       whoever is commissioning to a different place:
         not reached            -> the service is down, or packets are dropped
         reached, not a bridge  -> something else owns 9100 on that PC, OR it is
                                   a real networked Zebra, which never replies
                                   (PROTOCOL.md 'Non-bridge printers')
         bridge answered ERR    -> right machine, wrong queue name
       Flattening these into one 'printer offline' was the 2026-09-29 cost."""
    out = outcome or {}
    ack = out.get("ack") or {}
    if not out.get("ok") and not ack.get("acked"):
        return {"reached": False, "isBridge": False, "bridge": None, "queue": None,
                "ready": None, "jobs": None, "error": out.get("error") or "unknown"}
    if not ack.get("acked"):
        return {"reached": True, "isBridge": False, "bridge": None, "queue": None,
                "ready": None, "jobs": None, "error": None}
    if not ack.get("ok"):
        return {"reached": True, "isBridge": True, "bridge": ack.get("bridge"),
                "queue": ack.get("queue"), "ready": False, "jobs": ack.get("jobs"),
                "error": ack.get("error") or "unknown"}
    return {"reached": True, "isBridge": True, "bridge": ack.get("bridge"),
            "queue": ack.get("queue"), "ready": bool(ack.get("ready")),
            "jobs": ack.get("jobs"), "error": None}


def operatorGuidance(errorCondition, errorDescription=None):
    """Translate a dispatch failure into something an operator at a station can
       act on. Self-contained (no BlueRidge.*, no java) so the tests can exec it.

       Returns {title, what, action, canSelfFix}:
         title      -- the headline, in the operator's words
         what       -- one sentence on what actually happened
         action     -- the NEXT STEP, not a description of the fault
         canSelfFix -- True when the operator can resolve it where they stand

       canSelfFix is the field that matters. Section 6.3's taxonomy exists so a
       diagnosis points at one machine; this turns that into "go do X". Telling
       an operator to check an endpoint configuration is the same as telling
       them nothing, and telling them to try again when the queue name is wrong
       just stacks labels nobody asked for.

       An unrecognised condition is NOT self-fixable: an empty or guessy dialog
       in front of someone holding a basket is worse than an honest 'fetch a
       supervisor'."""
    cond = ("%s" % (errorCondition or "")).strip()
    detail = ("%s" % (errorDescription or "")).strip()

    if cond == "QueueNotDraining":
        return {
            "title": "The printer is not taking labels",
            "what": "The label reached the printer's PC, but its queue is not emptying.",
            "action": "Check the printer is plugged in and powered on. The label will "
                      "print by itself once it is -- do not send it again.",
            "canSelfFix": True}

    if cond == "DispatchFailed":
        # Refused and timed out are the same condition and different faults.
        # An operator cannot act on the distinction, but the sentence they read
        # out to a supervisor is what makes the callout useful.
        if "refused" in detail.lower():
            what = ("The printer's PC answered, but the printing service on it is not "
                    "running.")
        elif "timed out" in detail.lower():
            what = ("The printer's PC did not answer at all -- it may be switched off or "
                    "off the network.")
        else:
            what = "The label could not be sent to the printer's PC."
        return {
            "title": "Cannot reach the printer",
            "what": what,
            "action": "Check the PC next to the printer is switched on. If it is, tell a "
                      "supervisor and read them this message.",
            "canSelfFix": True}

    if cond == "QueueRejected":
        return {
            "title": "The printer is set up wrong",
            "what": "The printer's PC answered and refused the label: %s"
                    % (detail or "it does not recognise its printer."),
            "action": "Tell a supervisor -- this needs fixing on that PC. Sending it "
                      "once more will not help.",
            "canSelfFix": False}

    if cond == "EndpointUnresolved":
        return {
            "title": "No printer set up for this station",
            "what": "This station has no printer configured, so nothing was sent.",
            "action": "Tell a supervisor. The station needs a printer assigned before "
                      "it can print.",
            "canSelfFix": False}

    return {
        "title": "The label did not print",
        "what": detail or "The reason was not recorded.",
        "action": "Tell a supervisor and read them this message.",
        "canSelfFix": False}


def probeStatus(host, port):
    """PROTOCOL.md section "?STATUS": connect, send the command, half-close, read
       one line. NO LABEL IS CONSUMED, so this is safe to call against a live
       printer's bridge at any time -- which is the whole point: it proves route,
       firewall, service and queue binding in one call, and that is what makes
       commissioning 54 printers tractable instead of manufacturing a real
       container per printer.

       Reuses _sendTcp because the PAYLOAD is the only difference between a print
       and a probe. The framing, the half-close, the bounded read and _parseAck
       are identical, and a second copy of them would drift from the frozen
       protocol. Never raises."""
    return _describeProbe(_sendTcp(host, port, "?STATUS"))


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
        # A routine resolve does not warrant payload retention, so this row is
        # low fidelity -- and Audit_LogInterfaceCall NULLs RequestPayload and
        # ResponsePayload unless IsHighFidelity = 1 (FRS 3.17.4). The endpoint
        # and the tier therefore go in the Description, which is always kept.
        # Setting a payload here would look informative and be discarded.
        return {
            "systemName":       _SYSTEM_NAME,
            "direction":        "Outbound",
            "logEventTypeCode": "LabelDispatched",
            "description":      "%s endpoint resolved via %s to %s" % (
                labelKind, via or "unknown", ep),
            "requestPayload":   None,
            "responsePayload":  None,
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
