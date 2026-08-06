# AIM Integration — Plan 2: Ignition Layer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MES actually talk to AIM — fetch shipper IDs into the pool, report every completed container back, retry what fails, and give supervisors a screen to see and resolve the backlog.

**Architecture:** One new transport module (`BlueRidge.Lots.AimHttp`) is the only place an AIM call leaves the Gateway. One orchestration module (`BlueRidge.Lots.AimPost`) defines "post a serial" once, used by both the synchronous completion path and a 60-second retry sweep. Everything else is thin glue: named queries over Plan 1's procs, a timer, two view edits, and one new field.

**Tech Stack:** Ignition 8.3 Perspective (file-based project), Jython 2.7, SQL Server 2022.

**Depends on:** Plan 1 (`docs/superpowers/plans/2026-07-31-aim-integration-plan1-sql-foundation.md`) — **complete**, migration `0052`. Its closing signature table is the contract this plan consumes.
**Spec:** `docs/superpowers/specs/2026-07-31-aim-integration-ignition-design.md`
**Verified AIM contract:** `notes/2026-07-28_aim-interface-contract.md` — read §1 and §5.6 before Task 1.

---

## Global Constraints

- **Jython 2.7, not Python 3.** No f-strings, no `pathlib`. `%`-formatting only.
- **`except Exception` does NOT catch `java.lang.Throwable` in Jython.** Any code calling a Java API must `from java.lang import Throwable` and catch **both**, or use a bare `except:`. `BlueRidge.Lots.LabelTransport` is the reference implementation — read it before writing `AimHttp`.
- **No module-level `import BlueRidge.*`.** Commit `da809e3b` stripped them project-wide; project-library scripts resolve without them. Standard-library and `java.*` imports are fine (`LabelTransport` imports `re` at module level and `java.net.Socket` inside the function).
- **Named queries:** thin `EXEC` wrappers. `resource.json` carries `attributes.parameters[]` of `{type:"Parameter", identifier, sqlType}`. **sqlType codes in this project: `3` = BIGINT, `7` = NVARCHAR/String, `6` = BIT, `2` = numeric.** `type` is `"Query"` for reads, `"UpdateQuery"` for procs that emit no result set. Copy an existing sibling's `resource.json` verbatim and change only `parameters[]`.
- **Mutation procs return a status row** — consume via `BlueRidge.Common.Db.execMutation`, which returns `{Status, Message, ...}`. Reads use `execList` (list of dicts) or `execOne`. Only `Common.Db.*` may call `system.db.*`.
- **Route every mutation result through `BlueRidge.Common.Ui.notifyResult(result, successTitle=...)`.** Do not hand-roll toasts for mutation outcomes.
- **View files:** `meta.name` of the top component is always `root`. Style classes are referenced by suffix only (no `psc-` prefix). Use `position.display` (not `meta.visible`) for conditional visibility on flex children. `bidirectional: true` goes **inside** the binding's `config`.
- **Designer must be CLOSED** while editing any existing `view.json`. Designer writes `=`, `'`, `<`, `>`, `&` as 6-char unicode escapes, so literal-string matching fails on those characters — build match patterns with the escape form. Run `.\scan.ps1` after every file write.
- **ASCII-only** in any string that reaches SQL or ZPL.
- Timestamps display Eastern; the SQL layer already converts at the boundary. Do not re-convert in Python.

## Verification model — read this before Task 1

**There is no automated test harness for Jython in this repo.** Plan 1 had a 2323-assertion SQL suite; this plan has none. Verification is therefore:

