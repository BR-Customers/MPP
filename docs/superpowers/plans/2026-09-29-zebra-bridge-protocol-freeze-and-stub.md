# Zebra Bridge Protocol Freeze and Python Stub -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze the bridge wire protocol as a normative document and make `zebraPrinter/usb_tcp_bridge.py` its reference implementation, so the C# service, the `LabelTransport` logging work, and the Config Tool work can all proceed in parallel against a stable contract.

**Architecture:** The protocol becomes a document (`zebraPrinter/PROTOCOL.md`) that the three workstreams build against. The bridge's connection handling is refactored so request-to-response is a pure function, `handle_request(data, printer_name, spool, status)`, with the spooler and the queue-status reader injected. That seam is what makes the protocol testable with no printer attached. The socket loop reads to EOF (the sender half-closes), calls the handler, writes the one-line reply, and closes.

**Tech Stack:** Python 3 standard library only (`socket`, `ctypes`/`winspool.drv`), pytest 9.1.1.

**Spec:** `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md` sections 4.1 and 4.2.

## Global Constraints

- **Standard library only.** The bridge must run on a bare Windows box; no third-party imports, ever.
- **ASCII on the wire**, both directions. Non-ASCII in a queue name is replaced, never raised.
- **Responses are exactly one line**, terminated `\n`. Embedded newlines in any error text are collapsed to spaces before sending.
- **An empty request gets no response at all.** `BlueRidge.Location.Printer.validateEndpoint` connects and closes without sending; that bare-connect reachability probe must keep working unchanged.
- **The protocol document is normative.** Once Task 1 is committed, a change to the wire format is a change to `PROTOCOL.md` first and needs Jacques's agreement -- three workstreams depend on it.
- `BRIDGE_VERSION` is semver, starting `1.0.0`.
- Tests live at `zebraPrinter/tests/test_bridge_protocol.py` and run with `python -m pytest`, matching the `ignition/tests/` convention (docstring at the top saying what the file guards).

---

### Task 1: Freeze the protocol document

No code. This is the contract the other three workstreams consume, so it lands first and alone.

**Files:**
- Create: `zebraPrinter/PROTOCOL.md`

**Interfaces:**
- Consumes: nothing
- Produces: the normative wire format. Every later task and workstream cites this file.

- [ ] **Step 1: Write `zebraPrinter/PROTOCOL.md`**

````markdown
# MES Zebra Bridge -- Wire Protocol v1.0.0

Normative. The Gateway (`BlueRidge.Lots.LabelTransport`), the `MesZebraBridge`
Windows service, and `zebraPrinter/usb_tcp_bridge.py` all conform to this file.
Change it here first, with agreement, before changing any implementation.

Transport: TCP, default port 9100. One request per connection.

## Framing

The client writes its request, then **half-closes** its side of the socket
(`shutdown(SHUT_WR)`). The half-close is what ends the server's read
immediately; without it the server waits out a 2 second idle timeout and the
round trip becomes seconds instead of milliseconds.

The server then writes **one line**, terminated with a single `\n`, and closes.

All bytes in both directions are ASCII. A request larger than 1 MiB is
truncated at that limit.

## Requests

| First byte | Meaning |
|---|---|
| (no bytes at all) | Reachability probe. **The server replies nothing** and closes. |
| `?` | A command (see below). |
| anything else | ZPL to print. |

## Responses

A response is `OK` or `ERR`, a space, then `key=value` pairs separated by
single spaces. Values that may contain spaces are single-quoted; a `'` inside
a quoted value is doubled (`Bob's` becomes `'Bob''s'`).

### Print

```
-> ^XA...^XZ            then shutdown(SHUT_WR)
<- OK queue='Zebra GX420d (RAW)' job=41 bytes=1264
<- ERR queue not found: 'ZDesigner GX420d'; visible: Zebra GX420d (RAW)
```

`job` is the Windows spooler job id. `bytes` is the byte count handed to the
spooler.

`OK` means the named Windows queue accepted these bytes as that job. It does
**not** mean a label physically printed -- that is not knowable from here and
is never claimed.

### `?STATUS`

```
-> ?STATUS              then shutdown(SHUT_WR)
<- OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0
<- ERR unknown command '?WAT'
```

