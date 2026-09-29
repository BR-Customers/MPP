# LabelTransport ACK and Dispatch Logging -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `LabelTransport` read the bridge's ACK so `ok` means "the named Windows queue took this as job N", and make a failed print always leave a row saying which stage it died at -- including the resolve stage, which today writes nothing at all.

**Architecture:** The socket work stays in `_sendTcp`, but everything decidable is pulled into **pure functions** (`_parseAck`, `_dispatchLogParams`, `_resolveLogParams`) because `LabelTransport` is Jython importing `java.net` and CPython cannot load it. The repo's existing Jython tests `ast`-extract self-contained helpers and exec them; these functions are written to be extractable the same way. The untestable remainder is one socket read.

**Tech Stack:** Jython 2.7 (Ignition Gateway scope), pytest 9.1.1 for the extracted pure helpers, SQL Server for verification.

**Spec:** `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md` sections 5 and 6.
**Protocol:** `zebraPrinter/PROTOCOL.md` v1.0.0 -- frozen. This plan consumes it and must not change it.

## Global Constraints

- **Jython 2.7, not Python 3.** No f-strings, no `str.format` niceties beyond `%`, and `except Exception` does **not** catch `java.lang.Throwable` -- socket failures arrive as Throwable and must be caught first (`_sendTcp` already does this; keep it).
- **Logging must never break dispatch.** `logDispatch` uses a bare `except:` deliberately. Any new logging call does the same.
- **No schema change and no migration.** `Audit_LogInterfaceCall` already accepts every field used here. Resolve failures reuse `logEventTypeCode = 'LabelDispatched'` with `errorCondition = 'EndpointUnresolved'`.
- **`audit/Audit_LogInterfaceCall` is `UpdateQuery`-typed** -- it must go through `Common.Db.execNonQuery`, never `execList`.
- **A missing ACK is not an error.** A networked Zebra never replies; that is the expected result for `ConnectionKind = Networked` and is recorded as distinct from a failure.
- **`PROTOCOL.md` is frozen.** If something here seems to need a wire-format change, stop and raise it.
- New pure helpers live in `BlueRidge/Lots/LabelTransport/code.py` and must be **self-contained** -- no `BlueRidge.*` calls, no Java imports -- or the test extractor cannot exec them.

---

### Task 1: Parse the ACK line

Pure, and the whole reason `ok` can start meaning something stronger.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py`
- Test: `ignition/tests/test_label_transport_ack.py`

**Interfaces:**
- Consumes: `zebraPrinter/PROTOCOL.md` response grammar
- Produces: `_parseAck(line) -> dict` with keys `acked` (bool), `ok` (bool), `queue` (str|None), `job` (int|None), `bytes` (int|None), `error` (str|None)

- [ ] **Step 1: Write the failing tests**

Create `ignition/tests/test_label_transport_ack.py`:

```python
"""Guard for LabelTransport's read of the bridge ACK.

zebraPrinter/PROTOCOL.md is frozen and three workstreams build against it.
_parseAck is the Gateway's half of that contract, so these tests pin the exact
line formats rather than the behaviour they happen to produce.

LabelTransport is Jython and imports java.net, so it cannot be imported under
CPython. These tests ast-extract the self-contained helpers and exec those --
the same approach as test_location_sort_order.py.

Run: python -m pytest ignition/tests/test_label_transport_ack.py
"""

import ast
import io
import os

import pytest

MODULE = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python",
    "BlueRidge", "Lots", "LabelTransport", "code.py",
)

WANTED = ("_parseAck", "_unquote")


def load_helpers(path=MODULE):
    """Exec only the self-contained helpers, so the test needs no Ignition."""
    src = io.open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    keep = [n for n in tree.body
            if isinstance(n, ast.FunctionDef) and n.name in WANTED]
    ns = {}
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    return ns


@pytest.fixture(scope="module")
def helpers():
    ns = load_helpers()
    missing = [n for n in WANTED if n not in ns]
    if missing:
        pytest.fail("helper(s) missing from the module: %s" % ", ".join(missing))
    return ns


