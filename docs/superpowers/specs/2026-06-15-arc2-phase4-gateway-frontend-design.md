# Arc 2 Phase 4 — Movement + Trim + Receiving: Gateway + Front-End — Design

**Date:** 2026-06-15
**Status:** Draft for review
**Scope:** The **gateway + Perspective + Named-Query + entity-script** layer for Phase 4 — the deferred follow-on to the Phase 4 SQL foundation (`docs/superpowers/specs/2026-06-15-arc2-phase4-movement-trim-sql-design.md`). Adds: the **LTT label-dispatch path** (synchronous ZPL-to-Zebra over raw TCP, resolved from session), a small label-dispatch SQL delta (migration `0025`), the `onStartup` printer-resolution extension, the reusable **Movement Scan** component, the tabbed **Trim Station** view (IN/OUT), the **Receiving Dock** view, the Core Named Queries fronting the six Phase 4 procs, the Core entity-script modules, and the page-config routes. **No movement/trim SQL is authored here** — the Phase 4 SQL procs are the contracts; this layer is a thin, business-logic-free caller (FDS-13-002 / `feedback_no_business_logic_in_python`).

## 1. Source of truth

- **Phase 4 SQL spec** — the six procs wrapped here (`ItemLocation_CheckEligibility`, `Item_GetMaxParts`, `Lot_GetCellLineQuantity`, `Lot_GetWipQueueByLocation`, `Lot_MoveToValidated`, `TrimOut_Record`) + the decision that enforcement is server-side (this layer surfaces, never re-enforces).
- **Phased plan** — `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` § "Phase 4" (the `LttZplDispatcher`, Movement Scan, Trim, Receiving narratives + the Perspective-view + gateway tables).
- **FDS** — **FDS-02-009** (destination by scan/dropdown), **FDS-02-012** (eligibility reject message), **FDS-02-013** (tablet form factor — ≥44px targets, portrait), **FDS-05-004 / FRS 5.6.1** (Receiving pass-through), **FDS-03-017a** (checkpoint shape), **FDS-01-014** (interface-call logging to `Audit.InterfaceLog` — see §4 deviation note), **FDS-05-038** (Paused-LOT indicator, reused).
- **Shipped reference impls** this spec mirrors: `Components/PlantFloor/CellContextSelector` (scan + dropdown + page-scoped reply), `InitialsField` / `ElevationModal` (attribution + AD elevation), `PausedLotIndicator`; the Phase 1 `onStartup` (terminal resolution into `session.custom.terminal.*`); the Phase 3 front-end spec (structure, tab-shell, dynamic-field rendering). Pack files `02`/`03`/`04`/`06`/`07`.

## 2. Reconciliation to shipped resources (reuse, not rebuild)

- **Procs:** the six Phase 4 procs + Phase 2/3 `Lot_Get`, `Lot_Create`, `Lot_Update`, `ProductionEvent_Record`, `RejectEvent_Record`, `LotLabel_Print`, `LotLabel_Reprint`, `Lot_AssertNotBlocked`. The **`LotLabel_Print`/`Reprint` already render ZPL SQL-side and return `ZplContent`**, inserting `PrinterName` NULL — explicitly deferred to "the B17 gateway dispatcher" (this spec).
- **Audit:** `Audit.InterfaceLog` table + the existing **`Audit.Audit_LogInterfaceCall`** writer proc (columns `Direction`, `LogEventTypeId`, `RequestPayload`, `ResponsePayload`, `ErrorCondition`, `ErrorDescription`). The dispatch logs through this — **no new logging proc**.
- **Printer model:** `Printer` LocationTypeDefinition (DefId 16, Cell-kind, child of a Terminal) with `Endpoint` (required, "IP:port or print-queue name") + `Model` `LocationAttribute`s — **already seeded** (`011_seed_locations_mpp_plant.sql`). Every real terminal carries ≥1 child Printer (the `HasPrinter` registry flag from the terminal-mode redesign); `FALLBACK-TERMINAL` is the no-printer exception.
- **Startup:** `ignition/projects/MPP/.../startup/onStartup.py` already resolves `Terminal_GetByIpAddress` → `session.custom.terminal.*` and declares the session shape — extended here (§5).
- **Components:** `CellContextSelector`, `InitialsField`, `ElevationModal`, `PausedLotIndicator` embedded unchanged.

Net-new: 1 small SQL migration (`0025`), 1 `onStartup` extension, 3 view trees (+ row sub-views), ~9 Core NQs, ~4 Core entity modules, page-config routes + HomeRouter tiles.

## 3. Label-dispatch architecture (synchronous — the design call)

The operator is **physically gated** on holding the printed LTT, so dispatch is **synchronous**, not the phased plan's async "gateway message handler" (deviation noted in §11). Because Perspective scripts run in gateway scope, the socket write happens inline in the entity method — **no `system.util.sendMessage` handler**.