`ready` is `true` or `false`. `jobs` is the queue's current job count. No label
is consumed, so this is safe to call at any time and is the basis of the
Config Tool's "Test this printer" action.

Commands are case-insensitive. An unrecognised command is an `ERR`, never
silence.

## Non-bridge printers

A real networked Zebra on raw 9100 never replies. A client that reads nothing
before its timeout records `sent, no ack (raw 9100)`. That is **not** an
error -- it is the expected result for a `ConnectionKind = Networked` printer
and must be recorded as distinct from a failure.
````

- [ ] **Step 2: Verify it renders and says what you mean**

Run: `python -c "import io; print(len(io.open('zebraPrinter/PROTOCOL.md', encoding='utf-8').read().splitlines()))"`
Expected: a line count around 70, and no traceback.

- [ ] **Step 3: Commit**

```bash
git add zebraPrinter/PROTOCOL.md
git commit -m "docs(bridge): freeze the Zebra bridge wire protocol at v1.0.0"
```

---

### Task 2: Extract the request handler seam

The protocol logic must be testable with no printer attached. Extract it behind injected `spool` and `status` callables.

**Files:**
- Modify: `zebraPrinter/usb_tcp_bridge.py`
- Test: `zebraPrinter/tests/test_bridge_protocol.py`

**Interfaces:**
- Consumes: `zebraPrinter/PROTOCOL.md` from Task 1
- Produces:
  - `BRIDGE_VERSION: str` -- `"1.0.0"`
  - `handle_request(data: bytes, printer_name: str, spool, status) -> str | None`
  - `spool(data: bytes) -> tuple[int, int]` -- returns `(job_id, bytes_written)`, raises on failure
  - `status() -> dict` -- `{"queue": str, "ready": bool, "jobs": int}`

- [ ] **Step 1: Write the failing test**

Create `zebraPrinter/tests/test_bridge_protocol.py`:

```python
"""Wire-protocol guard for the MES Zebra bridge.

zebraPrinter/PROTOCOL.md is the contract three separate workstreams build
against -- the C# MesZebraBridge service, LabelTransport's ACK read, and the
Config Tool's test button. These tests pin the exact bytes on the wire so a
well-meaning edit to the bridge cannot silently move the contract.

The spooler and the queue-status reader are injected, so nothing here needs a
printer, a driver, or Windows print services.

Run: python -m pytest zebraPrinter/tests/test_bridge_protocol.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import usb_tcp_bridge as bridge


def _spool_ok(data):
    return (41, len(data))


def _status_ok():
    return {"queue": "Zebra GX420d (RAW)", "ready": True, "jobs": 0}


def test_empty_request_gets_no_reply():
    """validateEndpoint connects and closes without sending. Replying to that
       would be a protocol change; staying silent is the contract."""
    assert bridge.handle_request(b"", "Q", _spool_ok, _status_ok) is None
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: FAIL with `AttributeError: module 'usb_tcp_bridge' has no attribute 'handle_request'`

- [ ] **Step 3: Add the version constant and the handler**

In `zebraPrinter/usb_tcp_bridge.py`, after the `DEFAULT_PRINTER` line, add:

```python
BRIDGE_VERSION = "1.0.0"
MAX_REQUEST_BYTES = 1048576   # 1 MiB -- see PROTOCOL.md "Framing"
READ_TIMEOUT = 2.0
```

Then, above `def main():`, add:

```python
def _oneline(text):
    """Collapse whitespace so an error can never break the one-line framing."""
    return " ".join(("%s" % text).split())


def _quote(value):
    """Single-quote a wire value, doubling any embedded quote (PROTOCOL.md)."""
    return "'" + ("%s" % value).replace("'", "''") + "'"


def handle_request(data, printer_name, spool, status):
    """Map one request's bytes to one response line WITHOUT its trailing
       newline, or None when the protocol says stay silent.

       spool(data)  -> (job_id, bytes_written), raises on failure
       status()     -> {"queue": str, "ready": bool, "jobs": int}

       Pure apart from the two injected callables, so the whole protocol is
       testable with no printer attached."""
    if not data:
        return None
    return "ERR not implemented"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: PASS, 1 passed