def test_a_successful_print_ack_is_parsed(helpers):
    got = helpers["_parseAck"]("OK queue='Zebra GX420d (RAW)' job=41 bytes=1264")
    assert got["acked"] is True
    assert got["ok"] is True
    assert got["queue"] == "Zebra GX420d (RAW)"
    assert got["job"] == 41
    assert got["bytes"] == 1264
    assert got["error"] is None


def test_an_err_ack_carries_the_reason(helpers):
    got = helpers["_parseAck"]("ERR queue not found: 'ZDesigner GX420d'")
    assert got["acked"] is True
    assert got["ok"] is False
    assert "queue not found" in got["error"]


def test_no_ack_is_not_a_failure(helpers):
    """A networked Zebra never replies. That is the expected result for
       ConnectionKind = Networked, not an error."""
    for line in (None, "", "   "):
        got = helpers["_parseAck"](line)
        assert got["acked"] is False
        assert got["ok"] is False
        assert got["error"] is None


def test_a_doubled_quote_in_a_queue_name_is_unescaped(helpers):
    got = helpers["_parseAck"]("OK queue='Bob''s Zebra' job=1 bytes=2")
    assert got["queue"] == "Bob's Zebra"


def test_an_unparseable_line_is_reported_not_swallowed(helpers):
    got = helpers["_parseAck"]("banana")
    assert got["acked"] is True
    assert got["ok"] is False
    assert "banana" in got["error"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: FAIL at the fixture -- `helper(s) missing from the module: _parseAck, _unquote`

- [ ] **Step 3: Implement the helpers**

In `BlueRidge/Lots/LabelTransport/code.py`, directly above `def _sendTcp(`, add:

```python
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: PASS, 5 passed

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py ignition/tests/test_label_transport_ack.py
git commit -m "feat(ignition): LabelTransport can read what the bridge said back"
```

---

### Task 2: Read the ACK in `_sendTcp`

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py`

**Interfaces:**
- Consumes: `_parseAck` from Task 1
- Produces: `_sendTcp` returns `{ok, error, ack}` where `ack` is a `_parseAck` dict. `send()` passes `ack` through unchanged.

No unit test: this is `java.net`, unreachable from CPython. It is covered by the integration run in Task 5.

- [ ] **Step 1: Half-close and read the reply**

Replace the body of `_sendTcp` between `out.flush()` and the first `except`:

```python
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
```

- [ ] **Step 2: Add the two imports `_sendTcp` now needs**

In `_sendTcp`'s import block, add `BufferedReader` and `InputStreamReader`:

```python
    from java.net import Socket, InetSocketAddress
    from java.io import BufferedReader, InputStreamReader
    from java.lang import String as JString
    from java.lang import Throwable
```

- [ ] **Step 3: Carry `ack` through the failure paths**

Both `except` blocks in `_sendTcp` return a dict with no `ack` key, which would make callers branch on its presence. Give them one. Replace:

```python
    except Throwable as t:
        return {"ok": False, "error": t.getMessage() or str(t)}
    except Exception as e:
        return {"ok": False, "error": str(e)}
```

with:

```python
    except Throwable as t:
        return {"ok": False, "error": t.getMessage() or str(t), "ack": _parseAck(None)}
    except Exception as e:
        return {"ok": False, "error": str(e), "ack": _parseAck(None)}
```

- [ ] **Step 4: Give `_sendQueue` the same shape**

`send()` returns whichever dict the transport produced. `_dispatchLogParams` reads it with `.get("ack")`, so a missing key would not throw -- but the two transports returning different shapes is the kind of asymmetry that later code trips over, and `acked: False` is the honest answer for a queue print (there is no far end to answer). In `_sendQueue`, change the success return and all three failure returns to include `"ack": _parseAck(None)`:

```python
        return {"ok": True, "error": None, "ack": _parseAck(None)}
```

and for each of its three `{"ok": False, ...}` returns, add `, "ack": _parseAck(None)` before the closing brace.

- [ ] **Step 5: Verify the module still parses**

Run: `python -c "import ast, io; ast.parse(io.open('ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py', encoding='utf-8').read()); print('parses OK')"`
Expected: `parses OK`

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: PASS, 5 passed -- the extracted helpers are unaffected

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py
git commit -m "feat(ignition): ok now means the queue took it, not that bytes left the Gateway"
```

---

### Task 3: Put the ACK and the stage in the log row

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py`
- Test: `ignition/tests/test_label_transport_ack.py`

**Interfaces:**
- Consumes: `_parseAck` from Task 1
- Produces: `_dispatchLogParams(endpoint, zpl, outcome, labelKind) -> dict` -- the exact params passed to `audit/Audit_LogInterfaceCall`

- [ ] **Step 1: Write the failing tests**

Change `WANTED` at the top of `ignition/tests/test_label_transport_ack.py` to:

```python
WANTED = ("_parseAck", "_unquote", "_dispatchLogParams")
```

and append:

```python
def _params(helpers, outcome, endpoint="10.20.11.157:9100"):
    return helpers["_dispatchLogParams"](endpoint, "^XA^XZ", outcome, "Shipping label")


def test_a_spooled_print_records_the_queue_and_job(helpers):
    ack = {"acked": True, "ok": True, "queue": "Zebra GX420d (RAW)",
           "job": 41, "bytes": 1264, "error": None}
    p = _params(helpers, {"ok": True, "error": None, "transport": "tcp", "ack": ack})
    assert p["errorCondition"] is None
    assert "Spooled" in p["responsePayload"]
    assert "job=41" in p["responsePayload"]
    assert "Zebra GX420d (RAW)" in p["responsePayload"]


def test_a_networked_printer_with_no_ack_is_recorded_as_sent_not_failed(helpers):
    ack = {"acked": False, "ok": False, "queue": None,
           "job": None, "bytes": None, "error": None}
    p = _params(helpers, {"ok": True, "error": None, "transport": "tcp", "ack": ack})
    assert p["errorCondition"] is None
    assert "no ack" in p["responsePayload"]


def test_a_transport_failure_names_the_stage(helpers):
    p = _params(helpers, {"ok": False, "error": "Connect timed out",
                          "transport": "tcp", "ack": {"acked": False, "ok": False,
                                                      "queue": None, "job": None,
                                                      "bytes": None, "error": None}})
    assert p["errorCondition"] == "DispatchFailed"
    assert p["errorDescription"] == "Connect timed out"


def test_a_bridge_refusal_is_distinguished_from_a_network_failure(helpers):
    """The bridge answered -- so the network is fine and the queue is wrong.
       That must not read as a connectivity problem."""
    ack = {"acked": True, "ok": False, "queue": None, "job": None,
           "bytes": None, "error": "queue not found: 'ZDesigner GX420d'"}
    p = _params(helpers, {"ok": False, "error": ack["error"],
                          "transport": "tcp", "ack": ack})
    assert p["errorCondition"] == "QueueRejected"
    assert "ZDesigner GX420d" in p["errorDescription"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: FAIL at the fixture -- `helper(s) missing from the module: _dispatchLogParams`

- [ ] **Step 3: Implement the params builder**

Directly above `def logDispatch(`, add:

```python
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
```

`_SYSTEM_NAME` is a module-level constant, so the extracted namespace will not have it. Add it to the test's extractor by changing `load_helpers` to seed it -- in `ignition/tests/test_label_transport_ack.py`, replace `ns = {}` with:

```python
    ns = {"_SYSTEM_NAME": "Zebra"}
```

- [ ] **Step 4: Make `logDispatch` use it**

Replace the whole `params = { ... }` literal in `logDispatch` with:

```python
    params = _dispatchLogParams(endpoint, zpl, outcome, labelKind)
```

and delete the now-unused `ok = ...` and `transport = ...` lines above it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: PASS, 9 passed

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py ignition/tests/test_label_transport_ack.py
git commit -m "feat(ignition): a dispatch row says which stage it reached"
```

---

### Task 4: Log the resolve stage

The gap that let `ShippingLabel` 20016 and 20017 sit at `NULL`/`NULL` with nothing anywhere explaining why.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotLabel/code.py`
- Test: `ignition/tests/test_label_transport_ack.py`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `_resolveLogParams(endpoint, via, labelKind) -> dict`, and `logResolve(endpoint, via, labelKind)` which executes it

- [ ] **Step 1: Write the failing tests**

Change `WANTED` to:

```python
WANTED = ("_parseAck", "_unquote", "_dispatchLogParams", "_resolveLogParams")
```

and append:

```python
def test_a_resolved_endpoint_records_which_tier_chose_it(helpers):
    p = helpers["_resolveLogParams"]("10.20.11.157:9100", "terminal-printer",
                                     "Shipping label")
    assert p["errorCondition"] is None
    assert "terminal-printer" in p["responsePayload"]
    assert "10.20.11.157:9100" in p["responsePayload"]


def test_an_unresolved_endpoint_leaves_a_row_rather_than_silence(helpers):
    """ShippingLabel 20016/20017 on 2026-09-29: no PrintedAt, no PrintFailedAt,
       and no InterfaceLog row at all. This is that gap."""
    p = helpers["_resolveLogParams"]("", "none", "Shipping label")
    assert p["errorCondition"] == "EndpointUnresolved"
    assert p["responsePayload"] is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: FAIL at the fixture -- `helper(s) missing from the module: _resolveLogParams`

- [ ] **Step 3: Implement both functions**

In `LabelTransport/code.py`, directly above `def _dispatchLogParams(`, add:

```python
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
```

and directly above `def logDispatch(`, add:

```python
def logResolve(endpoint, via, labelKind):
    """Log the resolve stage. Bare except for the same reason logDispatch has
       one: logging must never break a print."""
    try:
        BlueRidge.Common.Db.execNonQuery("audit/Audit_LogInterfaceCall",
                                         _resolveLogParams(endpoint, via, labelKind))
    except:
        pass
```

- [ ] **Step 4: Call it from `ShippingDispatcher._resolveEndpoint`**

In `BlueRidge/Lots/ShippingDispatcher/code.py`, replace the body of `_resolveEndpoint` after the docstring with:

```python
    pid = _u(printerLocationId)
    if pid is not None:
        printer = BlueRidge.Location.Printer.getById(pid) or {}
        endpoint = (printer.get("endpoint") or printer.get("Endpoint") or "").strip()
        BlueRidge.Lots.LabelTransport.logResolve(endpoint, "printer-card", "Shipping label")
        return endpoint
    printer = _sessionPrinter()
    endpoint = (printer.get("endpoint") or "").strip()
    via = "session-printer"
    if not endpoint and terminalLocationId is not None:
        printer = BlueRidge.Location.Terminal.getPrinter(terminalLocationId) or {}
        endpoint = (printer.get("endpoint") or "").strip()
        via = "terminal-printer"
    if not endpoint:
        via = "none"
    BlueRidge.Lots.LabelTransport.logResolve(endpoint, via, "Shipping label")
    return endpoint
```

- [ ] **Step 5: Call it from `LotLabel._dispatchAfterRender`**

In `BlueRidge/Lots/LotLabel/code.py`, immediately before the fail-fast block

```python
    # Fail-fast: genuinely no printer configured for this terminal. LOT/label already exist.
    if not endpoint:
```

insert:

```python
    BlueRidge.Lots.LabelTransport.logResolve(
        endpoint, "session-printer" if printer.get("endpoint") else "terminal-printer", "LTT")
```

- [ ] **Step 6: Run the tests and verify all three modules still parse**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: PASS, 11 passed

Run:
```bash
python -c "import ast, io; [ast.parse(io.open(p, encoding='utf-8').read()) for p in ['ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py','ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py','ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotLabel/code.py']]; print('all parse OK')"
```
Expected: `all parse OK`

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/ShippingDispatcher/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LotLabel/code.py ignition/tests/test_label_transport_ack.py
git commit -m "feat(ignition): a print that never found a printer now says so"
```

---

### Task 5: Verify against the real bridge

The unit tests cover the decidable parts. Only a real socket proves `_sendTcp`'s half-close and read, and only a real dispatch proves the rows land. The Python bridge from the previous plan is the counterpart -- this is why it was built first.

**Files:**
- None modified. This is verification.

**Interfaces:**
- Consumes: everything from Tasks 1-4, plus `zebraPrinter/usb_tcp_bridge.py` speaking PROTOCOL.md v1.0.0

- [ ] **Step 1: Scan the changed scripts into the Gateway**

Run: `.\scan.ps1`
Expected: a success response from the Gateway API. Jython changes need no restart.

- [ ] **Step 2: Start the bridge on the local real queue**

```bash
python zebraPrinter/usb_tcp_bridge.py "ZDesigner GX420d"
```

Expected: `Bridging  0.0.0.0:9100  ->  printer 'ZDesigner GX420d'   (Ctrl-C to stop)`

- [ ] **Step 3: Point a printer row at it and note the baseline**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SET NOCOUNT ON; SELECT MaxId = ISNULL(MAX(Id),0) FROM Audit.InterfaceLog;" -b -I -C -W -s "|"
```

Record the number. Every row checked below must have a higher `Id`.

Set printer 148's endpoint to the local bridge through the Config Tool (Plant Hierarchy), or confirm an existing terminal already points at `127.0.0.1:9100`.

- [ ] **Step 4: Dispatch a real shipping label**

From a Designer Script Console on the local Gateway:

```python
print BlueRidge.Lots.ShippingDispatcher.dispatch(shippingLabelId=20018, printerLocationId=148)
```

Expected: `{'Status': 1, ...}` immediately (dispatch is async), the bridge logs a `connection from` line and an `OK queue='ZDesigner GX420d' job=<n> bytes=<m>`, and a spooler job appears.

- [ ] **Step 5: Confirm the row says Spooled, with the job id**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SET NOCOUNT ON; SELECT TOP 5 Id, LoggedAt, ErrorCondition, Descr=LEFT(Description,60), Resp=LEFT(ResponsePayload,70) FROM Audit.InterfaceLog ORDER BY Id DESC;" -b -I -C -W -s "|"
```

Expected: a `Resolved 127.0.0.1:9100 via printer-card` row and a `Spooled queue='ZDesigner GX420d' job=<n> bytes=<m>` row, both with `ErrorCondition` NULL.

- [ ] **Step 6: Prove each failure names itself**

Stop the bridge (`Ctrl-C`) and dispatch again.

Expected: `ErrorCondition = DispatchFailed` with `Connection refused` -- **not** `Connect timed out`, because the host is up and nothing is listening. That distinction is the one that identified the real fault on 2026-09-29.

Restart the bridge bound to a queue that does not exist:

```bash
python zebraPrinter/usb_tcp_bridge.py "No Such Queue"
```

Dispatch again. Expected: `ErrorCondition = QueueRejected`, **not** `DispatchFailed` -- the bridge answered, so the network was fine and the queue was wrong.

- [ ] **Step 7: Prove the resolve gap is closed**

Dispatch with a printer that has no endpoint:

```python
print BlueRidge.Lots.ShippingDispatcher.dispatch(shippingLabelId=20018, printerLocationId=144)
```

(Printer 144 is `172.17.20.229:9100`; if it resolves, use any printer row whose `Endpoint` is unset -- there are 51.)

Expected: a row with `ErrorCondition = EndpointUnresolved`. Before this plan, this case wrote **nothing at all**.

- [ ] **Step 8: Clean up**

Stop the bridge. Purge any spooler jobs:

```bash
powershell -Command "Get-PrintJob -PrinterName 'ZDesigner GX420d' -EA SilentlyContinue | ForEach-Object { Remove-PrintJob -PrinterName 'ZDesigner GX420d' -ID $_.Id }"
```

Restore printer 148's endpoint to `10.20.11.157:9100` if it was changed.

- [ ] **Step 9: Record the verified behaviour**

Append the four observed `ErrorCondition` values and their triggers to the spec's section 6.3 table, replacing the predicted list with the observed one.

```bash
git add docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md
git commit -m "docs(spec): record the dispatch failure taxonomy as observed, not predicted"
```
