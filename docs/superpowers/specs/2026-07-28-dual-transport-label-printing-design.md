# Dual-Transport Label Printing — Design

**Date:** 2026-07-28
**Status:** Approved (design); implementation plan pending
**Scope:** Transport layer + container-label wiring + label-type printer routing
**Supersedes:** the single-transport assumption in `docs/superpowers/specs/2026-06-15-arc2-phase4-gateway-frontend-design.md` §5

---

## 1. Problem

Label dispatch is built for a plant that does not exist yet.

Both dispatchers — `BlueRidge.Lots.LotLabel` and `BlueRidge.Lots.ShippingDispatcher` — carry a
byte-identical private `_dispatchZpl(endpoint, zpl)` that does exactly one thing: open a raw TCP
socket to `host:port` (default 9100) and write ASCII bytes. That is the entire transport layer.

MPP's actual fleet does not match it. `zebraPrinter/MPP_Terminal_Printer_Inventory.xlsx` tab 3
lists **63 printers: 63 have Windows share paths, 1 has an IP address.** MPP has confirmed the
fleet is mixed — some printers networked, some USB-hardwired to the shop-floor terminal PC.

Three further gaps compound it:

1. **No `Endpoint` value is seeded anywhere.** `sql/seeds/011_seed_locations_mpp_plant.sql`,
   `sql/seeds/gen_locations_mpp.js`, and `sql/scripts/reconcile_location_dev.sql` all create the
   `LocationAttributeDefinition` for `Endpoint` and never a single `LocationAttribute` value. All 30
   seeded printers resolve to `endpoint = ""`, so every dispatch fail-fasts on *"This terminal has no
   printer configured."*
2. **The attribute contract is already a lie.** `Endpoint`'s description reads
   `'Zebra print target - IP:port or print-queue name'`. The print-queue half was never implemented.
3. **`ShippingDispatcher` has zero callers.** Not `Container.complete`, not
   `Assembly.handleTrayComplete`, not any view. A completed container writes a `Lots.ShippingLabel`
   row and prints nothing. The only would-be caller, `PrintFailureGateway.sweepTick()`, is a bare
   `return`.

### 1.1 What the topology rules out

Perspective view scripts execute on the **Gateway**, not the client, and a browser session cannot
open a socket. There is no client-side path to a USB printer. Every printer — networked or
hardwired — must be reachable from the Gateway over the network. The only question is by which
protocol.

---

## 2. Decision

Build **two transports behind one interface**, selected by the syntax of the `Endpoint` string
(Approach A of three considered; see §9).

| `Endpoint` value | Transport | Reaches |
|---|---|---|
| `10.20.30.40:9100` | Raw TCP — **port mandatory** | A networked Zebra, or a terminal running the USB bridge |
| `\\FLXWAPSRV1\5A2 Machining Out` | Windows print queue (UNC) | A printer shared from a print server or a terminal PC |
| `Zebra GX420d (RAW)` | Windows print queue (local) | A queue installed on the Gateway host itself |

**Making the port mandatory on TCP is what removes the ambiguity that exists today.** The current
code treats any colon-less string as `hostname:9100`, so a bare `printer01` could equally be a
hostname or a queue name and the code silently guesses. With the port required, a bare name
unambiguously means "queue."

This is a free change: because **zero endpoints are seeded**, there is no migration and no existing
value to break.

### 2.1 Rejected alternatives

- **Explicit `ConnectionType` attribute** — adds schema, seed, reconcile-script and UI changes, plus
  a second field MPP must populate correctly across ~60 printers, to carry information the endpoint
  string already carries unambiguously. Deferred; can be added later if a real case demands it.
- **Unify on TCP, require the bridge everywhere** — one code path, but ~20 agent installs to deploy
  and monitor, and it makes a software problem into an ops problem. Rejected as the *only* option;
  retained as one valid deployment choice per printer under this design.

---

## 3. Components

### 3.1 `BlueRidge.Lots.LabelTransport` — new Core module

The single home for "get these bytes to that printer." No business logic, no DB access.