**Flow (`BlueRidge.Lots.LotLabel.print(data, appUserId, terminalLocationId)`, Core):**
1. `EXEC Lots.LotLabel_Print … @PrinterName = <session printer code>` → returns `{Status, Message, NewId (LotLabelId), ZplContent}`.
2. Resolve the target from **`session.custom.printer`** (resolved at startup, §5): `endpoint` (IP:port). **Validate populated** — empty → return a clear `{Status:0, Message:"This terminal has no printer configured."}` (your fail-fast guard); the LOT still exists, nothing is undone.
3. **Synchronous dispatch** via the helper `_dispatchZpl(endpoint, zpl)` (§4.2): `java.net.Socket` to `host:port` (default `9100`), **bounded 3–5 s connect + write timeout**, write the ZPL bytes (UTF-8/ASCII), close.
4. **Log the call to `Audit.InterfaceLog`** via `Audit_LogInterfaceCall` — `Direction='Outbound'`, event `LabelDispatched`, `RequestPayload` = endpoint + ZPL head, `ResponsePayload`/`ErrorCondition`/`ErrorDescription` = the socket outcome. **Logged on every attempt — success, failure, and each retry.**
5. **On success** → `EXEC Lots.LotLabel_RecordDispatch @LotLabelId, @PrinterName` (ack write-back: sets `PrinterName` + new `DispatchedAt`); return `{Status:1, …}`.
6. **On failure** → optional single **re-resolve of the endpoint from the DB** (covers a mid-session `Endpoint` attribute change / stale session value), retry once, log that attempt; if still failing, return `{Status:0, Message:<reason>}`.

**UI consequence:** a print failure does **NOT** roll back the LOT (mint and print are separate steps). The screen holds on the failed-print state, toasts the reason, and offers **Reprint** (re-fires `LotLabel_Reprint` → the same dispatch path, also logged). "Cannot move forward without the print" is enforced at the UI, not by undoing data.

## 4. Net-new SQL delta — migration `0025_arc2_phase4_label_dispatch.sql`

Small, label-dispatch-coupled (kept out of the movement/trim `0024` per the Spec-1/Spec-2 split). Versioned, `SchemaVersion` row, idempotent, ASCII-only.