1. **Script Console scripts** committed under `tools/script-console-demos/` — the precedent is `label_transport_grammar.py` from the dual-transport work. A human pastes them into the Gateway Script Console and compares output against a documented expectation. Every task that adds runtime logic ships one.
2. **`.\scan.ps1`** after every file write — must report clean.
3. **JSON validity** on every `view.json` / `resource.json` touched: `python -c "import json;json.load(open(r'<path>'))"`.
4. **The live AIM check** against company `01` (Task 1's gate).
5. **Human Designer smoke** — listed per task, owed at the end.

Do not claim a task is verified because code "looks right". State exactly which of the five above you ran.

**A deliberate asymmetry in how prescriptive this plan is.** Python, SQL and named-query steps carry
complete code — transcribe them. **View steps are specification-level**, giving the exact fields,
bindings, text and behaviour but not full `view.json`. A single Perspective screen is thousands of
lines of generated JSON whose structure depends on what is already in the file, so inlining it would
be both unreadable and stale on arrival. Read the existing view, follow the stated conventions, and
match the surrounding style. This mirrors how the dual-transport and PLC plans in this repo handled
view work.

**Where a view step feels underspecified, that is a signal to stop and ask, not to improvise a
layout.** Getting a binding shape wrong (a missing `bidirectional` inside `config`, an undeclared
bound custom property) produces a silently-broken screen rather than an error.

## ⚠️ Company 01 only

Production AIM runs on company **`99`** from the legacy MES box (`172.17.10.8`), counter at ~13.84M. **MES traffic must never target `99`.** The dev seed sets `01`. Every Script Console script in this plan must read the company code from `Lots.AimPoolConfig`, never hardcode it.

## ⚠️ Dev pool IDs will not post

`sql/seeds/028_seed_aim_pool_dev.sql` seeds `DEVAIM-000001`-style IDs. AIM requires a **9-digit zero-padded serial**. Every seeded ID will fail `postserial.csv`. Before enabling the timer in Dev, either clear the pool and let `topupTick` fetch real IDs from company `01`, or reseed in 9-digit format. Task 5 covers this.

---

### Task 1: `BlueRidge.Lots.AimHttp` — the transport

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimHttp/code.py`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimHttp/resource.json`
- Create: `tools/script-console-demos/aim_http_contract.py`

**Interfaces:**
- Produces:
  - `nextSerial()` -> `{"ok": bool, "serial": str|None, "error": str|None}`
  - `postSerial(serial, customerPart, qty, lot)` -> `{"ok": bool, "error": str|None}`
  - `_buildPostQuery(serial, customerPart, qty, lot)` -> `str` (exposed for the console script to assert against)
- Consumes: `Lots.AimPoolConfig_Get` for `AimBaseUrl` / `AimCompanyCode` / `AimPathToken`.

> ### 🔴 The single highest-risk detail in this plan
> The payload rides in the **query string**, and its delimiters are **literal backslash escape text** — `%5C` is a backslash, so `%5Cr%5Cn` is the two characters `\r\n`, **not** CR LF. The body is **empty**.
>
> **Therefore you MUST NOT use `system.net.httpClient()`.** It builds a `java.net.URI`, which percent-encodes the `%` in our already-encoded string, turning `%5C` into `%255C`. AIM then receives the literal text `%5C` and fails exactly the way this integration failed for two days before the format was reverse-engineered from AIM's own log.
>
> Use **`java.net.URL`** (which performs no encoding) + `openConnection()`.
>
> ### VERIFIED 2026-08-03 - this is a fact, not a hypothesis
> Run against **Ignition's own Jython 2.7.3** (`lib/core/common/jython-ia-2.7.3.5.jar`) on the dev
> box, against the live AIM server, company `01`:
> ```
> URL.getQuery() preserved the encoded query exactly   (PRESERVED: True)
> nextSerial  -> HTTP 200  serial='000000029'  9digits=True
> postSerial  -> HTTP 200  reply='000000029'   SUCCESS: True
> ```
> `java.net.URL` does **not** re-encode, and the `HttpURLConnection` shape below works end to end.
> Transcribe it as written.

- [ ] **Step 1: Read the precedent and the contract**

```bash
cat ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py
sed -n '/^## 3\./,/^## 4\./p' notes/2026-07-28_aim-interface-contract.md
```

`LabelTransport` shows this project's house style for a transport module: bounded timeouts, `Throwable`-aware exception handling, an outcome dict, and a `logDispatch` that never breaks the caller.

- [ ] **Step 2: Write the module**

Create `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimHttp/code.py`:

```python
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


def _configError(base, company, token):
    """Build a 'not configured' message naming the specific missing setting(s),
       rather than one indistinguishable message for every combination."""
    missing = []
    if not base:
        missing.append("base URL")
    if not company:
        missing.append("company code")
    if not token:
        missing.append("path token")
    return "AIM connection is not configured: missing %s." % ", ".join(missing)


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


def _readAll(stream):
    """Drain a Java InputStream to a string, one byte at a time (mirrors the
       original inline loop). Tolerates a None stream - getErrorStream() can
       legitimately return None when the server sent no error body - by
       returning "" rather than throwing."""
    if stream is None:
        return ""
    data = []
    try:
        while True:
            b = stream.read()
            if b == -1:
                break
            data.append(chr(b))
    finally:
        stream.close()
    return "".join(data)


def _post(urlString, bodyText):
    """POST to a pre-encoded URL string. Returns (ok, replyText, error).
       java.net.URL does NO encoding - the caller owns the exact bytes of the query.

       HttpURLConnection.getInputStream() THROWS on a 4xx/5xx response - the
       server's error body is only reachable via getErrorStream(). Read from
       whichever stream matches the status code so a rejection's actual message
       (e.g. AIM's "Not logged in - AIM Mobility must be restarted.") reaches the
       caller instead of being replaced by a generic IOException string."""
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
        if code >= 200 and code < 300:
            reply = _readAll(conn.getInputStream())
            return (True, reply, None)
        errorBody = _readAll(conn.getErrorStream())
        return (False, errorBody, "HTTP %s: %s" % (code, errorBody))
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


def _normalizeSerial(value):
    """Zero-pad a serial to 9 digits before comparing against AIM's echoed reply.
       postSerial's caller is expected to pass the zero-padded string nextSerial()
       returned, but this tolerates a bare int/numeric re-derived from a column too
       (e.g. str(29) would otherwise mismatch AIM's "000000029" echo). Anything not
       purely digits is returned unchanged - a malformed serial should fail the
       comparison loudly, not be silently reshaped."""
    s = str(value)
    if s.isdigit() and len(s) < 9:
        return s.zfill(9)
    return s


def nextSerial():
    """Fetch the next AIM shipper ID for the configured company code.
       Returns {ok, serial, error}. Never raises."""
    base, company, token = _config()
    if not base or not company or not token:
        return {"ok": False, "serial": None, "error": _configError(base, company, token)}
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
       Success is an EXACT match: AIM echoes back the serial it accepted. `serial`
       is normally the zero-padded 9-digit string nextSerial() returned, but a bare
       int is also accepted - both are zero-padded via _normalizeSerial() before
       comparison against AIM's echo."""
    base, company, token = _config()
    if not base or not company or not token:
        return {"ok": False, "error": _configError(base, company, token)}
    query = _buildPostQuery(serial, customerPart, qty, lot)
    url = "%s/mes/floor/%s/%s/postserial.csv?%s" % (base, company, token, query)
    ok, reply, err = _post(url, "")
    if not ok:
        _logAim("postserial", url, False, err)
        return {"ok": False, "error": err}
    got = (reply or "").strip()
    if got == _normalizeSerial(serial):
        _logAim("postserial", url, True)
        return {"ok": True, "error": None}
    # A reply starting 'POST ' is the listener echoing an unrecognized request.
    msg = "AIM rejected: %s" % (got[:200],)
    _logAim("postserial", url, False, msg)
    return {"ok": False, "error": msg}
```

Create `resource.json` beside it by copying `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/resource.json` and changing nothing but the timestamp.

- [ ] **Step 3: Write the Script Console gate**

Create `tools/script-console-demos/aim_http_contract.py`:

```python
# Paste into the Gateway Script Console. Proves the AimHttp contract end to end.
# SAFE: nextserial consumes ONE serial from the configured company's sequence.
# Company 01 is test. NEVER run this against company 99 (production).

print "=== 1. config ==="
base, company, token = BlueRidge.Lots.AimHttp._config()
print "   base=%s company=%s token=%s" % (base, company, token)
assert company != "99", "REFUSING to run against production company 99"

print "=== 2. query encoding (no live call) ==="
q = BlueRidge.Lots.AimHttp._buildPostQuery("000000024", "112006FB A000", 15, "LOTX")
print "   %s" % q
expected = "%5Cr%5Cn000000024%5Ct112006FB%20A000%5Ct15%5CtLOTX%5Cr%5Cn"
assert q == expected, "ENCODING WRONG\n  got: %s\n  exp: %s" % (q, expected)
print "   OK - backslashes are %5C, space is %20, no double-encoding"

print "=== 3. live nextSerial (consumes one serial) ==="
r = BlueRidge.Lots.AimHttp.nextSerial()
print "   %s" % r
assert r["ok"], "nextSerial failed: %s" % r["error"]
serial = r["serial"]

print "=== 4. live postSerial with a REAL customer part ==="
# Replace with a customer part that has an active blanket in the test company.
# Orders -> Order Entry -> Order Edit Lists -> Blanket Detail Summary by Customer Part
part = "112006FB A000"
r2 = BlueRidge.Lots.AimHttp.postSerial(serial, part, 15, serial)
print "   %s" % r2
if r2["ok"]:
    print "   PASS - AIM built the label. Verify on Unshipped Labels report."
else:
    print "   FAIL - %s" % r2["error"]
    print "   If the error starts 'AIM rejected: POST ' the query was not routed"
    print "   (double-encoding). If it says 'Blanket not found' the part has no"
    print "   active blanket - that is DATA, not transport."
```

- [ ] **Step 4: Scan and validate**

```bash
./scan.ps1
python -c "import json;json.load(open(r'ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimHttp/resource.json'))"
```

Expect `scan.ps1` clean and no JSON error.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimHttp/ tools/script-console-demos/aim_http_contract.py
git commit -m "feat(aim): AimHttp - the one place AIM calls leave the Gateway"
```

- [ ] **Step 6: HUMAN GATE (already DISCHARGED — see below) — run the Script Console script**

**DISCHARGED 2026-08-03 before execution began** — the contract was verified against Ignition's own Jython 2.7.3 jar and the live AIM server (company `01`, serial `000000029` posted and echoed), so Tasks 3-9 are NOT blocked. Running it once on the Gateway itself is still worth doing to confirm the Gateway JVM matches, but it is no longer a gate. A human opens the Gateway Script Console and runs `tools/script-console-demos/aim_http_contract.py`. Step 2 (encoding) must pass before the live steps are meaningful. Record the output in the task report.

If step 2 fails, `java.net.URL` is re-encoding after all and the module needs the raw-socket approach `LabelTransport` uses instead — stop and report rather than working around it.

---

### Task 2: Named queries for Plan 1's procs

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/lots/AimShipperIdPool_GetForPost/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/lots/AimShipperIdPool_RecordPostResult/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/lots/AimShipperIdPool_ListUnposted/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/lots/AimShipperIdPool_MarkPosted/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/parts/Item_GetAimCustomerPartNumber/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/parts/Item_SetAimCustomerPartNumber/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/named-query/lots/AimPoolConfig_Update/{query.sql,resource.json}`

**Interfaces:**
- Consumes: Plan 1's proc signatures (see that plan's closing table).
- Produces: the six NQ paths above, plus `AimPoolConfig_Update` extended to carry all nine settings.