**Public surface**

```
send(endpoint, zpl) -> {ok: bool, error: str|None, transport: "tcp"|"queue"|None}
describeEndpoint(endpoint) -> {transport, target, valid, reason}
```

`describeEndpoint` is pure, side-effect-free, and exists so commissioning can ask "what will this
string do?" from the Designer Script Console before a printer is ever wired. It delivers the
config-time feedback that the rejected `ConnectionType` attribute would have provided, without the
second field.

**Internal**

```
_parseEndpoint(endpoint) -> {kind, host, port, queue, reason}
_sendTcp(host, port, zpl) -> {ok, error}      # existing socket code, moved verbatim
_sendQueue(queueName, zpl) -> {ok, error}     # javax.print
```

**Grammar (normative, evaluated in order):**

1. Empty or whitespace-only → `invalid`, reason `"empty endpoint"`
2. Starts with `\\` → `queue`, target = the UNC path verbatim
3. Matches `^(.+):(\d+)$` → `tcp`, host = group 1, port = group 2
4. Otherwise → `queue`, target = the string verbatim (a queue local to the Gateway host)

**`_sendTcp`** is the current implementation unchanged: `Socket()`, `connect(InetSocketAddress,
4000)`, `setSoTimeout(4000)`, write `US-ASCII` bytes, flush, close in `finally`.

**`_sendQueue`** uses `javax.print`: look up print services via
`PrintServiceLookup.lookupPrintServices(None, None)`, match by name, and print a `SimpleDoc` with
`DocFlavor.BYTE_ARRAY.AUTOSENSE` so the ZPL passes through un-transformed. It returns the same
`{ok, error}` shape, and reports a distinct error when no service matches the name — that error text
is the one commissioning will read most often, so it names the queue and says the queue must be
visible to the Gateway's service account.

> **Deployment prerequisite, stated plainly.** `javax.print` enumerates printers visible to the
> account running the JVM. A UNC queue is not reachable merely by naming it — the printer connection
> must be installed on the Gateway host under the Gateway service account, and that account must be
> a domain user with access to the share. This is an IT prerequisite, not a code concern, and it is
> on the pre-onsite ask (§8).
>
> **Scaling note.** The queue transport suits a modest number of shared printers. If MPP ends up
> with 60 USB-on-terminal printers, installing 60 printer connections on the Gateway is worse than
> deploying the TCP bridge. Transport choice is per-printer and can be revised per site without a
> code change — that is the point of the design.

### 3.2 Both dispatchers drop their private copies

`LotLabel._dispatchZpl` and `ShippingDispatcher._dispatchZpl` are deleted; both call
`LabelTransport.send`. The duplicate is the reason a transport fix would otherwise have to be made
twice and could drift.

`_logDispatch` in both modules gains the transport name in its `description`
(`"LTT dispatch via tcp to 10.20.30.40:9100"`), so `Audit.InterfaceLog` distinguishes a TCP failure
from a queue failure without re-deriving it from the endpoint string.

### 3.3 Fold-in fix: the `_logDispatch` inconsistency

The two `_logDispatch` implementations currently disagree, and `LotLabel`'s is wrong.

`audit/Audit_LogInterfaceCall` is `"type": "UpdateQuery"`, and `Common.Db` documents the rule
directly: an UpdateQuery NQ must go through `execNonQuery`. `LotLabel` was changed (uncommitted) to
`execList`, which hands `_rowsToDicts` an Integer row count and throws — swallowed silently by a
bare except. `ShippingDispatcher` kept `execNonQuery`, and its comment states the opposite of
`LotLabel`'s.

Standardise on **`execNonQuery` + a bare `except:`**. The bare except is correct and must stay:
Jython 2's `except Exception` does not catch `java.lang.Throwable`, so a Java-side failure would
otherwise escape and break dispatch. Both modules get the same three lines and the same comment.

### 3.4 `Location.Terminal_GetPrinter` v2.0 — label-type routing