1. **ALTER `Lots.LotLabel` ADD `DispatchedAt DATETIME2(3) NULL`** — the dispatch-ack timestamp (distinct from `PrintedAt`, which is set at render time).
2. **`@PrinterName NVARCHAR(100) = NULL` param** added to `LotLabel_Print` **and** `LotLabel_Reprint` (the deferred param the proc headers already flag); persisted into the existing `LotLabel.PrinterName` column.
3. **`Lots.LotLabel_RecordDispatch @LotLabelId BIGINT, @PrinterName NVARCHAR(100)`** → `Status, Message`. Sets `PrinterName` + `DispatchedAt = SYSUTCDATETIME()` on the row. Status-row proc; NQ `type:"Query"`.
4. **Seed `Audit.LogEventType` `LabelDispatched`** (next free Id after Phase 4 `0024`'s 35 → **36**) for the `InterfaceLog` rows. (Endpoint resolution needs **no** new proc — it reads existing `LocationAttribute`s, §5.)

> ⚠️ **Migration-number coordination (resolved 2026-06-16):** Phase 3 SQL-deltas = `0023`; Spec 1 (movement/trim) = `0024`; this (label dispatch) = `0025`. The Phase 5 plan also earmarked `0024` for Machining — Phase 5 renumbers to `0026+` (it is later and unbuilt).

### 4.2 The socket helper (`BlueRidge.Lots.LotLabel._dispatchZpl`, Core)
Pure transport, no business logic: `Socket()` with `connect((host, port), timeout)`, `getOutputStream().write(zpl.getBytes("US-ASCII"))`, `flush()`, `close()`; returns `{ok, error}`. Parses `host:port` from the `Endpoint` string (default port 9100). **Assumption made explicit:** raw TCP only reaches **networked** printers (Ethernet/WiFi ZebraNet print server — the GX420d `GX42-202410-000` Ethernet variant). A USB-only printer on an operator tablet is unreachable from a server-side socket and is out of this model (would need client-side printing — not in scope).

## 5. `onStartup` extension — resolve the printer into session

Extend the existing terminal resolution: after `session.custom.terminal` is set, resolve the terminal's child Printer Location + its `Endpoint`/`Model` `LocationAttribute`s (via `BlueRidge.Location.Terminal.getPrinter(terminalLocationId)` reading existing LocationAttribute procs) into a **declared** `session.custom.printer = {locationId, code, endpoint, model}` (shape declared in `session-props/props.json`; empty dict when `HasPrinter` is false). One resolution per session; the dispatch reads it (§3 step 2). No per-print DB round-trip.

## 6. Front-end views (MPP)

All under `BlueRidge/Views/ShopFloor/...`; flex-repeater ROW sub-views under `Components/PlantFloor/<Page>/<Row>` (never nested in a page-view folder). `meta.name:"root"`; every binding-read `view.custom.*` prop pre-declared with a shaped default; ≥44px targets, portrait (FDS-02-013); no drag-and-drop.

**Scan-or-dropdown inputs (FDS-02-009) = one `ia.input.dropdown` with `allowCustomOptions: true`.** Where the plan says "scan **or** dropdown," do NOT pair a separate scan field with a picker — use a single dropdown with `props.allowCustomOptions: true` + `props.search.enabled: true`. A barcode scanner types into the search box and the value either matches a listed option or is accepted as a typed/scanned custom entry; the `onActionPerformed` handler resolves it (option Id, or the raw scanned string passed to the resolving entity call). This unifies the two input modes in one component. Applies to the **Trim OUT destination selector** (§6.2) and the **Receiving PartNumber** field (§6.3).

### 6.1 Movement Scan — reusable embedded component (`Components/PlantFloor/MovementScan`) — MVP
Host passes `params` (`replyMessage`, `destinationLocationId`); component owns its scan + validation cycle and returns the outcome by page-scoped message (mirrors `CellContextSelector`). Cycle: LTT scan/entry → `Lot.getByName` → `ItemLocation.checkEligibility(itemId, destinationLocationId)` (gate; render FDS-02-012 message on miss) → `Item.getMaxParts` + `Lot.getCellLineQuantity` (show "N of M capacity") → **`Lot.moveToValidated`** commit (server re-checks; surface its `Message`). Embedded in any receive station.

### 6.2 Trim Station — one tabbed top-level view (`Views/ShopFloor/TrimStation`) — MVP
Your call: a single view with an **`ia.container.tab`** shell (IN / OUT), sharing the scanned-LOT context on `view.custom.activeLotId` (`tab-strip`/`tab-item`/`tab-item-active` style slots per `feedback_ignition_tab_container_slots`). Header: `InitialsField` + `PausedLotIndicator` (bound to the Trim Area).
- **IN tab** — `MovementScan` embed (destination = Trim Shop **Area**) → on move, `ProductionEvent.record` (`TrimIn` template, carried-forward cumulative counters) → optional `RejectEvent.record` (scrap/yield loss) + optional `Lot.update` (weight-based piece correction, FRS 2.2.3). Trim is yield-loss only — no rename, no genealogy.
- **OUT tab** — single destination selector: one `ia.input.dropdown` with `allowCustomOptions: true` (scan **or** pick, FDS-02-009) → `TrimOut.record(parentLotId, TrimOutTemplateId, shotCount, scrapCount, destinationCellLocationId, …)` (whole-LOT move into the Machining FIFO queue). No split/multi-destination UX (that's Phase 5).
After submit, navigate to the Phase 2 `LOT Detail`.

### 6.3 Receiving Dock (`Views/ShopFloor/ReceivingDock`) — MVP
`Lot.create` form, `LotOriginType='Received'`, `currentLocationId = session.custom.cell` (Receiving Dock): PartNumber (one `ia.input.dropdown` with `allowCustomOptions: true` — scan or pick, resolved via `Item.getByPartNumber`), VendorLotNumber, PieceCount (text-field + proc coercion), optional serial range (`MinSerialNumber`/`MaxSerialNumber`). On success → **print the LTT via `LotLabel.print` (§3)** → navigate to `LOT Detail`. No movement (creation, not move).

### 6.4 Row sub-views
`Components/PlantFloor/TrimStation/WipQueueRow` (if the OUT/destination picker lists queue entries) and any dynamic field rows reuse the Phase 3 `FieldInputRow` pattern. Receiving uses none.

## 7. Named Queries (Core)

Two groups, `parts/` (+ existing) and the label bits. Mutations `type:"Query"` (status-row; `UpdateQuery` would throw). **Gateway restart** to register new Core NQs (scan insufficient — `project_mpp_nq_core_topology`).

| NQ | Proc | type |
|---|---|---|
| `parts/ItemLocation_CheckEligibility` | `Parts.ItemLocation_CheckEligibility` | Query |
| `parts/Item_GetMaxParts` | `Parts.Item_GetMaxParts` | Query |
| `lots/Lot_GetCellLineQuantity` | `Lots.Lot_GetCellLineQuantity` | Query |
| `lots/Lot_GetWipQueueByLocation` | `Lots.Lot_GetWipQueueByLocation` | Query |
| `lots/Lot_MoveToValidated` | `Lots.Lot_MoveToValidated` | **Query** (mutation) |
| `workorder/TrimOut_Record` | `Workorder.TrimOut_Record` | **Query** (mutation) |
| `lots/LotLabel_Print` (update +`@PrinterName`) | `Lots.LotLabel_Print` | **Query** |
| `lots/LotLabel_Reprint` (update +`@PrinterName`) | `Lots.LotLabel_Reprint` | **Query** |
| `lots/LotLabel_RecordDispatch` | `Lots.LotLabel_RecordDispatch` | **Query** |

## 8. Entity scripts (Core)

Schema-aligned, thin (`Common.Db/Ui/Util`, `_u()` boundary unwrap, no `system.db.*`, no business logic):
- **`BlueRidge.Lots.Lot`** — add `moveToValidated(data)`, `getCellLineQuantity(locationId, itemId)`, `getWipQueueByLocation(locationId, includeDescendants=False)`, `getByName(lotName)` (if absent).
- **`BlueRidge.Parts.ItemLocation`** — `checkEligibility(itemId, locationId)` → `{IsEligible, Path}`; binding-safe `…OrEmpty` variant.
- **`BlueRidge.Parts.Item`** — add `getMaxParts(itemId)`.
- **`BlueRidge.Workorder.TrimOut`** — `record(data, appUserId, terminalLocationId)`.
- **`BlueRidge.Lots.LotLabel`** — `print(...)` (orchestrates proc → dispatch → log → ack, §3), `reprint(...)`, `_dispatchZpl(endpoint, zpl)` (§4.2), `_logDispatch(...)` (wraps `Audit_LogInterfaceCall`).
- **`BlueRidge.Location.Terminal`** — add `getPrinter(terminalLocationId)` for the startup resolution.

## 9. Routes (page-config)

Add under `/shop-floor/*` (each carries a `title`): `/shop-floor/trim` → `TrimStation`, `/shop-floor/receiving` → `ReceivingDock`. `MovementScan` is embedded, not routed. HomeRouter gains Trim / Receiving tiles, gated by the terminal's resolved context (no new session props beyond `session.custom.printer`).

## 10. Test / smoke plan

No front-end unit harness; the SQL suite (`0024` + the `0025` label-dispatch tests) is the automated gate. Add SQL tests for `LotLabel_RecordDispatch` (ack sets `DispatchedAt`/`PrinterName`) and the `@PrinterName` round-trip. **Smoke seed** `sql/scratch/smoke_seed_phase4.sql` (idempotent, prints LOT ids + URLs). Operator walkthrough:
1. Trim terminal → `/shop-floor/trim`; IN tab: scan a Phase-3 die-cast LOT → eligibility + capacity shown → move to Trim Area + `TrimIn` checkpoint; record a scrap reject.
2. OUT tab: pick a Machining-line destination → `TrimOut_Record` → LOT visible in that line's FIFO queue (Phase 2 `LOT Detail` / Phase 5 queue).
3. Receiving → create a `Received` LOT (vendor lot + serial range) → **LTT prints** to the terminal's Zebra; pull the cable / point `Endpoint` at a dead host → failure toast + Reprint; confirm an `Audit.InterfaceLog` row per attempt (success + failure + retry).
4. Confirm `notifyResult` toasts on every mutation; nothing writes except on explicit button; `session.custom.printer` populated at startup; empty-printer terminal yields the fail-fast message.

**Dispatch verification without hardware:** point `Endpoint` at a local socket listener (or Labelary for ZPL visual checks); real GX420d print is a deployment gate.

## 11. Design decisions (locked at review 2026-06-15)

- **Synchronous dispatch, not async** (deviates from the phased plan's "Gateway message handler"). The operator is gated on the physical LTT; fire-and-forget would let a silent failure pass. Inline socket write (gateway scope) + bounded timeout. FDS-01-014's async guidance targeted slow EDI/AIM calls; **logging intent is preserved** — every attempt logs to `Audit.InterfaceLog` synchronously.
- **Printer resolved into `session.custom.printer` at startup** (not per-print). Fail-fast on empty (no-printer terminal); optional single DB re-resolve on dispatch failure.
- **Print failure never rolls back the LOT.** Retry via the existing `LotLabel_Reprint`. UI holds + offers Reprint.
- **Label SQL delta lives in Spec 2 / migration `0025`** (gateway-coupled). Endpoint resolution = existing `LocationAttribute` reads (no new endpoint proc).
- **One tabbed Trim Station view** (IN/OUT), not two routes.
- **Raw TCP 9100 to networked printers only** — USB-attached client printers are out of scope.

## 12. Out of scope

Phase 5 Machining (FIFO pick / BOM rename / sub-LOT split); real-Zebra hardware certification (deployment gate); client-side/USB printing; receiving inspection + vendor-lot verification workflows (FUTURE); any movement/trim proc change (Spec 1 owns that SQL).