- [ ] **Step 1: Copy the house format**

```bash
cat ignition/projects/Core/ignition/named-query/lots/AimShipperIdPool_Claim/resource.json
```

Every new `resource.json` is that file with only `parameters[]` changed (and `type` where noted). sqlType: **`3` = BIGINT, `7` = NVARCHAR, `6` = BIT**.

- [ ] **Step 2: Write the six new named queries**

`AimShipperIdPool_GetForPost/query.sql` — `type: "Query"`:
```sql
EXEC Lots.AimShipperIdPool_GetForPost @AimShipperId = :aimShipperId
```
parameters: `aimShipperId` (7).

`AimShipperIdPool_RecordPostResult/query.sql` — `type: "Query"` (it returns a status row):
```sql
EXEC Lots.AimShipperIdPool_RecordPostResult @Id = :id, @Success = :success, @Error = :error
```
parameters: `id` (3), `success` (6), `error` (7).

`AimShipperIdPool_ListUnposted/query.sql` — `type: "Query"`:
```sql
EXEC Lots.AimShipperIdPool_ListUnposted @Top = :top
```
parameters: `top` (3).

`AimShipperIdPool_MarkPosted/query.sql` — `type: "Query"`:
```sql
EXEC Lots.AimShipperIdPool_MarkPosted @Id = :id, @AppUserId = :appUserId, @Note = :note
```
parameters: `id` (3), `appUserId` (3), `note` (7).

`parts/Item_GetAimCustomerPartNumber/query.sql` — `type: "Query"`:
```sql
EXEC Parts.Item_GetAimCustomerPartNumber @ItemId = :itemId
```
parameters: `itemId` (3).

`parts/Item_SetAimCustomerPartNumber/query.sql` — `type: "Query"`:
```sql
EXEC Parts.Item_SetAimCustomerPartNumber @ItemId = :itemId, @Value = :value, @AppUserId = :appUserId
```
parameters: `itemId` (3), `value` (7), `appUserId` (3).