Today: `SELECT TOP 1 ... ORDER BY p.SortOrder, p.Id`. One printer per terminal, full stop.

Changes:

- New `LocationAttributeDefinition` on def 16 (`Printer`): **`LabelTypes`**, `NVARCHAR`, optional —
  a CSV of `Lots.LabelTypeCode.Code` values. The seeded codes are `Primary`, `Container`, `Master`,
  `Void` (migration `0004`); **`Primary` is the LTT / lot label**, which is what
  `LotLabel.printLabel` already default-resolves.

  > **Naming mismatch to reconcile.** The legacy inventory's "Label Type(s) Printed Here" column
  > uses `Lot`, `Container`, and `Container Hold` — none of which are our code values except
  > `Container`. The CSV stores **our** codes, not the inventory's wording, and the mapping is
  > `Lot -> Primary`, `Container -> Container`, `Container Hold -> (no code yet)`. A `Hold` code
  > does not exist and is added only when hold labels are built (§7); until then a hold printer is
  > recorded with a blank `LabelTypes` and reached through the fallback.
- New optional parameter `@LabelTypeCode NVARCHAR(50) = NULL`.
- Resolution:
  - `@LabelTypeCode IS NULL` → current behaviour exactly (TOP 1 by `SortOrder, Id`).
  - Provided → prefer a non-deprecated Printer child whose `LabelTypes` CSV contains the code;
    if none matches, **fall back** to the terminal's TOP 1.
- Returns the existing shape plus a `LabelTypes` column.

**Backward compatibility is total.** Every existing caller passes no label type and is unaffected;
every currently-seeded printer has a blank `LabelTypes` and keeps working through the fallback. This
also means the design is safe whether or not multi-printer-per-terminal turns out to be real — see
§8.2 item 4.

### 3.5 Printer resolution at dispatch time

`session.custom.printer` remains the terminal's default/fallback printer, resolved once by
`Terminal.applyToSession`. It is **not** expanded into a per-label-type map — that would bloat
session state and add a staleness surface.

Instead, when a dispatch knows its label type, it resolves `(terminal, labelType)` from the DB at
dispatch time and falls back to the session printer. Printing is a human-speed action; one extra
round trip is not a concern, and resolving fresh also sidesteps the existing staleness bug where a
printer configured mid-session is invisible until restart.

### 3.6 Container-label wiring

`Container_Complete` is a SQL proc and cannot print. The Python caller must, mirroring the pattern
already proven in `Workorder.Machining.mint()`.

`BlueRidge.Lots.Container.complete()` gains a dispatch tail: on `Status = 1` with a
`ShippingLabelId`, call `ShippingDispatcher.dispatchContainer(containerId, terminalLocationId)`,
check the returned `Status`, catch genuine exceptions, and **never lose the committed container** —
a print failure toasts and leaves the container complete.

`Assembly.handleTrayComplete` already routes through `Container.complete`, so it inherits the print
from this one wiring point.

`Shipping.reprintLabel()` gains the same tail. Today it writes a `ShippingLabel` row and prints
nothing while the Shipping Dock reports *"Label reprinted"* — a toast that is simply untrue.

### 3.7 `Lots.ShippingLabel_RecordDispatch` — new proc

`Lots.ShippingLabel` already carries `PrintedAt`, `PrintAttempts`, `LastPrintAttemptAt`,
`LastPrintError`, `PrintFailedAt`. **No code writes any of them.**

Mirror `Lots.LotLabel_RecordDispatch`: on success set `PrintedAt`; on failure increment
`PrintAttempts`, set `LastPrintAttemptAt` and `LastPrintError`, and set `PrintFailedAt` once
attempts are exhausted. Status-row proc, no OUTPUT params, per FDS-11-011.

This is also what unblocks `PrintFailureGateway.sweepTick()` later — the stranded-label sweep in
FDS-07-006b cannot be built until these columns are populated. Building the sweep is **not** in this
scope; populating the columns it will read is.

### 3.8 Container template storage — recommended, flagged

