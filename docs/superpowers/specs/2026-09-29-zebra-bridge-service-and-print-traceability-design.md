# Zebra Bridge Service and Print Traceability -- Design Spec

**Date:** 2026-09-29
**Status:** Design -- approach settled with Jacques 2026-09-29
**Scope:** 54 printers / 77 terminals, 100% USB-attached (MPP direction, 2026-09-29)
**Evidence:** end-to-end bring-up run 2026-09-29 against `MPP_MES_Dev`, Gateway `10.20.11.53`,
printer host `10.20.11.157`. Dispatch records in `Audit.InterfaceLog` ids 13-17; shipping labels
`Lots.ShippingLabel` 20015-20018. Every failure mode named in this spec was observed that day, not
hypothesised.
**Builds on:** `BlueRidge.Lots.LabelTransport` (the one place ZPL leaves the Gateway),
`BlueRidge.Lots.ShippingDispatcher`, `BlueRidge.Lots.LotLabel`,
`BlueRidge.Lots.PrintFailureGateway`.
**Supersedes:** `zebraPrinter/usb_tcp_bridge.py` as a deployment artifact. The script remains
useful as a bench tool and as the reference implementation of the spooler call.

---

## 1. Why

On 2026-09-29 a single shipping label was driven end to end from a Perspective client through the
Gateway to a USB Zebra on another machine. It worked. Getting there took most of a day, and
**none of the time went on the label** -- it went on three failures that the system could not
describe:

1. **A route black-hole.** The Gateway host held a stale DHCP lease on a disconnected USB NIC,
   which won the route to `10.20.11.0/24` at metric 25 and silently discarded all traffic to the
   subnet.
2. **A wrong address, and a test that could not detect it.** The printer host had moved from
   `.106` to `.157`. ICMP was blocked at that host, so `ping` failed identically whether the host
   was absent or merely firewalled.
3. **A missing inbound firewall rule** on the printer host. This surfaced as
   `ErrorCondition = DispatchFailed`, `ErrorDescription = "Connect timed out"` -- distinguishable
   from a stopped bridge (`Connection refused`) only by reading `Audit.InterfaceLog` directly.

Diagnosing one label required three uncorrelated sources: `Audit.InterfaceLog`, the
`Lots.ShippingLabel` row state, and a human reading a console window on a machine in the plant.
That does not scale to 54 terminals.

Two gaps were worse than the failures:

- **Stage 3 (endpoint resolution) is silent.** `ShippingLabel` 20016 and 20017 sat at
  `PrintedAt NULL` / `PrintFailedAt NULL` with **no `InterfaceLog` row at all**. The dispatch
  worker never ran and nothing recorded why. A stage that fails silently is worse than one that
  fails loudly.
- **There is no test print.** `BlueRidge.Location.Printer.validateEndpoint` checks endpoint string
  grammar only; nothing opens a socket. Commissioning 54 printers with no way to verify one --
  short of manufacturing a real container -- is the largest avoidable cost in the rollout.

## 2. Scope

**In:**
- A Windows service (`MesZebraBridge`) replacing the Python bridge as the deployed artifact.
- A wire protocol: ZPL in, one ACK line back; plus a `?STATUS` probe that prints nothing.
- `LabelTransport` reading the ACK and recording what the bridge actually did.
- One `Audit.InterfaceLog` row per dispatch on the happy path, carrying the whole journey.
- A logged resolve stage, closing the silent gap.
- A per-terminal deployment and commissioning sequence.

**Out:**
- Confirming that media physically fed (section 6.4).
- A heartbeat / live status board for all 54 terminals (section 11.2).
- Multiple printers behind one bridge (section 11.1).
- Migrating existing networked printers off raw 9100. They keep working unchanged.

## 3. The bridge service

A single self-contained executable targeting **.NET Framework 4.8**, present on every Windows
10/11 image, so there is no runtime to install and the binary stays small.

**Deployment per machine is one file and one command:**

```
MesZebraBridge.exe install
```

