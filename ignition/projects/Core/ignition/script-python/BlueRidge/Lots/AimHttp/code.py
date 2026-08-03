"""BlueRidge.Lots.AimHttp - the ONE place an AIM (Honda EDI) call leaves the Gateway.

   Verified contract (notes/2026-07-28_aim-interface-contract.md):
     POST {base}/mes/floor/{company}/{token}/nextserial.csv   body: CRLF CRLF
       -> 9-digit zero-padded serial + CRLF
     POST {base}/mes/floor/{company}/{token}/postserial.csv?<query>   body: EMPTY
       -> the same serial + CRLF on success

   The postserial payload rides in the QUERY STRING with an EMPTY body, and its
   delimiters are LITERAL BACKSLASH ESCAPE TEXT: %5C is a backslash, so %5Cr%5Cn is
   the two characters \\r\\n, NOT carriage-return/linefeed. Spaces are %20 (the
   embedded space in a customer part like '112006FB A000' is significant to AIM's
   lookup and must survive).

   DO NOT use system.net.httpClient(): it builds a java.net.URI which re-encodes the
   '%' in our already-encoded query, sending %255C. AIM then reads literal '%5C' text
   and the call fails silently-looking. java.net.URL performs no encoding - use it.

   Success detection is EXACT, not a length heuristic:
     nextSerial  -> trimmed reply is exactly 9 digits
     postSerial  -> trimmed reply EQUALS the serial we sent
   A reply beginning 'POST ' is the listener's unrecognized-request echo = rejected.

   Neither function raises. Both return an outcome dict. Bounded timeouts: a container
   completion must never hang on AIM."""
import re

_BS = chr(92)   # literal backslash. Built via chr() ON PURPOSE: this is the single most
                # escaping-sensitive value in the integration, and a source literal survives
                # one editor/tool round-trip fewer than you expect. (Verified 2026-08-03:
                # a heredoc silently collapsed the source literal into a real CRLF.)
_TIMEOUT_MS = 5000
_NINE_DIGITS = re.compile(r"^\d{9}$")


def _config():
    """Read AIM connection settings from the single-row Lots.AimPoolConfig.
       Returns (baseUrl, companyCode, pathToken); any may be None when unconfigured."""
    rows = BlueRidge.Common.Db.execList("lots/AimPoolConfig_Get") or []
    if not rows:
        return (None, None, None)
    r = rows[0]
    return (r.get("AimBaseUrl"), r.get("AimCompanyCode"), r.get("AimPathToken"))


def _urlEncodePayload(text):
    """Percent-encode the postserial payload. Only two characters need encoding for
       our field set: backslash (the literal escape marker) and space (significant
       inside a customer part number). Everything else in a serial / part / qty / lot
       is URL-safe. Deliberately hand-rolled rather than java.net.URLEncoder, which
       encodes space as '+' - AIM expects %20."""
    out = text.replace(_BS, "%5C").replace(" ", "%20")
    return out


def _buildPostQuery(serial, customerPart, qty, lot):
    """Build the postserial query string, WITHOUT the leading '?'.
       Shape: <BS>r<BS>n{serial}<BS>t{part}<BS>t{qty}<BS>t{lot}<BS>r<BS>n, then URL-encoded,
       where <BS> is a LITERAL BACKSLASH CHARACTER - not a carriage return, not a tab."""
    raw = (_BS + "r" + _BS + "n" + str(serial)
           + _BS + "t" + str(customerPart)
           + _BS + "t" + str(qty)
           + _BS + "t" + str(lot)
           + _BS + "r" + _BS + "n")
    return _urlEncodePayload(raw)


def _post(urlString, bodyText):
    """POST to a pre-encoded URL string. Returns (ok, replyText, error).
       java.net.URL does NO encoding - the caller owns the exact bytes of the query."""
    from java.lang import Throwable
    from java.net import URL
    conn = None
    try:
        conn = URL(urlString).openConnection()
        conn.setRequestMethod("POST")
        conn.setConnectTimeout(_TIMEOUT_MS)
        conn.setReadTimeout(_TIMEOUT_MS)
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.setDoOutput(True)
        body = (bodyText or "").encode("ascii")
        conn.setFixedLengthStreamingMode(len(body))
        os = conn.getOutputStream()
        try:
            if len(body):
                os.write(body)
            os.flush()
        finally:
            os.close()
        code = conn.getResponseCode()
        stream = conn.getInputStream()
        try:
            data = []
            while True:
                b = stream.read()
                if b == -1:
                    break
                data.append(chr(b))
            reply = "".join(data)
        finally:
            stream.close()
        if code != 200:
            return (False, reply, "HTTP %s" % code)
        return (True, reply, None)
    except Throwable, t:
        return (False, None, str(t))
    except Exception, e:
        return (False, None, str(e))
    finally:
        try:
            if conn is not None:
                conn.disconnect()
        except:
            pass


def _logAim(action, detail, ok, err=None):
    """Best-effort Audit.InterfaceLog write (FDS-01-014). Never breaks the caller.
       The audit NQ is UpdateQuery-typed, so it goes through execNonQuery."""
    params = {
        "systemName":       "AIM",
        "direction":        "Outbound",
        "logEventTypeCode": "LabelDispatched",
        "description":      "AIM %s" % action,
        "requestPayload":   detail,
        "responsePayload":  "OK" if ok else None,
        "errorCondition":   None if ok else "AimCallFailed",
        "errorDescription": err,
        "isHighFidelity":   True,
    }
    try:
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall", params)
    except:
        pass


def nextSerial():
    """Fetch the next AIM shipper ID for the configured company code.
       Returns {ok, serial, error}. Never raises."""
    base, company, token = _config()
    if not base or not company or not token:
        return {"ok": False, "serial": None,
                "error": "AIM connection is not configured (base URL, company code, path token)."}
    url = "%s/mes/floor/%s/%s/nextserial.csv" % (base, company, token)
    ok, reply, err = _post(url, "\r\n\r\n")
    if not ok:
        _logAim("nextserial", url, False, err)
        return {"ok": False, "serial": None, "error": err}
    serial = (reply or "").strip()
    if not _NINE_DIGITS.match(serial):
        msg = "Unexpected nextserial reply: %s" % (serial[:200],)
        _logAim("nextserial", url, False, msg)
        return {"ok": False, "serial": None, "error": msg}
    _logAim("nextserial", url, True)
    return {"ok": True, "serial": serial, "error": None}


def postSerial(serial, customerPart, qty, lot):
    """Bind content to an issued serial. Returns {ok, error}. Never raises.
       Success is an EXACT match: AIM echoes back the serial it accepted."""
    base, company, token = _config()
    if not base or not company or not token:
        return {"ok": False,
                "error": "AIM connection is not configured (base URL, company code, path token)."}
    query = _buildPostQuery(serial, customerPart, qty, lot)
    url = "%s/mes/floor/%s/%s/postserial.csv?%s" % (base, company, token, query)
    ok, reply, err = _post(url, "")
    if not ok:
        _logAim("postserial", url, False, err)
        return {"ok": False, "error": err}
    got = (reply or "").strip()
    if got == str(serial):
        _logAim("postserial", url, True)
        return {"ok": True, "error": None}
    # A reply starting 'POST ' is the listener echoing an unrecognized request.
    msg = "AIM rejected: %s" % (got[:200],)
    _logAim("postserial", url, False, msg)
    return {"ok": False, "error": msg}