`ShippingDispatcher._CONTAINER_TEMPLATE` is a hard-coded Python string constant. FDS §2064 requires
*"ZPL templates SHALL be configurable (not hard-coded)"*, and the LTT path already honours this by
storing bodies in `Lots.LabelTemplate`.

**Recommendation:** move the constant into `Lots.LabelTemplate` for `LabelTypeCodeId = 2`
(`Container`) and have `_renderContainerLabel` fetch the body instead of referencing a module
constant. Token substitution stays in Python.

This is a deliberate middle path. It satisfies "configurable" cheaply, without relocating the render
into SQL — which would be the full fix per the Phase 4 render-in-SQL decision, but is a materially
larger change (a new render proc, its own tests) that would inflate this scope.

**Flagged as a judgment call:** it leaves container rendering in Python while LTT rendering is in
SQL. That inconsistency is real. It is recorded here rather than silently accepted, and full
convergence is a candidate follow-up alongside the operation-template convergence TODO.

### 3.9 Also fixed in passing

`Lots.PrintReasonCode` Id 2 is seeded as `'Reprint — Damaged'` with an em-dash, which mojibakes
through `sqlcmd` per the repo's ASCII-only seed rule (tracked as P4-7). Corrected to
`'Reprint - Damaged'` in the same pass, since the label path is already being touched.

---

## 4. Data flow

**LTT (unchanged except the last hop):**

```
view -> LotLabel.printLabel(data, appUserId, terminalLocationId)
     -> NQ lots/LotLabel_Print -> Lots.LotLabel_Print
          (resolve LabelTemplate.ZplBody, substitute tokens, INSERT LotLabel, return ZplContent)
     -> resolve printer: Terminal_GetPrinter(terminal, 'Primary') | session.custom.printer
     -> LabelTransport.send(endpoint, zpl)          <-- NEW: tcp or queue
     -> Audit.InterfaceLog (every attempt, transport named)
     -> on success: Lots.LotLabel_RecordDispatch (PrinterName + DispatchedAt)
     -> on failure: one re-resolve + retry, then a UI message offering Reprint
```

**Container (new end-to-end):**

```
Assembly.handleTrayComplete -> Container.complete
     -> NQ lots/Container_Complete (claims AIM Shipper ID, INSERTs ShippingLabel)
     -> ShippingDispatcher.dispatchContainer(containerId, terminalLocationId)   <-- NEW WIRING
          -> NQ lots/Container_GetLabelData  (PartNumber, Description, CountryOfOrigin,
                                              Quantity, MfgDate, MfgLotNumber, Serial)
          -> render from LabelTemplate (LabelTypeCodeId 2)
          -> resolve printer: Terminal_GetPrinter(terminal, 'Container') | session.custom.printer
          -> LabelTransport.send(endpoint, zpl)
          -> Audit.InterfaceLog
          -> Lots.ShippingLabel_RecordDispatch     <-- NEW
     -> print failure never rolls back the completed container
```

---

## 5. Error handling

The governing rule is unchanged and non-negotiable: **a print failure never rolls back a business
transaction.** Minting a LOT and printing its label are separate steps; so are completing a
container and printing its label. This already holds in `LotLabel` and `Machining.mint`, and the new
container wiring follows it exactly.

| Condition | Behaviour |
|---|---|
| Empty endpoint | Fail-fast, `"This terminal has no printer configured."` No transport attempted. |
| Malformed endpoint | `describeEndpoint` reports it; `send` returns `{ok: False}` with the parse reason. |
| TCP connect/write failure | 4 s bounded timeout, logged, one DB re-resolve + retry, then surfaced. |
| Queue not found | Distinct error naming the queue and the service-account requirement. |
| `Audit.InterfaceLog` write failure | Swallowed by bare `except:` — logging must never break dispatch. |
| Container print failure | Container stays complete; operator toasted; `ShippingLabel` failure columns written. |

---

## 6. Testing

**No hardware is required for anything but final certification.**