The executable registers itself with the SCM, sets its own recovery options (restart on failure),
adds its own inbound firewall rule scoped to the Gateway address, and starts. Chosen over a
session process because "no touch" is stronger than "possible": a service starts before any
logon, survives the kiosk session being cycled, and is restarted by the SCM when it dies.

That last point is not theoretical. On 2026-09-29 the Python bridge exited on a queued `Ctrl-C`
the instant an unrelated probe released `accept()`, consumed the print job it was mid-way through
handling, and stayed dead. Across 54 unattended plant PCs that is a silent outage that reaches us
as "the printer is broken."

**Carried over from the Python implementation:**
- Spooler write via `winspool.drv` with the `RAW` datatype, so ZPL passes through untransformed.
- Listen on `0.0.0.0:9100`.

**Changed:**
- `SO_EXCLUSIVEADDRUSE` instead of `SO_REUSEADDR`. On Windows the latter permits a *second live
  process* to bind the same port with undefined delivery between them -- unlike POSIX, where it
  only permits rebinding a `TIME_WAIT` port.
- Queue resolution: auto-detect the Zebra queue, overridable in config. The queue name is the one
  value that differs per machine, and hand-typing it 54 times is 54 chances to hit the
  `Zebra GX420d (RAW)` vs `ZDesigner GX420d` trap observed on 2026-09-29. Detection enumerates
  local queues and selects the single one whose driver is a Zebra/ZDesigner driver **on a live
  port**; zero matches or more than one is a startup error naming what it found, never a guess.
  That host on 2026-09-29 had three candidate queues, two of them stale (`ZDesigner GX420d` bound
  to `LPT1:`), so the live-port test is the part doing the work.
- A rolling local log file. On 2026-09-29 the bridge's output existed only because it happened to
  be redirected.

## 4. Wire protocol

### 4.1 Print

The Gateway writes ZPL, half-closes its side, and reads one line.

```
-> <ZPL bytes>            then shutdownOutput()
<- OK queue='Zebra GX420d (RAW)' job=41 bytes=1264
<- ERR queue not found: 'ZDesigner GX420d'; visible: Zebra GX420d (RAW), ...
```

The half-close is load-bearing: it ends the bridge's read immediately instead of waiting out an
idle timeout, keeping the round trip in milliseconds.

**Why an ACK rather than a callback.** An earlier draft had the bridge POST its outcome back to
the Gateway, correlated by a `DispatchId` embedded in a ZPL `^FX` comment. That was discarded.
We own both ends of this socket, so the outcome can come back on the connection that is already
open: no correlation id, no second network path, no reverse firewall rule, and -- decisively --
**one log row instead of eight** (section 6.1).

**Networked Zebras are unaffected.** A real printer on raw 9100 never replies. A read timeout is
recorded as `sent, no ack (raw 9100)` and is **not** an error. The distinction is recorded rather
than smoothed over.

**What `ok` now means.** Today it means bytes left the Gateway. With an ACK it means the bridge
handed those bytes to the named Windows queue as a specific job. That is a materially stronger
claim, and it is the strongest one available (section 6.4).

### 4.2 Probe

The same protocol with a payload that is not ZPL:

```
-> ?STATUS
<- OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0
```

No label is consumed. This is the commissioning tool for all 54 printers and the basis of the
**Test this printer** action the Config Tool lacks today. A payload beginning `?` is a command;
anything else is ZPL. (The existing Python bridge already tolerates a no-data connection without
printing -- `if data:` guards the spool -- which is how reachability was probed on 2026-09-29
without wasting labels.)

## 5. `LabelTransport` changes

`_sendTcp` gains the half-close, a bounded ACK read, and returns the parsed ACK alongside
`{ok, error}`. `_sendQueue`, `_parseEndpoint` and the `send` dispatch are unchanged.

**The endpoint grammar is not being touched, but one property of it must be stated,** because it
cost real time on 2026-09-29: `_parseEndpoint` falls through to `kind: "queue"` for anything that
is not `host:port` or a UNC path. So **an endpoint missing its port is silently reclassified as a
Windows print-queue name** and fails at the spooler with an error pointing nowhere near the
network. `10.20.11.157` is a queue name; `10.20.11.157:9100` is a printer. Commissioning must
treat the port as mandatory, and section 9 checks it.