- [ ] **Step 3: Extend `AimPoolConfig_Update`**

`query.sql` becomes:
```sql
EXEC Lots.AimPoolConfig_Update
     @TargetBufferDepth = :targetBufferDepth,
     @TopupThreshold = :topupThreshold,
     @AlarmWarningDepth = :alarmWarningDepth,
     @AlarmCriticalDepth = :alarmCriticalDepth,
     @AimBaseUrl = :aimBaseUrl,
     @AimCompanyCode = :aimCompanyCode,
     @AimPathToken = :aimPathToken,
     @PostWarningAgeMinutes = :postWarningAgeMinutes,
     @PostCriticalAgeMinutes = :postCriticalAgeMinutes,
     @AppUserId = :appUserId
```
Add the five new identifiers to `parameters[]`: `aimBaseUrl` (7), `aimCompanyCode` (7), `aimPathToken` (7), `postWarningAgeMinutes` (3), `postCriticalAgeMinutes` (3).

> **The proc is preserve-on-omit** (`COALESCE(@Param, Column)`, commit `1dda2e1f`) — passing `None` for a setting leaves the stored value untouched. That is deliberate: it exists so a caller that only edits thresholds cannot wipe the connection settings. **Consequence: this NQ cannot blank a setting**, only overwrite it. Task 8's screen must therefore never present "clear this field" as an action.

- [ ] **Step 4: Validate and scan**

```bash
for f in $(git status --porcelain | grep -oE 'ignition/.*resource\.json'); do python -c "import json;json.load(open(r'$f'))" || echo "BAD: $f"; done
./scan.ps1
```

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/
git commit -m "feat(aim): named queries for the post-back procs + config connection settings"
```

---

### Task 3: `BlueRidge.Lots.AimPost` — one definition of "post a serial"

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPost/{code.py,resource.json}`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPool/code.py` (add the post-back wrappers)
- Create: `tools/script-console-demos/aim_post_one.py`

**Interfaces:**
- Consumes: Task 1's `AimHttp.postSerial`; Task 2's NQs.
- Produces:
  - `AimPost.postOne(aimShipperId)` -> `{"ok": bool, "outcome": "posted"|"no_customer_part"|"failed"|"not_found"|"already_posted", "error": str|None, "itemPartNumber": str|None}`
  - `AimPost.retryTick()` -> `{"attempted": int, "posted": int, "failed": int}` (Task 5 wires the timer)

- [ ] **Step 1: Add the thin wrappers to `AimPool`**

Append to `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPool/code.py` (no imports — see Global Constraints):

```python
def getForPost(aimShipperId):
    """Read one pool row's AIM post-back payload. Returns list[dict] (empty = not found).
       CustomerPartNumber is COALESCEd against the live item, so a row completed before
       the item had an AIM customer part picks the value up once it is configured."""
    BlueRidge.Common.Util.log("getForPost aimShipperId=%s" % aimShipperId, level="debug")
    return BlueRidge.Common.Db.execList(
        "lots/AimShipperIdPool_GetForPost", {"aimShipperId": aimShipperId})


def recordPostResult(poolId, success, error=None):
    """Record one AIM post attempt's outcome. Returns {Status, Message}."""
    BlueRidge.Common.Util.log(
        "recordPostResult poolId=%s success=%s" % (poolId, success), level="debug")
    return BlueRidge.Common.Db.execMutation(
        "lots/AimShipperIdPool_RecordPostResult",
        {"id": poolId, "success": 1 if success else 0, "error": error})


def listUnposted(top=50):
    """Rows owed to AIM (consumed, not yet posted), oldest first. Returns list[dict]."""
    return BlueRidge.Common.Db.execList("lots/AimShipperIdPool_ListUnposted", {"top": top})