*SQL*
- `Terminal_GetPrinter` v2: label-type match; fallback when `LabelTypes` blank; fallback when no
  printer matches the type; empty result when the terminal has no printer child; NULL label type
  reproduces v1 behaviour exactly (regression guard for every existing caller).
- `ShippingLabel_RecordDispatch`: success path sets `PrintedAt`; failure path increments
  `PrintAttempts` and sets `LastPrintError`; exhausted attempts set `PrintFailedAt`; bad id →
  `Status = 0`.
- Re-run the full suite: `Terminal_GetPrinter` gains a column, so any fixed-shape `INSERT-EXEC`
  capture over it must be updated (per the repo's re-run-after-shape-change rule).

*Python*
- `describeEndpoint` is pure — drive it from the Script Console over a table of inputs covering every
  grammar branch plus the ambiguous cases the old code got wrong (`printer01`, `10.0.0.5` with no
  port, a UNC path containing spaces).
- `_sendTcp` against `zebraPrinter/usb_tcp_bridge.py` on the Gateway box, or any socket listener.
- `_sendQueue` against a Windows queue installed on the Gateway host.

*Visual*
- Labelary for ZPL rendering, especially the Container template's rotated `^A0R` fields and
  ~1300-dot coordinates, which were authored for specific stock at a specific dpi. Verify before
  certifying against real stock.

---

## 7. Out of scope

Named explicitly so they are not silently assumed:

- **The FDS-07-006b stranded-print sweep and failure banner.** `PrintFailureGateway` stays a no-op.
  This design populates the columns that sweep will read; building the sweep is separate.
- **Async dispatch (FDS-07-005 / 006a `sendRequestAsync`).** Both dispatchers stay synchronous with
  one retry. The schema was built for the async design, so this divergence remains reversible.
- **Hold labels.** No template, no `LabelTypeCode` row, no print action. The `LabelTypes` attribute
  added in §3.4 is the extension point, so adding a `Hold` code later does not redo the routing work.
- **Honda blank fields** — Part No. Ext (C), D/C Part Level (2P), Auditor, 2D DataMatrix. Confirmed
  not AIM-sourced; they need part-master columns, a capture point, and the Honda content spec.
- **Moving container rendering into SQL.** See §3.8.

---

## 8. Pre-onsite MPP ask

Everything below can be done by MPP before anyone travels. Ordered by value.

### 8.1 The one command that could shrink this whole problem

**A share path tells us nothing about whether the printer is networked.** A queue shared as
`\\FLXWAPSRV1\5A2 Machining Out` may well sit on a TCP/IP port pointing at a Zebra that already has
an IP — in which case we skip the queue transport entirely and print direct.

Run on **FLXWAPSRV1** (and each other sharing host: `887intel`, `615lenovo-pc`, `985dell`,
`633Lenovo`, `922intel`, `767lenovo`):

```powershell
Get-Printer | Select-Object Name,DriverName,PortName,Shared,ShareName,PrinterStatus |
    Export-Csv "$env:USERPROFILE\Desktop\printers_$env:COMPUTERNAME.csv" -NoTypeInformation
Get-PrinterPort | Select-Object Name,Description,PrinterHostAddress,PortNumber |
    Export-Csv "$env:USERPROFILE\Desktop\printerports_$env:COMPUTERNAME.csv" -NoTypeInformation
```

`PrinterHostAddress` is the answer. Every row with an IP is a printer we can reach directly today.
This is the highest-value pre-onsite action by a wide margin — it may convert most of the "hardwired"
fleet into the already-built TCP path, and it costs one command.

### 8.2 Complete the inventory workbook

`MPP_Terminal_Printer_Inventory.xlsx` is mostly empty.

1. **Tab 2 (Terminals) is entirely blank — 60 empty rows.** This is the single most important
   missing dataset in the project, and it is not only a printing concern: the MES resolves a
   terminal's screen and zone **from the IP it connects from**. Without terminal name/hostname +
   static IP, nothing works. A stale or unregistered IP currently falls back to a terminal whose
   zone is the whole Madison Facility, which produces plant-wide queues and confusing errors.
2. **Tab 3 columns that are blank for all 63 rows:** Associated Terminal (the terminal↔printer link
   we need), Printer Model, Connection Type, Printer IP, Label Stock size.
3. **Printer Model matters more than it looks** — it sets dpi (203 vs 300). The legacy Container
   template's ~1300-dot coordinates were authored for one specific combination; a different dpi
   renders wrong.
4. **Does any terminal drive more than one printer?** The Lot/Container split mostly tracks terminal
   role (Machining OUT → Lot, Assembly OUT → Container), which would mean one printer per terminal
   holds fine. But three printers share legacy workcell 110 (`6MA 1 Final Assembly`, `6MA Assembly A
   P1`, `6MA Assembly B P1`) and two share workcell 104 (`Zebra Hold 1/2`). Whether those are one
   terminal or several decides whether §3.4's routing is load-bearing or just insurance.
5. **Which of the 63 are still in service?** The list is legacy; some are likely decommissioned.

### 8.3 Decisions MPP IT can make now

1. **Will the Zebras get static IPs or network cards?** Every yes collapses a printer onto the
   simplest, already-built path.
2. **What account will the Ignition Gateway service run as?** `LocalSystem` cannot reach a UNC
   share. The queue transport requires a domain user. This gates §3.1 entirely.
3. **Are shop-floor terminal PCs domain-joined, and may they share a printer?**
4. **May we install a small Windows service on terminal PCs?** If yes, the TCP bridge is available
   as a per-printer option.
5. **Is outbound TCP 9100 from the Gateway to the plant-floor VLAN permitted?** Worth confirming
   before it is discovered onsite.

### 8.4 Physical checks MPP can do without us

- For any printer believed to be networked, **print a config label** (hold the feed button) — it
  prints the IP and firmware. Cheap and definitive.
- Identify dead or decommissioned printers.
- **Collect one physical sample of each label type** currently printed — Lot, Container, Container
  Hold. We compare our ZPL output against the real thing rather than against the legacy template's
  coordinates.

### 8.5 Label-content data (same audience, different problem)

Not transport, but owed by the same people and worth asking in one message:

- **Part Number Extension (C)** — where does this live today? A column, embedded in the part number,
  or sourced from Macola?
- **D/C Part Level (2P)** — the design-change/revision level. MES has no revision column on `Item`.
- **Auditor** — the LOT creator's initials, or a separate QA sign-off captured at container close?
  The second needs a capture point we do not have.
- **Honda 2D DataMatrix content spec** — the exact field concatenation.
- **Does any MPP part ship to more than one Honda destination?** From the AIM contract note: AIM
  resolves label format by Item + Destination, and explicitly excludes parts with
  destination-specific content.

---

## 9. Approaches considered

| | Transport selection | Verdict |
|---|---|---|
| **A** | Endpoint grammar — the string declares the transport | **Chosen.** No schema/seed/UI change; one field for MPP to fill instead of two; delivers the contract the attribute already promises. Ambiguity removed by making the TCP port mandatory, which is free because no endpoint is seeded. |
| **B** | Explicit `ConnectionType` attribute | Rejected. Config-time validation is its real benefit, and `describeEndpoint` provides that without a second field to populate correctly across ~60 printers. |
| **C** | Hybrid — parse by default, attribute overrides | Rejected. Two sources of truth for one decision is how config drift starts. Add B later if a real case demands it. |

---

## 10. Open questions

1. **Multi-printer per terminal** — real, or does one-per-terminal hold? (§8.2 item 4.) The fallback
   in §3.4 makes the design safe either way; the answer only decides whether the routing is
   load-bearing.
2. **Gateway service account** — until answered (§8.3 item 2), the queue transport is built but
   unprovable against a real share.
3. **Bridge packaging** — if the TCP bridge is used on terminals, it needs to bind the LAN IP rather
   than loopback and run as a Windows service. `usb_tcp_bridge.py` today binds `127.0.0.1` and dies
   with the console session. Scoped only if MPP chooses that path for at least one printer.