**`_sendQueue` is not a route to a terminal printer.** It uses `javax.print`, which enumerates
queues visible to the *Gateway service account* -- its own error text says the queue must be
installed on the Gateway host. Reaching 54 terminal-attached printers this way would mean 54
shared-printer connections installed on the Gateway under its service account, plus SMB
authentication on every print. Rejected; recorded here so it is not re-proposed.

## 6. Logging model

### 6.1 One row per dispatch

| Outcome | Rows written |
|---|---|
| Success | **1** -- endpoint, queue, job id, byte count, stage reached |
| Transport failure | 1 per attempt (up to 3), each naming the stage it died at |
| Resolve failure | **1** -- the gap that writes nothing today |

Success collapses to one row because `Lots.ShippingLabel.PrintedAt` is already the durable
business fact. `Audit.InterfaceLog` is the *diagnostic* record and does not need to be a second
copy of it. Failures stay verbose deliberately: they are rare, and that is when detail is wanted.

`Audit.InterfaceLog` already has the shape -- `Direction`, `RequestPayload`, `ResponsePayload`,
`ErrorCondition`, `ErrorDescription`, `IsHighFidelity` -- and `audit/Audit_LogInterfaceCall` is
already the write path. No schema change is required.

### 6.2 The resolve stage

`ShippingDispatcher._resolveEndpoint` and `LotLabel._dispatchAfterRender` log the endpoint they
chose **and which tier chose it** (printer-card override / session printer / terminal printer),
or log the failure to resolve one. This is the fix for the `20016`/`20017` silence.

### 6.3 Reading a failure

The stage reached is a field on the row, so diagnosis is one query and no cross-referencing:

```
Resolved -> Sent -> Acked -> Spooled(job 41)    success
Resolved -> Sent -> (no ack)                    networked printer, expected
Resolved -> Sent -> ERR no such queue           queue-name mismatch on the terminal
Resolved -> ConnectTimeout                      firewall on the printer host
Resolved -> ConnectionRefused                   bridge service is down
(resolve failed, no further stages)             configuration -- no endpoint for this terminal
```

`Connect timed out` versus `Connection refused` is the distinction that identified the real fault
on 2026-09-29 and it is preserved verbatim rather than normalised into a generic failure.

### 6.4 What is deliberately not claimed

**We log "spooled", never "printed".** The bridge reports the Windows job id and that is the last
thing we can honestly assert. Whether media fed is not knowable from here, and a `Complete` stage
would be an invented fact.

`Lots.ShippingLabel.PrintedAt` is a slight misnomer under this scheme. It is live schema with
existing consumers and is **left alone**; the precision lives in `InterfaceLog`.

## 7. Per-terminal deployment

Per machine, in order:

1. **Driver** -- install the Zebra driver; confirm the queue name with `Get-Printer`.
2. **Bridge** -- copy `MesZebraBridge.exe`, run `MesZebraBridge.exe install`. Registers the
   service, sets SCM recovery, adds the inbound rule for TCP 9100 scoped to the Gateway, starts.
3. **Address** -- static IP or a DHCP reservation (section 10.1).
4. **Configuration** (section 8) -- Terminal row IP, Printer row `Endpoint` and `ConnectionKind`.
5. **Verify** (section 9) -- `?STATUS` probe, then one real label.

Steps 1-3 happen at the machine; 4-5 from the Config Tool.

## 8. Configuration per terminal

| Row | Requirement |
|---|---|
| `Location.Location` Terminal (TypeDef 7) | IP attribute = the **client device's** IP. Resolves `session.custom.terminal`; an unregistered IP falls back Facility-wide and resolves no printer. |
| `Location.Location` Printer (TypeDef 16) | child of that terminal |
| Printer `Endpoint` | `host:port` -- **port mandatory** (section 5) |
| Printer `ConnectionKind` | `Networked` |
| Terminal `SuppressAimAndLabel` | `1` while legacy owns the line, `0` at go-live. Blocks the AIM claim *and* the label mint. |

