# Dual-Transport Label Printing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the MES print to both networked Zebras (raw TCP) and USB printers shared from a terminal PC (Windows print queue), route labels to the right printer by label type, and make container labels actually print.

**Architecture:** One new Core module `BlueRidge.Lots.LabelTransport` owns all byte-level dispatch and picks its transport from the syntax of the printer's `Endpoint` string. Both existing dispatchers delete their duplicate `_dispatchZpl` and call it. `Location.Terminal_GetPrinter` gains an optional label-type filter with fallback to today's behaviour, and `Container.complete` gains a dispatch tail so completed containers print.

**Tech Stack:** Ignition 8.3 Perspective (Jython 2.7 script modules, named queries), SQL Server 2022 (versioned + repeatable migrations, `test.Assert_*` harness driven by `sql/tests/Run-Tests.ps1`).

**Spec:** `docs/superpowers/specs/2026-07-28-dual-transport-label-printing-design.md`

## Global Constraints

- **No OUTPUT parameters in stored procedures** (FDS-11-011). Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message;`. Read procs return an empty rowset for not-found.
- **`UpperCamelCase`** tables/columns; `BIGINT` ids; `NVARCHAR` never `VARCHAR`; `DATETIME2(3)`; timestamps stored UTC.
- **Seed/data string values and ZPL payloads are ASCII-only.** No em-dash, no middle-dot. `sqlcmd` reads `.sql` in the Windows codepage and non-ASCII becomes mojibake.
- **Jython 2 keywords:** `print` is reserved. Never write `job.print(...)` — use `getattr(job, "print")`. This is why the existing public method is `printLabel`, not `print`.
- **Jython 2 exception handling:** `except Exception` does **not** catch `java.lang.Throwable`. Any block wrapping a Java call must catch `Throwable` explicitly (or use a bare `except:`).
- **Named-query `sqlType` codes** are Designer's own enum, not `java.sql.Types`: `3` = BIGINT id, `7` = NVARCHAR, `6` = BIT.
- **Named-query type must match the proc:** a proc that SELECTs a result set is `"type": "Query"`; a proc that emits none is `"type": "UpdateQuery"` and must be called via `execNonQuery`.
- **Print failure never rolls back a business transaction.** Minting a LOT and printing its label are separate steps; so are completing a container and printing its label.
- **Ignition file edits:** all files below are new files, script modules, named queries, or SQL — never an existing `view.json`. Safe to edit on disk. Run `scan.ps1` afterwards.
- **Git commits:** omit the `Co-Authored-By: Claude` trailer.
- **Next free versioned migration number is `0045`** (last applied is `0044_operator_change_audit_event.sql`).

## File Structure

| File | Responsibility |
|---|---|
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py` | **New.** Endpoint grammar, `describeEndpoint`, `send`, `_sendTcp`, `_sendQueue`. The only place ZPL bytes leave the Gateway. |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/resource.json` | **New.** Module manifest. |
| `tools/script-console-demos/label_transport_grammar.py` | **New.** Runnable assertion script for the pure grammar. |
| `.../BlueRidge/Lots/LotLabel/code.py` | Drops `_dispatchZpl`; calls `LabelTransport`; logs transport; label-type-aware printer resolution. |
| `.../BlueRidge/Lots/ShippingDispatcher/code.py` | Same, plus renders the container template from the DB. |
| `.../BlueRidge/Lots/Container/code.py` | Gains the dispatch tail on `complete()`. |
| `.../BlueRidge/Lots/Shipping/code.py` | Gains the dispatch tail on `reprintLabel()`. |
| `.../BlueRidge/Location/Terminal/code.py` | `getPrinter` gains `labelTypeCode`. |
| `sql/migrations/versioned/0045_label_type_routing.sql` | `LabelTypes` attribute definition; PrintReasonCode em-dash fix. |
| `sql/migrations/versioned/0046_container_label_template.sql` | Container ZPL body into `Lots.LabelTemplate`. |
| `sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql` | v2.0 with `@LabelTypeCode`. |
| `sql/migrations/repeatable/R__Lots_ShippingLabel_RecordDispatch.sql` | **New** proc — dispatch write-back. |
| `sql/migrations/repeatable/R__Lots_LabelTemplate_GetActiveByTypeCode.sql` | **New** proc — fetch a configurable ZPL body by label-type code. |
| `sql/migrations/repeatable/R__Lots_ShippingLabel_GetContainerId.sql` | **New** proc — reprint needs the container behind a label. |
| `ignition/projects/Core/ignition/named-query/location/Terminal_GetPrinter/*` | New `labelTypeCode` parameter. |
| `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_RecordDispatch/*` | **New** NQ. |
| `ignition/projects/Core/ignition/named-query/lots/LabelTemplate_GetActiveByTypeCode/*` | **New** NQ. |
| `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetContainerId/*` | **New** NQ. |
| `sql/tests/0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql` | **New** tests. |
| `sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql` | **New** tests. |

---

## Task 1: `LabelTransport` module

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/resource.json`
- Test: `tools/script-console-demos/label_transport_grammar.py`

**Interfaces:**
- Consumes: `BlueRidge.Common.Db.execNonQuery` (for `logDispatch` only — the grammar functions stay pure and callable with no DB).
- Produces:
  - `send(endpoint, zpl) -> {"ok": bool, "error": str|None, "transport": "tcp"|"queue"|None}`
  - `describeEndpoint(endpoint) -> {"transport": str|None, "target": str|None, "valid": bool, "reason": str|None}`
  - `logDispatch(endpoint, zpl, outcome, labelKind) -> None`

> **Decision (2026-07-28, supersedes the spec's §3.2 wording):** `_logDispatch` is **extracted
> into this module** rather than duplicated in both dispatchers. The two copies would have
> differed by a single description string — both already use `systemName = "Zebra"` — and this
> module already produces the transport name being logged, so it is the natural owner.

- [ ] **Step 1: Write the failing test**

Create `tools/script-console-demos/label_transport_grammar.py`:

```python
# =============================================================================
# Test: BlueRidge.Lots.LabelTransport endpoint grammar
#
# Run in the Designer Script Console (Tools -> Script Console). Paste, execute.
# Prints one line per case; a FAIL line means the grammar is wrong.
#
# Grammar under test (design 2026-07-28 sec 3.1), evaluated in order:
#   1. empty/whitespace          -> invalid
#   2. starts with \\            -> queue (UNC verbatim)
#   3. matches ^(.+):(\d+)$      -> tcp
#   4. anything else             -> queue (local queue name)
#
# The port is MANDATORY for tcp. That is the whole point: it makes a bare
# name unambiguously a queue, where the old code silently guessed hostname.
# =============================================================================
import BlueRidge.Lots.LabelTransport as LT

CASES = [
    # (endpoint,                      expected transport, expected target)
    ("10.20.30.40:9100",              "tcp",   "10.20.30.40:9100"),
    ("zebra-dc1.mpp.local:9100",      "tcp",   "zebra-dc1.mpp.local:9100"),
    ("10.20.30.40:6101",              "tcp",   "10.20.30.40:6101"),
    ("\\\\FLXWAPSRV1\\5A2 Machining", "queue", "\\\\FLXWAPSRV1\\5A2 Machining"),
    ("\\\\887intel\\RPY COMP",        "queue", "\\\\887intel\\RPY COMP"),
    ("Zebra GX420d (RAW)",            "queue", "Zebra GX420d (RAW)"),
    ("printer01",                     "queue", "printer01"),   # bare name = queue, NOT host:9100
    ("  10.20.30.40:9100  ",          "tcp",   "10.20.30.40:9100"),   # trimmed
]

INVALID = ["", "   ", None, ":9100", "10.20.30.40:0", "10.20.30.40:70000"]

failures = 0
for endpoint, wantTransport, wantTarget in CASES:
    d = LT.describeEndpoint(endpoint)
    ok = d["valid"] and d["transport"] == wantTransport and d["target"] == wantTarget
    if not ok:
        failures += 1
    print "%s  %-32r -> %s" % ("PASS" if ok else "FAIL", endpoint, d)

for endpoint in INVALID:
    d = LT.describeEndpoint(endpoint)
    ok = (not d["valid"]) and d["transport"] is None and d["reason"]
    if not ok:
        failures += 1
    print "%s  %-32r -> %s" % ("PASS" if ok else "FAIL", endpoint, d)

# send() on an invalid endpoint must return, never raise.
r = LT.send("", "^XA^XZ")
ok = (r["ok"] is False) and (r["transport"] is None) and r["error"]
if not ok:
    failures += 1
print "%s  send('') returns instead of raising -> %s" % ("PASS" if ok else "FAIL", r)

print "\n%d failure(s)" % failures
```

- [ ] **Step 2: Run it to verify it fails**

Open the Designer Script Console, paste the file contents, execute.
Expected: `ImportError: No module named LabelTransport`.

- [ ] **Step 3: Write the module**

Create `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py`:

```python
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

import BlueRidge.Common.Db

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


def _sendTcp(host, port, zpl):
    """Raw-TCP write of the ZPL bytes, bounded timeout. Returns {ok, error}.
       Catches Throwable FIRST: a socket failure is java.net.ConnectException, and
       Jython's `except Exception` does NOT catch java.lang.Throwable."""
    from java.net import Socket, InetSocketAddress
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
        return {"ok": True, "error": None}
    except Throwable as t:
        return {"ok": False, "error": t.getMessage() or str(t)}
    except Exception as e:
        return {"ok": False, "error": str(e)}
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
                              % (queueName, visible))}
        doc = SimpleDoc(JString(zpl or "").getBytes("US-ASCII"),
                        DocFlavor.BYTE_ARRAY.AUTOSENSE, None)
        job = target.createPrintJob()
        # getattr because `print` is a Jython 2 keyword -- job.print(...) will not parse.
        getattr(job, "print")(doc, HashPrintRequestAttributeSet())
        return {"ok": True, "error": None}
    except Throwable as t:
        return {"ok": False, "error": t.getMessage() or str(t)}
    except Exception as e:
        return {"ok": False, "error": str(e)}


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


def logDispatch(endpoint, zpl, outcome, labelKind):
    """Log ONE dispatch attempt to Audit.InterfaceLog -- every attempt: success,
       failure, retry (FDS-01-014). labelKind is the human label for the description,
       e.g. 'LTT' or 'Shipping label'. High-fidelity so endpoint, transport and the
       ZPL head persist; the transport name is what distinguishes a TCP failure from
       a queue failure in the audit trail without re-parsing the endpoint."""
    ok = bool(outcome and outcome.get("ok"))
    transport = (outcome or {}).get("transport") or "unknown"
    params = {
        "systemName":       _SYSTEM_NAME,
        "direction":        "Outbound",
        "logEventTypeCode": "LabelDispatched",
        "description":      "%s dispatch via %s to %s" % (labelKind, transport, endpoint or "(none)"),
        "requestPayload":   "%s | %s" % (endpoint or "", (zpl or "")[:200]),
        "responsePayload":  "OK" if ok else None,
        "errorCondition":   None if ok else "DispatchFailed",
        "errorDescription": None if ok else (outcome.get("error") if outcome else "unknown"),
        "isHighFidelity":   True,
    }
    # audit/Audit_LogInterfaceCall is "UpdateQuery"-typed (the proc emits no result set),
    # so it MUST go through execNonQuery -- execList would hand _rowsToDicts an Integer
    # row count and throw. Bare except (not `except Exception`) because Jython's
    # `except Exception` does NOT catch java.lang.Throwable; logging must never
    # break dispatch.
    try:
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall", params)
    except:
        pass
```

Create `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/resource.json`:

```json
{
  "scope": "A",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "code.py"
  ],
  "attributes": {
    "hintScope": 2,
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-07-28T12:00:00Z"
    }
  }
}
```

- [ ] **Step 4: Scan the project and re-run the test**

Run: `.\scan.ps1`
Then re-run the Script Console test.
Expected: every line `PASS`, final line `0 failure(s)`.

- [ ] **Step 5: Verify TCP against the local bridge (no Zebra needed)**

In one terminal on the **Gateway host**:

```bash
python zebraPrinter/usb_tcp_bridge.py "Microsoft Print to PDF"
```

In the Script Console:

```python
import BlueRidge.Lots.LabelTransport as LT
print LT.send("127.0.0.1:9100", "^XA^CFA,30^FO50,50^FDMES TRANSPORT TEST^FS^XZ")
```

Expected: `{'ok': True, 'error': None, 'transport': 'tcp'}` and the bridge prints a `received N bytes` line.

- [ ] **Step 6: Verify the queue transport enumerates**

```python
import BlueRidge.Lots.LabelTransport as LT
print LT.send("NoSuchQueue", "^XA^XZ")
```

Expected: `ok` is `False` and the error lists the queues visible to the Gateway service account. That list is the commissioning diagnostic — record it.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport tools/script-console-demos/label_transport_grammar.py
git commit -m "feat(labels): LabelTransport module - TCP + Windows queue by endpoint grammar"
```

---

## Task 2: Repoint both dispatchers onto `LabelTransport`

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotLabel/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py`

**Interfaces:**
- Consumes: `LabelTransport.send(endpoint, zpl) -> {ok, error, transport}` (Task 1).
- Produces: no signature changes. `printLabel`, `reprint`, `dispatch`, `dispatchContainer` keep their existing surfaces.

- [ ] **Step 1: Delete `_dispatchZpl` from `LotLabel/code.py`**

Remove the whole `_dispatchZpl` function (lines 72–99) and these now-unused imports:

```python
from java.net import Socket, InetSocketAddress
from java.lang import String as JString
```

Add to the import block:

```python
import BlueRidge.Lots.LabelTransport
```

- [ ] **Step 2: Delete `LotLabel._logDispatch` — the logger now lives in `LabelTransport`**

Delete the entire `_logDispatch` function from `LotLabel/code.py` (lines 102–124), and delete the now-unused module constant:

```python
_SYSTEM_NAME = "Zebra"
```

Every call site becomes:

```python
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "LTT")
```

> This is where the `execList` regression gets resolved: `LabelTransport.logDispatch` (Task 1) uses `execNonQuery`, which is what the `"type": "UpdateQuery"` NQ requires per `Common.Db.execNonQuery`'s own docstring. It keeps the bare `except:` — that half of the uncommitted change was correct, because Jython's `except Exception` does not catch `java.lang.Throwable`.

- [ ] **Step 3: Point the dispatch tail at `LabelTransport`**

In `_dispatchAfterRender`, replace the first `_dispatchZpl` / `_logDispatch` pair:

```python
    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "LTT")
```

and the retry pair:

```python
        outcome = BlueRidge.Lots.LabelTransport.send(freshEndpoint, zpl)
        BlueRidge.Lots.LabelTransport.logDispatch(freshEndpoint, zpl, outcome, "LTT")
```

Everything else in that function is unchanged — same re-resolve, same single retry, same return shapes.

- [ ] **Step 4: Apply the same treatment to `ShippingDispatcher/code.py`**

Delete its `_dispatchZpl` (lines 104–129), its `_logDispatch` (lines 132–151), the `_SYSTEM_NAME` constant, and the two `java.net` / `java.lang` imports. Add `import BlueRidge.Lots.LabelTransport`. In both `dispatch` and `dispatchContainer`, replace each dispatch/log pair with:

```python
    outcome = BlueRidge.Lots.LabelTransport.send(endpoint, zpl)
    BlueRidge.Lots.LabelTransport.logDispatch(endpoint, zpl, outcome, "Shipping label")
```

- [ ] **Step 5: Verify no duplicated transport or logging code remains**

```bash
grep -rn "_dispatchZpl\|_logDispatch\|from java.net import Socket\|_SYSTEM_NAME" ignition/projects/Core/ignition/script-python/BlueRidge/Lots/
```

Expected: `_SYSTEM_NAME` matches only inside `LabelTransport/code.py`; `_dispatchZpl`, `_logDispatch` and the `java.net` import produce **no matches at all** (the transport module names its socket import inside `_sendTcp`).

- [ ] **Step 6: Smoke the LTT path end to end**

Run `.\scan.ps1`. With `usb_tcp_bridge.py` running on the Gateway host, set a test terminal's printer `Endpoint` to `127.0.0.1:9100` via the Config Tool Plant Hierarchy, then reprint a label from LOT Detail.
Expected: toast `LTT reprinted`; bridge shows bytes received; `Audit.InterfaceLog` has a row whose Description reads `LTT dispatch via tcp to 127.0.0.1:9100`.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotLabel/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py
git commit -m "refactor(labels): both dispatchers onto LabelTransport; fix InterfaceLog NQ call"
```

---

## Task 3: `LabelTypes` attribute + `Terminal_GetPrinter` v2.0

**Files:**
- Create: `sql/migrations/versioned/0045_label_type_routing.sql`
- Modify: `sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Location.Terminal_GetPrinter @TerminalLocationId BIGINT, @LabelTypeCode NVARCHAR(50) = NULL` returning columns `LocationId, Code, Name, Endpoint, Model, LabelTypes` (six columns — one more than v1).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql`:

```sql
-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-28
-- Description:  Location.Terminal_GetPrinter v2.0 label-type routing.
--               Asserts:
--                 * @LabelTypeCode matches a printer whose LabelTypes CSV contains it
--                 * no match -> falls back to the terminal's TOP 1 by SortOrder
--                 * blank LabelTypes -> always the fallback (backward compatible)
--                 * @LabelTypeCode NULL -> v1 behaviour exactly (TOP 1 by SortOrder)
--                 * terminal with no printer child -> empty rowset
--
--               Fixture subtree under the Site (MPP-MAD):
--                 TEST-LTR-TERM (Terminal, DefId 7)
--                   +- TEST-LTR-P1 (Printer, DefId 16, SortOrder 1, LabelTypes 'Primary')
--                   +- TEST-LTR-P2 (Printer, DefId 16, SortOrder 2, LabelTypes 'Container')
--                 TEST-LTR-TERM2 (Terminal, DefId 7)
--                   +- TEST-LTR-P3 (Printer, DefId 16, SortOrder 1, LabelTypes blank)
--                 TEST-LTR-TERM3 (Terminal, DefId 7, NO printer)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql';
GO

-- ---- teardown (attributes, then children, then parents) ----
DELETE FROM Location.LocationAttribute
WHERE LocationId IN (SELECT Id FROM Location.Location
                     WHERE Code IN (N'TEST-LTR-P1', N'TEST-LTR-P2', N'TEST-LTR-P3'));
DELETE FROM Location.Location WHERE Code IN (N'TEST-LTR-P1', N'TEST-LTR-P2', N'TEST-LTR-P3');
DELETE FROM Location.Location WHERE Code IN (N'TEST-LTR-TERM', N'TEST-LTR-TERM2', N'TEST-LTR-TERM3');
GO

-- ---- fixture ----
DECLARE @SiteId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (7, @SiteId, N'LTR Terminal',   N'TEST-LTR-TERM',  N'Label routing test terminal', 960),
       (7, @SiteId, N'LTR Terminal 2', N'TEST-LTR-TERM2', N'Blank LabelTypes terminal',   961),
       (7, @SiteId, N'LTR Terminal 3', N'TEST-LTR-TERM3', N'No printer terminal',         962);

DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM2');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @T1, N'LTR Printer 1', N'TEST-LTR-P1', N'Primary label printer',   1),
       (16, @T1, N'LTR Printer 2', N'TEST-LTR-P2', N'Container label printer', 2),
       (16, @T2, N'LTR Printer 3', N'TEST-LTR-P3', N'Blank LabelTypes',        1);

DECLARE @EpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint');
DECLARE @LtDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'LabelTypes');

INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
SELECT Id, @EpDef, N'10.0.0.1:9100' FROM Location.Location WHERE Code = N'TEST-LTR-P1'
UNION ALL SELECT Id, @EpDef, N'10.0.0.2:9100' FROM Location.Location WHERE Code = N'TEST-LTR-P2'
UNION ALL SELECT Id, @EpDef, N'10.0.0.3:9100' FROM Location.Location WHERE Code = N'TEST-LTR-P3'
UNION ALL SELECT Id, @LtDef, N'Primary'       FROM Location.Location WHERE Code = N'TEST-LTR-P1'
UNION ALL SELECT Id, @LtDef, N'Container,Master' FROM Location.Location WHERE Code = N'TEST-LTR-P2';
GO

-- =============================================
-- Test 1: 'Container' routes to P2, not the SortOrder-1 printer
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R1 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R1 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1, @LabelTypeCode = N'Container';
SELECT @Code = Code FROM #R1; DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Container routes to the Container printer',
    @Expected = N'TEST-LTR-P2', @Actual = @Code;
GO

-- =============================================
-- Test 2: second CSV entry ('Master') also matches P2
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R2 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R2 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1, @LabelTypeCode = N'Master';
SELECT @Code = Code FROM #R2; DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Second CSV entry matches',
    @Expected = N'TEST-LTR-P2', @Actual = @Code;
GO

-- =============================================
-- Test 3: unmatched label type falls back to TOP 1 by SortOrder
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R3 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R3 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1, @LabelTypeCode = N'Void';
SELECT @Code = Code FROM #R3; DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Unmatched type falls back to SortOrder 1',
    @Expected = N'TEST-LTR-P1', @Actual = @Code;
GO

-- =============================================
-- Test 4: blank LabelTypes -> fallback (backward compatible)
-- =============================================
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM2');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R4 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R4 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T2, @LabelTypeCode = N'Container';
SELECT @Code = Code FROM #R4; DROP TABLE #R4;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] Blank LabelTypes still resolves via fallback',
    @Expected = N'TEST-LTR-P3', @Actual = @Code;
GO

-- =============================================
-- Test 5: NULL label type reproduces v1 behaviour (regression guard)
-- =============================================
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM');
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R5 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R5 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T1;
SELECT @Code = Code FROM #R5; DROP TABLE #R5;
EXEC test.Assert_IsEqual @TestName = N'[LabelRouting] NULL label type = v1 TOP 1 by SortOrder',
    @Expected = N'TEST-LTR-P1', @Actual = @Code;
GO

-- =============================================
-- Test 6: terminal with no printer child -> empty rowset
-- =============================================
DECLARE @T3 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-LTR-TERM3');
DECLARE @Rows INT;
CREATE TABLE #R6 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(200), Model NVARCHAR(200), LabelTypes NVARCHAR(200));
INSERT INTO #R6 EXEC Location.Terminal_GetPrinter @TerminalLocationId = @T3, @LabelTypeCode = N'Primary';
SELECT @Rows = COUNT(*) FROM #R6; DROP TABLE #R6;
EXEC test.Assert_RowCount @TestName = N'[LabelRouting] Terminal with no printer -> empty set',
    @ExpectedCount = 0, @ActualCount = @Rows;
GO
```

- [ ] **Step 2: Run it to verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "030_Terminal_GetPrinter_label_routing"
```

Expected: failure — `LabelTypes` attribute definition does not exist, and `@LabelTypeCode` is not a parameter of the proc.

- [ ] **Step 3: Add the `LabelTypes` attribute definition — in the SEED layer, not the migration**

> **Correction applied during execution (2026-07-28).** This step originally put the
> `LabelTypes` `LocationAttributeDefinition` insert into migration `0045`. That is **wrong and
> would fail every fresh build**: the insert FKs to `LocationTypeDefinitionId = 16` (`Printer`),
> and that row is created only by the **seed** (`sql/seeds/011_seed_locations_mpp_plant.sql`,
> generated from `sql/seeds/gen_locations_mpp.js`) — no versioned migration creates it.
> `Reset-DevDatabase.ps1` runs versioned migrations at step **4/6** and seeds at step **6/6**, so
> at migration time the FK target does not yet exist. The sibling `Endpoint` and `Model`
> attributes for the same DefId are seeded for exactly this reason; `LabelTypes` follows that
> precedent.

Add to `sql/seeds/gen_locations_mpp.js`, immediately after the existing `Model` attribute block:

```javascript
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'LabelTypes')
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES (16, N'LabelTypes', N'NVARCHAR', 0, NULL, NULL, 3, N'Comma-separated Lots.LabelTypeCode codes this printer serves (Primary,Container,Master,Void). Blank = any.');
```

Then regenerate both generated artifacts so they do not drift from the generator:

```bash
node sql/seeds/gen_locations_mpp.js
```

This rewrites `sql/seeds/011_seed_locations_mpp_plant.sql` and `sql/scripts/reconcile_location_dev.sql`.

- [ ] **Step 3b: Write migration `0045`**

With the attribute definition moved to the seed layer, `0045` carries only the ASCII correction.
Create `sql/migrations/versioned/0045_label_type_routing.sql`:

```sql
-- ============================================================
-- Migration:   0045_label_type_routing.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-28
-- Description: Dual-transport label printing (design 2026-07-28) part 1.
--                ~ Lots.PrintReasonCode Id 2 name em-dash -> ASCII hyphen. The
--                  0004 seed wrote 'Reprint - Damaged' with an em-dash, which
--                  mojibakes through sqlcmd (repo ASCII-only rule; tracked P4-7).
--              Idempotent (re-apply = no-op). ASCII-only strings.
-- ============================================================

UPDATE Lots.PrintReasonCode
SET Name = N'Reprint - Damaged'
WHERE Id = 2 AND Name <> N'Reprint - Damaged';
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0045_label_type_routing')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0045_label_type_routing',
            N'Label-type printer routing: Printer.LabelTypes attribute definition; PrintReasonCode 2 em-dash corrected to ASCII.');
GO

PRINT 'Migration 0045 (label-type routing) applied.';
GO
```

- [ ] **Step 4: Rewrite `Terminal_GetPrinter` as v2.0**

Replace the body of `sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_Terminal_GetPrinter.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     2.0
-- Description: Resolves a Terminal's child Printer Location + its Endpoint / Model /
--              LabelTypes attribute values, for the onStartup session resolution and
--              the label dispatch path.
--
--              v2.0 (design 2026-07-28 sec 3.4): optional @LabelTypeCode routes to the
--              printer whose LabelTypes CSV contains that code. No match -- or a blank
--              LabelTypes, or @LabelTypeCode NULL -- FALLS BACK to the terminal's first
--              printer by SortOrder, which is v1 behaviour exactly. That fallback is
--              what makes every existing caller and every seeded printer unaffected.
--
--              Read proc: one row or empty when the terminal has no Printer child (the
--              no-printer / FALLBACK terminal case -> fail-fast on dispatch). All three
--              attributes LEFT-joined so a row returns even when a value is unset.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetPrinter
    @TerminalLocationId BIGINT,
    @LabelTypeCode      NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Candidates AS (
        SELECT
            p.Id               AS LocationId,
            p.Code             AS Code,
            p.Name             AS Name,
            epv.AttributeValue AS Endpoint,
            mdv.AttributeValue AS Model,
            ltv.AttributeValue AS LabelTypes,
            p.SortOrder        AS SortOrder,
            -- 0 sorts ahead of 1: an explicit label-type match wins, everything
            -- else falls through to the SortOrder ordering below.
            CASE WHEN @LabelTypeCode IS NOT NULL
                  AND ltv.AttributeValue IS NOT NULL
                  AND N',' + REPLACE(ltv.AttributeValue, N' ', N'') + N','
                      LIKE N'%,' + @LabelTypeCode + N',%'
                 THEN 0 ELSE 1 END AS MatchRank
        FROM Location.Location p
        INNER JOIN Location.LocationTypeDefinition def ON def.Id = p.LocationTypeDefinitionId
        LEFT JOIN Location.LocationAttributeDefinition epd
            ON epd.LocationTypeDefinitionId = def.Id AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
        LEFT JOIN Location.LocationAttribute epv
            ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
        LEFT JOIN Location.LocationAttributeDefinition mdd
            ON mdd.LocationTypeDefinitionId = def.Id AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
        LEFT JOIN Location.LocationAttribute mdv
            ON mdv.LocationId = p.Id AND mdv.LocationAttributeDefinitionId = mdd.Id
        LEFT JOIN Location.LocationAttributeDefinition ltd
            ON ltd.LocationTypeDefinitionId = def.Id AND ltd.AttributeName = N'LabelTypes' AND ltd.DeprecatedAt IS NULL
        LEFT JOIN Location.LocationAttribute ltv
            ON ltv.LocationId = p.Id AND ltv.LocationAttributeDefinitionId = ltd.Id
        WHERE p.ParentLocationId = @TerminalLocationId
          AND def.Name = N'Printer'
          AND p.DeprecatedAt IS NULL
    )
    SELECT TOP 1
        LocationId, Code, Name, Endpoint, Model, LabelTypes
    FROM Candidates
    ORDER BY MatchRank, SortOrder, LocationId;
END;
GO
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "030_Terminal_GetPrinter_label_routing"
```

Expected: 6 assertions, 0 failures.

- [ ] **Step 6: Run the FULL suite — the proc's result shape changed**

`Terminal_GetPrinter` gained a sixth column, so any fixed-shape `INSERT-EXEC` capture over it breaks. Per the repo rule, check both the runner's exit code and the output:

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

Expected: no `FAIL:` lines and no `ERROR running` lines. `sql/tests/0020_PlantFloor_Foundation/015_Terminal_ContextCells_List.sql` exercises `Terminal_List`/`HasPrinter` rather than this proc, but confirm it stays green.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/versioned/0045_label_type_routing.sql sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql sql/tests/0025_PlantFloor_Label_Dispatch/030_Terminal_GetPrinter_label_routing.sql
git commit -m "feat(labels): label-type printer routing on Terminal_GetPrinter v2.0"
```

---

## Task 4: Wire label-type routing through Ignition

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/location/Terminal_GetPrinter/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/location/Terminal_GetPrinter/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotLabel/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py`

**Interfaces:**
- Consumes: `Location.Terminal_GetPrinter @TerminalLocationId, @LabelTypeCode` (Task 3).
- Produces: `Terminal.getPrinter(terminalLocationId, labelTypeCode=None) -> {locationId, code, endpoint, model, labelTypes}` — note the new fifth key.

- [ ] **Step 1: Add the NQ parameter**

`query.sql`:

```sql
EXEC Location.Terminal_GetPrinter
    @TerminalLocationId = :terminalLocationId,
    @LabelTypeCode      = :labelTypeCode
```

In `resource.json`, replace the `parameters` array:

```json
    "parameters": [
      { "type": "Parameter", "identifier": "terminalLocationId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "labelTypeCode",      "sqlType": 7 }
    ]
```

- [ ] **Step 2: Widen `Terminal.getPrinter`**

Replace `getPrinter` in `BlueRidge/Location/Terminal/code.py` (lines 147–164):

```python
def getPrinter(terminalLocationId, labelTypeCode=None):
    """Resolve the terminal's Printer Location + its Endpoint/Model/LabelTypes values.
       labelTypeCode (a Lots.LabelTypeCode Code such as 'Primary' or 'Container')
       routes to the printer serving that type; the proc falls back to the terminal's
       first printer when nothing matches, so omitting it is v1 behaviour.
       Returns {locationId, code, endpoint, model, labelTypes} or {} (the fail-fast case)."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    ltc = BlueRidge.Common.Util.extractQualifiedValues(labelTypeCode)
    BlueRidge.Common.Util.log("terminalLocationId=%s labelTypeCode=%s" % (tid, ltc))
    if tid is None:
        return {}
    row = BlueRidge.Common.Db.execOne("location/Terminal_GetPrinter",
                                      {"terminalLocationId": tid, "labelTypeCode": ltc})
    if not row:
        return {}
    return {
        "locationId": row.get("LocationId"),
        "code":       row.get("Code") or "",
        "endpoint":   row.get("Endpoint") or "",
        "model":      row.get("Model") or "",
        "labelTypes": row.get("LabelTypes") or "",
    }
```

> `applyToSession` calls `getPrinter(tid)` with no label type and keeps writing `session.custom.printer` as the terminal's default. Leave it unchanged — per design §3.5 the session holds the fallback printer, and label-type resolution happens at dispatch time.

- [ ] **Step 3: Resolve by label type in `LotLabel._dispatchAfterRender`**

Change the signature and the resolution block. Replace the function's first resolution section:

```python
def _dispatchAfterRender(res, appUserId, terminalLocationId, labelTypeCode=None):
    """Shared tail for printLabel/reprint: take a render result (Status, Message,
       NewId=LotLabelId, ZplContent), dispatch the ZPL, log, ack on success, with
       one endpoint re-resolve + retry on failure. Returns a UI status dict."""
    if not res or not res.get("Status"):
        return res
    lotLabelId = res.get("NewId")
    zpl = res.get("ZplContent") or ""

    # Resolve by label type first (design sec 3.5): resolving fresh also sidesteps the
    # stale-session bug where a printer configured mid-session stays invisible until
    # a restart. Fall back to the session printer when the DB read yields nothing.
    printer = {}
    if terminalLocationId is not None:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId, labelTypeCode) or {}
    if not (printer.get("endpoint") or "").strip():
        printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    printerCode = printer.get("code") or ""
```

Delete the now-redundant `if not endpoint and terminalLocationId is not None:` re-resolve block that followed (the fresh read above replaces it). Keep the fail-fast `if not endpoint:` block, the dispatch, the log, the ack, and the retry block exactly as they are.

- [ ] **Step 4: Pass the label type from both entry points**

In `printLabel`, the label type is already resolved as an id. Pass its code through — replace the final line:

```python
    return _dispatchAfterRender(res, appUserId, terminalLocationId,
                                _labelTypeCodeById(labelTypeCodeId))
```

In `reprint`, the reprint reuses the LOT's Primary label type:

```python
    return _dispatchAfterRender(res, appUserId, terminalLocationId, "Primary")
```

Add the id→code resolver next to the existing `_labelTypeIdByCode` helper:

```python
def _labelTypeCodeById(labelTypeCodeId):
    """Resolve a Lots.LabelTypeCode Code by Id (routing needs the code, the procs
       take the id). Returns the Code or None."""
    if labelTypeCodeId is None:
        return None
    for r in (BlueRidge.Common.Db.execList("lots/LabelTypeCode_List") or []):
        if r.get("Id") == labelTypeCodeId:
            return r.get("Code")
    return None
```

- [ ] **Step 5: Route container labels to the Container printer**

In `ShippingDispatcher.dispatchContainer`, replace its resolution block:

```python
    printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId, "Container") or {}
    if not (printer.get("endpoint") or "").strip():
        printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    if not endpoint:
        return {"Status": 0, "Message": "This terminal has no printer configured."}
```

Apply the same three lines to the legacy `dispatch()` function.

- [ ] **Step 6: Verify routing from the Script Console**

```python
import BlueRidge.Location.Terminal as T
tid = <a terminal location id with two printers>
print T.getPrinter(tid)
print T.getPrinter(tid, "Container")
print T.getPrinter(tid, "Primary")
```

Expected: the bare call and `"Primary"` return the SortOrder-1 printer; `"Container"` returns the Container printer once you set its `LabelTypes` to `Container` in the Config Tool.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/location/Terminal_GetPrinter ignition/projects/Core/ignition/script-python/BlueRidge/Location/Terminal/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotLabel/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py
git commit -m "feat(labels): route dispatch to the printer serving the label type"
```

---

## Task 5: `ShippingLabel_RecordDispatch` + container template in the DB

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ShippingLabel_RecordDispatch.sql`
- Create: `sql/migrations/versioned/0046_container_label_template.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_RecordDispatch/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_RecordDispatch/resource.json`
- Test: `sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Lots.ShippingLabel_RecordDispatch @ShippingLabelId BIGINT, @Success BIT, @ErrorText NVARCHAR(500) = NULL, @MaxAttempts INT = 3` returning `Status, Message`. NQ path `lots/ShippingLabel_RecordDispatch`, type `Query`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql`:

```sql
-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-28
-- Description:  Lots.ShippingLabel_RecordDispatch write-back.
--               Asserts:
--                 * success -> PrintedAt set, LastPrintError cleared
--                 * failure -> PrintAttempts incremented, LastPrintError stored,
--                              PrintFailedAt still NULL below the attempt cap
--                 * failure at the cap -> PrintFailedAt set
--                 * unknown ShippingLabelId -> Status = 0
--
--               Fixture is SELF-CONTAINED: Run-Tests.ps1 resets with -SkipDemoSeed, so
--               Lots.Container is EMPTY -- never reuse "TOP 1 existing container". Opens
--               its own container via Lots.Container_Open (house pattern, cf.
--               0028_PlantFloor_Assembly/040) and inserts BOTH ShippingLabel rows up
--               front, so later batches look labels up by AimShipperId and never need
--               the container id again.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql';
GO

DELETE FROM Lots.ShippingLabel WHERE AimShipperId LIKE N'TESTRD%';
GO

-- ---- self-contained container fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'RD-SHIP-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'RD-SHIP-TEST', N'RecordDispatch test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RD-SHIP-TEST');

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 4, 25, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');

-- Both labels created up front: later batches resolve them by AimShipperId.
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId)
VALUES (@ContainerId, N'TESTRD0001', @LabelType, 1, 1),
       (@ContainerId, N'TESTRD0002', @LabelType, 1, 1);
GO

-- =============================================
-- Test 1: success sets PrintedAt and clears the error
-- =============================================
DECLARE @Id BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'TESTRD0001');
DECLARE @Status BIT, @PrintedAt DATETIME2(3), @Err NVARCHAR(500);
CREATE TABLE #S1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S1 EXEC Lots.ShippingLabel_RecordDispatch @ShippingLabelId = @Id, @Success = 1;
SELECT @Status = Status FROM #S1; DROP TABLE #S1;
SELECT @PrintedAt = PrintedAt, @Err = LastPrintError FROM Lots.ShippingLabel WHERE Id = @Id;
EXEC test.Assert_IsTrue   @TestName = N'[ShipDispatch] success returns Status=1', @Condition = @Status;
EXEC test.Assert_IsNotNull @TestName = N'[ShipDispatch] success sets PrintedAt',  @Value = @PrintedAt;
EXEC test.Assert_IsNull   @TestName = N'[ShipDispatch] success clears LastPrintError', @Value = @Err;
GO

-- =============================================
-- Test 2: failure increments attempts, stores the error, no PrintFailedAt yet
-- =============================================
DECLARE @Id BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'TESTRD0002');
DECLARE @Attempts INT, @Err NVARCHAR(500), @FailedAt DATETIME2(3);
CREATE TABLE #S2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S2 EXEC Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId = @Id, @Success = 0, @ErrorText = N'connection refused';
DROP TABLE #S2;
SELECT @Attempts = PrintAttempts, @Err = LastPrintError, @FailedAt = PrintFailedAt
FROM Lots.ShippingLabel WHERE Id = @Id;
EXEC test.Assert_IsEqual @TestName = N'[ShipDispatch] failure increments PrintAttempts to 1',
    @Expected = N'1', @Actual = @Attempts;
EXEC test.Assert_IsEqual @TestName = N'[ShipDispatch] failure stores LastPrintError',
    @Expected = N'connection refused', @Actual = @Err;
EXEC test.Assert_IsNull @TestName = N'[ShipDispatch] below cap leaves PrintFailedAt NULL',
    @Value = @FailedAt;
GO

-- =============================================
-- Test 3: failure at the attempt cap sets PrintFailedAt
-- =============================================
DECLARE @Id BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'TESTRD0002');
DECLARE @FailedAt DATETIME2(3);
CREATE TABLE #S3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S3 EXEC Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId = @Id, @Success = 0, @ErrorText = N'connection refused';
INSERT INTO #S3 EXEC Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId = @Id, @Success = 0, @ErrorText = N'connection refused';
DROP TABLE #S3;
SELECT @FailedAt = PrintFailedAt FROM Lots.ShippingLabel WHERE Id = @Id;
EXEC test.Assert_IsNotNull @TestName = N'[ShipDispatch] third failure sets PrintFailedAt',
    @Value = @FailedAt;
GO

-- =============================================
-- Test 4: unknown id -> Status = 0
-- =============================================
DECLARE @Status BIT;
CREATE TABLE #S4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #S4 EXEC Lots.ShippingLabel_RecordDispatch @ShippingLabelId = -1, @Success = 1;
SELECT @Status = Status FROM #S4; DROP TABLE #S4;
EXEC test.Assert_IsEqual @TestName = N'[ShipDispatch] unknown id -> Status=0',
    @Expected = N'0', @Actual = @Status;
GO

-- ---- teardown: labels first, then the containers they referenced, so a re-run
-- ---- does not accumulate a fresh Container_Open row every time.
DELETE FROM Lots.ShippingLabel WHERE AimShipperId LIKE N'TESTRD%';
DELETE FROM Lots.Container
WHERE ItemId = (SELECT Id FROM Parts.Item WHERE PartNumber = N'RD-SHIP-TEST');
GO
```

- [ ] **Step 2: Run it to verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "040_ShippingLabel_RecordDispatch"
```

Expected: failure — `Could not find stored procedure 'Lots.ShippingLabel_RecordDispatch'`.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Lots_ShippingLabel_RecordDispatch.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_ShippingLabel_RecordDispatch.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     1.0
-- Description: Dispatch write-back for a container shipping label (design 2026-07-28
--              sec 3.7). Mirrors Lots.LotLabel_RecordDispatch.
--                @Success = 1 -> PrintedAt + LastPrintAttemptAt set, error cleared.
--                @Success = 0 -> PrintAttempts incremented, LastPrintAttemptAt and
--                                LastPrintError stored; PrintFailedAt set once
--                                attempts reach @MaxAttempts (FDS-07-006a: 3).
--              These five columns exist since 0028 and NOTHING wrote them until now;
--              the FDS-07-006b stranded-print sweep reads them, so populating them is
--              what makes that sweep buildable later (the sweep itself is out of scope).
--              Status-row proc (NQ type=Query). No audit row -- the dispatch attempt
--              logs to Audit.InterfaceLog via the entity script. No OUTPUT params;
--              RAISERROR (not THROW) in the CATCH.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId BIGINT,
    @Success         BIT,
    @ErrorText       NVARCHAR(500) = NULL,
    @MaxAttempts     INT           = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @ShippingLabelId IS NULL OR @Success IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShippingLabelId, Success).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.ShippingLabel WHERE Id = @ShippingLabelId)
        BEGIN
            SET @Message = N'Shipping label not found.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @Success = 1
        BEGIN
            UPDATE Lots.ShippingLabel
            SET PrintedAt          = SYSUTCDATETIME(),
                LastPrintAttemptAt = SYSUTCDATETIME(),
                LastPrintError     = NULL,
                PrintFailedAt      = NULL
            WHERE Id = @ShippingLabelId;

            SET @Message = N'Print recorded.';
        END
        ELSE
        BEGIN
            UPDATE Lots.ShippingLabel
            SET PrintAttempts      = PrintAttempts + 1,
                LastPrintAttemptAt = SYSUTCDATETIME(),
                LastPrintError     = @ErrorText,
                PrintFailedAt      = CASE WHEN PrintAttempts + 1 >= @MaxAttempts
                                          THEN SYSUTCDATETIME() ELSE PrintFailedAt END
            WHERE Id = @ShippingLabelId;

            SET @Message = N'Print failure recorded.';
        END

        SET @Status = 1;
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "040_ShippingLabel_RecordDispatch"
```

Expected: 8 assertions, 0 failures.

- [ ] **Step 5: Move the container ZPL into `Lots.LabelTemplate`**

Create `sql/migrations/versioned/0046_container_label_template.sql`. The body is the flattened Honda container label with `{Token}` placeholders — ASCII-only, no apostrophes, so it is safe as a single `N'...'` literal.

```sql
-- ============================================================
-- Migration:   0046_container_label_template.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-28
-- Description: Dual-transport label printing (design 2026-07-28) part 2.
--              Replaces the ACTIVE 'Container' LabelTemplate body. The 0021 seed
--              gave ALL FOUR label types the same LOT-shaped placeholder ZPL, so a
--              Container-type render produced a lot label; and the real container
--              layout lived as a hard-coded Python constant in
--              BlueRidge.Lots.ShippingDispatcher, which FDS sec 2064 forbids
--              ("ZPL templates SHALL be configurable, not hard-coded").
--
--              Layout flattened from zebraPrinter/Label Template - Container.zpl;
--              positions/fonts/lines preserved. Tokens resolve from
--              Lots.Container_GetLabelData. The Honda-specific fields (PartExt,
--              PartLevel, Auditor) render blank until sourced, and their un-sourced
--              barcodes (2D DataMatrix, part-ext, part-level) are omitted. ^PQ2 = 2
--              copies, per the source label.
--              Idempotent (re-apply = no-op). ASCII-only.
-- ============================================================

UPDATE Lots.LabelTemplate
SET ZplBody =
    N'^XA^POI' +
    N'^A0R,24,26^FO740,20^FDPART NO. (P)^FS' +
    N'^A0R,86,86^FO690,200^FD{PartNumber}^FS' +
    N'^A0R^FO600,70^BY3^B3,,100,N,^FD{PartNumber}^FS' +
    N'^A0R,24,24^FO550,20^FDPART NO. EXT (C)^FS' +
    N'^A0R,72,72^FO480,70^FD{PartExt}^FS' +
    N'^A0R,24,24^FO550,670^FDDESCRIPTION^FS' +
    N'^A0R,45,36^FO500,670^FD{Description}^FS' +
    N'^A0R,24,24^FO460,670^FDMFG LOT NUMBER^FS' +
    N'^A0R,45,36^FO410,670^FD{MfgLotNumber}^FS' +
    N'^A0R,24,24^FO460,1070^FDMFG DATE^FS' +
    N'^A0R,45,36^FO410,1070^FD{MfgDate}^FS' +
    N'^A0R,24,24^FO460,940^FDAUDIT^FS' +
    N'^A0R,45,36^FO420,940^FD{Auditor}^FS' +
    N'^A0R,24,24^FO370,20^FDD/C PART LEVEL (2P)^FS' +
    N'^A0R,72,72^FO300,70^FD{PartLevel}^FS' +
    N'^A0R^FO320,720^BY3^B3,,75,N,^FDQ{Quantity}^FS' +
    N'^A0R,72,72^FO240,720^FD{Quantity}^FS' +
    N'^A0R,24,24^FO230,670^FDQUANTITY (Q)^FS' +
    N'^A0R,24,24^FO190,20^FDSERIAL (1S)^FS' +
    N'^A0R,72,72^FO140,200^FD{Serial}^FS' +
    N'^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS' +
    N'^A0R,24,24^FO20,20^FDMade In / C.O.O.                                               Madison Precision Products Inc., 94 E 400 North, Madison, IN 47250^FS' +
    N'^A0R,24,24^FO20,220^FD{CountryOfOrigin}^FS' +
    N'^FO580,10^GB0,1300,3^FS' +
    N'^FO490,650^GB0,905,3^FS' +
    N'^FO400,10^GB0,1300,3^FS' +
    N'^FO220,10^GB0,1300,3^FS' +
    N'^FO220,650^GB360,0,3^FS' +
    N'^PQ2' +
    N'^XZ'
WHERE LabelTypeCodeId = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container')
  AND DeprecatedAt IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0046_container_label_template')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0046_container_label_template',
            N'Honda container shipping-label ZPL moved from a Python constant into the active Container LabelTemplate.');
GO

PRINT 'Migration 0046 (container label template) applied.';
GO
```

- [ ] **Step 6: Verify the template is ASCII-only**

Non-ASCII in a ZPL body becomes mojibake through `sqlcmd`. Confirm before applying:

```bash
powershell -Command "$b=[IO.File]::ReadAllBytes('sql/migrations/versioned/0046_container_label_template.sql'); ($b | Where-Object { $_ -gt 127 }).Count"
```

Expected: `0`.

- [ ] **Step 7: Create the write-back named query**

`ignition/projects/Core/ignition/named-query/lots/ShippingLabel_RecordDispatch/query.sql`:

```sql
EXEC Lots.ShippingLabel_RecordDispatch
    @ShippingLabelId = :shippingLabelId,
    @Success         = :success,
    @ErrorText       = :errorText
```

`resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-07-28T12:00:00Z"
    },
    "parameters": [
      { "type": "Parameter", "identifier": "shippingLabelId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "success",         "sqlType": 6 },
      { "type": "Parameter", "identifier": "errorText",       "sqlType": 7 }
    ]
  }
}
```

- [ ] **Step 8: Run the full suite**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

Expected: no `FAIL:` lines and no `ERROR running` lines.

- [ ] **Step 9: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ShippingLabel_RecordDispatch.sql sql/migrations/versioned/0046_container_label_template.sql sql/tests/0025_PlantFloor_Label_Dispatch/040_ShippingLabel_RecordDispatch.sql ignition/projects/Core/ignition/named-query/lots/ShippingLabel_RecordDispatch
git commit -m "feat(labels): ShippingLabel dispatch write-back + container ZPL into LabelTemplate"
```

---

## Task 6: Wire container-label dispatch

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Shipping/code.py`
- Create: `sql/migrations/repeatable/R__Lots_LabelTemplate_GetActiveByTypeCode.sql`
- Create: `sql/migrations/repeatable/R__Lots_ShippingLabel_GetContainerId.sql`
- Create: `ignition/projects/Core/ignition/named-query/lots/LabelTemplate_GetActiveByTypeCode/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetContainerId/{query.sql,resource.json}`

**Interfaces:**
- Consumes: `LabelTransport.send` (Task 1), `Terminal.getPrinter(tid, labelTypeCode)` (Task 4), NQ `lots/ShippingLabel_RecordDispatch` (Task 5).
- Produces: `ShippingDispatcher.dispatchContainer(containerId, terminalLocationId=None, shippingLabelId=None) -> {Status, Message}`.

- [ ] **Step 1: Render the container template from the DB**

In `ShippingDispatcher/code.py`, delete the `_CONTAINER_TEMPLATE` module constant and replace `_renderContainerLabel`:

```python
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
```

Create the supporting read proc `sql/migrations/repeatable/R__Lots_LabelTemplate_GetActiveByTypeCode.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_LabelTemplate_GetActiveByTypeCode.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     1.0
-- Description: Returns the ACTIVE Lots.LabelTemplate.ZplBody for a LabelTypeCode
--              Code, so a Python renderer can fetch a configurable template instead
--              of carrying a hard-coded constant (design 2026-07-28 sec 3.8).
--              Read proc; empty rowset = no active template for that code.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.LabelTemplate_GetActiveByTypeCode
    @LabelTypeCode NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabelTypeCode IS NULL
        RETURN;

    SELECT TOP 1 t.Id AS Id, t.ZplBody AS ZplBody
    FROM Lots.LabelTemplate t
    INNER JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
    WHERE c.Code = @LabelTypeCode
      AND t.DeprecatedAt IS NULL
    ORDER BY t.Id DESC;
END;
GO
```

Create `ignition/projects/Core/ignition/named-query/lots/LabelTemplate_GetActiveByTypeCode/query.sql`:

```sql
EXEC Lots.LabelTemplate_GetActiveByTypeCode
    @LabelTypeCode = :labelTypeCode
```

And `ignition/projects/Core/ignition/named-query/lots/LabelTemplate_GetActiveByTypeCode/resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-07-28T12:00:00Z"
    },
    "parameters": [
      { "type": "Parameter", "identifier": "labelTypeCode", "sqlType": 7 }
    ]
  }
}
```

- [ ] **Step 2: Add the write-back to `dispatchContainer`**

Replace `dispatchContainer` in `ShippingDispatcher/code.py`:

```python
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
```

- [ ] **Step 3: Give `Container.complete` a dispatch tail**

In `BlueRidge/Lots/Container/code.py`, add `import BlueRidge.Lots.ShippingDispatcher` to the import block and replace the tail of `complete`:

```python
    result = BlueRidge.Common.Db.execMutation("lots/Container_Complete", params)
    # Print the container's shipping label. Mirrors Workorder.Machining.mint: check the
    # RETURNED Status (dispatchContainer does not raise for the common shop-floor cases)
    # AND catch genuine exceptions -- either way NEVER lose the completed container.
    # Complete and print are separate steps (FDS-07-005/006a).
    if result and result.get("Status") and result.get("ShippingLabelId") is not None:
        try:
            printRes = BlueRidge.Lots.ShippingDispatcher.dispatchContainer(
                containerId, terminalLocationId, result.get("ShippingLabelId"))
        except Exception as e:
            printRes = {"Status": 0, "Message": "print raised: %s" % e}
        result["LabelPrint"] = printRes
        if not (printRes and printRes.get("Status")):
            BlueRidge.Common.Util.log(
                "Container shipping label print failed: %s" % (printRes or {}).get("Message"))
            BlueRidge.Common.Notify.toast(
                "Label not printed",
                "The container was completed but its shipping label did not print. "
                "Reprint from the Shipping Dock.",
                "warning")
    return result
```

Add `import BlueRidge.Common.Notify` to the import block if it is not already there.

> `Assembly.handleTrayComplete` already routes through `Container.complete`, so it inherits the print from this one wiring point. No change there.

- [ ] **Step 4: Give `Shipping.reprintLabel` the same tail**

Today it writes a `ShippingLabel` row and prints nothing, while the Shipping Dock reports *"Label reprinted"*. In `BlueRidge/Lots/Shipping/code.py`, add `import BlueRidge.Lots.ShippingDispatcher` and replace the tail of `reprintLabel`:

```python
    result = BlueRidge.Common.Db.execMutation("lots/ShippingLabel_Reprint", params)
    if result and result.get("Status") and result.get("NewId") is not None:
        containerId = (BlueRidge.Common.Db.execOne(
            "lots/ShippingLabel_GetContainerId", {"shippingLabelId": result.get("NewId")}) or {}
        ).get("ContainerId")
        if containerId is not None:
            try:
                printRes = BlueRidge.Lots.ShippingDispatcher.dispatchContainer(
                    containerId, terminalLocationId, result.get("NewId"))
            except Exception as e:
                printRes = {"Status": 0, "Message": "print raised: %s" % e}
            result["LabelPrint"] = printRes
            if not (printRes and printRes.get("Status")):
                result["Status"] = 0
                result["Message"] = printRes.get("Message") or "Print failed."
    return result
```

Create `sql/migrations/repeatable/R__Lots_ShippingLabel_GetContainerId.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_ShippingLabel_GetContainerId.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     1.0
-- Description: Resolves the ContainerId behind a ShippingLabel so the reprint path
--              can re-render the container label (design 2026-07-28 sec 3.6).
--              Read proc; empty rowset = label not found.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ShippingLabel_GetContainerId
    @ShippingLabelId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ShippingLabelId IS NULL
        RETURN;

    SELECT sl.ContainerId AS ContainerId
    FROM Lots.ShippingLabel sl
    WHERE sl.Id = @ShippingLabelId;
END;
GO
```

Create `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetContainerId/query.sql`:

```sql
EXEC Lots.ShippingLabel_GetContainerId
    @ShippingLabelId = :shippingLabelId
```

And `ignition/projects/Core/ignition/named-query/lots/ShippingLabel_GetContainerId/resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-07-28T12:00:00Z"
    },
    "parameters": [
      { "type": "Parameter", "identifier": "shippingLabelId", "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 5: Verify the rendered ZPL before touching hardware**

```python
import BlueRidge.Common.Db as Db
import BlueRidge.Lots.ShippingDispatcher as SD
cid = <an existing completed Container id>
print SD._renderContainerLabel(Db.execOne("lots/Container_GetLabelData", {"containerId": cid}))
```

Expected: ZPL with real values substituted and no residual `{Token}` text. Paste it into `labelary.com/viewer.html` (4x6, 203 dpi) and confirm the layout renders — the rotated `^A0R` fields and ~1300-dot coordinates were authored for specific stock.

- [ ] **Step 6: Smoke the full container path**

Run `.\scan.ps1`, restart the Gateway (stale-connection rule after any migration), start `usb_tcp_bridge.py`, point the assembly terminal's printer `Endpoint` at `127.0.0.1:9100`, then complete a container from Assembly.
Expected: the bridge receives bytes; `Lots.ShippingLabel.PrintedAt` is set for the new row; `Audit.InterfaceLog` shows `Shipping label dispatch via tcp to 127.0.0.1:9100`. Then stop the bridge and complete another container: the container still completes, a warning toast appears, and `PrintAttempts` = 1 with `LastPrintError` populated.

- [ ] **Step 7: Run the full suite and commit**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

Expected: no `FAIL:` lines, no `ERROR running` lines.

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots sql/migrations/repeatable/R__Lots_LabelTemplate_GetActiveByTypeCode.sql sql/migrations/repeatable/R__Lots_ShippingLabel_GetContainerId.sql ignition/projects/Core/ignition/named-query/lots
git commit -m "feat(labels): dispatch container shipping labels on completion and reprint"
```

---

## Post-implementation

- [ ] Update `docs/ARC2_FDS_CONFORMANCE.md`: FDS-07-006 (label content) Partial -> Built; FDS-07-007 note that `ZplContent` is still absent from `ShippingLabel`; FDS-05-020 drop the em-dash mojibake note (P4-7 fixed).
- [ ] Add a `PROJECT_STATUS.md` section for the session.
- [ ] Leave FDS-07-006a/b as documented divergences — async dispatch and the stranded-print sweep remain out of scope (spec §7).