- [ ] **Step 5: Commit**

```bash
git add zebraPrinter/usb_tcp_bridge.py zebraPrinter/tests/test_bridge_protocol.py
git commit -m "test(bridge): a silent reply to an empty request is the contract, not an accident"
```

---

### Task 3: `?STATUS`

**Files:**
- Modify: `zebraPrinter/usb_tcp_bridge.py`
- Test: `zebraPrinter/tests/test_bridge_protocol.py`

**Interfaces:**
- Consumes: `handle_request`, `_quote`, `BRIDGE_VERSION` from Task 2
- Produces: the `?STATUS` response line, consumed by the Config Tool test button

- [ ] **Step 1: Write the failing tests**

Append to `zebraPrinter/tests/test_bridge_protocol.py`:

```python
def test_status_reports_version_queue_and_readiness():
    reply = bridge.handle_request(b"?STATUS", "Zebra GX420d (RAW)",
                                  _spool_ok, _status_ok)
    assert reply == ("OK bridge=%s queue='Zebra GX420d (RAW)' ready=true jobs=0"
                     % bridge.BRIDGE_VERSION)


def test_status_is_case_insensitive():
    assert bridge.handle_request(b"?status", "Q", _spool_ok, _status_ok) == \
        bridge.handle_request(b"?STATUS", "Q", _spool_ok, _status_ok)


def test_status_reports_a_not_ready_queue():
    def busy():
        return {"queue": "Q", "ready": False, "jobs": 3}
    reply = bridge.handle_request(b"?STATUS", "Q", _spool_ok, busy)
    assert "ready=false" in reply
    assert "jobs=3" in reply


def test_a_quote_in_a_queue_name_is_doubled():
    def odd():
        return {"queue": "Bob's Zebra", "ready": True, "jobs": 0}
    reply = bridge.handle_request(b"?STATUS", "Q", _spool_ok, odd)
    assert "queue='Bob''s Zebra'" in reply


def test_unknown_command_is_refused_not_ignored():
    reply = bridge.handle_request(b"?WAT", "Q", _spool_ok, _status_ok)
    assert reply.startswith("ERR unknown command")
    assert "?WAT" in reply
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: 1 passed, 5 failed -- each failing on `ERR not implemented`

- [ ] **Step 3: Implement command dispatch**

Replace the body of `handle_request` after the empty-data guard:

```python
    if not data:
        return None
    if data[:1] == b"?":
        cmd = data.decode("ascii", "replace").strip().upper()
        if cmd == "?STATUS":
            s = status()
            return "OK bridge=%s queue=%s ready=%s jobs=%d" % (
                BRIDGE_VERSION, _quote(s["queue"]),
                "true" if s["ready"] else "false", int(s["jobs"]))
        return "ERR unknown command %s" % _quote(cmd)
    return "ERR not implemented"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: PASS, 6 passed

- [ ] **Step 5: Commit**

```bash
git add zebraPrinter/usb_tcp_bridge.py zebraPrinter/tests/test_bridge_protocol.py
git commit -m "feat(bridge): ?STATUS answers which queue it is bound to, printing nothing"
```

---

### Task 4: The print ACK

**Files:**
- Modify: `zebraPrinter/usb_tcp_bridge.py`
- Test: `zebraPrinter/tests/test_bridge_protocol.py`

**Interfaces:**
- Consumes: `handle_request` from Tasks 2-3
- Produces: the print response line, consumed by `LabelTransport._sendTcp`. `send_raw` changes signature to return `(job_id, bytes_written)`.

- [ ] **Step 1: Write the failing tests**

Append to `zebraPrinter/tests/test_bridge_protocol.py`:

```python
def test_zpl_is_spooled_and_acked_with_the_job_id():
    seen = {}

    def spool(data):
        seen["data"] = data
        return (41, len(data))

    reply = bridge.handle_request(b"^XA^XZ", "Zebra GX420d (RAW)",
                                  spool, _status_ok)
    assert seen["data"] == b"^XA^XZ"
    assert reply == "OK queue='Zebra GX420d (RAW)' job=41 bytes=6"


def test_a_spooler_failure_is_reported_on_exactly_one_line():
    """The queue-not-found error names every visible queue, which is
       multi-line. One-line framing is not negotiable, so it is collapsed."""
    def spool(data):
        raise RuntimeError("queue not found: 'ZDesigner GX420d'\nvisible:\n  A\n  B")

    reply = bridge.handle_request(b"^XA^XZ", "Q", spool, _status_ok)
    assert reply.startswith("ERR ")
    assert "\n" not in reply
    assert "ZDesigner GX420d" in reply
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: 6 passed, 2 failed on `ERR not implemented`

- [ ] **Step 3: Implement the print branch**

Replace the trailing `return "ERR not implemented"` in `handle_request` with:

```python
    try:
        job, written = spool(data)
    except Exception as e:
        return "ERR %s" % _oneline(e)
    return "OK queue=%s job=%d bytes=%d" % (_quote(printer_name), int(job), int(written))
```

- [ ] **Step 4: Make `send_raw` return the job id**

`StartDocPrinterW` already returns the spooler job id and `0` on failure; the current code discards it. In `send_raw`, replace:

```python
        di = DOCINFO("MES ZPL", None, "RAW")
        if not winspool.StartDocPrinterW(h, 1, ctypes.byref(di)):
            raise ctypes.WinError(ctypes.get_last_error())
```

with:

```python
        di = DOCINFO("MES ZPL", None, "RAW")
        job = winspool.StartDocPrinterW(h, 1, ctypes.byref(di))
        if not job:
            raise ctypes.WinError(ctypes.get_last_error())
```

and replace `return written.value` with:

```python
            return (int(job), int(written.value))
```

Update the docstring's first line to: `"""Send raw bytes to a Windows print queue. Returns (job_id, bytes_written)."""`

- [ ] **Step 5: Fix the existing call site so this commit leaves a working file**

`main()` still unpacks `send_raw` as an int and would fail at runtime. Task 5 deletes this block entirely, but it must not be broken in between. In `main()`, replace:

```python
                n = send_raw(printer_name, data)
                print("  received %d bytes -> spooled %d to '%s'" % (len(data), n, printer_name))
```

with:

```python
                job, n = send_raw(printer_name, data)
                print("  received %d bytes -> spooled %d to '%s' as job %d"
                      % (len(data), n, printer_name, job))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: PASS, 8 passed

- [ ] **Step 7: Commit**

```bash
git add zebraPrinter/usb_tcp_bridge.py zebraPrinter/tests/test_bridge_protocol.py
git commit -m "feat(bridge): a print is acked with the queue and the spooler job id"
```

---

### Task 5: Serve it over a real socket

The handler is correct in isolation. Now the socket loop must read to EOF, reply, and close -- today it closes in a `finally` before anything can be written back.

**Files:**
- Modify: `zebraPrinter/usb_tcp_bridge.py`
- Test: `zebraPrinter/tests/test_bridge_protocol.py`

**Interfaces:**
- Consumes: `handle_request` from Tasks 2-4
- Produces: `serve_connection(conn, printer_name, spool, status) -> None` and `queue_status(printer_name) -> dict`

- [ ] **Step 1: Write the failing test**

Append to `zebraPrinter/tests/test_bridge_protocol.py` (and add `import socket` and `import threading` to the imports at the top):