def markPosted(poolId, note, appUserId=None):
    """Human-confirmed resolution for a row AIM already has but never acknowledged.
       Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "lots/AimShipperIdPool_MarkPosted",
        {"id": poolId, "appUserId": appUserId, "note": note})
```

- [ ] **Step 2: Write `AimPost`**

Create `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPost/code.py`:

```python
"""BlueRidge.Lots.AimPost - the ONE definition of 'post a serial to AIM'.

   Both callers use postOne: the synchronous path in Container.complete, and the
   60s retry sweep (AimPostTimer -> retryTick). Having one definition is the point -
   retry can never drift from first-attempt behaviour.

   postOne RE-READS the payload on every attempt rather than trusting a snapshot, so
   a row that failed because its item had no AIM customer part self-heals the moment
   someone fills that field in - no requeue, no manual step. (Lots.AimShipperIdPool_
   GetForPost COALESCEs the frozen snapshot against the live Parts.Item value.)

   Nothing here raises. A container completion must never fail because AIM is down."""


def postOne(aimShipperId):
    """Post one owed serial to AIM and record the outcome.
       Returns {ok, outcome, error, itemPartNumber}. Outcomes:
         posted           - AIM accepted it
         already_posted   - nothing owed; no call made
         not_found        - no such pool row
         no_customer_part - item has no AimCustomerPartNumber; NO call made
         failed           - AIM refused or was unreachable"""
    from java.lang import Throwable
    try:
        rows = BlueRidge.Lots.AimPool.getForPost(aimShipperId) or []
        if not rows:
            return {"ok": False, "outcome": "not_found",
                    "error": "No AIM pool row for %s." % aimShipperId,
                    "itemPartNumber": None}
        row = rows[0]
        if row.get("PostedAt") is not None:
            return {"ok": True, "outcome": "already_posted", "error": None,
                    "itemPartNumber": row.get("ItemPartNumber")}

        customerPart = row.get("CustomerPartNumber")
        itemPartNumber = row.get("ItemPartNumber")
        if not customerPart:
            msg = "No AIM customer part configured for %s." % (itemPartNumber or "this item")
            BlueRidge.Lots.AimPool.recordPostResult(row.get("Id"), False, msg)
            return {"ok": False, "outcome": "no_customer_part", "error": msg,
                    "itemPartNumber": itemPartNumber}

        res = BlueRidge.Lots.AimHttp.postSerial(
            aimShipperId, customerPart, row.get("Quantity"), row.get("LotNumber"))
        BlueRidge.Lots.AimPool.recordPostResult(
            row.get("Id"), res.get("ok"), res.get("error"))
        if res.get("ok"):
            return {"ok": True, "outcome": "posted", "error": None,
                    "itemPartNumber": itemPartNumber}
        return {"ok": False, "outcome": "failed", "error": res.get("error"),
                "itemPartNumber": itemPartNumber}
    except Throwable, t:
        BlueRidge.Common.Util.log("postOne %s failed: %s" % (aimShipperId, t), level="error")
        return {"ok": False, "outcome": "failed", "error": str(t), "itemPartNumber": None}
    except Exception, e:
        BlueRidge.Common.Util.log("postOne %s failed: %s" % (aimShipperId, e), level="error")
        return {"ok": False, "outcome": "failed", "error": str(e), "itemPartNumber": None}


def retryTick(batch=50):
    """Sweep rows owed to AIM. Each row is individually guarded so one failure cannot
       abort the batch; the whole tick is guarded so a timer can never throw. Order
       does not matter - AIM accepts serials out of order (verified 2026-07-31)."""
    from java.lang import Throwable
    stats = {"attempted": 0, "posted": 0, "failed": 0}
    try:
        for row in (BlueRidge.Lots.AimPool.listUnposted(batch) or []):
            serial = row.get("AimShipperId")
            stats["attempted"] += 1
            try:
                res = postOne(serial)
                if res.get("ok"):
                    stats["posted"] += 1
                else:
                    stats["failed"] += 1
            except Throwable, t:
                stats["failed"] += 1
                BlueRidge.Common.Util.log("retryTick row %s: %s" % (serial, t), level="error")
            except Exception, e:
                stats["failed"] += 1
                BlueRidge.Common.Util.log("retryTick row %s: %s" % (serial, e), level="error")
        if stats["attempted"]:
            BlueRidge.Common.Util.log("retryTick %s" % stats)
    except Throwable, t:
        BlueRidge.Common.Util.log("retryTick failed: %s" % t, level="error")
    except Exception, e:
        BlueRidge.Common.Util.log("retryTick failed: %s" % e, level="error")
    return stats
```

Create `resource.json` by copying `AimHttp`'s.

- [ ] **Step 3: Write the Script Console script**

Create `tools/script-console-demos/aim_post_one.py`:

```python
# Paste into the Gateway Script Console. Exercises postOne against real owed rows.
# Consumes nothing by itself - it only posts rows the MES already owes AIM.

owed = BlueRidge.Lots.AimPool.listUnposted(10) or []
print "owed rows: %d" % len(owed)
for r in owed:
    print "  %s  part=%r qty=%s lot=%s attempts=%s age=%smin err=%r" % (
        r.get("AimShipperId"), r.get("CustomerPartNumber"), r.get("Quantity"),
        r.get("LotNumber"), r.get("PostAttempts"), r.get("AgeMinutes"),
        r.get("LastPostError"))

if owed:
    s = owed[0].get("AimShipperId")
    print "\nposting %s ..." % s
    print "  %s" % BlueRidge.Lots.AimPost.postOne(s)
    print "\nre-posting the SAME serial (expect outcome=already_posted, no AIM call):"
    print "  %s" % BlueRidge.Lots.AimPost.postOne(s)
else:
    print "nothing owed - complete a container first, or seed a row."
```

- [ ] **Step 4: Scan, validate, commit**

```bash
./scan.ps1
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPost/ ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPool/code.py tools/script-console-demos/aim_post_one.py
git commit -m "feat(aim): AimPost.postOne/retryTick - one definition of posting a serial"
```

- [ ] **Step 5: 🔴 HUMAN GATE — Script Console**

Run `aim_post_one.py`. Confirm a real owed row posts, and that re-posting the same serial returns `already_posted` **without** an AIM call (the row's `PostAttempts` must not increase on the second call).

---

### Task 4: Real `topupTick` + backlog escalation in `alarmTick`

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPoolGateway/code.py`
- Create: `tools/script-console-demos/aim_topup.py`

**Interfaces:**
- Consumes: `AimHttp.nextSerial`, `AimPool.topup`, `AimPool.getDepth`, `AimPool.listUnposted`, `AimPoolConfig.get`.
- Produces: `topupTick()` fetching real IDs; `alarmTick()` additionally raising a backlog-age alarm.

- [ ] **Step 1: Implement `topupTick`**

Replace the `return`-only stub. Behaviour per FDS-07-010, adapted to the verified contract (the pool is global — `nextserial.csv` takes no part parameter):

```python
def topupTick():
    """Refill the AIM shipper-ID pool toward TargetBufferDepth.

       The pool is GLOBAL: AIM's nextserial.csv issues serials per COMPANY CODE and
       accepts no part parameter, so FDS-07-010's per-part loop does not apply.

       Fetches one ID per AIM call, stopping at the target, on the first failure, or
       at a hard per-tick cap so a misconfigured endpoint cannot spin. Never raises -
       a timer must not throw."""
    from java.lang import Throwable
    _MAX_PER_TICK = 25
    try:
        cfgRows = BlueRidge.Lots.AimPoolConfig.get() or []
        cfg = cfgRows[0] if cfgRows else {}
        target = cfg.get("TargetBufferDepth") or 50
        threshold = cfg.get("TopupThreshold") or 30

        depthRows = BlueRidge.Lots.AimPool.getDepth() or []
        depth = (depthRows[0].get("Depth") if depthRows else 0) or 0
        if depth >= threshold:
            return {"fetched": 0, "depth": depth}

        fetched = 0
        while depth + fetched < target and fetched < _MAX_PER_TICK:
            res = BlueRidge.Lots.AimHttp.nextSerial()
            if not res.get("ok"):
                BlueRidge.Common.Util.log(
                    "topupTick stopping: %s" % res.get("error"), level="warn")
                break
            up = BlueRidge.Lots.AimPool.topup(res.get("serial"))
            if not (up and up.get("Status")):
                BlueRidge.Common.Util.log(
                    "topupTick could not pool %s: %s"
                    % (res.get("serial"), up and up.get("Message")), level="warn")
                break
            fetched += 1
        if fetched:
            BlueRidge.Common.Util.log("topupTick fetched %d (depth was %d)" % (fetched, depth))
        return {"fetched": fetched, "depth": depth + fetched}
    except Throwable, t:
        BlueRidge.Common.Util.log("topupTick failed: %s" % t, level="error")
        return {"fetched": 0, "depth": 0}
    except Exception, e:
        BlueRidge.Common.Util.log("topupTick failed: %s" % e, level="error")
        return {"fetched": 0, "depth": 0}
```

> **A serial fetched from AIM but not pooled is lost forever** — AIM's counter has moved and there is no way to return it. That is why the loop breaks immediately when `topup` fails rather than continuing to fetch.

- [ ] **Step 2: Add backlog escalation to `alarmTick`**

`alarmTick` currently alarms on pool depth only. Add a second, independent rising-edge check on **backlog age**, using `PostWarningAgeMinutes` / `PostCriticalAgeMinutes` from config and the `AgeMinutes` of the oldest row from `AimPool.listUnposted(1)`. Keep a separate state variable from the depth alarm — the two conditions are unrelated and must not clear each other. Reuse the existing `system.perspective.sendMessage("aim-pool-alarm", ...)` mechanism, adding a `kind` key (`"depth"` or `"backlog"`) so a consumer can tell them apart.

- [ ] **Step 3: Console script + scan + commit**

Create `tools/script-console-demos/aim_topup.py` printing config, current depth, then one `topupTick()` call and the resulting depth. Then:

```bash
./scan.ps1
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPoolGateway/code.py tools/script-console-demos/aim_topup.py
git commit -m "feat(aim): real topupTick against AIM + backlog-age escalation in alarmTick"
```

- [ ] **Step 4: 🔴 HUMAN GATE**

Run `aim_topup.py`. Confirm the pool depth rises and that the fetched IDs are **9-digit**. Note the company `01` counter position before and after.

---

### Task 5: `AimPostTimer` + dev pool hygiene

**Files:**
- Create: `ignition/projects/MPP/ignition/timer/AimPostTimer/{handleTimerEvent.py,resource.json}`
- Modify: `sql/seeds/028_seed_aim_pool_dev.sql`

- [ ] **Step 1: Create the timer**

Copy `ignition/projects/MPP/ignition/timer/AimPoolAlarmTimer/resource.json` and set `delay` to `60000`, **`enabled` to `false`**.

`handleTimerEvent.py`:
```python
def handleTimerEvent():
	# Every 60s: post any container completions still owed to AIM.
	# SHIPS DISABLED - enable only after the Script Console gates in Tasks 1 and 3 pass
	# on the target Gateway. Logic lives in Core; this is dispatch only.
	BlueRidge.Lots.AimPost.retryTick()
```

> **Ships disabled deliberately.** A half-configured Gateway that starts posting to AIM burns serials against wrong data, and a burnt serial cannot be returned.

- [ ] **Step 2: Fix the dev seed's ID format**

`sql/seeds/028_seed_aim_pool_dev.sql` currently seeds `DEVAIM-000001`-style IDs. AIM requires **9 digits**, so every one of them fails `postserial.csv` the moment the timer is enabled in Dev. Change the generated format to 9 digits in a range that cannot collide with real AIM serials (company 01 is near `000000030`; production is ~`013.8M`) — use `999000001`+ and add a comment saying why. Add a header note that these are **local placeholders that will never post successfully**, and that a realistic Dev exercise means clearing the pool and letting `topupTick` fetch real IDs from company `01`.

- [ ] **Step 3: Verify the seed still applies**

```bash
powershell.exe -NoProfile -File "sql\tests\Run-Tests.ps1" -Filter "0049_AimIntegration"
```
Expect **45/45** — the seed runs during the reset, so a syntax error there fails the run.

- [ ] **Step 4: Scan and commit**

```bash
./scan.ps1
git add ignition/projects/MPP/ignition/timer/AimPostTimer/ sql/seeds/028_seed_aim_pool_dev.sql
git commit -m "feat(aim): AimPostTimer (disabled at ship) + 9-digit dev pool IDs"
```

---

### Task 6: Wire the post-back into container completion

> **⚠️ PARTIALLY SUPERSEDED 2026-08-04.** Step 1 (calling `postOne` after completion) is still
> correct and shipped as-is. Steps 2, 3 and 5 below build/wire the `AimNoCustomerPart` config-gap
> popup and its `no_customer_part` outcome branch — both are **removed**. Live AIM testing proved
> the customer part is derivable from `Item.PartNumber`, so with `PartNumber NOT NULL` a configured
> item can never reach `postOne` missing a customer part; the outcome is unreachable and the modal
> it triggered has nothing left to report. See Task 7's supersede notice and
> `docs/superpowers/specs/2026-07-31-aim-integration-ignition-design.md` §6.1/§6.2. Left below for
> historical record only.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AimNoCustomerPart/{view.json,resource.json}`

**Interfaces:**
- Consumes: `AimPost.postOne`.
- Produces: `Container.complete` returns an added `AimPost` key carrying `postOne`'s outcome dict.

- [ ] **Step 1: Call `postOne` after completion**

In `Container.complete`, after the existing label-dispatch block, add an equally-guarded post-back. It runs **after** the proc has committed, so an AIM outage can never roll back a container:

```python
    # Report the completed container to AIM. Runs AFTER the proc committed and is fully
    # guarded: complete, print and post are three separate steps (FDS-07-005/006a/012).
    # A failure leaves the row owed; AimPostTimer retries it. NEVER lose the container.
    if result and result.get("Status") and result.get("AimShipperId"):
        try:
            result["AimPost"] = BlueRidge.Lots.AimPost.postOne(result.get("AimShipperId"))
        except Throwable, t:
            BlueRidge.Common.Util.log("AIM post-back failed: %s" % t, level="error")
            result["AimPost"] = {"ok": False, "outcome": "failed", "error": str(t)}
        except Exception, e:
            BlueRidge.Common.Util.log("AIM post-back failed: %s" % e, level="error")
            result["AimPost"] = {"ok": False, "outcome": "failed", "error": str(e)}
```

`Throwable` is already imported at the top of `complete`.

- [ ] **Step 2: Build the config-gap popup**

Create `BlueRidge/Components/Popups/AimNoCustomerPart` — a **new** view, so file-authoring is safe. Params: `partNumber` (input). Modal, no close icon, single **OK** button. Copy the structure and style classes from an existing popup (`BlueRidge/Components/Popups/ConfirmDestructive` is the closest shape) so it matches the plant-floor design system.

Body text:
> **AIM not updated — no customer part number**
> Part `{partNumber}` has no AIM customer part number configured. The container completed and the label printed, but Honda's system was not updated. A supervisor must set this in Item Master.

- [ ] **Step 3: Branch the operator feedback**

Wherever `Container.complete` is called from a view, branch on `result["AimPost"]["outcome"]`:

| outcome | feedback |
|---|---|
| `posted` / `already_posted` | nothing — normal completion |
| `no_customer_part` | open the `AimNoCustomerPart` popup with `partNumber` |
| `failed` / `not_found` | toast: *"AIM not updated for `<serial>` — will retry automatically."* |

Find the callers with `grep -rn "Container.complete\|Container\.complete" ignition/projects/MPP/`. **Designer must be closed** when editing those existing `view.json` files, and remember `=` is written as its 6-char unicode escape.

The config gap gets a modal because it is an actionable configuration error someone must fix; a transport failure gets a passive toast because the operator can do nothing about it and the sweep will handle it.

- [ ] **Step 4: Validate, scan, commit**

```bash
python -c "import json;json.load(open(r'ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AimNoCustomerPart/view.json'))"
./scan.ps1
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/
git commit -m "feat(aim): post completed containers to AIM; config-gap modal, retry toast"
```

- [ ] **Step 5: 🔴 HUMAN GATE — Designer smoke**

Complete a container in Dev on an item **with** an AIM customer part (expect silence + the serial appearing on AIM's Unshipped Labels report) and on one **without** (expect the modal, and the row visible as owed on the `/aim-pool` screen once Task 8 lands).

---

### Task 7: Item Master — the AIM customer part field

> **⚠️ SUPERSEDED 2026-08-04.** Live testing against MPP's AIM server proved the customer part is
> derivable from `Item.PartNumber` (strip dashes, preserve embedded spaces) — the "NOT derivable
> from PartNumber; sourced from AIM's cross-reference" premise below was wrong for MPP's own part
> numbers. Migration `0054_drop_item_aim_customer_part.sql` drops the column and procs this task's
> accessors depended on; the `getAimCustomerPartNumber` / `setAimCustomerPartNumber` entity methods
> and the Identity field this task adds are both **removed**, replaced by nothing — there is no
> longer a per-item value to view or edit. See `notes/2026-07-28_aim-interface-contract.md` for the
> evidence and `docs/superpowers/specs/2026-07-31-aim-integration-ignition-design.md` §4.1/§4.2/§9
> for the updated design. This task is left below **for historical record only** — do not execute
> it.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json`

- [ ] **Step 1: Add the entity methods**

Mirror `getPlcId` / `setPlcId` in the same file — they exist as the precedent for exactly this shape:

```python
def getAimCustomerPartNumber(itemId):
    """Read the item's AIM Customer Part - the value AIM's postserial.csv matches on.
       NOT derivable from PartNumber; sourced from AIM's cross-reference. Returns the
       string, or None when unset (a normal state - not every item ships to Honda)."""
    rows = BlueRidge.Common.Db.execList(
        "parts/Item_GetAimCustomerPartNumber", {"itemId": itemId}) or []
    return rows[0].get("AimCustomerPartNumber") if rows else None


def setAimCustomerPartNumber(itemId, value, appUserId=None):
    """Set (or clear, with None) the item's AIM Customer Part. Returns {Status, Message}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation(
        "parts/Item_SetAimCustomerPartNumber",
        {"itemId": itemId, "value": value, "appUserId": appUserId})