**Terminal IP and printer Endpoint are different fields with different jobs.** One binds the
session; one addresses the printer. They coincide only when the browser runs on the machine the
printer is attached to. Conflating them cost time on 2026-09-29.

**`session.custom.printer` resolves once at session startup.** Any configuration change requires
a **new session**, not a page refresh. There is a DB re-resolve fallback, but it fires only when
the session value is empty, or on failure when the freshly resolved endpoint *differs*.

## 9. Commissioning check

Per printer, before it is considered live:

1. `?STATUS` from the Gateway returns `ready=true` and the expected queue name. Proves route,
   firewall, service, and queue binding in one call, with no label consumed.
2. One real label. Confirm the `InterfaceLog` row reads `Spooled` with a job id, and that a label
   physically emerged -- the one step a human still has to do (section 6.4).

Step 1 is what makes 54 printers tractable. Without it, the only test is manufacturing a real
container, which on 2026-09-29 required seeding ten component LOTs, two purchased-part LOTs, and
temporarily shrinking a container configuration.

## 10. Risks

### 10.1 DHCP drift

A moved lease breaks the printer endpoint and any source-scoped firewall rule, silently, and
presents as a printer fault. This has already happened once: the Gateway host carries a stale
inbound rule for `10.20.11.106`, the printer host's former address. **Static addressing or DHCP
reservations are a prerequisite, not a nicety.**

### 10.2 Data quality in existing rows

Terminal 147 (`MA2-6MACH-AOUT3`) holds `http://172.17.21.237` in its IP attribute -- a URL where
every other row holds a bare address. It can never match a client IP. Whether this is deliberate
(consumed as a URL elsewhere) or drift is **unresolved**; it is a live 6MA parallel-run row and
was not touched. Commissioning should validate the shape of this attribute across all 77
terminals before the rollout, not during it.

### 10.3 Silent async failure

`ShippingDispatcher` is gateway-async and `reprintAndDispatch` returns `Status 1` even when the
send fails -- its message becomes "Reprint recorded, but it could not be sent to the printer",
which `notifyResult` renders as a **green** toast. On 2026-09-29 this read as success while three
dispatch attempts were timing out. The logging in section 6 is the mitigation; whether the toast
itself should change is section 12.2.

## 11. Deferred

### 11.1 Multiple printers per bridge

`MA2-59B-AOUT1` currently carries ten printer rows (`P1`-`P10`). As of 2026-09-29 these are ten
*networked* printers and MPP intends to reduce the station to one. The bridge listens on one port
and binds one queue, so a single `host:9100` endpoint cannot address ten queues on one PC. If
that station stays plural **and** goes USB, the endpoint grammar needs a queue selector and
section 4.1 changes. Benched by agreement; revisit before that station is commissioned.

### 11.2 Heartbeat and status board

The `?STATUS` probe answers "is it alive" at the moment someone asks. A periodic heartbeat would
answer it continuously and give a 54-terminal board. Deferred: the probe solves the commissioning
cost, which is certain; the board solves a monitoring need that may not materialise. The probe is
the primitive a heartbeat would be built on, so nothing is foreclosed.

## 12. Open items

1. **Bridge configuration file** -- format and location for the queue-name override and the
   Gateway address used by the firewall rule. Not yet specified.
2. **Should the reprint toast stop reporting success on a failed send?** (section 10.3.) Changing
   it touches `notifyResult` semantics shared by every mutation, so it is raised, not decided.
3. **Service account** for `MesZebraBridge`. `LocalSystem` is sufficient for `winspool` but is
   broader than needed; a lower-privilege account may not see the queue. To be settled at build.
4. **Signing.** An unsigned executable on locked-down plant PCs risks SmartScreen and AV
   heuristics. Whether MPP IT has a signing certificate or a deployment channel that exempts it
   is unknown -- and the answer may also give a push mechanism for the 54 installs.