```python
def _serve_one(printer_name, spool, status):
    """Accept exactly one connection on an ephemeral port. Returns the port."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]

    def run():
        try:
            conn, _ = srv.accept()
            bridge.serve_connection(conn, printer_name, spool, status)
        finally:
            srv.close()

    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    return port


def test_half_close_then_read_the_ack_over_a_real_socket():
    port = _serve_one("Q", lambda d: (7, len(d)), _status_ok)
    c = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        c.sendall(b"^XA^XZ")
        c.shutdown(socket.SHUT_WR)
        line = c.makefile("rb").readline()
    finally:
        c.close()
    assert line == b"OK queue='Q' job=7 bytes=6\n"


def test_a_bare_connect_gets_no_bytes_and_no_hang():
    """The reachability probe: connect, send nothing, close. Must not print
       and must not leave the client waiting."""
    port = _serve_one("Q", lambda d: (7, len(d)), _status_ok)
    c = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        c.shutdown(socket.SHUT_WR)
        assert c.makefile("rb").readline() == b""
    finally:
        c.close()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: 8 passed, 2 failed with `AttributeError: module 'usb_tcp_bridge' has no attribute 'serve_connection'`

- [ ] **Step 3: Add the queue-status reader**

`GetPrinterW` level 2 carries both the queue's status word and its job count. Add the struct beside `DOCINFO`:

```python
class PRINTER_INFO_2(ctypes.Structure):
    _fields_ = [("pServerName", wintypes.LPWSTR), ("pPrinterName", wintypes.LPWSTR),
                ("pShareName", wintypes.LPWSTR), ("pPortName", wintypes.LPWSTR),
                ("pDriverName", wintypes.LPWSTR), ("pComment", wintypes.LPWSTR),
                ("pLocation", wintypes.LPWSTR), ("pDevMode", wintypes.LPVOID),
                ("pSepFile", wintypes.LPWSTR), ("pPrintProcessor", wintypes.LPWSTR),
                ("pDatatype", wintypes.LPWSTR), ("pParameters", wintypes.LPWSTR),
                ("pSecurityDescriptor", wintypes.LPVOID),
                ("Attributes", wintypes.DWORD), ("Priority", wintypes.DWORD),
                ("DefaultPriority", wintypes.DWORD), ("StartTime", wintypes.DWORD),
                ("UntilTime", wintypes.DWORD), ("Status", wintypes.DWORD),
                ("cJobs", wintypes.DWORD), ("AveragePPM", wintypes.DWORD)]
```

and beside the other `argtypes` declarations:

```python
winspool.GetPrinterW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPBYTE,
                                 wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
winspool.GetPrinterW.restype = wintypes.BOOL
```

then, above `handle_request`:

```python
def queue_status(printer_name):
    """Read the queue's real state. ready = the queue opens and reports no
       error/offline/paused bit; jobs = its current job count. Never raises --
       an unopenable queue is a not-ready answer, which is the honest one."""
    h = wintypes.HANDLE()
    if not winspool.OpenPrinterW(printer_name, ctypes.byref(h), None):
        return {"queue": printer_name, "ready": False, "jobs": 0}
    try:
        needed = wintypes.DWORD(0)
        winspool.GetPrinterW(h, 2, None, 0, ctypes.byref(needed))
        if not needed.value:
            return {"queue": printer_name, "ready": False, "jobs": 0}
        buf = ctypes.create_string_buffer(needed.value)
        if not winspool.GetPrinterW(h, 2, ctypes.cast(buf, wintypes.LPBYTE),
                                    needed.value, ctypes.byref(needed)):
            return {"queue": printer_name, "ready": False, "jobs": 0}
        info = ctypes.cast(buf, ctypes.POINTER(PRINTER_INFO_2)).contents
        # PRINTER_STATUS_ERROR | _OFFLINE | _PAUSED | _NOT_AVAILABLE | _NO_TONER
        bad = 0x00000002 | 0x00000080 | 0x00000001 | 0x00001000 | 0x00040000
        return {"queue": printer_name,
                "ready": (info.Status & bad) == 0,
                "jobs": int(info.cJobs)}
    finally:
        winspool.ClosePrinter(h)
```

- [ ] **Step 4: Add `serve_connection` and rewrite the accept loop**

Above `def main():`:

```python
def _read_request(conn):
    """Read until the peer half-closes, or the idle timeout, or the size cap."""
    chunks, total = [], 0
    try:
        while True:
            b = conn.recv(4096)
            if not b:
                break
            chunks.append(b)
            total += len(b)
            if total >= MAX_REQUEST_BYTES:
                break
    except socket.timeout:
        pass
    return b"".join(chunks)


def serve_connection(conn, printer_name, spool, status):
    """Read one request, write one response line, close. Never raises."""
    try:
        conn.settimeout(READ_TIMEOUT)
        reply = handle_request(_read_request(conn), printer_name, spool, status)
        if reply is not None:
            conn.sendall((reply + "\n").encode("ascii", "replace"))
            print("  %s" % reply)
            sys.stdout.flush()
    except Exception as e:
        print("  HANDLER ERROR: %s" % _oneline(e))
        sys.stdout.flush()
    finally:
        try:
            conn.close()
        except Exception:
            pass