```

- [ ] **Step 2: Add the field to Identity**

Read how `PlcId` is loaded and saved in `Identity/view.json` and replicate it exactly — it uses the separate accessors rather than `Item_Get`/`Item_Update`, which is why those procs' shapes stayed stable.

Label the field **"AIM Customer Part"** with helper text: *"As AIM stores it — e.g. `112006FB A000`. The embedded space is significant."*

> **Designer must be CLOSED.** This is an existing view; `=` appears as its 6-char unicode escape in the file.

- [ ] **Step 3: Validate, scan, commit**

```bash
python -c "import json;json.load(open(r'ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Identity/view.json'))"
./scan.ps1
git add ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Item/code.py ignition/projects/MPP_Config/
git commit -m "feat(aim): Item Master AIM customer-part field"
```

- [ ] **Step 4: 🔴 HUMAN GATE**

In Designer, set an item's AIM Customer Part, save, reload, confirm it persists **with its embedded space intact**. Then confirm a previously-failed owed row for that item posts successfully on the next `retryTick` — that is the self-heal working end to end.

---

### Task 8: `/aim-pool` screen — connection settings, backlog, MarkPosted

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AimPoolConfig/view.json`
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AimUnpostedRow/{view.json,resource.json}`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPoolConfig/code.py`

- [ ] **Step 1: Extend the config wrapper to nine settings**

`AimPoolConfig.update` currently takes four. Add the five new ones, **all defaulting to `None`** so existing four-argument callers keep working and, thanks to the proc's `COALESCE`, leave the stored values untouched.

- [ ] **Step 2: Add connection fields to the screen**

Add `AimBaseUrl`, `AimCompanyCode`, `AimPathToken`, `PostWarningAgeMinutes`, `PostCriticalAgeMinutes` to the existing form, bound bidirectionally into `view.custom.editDraft` (remember: `bidirectional: true` goes **inside** `config`). Pre-declare every bound custom property with a fully-shaped default — a nested read against a not-yet-existent property renders a red Component Error.

Put a visible warning beside the company code: *"`01` is test. Production runs on `99` — never point the MES at it."*

Because the proc cannot blank a setting, **do not offer a "clear" action** on these fields.

- [ ] **Step 3: Build the unposted list**

New `AimUnpostedRow` instance view (safe to file-author) showing serial, container, part, qty, lot, age, attempts, and `LastPostError`. Drive it from a flex-repeater bound to `AimPool.listUnposted`.

Flex-repeater rows need `useDefaultViewHeight: true` **and** an `elementPosition.basis` in pixels matching `defaultSize.height`, or rows stretch to fill.

Precompute any date display in Python — dates serialize to strings across the repeater param hop, so `dateFormat` in a binding misrenders.