```

Then replace everything in `main()` from `while True:` to the end of the function with:

```python
    while True:
        try:
            conn, addr = srv.accept()
        except socket.timeout:
            continue
        print("  connection from %s" % (addr[0],))
        sys.stdout.flush()
        serve_connection(conn, printer_name,
                         lambda d: send_raw(printer_name, d),
                         lambda: queue_status(printer_name))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest zebraPrinter/tests/test_bridge_protocol.py -v`
Expected: PASS, 10 passed

- [ ] **Step 6: Commit**

```bash
git add zebraPrinter/usb_tcp_bridge.py zebraPrinter/tests/test_bridge_protocol.py
git commit -m "feat(bridge): the socket answers -- read to EOF, reply on one line, close"
```

---

### Task 6: Verify against the real printer

The tests prove the protocol. Only hardware proves the spooler path, and the `job` id in the ACK has never been read from a real `StartDocPrinterW` return.

**Files:**
- Modify: `zebraPrinter/PROTOCOL.md` (record the observed exchange)

**Interfaces:**
- Consumes: the whole bridge from Tasks 2-5
- Produces: a verified reference exchange the C# service can be tested against

- [ ] **Step 1: Start the patched bridge against the real queue**

On the machine with the Zebra:

```bash
python zebraPrinter/usb_tcp_bridge.py "Zebra GX420d (RAW)"
```

Expected: `Bridging  0.0.0.0:9100  ->  printer 'Zebra GX420d (RAW)'   (Ctrl-C to stop)`

- [ ] **Step 2: Probe it, consuming no label**

From the Gateway host:

```bash
powershell -Command "$c=New-Object Net.Sockets.TcpClient('10.20.11.157',9100); $s=$c.GetStream(); $b=[Text.Encoding]::ASCII.GetBytes('?STATUS'); $s.Write($b,0,$b.Length); $s.Flush(); $c.Client.Shutdown('Send'); (New-Object IO.StreamReader($s)).ReadLine(); $c.Close()"
```

Expected: `OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0`
No label prints.

- [ ] **Step 3: Print one label and read the ACK**

```bash
powershell -Command "$c=New-Object Net.Sockets.TcpClient('10.20.11.157',9100); $s=$c.GetStream(); $b=[Text.Encoding]::ASCII.GetBytes('^XA^CFA,30^FO50,50^FDPROTOCOL V1^FS^XZ'); $s.Write($b,0,$b.Length); $s.Flush(); $c.Client.Shutdown('Send'); (New-Object IO.StreamReader($s)).ReadLine(); $c.Close()"
```

Expected: `OK queue='Zebra GX420d (RAW)' job=<n> bytes=39` with `<n>` a non-zero spooler job id, and a label reading `PROTOCOL V1` physically emerges.

If `job=0`, `StartDocPrinterW`'s return is not the job id on this driver and Task 4 Step 4 needs revisiting -- record that rather than shipping a zero.

- [ ] **Step 4: Confirm the reachability probe still prints nothing**

```bash
powershell -Command "(Test-NetConnection 10.20.11.157 -Port 9100).TcpTestSucceeded"
```

Expected: `True`, the bridge logs `connection from <ip>`, and **no label prints**. This is the behaviour `validateEndpoint` depends on.

- [ ] **Step 5: Record the verified exchange in `PROTOCOL.md`**

Append to `zebraPrinter/PROTOCOL.md`:

```markdown
## Verified

Observed against a Zebra GX420d on `Zebra GX420d (RAW)` / USB001, bridge host
`10.20.11.157`, Gateway host `10.20.11.53`:

    ?STATUS  -> OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0
    ^XA...   -> OK queue='Zebra GX420d (RAW)' job=<n> bytes=39   (label printed)
    (empty)  -> no reply, no label

The C# `MesZebraBridge` service is correct when it reproduces these three
exchanges byte for byte.
```

Replace `<n>` with the job id actually observed.

- [ ] **Step 6: Commit**

```bash
git add zebraPrinter/PROTOCOL.md
git commit -m "docs(bridge): record the protocol exchange verified against real hardware"
```