- [ ] **Step 4: Wire MarkPosted**

A per-row **Mark Posted** button opening a confirmation popup that **requires a note** (the proc rejects a blank one — mirror that in the UI rather than letting the proc reject it). Route the result through `Common.Ui.notifyResult` and refresh the list.

The confirmation text must make the stakes explicit: *"This records that AIM already has this label. Only do this after confirming the serial on AIM's Unshipped Labels report — the MES cannot verify it."*

- [ ] **Step 5: Validate, scan, commit**

```bash
for f in $(git status --porcelain | grep -oE 'ignition/.*\.json'); do python -c "import json;json.load(open(r'$f'))" || echo "BAD: $f"; done
./scan.ps1
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/ ignition/projects/Core/ignition/script-python/BlueRidge/Lots/AimPoolConfig/code.py
git commit -m "feat(aim): /aim-pool connection settings, unposted backlog list, MarkPosted"
```

- [ ] **Step 6: 🔴 HUMAN GATE**

Save connection settings and confirm they persist. Confirm a four-argument threshold-only save (the pre-existing path) does **not** wipe them. Mark a row posted and confirm it leaves the list and writes an audit row naming the serial.

---

### Task 9: `AimPoolTile` — global depth + backlog

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AimPoolTile/view.json`

- [ ] **Step 1: Finish the tile**

Plan 1 left it minimally resynced with a `TODO(Plan 2)`. Complete it: show global pool depth against the warning/critical **depth** thresholds, and add a second line showing the **unposted backlog** count and oldest age against the warning/critical **age** thresholds. Remove the `TODO(Plan 2)` marker.

The two conditions are independent — the tile must be able to show a healthy pool with a critical backlog, and vice versa.

- [ ] **Step 2: Validate, scan, commit**

```bash
python -c "import json;json.load(open(r'ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AimPoolTile/view.json'))"
./scan.ps1
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/AimPoolTile/
git commit -m "feat(aim): AimPoolTile shows global depth and post backlog"
```

- [ ] **Step 3: Note the embedding gap**

`AimPoolTile` has **no embedder** — no view currently includes it. Record in the task report whether it should be added to a supervisor dashboard, or left available for later. Do not add it to a dashboard unprompted; that is a layout decision for the project owner.

---

## Owed human verification (collected)

None of these can be done by an agent. Collect them into one Designer/Gateway session:

1. ~~**Task 1 - the encoding gate.**~~ **DISCHARGED 2026-08-03** against Ignition's own Jython jar + the live AIM server (company `01`; serial `000000029` posted and echoed). Re-running `aim_http_contract.py` in the Gateway Script Console is still worth one pass to confirm the *Gateway's* JVM matches the local one, but it no longer blocks anything.
2. **Task 3** — `aim_post_one.py`: a real row posts; re-posting returns `already_posted` with no attempt increment.
3. **Task 4** — `aim_topup.py`: depth rises, IDs are 9-digit.
4. **Task 6** — complete a container with and without an AIM customer part; verify the serial on AIM's Unshipped Labels report.
5. **Task 7** — the field persists with its embedded space; a previously-failed row self-heals on the next tick.
6. **Task 8** — settings persist; a four-arg threshold save does not wipe them; MarkPosted audits.
7. **Enable `AimPostTimer`** only after 1-6 pass.

## Still unresolved after this plan

- **Holds (FDS-07-011)** — the AIM agreement covers label creation only. Appendix L implies QA performs holds by hand in AIM's UI. Needs a decision with MPP.
- **`previousSerial` (FDS-07-012)** — no equivalent in this interface, so Sort Cage re-pack traceability has no transport.
- **OI-33 empty-pool policy** — hard-fail retained; still a business decision.
- **Customer-part data** — the column and editor exist; MPP must supply the mapping.
- **Production company code** — `01` is test; the production code and its counter position must be confirmed before cutover.
- **`MPP_MES_DATA_MODEL.md`** — not yet updated for migration `0052`'s columns.
