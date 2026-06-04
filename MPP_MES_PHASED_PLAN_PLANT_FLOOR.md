# MPP MES — Phased Delivery Plan: Arc 2 (Plant Floor MES)

**Document ID:** MPP-PLAN-ARC2-v1.0
**Project:** Madison Precision Products MES Replacement
**Contractor:** Blue Ridge Automation
**Version:** 1.1 (2026-06-03)
**Status:** Working draft — full rebuild against current source-of-truth docs (FDS v0.11m, Data Model v1.9l, User Journeys v0.9, Open Issues Register v2.16, Seeding Registry v1.0). Supersedes the v0.1 → v0.3 line; the prior draft chain is retained in git history.

> **Reader note (v1.0):** This is a clean rebuild. Read top-to-bottom. Cross-Cutting Concerns (B1–B17) are normative for every phase. **Phase 0 has two parallel tracks** — MPP-owned customer validation and Blue Ridge–owned architecture decisions (OI-35) — both must complete before Phase 1 SQL build commences. Per-phase narratives reference current source-of-truth docs by version; updates to those docs propagate here at the next plan revision.

> **In-progress note (v1.0a, 2026-04-29):** This file currently contains Phases 0–4 of the rebuild. Phases 5–8 are placeholders awaiting review of the first half. The closing sections (Out of Scope, Open Items Affecting This Plan, Related Documents) will land with Phases 5–8.

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 1.1 | 2026-06-03 | Blue Ridge Automation | **Sub-LOT split relocated from Trim OUT to Machining OUT** (per MPP, confirmed 2026-06 — settled, not an open item). Reverses the v1.0 driver-(a) claim that the split sits at Trim OUT. Trim is now a **1:1 whole-LOT move tracked at Area resolution**; the `Parts.OperationTemplate.RequiresSubLotSplit` flag plus the split UX / `*_Record` split branch / split tests move from **Phase 4 (Trim, migration `0017`)** to **Phase 5 (Machining OUT, migration `0018`)**. Phase 4 Trim OUT becomes move-whole-only (`TrimOut_Record` no longer splits); Phase 5 Machining OUT gains an **operator-initiated split path on sublotting lines** (physical signature: a dedicated Machining OUT terminal) alongside the existing PLC auto-move on coupled lines. UJ-03 reframed (was closed backwards as "Machining no longer splits"). The Phase 4→5 ordering is unchanged but its nature shifts: a whole-LOT handoff into the Machining FIFO queue, not pre-split sub-LOTs. Mirrors **FDS v1.3**. **No schema change** — `Lot.ParentLotId` / `LotGenealogy` already model machining-origin sub-LOTs; the `RequiresSubLotSplit` column simply lands in `0018` instead of `0017`. |
| 1.0 | 2026-04-29 | Blue Ridge Automation | **Full rebuild against current source-of-truth docs.** Replaces the v0.1 → v0.3 line. Drivers: (a) the v0.11k/l/m FDS continuity passes shifted three workflow boundaries — sub-LOT split moved from Machining IN to **Trim OUT** (FDS-05-009), part-identity rename moved from Casting→Trim to **Trim→Machining** (FDS-05-033), Machining OUT became event-driven PLC-auto-complete + auto-move to coupled Cell (FDS-06-008); (b) container closure granularity moved from container-level to **tray-level** with three peer methods `ByCount` / `ByWeight` / `ByVision` (FDS-06-014); (c) end-of-shift time entry reframed as a single FDS-09-013 submission with shift-schedule durations (no minute adjustments); (d) OIR v2.16 added **OI-35** (long-horizon scaling + retention + archiving — gates Arc 2 Phase 1 SQL build); (e) OIR closures v2.10 → v2.16 retired ~14 prior gating items. Phase shape preserved (9 phases, 0–8); structural elements lifted verbatim (Cross-Cutting Concerns B1–B17, Architecture Pattern, Phase template, SP convention). Per-phase narratives rewritten from current source where FDS reframes hit; lifted with light touch-up where current. NEW section *Seeding Registry — Phase Coupling* maps S-01..S-11 to phases. Phase 0 expanded with the Architecture Decision track (OI-35 — 8 decisions). Phase 1 entry gated on **both** Phase 0 tracks; migration baked-in with the architectural decisions on day one. |

---

## Purpose

This document is the phased delivery plan for **Arc 2 (Plant Floor MES)** — the operator-facing portion of the MPP MES replacement. It is the sibling of `MPP_MES_PHASED_PLAN_CONFIG_TOOL.docx` (Arc 1), which is complete.

**Arc 1** built the Configuration Tool: the engineering-facing surface where plant, items, routes, BOMs, quality specs, and reference vocabularies (shifts, downtime codes, defect codes) are authored. Arc 1 delivered across eight phases, with 13 versioned migrations (`0001`–`0013`), ~216 repeatable stored procedures, and **858/858 passing tests** as of 2026-04-28.

**Arc 2** builds the Plant Floor MES: the operator-facing surface that runs against Arc 1's configured master data. Its audiences are **shop-floor operators, supervisors, quality staff, and shipping staff**, interacting through Ignition Perspective touch terminals, barcode scanners, and PLC-integrated production machinery. Arc 2 captures LOT lifecycle from die-cast origination through containerized shipment to Honda, with traceable genealogy at every step.

This plan has one explicit precondition: **Phase 0 must complete before Phase 1 implementation begins.** Phase 0 has two parallel tracks — an MPP-owned **Customer Validation Gate** that resolves design-time decisions whose wrong answer would force a phase rebuild, and a Blue Ridge–owned **Architecture Decision Workshop** (OI-35) that resolves long-horizon scaling decisions that must bake into the Phase 1 migration on day one.

---

## Architecture Pattern

Arc 1 used Ignition Named Queries calling stored procedures, with Perspective views as thin CRUD forms over the proc layer. Arc 2 builds on that architecture but adds two more layers, both first-class in this plan:

**Ignition Gateway Scripts.** Many plant-floor events originate outside Perspective sessions: PLC tags change, OmniServer scales publish values, timers tick at shift boundaries, and external systems (AIM, Zebra printers) expect direct calls. These live in Ignition Gateway scripts — long-running background scripts that watch OPC tags, poll queues, and issue HTTP/SOAP calls. Gateway scripts call stored procs for DB work; they never execute DML directly.

**PLC/OPC Touchpoints.** Plant-floor workflows tangle with assembly PLC handshakes (MIP), scales (OmniServer), and vision systems (Cognex). This plan describes PLC touchpoints **functionally** — what tag is read, what is written, what the handshake semantics are — but defers bit-level OPC addresses and register maps to `reference/5GO_AP4_Automation_Touchpoint_Agreement.pdf` and FRS Appendix C.

The three layers compose as:

```
  Perspective View (touch UI)
       │         │
       │ (Named Query)           (Named Query)
       ▼         ▼                      ▼
  Stored Proc (SQL)   ◀─── calls ───  Gateway Script (Python)
                                          │        │
                                          ▼        ▼
                                     OPC/PLC   AIM / Zebra / etc.
```

Stored procs remain the authoritative write path — no Gateway script or Perspective binding performs DML directly. Every external I/O (AIM HTTP, Zebra socket write, OPC tag write-back) is bracketed with `Audit.Audit_LogInterface` calls so the external conversation is reconstructible forever.

---

## Cross-Cutting Concerns

Arc 1's conventions carry forward unchanged and apply to every Arc 2 proc. They are not repeated here; see `MPP_MES_PHASED_PLAN_CONFIG_TOOL.docx` § Cross-Cutting Concerns. In summary: audit streams (ConfigLog, OperationLog, InterfaceLog, FailureLog), code-table-backed status everywhere, soft-delete via `DeprecatedAt` (never hard DELETE except where explicitly documented — `BomLine`, `RouteStep`), optimistic locking via `@RowVersion` on Update, `SortOrder` + `_MoveUp`/`_MoveDown` instead of drag-drop, BIGINT/NVARCHAR everywhere, single result set per proc (no OUTPUT parameters), `RAISERROR` in nested CATCH blocks (not `THROW`), user attribution via `@AppUserId BIGINT`.

Arc 2 adds the following seventeen conventions. These are normative for every phase of this plan.

### B1 — Operator session context binding

Every Arc 2 mutation proc accepts both `@AppUserId BIGINT` and `@TerminalLocationId BIGINT` as required parameters. Procs validate both exist and are active (AppUser not deprecated, Terminal Location not deprecated, Location of type `Terminal`). On any rejection, `Audit.FailureLog` captures both values along with the attempted parameters.

Session lifecycle (inactivity timeout, re-auth for high-security actions, logout) is **enforced at the Ignition Perspective layer**, not in procs. Procs treat every call as equally authoritative; Perspective is responsible for ensuring the caller is authenticated and the session has not expired.

### B2 — `BlocksProduction` interlock discipline

Any proc that advances a LOT through the process — `Lot_MoveTo`, `ProductionEvent_Record`, `ConsumptionEvent_Record`, `Lot_Split`, `Lot_Merge`, `ContainerSerial_Add`, `Container_Create` — first calls the shared guard `Lots.Lot_AssertNotBlocked(@LotId)`. The guard reads `Lot.LotStatusId → LotStatusCode.BlocksProduction`. Any status with `BlocksProduction=1` (Hold, Scrap, Closed) trips the guard. A tripped guard is a **business rule violation**, not an exception: the caller receives `Status=0, Message='LOT MESL1710935 is in status Hold and cannot progress'`, the attempt is logged to FailureLog, and no partial writes occur.

The guard is delivered in Phase 1 (as part of the LOT core skeleton) and reused across all downstream phases.

### B3 — Open-event invariant

`Oee.DowntimeEvent` and `Quality.HoldEvent` both carry nullable `EndedAt` / `ReleasedAt` columns. The invariant: **at most one open event per resource at any time**. For `DowntimeEvent`, the resource is the machine `Location`; for `HoldEvent`, the resource is the `Lot` (or the optional `NonConformance`); for `Lots.PauseEvent`, the resource is the `(LotId, LocationId)` pair. `_Start` / `_Place` / `_Pause` procs enforce the invariant with an explicit pre-check:

```sql
IF EXISTS (SELECT 1 FROM Oee.DowntimeEvent
           WHERE LocationId = @LocationId AND EndedAt IS NULL)
BEGIN
    SET @Status = 0;
    SET @Message = CONCAT('Machine ', @LocationName, ' already has an open downtime event');
    -- log failure, return
END
```

Attempting a second open event is a business rule violation, not an exception. `_End` / `_Release` / `_Resume` procs reject if no open event exists.

### B4 — Gateway script layer contract

Gateway scripts call stored procs the same way Perspective views do — through parameterized Named Queries. Gateway scripts **MUST NOT** execute raw DML via `system.db.runUpdateQuery` or inline SQL. External I/O (AIM HTTP/SOAP, Zebra printer socket writes, OPC read/write via TOPServer or OmniServer) happens **only** in Gateway scripts; stored procs never reach outside the database.

**Trigger pattern (FDS-01-014 / UJ-18 — Gateway-script-async):** all external integrations are dispatched via `system.util.sendMessage` (fire-and-forget) or `system.util.sendRequestAsync` (when the caller needs error surfacing — print path, AIM Hold/Update). The Perspective view (or the MES proc, when proc-driven) fires the message; a Gateway-scoped message handler performs the external call. Sync direct-call from inside an MES proc is retired for **external** systems — sync remains the model for inter-MES DB calls only. The async dispatch decouples MES correctness from external availability and makes failures observable, retryable, and logged without operator-blocking. Note: `system.util.sendMessageAsync` is not a real Ignition API — pick `sendMessage` vs `sendRequestAsync` per caller need.

**Audit trail.** Every external call is bracketed by `Audit.Audit_LogInterface` writes — one when the request fires (Direction='Outbound', RequestPayload populated, ResponsePayload NULL), one when the response or error returns (update the same row). Critical failures additionally log to `Audit.FailureLog`. The OI-01 "no outbox" decision still stands — there is no separate outbox table; the message-handler pattern delivers async semantics without a DB queue.

**Special case — pre-fetched buffers.** When zero operator-perceived latency is required (`Container_Complete` → AIM Shipper ID assignment per UJ-04), a pre-fetched local buffer (`Lots.AimShipperIdPool`, FDS-07-010) replaces the dispatch model: the MES proc consumes locally; the buffer's topup loop runs as a Gateway-script-async. Empty pool = hard fail (FDS-07-010a — pending OI-33 customer validation).

**Special case — print failure surfacing.** Print attempts retry inline within the message handler (3 × 2s gap for shipping labels per FDS-07-006a). On exhaustion, DB state (`PrintFailedAt`, `BannerAcknowledgedAt`) drives a per-terminal banner via Gateway-broadcast-with-session-filter (FDS-07-006b) — one DB query per 5s regardless of terminal count; session-side filter is a cheap branch. A low-frequency safety-sweep timer (~5 min) recovers orphans (Gateway restart between proc commit and message dispatch) and alarms on stranded-prints count > 5.

### B5 — PLC descriptive boundary

Phase narratives describe what Gateway scripts read from and write to PLC tags in prose: tag names (e.g., `PartSN`, `PartValid`, `DataReady`, `HardwareInterlockEnable`, `CycleComplete`, `OperationComplete`, `CompletionConfirmed`, `TrayFullFlag`), semantics (edge-triggered vs. level-triggered), and handshake steps. **Bit-level OPC addresses, data types, register numbers, and PLC ladder logic stay out of this plan.** They live in `reference/5GO_AP4_Automation_Touchpoint_Agreement.pdf` and FRS Appendix C. Gateway script implementation references those documents; the plan references them by path.

### B6 — Print job contract

ZPL generation for labels (LTT, shipping label, master label) is assembled in Gateway scripts from a template file plus data returned by the originating stored proc. The stored proc (`LotLabel_Print`, `ShippingLabel_Print`, etc.) writes the audit row with the full rendered `ZplContent` and returns its Id; the Gateway script reads the Id, dispatches the ZPL content to the physical Zebra printer (via socket), and records the print acknowledgement back on the same row (not via a second insert). Void labels use `IsVoid=1` + `VoidedAt` + `VoidedByUserId`; rows are never deleted.

### B7 — Late-binding reason codes

`Oee.DowntimeEvent.DowntimeReasonCodeId` is **nullable**. When a PLC detects a machine stop before an operator classifies it, `DowntimeEvent_Start` inserts the row with NULL reason. `DowntimeEvent_End` succeeds with a NULL reason. Unclassified downtime is flagged on the shift-supervisor dashboard and on shift-end reporting — it is not blocked at proc level. A separate `DowntimeReasonCode_Assign` proc fills the reason later; it refuses to overwrite an already-assigned reason (supervisors must correct by other means).

### B8 — Genealogy traversal

`Lots.Lot_GetGenealogyTree(@LotId, @Direction)` uses a recursive CTE with `OPTION (MAXRECURSION 100)`. The `@Direction` parameter takes `'Ancestors'` (walk ParentLot → ParentLot → ...) or `'Descendants'` (walk children via `LotGenealogy`). Tree depth beyond 100 hops is a business rule violation with the message `genealogy tree exceeds supported depth of 100`. Real plant genealogy never approaches this bound; the cap is a defensive recursion guard. **Note (OI-35 / Phase 0 architecture):** if the architecture review elects to add a materialized closure table, this CTE traversal becomes a fallback and the closure table is the canonical query path — see Phase 1 Data Model Changes for the conditional schema.

### B9 — Test pattern extension for open-state events

Arc 1's test pattern covered mutations with a temp-table capture of the result shape (`Status / Message / NewId`). Arc 2 extends this for open-state events: after `_Start` / `_Place` / `_Pause`, tests assert `EndedAt IS NULL` (or `ReleasedAt IS NULL` / `ResumedAt IS NULL`) directly against the underlying table:

```sql
DECLARE @OpenCount INT;
SELECT @OpenCount = COUNT(*)
FROM Oee.DowntimeEvent
WHERE LocationId = @LocationId AND EndedAt IS NULL;
IF @OpenCount <> 1
    RAISERROR('Expected exactly 1 open DowntimeEvent, got %d', 16, 1, @OpenCount);
```

After `_End` / `_Release` / `_Resume`, tests assert the same row's terminal column `IS NOT NULL`.

### B10 — Serial number migration audit

UJ-05 default direction (committed 2026-04-27): **update-in-place + new `Lots.ContainerSerialHistory` table** capturing each migration event. Awaits MPP Quality + Honda compliance affirmation before final lock; if MPP rejects update-in-place, the convention reverts to void-and-recreate with no history table. Schema delivers in Phase 7 alongside the rest of the Sort Cage workflow. Until UJ-05 closes definitively, Phase 7 builds against the default direction with the procs structured so a void-and-recreate flip can swap in without a migration rebuild.

### B11 — Zone-based default screen routing

On Perspective session startup, the client IP resolves to a Terminal-type `Location` row by querying its existing `IpAddress` `LocationAttribute`. The Terminal's zone (parent Area in the `Location` hierarchy) plus a `DefaultScreen` `LocationAttributeDefinition` on the `Terminal` `LocationTypeDefinition` drives the initial Perspective view shown to any operator who logs in at that station.

A Trim Shop terminal opens to the Trim Station Screen; a Shipping Dock terminal opens to the Shipping Screen; a Die Cast terminal opens to the Die Cast LOT Entry Screen. Operator presence (initials) is orthogonal — the default-screen lookup happens on session start, before any initials entry or per-action elevation.

The `DefaultScreen` attribute is seeded as a new `LocationAttributeDefinition` row on the `Terminal` `LocationTypeDefinition` (via migration or via the existing Arc 1 Config Tool). Phase 1 delivers `Location.Terminal_GetByIpAddress` and the `Terminal_ResolveFromSession` Gateway script that stashes Zone + DefaultScreen in session props for the Home router view to consume.

### B12 — Purpose-built top-level views, polymorphic embedded components

**Top-level views are purpose-built per workflow.** No generic dashboard-configuration engine. One view per terminal function (Die Cast LOT Entry, Trim Station, Machining IN, Sort Cage Workflow, Shipping Dock, Hold Management, etc.); B11 routing picks by Terminal Location. **LocationAttribute is for business policies only**, never UI configuration. Flexware's `*DashboardConfiguration` family (`LotTrackingDashboardConfiguration`, `LotCreateDashboardConfiguration`, `WorkOrderDashboardConfiguration`, `FinalAssemblyDashboardConfiguration`, `CreateAllocationDashboardConfiguration`, `SortDashboardConfiguration`, `MaterialLabelPrintDashboardConfiguration`, `WorkstationDashboardConfiguration`) is **NOT reproduced**. If two top-level views need different populate behavior, they are different views — not a configurable flag.

**Polymorphism lives at the embedded-component level — Flex Repeater + Embedded View is the canonical pattern.** Anywhere a view needs to handle N similar items (1 ≤ N ≤ many), the result set is bound to a Flex Repeater whose embedded view is the polymorphic unit. Examples: a destination picker repeater that renders N pickers when a machined LOT splits into N sub-LOTs at Machining OUT — same UI, same submit handler, count driven by the result set. Other natural Flex Repeater + Embedded View patterns: LOT history rows on the LOT Detail view, ancestor/descendant cards on the Genealogy Viewer, hold-row cards on Hold Management, container cards on the Sort Cage workflow, paused-LOT detail rows on the Paused-LOT indicator's tap-through list.

**Naturally-parametric top-level views.** Some top-level views are inherently polymorphic by data-binding rather than by Flex Repeater composition: `LOT Detail` (one view, takes `@LotId`, conditionally renders Tool/Cavity rows when populated), `LOT Search` (one view, filter-driven), `Genealogy Viewer` (one view, takes `@LotId`). These do **not** get per-station variants. There is no "Die Cast LOT Detail" or "Trim LOT Detail" or "Machining LOT Detail" — there is one `LOT Detail` that adapts to whatever the LOT carries.

**Cross-cutting embedded components** (used across phases without modification): Per-Mutation Initials Field, Elevation Modal (per-action AD), Paused-LOT Indicator + tap-through detail list, Movement Scan, Cell Context Selector (Shared terminals), Confirmation Method Resolver (reads `ConfirmationMethod` LocationAttribute → renders Vision / Barcode / Both UX). These are inventoried per phase but their implementations live once and are reused.

### B13 — Tool/Cavity system of record

`Tool` and `Cavity` live on `Lots.Lot` (`ToolId`, `ToolCavityId` FKs, Data Model v1.9). They are **never duplicated** on `Workorder.ProductionEvent`, `Workorder.ConsumptionEvent`, or any derived LOT created via consumption / sub-LOT split. Honda-trace queries walk `Lots.LotGenealogy` (or the OI-35 closure table, if Phase 0 architecture review elects it) to the origin LOT and read Tool/Cavity from there. Downstream (Trim, Machining, Assembly) LOTs carry `ToolId = NULL` and `ToolCavityId = NULL`.

### B14 — Checkpoint-shape events

`Workorder.ProductionEvent` is a **checkpoint table** — each row carries cumulative `ShotCount` / `ScrapCount` as-of-the-checkpoint. Deltas are derived by readers via `LAG()` over `(LotId, EventAt)`. **No** per-event `GoodCount` / `NoGoodCount`. **No** `StartedAt` / `EndedAt`. **No** `LocationId` / `ItemId` / `DieIdentifier` / `CavityNumber` (all derivable from `Lot.ToolId` / `Lot.ToolCavityId` + `LotMovement` + `Lot.ItemId`). A missed checkpoint doesn't compound errors — the next event carries truth.

### B15 — Identifier minting via `IdentifierSequence_Next`

All MPP-internal identifier minting (LOT LTT barcodes, SerializedItem IDs, future non-AIM counters) goes through `Lots.IdentifierSequence_Next @Code`. **No ad-hoc identifier generation anywhere.** The `Lots.IdentifierSequence` table seeds at cutover from Flexware live counter values (S-10 in the Seeding Registry; OI-31 for the format-carry-forward + reset-policy questions). AIM Shipper IDs are a separate concern (Honda-issued via `AIM.GetNextNumber`, pooled locally per UJ-04).

**Note (OI-35 / Phase 0 architecture):** the implementation is row-locked-update by default; if Phase 0 architecture review elects SQL Server `SEQUENCE` object instead, the proc wraps the sequence with a format-string function and the underlying mechanism changes — Phase 1 honors the decided approach.

### B16 — Lazy LOT creation

LOT creation is operator-driven, not auto-triggered at any prescribed moment. `Lots.Lot_Create` fires whenever the operator decides — basket-full, before starting the next LOT, etc. The MES **does not auto-create N LOTs at run start**. Phase 3 UI and procs **must not require** a `Lot` row to exist for an in-progress cavity; physical-but-unlogged baskets are normal. Tool + Cavity assignment happens at `Lot_Create` time (FDS-05-034 / FDS-05-036).

### B17 — Gateway-script-async external integrations (FDS-01-014, UJ-18)

All MES outbound calls to external systems (AIM, Zebra printers, Honda EDI, future Macola pushes) use the Gateway-script-async pattern. Perspective views fire `system.util.sendMessage` or `system.util.sendRequestAsync` to a Gateway-scoped message handler with the relevant entity ID(s) as payload; the handler performs the external call. Failures retry inline within the handler (e.g., 3 attempts × 2s gap for shipping labels per FDS-07-006a) and ultimately write `Audit.FailureLog` if exhausted. Operator-facing failure surfaces (per-terminal banners, wallboard alarms) bind to **DB state** — not in-flight handler state — so Gateway restarts don't lose visibility. Sync direct-call from inside MES procs is retired for **external** systems; sync remains for inter-MES DB calls. Pre-fetched buffers (`Lots.AimShipperIdPool` per UJ-04) are the special case where zero operator-perceived latency is required.

---

## Stored Procedure Template and Conventions

Arc 2 procs follow the same template, error hierarchy, audit placement rules, and code-review checklist defined in `MPP_MES_PHASED_PLAN_CONFIG_TOOL.docx` § Stored Procedure Template and Conventions. The template is reproduced in full there; it is not duplicated here. Cited fresh reminders:

- Three-tier error hierarchy (parameter validation → business rule → unexpected exception)
- `SET NOCOUNT ON; SET XACT_ABORT ON;` at top of every mutation proc
- Parameter validation and business-rule checks **before** `BEGIN TRANSACTION`; only the mutation wrapped in transaction
- Success audit call (`Audit.Audit_LogOperation` for Arc 2 plant-floor procs) **inside** the transaction, before `COMMIT`
- Failure audit call (`Audit.Audit_LogFailure`) outside transactions, in a nested TRY/CATCH around the failure-log insert so a failed audit-write cannot interfere with the primary rollback
- Final `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];` on every exit path (no OUTPUT parameters — FDS-11-011)
- `RAISERROR` not `THROW` in nested CATCH blocks
- All DB references schema-qualified (`Lots.Lot`, `Audit.Audit_LogOperation`)

One Arc 2 divergence: the primary audit sink for mutation procs is **`Audit.OperationLog`** (via `Audit.Audit_LogOperation`), not `Audit.ConfigLog` (via `Audit.Audit_LogConfigChange`). This is the core distinction between the two arcs. Config Tool mutations describe engineering-authored rules; Plant Floor mutations describe operator-observed events. The two audit streams are read by different supervisory queries.

**Note (OI-35 / Phase 0 architecture):** if the architecture review elects to split `OperationLog` into a 7-year retention general audit and a separate 20-year `Lots.LotEventLog` for traceability events, Arc 2 procs use `Lots.LotEventLog` for LOT-event mutations and `Audit.OperationLog` for everything else. The proc layer abstracts the destination; callers don't change.

---

## Seeding Registry — Phase Coupling

The Seeding Registry (`MPP_MES_SEEDING_REGISTRY.docx` v1.0) tracks 11 external-data items (S-01 through S-11) sourced from MPP IT, MPP Quality, MPP Engineering, Honda, and vendors. These are **deployment-time data dependencies, not build blockers** — the schema CREATEs in the appropriate phase regardless of seed-data delivery status. Only S-08 (DieRankCompatibility) is a true blocker, and it carries a supervisor-override workaround so Phase 2 can ship without it. The table below maps each S-item to the phase that consumes it.

| ID | Item | Owner | Phase | Status (2026-04-29) | Notes |
|---|---|---|---|---|---|
| **S-01** | Plant equipment master (Machines, ~209 rows) | MPP Engineering | Phase 1 (Location seed) | 🟡 Received — needs DC/MS/TS→Area mapping | CSV at `reference/seed_data/machines.csv`; loaded into `Location.Location` rows via Phase 1 dev-seed once mapping locks. |
| **S-02** | Downtime reason codes (~353 rows) | MPP Engineering | Phase 8 (`Oee.DowntimeReasonCode` bulk load) | 🟡 Received — needs DC/MS/TS→Area mapping | Bulk-load proc `Oee.DowntimeReasonCode_BulkLoadFromSeed` shipped Phase 8 of Arc 1; awaits MPP-confirmed Area mapping to invoke against the 353-row CSV. |
| **S-03** | Defect codes (~153 rows) | MPP Quality | Phase 6 (Quality.DefectCode), Phase 8 (per-Area filtering) | 🟡 Received — needs Area mapping | CSV at `reference/seed_data/defect_codes.csv`. |
| **S-04** | OPC tag catalog (~161 rows) | MPP Engineering | Phase 6 + Phase 7 (PLC integration design) | 🟡 Received — endpoint validation pending | CSV at `reference/seed_data/opc_tags.csv`; informs Gateway script tag bindings. |
| **S-05** | Parts master list | MPP IT | Phase 1 (`Parts.Item` bulk load) | ⬜ Owed | Format TBD; bulk-load proc skeleton lands in Phase 1 once MPP confirms export shape. |
| **S-06** | Flexware BOM export (formerly OI-13) | MPP IT | Phase 4 + Phase 6 (`Parts.Bom` + `BomLine` seed) | ⬜ Owed | One-shot pull at cutover; refreshed at deployment. |
| **S-07** | Die rank list | MPP Quality | Phase 1 (`Tools.DieRank` code table) | ⬜ Owed | Empty seed ships in Phase G; populated from MPP Quality input before Phase 2 merge tests run. |
| **S-08** | Die rank compatibility matrix | MPP Quality | Phase 2 (`Tools.DieRankCompatibility` — gates `Lot_Merge` cross-die rules) | ⬜ Owed — **TRUE BLOCKER (with override)** | Empty seed; merge proc rejects cross-die merges until populated, **supervisor override unblocks edge cases per FDS-04-007** (so the build is not gated, just the operational path). |
| **S-09** | Label-type seed validation | MPP Shipping | Phase 6 (LotLabel) + Phase 7 (ShippingLabel) | ⬜ Owed | Phase 0 walkthrough confirms the Flexware 3-template inventory (CONTAINER / LOT / CONTAINER_HOLD) plus any additions (Sort Cage, Hold, Void). |
| **S-10** | Identifier sequence baselines | MPP IT | Phase 1 (`Lots.IdentifierSequence` cutover seed) | ⬜ Owed (cutover-only) | Two counters: `Lot` (`MESL{0:D7}`, ~1,710,932 baseline) and `SerializedItem` (`MESI{0:D7}`, ~2,492 baseline). Sampled values drift; final values pulled at cutover day. Couples to **OI-31** (format carry-forward + rollover policy questions, gated in Phase 0). |
| **S-11** | AIM pool config tuning | MPP post-deploy | Phase 7 (`Lots.AimPoolConfig`) | 🟡 Defaults seeded | `TargetBufferDepth=50`, `TopupThreshold=30`, `AlarmWarningDepth=20`, `AlarmCriticalDepth=10`. Configuration Tool surfaces these for tuning post-deploy. |

**Status legend:** ⬜ Owed | 🟡 Received (needs prep / mapping) | ✅ Loaded (Dev) | 🔵 Verified (Cutover).

Per-phase narratives reference these S-items where relevant; this table is the canonical index. Updates flow into the Seeding Registry first, then into this table at the next plan revision.

---

## Phase Map and Dependencies

```
Phase 0 (Customer Validation Gate + Architecture Decision Workshop — parallel tracks)
    │
    ▼
Phase 1 (Foundation) ──────────────────────────────────▶ Phase 8 (Downtime + Shift)  [parallel]
    │
    ▼
Phase 2 (LOT lifecycle)
    │
    ▼
Phase 3 (Die Cast) ───────────────────────────┐
    │                                          │
    ├──────────────▶ Phase 4 (Move + Trim + Rx — whole-LOT move out)
    │                          │               │
    │                          ▼               │
    │                    Phase 5 (Machining: FIFO Pick + Rename + Sub-LOT Split / PLC Auto-Complete at OUT)
    │                          │               │
    │                          ▼               │
    │                    Phase 6 (Assembly + MIP + Container Pack — tray-level closure)
    │                          │               │
    │                          ▼               │
    └──────────────▶    Phase 7 (Hold + Sort Cage + Shipping + AIM)
```

**Direct dependency table:**

| Phase | Directly depends on | Unblocks |
|---|---|---|
| 0 | — | 1 |
| 1 | 0 (both tracks) | 2, 8 |
| 2 | 1 | 3 |
| 3 | 1, 2 | 4, 7 |
| 4 | 1, 2, 3 | 5 |
| 5 | 1, 2, 3, 4 | 6 |
| 6 | 1, 2, 3, 4, 5 | 7 |
| 7 | 1, 2, 3, 6 | — |
| 8 | 1 | — (parallel track) |

Phase 8 runs in parallel to Phases 2–7 as soon as Phase 1 lands. Phase 4 and Phase 5 can no longer parallelize — Phase 5 consumes the whole LOTs that Phase 4's Trim OUT deposits into the Machining FIFO queue (the sub-LOT split itself is now internal to Phase 5, at Machining OUT). A small team can still parallelize by running 8 alongside 2 + 3.

**Note on Phase 0 parallel tracks.** The Customer Validation Gate (MPP-owned) and the Architecture Decision Workshop (Blue Ridge–owned) are independent — they MAY run on different days with different stakeholders. Both must complete before Phase 1 commences. Customer validation outputs feed Phase 1's seed data and column lists; architecture decisions feed Phase 1's migration shape (partition functions, closure tables, etc.).

---

# Phase 0 — Customer Validation Gate + Architecture Decision Workshop

**Goal:** Resolve two classes of decisions whose wrong answer would force a phase rebuild in Arc 2: (a) MPP-owned design choices about workflow, retention, label scope, and rollout shape; (b) Blue Ridge–owned architectural decisions about long-horizon scaling, retention, and archiving (OI-35) that must bake into the Phase 1 migration on day one.

**Dependencies:** None. Phase 0 blocks Phase 1 implementation but can run in parallel with Arc 1 post-delivery work.

**Status:** Unblocked. Both tracks require stakeholder availability — MPP for the customer validation track, Blue Ridge architecture + MPP IT for the OI-35 track (MPP IT participates only in the retention-policy negotiation; the rest is Blue Ridge–internal).

## Two Parallel Tracks

### Track A — Customer Validation Gate (MPP-owned)

This is the workshop with MPP stakeholders (operations, quality, IT, production-control) where each gating item is walked, discussed, and decided. Items below are **must resolve** before Phase 1 — wrong answer rebuilds a phase.

| # | Item | Question | Why it gates | OIR ref |
|---|---|---|---|---|
| A1 | **OI-31** Identifier sequence cutover | Final cutover seed values + format carry-forward (keep `MESL`/`MESI`, or mint new?). Reset policy. Rollover policy at 9,999,999. Plus Ben's rollout-shape decision (single-line vs full-cutover vs shadow — memo at `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`). Couples to **S-10** in the Seeding Registry. | Phase 1 migration seeds `LastValue`; wrong seed = LTT collisions with live Flexware LOTs at cutover. | OI-31 |
| A2 | **FDS-06-030** WorkOrder BIT-flag enumeration | Which Flexware WorkOrder flags are live (`IsCameraProcessingEnabled`, `IsScaleProcessingEnabled`, `GroupTargetWeight` + tolerance + UOM, `RecipeNumber`, `TrayQuantity`, `ReturnableDunnageCode`, `Customer`)? | Phase 1 `Workorder.WorkOrder` CREATE column list. Dead flags don't ship. | FDS-06-030 |
| A3 | Historical data migration | Cutover approach — which entities migrate (LOTs, SerializedItems, ProductionOrders, Containers, Genealogy). Discrepancy review for unmatched rows (e.g., Flexware `LotAttribute.DIE NAME` with no matching `Tools.Tool.Code`). | Phase 1 migration-script + pre-flight validation design. | — |
| A4 | ShotCount semantics | `Workorder.ProductionEvent.ShotCount` = cumulative counter (current default) OR derived from aggregated LOT quantities? | Phase 3 operator-screen design + reporting path. Default until decided: keep cumulative column, mark provisional. | — |
| A5 | Workstation `DefaultScreen` + `ConfirmationMethod` seeding | Per-Cell list of terminal-function Perspective views + per-Cell `ConfirmationMethod` value (`Vision` / `Barcode` / `Both`). | Phase 1 seed data for B11 routing + UJ-17 / FDS-10-013. | — |
| A6 | Honda AIM Hold/Update contract detail | `PlaceOnHold` / `ReleaseFromHold` / `UpdateAim` signatures + error recovery expectations. UJ-04 GetNextNumber pool flow already locked; this covers the remaining AIM operations. | Phase 7 shipping Gateway scripts (Hold + Sort Cage re-pack paths). | UJ-04 (closed); remaining AIM ops |
| A7 | Label template scope | Flexware has 3 templates (CONTAINER / LOT / CONTAINER_HOLD). Confirm matches + any new (Sort Cage, Hold, Void). Print pattern itself is locked (UJ-18 Gateway-script-async); only template inventory is open. | Phase 6 / 7 label print procs + ZPL templates. Couples to **S-09** in the Seeding Registry. | — |
| A8 | **OI-32** Material Allocation operator screen | Premise challenged by Jacques in OIR v2.10 review; Blue Ridge clarification queued for confirmation. Awaits a separate Materials-Allocation walkthrough with MPP. | Phase 6 Assembly material flow. | OI-32 |
| A9 | **OI-33** AIM pool empty-pool hard-fail customer validation | Customer affirmation that **hard-fail** is the desired posture when the pool is exhausted (production stops on affected lines until pool refills; no soft-fallback or placeholder-then-reconcile). Per FDS-07-010a — current design is hard-fail. | Phase 7 `Container_Complete` semantics + operational expectations. | OI-33 |

### Track B — Architecture Decision Workshop (Blue Ridge–owned, with MPP IT for retention)

This is the architecture review captured by **OI-35** in the OIR (HIGH severity, "MUST DECIDE BEFORE ARC 2 PHASE 1 SQL BUILD"). Items 1, 3, 6, 8 are softer (post-CREATE configurable) but cleaner to lock in upfront; items 2, 4, 5, 7 must be in the **CREATE migration** because retrofitting them against populated 100M+ row tables is operationally expensive. Full context: `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

| # | Decision | Owner | Hard-gate reason |
|---|---|---|---|
| B1 | **Per-table retention class.** Negotiate which tables genuinely need 20 years vs which can carry 7-year retention. Push-back candidates: `Audit.OperationLog`, `Audit.FailureLog`, `Audit.InterfaceLog`, `Oee.DowntimeEvent`, `Audit.ConfigLog`. Honda traceability data (`Lots.*` events, `ContainerSerial`, `ShippingLabel`, `LotGenealogy`) almost certainly stays at 20 years. | Blue Ridge + MPP IT | Drives FDS-11 retention-policy amendment + which tables need partitioning. |
| B2 | **Partitioning scheme.** Native SQL Server 2022 range partitioning, monthly partitions, sliding-window automation. Applies to ~14 deferred high-volume event tables. Partition column is `CreatedAt` / `EventAt` / `LoggedAt` per table. | Blue Ridge | Partition function + scheme go in the CREATE migration. Partitioning a populated 100M-row table later requires rebuild + log-volume blow-up. |
| B3 | **Columnstore on aged partitions.** Convert partitions older than ~90 days from rowstore to clustered columnstore. Expected 8–15× compression on event-shape data. | Blue Ridge | Partition-aging job + maintenance plan. Configurable post-CREATE. |
| B4 | **`Lots.LotGenealogy` materialized closure table.** Pre-compute every ancestor-descendant pair at LOT creation time (`AncestorLotId`, `DescendantLotId`, `Depth`). Honda audit becomes O(1) lookup vs O(depth) recursion. | Blue Ridge | Closure table CREATEs alongside `LotGenealogy`. Backfilling 50M+ ancestor pairs from a recursive walk after 5 years of operation is expensive. |
| B5 | **Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot`.** OI-23 chose the view-based path (`Lots.v_LotDerivedQuantities`); at scale the view aggregates over 200M+ event rows per query. If materialize, do it in the same `Lot_Create` / event-write procs that already touch the Lot row. | Blue Ridge | If materialized, columns and update paths land in CREATE migration. View stays as fallback for diagnostics. |
| B6 | **`Lots.IdentifierSequence_Next` locking model.** Single-row hot table; ~150K LOTs/year creates row-lock contention. Two paths: (a) explicit `WITH (ROWLOCK, UPDLOCK)` with serializable transaction (current implicit pattern); (b) replace with SQL Server `SEQUENCE` object + format-string wrapper. | Blue Ridge | Affects `IdentifierSequence_Next` proc shape + table presence. Configurable but cleaner upfront. |
| B7 | **Split `Audit.OperationLog`.** Today every mutating proc writes here. Keep `OperationLog` for 7-year general audit; add a separate `Lots.LotEventLog` for traceability subset (LOT events, container close events, ShippingLabel mints) at 20-year retention. | Blue Ridge + MPP IT | If split, the new table CREATEs in the Phase 1 migration and the `Audit_LogOperation` shared proc routes by entity type. Retroactive split requires data migration. |
| B8 | **Filtered indexes on hot subsets.** Systematic per-table pass: every "active subset" query (`WHERE LotStatusCodeId IN (active codes)`, `WHERE ResumedAt IS NULL`, `WHERE ConsumedAt IS NULL`, `WHERE PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`) gets a filtered index 0.1–1% the size of the full table. | Blue Ridge | Index list for each Phase 1 CREATE; configurable post-CREATE but cleaner upfront. |

## Data Model Changes

None directly — Phase 0 produces decisions, not DDL. Any DDL deltas flowing from Phase 0 decisions are captured in the Phase 1 migration.

## Open Items Affecting This Phase

This phase **is** the open items phase. The two tracks above enumerate the must-resolve items. Lower-priority items handled opportunistically:

| Item | Status | Fallback if unresolved at Phase 0 |
|---|---|---|
| **UJ-19** Productivity DB replacement & 4 PD reports | ⬜ Open | MPP names the four PD reports + their data sources for MES reporting subsystem replication. Couples to **OI-30** Reports tile. |
| **UJ-05** Sort Cage serial migration | ⬜ Open | Update-in-place + `Lots.ContainerSerialHistory` is the schema-supportable default. Awaits MPP Quality + Honda compliance affirmation. |
| **UJ-03** Sublot split trigger | 🔶 In Review | Auto-prompt 50/50 even split (Option A) is current default per FDS-05-009; Ben confirms whether all parts split or only some. |
| **OI-24..30 discovery items** | ⬜ Open | Automation tile, Notifications, Supply part flag, cast-override cell flag, Workstation Category, Reports enumeration — handled in their respective phase walkthroughs if MPP brings input. |
| **OI-34** Production schedule leverage | ⬜ Open | Current minimal use (shift-window timing only) is sufficient; expanded use (target quotas per shift, drift detection, etc.) drops into post-Phase-9 enrichment. |

**Already closed** items that previously appeared on the Phase 0 list:

- OI-01 Event outbox; OI-02 weight-based closure; OI-03 shift runtime; OI-04 vision-conflict; OI-05 merge rules; OI-06 / UJ-01 operator identity; OI-07 WorkOrderType; OI-08 terminal mode; OI-09 / UJ-15 cavity-parallel LOTs; OI-10 tool life (superseded); OI-11 Casting→Trim (superseded by Trim→Machining); OI-12 MaxParts; OI-13 BOM export (now S-06); OI-14, -15, -16, -17, -18, -19, -20, -21, -22, -23, -32b; UJ-02, -04, -06, -07, -08, -09, -10, -11, -12, -13, -14, -15, -16, -17, -18.

See `MPP_MES_Open_Issues_Register.docx` v2.16 for full status and decision history.

## State & Workflow

Phase 0 has two parallel tracks. The MPP-owned track is a facilitated workshop, not a technical build. The Blue Ridge–owned track is an architecture review session.

### Track A — Customer Validation Gate workflow

1. **Pre-work.** Blue Ridge drafts a facilitator deck summarizing each gating item: the question, candidate answers, design implication of each, Blue Ridge's recommended default. Distributed to MPP 3 business days before workshop.
2. **Workshop.** 2–3 hour session with MPP stakeholders. Each gating item is walked, discussed, and decided. Opportunistic items covered if time permits.
3. **Decision log capture.** Decisions appended to `MPP_MES_Open_Issues_Register.docx` with signed-off dates. Each decision references its OI/UJ number.
4. **Schema delta capture.** Any DDL additions (new columns, new attribute-definition rows, new code-table entries) documented and folded into the Phase 1 migration file.

### Track B — Architecture Decision Workshop workflow

1. **Pre-work.** Blue Ridge architecture lead drafts a decision deck covering items B1–B8. For B1 (retention policy), the deck includes a per-table proposed retention class for MPP IT review.
2. **Internal session (B2, B3, B4, B5, B6, B7, B8).** Blue Ridge architecture review covers items 2–8 — these are technical decisions that don't require MPP input. ~2 hours.
3. **MPP IT session (B1).** Single-meeting deliverable on per-table retention policy. ~1 hour. Output: signed-off retention class per table.
4. **Architecture-decision log.** All 8 decisions captured in a new section of the Data Model spec (§ "Scaling Decisions") at the next data model bump (likely v1.10). Drives Phase 1 migration content.
5. **FDS-11 amendment.** FDS § 11 (Audit) gains a per-table retention paragraph at the next FDS bump.

## API Layer (Named Queries → Stored Procedures)

None — no code deliverables in Phase 0.

## Gateway Scripts

None.

## Perspective Views

None.

## Test Coverage

No test suite additions.

## Phase 0 complete when

- [ ] **Track A:** Workshop held with MPP representatives. Decision log for items A1–A9 appended to Open Issues Register with signed-off dates.
- [ ] **Track B:** Architecture decisions B1–B8 finalized. Data Model § "Scaling Decisions" added (data model bump). FDS-11 retention paragraph drafted (FDS bump).
- [ ] **B10 convention** (serial migration audit) rewritten with the chosen UJ-05 pattern (default direction: update-in-place + `Lots.ContainerSerialHistory`; awaits MPP Quality + Honda affirmation).
- [ ] Any DDL deltas (Track A column lists, Track B partitioning + closure table + materialization columns + filtered indexes) captured in the Arc 2 Phase 1 migration draft. **Migration numbering:** versioned migrations 0001–0013 are landed (Arc 1 complete + 0013 OI-07/OI-12 corrections). Arc 2 Phase 1 lands at `0014_arc2_phase1_shop_floor_foundation.sql`.
- [ ] Opportunistic items resolved or explicitly deferred with a documented fallback (UJ-19 PD reports, UJ-05 Sort Cage serial migration, UJ-03 sublot trigger, OI-24..30 discovery items, OI-34 production schedule leverage).

---

# Phase 1 — Shop Floor Foundation

**Goal:** Deliver the cross-cutting infrastructure that every downstream Arc 2 phase depends on — operator session, terminal binding, IP-based zone routing, shift runtime, LOT core skeleton, identifier sequence, and the shared operation-log audit contract — with the OI-35 architectural decisions baked into the migration on day one.

**Dependencies:** Phase 0 complete (**both** tracks). Arc 1 SQL complete (all tables referenced exist, Audit procs operational).

**Status:** Blocked on Phase 0.

## Data Model Changes

**Migration `sql/migrations/versioned/0014_arc2_phase1_shop_floor_foundation.sql`** (next unclaimed number — Arc 1 consumed `0001`–`0013`).

The Phase 1 migration carries **two distinct concerns** simultaneously: the new tables required by the operator-facing surface, and the OI-35 architectural decisions resolved in Phase 0. This is intentional — partitioning, closure tables, materialization, and filtered indexes are all cheaper to land at CREATE time than retrofit. The actual contents of the migration depend on Phase 0 outputs; the descriptions below assume the Phase 0 default decisions (with each variant called out).

**New tables (Arc 2 — introduced here, per Data Model v1.9l):**

- `Workorder.WorkOrder` — CREATE with the v1.9l column contract: `Id`, `WoNumber`, `WorkOrderTypeId` (FK → `Workorder.WorkOrderType`; defaults to the single-seeded `Production` row per OI-07), `ItemId`, `RouteTemplateId`, `WorkOrderStatusId`, `ToolId` (FK → `Tools.Tool`, NULL — schema hook for FUTURE Maintenance WOs, unpopulated in MVP), `CreatedAt`, `CompletedAt`. **Plus the FDS-06-030 Phase-0-confirmed BIT-flag columns** (live flags only, per A2 decision).
- `Workorder.WorkOrderOperation` — CREATE per Data Model §4. `AppUserId BIGINT NULL FK → AppUser.Id`.
- `Workorder.ProductionEvent` — CREATE per Data Model v1.9l checkpoint shape: `Id`, `LotId`, `OperationTemplateId`, `WorkOrderOperationId` (NULL), `EventAt`, `ShotCount` (NULL, cumulative), `ScrapCount` (NULL, cumulative), `ScrapSourceId` (NULL FK → `Workorder.ScrapSource`), `WeightValue`, `WeightUomId`, `AppUserId BIGINT NOT NULL FK → AppUser.Id`, `TerminalLocationId`, `Remarks`. **Required index `(LotId, EventAt DESC)`.** No `LocationId`, no `ItemId`, no `DieIdentifier`, no `CavityNumber`, no `GoodCount` / `NoGoodCount`, no `StartedAt` / `EndedAt`.
- `Workorder.ProductionEventValue` — CREATE per Data Model §4 (child of ProductionEvent, extensible `DataCollectionField` capture).
- `Workorder.ConsumptionEvent` — CREATE per Data Model §4. `AppUserId BIGINT NOT NULL FK → AppUser.Id`.
- `Workorder.RejectEvent` — CREATE per Data Model §4. `AppUserId BIGINT NOT NULL FK → AppUser.Id`.
- `Lots.IdentifierSequence` — CREATE per Data Model §3 (OI-31). Seed `Lot` (`MESL{0:D7}`) + `SerializedItem` (`MESI{0:D7}`) rows with `LastValue` set from the cutover-day Flexware snapshot (S-10, Phase 0 Track A delivers the values). **Implementation depends on Phase 0 Track B / B6:** if `SEQUENCE` object elected, `IdentifierSequence_Next` wraps a `SEQUENCE` per code; if row-locked-update elected, the proc uses `UPDATE ... WITH (ROWLOCK, UPDLOCK)`.

**OI-35 architectural additions (per Phase 0 Track B outputs):**

- **Partition functions + schemes** for the high-volume event tables: `Workorder.ProductionEvent`, `Workorder.ConsumptionEvent`, `Workorder.RejectEvent`, `Lots.LotMovement`, `Lots.LotStatusHistory`, `Lots.LotAttributeChange`, `Lots.LotGenealogy`, `Lots.ContainerSerial`, `Audit.OperationLog`, `Audit.InterfaceLog`, `Audit.FailureLog`, `Oee.DowntimeEvent`, `Quality.HoldEvent`. Range partitioned on `CreatedAt` / `EventAt` / `LoggedAt` per table. Monthly boundaries; sliding-window maintenance lands in a Phase 1 Gateway timer.
- **Materialized closure table for `Lots.LotGenealogy`** (if Phase 0 elected B4): `Lots.LotGenealogyClosure (AncestorLotId BIGINT, DescendantLotId BIGINT, Depth INT, CONSTRAINT PK_LotGenealogyClosure PRIMARY KEY (AncestorLotId, DescendantLotId))`. Indexed on both directions. `Lot_Create` and `Lot_Split` / `Lot_Merge` write closure rows transactionally alongside the genealogy edge.
- **Materialized derived-quantity columns on `Lots.Lot`** (if Phase 0 elected B5): `TotalInProcess INT NOT NULL DEFAULT 0`, `InventoryAvailable INT NOT NULL DEFAULT 0`. Updated by `ProductionEvent_Record` / `ConsumptionEvent_Record` inside the same transaction. The `Lots.v_LotDerivedQuantities` view stays as a diagnostic fallback.
- **Split `Audit.OperationLog`** (if Phase 0 elected B7): new `Lots.LotEventLog` table created with the same row shape as `OperationLog` plus `LotId BIGINT NOT NULL FK → Lots.Lot.Id`. The shared `Audit_LogOperation` proc routes by entity type — LOT events to `LotEventLog`, everything else to `OperationLog`. Retention class differs (20-year vs 7-year).
- **Filtered indexes on hot subsets** (per B8): see per-table indexes in the corresponding phase migrations.

**ALTERs (Arc 2 Phase 1):**

- `Lots.Lot` ADD `ToolId BIGINT NULL FK → Tools.Tool(Id)` and `ToolCavityId BIGINT NULL FK → Tools.ToolCavity(Id)`. Required at `Lot_Create` for die-cast-origin LOTs; NULL elsewhere; NULL after `Lot_Merge`.

**LocationAttributeDefinition seeds on the `Terminal` `LocationTypeDefinition`:**

- `DefaultScreen` (NVARCHAR — Perspective route path, e.g., `'/shop-floor/die-cast-entry'`).
- `RequiresCompletionConfirm` (BIT — per OI-16) — when set on a Dedicated Terminal, the auto-finish completion flow shows a large "Confirm Completion" button instead of a passive popup. NULL = 0 = passive popup.
- *No `TerminalMode` seed* — terminal mode is derived from the Terminal Location's parent ISA-95 tier per OI-08 (Cell-parent → Dedicated; WorkCenter- or Area-parent → Shared).

**LocationAttributeDefinition seeds on Cell-tier `LocationTypeDefinition`s:**

- `ConfirmationMethod` (NVARCHAR — `'Vision'` / `'Barcode'` / `'Both'`) on relevant Cell types (e.g., `AssemblyStation`, `SerializedAssemblyLine`) — per FDS-10-013 / UJ-17. Read by the production proc and operator UI; drives the FDS-06-010 / FDS-10-003 part-identity check. The exact list of receiving Cell types comes from Phase 0 A5.
- `CoupledDownstreamCellLocationId` (Integer / `Location.Location.Id` reference) on `CNCMachine` — per FDS-06-008. When non-NULL on a Machining Cell, Machining OUT auto-moves the LOT to the referenced Cell. NULL = legacy uncoupled path.

**What is NOT seeded (per Phase C security rewrite):**

- No `IdleTimeoutSeconds` attribute — there is no shift-start login to time out. Operator presence is persistent on Dedicated terminals; Shared terminals prompt on first action or machine change. The 30-minute idle re-confirmation overlay on Dedicated terminals is Perspective-layer behaviour, not a DB attribute.
- No `RequiresReauthForSensitive` attribute — elevation is per-action AD prompt (FDS-04-007) for every elevated action, everywhere. No per-terminal opt-out.

**Other migration tasks:**

- Add `Location.Location.IpAddress`-attribute-index if missing (read-heavy lookup in `Terminal_GetByIpAddress`).
- Seed a fallback `Terminal` `Location` row representing the global default (used when an unregistered IP connects).

**Tables used (existing from Arc 1 / Phase G):**

| Table | Role |
|---|---|
| `Location.Location` | Terminal location lookup by IP |
| `Location.LocationAttribute` | `IpAddress`, `DefaultScreen`, `ConfirmationMethod`, `CoupledDownstreamCellLocationId` values per Location |
| `Location.LocationAttributeDefinition` | Definitions of Terminal + Cell-tier attributes |
| `Location.AppUser` | Initials-based operator presence resolver; interactive users carry AD account |
| `Tools.Tool`, `Tools.ToolCavity`, `Tools.ToolAssignment` | System of record for Tool identity; Lot.ToolId / Lot.ToolCavityId FK to these |
| `Oee.ShiftSchedule` | Active-shift resolver input |
| `Oee.Shift` | Runtime shift instances (append-only) |
| `Lots.Lot` | LOT header — minimal CRUD in this phase (Phase 2 expands) |
| `Lots.LotStatusHistory` | Append on status change |
| `Lots.LotMovement` | Append on move |
| `Lots.LotStatusCode` | `BlocksProduction` flag source |
| `Audit.OperationLog` | Destination for general audit (or `LotEventLog` for LOT events if B7 elected) |
| `Audit.FailureLog` | Destination for rejected calls |

## Open Items Affecting This Phase

| Item | Assumption used |
|---|---|
| **OI-31** identifier sequences | Pending Phase 0 Track A — cutover-day `LastValue` for Lot + SerializedItem; format carry-forward confirmed; locking model from Phase 0 Track B / B6. |
| **OI-35** architectural decisions | Pending Phase 0 Track B — drives the migration shape. Default decisions assumed for the migration draft; final migration written after Phase 0. |
| **FDS-06-030** WorkOrder BIT flags | Pending Phase 0 Track A — live flag column list on `Workorder.WorkOrder` CREATE. |
| **Historical data migration** | Pending Phase 0 Track A — entity list, pre-flight validation, discrepancy review process. |
| OI-06 / UJ-01 operator identity | ✅ Closed (Phase C). Initials-based presence + per-action AD elevation. Phase 1 delivers `AppUser_GetByInitials`. |
| UJ-10 shift boundary | ✅ Closed (Option D). Events span boundaries naturally per OI-03 — `Shift_End` does NOT auto-close open `DowntimeEvent` rows; the open-event invariant per B3 carries through the boundary. |
| UJ-17 vision vs barcode | ✅ Closed (Option A). `ConfirmationMethod` LocationAttribute on Cell-tier types per FDS-10-013. |
| OI-16 / RequiresCompletionConfirm | ✅ Closed. Per-Terminal BIT LocationAttribute. |
| OI-08 terminal mode | ✅ Closed. Mode derived from parent Location tier — Engineering attaches Terminals at the right place in the hierarchy. No seeded attribute. |
| UJ-18 Gateway-script-async | ✅ Closed. B4 + B17 codify the pattern. AIM pool topup is the canonical example; Phase 1 doesn't directly use it (no external integrations until Phase 6/7), but Gateway-script-async is the foundation pattern for everything downstream. |

## State & Workflow

### Session establishment (terminal startup)

An Ignition Perspective session starts when a Perspective client connects to the Gateway. The Gateway invokes the `Terminal_ResolveFromSession` script with the client's IP.

1. Gateway calls `Location.Terminal_GetByIpAddress(@IpAddress = '10.12.7.34')`.
2. Proc queries `Location.LocationAttribute` for `AttributeName = 'IpAddress' AND Value = @IpAddress`, joins to the parent `Location` row (which must be `LocationType = 'Terminal'`), and returns:
   - `TerminalLocationId` (the Terminal Location's Id)
   - `TerminalName` (Location.Name — e.g., `'DC-TERM-05'`)
   - `ZoneLocationId` + `ZoneName` (the Terminal's parent Area — e.g., `'Die Cast'`)
   - `DefaultScreen` (from `LocationAttribute`, e.g., `'/shop-floor/die-cast-entry'`)
   - `TerminalMode` — **derived** from the Terminal Location's parent tier: `Dedicated` if parent is a Cell, `Shared` if parent is a WorkCenter or Area. No stored attribute.
3. If no Terminal matches the IP, proc returns the fallback Terminal's attributes. The Gateway script flags the session as "unregistered terminal" and routes to a generic Terminal Selector screen.
4. Gateway stashes these values in Perspective session props: `session.custom.terminal.*`.
5. Perspective's Home router view reads `session.custom.terminal.defaultScreen` and navigates to that path.

No DB mutation during session establishment. No audit log — this is a read-only lookup.

### Operator presence (initials-based — per Phase C / FDS §4)

**There is no login, no clock number, no PIN.** Operators are identified on a terminal by their **initials**, which establish a persistent operator presence context that pre-populates a defeasible Initials field on every mutation screen.

**Dedicated terminals (parented to a Cell — typically the lower-volume single-machine workstations):**

1. The operator scans or types their initials (e.g., `XX`) on the shift-start handoff screen or on first touch after the machine sits idle.
2. Perspective calls `Location.AppUser_GetByInitials @Initials='XX'`.
3. Proc returns the `AppUser` row (Id, Initials, DisplayName, UserClass). Empty result set = initials unknown — Perspective shows an inline error ("Initials XX not recognised — ask Admin to add this operator in the Configuration Tool") and does not proceed.
4. On success, Perspective stashes `session.custom.user.*` with `{appUserId, initials, displayName, userClass}`. Presence persists through the shift.
5. **30-minute idle re-confirmation.** A Perspective view-side timer resets on every interaction. At 30 minutes idle, the next touch shows a modal: *"Operate as XX? Yes / No — change."* On `Yes`, presence continues. On `No — change`, Perspective clears the session's initials and the operator scans/types fresh initials. The timer is a Perspective concern — no DB state.

**Shared terminals (parented to a WorkCenter or Area — typically the higher-volume multi-machine areas like Die Cast or Assembly):**

1. Presence is prompted **on first action and on every Cell-context change**. The Initials field at the top of every mutation screen is never pre-populated.
2. Operator enters initials inline on the screen being submitted. Each mutation carries its own `@AppUserId` resolved by `AppUser_GetByInitials` at submit time.
3. No persistent `session.custom.user.*` on shared terminals — every action is standalone.

**Cell-context selection (Shared terminals only — per FDS-02-009 / FDS-02-011):** The terminal's active Cell context is selectable by **scan or dropdown**. Selection is the first step of every interaction; it persists across the session until the operator changes it (again by scan or dropdown). Dedicated terminals have no Cell-context selector — context is fixed to the terminal's parent Cell.

**Pre-populated defeasible Initials field:** Every mutation screen shows an Initials field pre-populated from `session.custom.user.initials` (Dedicated) or empty (Shared). Operator can override before submit — e.g., when a pair-working colleague enters data on behalf of the primary operator. The value at submit time is what stamps the event.

### Elevated actions (per FDS-04-007)

Elevated actions (place hold, release hold, scrap LOT, void shipping label, Tool mount / release, admin remove-item, override a BOM-driven destination, supervisor merge override, BOM-substitute material override) require a **per-action Active Directory authentication**. On invocation:

1. Perspective shows the AD credential modal (AD username + password, integrated auth where available).
2. Perspective calls `Location.AppUser_AuthenticateAd @AdAccount='jdoe', @Password='...'` (proc delegates to Ignition's AD binding; returns the matching `AppUser.Id` + role list; NULL if invalid or role not permitted).
3. On success, the elevated action proceeds with the authenticated user's `@AppUserId` — this value stamps the mutation; the original operator-presence `@AppUserId` stays for non-elevated events. The elevation does NOT open a sticky session — next elevated action re-prompts.
4. Every elevation attempt (success and failure) writes to `Audit.OperationLog` with `LogEventType='ElevationGranted'` or `Audit.FailureLog` with `LogEventType='ElevationDenied'`.

No "re-auth" flag on Terminal, no 5-minute-window session stickiness, no PIN fallback. Elevation is always per-action.

### Shift runtime

Shift boundaries are driven by a Gateway script tick (`ShiftBoundaryTicker`, runs every 60 seconds):

1. Ticker calls `Oee.Shift_GetActive(@LocationId, @NowUtc)`.
2. Proc looks up `Oee.ShiftSchedule` rows active on today's day-of-week (per `DaysOfWeekBitmask`) with `EffectiveFrom <= @NowUtc` and `DeprecatedAt IS NULL`. Returns the one matching the current time-of-day window.
3. Ticker also calls `Oee.Shift_GetOpen(@ShiftScheduleId)` to see if there's an open `Shift` row for this schedule.
4. If the active schedule has no open `Shift` row, ticker calls `Oee.Shift_Start(@ShiftScheduleId, @ActualStart = @NowUtc)`. Proc inserts the Shift row, logs OperationLog.
5. If the previously-active schedule has an open `Shift` row but the active schedule is different (i.e., boundary crossed), ticker calls `Oee.Shift_End(@ShiftId, @ActualEnd = @NowUtc)` on the outgoing Shift. Proc updates the row, logs OperationLog.
6. **No auto-carryover of open events.** Per UJ-10 (Option D, closed): open `Oee.DowntimeEvent` rows remain open across the shift boundary; the incoming operator closes them when the machine resumes (FDS-09-010). Same for open `Lots.PauseEvent` rows.

### LOT core skeleton

Phase 1 delivers minimal LOT procs — enough to let Phase 3 (Die Cast) create its first LOT. Full LOT lifecycle (`Lot_Update`, `Lot_UpdateAttribute`, genealogy) is Phase 2.

`Lot_Create` flow (narrated from Phase 3's perspective — the proc is delivered here). Aligned to Data Model v1.9l + FDS-05-034 / FDS-05-035:

1. Operator takes a basket from a machine's active cavity and scans a fresh pre-printed LTT barcode at the terminal. Perspective builds the parameter set: `@LotName = NULL` (proc mints via `IdentifierSequence_Next @Code='Lot'`), `@ItemId`, `@LotOriginTypeId`, `@CurrentLocationId` (Cell), `@PieceCount`, `@ToolId` (NULL for non-die-cast origins; required for Die Cast — Perspective auto-populates from `ToolAssignment_ListActiveByCell` and operator confirms), `@ToolCavityId` (same rule), `@Weight`, `@WeightUomId`, `@VendorLotNumber` (Received only), `@AppUserId`, `@TerminalLocationId`.
2. Proc validates parameters (no NULLs on required, FKs resolve).
3. Proc validates business rules:
   - `@Item` eligible at `@CurrentLocationId` via `Parts.v_EffectiveItemLocation` (Direct ∪ BomDerived per FDS-02-012).
   - Piece count within `Parts.Item.MaxLotSize` (semantic `PartsPerBasket`).
   - If `@LotOriginTypeCode = 'Manufactured'` and the Cell has an active `Tools.ToolAssignment` (die-cast-origin check):
     - `@ToolId` and `@ToolCavityId` are required (per FDS-05-034).
     - `Tools.ToolAssignment` exists for `@ToolId` on `@CurrentLocationId` with `ReleasedAt IS NULL`.
     - `@ToolCavityId` belongs to `@ToolId`.
     - `ToolCavity.StatusCode = 'Active'`.
   - Non-die-cast origins (Received, Trim/Machining intermediate, Assembly, Serialized) SHALL pass NULL Tool/Cavity — proc does not require them.
4. `BEGIN TRANSACTION`.
5. Proc calls `Lots.IdentifierSequence_Next @Code='Lot'` which atomically increments `LastValue` (or invokes the `SEQUENCE` per B6) and returns the formatted string (e.g., `MESL1710935`). This is `@MintedLotName`.
6. Proc inserts `Lots.Lot` row with `LotName = @MintedLotName`, `LotStatusId = 'Good'`, `ToolId`, `ToolCavityId`. Returns new `Id` as `@NewId`.
7. Proc inserts `Lots.LotStatusHistory` row: `OldStatusId = NULL`, `NewStatusId = 'Good'`, `ChangedByUserId = @AppUserId`, `TerminalLocationId = @TerminalLocationId`.
8. **If B4 elected:** Proc inserts `Lots.LotGenealogyClosure` self-row `(AncestorLotId = @NewId, DescendantLotId = @NewId, Depth = 0)` to seed the closure for this LOT.
9. **If B5 elected:** `TotalInProcess` and `InventoryAvailable` initialize to 0 / `@PieceCount` respectively (no event yet; LOT is at its origin Cell).
10. Proc calls `Audit.Audit_LogOperation` (or `LotEventLog_LogEvent` if B7 elected) with `LogEntityTypeCode='Lot'`, `LogEventTypeCode='LotCreated'`, `EntityId=@NewId`, `Description='Created LOT <LotName> at <LocationName>'` (plus Tool/Cavity in description for die-cast-origin LOTs).
11. `COMMIT`.
12. Final `SELECT @Status, @Message, @NewId, @MintedLotName`.

If any validation fails, no transaction opens, `Audit.Audit_LogFailure` is called with the attempted parameters (Tool/Cavity included), and the proc returns early. Note: `IdentifierSequence_Next` is invoked **inside** the transaction so a rolled-back LOT doesn't burn a counter value (when B6 elected `SEQUENCE`, the sequence value IS burned regardless of rollback — accepted tradeoff for concurrency).

### `Lot_AssertNotBlocked` shared guard

Procedure called by every downstream proc that advances a LOT. Reads `Lot.LotStatusId → LotStatusCode.BlocksProduction`. Returns `IsBlocked BIT, Message NVARCHAR(500)`. Internal — no audit, no FailureLog; callers that receive `IsBlocked=1` log their own rejection via FailureLog and return early. Delivered in Phase 1; reused everywhere downstream per B2.

## API Layer (Named Queries → Stored Procedures)

### Location — Terminal resolution

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.Terminal_GetByIpAddress` | `@IpAddress NVARCHAR(45)` | Reads `LocationAttribute` where `AttributeName='IpAddress'`; joins to parent Terminal Location and its parent Area. Computes `TerminalMode` from parent tier. Returns fallback Terminal if no match. Falls back gracefully, never errors on unknown IP. | `Location.Location`, `Location.LocationAttribute`, `Location.LocationType`, `Location.LocationTypeDefinition` | Perspective session start, via Gateway script | Single row: `TerminalLocationId, TerminalName, ZoneLocationId, ZoneName, DefaultScreen, TerminalMode` |
| `Location.Terminal_List` | (none) | Admin query — all Terminal-type Locations with attributes. Used by an admin screen (not operator-facing). | `Location.Location`, `Location.LocationAttribute` | Admin browsing Terminal inventory | Rowset per Terminal |

### AppUser — initials-based presence + AD elevation

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Location.AppUser_GetByInitials` | `@Initials NVARCHAR(10)` | Resolves initials to an active `AppUser` row. Empty result set = unknown initials. No audit on lookup (initials-presence is not a security event). Used by Perspective on shift-start (Dedicated terminals) and on every Shared-terminal mutation. | `Location.AppUser` | Shift-start handoff; shared-terminal submit; 30-min idle re-confirm | Single row: `Id, Initials, DisplayName, UserClass, IgnitionRole` (or empty set if unknown). |
| `Location.AppUser_AuthenticateAd` | `@AdAccount NVARCHAR(100)`, `@TerminalLocationId BIGINT`, `@ActionCode NVARCHAR(50)` | **Elevation proc.** Delegates the credential check to Ignition's AD binding (the Perspective modal submits `@AdAccount + password`; if Ignition validates, it calls this proc with `@AdAccount` only). Proc looks up the matching `AppUser.AdAccount`, verifies the user is not deprecated, verifies `IgnitionRole` matches the role permitted for `@ActionCode`, and returns the `AppUserId`. On any reject, writes `Audit.FailureLog` with `LogEventType='ElevationDenied'`. On success, writes `Audit.OperationLog` with `LogEventType='ElevationGranted'`. | `Location.AppUser`, `Audit.Audit_LogOperation`, `Audit.Audit_LogFailure` | Every elevated action per FDS-04-007 | Single row: `Status BIT, Message NVARCHAR(500), AppUserId BIGINT` (NULL on failure). |
| `Location.AppUser_GetRoles` | `@AppUserId BIGINT` | Returns the `IgnitionRole` for interactive users; empty result for operator-class users. Used by Perspective to gate elevated-screen visibility. | `Location.AppUser` | On elevation success | Rowset of role strings. |

> **Explicitly NOT delivered:** clock# + PIN authentication procs. Phase G migration `0011_drop_appuser_legacy_auth.sql` already dropped `AppUser.ClockNumber` and `AppUser.PinHash` columns. Any Phase 3+ proc that references those columns is a bug.

### Shift — runtime instances

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Oee.Shift_Start` | `@ShiftScheduleId BIGINT`, `@ActualStart DATETIME2(3)`, `@Remarks NVARCHAR(500) NULL`, `@AppUserId BIGINT`, `@TerminalLocationId BIGINT` | Inserts a new `Oee.Shift` row. Rejects if an open Shift (ActualEnd NULL) already exists for this ShiftSchedule (per B3). | `Oee.Shift`, `Oee.ShiftSchedule`, `Audit.Audit_LogOperation` | Gateway ShiftBoundaryTicker | `Status, Message, NewId` |
| `Oee.Shift_End` | `@ShiftId BIGINT`, `@ActualEnd DATETIME2(3)`, `@Remarks NVARCHAR(500) NULL`, `@AppUserId BIGINT`, `@TerminalLocationId BIGINT` | Closes the Shift: updates `ActualEnd`. Rejects if ActualEnd already set. **No auto-carryover logic** — open events stay open per UJ-10 / FDS-09-010. | `Oee.Shift`, `Audit.Audit_LogOperation` | Gateway ShiftBoundaryTicker or manual override | `Status, Message` |
| `Oee.Shift_GetActive` | `@LocationId BIGINT NULL`, `@NowUtc DATETIME2(3) = SYSDATETIME()` | Returns the schedule active at `@NowUtc` matching the day-of-week bitmask. Does not create a Shift row. | `Oee.ShiftSchedule` | Gateway ShiftBoundaryTicker; supervisor dashboard | Single row or empty |
| `Oee.Shift_GetOpen` | `@ShiftScheduleId BIGINT` | Returns the open Shift (if any) for this schedule. Used by the ticker to detect whether a Shift_Start is needed. | `Oee.Shift` | Gateway ShiftBoundaryTicker | Single row or empty |

### Lot — core skeleton (minimal; Phase 2 expands)

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Lots.Lot_Create` | `@ItemId`, `@LotOriginTypeId`, `@CurrentLocationId`, `@PieceCount`, `@Weight`, `@WeightUomId`, `@ToolId`, `@ToolCavityId`, `@VendorLotNumber`, `@MinSerialNumber`, `@MaxSerialNumber`, `@AppUserId`, `@TerminalLocationId` | Creates a Lot with status 'Good'. Mints `LotName` via `IdentifierSequence_Next @Code='Lot'` inside the transaction. Validates `Item` eligibility via `v_EffectiveItemLocation`, piece count ≤ `Parts.Item.MaxLotSize` (`PartsPerBasket`). Validates Tool/Cavity per FDS-05-034 for die-cast-origin. Inserts initial `LotStatusHistory` row. **If B4 elected:** inserts self-row in `LotGenealogyClosure`. Audit via `Audit.Audit_LogOperation` (or `LotEventLog_LogEvent` if B7). | `Lots.Lot`, `Lots.LotStatusHistory`, `Lots.IdentifierSequence`, `Lots.LotGenealogyClosure` (if B4), `Parts.Item`, `Parts.v_EffectiveItemLocation`, `Tools.Tool`, `Tools.ToolCavity`, `Tools.ToolAssignment`, `Lots.LotOriginType`, `Lots.LotStatusCode`, `Audit.Audit_LogOperation` | Phase 3+ station produces a new LOT | `Status, Message, NewId, MintedLotName NVARCHAR(50)` |
| `Lots.IdentifierSequence_Next` | `@Code NVARCHAR(30)` | Atomically returns the next formatted identifier string. Implementation per Phase 0 B6 decision (row-locked update OR `SEQUENCE` wrapper). Raises on unknown `@Code` or rollover breach. | `Lots.IdentifierSequence` (or sequence object) | Any identifier minting path | Single row: `Value NVARCHAR(50)`. |
| `Lots.Lot_Get` | `@LotId BIGINT NULL`, `@LotName NVARCHAR(50) NULL` | Returns the Lot row. **If B5 elected:** the materialized columns `TotalInProcess` and `InventoryAvailable` are returned directly. **If B5 not elected:** view-joined to `v_LotDerivedQuantities` at read time. Empty result set = not found. | `Lots.Lot`, optionally `Lots.v_LotDerivedQuantities` | Any screen displaying a LOT | Single row of Lot columns + derived quantities |
| `Lots.Lot_List` | `@ItemId NULL`, `@CurrentLocationId NULL`, `@LotStatusId NULL`, `@LimitRows INT = 100` | Filterable listing. Read-only, no audit. Same view-vs-materialized rule as `Lot_Get`. | `Lots.Lot` | LOT search screen | Rowset of Lot columns |
| `Lots.Lot_UpdateStatus` | `@LotId`, `@NewLotStatusId`, `@Reason`, `@AppUserId`, `@TerminalLocationId`, `@RowVersion ROWVERSION` | Updates `Lot.LotStatusId` with optimistic-lock check. Inserts `LotStatusHistory` row. Rejects no-op (new = current). Phase 1 only accepts Good → Closed transitions; Phase 2 expands. | `Lots.Lot`, `Lots.LotStatusHistory`, `Lots.LotStatusCode`, `Audit.Audit_LogOperation` | Phase 2+ for general transitions; Phase 7 for holds | `Status, Message` |
| `Lots.Lot_MoveTo` | `@LotId`, `@ToLocationId`, `@AppUserId`, `@TerminalLocationId` | Updates `Lot.CurrentLocationId` and inserts `LotMovement` row with `FromLocationId` = prior, `ToLocationId` = new. Calls `Lot_AssertNotBlocked` first (per B2). | `Lots.Lot`, `Lots.LotMovement`, `Lots.Lot_AssertNotBlocked`, `Audit.Audit_LogOperation` | Any station that receives a scanned LOT | `Status, Message` |
| `Lots.Lot_AssertNotBlocked` | `@LotId BIGINT` | Internal shared guard. Returns `IsBlocked BIT, Message NVARCHAR(500)`. No audit. Called by every advancing proc (B2). | `Lots.Lot`, `Lots.LotStatusCode` | Every mutation that advances a LOT | Single row |

### Audit — shared operation logger

| Procedure | Parameters | Notes | Dependencies | Executed When | Output |
|---|---|---|---|---|---|
| `Audit.Audit_LogOperation` | `@AppUserId`, `@TerminalLocationId`, `@LocationId NULL`, `@LogSeverityCode = 'Info'`, `@LogEventTypeCode`, `@LogEntityTypeCode`, `@EntityId`, `@Description`, `@OldValue NULL`, `@NewValue NULL` | Inserts into `Audit.OperationLog`. **If B7 elected:** routes LOT-event entity types to `Lots.LotEventLog` instead. Resolves code strings to FK ids internally. Returns no result set (audit writers silent). | `Audit.OperationLog`, optionally `Lots.LotEventLog` | Every Arc 2 mutation proc | (none) |

## Gateway Scripts

| Script | Purpose | Trigger | External System | Audit |
|---|---|---|---|---|
| `Terminal_ResolveFromSession` | On Perspective session start, read client IP, call `Terminal_GetByIpAddress`, stash Terminal / Zone / DefaultScreen / TerminalMode into `session.custom.terminal.*`. If unregistered IP, fall back to global-default Terminal and flag the session. | Perspective session startup event | — | — (read-only) |
| `PresenceIdleWatcher` (Perspective view-side, not Gateway) | Dedicated terminals only. Per-view 30-minute idle detector resets on any interaction. At timeout, shows the "Operate as [XY]? Yes / No — change" modal. On `No — change`, clears `session.custom.user.*` and routes to initials entry. | Perspective interaction events | — | — |
| `ShiftBoundaryTicker` | Every 60 seconds: for each configured schedule, resolve active schedule, detect boundary crossings, call `Shift_End` on outgoing + `Shift_Start` on incoming. **No auto-carryover** — open events stay open per UJ-10. | Gateway timer (60s) | — | OperationLog on Shift_Start / Shift_End |
| `PartitionMaintenance` (if Phase 0 B2 elected partitioning) | Daily — creates next month's partition + ages oldest partition into archive boundary. Switches partitions older than 90 days to columnstore (B3). | Gateway timer (24h) | — | OperationLog on each partition switch |

> **Removed:** `AdAuthenticator` Gateway script is not needed — AD credential validation is delegated to Ignition's built-in AD binding (invoked by the Perspective elevation modal), with `AppUser_AuthenticateAd` performing only the post-validation role check + audit write.

## Perspective Views

| View | Purpose |
|---|---|
| Initials Entry (Dedicated terminals) | Shift-start handoff and 30-minute re-confirm modal. Operator scans or types initials. Submits `AppUser_GetByInitials`; inline error on unknown. Sets `session.custom.user.*` on success. No password, no PIN. |
| Terminal Selector | Shown only for unregistered-IP sessions. Operator selects terminal from a list or scans a terminal barcode. Updates `session.custom.terminal.*` from a manual selection proc. |
| Cell Context Selector (Shared terminals) | Per FDS-02-009/-011 — operator selects active Cell context by **scan or dropdown**. Persists across the session until explicit change. Dedicated terminals do not show this view. |
| Home Router | Stateless: reads `session.custom.terminal.defaultScreen` and navigates. Falls back to a generic Home tile grid if DefaultScreen is NULL. |
| 30-Min Idle Re-Confirm Modal | Dedicated terminals only. *"Operate as XX? Yes / No — change."* `Yes` continues presence; `No — change` clears and returns to Initials Entry. |
| Per-Mutation Initials Field | Every mutation screen shows a prominent Initials field, pre-populated from `session.custom.user.initials` on Dedicated terminals, empty on Shared. Operator can override before submit. |
| Elevation Modal (per-action AD) | Triggered by elevated actions per FDS-04-007. AD username + password inline; integrated auth via Ignition AD binding where available. On success, action proceeds with the elevated `@AppUserId`; no sticky session. Every attempt logged. |

## Test Coverage

New test suite at `sql/tests/0014_PlantFloor_Foundation/` (next unclaimed test-suite number — Arc 1 consumed `0001`–`0019`):

| File | Covers |
|---|---|
| `010_Terminal_GetByIpAddress.sql` | Known IP resolves to correct Terminal + Zone + DefaultScreen + derived TerminalMode (Dedicated for Cell parent, Shared for WC/Area parent); unknown IP returns fallback; Terminal without DefaultScreen attribute returns NULL DefaultScreen; deprecated Terminal not returned. |
| `020_AppUser_GetByInitials.sql` | Known initials return the AppUser row; unknown initials return empty result set; deprecated AppUser returns empty; mixed-class lookup (operator + interactive) covered. |
| `025_AppUser_AuthenticateAd.sql` | Valid AD account + permitted role + valid action code returns AppUserId + OperationLog 'ElevationGranted'; wrong role rejects with FailureLog 'ElevationDenied'; deprecated AD user rejects; unknown `@ActionCode` rejects; missing `@AdAccount` rejects. |
| `030_Shift_lifecycle.sql` | `Shift_Start` creates row; `Shift_Start` rejects when open Shift exists (B3); `Shift_End` closes row; `Shift_End` rejects when no open Shift; `Shift_GetActive` returns schedule by day-of-week bitmask. |
| `035_IdentifierSequence.sql` | `IdentifierSequence_Next` returns correctly formatted strings for `MESL{0:D7}` and `MESI{0:D7}`; raises on unknown @Code; raises on rollover breach at EndingValue; concurrent callers see strictly-increasing values (per Phase 0 B6 chosen mechanism). |
| `040_Lot_Create.sql` | Valid manufacture creates Lot + LotStatusHistory with Tool/Cavity set; minted `LotName` matches `MESL{0:D7}` format; die-cast-origin LOT without @ToolId rejects; die-cast-origin LOT with @ToolId not mounted on Cell rejects; cavity not belonging to tool rejects; cavity in Closed/Scrapped state rejects; non-die-cast-origin LOT with NULL Tool/Cavity accepted; ineligible Item-at-Location rejects (via `v_EffectiveItemLocation` Direct ∪ BomDerived); piece count over `MaxLotSize` rejects; missing `@AppUserId` rejects. |
| `045_LotGenealogyClosure_self.sql` (if B4 elected) | `Lot_Create` inserts self-row in `LotGenealogyClosure` with `Depth=0`; concurrent creates don't collide on the closure unique constraint; rolled-back `Lot_Create` does not leave a closure row. |
| `050_Lot_Get_List.sql` | `Lot_Get` by Id and by LotName returns Tool/Cavity FKs + derived quantities (materialized or view per B5); empty result for non-existent; `Lot_List` filters work; limit applied. |
| `060_Lot_UpdateStatus.sql` | Valid transition applies; stale `@RowVersion` rejects; no-op (same status) rejects; invalid target status rejects. |
| `070_Lot_MoveTo.sql` | Valid move updates CurrentLocationId + inserts LotMovement; move from unblocked Lot succeeds; move from blocked Lot (Hold/Scrap/Closed) rejects via `Lot_AssertNotBlocked`. |
| `080_Lot_AssertNotBlocked.sql` | Good returns `IsBlocked=0`; Hold/Scrap/Closed return `IsBlocked=1` with correct Message; non-existent Lot returns `IsBlocked=1` with 'LOT not found' message. |

Target: 80–105 passing tests in suite 0014 (up from v0.x target — adds closure-table tests + Tool/Cavity validation + IdentifierSequence + AD elevation).

## Phase 1 complete when

- [ ] Migration `0014_arc2_phase1_shop_floor_foundation.sql` applied to dev. All Phase 1 CREATE / ALTER / seed delivered.
- [ ] **OI-35 architectural decisions baked in** per Phase 0 outputs — partition functions in place, closure table CREATEd (if B4), materialized columns added (if B5), `OperationLog` split (if B7), filtered indexes per B8.
- [ ] All repeatable procs present and up-to-date.
- [ ] **No proc anywhere in the repo references `AppUser.ClockNumber` or `AppUser.PinHash`** (both columns dropped by Phase G migration `0011`). Grep verification: `grep -ri 'ClockNumber\|PinHash' sql/` returns zero hits in active code.
- [ ] All tests in `sql/tests/0014_PlantFloor_Foundation/` pass (target 80–105).
- [ ] Reset script (`Reset-DevDatabase.ps1`) discovers and applies the new migration and runs the new test suite.
- [ ] Gateway script `Terminal_ResolveFromSession` implemented and tested against Perspective sessions from known + unknown IPs.
- [ ] Gateway script `ShiftBoundaryTicker` implemented; verified end-to-end against a dev ShiftSchedule that crosses a boundary within the test window.
- [ ] Gateway script `PartitionMaintenance` implemented (if B2 elected); verified manually against a dev partition at a month boundary.
- [ ] Perspective views: Initials Entry, Terminal Selector, Cell Context Selector (Shared), Home Router, 30-Min Idle Re-Confirm Modal, Elevation Modal all built and routed correctly.
- [ ] `Audit.Audit_LogOperation` code-string → FK resolution verified for `LogEventType` values: `'ShiftStarted'`, `'ShiftEnded'`, `'LotCreated'`, `'LotStatusChanged'`, `'LotMoved'`, `'ElevationGranted'`. `Audit.Audit_LogFailure` verified for `'ElevationDenied'`. Any missing `Audit.LogEventType` rows seeded.
- [ ] Downstream phases can call `Lot_Create` (with Tool/Cavity FKs), `IdentifierSequence_Next`, `AppUser_GetByInitials`, `AppUser_AuthenticateAd`, `Lot_MoveTo`, `Lot_UpdateStatus`, and `Lot_AssertNotBlocked` against the delivered contract.
- [ ] **End-to-end integration check**: a dev operator scans initials at a dev Dedicated Terminal, presence persists, the operator creates a die-cast LOT (Tool auto-populated from active ToolAssignment, operator confirms, cavity selected), the LOT is minted with `MESL{0:D7}` name, a placeholder elevated action triggers the AD Elevation Modal and logs both OperationLog + FailureLog rows appropriately. Closure table row inserted (if B4). Materialized derived columns reflect zero in-process / full-piece-count available (if B5).

---

# Phase 2 — LOT Lifecycle Completion

**Goal:** Fill out the complete LOT surface — all mutation procs, append-only history streams, full genealogy (split / merge / consumption), pause lifecycle, derived quantity reads, and label reprint — so downstream operator-station phases compose from a stable LOT API.

**Dependencies:** Phase 1 (foundation). Most Lots schema tables already exist from Phase 1 migration.

**Status:** Blocked on Phase 1.

## Data Model Changes

**Migration `sql/migrations/versioned/0015_arc2_phase2_lot_lifecycle.sql`** (next unclaimed after Phase 1).

**New tables:**

- **`Lots.PauseEvent`** (OI-21 / FDS-05-038) — append-only place + close lifecycle for operator-driven LOT pauses at a workstation. Columns: `Id BIGINT PK`, `LotId BIGINT NOT NULL FK → Lots.Lot.Id`, `LocationId BIGINT NOT NULL FK → Location.Location.Id (Cell-tier)`, `PausedByUserId BIGINT NOT NULL FK → AppUser.Id`, `PausedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()`, `PausedReason NVARCHAR(500) NULL`, `ResumedByUserId BIGINT NULL FK → AppUser.Id`, `ResumedAt DATETIME2(3) NULL`, `ResumedRemarks NVARCHAR(500) NULL`. Constraints: `CK_PauseEvent_ResumePaired` pairing the resume cols; filtered UNIQUE `UQ_PauseEvent_OpenLotLocation (LotId, LocationId) WHERE ResumedAt IS NULL`. Filtered indexes: `IX_PauseEvent_OpenByLocation (LocationId) WHERE ResumedAt IS NULL` (Paused-LOT indicator counter) + `IX_PauseEvent_Lot (LotId, PausedAt DESC)` (per-LOT pause history). `Audit.LogEntityType` +1 row (`PauseEvent`).

**New views (if Phase 0 B5 NOT elected — view stays as primary read path):**

- **`Lots.v_LotDerivedQuantities (LotId, TotalInProcess, InventoryAvailable)`** (OI-23 / FDS-05-031) — joins `Lots.Lot.PieceCount` with aggregations over `Workorder.ProductionEvent` (cumulative checkpoint counters) and `Workorder.ConsumptionEvent`. `Lot_Get` and `Lot_List` JOIN this view at read time. *If B5 elected, view remains as a diagnostic fallback; primary read path is the materialized columns on `Lots.Lot`.*

**Indexes:** Phase 2 indexes any hot-read paths exposed by testing (e.g., `Lots.LotGenealogy(ParentLotId)` and `Lots.LotGenealogy(ChildLotId)` if not already covered by Phase 1 partition-aligned indexes).

**Tables used:**

| Table | Role |
|---|---|
| `Lots.Lot` | Header — expanded update surface |
| `Lots.LotStatusHistory` | Append on every `Lot_UpdateStatus` |
| `Lots.LotMovement` | Append on every `Lot_MoveTo` |
| `Lots.LotAttributeChange` | Append on every `Lot_UpdateAttribute` |
| `Lots.LotGenealogy` | Append on Split / Merge / Consumption |
| `Lots.LotGenealogyClosure` (if B4) | Maintained alongside `LotGenealogy` for O(1) ancestor walks |
| `Lots.GenealogyRelationshipType` | Code table — Split, Merge, Consumption |
| `Lots.LotLabel` | Append on every label print/reprint |
| `Lots.PrintReasonCode` | Code table |
| `Lots.LabelTypeCode` | Code table |
| `Lots.PauseEvent` | NEW — operator-driven LOT pause lifecycle |
| `Tools.DieRankCompatibility` | **Read-only** — `Lot_Merge` consults for cross-die merge approval (S-08) |

## Open Items Affecting This Phase

| Item | Status |
|---|---|
| **UJ-08** merge rules | ✅ Closed (Option A). Proc-enforced rules per OI-05 / FDS-05-025..030: same `ItemId`, post-sort only, die-rank-compat from `Tools.DieRankCompatibility` (S-08), no `Hold × Good` mixing. Supervisor AD elevation per FDS-04-007 unblocks edge cases. **S-08 die rank matrix is owed but not blocking** — supervisor override is the escape hatch. |
| **OI-21** Pausable LOT | ✅ Closed (design locked). `PauseEvent` CREATE + 4 procs delivered in this phase. |
| **OI-23** Lot derived quantities | ✅ Closed (view) — but **may flip to materialized columns** per Phase 0 B5. Phase 2 honors the elected approach. |
| **B10** serial migration | Pending Phase 0 (UJ-05 still in default state). Not relevant here — Phase 7 consumes this. Confirm B10 is finalized before Phase 7 starts. |

## State & Workflow

### Full `Lot_Update`

`Lot_Update` is distinct from `Lot_UpdateStatus`. It covers mutations to LOT header fields other than status — piece count correction, weight correction, vendor-lot-number correction for received LOTs. Each field change is captured as a separate `LotAttributeChange` row so the before/after audit is field-level.

1. Perspective sends the full LOT payload with the operator's intended new values.
2. Proc validates optimistic lock via `@RowVersion`.
3. Proc validates `Lot_AssertNotBlocked` (per B2 — even "corrections" on a held LOT are not allowed; release the hold first).
4. Proc compares each mutable field. For each changed field, insert `LotAttributeChange` row with `AttributeName`, `OldValue`, `NewValue`, `ChangedByUserId`, `TerminalLocationId`, `ChangedAt`.
5. Update the `Lot` row with the new values; `UpdatedByUserId`, `UpdatedAt`, `RowVersion` auto-updated.
6. **If B5 elected:** if `PieceCount` changed, also recalculate `InventoryAvailable` accordingly.
7. Audit via `Audit_LogOperation` with `LogEventType='LotUpdated'`.

### Genealogy — three shapes

**Split.** One parent LOT becomes multiple child LOTs. `Lot_Split` is consumed by Phase 5 (Machining OUT sub-LOT split) and Phase 7 (Sort Cage). Sequence:

1. Parameter validation, `Lot_AssertNotBlocked` on the parent.
2. Business rule: sum of child piece counts ≤ parent piece count.
3. For each child spec: call `Lot_Create` (which transactionally seeds `LotGenealogyClosure` self-row if B4); insert `LotGenealogy` row `(ParentLotId, ChildLotId, RelationshipType='Split', PieceCount = child's share, ...)`; **if B4:** insert closure rows `(AncestorLotId, ChildLotId, Depth+1)` for every existing ancestor of the parent plus the parent itself.
4. Reduce parent piece count via `Lot_UpdateAttribute`. If residual is 0, `Lot_UpdateStatus` parent → `Closed`.
5. Audit via `Audit_LogOperation` with `LogEventType='LotSplit'`.

**Merge.** Multiple source LOTs combine into one output. Per FDS-05-025..030 + UJ-08 (closed Option A): same `ItemId`, post-sort only, die-rank-compatibility from `Tools.DieRankCompatibility` (S-08), no `Hold × Good` mixing, supervisor AD override unblocks edge cases.

`Lot_Merge` sequence:

1. Parameter validation: ≥2 source LOTs listed.
2. `Lot_AssertNotBlocked` on each source.
3. Business rules: same `ItemId`, all sources `Good`, die-rank-compatibility check (when sources have differing `ToolId`, look up `DieRankCompatibility` matrix; reject with clear message until matrix populated; supervisor override from FDS-04-007 always works as escape hatch).
4. Create the merged output via `Lot_Create` with `ToolId = NULL`, `ToolCavityId = NULL` (blended-origin material can't be denormalized — Tool-specific trace reconstructed via `LotGenealogy` walk of pre-merge sources per FDS-05-030).
5. For each source: insert `LotGenealogy` row `(ParentLotId = sourceId, ChildLotId = outputId, RelationshipType='Merge', ...)`; **if B4:** insert closure rows `(AncestorLotId, outputId, ...)` for every ancestor of every source. `Lot_UpdateStatus` source → `Closed`.
6. Audit with `LogEventType='LotMerged'`.
7. Return output Lot Id.

**Consumption.** One or more source LOTs are consumed to produce a child LOT or to fill a serialized part's container. Handled by `LotGenealogy_RecordConsumption` (low-level) and invoked by Phase 5 Machining IN (BOM-driven rename) and Phase 6 Assembly (`ConsumptionEvent_Record`).

`LotGenealogy_RecordConsumption` is narrow: given a source LOT, a produced LOT or container tray position, and a piece count, insert the `LotGenealogy` row with `RelationshipType='Consumption'`; **if B4:** insert closure rows. Phases 5 + 6 wire this into their workflows with surrounding validation (BOM check, interlock bypass handling, container-tray placement).

### Genealogy traversal

`Lot_GetGenealogyTree` walks the graph. Two implementations possible per Phase 0 B4:

- **If B4 NOT elected:** Recursive CTE walking `LotGenealogy`. `OPTION (MAXRECURSION 100)`. `@Direction` selects Ancestors / Descendants / Both.
- **If B4 elected:** Direct query against `LotGenealogyClosure`. O(1) per ancestor; no recursion. Same return shape as the CTE version. Honda audits at year 15 stay fast regardless of partition count.

### Label reprint

`LotLabel_Reprint` captures a new `LotLabel` row with a `PrintReasonCode` (label damaged, LOT attribute corrected, split generated a new child LTT, merge issued a new parent). The original `LotLabel` row is not modified — labels are append-only. Perspective's reprint dialog forces a reason selection; the Gateway ZPL dispatcher renders and prints as with `LotLabel_Print`.

### LOT pause at workstation (OI-21 / FDS-05-038)

Pause is a `(Lot, Location)` lifecycle event recording an operator's deliberate shift of focus away from a partially-progressed LOT at a Cell. The paused LOT remains in-process at the original Cell with its prior partial-start state intact (FDS-05-032); the operator MAY freely run other LOTs at that Cell while the pause is open.

Storage is `Lots.PauseEvent` — append-only place + close lifecycle (mirrors `Quality.HoldEvent`). Pause is **orthogonal** to `Workorder.WorkOrderStatus`, `Workorder.OperationStatus`, and `Lots.LotStatusCode` — no `Paused` row in any of those code tables. Pause does NOT write a `Oee.DowntimeEvent`.

**Cross-location concurrency.** The same LOT MAY be paused at multiple Cells simultaneously. Filtered UNIQUE on `(LotId, LocationId) WHERE ResumedAt IS NULL` enforces at most one **open** pause per `(LotId, LocationId)`.

**Operator UX — no auto-prompt.** When an operator selects or scans a fresh LOT at a Cell that has a paused LOT open, the system SHALL NOT automatically prompt "resume paused LOT?" Instead, every workstation Perspective view binds to a **Paused-LOT indicator** that shows the current open-pause count for the operator's Cell; tapping the indicator opens a list view (LotName, Part, PausedAt, PausedByUserId) backed by `LotPause_GetByLocation @LocationId` and lets the operator resume any LOT explicitly. Resume MAY be performed by a different operator from the one who paused.

**No TTL.** Paused LOTs SHALL NOT be auto-resumed or auto-cancelled. They MAY persist across shifts and operators.

### LOT derived quantities

The Lot Details header surfaces two derived quantities. Read path depends on Phase 0 B5:

- **TotalInProcess** — pieces at all non-terminal workstations (started but not yet completed out).
- **InventoryAvailable** — pieces still available for consumption or scrap.

**If B5 elected:** materialized columns on `Lots.Lot`, kept current by `ProductionEvent_Record` / `ConsumptionEvent_Record` writes. `Lot_Get` reads them directly.

**If B5 NOT elected:** view-backed via `v_LotDerivedQuantities`. `Lot_Get` JOINs the view at read time.

## API Layer (Named Queries → Stored Procedures)

### Lot — expanded mutations

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Lots.Lot_Update` | `@LotId`, `@PieceCount NULL`, `@Weight NULL`, `@WeightUomId NULL`, `@VendorLotNumber NULL`, `@RowVersion ROWVERSION`, `@AppUserId`, `@TerminalLocationId` | Full header update. Inserts one `LotAttributeChange` row per changed field. Rejects on stale `@RowVersion`. `Lot_AssertNotBlocked`. **If B5:** recalculates `InventoryAvailable` if PieceCount changed. | `Status, Message` |
| `Lots.Lot_UpdateAttribute` | `@LotId`, `@AttributeName`, `@NewValue`, `@AppUserId`, `@TerminalLocationId` | Single-field update helper. Used by `Lot_Split` to reduce parent piece count. | `Status, Message` |
| `Lots.Lot_Split` | `@ParentLotId`, `@ChildrenJson` (JSON array of `{pieceCount, currentLocationId}`), `@AppUserId`, `@TerminalLocationId` | Creates N child LOTs, inserts SPLIT genealogy rows + closure rows (B4), reduces parent piece count, closes parent if residual=0. Rejects if sum(children) > parent. `Lot_AssertNotBlocked` on parent. | Multi-row: header `Status, Message`; per-child `ChildLotId, ChildLotName, PieceCount` |
| `Lots.Lot_Merge` | `@SourceLotIdsJson`, `@OutputItemId`, `@OutputLocationId`, `@AppUserId`, `@TerminalLocationId` | Combines sources into one output. Proc-enforced rules per FDS-05-025..030. Closes all sources. | `Status, Message, NewId` |
| `Lots.LotGenealogy_RecordConsumption` | `@SourceLotId`, `@ConsumedPieceCount`, `@ProducedLotId NULL`, `@ProducedContainerId NULL`, `@ProducedSerialNumber NULL`, `@AppUserId`, `@TerminalLocationId` | Internal — inserts CONSUMPTION genealogy + closure rows. Called from Phase 5 Machining IN and Phase 6 Assembly. | `Status, Message, NewId` |

### Genealogy traversal

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Lots.Lot_GetGenealogyTree` | `@LotId`, `@Direction NVARCHAR(20) = 'Both'` | If B4: closure-table query. If not: recursive CTE with `OPTION (MAXRECURSION 100)`. Same return shape either way. | Flat rowset with depth + relationship |
| `Lots.Lot_GetParents` | `@LotId` | One-hop up. | Rowset of parent Lots |
| `Lots.Lot_GetChildren` | `@LotId` | One-hop down. | Rowset of child Lots |
| `Lots.Lot_GetAttributeHistory` | `@LotId` | All `LotAttributeChange` + `LotStatusHistory` + `LotMovement` rows for a LOT, unioned and ordered by time. | Rowset of events |

### Labels

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Lots.LotLabel_Print` | `@LotId`, `@LabelTypeCodeId`, `@PrintReasonCodeId`, `@AppUserId`, `@TerminalLocationId` | Inserts `LotLabel` row with rendered ZPL. Called by initial create paths + reprint paths. | `Status, Message, NewId, ZplContent NVARCHAR(MAX)` |
| `Lots.LotLabel_Reprint` | `@LotId`, `@PrintReasonCodeId`, `@AppUserId`, `@TerminalLocationId` | Convenience wrapper — `Initial=0`. | Same shape as `Print` |

### LOT pause (OI-21)

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Lots.LotPause_Place` | `@LotId`, `@LocationId`, `@PausedReason NVARCHAR(500) NULL`, `@AppUserId`, `@TerminalLocationId` | Opens a pause. Rejects if open pause already exists for this `(LotId, LocationId)` per B3. `Lot_AssertNotBlocked`. | `Status, Message, NewId` |
| `Lots.LotPause_Resume` | `@PauseEventId`, `@ResumedRemarks NVARCHAR(500) NULL`, `@AppUserId`, `@TerminalLocationId` | Closes the pause. Rejects if already resumed. Resumer MAY be different from pauser. | `Status, Message` |
| `Lots.LotPause_GetByLocation` | `@LocationId BIGINT` | Returns all open pauses at a Cell — drives Paused-LOT indicator detail list. | Rowset: `LotId, LotName, ItemId, ItemCode, PausedAt, PausedByUserId, PausedReason` |
| `Lots.LotPause_GetCountsByLocation` | `@LocationId BIGINT` | Single integer — open-pause count for the Paused-LOT indicator badge. | Single row: `OpenPauseCount INT` |

## Gateway Scripts

None new in Phase 2 — all writes are operator-initiated through Perspective.

## Perspective Views

| View | Purpose |
|---|---|
| LOT Detail | Header + piece count + status + Tool/Cavity (Die Cast LOTs) + parents/children genealogy + history tab + paused-at list. Read-mostly; field edits via `Lot_Update`. |
| LOT Search | Filterable list of LOTs by Item, Location, Status. Calls `Lot_List`. |
| Genealogy Viewer | Visual tree from `Lot_GetGenealogyTree`. Closure-table-backed if B4. |
| Paused-LOT Indicator (cross-cutting) | Embedded on every workstation Perspective view. Shows open-pause count for the operator's Cell; tap opens detail list. |

## Test Coverage

New test suite at `sql/tests/0015_PlantFloor_Lot_Lifecycle/`:

| File | Covers |
|---|---|
| `010_Lot_Update.sql` | Field-level changes audit; row-version conflict; blocked-LOT rejection; B5 materialized recalculation. |
| `020_Lot_Split.sql` | N-way split; sum-exceeds-parent rejection; closure rows inserted (B4); parent reduced/closed correctly. |
| `030_Lot_Merge.sql` | Same-Item/same-Tool merge succeeds; cross-Tool with rank-compat=1 succeeds; cross-Tool with rank-compat=0 rejects; supervisor override path; merged LOT carries NULL Tool/ToolCavity. |
| `040_LotGenealogy_RecordConsumption.sql` | Consumption genealogy + closure rows; multi-source consumption. |
| `050_Lot_GetGenealogyTree.sql` | Ancestors / Descendants / Both; depth bound (B8); closure-vs-CTE result equivalence (when B4). |
| `060_LotPause_lifecycle.sql` | Place + resume; double-place rejection (B3); cross-Cell concurrent pauses allowed; resumer ≠ pauser. |
| `065_LotPause_indicator.sql` | `_GetCountsByLocation` returns correct open count; `_GetByLocation` returns correct list ordered by `PausedAt`. |
| `070_Label_print_reprint.sql` | Initial print; reprint with reason; ZPL content rendered. |

Target: 90–120 passing tests in suite 0015.

## Phase 2 complete when

- [ ] Migration `0015_arc2_phase2_lot_lifecycle.sql` applied. `PauseEvent` CREATEd; `v_LotDerivedQuantities` view CREATEd (or skipped if B5 elected).
- [ ] All Phase 2 procs (Lot mutation expansion, genealogy traversal, pause lifecycle, label print/reprint) delivered.
- [ ] All tests in `sql/tests/0015_PlantFloor_Lot_Lifecycle/` pass.
- [ ] Perspective views: LOT Detail, LOT Search, Genealogy Viewer, Paused-LOT Indicator implemented.
- [ ] Phase 3+ stations can call `Lot_Split`, `Lot_Merge`, `LotGenealogy_RecordConsumption`, `LotLabel_Print`, `LotPause_Place`, `LotPause_Resume`, `Lot_GetGenealogyTree` against the delivered contract.

---

# Phase 3 — Die Cast Operator Station

**Goal:** Deliver the Die Cast workflow — LOT creation against an active Tool/Cavity, cumulative-checkpoint ProductionEvent capture, RejectEvent capture for early scrap, and PLC-driven downtime detection ingestion (the proc layer; PLC integration itself is Phase 6 territory).

**Dependencies:** Phase 1 (foundation), Phase 2 (LOT lifecycle).

**Status:** Blocked on Phases 1–2.

## Data Model Changes

**Migration `sql/migrations/versioned/0016_arc2_phase3_die_cast.sql`** (next unclaimed).

- Seed `Parts.OperationTemplate` rows for `DieCastShot` with the appropriate `OperationTemplateField` entries (no `DieIdentifier` / `CavityNumber` / `WarmupShotCount` — Tool/Cavity on Lot per B13; warm-up on `DowntimeEvent` per UJ-14).
- Seed `Audit.LogEventType` rows: `DieCastCheckpointRecorded`, `RejectEventRecorded` (if not already seeded).
- No new tables; no schema changes.

**Tables used:** `Lots.Lot`, `Workorder.ProductionEvent`, `Workorder.ProductionEventValue`, `Workorder.RejectEvent`, `Quality.DefectCode`, `Tools.Tool`, `Tools.ToolCavity`, `Tools.ToolAssignment`.

## Open Items Affecting This Phase

| Item | Status |
|---|---|
| **A4** ShotCount semantics | Pending Phase 0 — cumulative counter (default) vs derived from aggregated LOT quantities. Phase 3 ships with cumulative; reframe is post-Phase-3 if MPP elects derived. |
| OI-09 cavity-parallel LOTs | ✅ Closed. N cavities → N peer LOTs (not sublots). Each LOT has its own `ToolCavityId`. |
| UJ-11 paper-to-screen | ✅ Closed (Option A — flagged risk). Couples to OI-31 rollout shape. |
| UJ-14 warm-up shots | ✅ Closed (Option A). `DowntimeEvent.ShotCount` only — no `ProductionEventValue.WarmupShotCount`. |
| OI-10 tool life | ✅ Superseded by Phase B Tools (Phase G of Arc 1). Tool identity and history live in `Tools` schema; shot counts derive from `ProductionEvent`. |

## State & Workflow

### Cavity-parallel LOTs at Die Cast

A multi-cavity die produces **N parallel independent LOTs, not sublots.** Each cavity's basket is a peer LOT with its own `ToolCavityId` set at creation (FDS-05-034). Each LOT has its own piece count, fills at its own rate, closes independently. There is no parent/child FK between cavity peers — `LotGenealogy` is flat at Die Cast. One LTT label per LOT.

Sub-LOT splitting is a separate concept that fires at **Machining OUT** (per FDS-05-009 / Phase 5) — it splits a machined LOT across downstream destinations on lines that sublot, and is unrelated to die cavities.

### Die Cast LOT creation walkthrough

Die Cast terminals are typically **Shared** — parented to a Die Cast Area or Die Cast WorkCenter rather than a single press. One terminal serves multiple presses; the operator selects the active Cell context (the specific press they're logging a basket for) by scan or dropdown per FDS-02-009. The walkthrough below assumes the Shared model; if a deployment chooses to dedicate a terminal to a single press (Cell-parented), the Cell-context-selection step is omitted and the Cell auto-resolves from the terminal's parent.

1. The operator approaches a Shared Die Cast terminal. Initials are not pre-populated (Shared terminals prompt per-action per FDS-04-009).
2. The operator selects the active Cell context (scan a press barcode or pick from a dropdown of presses descendant of the terminal's parent). Selection writes to `session.custom.terminal.activeCellLocationId` and persists until the operator changes it.
3. A die is mounted on the selected press. The active `Tools.ToolAssignment` row for that Cell points at it. As the shift runs, castings drop into per-cavity baskets beside the press.
4. When a cavity's basket fills, the operator peels a pre-printed LTT barcode label off the stack (per FRS 2.2.1) and sticks it on the basket. The operator walks to the terminal, enters initials inline on the LOT-creation screen (Shared-terminal pattern), and scans the LTT.
5. Perspective opens the LOT creation form. The **Cell** is the active context selected in step 2. The **Tool** field pre-populates from `Tools.ToolAssignment_ListActiveByCell(@SelectedCellLocationId)`. The operator confirms.
6. If the physical die has been swapped without the MES being updated, the operator hits **Edit** — an AD elevation prompt fires per FDS-04-007, a supervisor authenticates, the inline `Tools.ToolAssignment_Release` + `_Assign` correct the system of record in one transaction, and the Tool field updates.
7. The operator picks the cavity from the cavity dropdown (filtered to active cavities on the mounted Tool via `Tools.ToolCavity_ListActiveByTool`), confirms piece count, and submits.
8. Perspective calls `Lots.Lot_Create` with the `@ItemId` (the cast/trim Item produced at this press, looked up from the Tool's configuration), `@LotOriginTypeId = 'Manufactured'`, `@CurrentLocationId = (selected Cell's Id)`, `@PieceCount`, `@ToolId`, `@ToolCavityId`, `@AppUserId`, `@TerminalLocationId`.
9. Proc validates per FDS-05-034: Item eligible at the selected Cell (`v_EffectiveItemLocation` Direct ∪ BomDerived), piece count ≤ `Parts.Item.MaxLotSize` (`PartsPerBasket`), Tool mounted on Cell, Cavity belongs to Tool, Cavity `Active`.
10. Proc mints `LotName` via `IdentifierSequence_Next @Code='Lot'` (e.g., `MESL1710935`).
11. Proc inserts `Lots.Lot`, `Lots.LotStatusHistory` (initial `Good`), and (if B4) the closure self-row.
12. Proc writes a first **checkpoint `ProductionEvent`** for this LOT — `EventAt = SYSUTCDATETIME()`, `LotId`, `OperationTemplateId = DieCastShot`, cumulative `ShotCount` and `ScrapCount` for the cavity at this moment, `AppUserId`, `TerminalLocationId`. No `LocationId`, no `ItemId`, no `DieIdentifier`, no `CavityNumber` (all derivable from the LOT's FKs per B14).
13. Audit `LotCreated` + `DieCastCheckpointRecorded`. Print LTT label via `LotLabel_Print` (Phase 2).

A second cavity's basket fills on its own rhythm and is logged separately as a peer LOT — different `LotName`, different `ToolCavityId`, different LTT. **Cavity-parallel LOTs are peers, not sublots.** They share a Tool but nothing else. Each fills, closes, and moves independently via an explicit "Complete + Move" when the basket leaves the press (Phase 4 Movement Scan pattern).

### Die Cast warm-up shots (UJ-14 closed)

Warm-up shots are tracked as a **downtime sub-category**, not as production. `Oee.DowntimeEvent.ShotCount` carries the warm-up shot count when `DowntimeReasonType = Setup`. Warm-up shots are not entered on the LOT creation screen — they're recorded against the prior downtime event (machine startup). Good production shots count toward `ProductionEvent.ShotCount` cumulative.

### Tool life tracking (OI-10 superseded)

Tool identity, cavity status (`Active` / `Closed` / `Scrapped`), and check-in/out history live in the `Tools` schema (delivered in Arc 1 Phase G). Shot counts derive from `ProductionEvent` filtered by `Lot.ToolId` / `Lot.ToolCavityId`. There is no per-Tool live counter column — derivation is the system of record. Tool-life threshold alarms remain **FUTURE** — delivered later via a scheduled Gateway Script that reads the derived shot counts.

### Reject capture at Die Cast

The operator enters reject events against the current LOT — defect code (e.g., `DC-POR-01 Porosity`), quantity, optional remarks. Per FRS Section 4, reject/scrap data is retained for analysis but is not part of the permanent production record in the same way good counts are — MPP MAY elect not to record rejects at every step. Phase 3 delivers the proc; the operator decides per-LOT.

### Downtime entry at Die Cast

A press stops; the operator logs the event via the Phase 8 Downtime Entry view — selects machine, reason code (e.g., `EQ-DIE-STICK`), start time, end time. If the PLC detected the stop first, the `DowntimeEvent` would have been created automatically with `source=PLC` and a NULL reason; the operator just assigns the reason code (per B7 — late-binding reason codes). Phase 3 doesn't deliver downtime procs — that's Phase 8.

## API Layer (Named Queries → Stored Procedures)

| Procedure | Parameters | Notes | Dependencies | Output |
|---|---|---|---|---|
| `Workorder.ProductionEvent_Record` | `@LotId`, `@OperationTemplateId`, `@WorkOrderOperationId NULL`, `@EventAt`, `@ShotCount NULL`, `@ScrapCount NULL`, `@WeightValue NULL`, `@WeightUomId NULL`, `@DataCollectionValuesJson NULL`, `@AppUserId`, `@TerminalLocationId`, `@Remarks NULL` | Inserts a checkpoint event. Validates `Lot_AssertNotBlocked`. **If B5:** updates `Lot.TotalInProcess` / `InventoryAvailable`. Returns `NewId`. | `Workorder.ProductionEvent`, `Workorder.ProductionEventValue`, `Lots.Lot`, `Lots.Lot_AssertNotBlocked`, `Audit.Audit_LogOperation` | `Status, Message, NewId` |
| `Workorder.RejectEvent_Record` | `@LotId`, `@DefectCodeId`, `@Quantity`, `@ChargeToArea NULL`, `@Remarks NULL`, `@AppUserId`, `@TerminalLocationId` | Inserts a reject event. Independent of ProductionEvent (rejects can fire any time). | `Workorder.RejectEvent`, `Quality.DefectCode`, `Audit.Audit_LogOperation` | `Status, Message, NewId` |
| `Tools.ToolAssignment_ListActiveByCell` | `@CellLocationId BIGINT` | Returns active Tool assigned to this Cell (zero or one row in MVP for Die Cast — known limitation: filtered UNIQUE on Cell prevents multi-Tool Cells, fine for Die Cast / not for Machining cells with multiple cutters; revisit post-MVP). | `Tools.ToolAssignment` | Single row or empty |
| `Tools.ToolCavity_ListActiveByTool` | `@ToolId BIGINT` | Returns active cavities for a Tool. | `Tools.ToolCavity` | Rowset |

## Gateway Scripts

| Script | Purpose | Trigger |
|---|---|---|
| `DieCastCycleReader` (per-press) | Reads PLC `CycleComplete` edge, increments a per-Cavity in-memory shot counter that Perspective queries when the operator opens the LOT creation screen (informs `@ShotCount` parameter). Optional — operator can override. | PLC tag edge (TOPServer) |

## Perspective Views

| View | Purpose |
|---|---|
| Die Cast LOT Entry (purpose-built top-level view) | Composes the Cell Context Selector (Shared terminals — selects active press), Per-Mutation Initials Field, and Die-Cast-specific form (Tool pre-populated from active assignment with elevated Edit, Cavity dropdown filtered to active cavities, piece count + weight inputs). Submits `Lot_Create` + first `ProductionEvent_Record`. Inline reject entry triggers `RejectEvent_Record`. Embedded Paused-LOT Indicator surfaces any paused LOTs for the active Cell. |

**No separate Die Cast LOT Detail view.** After submit, navigation routes to the polymorphic Phase 2 `LOT Detail` view (parameterized by the new `LotId`). That view conditionally renders Tool / Cavity rows when populated — which they are for Die Cast–origin LOTs — and skips them for other origins. One LOT Detail surface across the entire plant.

## Test Coverage

New test suite at `sql/tests/0016_PlantFloor_DieCast/`:

| File | Covers |
|---|---|
| `010_ProductionEvent_Record.sql` | Checkpoint insertion; LAG-derived deltas equal cumulative diff; missing required params reject; blocked-LOT rejection; B5 materialized column updates. |
| `020_RejectEvent_Record.sql` | Insertion; defect code FK validation; quantity must be positive. |
| `030_DieCast_walkthrough.sql` | End-to-end scenario: ToolAssignment lookup against a selected Cell → Lot_Create with Tool/Cavity → first ProductionEvent → second ProductionEvent at later time → LAG delta correct. |
| `040_CavityParallel_peers.sql` | Two LOTs created on the same Tool, different Cavities, no parent-child FK; each closes independently. |

Target: 50–70 passing tests in suite 0016.

## Phase 3 complete when

- [ ] Migration `0016_arc2_phase3_die_cast.sql` applied. OperationTemplate seeds in place. LogEventType seeds in place.
- [ ] `ProductionEvent_Record` and `RejectEvent_Record` procs delivered with checkpoint shape (no `GoodCount` / `NoGoodCount` parameters).
- [ ] `ToolAssignment_ListActiveByCell` and `ToolCavity_ListActiveByTool` procs delivered.
- [ ] All tests in `sql/tests/0016_PlantFloor_DieCast/` pass (target 50–70).
- [ ] Perspective Die Cast LOT Entry view implemented with Tool auto-populate + elevated Edit + Cavity dropdown.
- [ ] Gateway `DieCastCycleReader` implemented (optional — operator override path covers if not yet wired).
- [ ] **End-to-end integration check:** an operator at a Shared Die Cast terminal selects a press as Cell context, creates a Cavity-A LOT, then later creates a Cavity-B LOT on the same press; both peer LOTs exist with their respective `ToolCavityId`; first `ProductionEvent` written for each with cumulative `ShotCount`; one reject event recorded; LTT labels printed; navigation to Phase 2 `LOT Detail` shows Tool/Cavity rendered correctly.

---

# Phase 4 — Movement + Trim + Receiving

**Goal:** Deliver the cross-cutting Movement Scan pattern that every downstream operator station reuses, the Trim Shop checkpoint workflow (LOT keeps cast-part identity through Trim — yield loss only; tracked at **Area** resolution: check-in → process → check-out), the **Trim OUT 1:1 whole-LOT move** to the destination Machining line (FDS-06-006 — no split at Trim; sub-LOT splitting moved to Machining OUT / Phase 5 per FDS-05-009), and the Receiving Dock pass-through-part flow.

**Dependencies:** Phase 1 (foundation), Phase 3 (`ProductionEvent_Record`). (No longer depends on Phase 2 `Lot_Split` — Trim OUT moves the LOT whole; the split moved to Phase 5.)

**Status:** Blocked on Phases 1–3.

## Data Model Changes

**Migration `sql/migrations/versioned/0017_arc2_phase4_movement_trim_receiving.sql`** (next unclaimed).

- Seed `Parts.OperationTemplate` rows for `TrimIn`, `TrimOut`, `ReceivingScan` with appropriate `OperationTemplateField` entries. `TrimOut` is a whole-LOT move — it carries no split flag (the `RequiresSubLotSplit` column now lands in Phase 5's migration `0018` on the `MachiningOut` template).
- Seed `Audit.LogEventType` rows: `LotMoved`, `TrimCheckpointRecorded`, `TrimOutRecorded`, `ReceivingScanRecorded` (where missing).
- No new tables. No schema additions (the `RequiresSubLotSplit` ALTER moved to Phase 5 / migration `0018`).

**Tables used:** `Lots.Lot`, `Lots.LotMovement`, `Workorder.ProductionEvent`, `Workorder.RejectEvent`, `Parts.OperationTemplate`, `Parts.v_EffectiveItemLocation`, `Parts.Item.MaxParts` (OI-12 cap), `Location.LocationAttribute` (`LinesideLimit`). (No `Lots.LotGenealogy` / closure writes in Phase 4 — Trim OUT moves the LOT whole; genealogy split edges are written in Phase 5 at Machining OUT.)

## Open Items Affecting This Phase

| Item | Status |
|---|---|
| **OI-11** Casting → Trim part-identity rename | ✅ Superseded — rename moved to Trim → Machining (FDS-05-033 v0.11m). Trim Shop is yield loss only, no rename. |
| **OI-12** `MaxParts` per-Item per-Location cap | ✅ Closed. Movement Scan validates incoming quantity against `Parts.Item.MaxParts` at the destination Cell. |
| **OI-18** ItemLocation hierarchy cascade | ✅ Closed. `Parts.v_EffectiveItemLocation` (Direct ∪ BomDerived per FDS-02-012) walks Cell → WorkCenter → Area → Site at scan-in. |
| **UJ-03** Sub-LOT split trigger | ➡️ Moved to Phase 5. The split no longer fires at Trim OUT — Trim OUT is a whole-LOT move. The `RequiresSubLotSplit` flag and the split UX live on the `MachiningOut` template (Phase 5). See Phase 5's Open Items table for the current UJ-03 status. |

## State & Workflow

### Movement Scan Screen — reusable pattern (LOT inbound)

Every operator station that **receives** a scanned LOT-in uses the same Movement Scan pattern. This is the inbound flow. Outbound flows (Trim OUT, Machining OUT) are described in their own sections below — they are NOT part of Movement Scan.

1. Operator scans LTT at the destination terminal.
2. Perspective calls `Lots.Lot_Get` with `@LotName` for header data.
3. Perspective calls `Parts.ItemLocation_CheckEligibility(@ItemId, @CellLocationId)` (which reads `v_EffectiveItemLocation` Direct ∪ BomDerived). On reject, surface the FDS-02-012 reject message: *"Part {PartNumber} is not configured for {CellCode} and is not a component of any part eligible there."*
4. Perspective calls `Parts.Item_GetMaxParts(@ItemId)` and `Lots.Lot_GetCellLineQuantity(@CellLocationId, @ItemId)` (sums existing pieces of this Item at this Location across all open LOTs). If `existing + incoming > MaxParts`, reject with OI-12 message.
5. On accept: `Lots.Lot_MoveTo` writes the `LotMovement` row.
6. Phase-specific follow-on **on the inbound side**: Trim IN writes a checkpoint `ProductionEvent`; Machining IN (Phase 5) does NOT use this Movement Scan pattern at all — Machining IN is FIFO pick + BOM-driven rename, not scan-to-receive; Receiving creates the LOT via `Lot_Create` rather than moving an existing LOT. Outbound flows that complete an operation and route LOT(s) to the next station live in their own sections (Trim OUT below; Phase 5 Machining OUT is fully PLC-driven).

### Trim Shop — Trim IN (checkpoint + yield loss)

A LOT arrives at the Trim Shop and an operator scans the LTT.

1. Movement Scan pattern fires `Lot_MoveTo` from the upstream Die Cast Cell to the **Trim Shop Area** (Trim is tracked at Area resolution — check-in → process → check-out, not at line or cell level).
2. The scan also triggers a **checkpoint `ProductionEvent`** with `OperationTemplateId = TrimIn`, `EventAt = SYSUTCDATETIME()`, cumulative `ShotCount` (carries forward — Trim doesn't add shots) and `ScrapCount` (carries forward). Because this is the LOT's second event, deltas pop out from `LAG()` at read time.
3. The operator runs sprue removal, deburr, wash. If the basket needs a piece-count correction (weight-based estimation per FRS 2.2.3), the operator updates via `Lot_Update` (Phase 2) — `LotAttributeChange` records the before/after.
4. If sprue/deburr/wash yields scrap, the operator records `RejectEvent_Record` (Phase 3) on the same LOT — the LOT still carries its cast/trim Item identity; trim is yield loss, not a rename. There is no `ConsumptionEvent`, no new LOT, no genealogy edge from Trim work itself.

### Trim OUT — outbound flow (1:1 whole-LOT move)

When the operator completes Trim work and triggers Trim OUT, the LOT moves **whole** to its destination Machining line — Trim OUT does **not** split (sub-LOT splitting moved to Machining OUT / Phase 5 per FDS-05-009). The operator selects a single destination by **scan or dropdown** (per FDS-02-009), or routing supplies it where the line's Operation Template defines it.

1. Operator selects the destination Machining line (scan or dropdown).
2. On confirm, Perspective calls `Workorder.TrimOut_Record`:
   - Writes a closing `ProductionEvent` with `OperationTemplateId = TrimOut` and the final cumulative counters.
   - Calls `Lots.Lot_MoveTo` from the Trim Shop Area to the destination — this places the whole LOT in that line's FIFO queue (read by Phase 5 Machining IN via `Lot_GetWipQueueByLocation`).
   - The parent LOT stays whole and open — no split, no children, no genealogy edge, no closure-table additions.
   - Audit `TrimOutRecorded`.
3. The LOT retains its cast/trim `ItemId` until the rename at Machining IN (FDS-05-033).

There is no multi-destination / Flex-Repeater UX at Trim OUT in this model — that machinery now lives at Machining OUT (Phase 5), driven by the `RequiresSubLotSplit` flag on the `MachiningOut` Operation Template.

### Receiving Dock — pass-through parts

A truck delivers 6MA Cam Holder housings (pass-through — MPP doesn't manufacture). The Receiving operator scans the packing slip on a Receiving terminal:

1. Perspective opens the Receiving screen. Inputs: `@PartNumber` (resolves to `@ItemId`), `@VendorLotNumber`, `@PieceCount`.
2. Perspective calls `Lots.Lot_Create` with `@LotOriginTypeId = 'Received'`, `@CurrentLocationId = (Receiving Dock's Id)`, NULL Tool/Cavity (non-die-cast), `@VendorLotNumber`. Mints the LOT.
3. LTT label prints. The received LOT is identical to a manufactured LOT downstream — same movement, hold, consumption, genealogy. Difference is `LotOriginType = 'Received'`.

Per FRS 5.6.1 and Scope Matrix row 3, receiving pass-through parts is MVP. Full operational workflows (receiving inspection, vendor lot verification, staging procedures specific to pass-through) are FUTURE — the schema supports them; the Perspective screens beyond basic Receiving are deferred.

### Supplier-identified serial ranges

Some pass-through parts arrive with vendor-issued serial number ranges (e.g., PNA mounting pins). Phase 4 Receiving captures `@MinSerialNumber` and `@MaxSerialNumber` on `Lot_Create` — Phase 6 Assembly's `ConsumptionEvent` validates that consumed serials fall within the LOT's range.

## API Layer (Named Queries → Stored Procedures)

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Parts.ItemLocation_CheckEligibility` | `@ItemId`, `@CellLocationId` | Reads `v_EffectiveItemLocation`. Returns `IsEligible BIT` + the matching path (`Direct` / `BomDerived` / NULL). | Single row |
| `Parts.Item_GetMaxParts` | `@ItemId` | Returns `MaxParts INT NULL` for the Item. | Single row |
| `Lots.Lot_GetCellLineQuantity` | `@CellLocationId`, `@ItemId` | Sums existing pieces of this Item at this Location across all open LOTs. Used by Movement Scan to validate against `MaxParts`. | Single row |
| `Workorder.TrimOut_Record` | `@ParentLotId`, `@OperationTemplateId`, `@ShotCount`, `@ScrapCount`, `@DestinationCellLocationId`, `@AppUserId`, `@TerminalLocationId` | Writes the closing Trim `ProductionEvent`, then calls `Lot_MoveTo` once to move the **whole** LOT to the destination Machining line. No split — single transaction, whole-LOT move only. (Splitting moved to `MachiningOut_Record` in Phase 5.) | Single row: `Status, Message, ProductionEventId` |
| `Lots.Lot_GetWipQueueByLocation` | `@LocationId BIGINT`, `@IncludeDescendants BIT = 0` | Returns the LOTs at the given location in arrival order (`LastMovementAt ASC`). Used by Phase 5 Machining IN to display FIFO queue. | Rowset |

## Gateway Scripts

| Script | Purpose | Trigger |
|---|---|---|
| `LttZplDispatcher` | Receives `system.util.sendMessage` events from `LotLabel_Print` (Phase 2) — assembles ZPL from a template + dispatches to the Zebra at the operator's terminal. Updates the `LotLabel` row with print-ack timestamp. | Gateway message handler |

## Perspective Views

| View | Purpose |
|---|---|
| Movement Scan (cross-cutting embedded component) | Embedded pattern reused in every station that **receives** LOTs (Trim IN, Receiving — though Receiving uses `Lot_Create`, not `Lot_MoveTo`). Validates eligibility + MaxParts; calls `Lot_MoveTo`. |
| Trim Station IN (purpose-built top-level view) | Composes Movement Scan + Per-Mutation Initials Field + checkpoint `ProductionEvent` write + reject capture. Embedded Paused-LOT Indicator. |
| Trim Station OUT (purpose-built top-level view) | Composes a closing `ProductionEvent` write + a single destination selector (scan or dropdown) + `TrimOut_Record` (whole-LOT move). No split UX — one destination, one submit. (The multi-destination Flex-Repeater split UX moved to Phase 5's Machining OUT view.) |
| Receiving Dock (purpose-built top-level view) | LOT creation from packing-slip data — `Lot_Create` with `LotOriginType='Received'`. Captures vendor lot number + supplier-issued serial range. |

After submit, navigation from any Trim view routes to the polymorphic Phase 2 `LOT Detail` view for the moved/split LOT(s).

## Test Coverage

New test suite at `sql/tests/0017_PlantFloor_Movement_Trim/`:

| File | Covers |
|---|---|
| `010_ItemLocation_CheckEligibility.sql` | Direct match; BomDerived match; cascade Cell → WorkCenter → Area; ineligible (no path) rejects with FDS-02-012 message. |
| `020_Item_GetMaxParts_and_Lot_GetCellLineQuantity.sql` | MaxParts read; sum-by-Cell-by-Item correct across multiple open LOTs; deprecated LOTs excluded. |
| `030_Movement_Scan_pattern.sql` | Eligible move succeeds + LotMovement row + checkpoint ProductionEvent (Trim); MaxParts overflow rejects with OI-12 message. |
| `040_TrimOut_Record_move_whole.sql` | `TrimOut_Record` moves the whole LOT to the destination Machining line; closing `ProductionEvent` written; `LotMovement` row written; LOT visible in that line's FIFO queue; parent stays open — no split, no children, no closure rows. |
| `050_TrimOut_Record_validation.sql` | Missing destination rejects; non-Machining destination rejects (eligibility check); blocked LOT rejects via `Lot_AssertNotBlocked`. |
| `070_Receiving_pass_through.sql` | Lot_Create with `LotOriginType = 'Received'`; vendor lot number captured; serial range captured. |

(Sub-LOT split tests — multi-way split, split-to-same-cell, flag-mismatch — moved to Phase 5 suite `0018`, where the split now lives.)

Target: 55–75 passing tests in suite 0017.

## Phase 4 complete when

- [ ] Migration `0017_arc2_phase4_movement_trim_receiving.sql` applied. OperationTemplate seeds in place. LogEventType seeds in place.
- [ ] Movement Scan pattern delivered (helper procs + Perspective component).
- [ ] `TrimOut_Record` proc delivered — whole-LOT move to the destination Machining line (no split).
- [ ] `Lot_GetWipQueueByLocation` delivered (consumed by Phase 5).
- [ ] All tests in `sql/tests/0017_PlantFloor_Movement_Trim/` pass (target 55–75).
- [ ] Perspective Movement Scan, Trim Station IN, Trim Station OUT (whole-LOT move), Receiving Dock views implemented.
- [ ] Gateway `LttZplDispatcher` implemented and tested against Zebra emulator + real Zebra at the dev Trim terminal.
- [ ] **End-to-end integration check:** A LOT created in Phase 3 moves to Trim → Trim IN checkpoint event written → Trim OUT moves the whole LOT to one Machining line → LOT visible in that line's FIFO queue via `Lot_GetWipQueueByLocation` (no split at Trim — the sub-LOT split is exercised in Phase 5).

---

# Phase 5 — Machining

**Goal:** Deliver the Machining workflow — FIFO pick at Machining IN (whole cast/trim LOTs from Trim OUT) with the BOM-driven part-identity rename (FDS-05-033); the Machining OUT split-or-auto-move branch (FDS-06-008 + FDS-05-009) — an operator-initiated **sub-LOT split** on sublotting lines (those with a dedicated Machining OUT terminal, `RequiresSubLotSplit=1`), and PLC-driven auto-completion with auto-move to the coupled Assembly Cell on non-sublotting coupled lines; and reject capture for out-of-tolerance pieces. Machining OUT therefore has an operator screen **only** on sublotting lines; coupled lines remain fully event-driven with no operator OUT screen.

**Dependencies:** Phase 1 (foundation), Phase 2 (`Lot_Split` — now consumed here for the Machining OUT split — + `LotGenealogy_RecordConsumption`), Phase 3 (`ProductionEvent_Record`, `RejectEvent_Record`), Phase 4 (Trim OUT places **whole** cast/trim LOTs into this phase's FIFO queues; `Lot_GetWipQueueByLocation` is the queue read).

**Status:** Blocked on Phases 1–4.

## Data Model Changes

**Migration `sql/migrations/versioned/0018_arc2_phase5_machining.sql`** (next unclaimed).

- **ALTER `Parts.OperationTemplate` ADD `RequiresSubLotSplit BIT NOT NULL DEFAULT 0`** — controls the **Machining OUT** outbound flow (relocated here from Phase 4 per FDS v1.3 / Phased Plan v1.1). When `1`, the line sublots: the Machining OUT screen presents the multi-destination split UX (one sub-LOT per destination). When `0` (default), the line does not sublot — Machining OUT is the PLC-driven auto-move (coupled) or manual whole-move (uncoupled). Versioned per the existing OperationTemplate clone-to-modify pattern. Engineering authors per Item per Cell via the Configuration Tool; the physical correlate is whether the line has a dedicated Machining OUT terminal.
- Seed `Parts.OperationTemplate` rows for `MachiningIn` and `MachiningOut` with the appropriate `OperationTemplateField` entries (cycle time, fixture, program — final list confirmed during Phase 0 A5 walkthrough alongside `DefaultScreen` / `ConfirmationMethod` seeding). Initial `MachiningOut` seed rows carry `RequiresSubLotSplit = 1` for lines known to sublot; the rest default to `0` and Engineering edits per Item later.
- Seed `Audit.LogEventType` rows: `MachiningInPicked`, `MachiningOutCompleted`, `MachiningOutAutoMoved`, `MachiningOutSubLotSplit` (where missing).
- No new tables.

> **Data model follow-up flagged:** the `RequiresSubLotSplit BIT` column on `Parts.OperationTemplate` lands in this migration (moved from the Phase 4 plan). `MPP_MES_DATA_MODEL.md` still describes it (and `Item.DefaultSubLotQty`) under **Trim OUT** semantics — that reword to Machining OUT is a still-pending data-model revision (deferred 2026-06-03).

**Tables used:** `Lots.Lot`, `Workorder.ProductionEvent`, `Workorder.ConsumptionEvent`, `Workorder.RejectEvent`, `Lots.LotGenealogy` (+ `LotGenealogyClosure` if B4), `Lots.LotMovement`, `Parts.Bom`, `Parts.BomLine`, `Parts.OperationTemplate` (now with `RequiresSubLotSplit`), `Location.LocationAttribute` (`CoupledDownstreamCellLocationId` per FDS-06-008). Procs: `Lots.Lot_Split` (Machining OUT split), `Lots.Lot_MoveTo`.

## Open Items Affecting This Phase

| Item | Status |
|---|---|
| **A4** ShotCount semantics | Pending Phase 0 — affects Machining ProductionEvent contents same as Die Cast. |
| **OI-18** ItemLocation hierarchy cascade | ✅ Closed. `v_EffectiveItemLocation` Direct ∪ BomDerived applies at Machining IN — the cast/trim parent must be eligible at the Machining Cell (BomDerived path resolves through the machined-Item BOM whose child is the cast/trim Item). |
| **UJ-03** Sub-LOT split trigger | 🔶 In Review (Ben pending). Resolved structurally via `Parts.OperationTemplate.RequiresSubLotSplit` BIT on the `MachiningOut` template (this phase) — Engineering authors per Item per Cell whether Machining OUT splits or moves whole. The split fires at **Machining OUT** (per MPP, confirmed 2026-06), not Trim OUT. Machining IN consumes a **whole** cast/trim LOT and produces a renamed machined LOT one-to-one; the machined LOT is what gets split (if at all) at Machining OUT. Ben's remaining input is whether split-default-quantities need a per-Item override beyond the system-wide N=2 even-split default. |
| **FDS-06-008** Auto-move on completion | ✅ Closed. `CoupledDownstreamCellLocationId` LocationAttribute on the Machining Cell drives the auto-move target. NULL = legacy uncoupled path (operator-driven move via Phase 4 Movement Scan). |

## State & Workflow

### Machining IN — FIFO pick + BOM-driven rename

The operator at a Machining Cell terminal sees the Cell's FIFO queue — **whole** cast/trim LOTs that landed here at Trim OUT (Phase 4, 1:1 move) are visible in arrival order. **There is no scan-to-receive at Machining IN.** The pick + rename is the receive event.

1. Perspective calls `Lots.Lot_GetWipQueueByLocation @LocationId = (this Cell's Id)` — returns the LOTs ordered by `LastMovementAt ASC`.
2. The Machining IN view renders the queue. The operator picks the next entry (by tap or scan of the LTT for confirmation). Override of FIFO order is allowed — Perspective prompts for an optional "queue override reason" when a non-first entry is picked, captured to the resulting `ProductionEvent`'s `ProductionEventValue` rows.
3. On pick, the system applies the **BOM-driven part-identity rename** (FDS-05-033). The picked LOT carries the cast/trim Item (e.g., `5G0-TRIM-4102`); the active `Parts.Bom` for the machined Item (`5G0-MACHINED-4102`) has a single `BomLine` with `ChildItemId = 5G0-TRIM-4102` at `QtyPer = 1`.
4. Perspective calls `Workorder.MachiningIn_PickAndConsume` (composite proc):
   - Validates `Lot_AssertNotBlocked` on the picked LOT.
   - Validates eligibility — the picked LOT's Item must resolve via `v_EffectiveItemLocation` BomDerived path at this Cell (the cast/trim Item is eligible because it's a child line on the machined Item's BOM and the machined Item has Direct eligibility here).
   - Resolves the produced Item by BOM lookup — finds the active `Parts.Bom` whose only `BomLine` lists the picked LOT's Item as the child. (If multiple BOMs match — degenerate misconfiguration — proc raises with a clear message.)
   - Calls `Lots.Lot_Create` to mint the machined LOT under the produced Item with `LotOriginType='Manufactured'` (NULL Tool/Cavity — Tool/Cavity belong to die-cast LOTs only per B13). Mints a fresh `LotName` via `IdentifierSequence_Next`.
   - Calls `Lots.LotGenealogy_RecordConsumption` to insert the genealogy + closure rows linking source LOT → produced machined LOT.
   - Writes a `Workorder.ConsumptionEvent` row recording the per-piece consumption (source piece count = produced piece count for a 1-line BOM at QtyPer=1).
   - Writes a checkpoint `Workorder.ProductionEvent` for the new machined LOT with `OperationTemplateId = MachiningIn` and `EventAt = SYSUTCDATETIME()`.
   - Closes the source LOT (`Lot_UpdateStatus → Closed`) since all pieces have been consumed into the machined LOT.
   - Audit: `MachiningInPicked`.
5. Perspective prompts the operator to scan a fresh LTT for the new machined LOT. The label prints via `LotLabel_Print` (Phase 2).
6. The operator places the machined LOT in the machining setup and starts the cycle.

### Machining OUT — split (sublotting lines) or PLC auto-complete + auto-move (FDS-06-008 + FDS-05-009)

Machining OUT behavior is determined by the active `MachiningOut` OperationTemplate's `RequiresSubLotSplit` flag (physical correlate: whether the line has a dedicated Machining OUT terminal).

**Sublotting line — `RequiresSubLotSplit = 1` (operator-initiated split, per FDS-05-009):**

1. The operator completes the Machining operation and triggers Machining OUT at the line's Machining OUT terminal.
2. Perspective pre-fills the machined LOT's piece count and presents an auto-split preview — default N=2 even split (e.g., 48 → 24/24; 51 → 26/25). The operator MAY adjust the number of sub-LOTs and per-sub-LOT quantities; the total SHALL equal the parent's piece count.
3. A Flex Repeater renders N destination-selection rows — one per sub-LOT, each with its piece count + a destination selector (scan or dropdown per FDS-02-009). Routing MAY supply the destination set where the Operation Template defines it.
4. On confirm, Perspective calls `Workorder.MachiningOut_RecordSplit` with `@SplitChildrenJson` (`[{pieceCount, destinationLocationId}, ...]`):
   - Writes a closing `ProductionEvent` with `OperationTemplateId = MachiningOut` and the final cumulative counters.
   - Calls `Lots.Lot_Split` for the N children. Each child inherits the parent's **machined** Item (rename already happened at Machining IN per FDS-05-033) and is machining-origin (NULL Tool/Cavity per B13).
   - For each child, calls `Lots.Lot_MoveTo` from this Machining Cell to its destination.
   - Returns a multi-row result with each child's `LotName` for LTT printing.
   - Audit: `MachiningOutSubLotSplit`.
5. LTT labels print for each child sub-LOT — labels follow FDS-05-024 parent-reference rule (child `LotName` + parent `LotName` both shown).

**Non-sublotting line — `RequiresSubLotSplit = 0` (PLC-driven auto-complete, FDS-06-008):**

Machining OUT is **event-driven, not operator-initiated.** The operator does not scan, sign off, or interact with the MES at the moment of completion.

1. The Machining PLC asserts `OperationComplete` (or equivalent edge — final tag name confirmed during Phase 0 A5 / `OperationTemplate` field walkthrough).
2. The Gateway script `MachiningOpCompleteWatcher` (per-Cell) reads the edge and resolves the active machined LOT at this Cell from `Lots.Lot.CurrentLocationId`.
3. The Gateway script calls `Workorder.MachiningOut_AutoComplete @LotId, @CellLocationId, @AppUserId = (a "system" AppUser row reserved for PLC-driven actions), @TerminalLocationId = NULL`.
4. The proc:
   - Validates `Lot_AssertNotBlocked` on the machined LOT.
   - Writes a checkpoint `Workorder.ProductionEvent` with `OperationTemplateId = MachiningOut` and `EventAt = SYSUTCDATETIME()`.
   - Reads the `CoupledDownstreamCellLocationId` LocationAttribute on the Machining Cell.
   - **If `CoupledDownstreamCellLocationId` is non-NULL:** calls `Lots.Lot_MoveTo` from this Machining Cell to the coupled downstream Cell. Audit: `MachiningOutAutoMoved`.
   - **If `CoupledDownstreamCellLocationId` is NULL:** writes only the `ProductionEvent`. Audit: `MachiningOutCompleted`. The LOT stays at the Machining Cell awaiting an explicit operator-driven movement (legacy uncoupled path — the operator uses the Phase 4 Movement Scan to move the LOT manually).
5. The basket physically rolls to the coupled Cell (typically the paired Assembly Cell within the same WorkCenter). The Assembly Cell sees the machined LOT arrive in its queue without any operator action between Machining and Assembly.

(Coupling note: a sublotting line is configured with `CoupledDownstreamCellLocationId` NULL — its Machining OUT terminal drives the FDS-05-009 split rather than an auto-move. So `RequiresSubLotSplit = 1` lines are also uncoupled; the two settings are consistent, not independent knobs.)

### Reject capture at Machining

If parts come off out-of-tolerance during the cycle, the operator records `RejectEvent_Record` (Phase 3) against the machined LOT — defect code from a Machining-Area-filtered DefectCode picker (e.g., `MS-OOT-01 Dimensional`, `MS-TOOLMARK-02`), quantity, optional remarks. Reject capture is independent of the Machining OUT event — it can fire at any time during the cycle (before, during, after the OUT auto-complete).

### Rework LOTs

Machining may process a rework LOT returning from Phase 7's Sort Cage. Rework LOTs appear in the Cell's FIFO queue if their `CurrentLocationId` is this Machining Cell. No special handling — they look identical in the queue. The MachiningIn pick + rename mechanic still applies (rework consumes the rework LOT and produces a new machined LOT under the same Item, completing the second-pass genealogy).

## API Layer (Named Queries → Stored Procedures)

| Procedure | Parameters | Notes | Dependencies | Output |
|---|---|---|---|---|
| `Workorder.MachiningIn_PickAndConsume` | `@SourceLotId BIGINT`, `@CellLocationId BIGINT`, `@QueueOverrideReason NVARCHAR(500) NULL`, `@AppUserId`, `@TerminalLocationId` | Composite: validates eligibility + BOM lookup; mints machined LOT via `Lot_Create`; writes `ConsumptionEvent` + `LotGenealogy` (+ closure) + checkpoint `ProductionEvent`; closes source sub-LOT. Single transaction. | `Lots.Lot_Create`, `Lots.LotGenealogy_RecordConsumption`, `Lots.Lot_UpdateStatus`, `Workorder.ProductionEvent`, `Workorder.ConsumptionEvent`, `Parts.Bom`, `Parts.BomLine`, `v_EffectiveItemLocation`, `Audit.Audit_LogOperation` | `Status, Message, NewMachinedLotId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT` |
| `Workorder.MachiningOut_AutoComplete` | `@LotId BIGINT`, `@CellLocationId BIGINT`, `@AppUserId BIGINT`, `@TerminalLocationId NULL` | PLC-triggered on non-sublotting lines (`RequiresSubLotSplit=0`). Writes Machining OUT checkpoint `ProductionEvent` + reads `CoupledDownstreamCellLocationId` + auto-`Lot_MoveTo` if non-NULL. | `Workorder.ProductionEvent`, `Lots.Lot_MoveTo`, `Location.LocationAttribute`, `Audit.Audit_LogOperation` | `Status, Message, ProductionEventId, AutoMoved BIT, ToLocationId BIGINT NULL` |
| `Workorder.MachiningOut_RecordSplit` | `@ParentLotId BIGINT`, `@OperationTemplateId BIGINT`, `@SplitChildrenJson NVARCHAR(MAX)` (`[{pieceCount, destinationLocationId}, ...]`), `@AppUserId`, `@TerminalLocationId` | Operator-triggered on sublotting lines (`RequiresSubLotSplit=1`). Validates the JSON child count + that the sum equals the parent piece count; writes the closing `ProductionEvent`; calls `Lot_Split` for the N children; then `Lot_MoveTo` for each child to its destination. Single transaction. | `Lots.Lot_Split`, `Lots.Lot_MoveTo`, `Workorder.ProductionEvent`, `Lots.LotGenealogy`, `Audit.Audit_LogOperation` | Multi-row: header `Status, Message, ProductionEventId`; per-child row `(ChildLotId, ChildLotName, DestinationLocationId)` |

## Gateway Scripts

| Script | Purpose | Trigger | External System | Audit |
|---|---|---|---|---|
| `MachiningOpCompleteWatcher` (per Cell) | Watches PLC `OperationComplete` edge on each **non-sublotting** Machining Cell (`RequiresSubLotSplit=0`). On edge, resolves the active machined LOT and calls `MachiningOut_AutoComplete`. (Sublotting cells have no PLC auto-complete — their Machining OUT is operator-driven via `MachiningOut_RecordSplit`.) | PLC tag edge (TOPServer) | PLC | OperationLog via the proc's audit; InterfaceLog on every PLC read/write per B4 |
| `MachiningCycleReader` (optional, per Cell) | Reads PLC `CycleComplete` per individual cycle and stamps cumulative cycle-time onto the Machining IN ProductionEventValue. Optional — operator can enter cycle time manually if PLC doesn't expose the tag. | PLC tag edge | PLC | InterfaceLog on read |

## Perspective Views

| View | Purpose |
|---|---|
| Machining IN (purpose-built top-level view) | Composes the FIFO Queue list (Flex Repeater binding `Lot_GetWipQueueByLocation` → embedded view per queue entry: LotName, parent LotName, piece count, arrival time, "Pick" button) + Per-Mutation Initials Field + BOM-Driven Rename Confirmation Modal + Cell Context Selector (Shared terminals only) + Paused-LOT Indicator. Submit on Pick fires `MachiningIn_PickAndConsume`. |
| BOM-Driven Rename Confirmation Modal (cross-cutting embedded component) | Displays *"This LOT is {SourceItem}. Receive as {ProducedItem}?"* with Confirm / Cancel. Reusable across any phase that does BOM-driven rename. |
| Machining OUT Split (purpose-built top-level view — sublotting lines only) | Shown only on lines whose `MachiningOut` template has `RequiresSubLotSplit=1`. Auto-split preview (editable N + per-child piece counts) + a **Flex Repeater + Embedded View** of destination selectors (one row per sub-LOT). Single submit fires `MachiningOut_RecordSplit`. |
| Cell Selector Repeater Entity (cross-cutting embedded view) | The embedded view the Flex Repeater renders per row in Machining OUT Split (and any future view that picks N destinations). One sub-LOT row, one destination selector (scan or dropdown), one piece-count display. Pure composition — no business logic. (Moved here from Phase 4 with the split.) |

**No operator OUT screen on non-sublotting lines.** On coupled / uncoupled lines (`RequiresSubLotSplit=0`) Machining OUT is fully PLC-driven — operators see the machined LOT arrive at the coupled downstream Cell (typically Assembly) via that Cell's queue read; the Phase 2 `LOT Detail` view shows the full event timeline if needed. Sublotting lines (`RequiresSubLotSplit=1`) use the Machining OUT Split view above.

## Test Coverage

New test suite at `sql/tests/0018_PlantFloor_Machining/`:

| File | Covers |
|---|---|
| `010_MachiningIn_PickAndConsume_happy.sql` | Whole cast/trim LOT in queue → pick → BOM resolves machined Item → new machined LOT minted → ConsumptionEvent + genealogy (+ closure) + checkpoint event written → source LOT closed. |
| `020_MachiningIn_eligibility.sql` | BomDerived eligibility resolves through the machined Item's BOM; ineligible (no path) rejects with FDS-02-012 message. |
| `030_MachiningIn_BOM_lookup_edge_cases.sql` | Missing BOM rejects; multiple BOMs matching the source Item rejects with clear message; deprecated BOM not used. |
| `040_MachiningOut_AutoComplete_coupled.sql` | `RequiresSubLotSplit=0`, `CoupledDownstreamCellLocationId` non-NULL → ProductionEvent + LotMovement to coupled Cell; AutoMoved=1 returned. |
| `050_MachiningOut_AutoComplete_uncoupled.sql` | `RequiresSubLotSplit=0`, `CoupledDownstreamCellLocationId` NULL → ProductionEvent only, no LotMovement; AutoMoved=0 returned. |
| `060_MachiningOut_blocked_lot.sql` | Held LOT at Machining Cell → AutoComplete rejects via Lot_AssertNotBlocked. |
| `070_MachiningOut_RecordSplit.sql` | `RequiresSubLotSplit=1` — 2-way split into two destinations; child LOTs inherit the machined Item; `LotGenealogy` Split edges + closure rows; `LotMovement` per child; parent closed; children visible in their destination queues. |
| `075_MachiningOut_RecordSplit_same_destination.sql` | `RequiresSubLotSplit=1` — N children all routed to the same destination (legitimate edge case). |
| `080_MachiningOut_RecordSplit_validation.sql` | Sum-of-children ≠ parent rejects; missing destination rejects; blocked parent LOT rejects via `Lot_AssertNotBlocked`. |
| `090_Rework_LOT_in_queue.sql` | Rework LOT routed back to a Machining Cell from Sort Cage flows through the same MachiningIn pick + rename without special handling. |

Target: 80–110 passing tests in suite 0018.

## Phase 5 complete when

- [ ] Migration `0018_arc2_phase5_machining.sql` applied — including the `RequiresSubLotSplit` ALTER (moved from Phase 4). OperationTemplate seeds in place. LogEventType seeds in place.
- [ ] `MachiningIn_PickAndConsume` composite proc delivered.
- [ ] `MachiningOut_AutoComplete` PLC-trigger proc delivered.
- [ ] `MachiningOut_RecordSplit` operator-split proc delivered (sublotting lines).
- [ ] All tests in `sql/tests/0018_PlantFloor_Machining/` pass (target 80–110).
- [ ] Perspective Machining IN view implemented with FIFO Queue Repeater + BOM-Driven Rename Confirmation Modal.
- [ ] Perspective Machining OUT Split view implemented (Flex Repeater destination selectors) for sublotting lines.
- [ ] Gateway `MachiningOpCompleteWatcher` per-Cell implemented and tested against PLC `OperationComplete` edge in dev (non-sublotting cells).
- [ ] **End-to-end integration check (coupled path):** A Phase 4 Trim OUT whole-LOT move sends a LOT to a Machining Cell whose `CoupledDownstreamCellLocationId` points at a paired Assembly Cell. Operator picks from FIFO → BOM-driven rename produces machined LOT → cycle runs → PLC asserts OperationComplete → auto-complete writes ProductionEvent + auto-move to Assembly Cell. Operator never scans Machining OUT.
- [ ] **End-to-end integration check (uncoupled path):** Same flow, but with `CoupledDownstreamCellLocationId` NULL → auto-complete writes ProductionEvent only; LOT stays at Machining Cell; operator uses Phase 4 Movement Scan to move it manually.
- [ ] **End-to-end integration check (sublotting path):** A whole LOT picked + renamed at a `RequiresSubLotSplit=1` line → operator triggers Machining OUT → splits into two sub-LOTs routed to two destinations → LTT labels print → both sub-LOTs visible in their destination queues; genealogy shows the Split edges from the machined parent.

---

# Phase 6 — Assembly + MIP + Container Pack

**Goal:** Deliver the Assembly workflow (serialized lines with PLC/MIP handshake, non-serialized lines with operator-driven count entry), tray-level container closure with three peer methods (`ByCount` / `ByWeight` / `ByVision` per FDS-06-014), BOM-based material verification with supervisor override (UJ-09), per-Cell `ConfirmationMethod` resolver (UJ-17), HardwareInterlockBypassed flag capture (UJ-16), and atomic container completion claiming an AIM Shipper ID from the local pool (Phase 7 schema, claim path here per UJ-04).

**Dependencies:** Phase 1 (foundation), Phase 2 (LOT lifecycle + label print), Phase 3 (ProductionEvent + Reject), Phase 4 (Movement Scan for inbound lineside material; auto-coupled inbound from Phase 5 Machining), Phase 5 (machined LOTs auto-arrive). Phase 7's `AimShipperIdPool` schema CREATEs in Phase 7 — Phase 6 consumes via `_Claim` proc; the pool is filled by Phase 7's topup loop.

**Status:** Blocked on Phases 1–5 + Phase 7 schema CREATE (cross-phase dependency: Phase 6 calls `AimShipperIdPool_Claim` which lives in Phase 7's migration). Sequencing: Phase 7 ships its schema CREATE before Phase 6 ships its container-close proc, even though Phase 7's overall delivery follows Phase 6.

## Data Model Changes

**Migration `sql/migrations/versioned/0019_arc2_phase6_assembly.sql`** (next unclaimed).

**New tables (Container family — anchored here, consumed across Phases 6 + 7):**

- `Lots.Container` — header for a packaging unit. Columns: `Id BIGINT PK`, `ItemId BIGINT FK → Parts.Item.Id`, `ContainerConfigId BIGINT FK → Parts.ContainerConfig.Id`, `CurrentLocationId BIGINT FK → Location.Location.Id`, `ContainerStatusCodeId BIGINT FK → Lots.ContainerStatusCode.Id`, `OpenedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()`, `CompletedAt DATETIME2(3) NULL`, `CreatedByUserId BIGINT FK → AppUser.Id`, `RowVersion ROWVERSION`. Filtered indexes per OI-35 B8: `IX_Container_OpenByLocation (CurrentLocationId, OpenedAt) WHERE ContainerStatusCodeId IN (Open codes)`.
- `Lots.ContainerTray` — child of Container. Columns: `Id BIGINT PK`, `ContainerId BIGINT FK → Container.Id`, `TrayPosition INT NOT NULL`, `PartsClosedCount INT NOT NULL DEFAULT 0`, `ClosedAt DATETIME2(3) NULL`, `ClosedByUserId BIGINT FK → AppUser.Id NULL`, `ClosureMethod NVARCHAR(20) NULL` (`ByCount`/`ByWeight`/`ByVision` — captured from `Parts.ContainerConfig.ClosureMethod` at the moment of closure for audit). Filtered UNIQUE `(ContainerId, TrayPosition)`.
- `Lots.ContainerSerial` — junction: serial numbers in container tray positions. Columns: `Id BIGINT PK`, `ContainerId BIGINT FK → Container.Id`, `ContainerTrayId BIGINT FK → ContainerTray.Id NULL`, `SerializedPartId BIGINT FK → SerializedPart.Id`, `TrayPosition INT NULL`, `HardwareInterlockBypassed BIT NOT NULL DEFAULT 0` (UJ-16 Option A). Filtered indexes for serial lookups and per-Container drilldown.
- `Lots.SerializedPart` — the laser-etched part itself. Columns: `Id BIGINT PK`, `SerialNumber NVARCHAR(50) UNIQUE`, `ItemId BIGINT FK → Parts.Item.Id`, `ProducingLotId BIGINT FK → Lots.Lot.Id`, `EtchedAt DATETIME2(3) NOT NULL`, `EtchedByUserId BIGINT FK → AppUser.Id`. `SerialNumber` mints via `Lots.IdentifierSequence_Next @Code='SerializedItem'` per B15.

**Seeds:**

- `Parts.OperationTemplate` rows for assembly operations per Item — one set per serialized line (5G0 family) and one per non-serialized line (6B2, RPY, etc.). Final list confirmed during Phase 0 A5 walkthrough.
- `Audit.LogEntityType` rows: `Container`, `ContainerTray`, `ContainerSerial`, `SerializedPart`.
- `Audit.LogEventType` rows: `ContainerOpened`, `TrayClosed`, `ContainerCompleted`, `ContainerSerialAdded`, `MaterialSubstituteOverride` (UJ-09), `WorkOrderCompletionConfirmed` (FDS-06-028 / OI-16).

**Tables used (existing + new):** `Lots.Lot`, `Lots.LotGenealogy` (+ closure if B4), `Lots.LotMovement`, `Workorder.ConsumptionEvent`, `Workorder.ProductionEvent`, `Workorder.RejectEvent`, `Parts.Bom`, `Parts.BomLine`, `Parts.ContainerConfig` (`ClosureMethod`, `TraysPerContainer`, `PartsPerTray`), `Parts.Item.MaxParts` (lineside cap), `Location.LocationAttribute` (`ConfirmationMethod`, `RequiresCompletionConfirm`).

## Open Items Affecting This Phase

| Item | Status |
|---|---|
| **OI-16** PLC `CompletionConfirmed` BIT + `RequiresCompletionConfirm` LocationAttribute | ✅ Closed. Auto-finish gate per FDS-06-028 reads PLC `CompletionConfirmed` BIT (belt-and-suspenders alongside count-crosses-target); per-Terminal `RequiresCompletionConfirm` LocationAttribute (seeded in Phase 1) toggles the operator UX between large "Confirm Completion" button and passive popup. |
| **OI-33** AIM pool empty-pool hard-fail | 🔶 Pending Phase 0 customer validation. Default direction (current FDS-07-010a): hard-fail — `Container_Complete` rolls back on empty pool, line stops, operator sees error. Phase 6 ships against the default; if Phase 0 elects soft-fallback the close path needs redesign. |
| **UJ-09** Material verification at scan-in | ✅ Closed (Option C). Strict BOM check at material scan-in; BOM-mismatch surfaces a supervisor AD-elevated one-shot override per FDS-04-007 + FDS-06-011 — substitution is logged (`MaterialSubstituteOverride` audit). |
| **UJ-13** ContainerConfig.ClosureMethod | ✅ Closed. Per-Item via `Parts.ContainerConfig.ClosureMethod` — three peer values `ByCount` / `ByWeight` / `ByVision` per FDS-06-014. |
| **UJ-16** HardwareInterlockBypassed | ✅ Closed (Option A). BIT column on `Lots.ContainerSerial` (created in this phase's migration). |
| **UJ-17** Vision vs barcode | ✅ Closed (Option A). `ConfirmationMethod` LocationAttribute on Cell (seeded Phase 1); the Confirmation Method Resolver embedded component reads it and renders the appropriate UX. |
| **UJ-18** Print failure surfacing | ✅ Closed. Gateway-broadcast-with-session-filter per FDS-07-006b. The print-failure banner embedded component (cross-cutting) appears on every workstation view including Assembly. |
| **OI-35 B5 materialization** | If elected (Phase 0): `ConsumptionEvent_Record` updates `Lot.TotalInProcess` / `InventoryAvailable` for the consumed source LOT. |

## State & Workflow

### Serialized assembly line — PLC/MIP handshake

Serialized lines (e.g., 5G0 Front Cover) carry full PLC/MIP integration. The line auto-loads parts from the upstream Machining Cell (auto-moved via FDS-06-008 / Phase 5) and from staged lineside LOTs of consumable materials (e.g., PNA mounting pins). Per-piece operator interaction is minimal — the operator monitors and intervenes on errors.

Per-piece flow:
1. The assembly machine loads a casting from the upstream LOT, presses in the components per BOM, and the laser etches a serial number `5G0F-NNNNNN` (minted from `IdentifierSequence_Next @Code='SerializedItem'` if the MES mints; otherwise the MES validates a PLC-supplied serial).
2. The PLC writes `DataReady=1`. The MES reads `PartSN`, validates uniqueness, writes `PartValid=1` back. The PLC releases the part.
3. The MES writes a `Lots.SerializedPart` row + a `Workorder.ConsumptionEvent` (one per BOM component consumed) + a `Lots.LotGenealogy` row linking each consumed source LOT to the produced SerializedPart.
4. The part drops into a tray position. `ContainerSerial` row inserted with `ContainerId`, `ContainerTrayId`, `TrayPosition`, `SerializedPartId`. **If `HardwareInterlockEnable = false` on the PLC at the moment of placement, `ContainerSerial.HardwareInterlockBypassed = 1`** (UJ-16).
5. When the tray's `PartsClosedCount` reaches `Parts.ContainerConfig.PartsPerTray`, the tray closes — `ContainerTray.ClosedAt` set, `ClosureMethod` captured (`ByVision` for serialized lines — camera per-piece validation drove the count; PLC `TrayFullFlag` confirms).
6. When accumulated tray closes reach `TraysPerContainer × PartsPerTray` for the Container, the Container completes (see "Container completion" below).

### Non-serialized assembly line — operator-driven count

Non-serialized lines (e.g., 6B2 Cam Holder, RPY Assembly Sets) use OPC `PartDisposition` flags + operator-confirmed counts. No per-piece serial. Tray-level closure still applies — same three closure methods, same accumulation logic — but the tray gate is operator-driven (`ByCount`) or scale-driven (`ByWeight`).

Per-tray flow:
1. The operator runs the operation. As parts accumulate in a tray, the OPC `PartDisposition` tag indicates per-piece pass/fail (and the running good count, depending on line).
2. When the operator (`ByCount`) or scale (`ByWeight`) signals tray full, Perspective calls `Lots.ContainerTray_Close`. The proc validates the count matches `PartsPerTray`, sets `ContainerTray.ClosedAt`, captures `ClosureMethod`, increments the parent Container's running parts count.
3. ConsumptionEvents fire per tray for the BOM components consumed (one ConsumptionEvent per BOM line per tray).
4. Same accumulation rule as serialized — Container completes when `accumulatedClosedTrayParts ≥ TraysPerContainer × PartsPerTray`.

### Tray-level closure — three peer ClosureMethod values (FDS-06-014)

Closure validation happens at the **tray** level, with the container as the accumulator. `Parts.ContainerConfig.ClosureMethod` selects the per-tray trigger:

- `ByCount`: operator confirms tray quantity at the Per-Tray Close screen (or the PLC asserts `TrayFullFlag` based on a count the operator entered upstream).
- `ByWeight`: OmniServer scale publishes the per-tray weight; PLC compares against `TargetWeight` configured on `ContainerConfig` and asserts `TrayFullFlag` at threshold.
- `ByVision`: camera validates each part (pass/fail per piece); PLC accumulates the validated count and asserts `TrayFullFlag` at `PartsPerTray`.

The MES reads `TrayFullFlag` (or accepts the operator's `ContainerTray_Close` submit on `ByCount` lines), writes the tray-close row, and **derives** the container fill from accumulated tray closes — no separate `ContainerFullFlag` PLC tag is required.

### Container completion (atomic close + AIM pool claim + async print)

When the container's accumulated parts reach the configured capacity, Perspective (or a Gateway script on PLC-driven lines) calls `Lots.Container_Complete`:

1. Validate the container is Open and the accumulated count matches `TraysPerContainer × PartsPerTray`.
2. **AIM pool claim (UJ-04 + OI-33).** Call `Lots.AimShipperIdPool_Claim @PartNumber, @ContainerId` — atomic FIFO claim from the local pool, sub-millisecond, never blocked on AIM. **Empty-pool behavior is hard-fail per FDS-07-010a (default; OI-33 customer validation pending).** On empty pool the proc raises a business-rule error; the surrounding transaction rolls back; the operator sees an error banner ("AIM pool exhausted — contact IT"); the line stops on this terminal until pool refills.
3. On successful claim: insert `Lots.ShippingLabel` row with `PrintedAt = NULL`, `AimShipperId = (claimed Id)`, `TerminalLocationId`, `ContainerId`, etc. Update `Container.ContainerStatusCodeId` to `Complete`, set `CompletedAt`.
4. **OI-16 / FDS-06-028 auto-finish gate.** Read the PLC `CompletionConfirmed` BIT (belt-and-suspenders alongside count-target-crossing). If `RequiresCompletionConfirm` LocationAttribute on the Terminal is `1`, Perspective also requires the operator to tap a large "Confirm Completion" button before the close commits; if `0` (or NULL), the close proceeds with a passive popup.
5. **All four steps above run inside a single atomic transaction** — close, claim, ShippingLabel insert, status flip — sub-millisecond when the AIM pool is healthy.
6. **Async print dispatch (UJ-18 / FDS-07-006a).** After commit, Perspective fires `system.util.sendRequestAsync('mes', 'print-shipping-label', {ShippingLabelId})`. The Gateway handler renders ZPL and dispatches to the Zebra at `TerminalLocationId`. Three retries × 2s gap inline within the handler. On success, update `ShippingLabel.PrintedAt`. On exhaustion, set `PrintFailedAt` — drives the Print Failure Banner via the Gateway-broadcast safety-sweep (Phase 7).

### BOM material verification at scan-in (UJ-09 — Option C)

Strict BOM check + supervisor AD-elevated one-shot override:

1. The operator scans an inbound lineside LOT for consumption.
2. Perspective calls `Workorder.ConsumptionEvent_RecordWithBomCheck @SourceLotId, @ProducingLotId, @CellLocationId, ...`. The proc resolves the active BOM for the producing Item at this Cell and validates the source LOT's Item is a child line.
3. **Strict match:** if the source Item is on the BOM, ConsumptionEvent writes normally.
4. **Mismatch:** the proc returns `Status=0, Message='Source Item {X} is not a configured component for {ProducedItem} at this Cell.'` Perspective shows a supervisor-override modal (per FDS-04-007).
5. On supervisor AD authentication via `AppUser_AuthenticateAd @ActionCode='MaterialSubstituteOverride'`, Perspective re-calls the proc with `@OverrideAppUserId = (supervisor's Id), @OverrideAuthorized = 1`. The proc accepts the consumption, writes the ConsumptionEvent, and writes a `MaterialSubstituteOverride` audit row capturing both the operator's and supervisor's user ids.
6. The override is **one-shot** per consumption event — next scan re-runs the strict check.

### `ConfirmationMethod` per Cell (UJ-17 / FDS-10-013)

The Confirmation Method Resolver (cross-cutting embedded component) reads the `ConfirmationMethod` LocationAttribute (seeded Phase 1) on the operator's active Cell:

- `Vision`: rely on PLC `VisionPartNumber` for part-identity confirmation.
- `Barcode`: require the operator to scan the part's barcode.
- `Both`: both checks must agree; mismatches trigger the OI-04 line-stop / 10-fail-escalation flow (FDS-10-005..012).

### `HardwareInterlockBypassed` (UJ-16)

When the PLC asserts `HardwareInterlockEnable = false` (a valid bypass mode per the touchpoint agreement, not an error), parts proceed without MES serial validation. The corresponding `ContainerSerial` row carries `HardwareInterlockBypassed = 1` so the audit trail records that the part entered the container without validation. This is per-piece granular — a single bypass in the middle of an otherwise-validated container shows up on exactly the affected `ContainerSerial` rows.

## API Layer (Named Queries → Stored Procedures)

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Lots.Container_Open` | `@ItemId`, `@ContainerConfigId`, `@CellLocationId`, `@AppUserId`, `@TerminalLocationId` | Opens a new container at a Cell. Returns `Id`. | `Status, Message, NewId` |
| `Lots.ContainerTray_Close` | `@ContainerId`, `@TrayPosition INT`, `@PartsCount INT`, `@ClosureMethod NVARCHAR(20)`, `@AppUserId`, `@TerminalLocationId` | Validates count vs `PartsPerTray`, sets `ClosedAt`, captures `ClosureMethod`, increments parent Container's running parts count. | `Status, Message, NewId, ContainerAccumulatedParts INT` |
| `Lots.ContainerSerial_Add` | `@ContainerId`, `@ContainerTrayId NULL`, `@TrayPosition NULL`, `@SerializedPartId`, `@HardwareInterlockBypassed BIT`, `@AppUserId`, `@TerminalLocationId` | Inserts the per-piece serial assignment to a tray position. | `Status, Message, NewId` |
| `Lots.SerializedPart_Mint` | `@ItemId`, `@ProducingLotId`, `@AppUserId`, `@TerminalLocationId` | Mints a new SerializedPart. Calls `IdentifierSequence_Next @Code='SerializedItem'`. | `Status, Message, NewId, SerialNumber NVARCHAR(50)` |
| `Lots.Container_Complete` | `@ContainerId`, `@PlcCompletionConfirmed BIT`, `@OperatorConfirmed BIT`, `@AppUserId`, `@TerminalLocationId` | Atomic close: validates accumulated count, claims AIM ID via `AimShipperIdPool_Claim`, inserts `ShippingLabel` row, flips status. **Hard-fails on empty pool per FDS-07-010a** (OI-33 pending). Reads `RequiresCompletionConfirm` on Terminal — if 1, requires `@OperatorConfirmed=1`. | `Status, Message, ShippingLabelId BIGINT, AimShipperId NVARCHAR(50)` |
| `Workorder.ConsumptionEvent_RecordWithBomCheck` | `@SourceLotId`, `@ProducingLotId`, `@CellLocationId`, `@ConsumedPieceCount`, `@ContainerSerialId NULL`, `@OverrideAppUserId NULL`, `@OverrideAuthorized BIT = 0`, `@AppUserId`, `@TerminalLocationId` | Strict BOM check; rejects on mismatch unless `@OverrideAuthorized=1` (with `@OverrideAppUserId` from prior `AppUser_AuthenticateAd @ActionCode='MaterialSubstituteOverride'`). On override, writes the audit row. | `Status, Message, NewId` |

## Gateway Scripts

| Script | Purpose | Trigger | External | Audit |
|---|---|---|---|---|
| `AssemblyMipHandler` (per serialized line) | PLC handshake — reads `PartSN`, writes `PartValid`, monitors `HardwareInterlockEnable`, `DataReady`, `ContainerFullFlag` (legacy — being deprecated by tray-level closure but supported during cutover for any line that still drives container-level), `CompletionConfirmed`. Calls `ConsumptionEvent_RecordWithBomCheck` + `SerializedPart_Mint` + `ContainerSerial_Add`. On tray-fill / container-fill thresholds calls `ContainerTray_Close` + `Container_Complete`. | PLC tag edges | PLC (TOPServer) | Per-call OperationLog via procs; InterfaceLog on every PLC read/write per B4 |
| `NonSerializedLineHandler` (per non-serialized line) | OPC `PartDisposition` reader → operator-confirmed count + scale-driven count for `ByWeight` lines. Calls `ContainerTray_Close` on tray-full edge. | PLC tag edge / OmniServer scale | PLC, OmniServer | InterfaceLog |
| `ShippingLabelDispatcher` | Receives `print-shipping-label` messages, renders ZPL, dispatches to Zebra at `TerminalLocationId`, retries 3× 2s, updates `ShippingLabel.PrintedAt` or `PrintFailedAt`. | Gateway message handler | Zebra socket | InterfaceLog per attempt |

## Perspective Views

| View | Purpose |
|---|---|
| Assembly Serialized (purpose-built top-level view) | Composes Per-Mutation Initials Field + Confirmation Method Resolver + Paused-LOT Indicator + Print Failure Banner. Read-mostly during normal operation (PLC drives most events); operator UX activates on errors, line-stops, supervisor overrides. The OI-16 "Confirm Completion" gesture button (when `RequiresCompletionConfirm=1`) renders here. |
| Assembly Non-Serialized (purpose-built top-level view) | Composes the same cross-cutting components + an operator-driven Per-Tray Close form (`ByCount` / `ByWeight` rendered per `ConfirmationMethod`). |
| Confirmation Method Resolver (cross-cutting embedded component) | Reads `ConfirmationMethod` LocationAttribute → renders Vision / Barcode / Both UX appropriate to the active Cell. Reusable across Assembly + any future view that does part-identity confirmation. |
| Print Failure Banner (cross-cutting embedded component) | Subscribes to `print-failure-alert` Gateway-broadcast messages, filters by `session.custom.terminal.terminalLocationId`, renders banner when `PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`. Actions: Retry / Reprint / Acknowledge. |
| Material Substitute Override Modal (cross-cutting embedded component) | UJ-09 — supervisor AD-elevated one-shot override for BOM-mismatch consumption. |

## Test Coverage

New test suite at `sql/tests/0019_PlantFloor_Assembly/`:

| File | Covers |
|---|---|
| `010_Container_lifecycle.sql` | Open → multi-tray accumulate → Complete; status transitions; CompletedAt set. |
| `020_ContainerTray_Close_methods.sql` | `ByCount` / `ByWeight` / `ByVision` all close with `ClosureMethod` captured; mismatched count rejects. |
| `030_ContainerSerial_Add_with_bypass.sql` | Insert with `HardwareInterlockBypassed=1`; multiple bypassed serials in one container; audit row captures the flag. |
| `040_Container_Complete_happy.sql` | Healthy AIM pool → claim succeeds, ShippingLabel inserted, status flips; print message dispatched. |
| `050_Container_Complete_empty_pool_hard_fail.sql` | Empty pool → atomic ROLLBACK; container stays Open; operator-facing error message. |
| `060_Container_Complete_with_completion_confirm.sql` | RequiresCompletionConfirm=1 + @OperatorConfirmed=0 rejects; =1 succeeds. |
| `070_BomCheck_strict.sql` | Source on BOM succeeds; off-BOM rejects with FDS-06-011 message. |
| `080_BomCheck_supervisor_override.sql` | Off-BOM + valid supervisor @OverrideAppUserId + @OverrideAuthorized=1 succeeds; audit row captures both AppUserIds. |
| `090_SerializedPart_Mint.sql` | Mints via IdentifierSequence_Next; SerialNumber matches `MESI{0:D7}` format; rolls back on unrelated transaction failure does not burn the counter (per B6 row-locked-update model — note: if Phase 0 elected SEQUENCE, the counter does burn, accepted tradeoff). |

Target: 100–135 passing tests in suite 0019.

## Phase 6 complete when

- [ ] Migration `0019_arc2_phase6_assembly.sql` applied. Container family CREATEd. Seeds in place.
- [ ] All Phase 6 procs delivered.
- [ ] All tests in `sql/tests/0019_PlantFloor_Assembly/` pass.
- [ ] Perspective Assembly Serialized + Assembly Non-Serialized views implemented composing all cross-cutting components.
- [ ] Gateway `AssemblyMipHandler` per serialized line implemented and tested against PLC simulator + dev 5G0 MIP.
- [ ] Gateway `ShippingLabelDispatcher` implemented; 3-retry mechanism tested against Zebra emulator failures; `PrintFailedAt` set correctly on exhaustion.
- [ ] **End-to-end integration check (serialized line):** machined LOT auto-arrives from Phase 5 → assembly cycle consumes via PLC handshake → SerializedPart minted, ContainerSerial inserted with bypass=0 (or =1 on a deliberate bypass test) → tray closes via ByVision → container accumulates → Container_Complete claims AIM ID, inserts ShippingLabel, flips status → ZPL prints at the closing terminal's Zebra.
- [ ] **End-to-end integration check (non-serialized line):** machined LOT auto-arrives → operator records per-tray close (ByCount or ByWeight) → container accumulates → Container_Complete + AIM claim + print as above.
- [ ] **Empty-pool fail check:** drain the AIM pool → attempt Container_Complete → expect business-rule error + ROLLBACK + operator banner.

---

# Phase 7 — Hold + Sort Cage + Shipping + AIM Pool Lifecycle

**Goal:** Deliver Hold lifecycle (place / release on LOTs and Containers — proc-enforced via FDS-08-007a), Sort Cage re-containerization with `ContainerSerialHistory` (UJ-05 default direction — update-in-place), Shipping Dock truck-out (every container scanned must be Complete + AIM-valid + non-Hold), AIM Shipper ID pool topup loop + tier alarms + config CRUD, and the Print Failure Safety Sweep timer.

**Dependencies:** Phase 1 (foundation), Phase 2 (LOT lifecycle), Phase 6 (Container family — Phase 6's migration CREATEs `Container` + `ContainerTray` + `ContainerSerial` + `SerializedPart`; Phase 7's migration adds the Hold + AIM pool tables and the SortCage history table that consume them).

**Status:** Blocked on Phase 6 schema CREATE. Sequencing note: Phase 7's `AimShipperIdPool_Claim` proc is consumed by Phase 6's `Container_Complete` — the pool tables CREATE in Phase 7's migration; Phase 6 ships the consumer last (in the same delivery cycle).

## Data Model Changes

**Migration `sql/migrations/versioned/0020_arc2_phase7_hold_sort_shipping_aim.sql`** (next unclaimed).

**New tables:**

- `Quality.HoldEvent` (if not already in Phase 1 — confirm during Phase 0 scoping). Columns per Data Model v1.9l §5: `Id`, `LotId NULL FK → Lots.Lot.Id`, `ContainerId NULL FK → Lots.Container.Id`, `HoldTypeCodeId BIGINT FK → Quality.HoldTypeCode.Id`, `Reason NVARCHAR(500)`, `PlacedByUserId BIGINT FK → AppUser.Id`, `PlacedAt DATETIME2(3)`, `ReleasedByUserId BIGINT FK → AppUser.Id NULL`, `ReleasedAt DATETIME2(3) NULL`. Filtered UNIQUE for at-most-one-open per `(LotId)` and `(ContainerId)` per B3.
- `Lots.AimShipperIdPool` (per Data Model v1.9h / UJ-04). Columns: `Id`, `AimShipperId NVARCHAR(50) UNIQUE`, `PartNumber NVARCHAR(50)` (AIM IDs are fetched per-part-number), `FetchedAt`, `FetchedInterfaceLogId BIGINT FK → Audit.InterfaceLog.Id`, `ConsumedAt NULL`, `ConsumedByContainerId NULL FK → Lots.Container.Id`, `ConsumedByUserId NULL FK → AppUser.Id`. Filtered index `IX_AimShipperIdPool_AvailableByPart (PartNumber, FetchedAt) WHERE ConsumedAt IS NULL` — drives the FIFO-by-part-number claim.
- `Lots.AimPoolConfig` (per Data Model v1.9h). Single-row table holding configurable thresholds: `TargetBufferDepth INT DEFAULT 50`, `TopupThreshold INT DEFAULT 30`, `AlarmWarningDepth INT DEFAULT 20`, `AlarmCriticalDepth INT DEFAULT 10`. `CHECK (Id = 1)` enforces single-row.
- `Lots.ContainerSerialHistory` (UJ-05 default direction — update-in-place). Columns: `Id`, `ContainerSerialId BIGINT FK → ContainerSerial.Id`, `OldContainerId BIGINT FK → Container.Id`, `NewContainerId BIGINT FK → Container.Id`, `OldTrayPosition INT NULL`, `NewTrayPosition INT NULL`, `MigrationReasonCode NVARCHAR(50)` (`SortCage`, `Repack`, `RangeAdjustment`), `MigratedAt DATETIME2(3)`, `MigratedByUserId BIGINT FK → AppUser.Id`. Filtered index for per-SerializedPart history walk.

**Seeds:**

- `Quality.HoldTypeCode`: `CustomerComplaint`, `QualityIssue`, `EngineeringHold`, `ProductionHold`, `ContainerHold`. Final list confirmed Phase 0 A7 walkthrough alongside label-template scope.
- `Lots.AimPoolConfig` initial single row with default thresholds.
- `Audit.LogEntityType` rows: `HoldEvent`, `AimShipperIdPool`, `AimPoolConfig`, `ContainerSerialHistory`.
- `Audit.LogEventType` rows: `HoldPlaced`, `HoldReleased`, `AimShipperIdClaimed`, `AimShipperIdToppedUp`, `AimPoolWarningAlarmFired`, `AimPoolCriticalAlarmFired`, `ContainerSerialMigrated`, `ShippingLabelVoided`, `ContainerShipped`, `PrintFailureSafetySweepRecovered`.

**Tables used (existing):** all Phase 6 Container family, `Lots.Lot`, `Lots.LotStatusHistory`, `Lots.LotStatusCode` (`BlocksProduction` flag — Hold transitions a LOT to a status with `BlocksProduction=1`), `Lots.ShippingLabel` (Phase 6).

## Open Items Affecting This Phase

| Item | Status |
|---|---|
| **OI-22** Hold Management screen | ✅ Closed. Dedicated top-level Perspective view (FDS-08-007a). |
| **UJ-04** AIM pool design lock | ✅ Closed (2026-04-27). Pool model in this phase — sync FIFO claim by part number + Gateway-script-async topup loop + tier alarms (warning/critical/exhausted). |
| **OI-33** AIM pool empty-pool hard-fail | 🔶 Pending Phase 0 customer validation. Default direction (current FDS-07-010a): hard-fail. Phase 7's `_Claim` proc raises a business-rule error on empty pool (consumed by Phase 6's atomic close which ROLLBACKs). |
| **A6** Honda AIM Hold/Update contract | Pending Phase 0 — `PlaceOnHold`, `ReleaseFromHold`, `UpdateAim` signatures + error recovery for the Phase 7 hold + Sort Cage workflows. |
| **A7** Label template scope | Pending Phase 0 — confirms Container / LOT / ContainerHold templates + any new (Sort Cage, Hold, Void). Couples to S-09 in the Seeding Registry. |
| **UJ-05** Sort Cage serial migration | ⬜ Open (default direction committed). Update-in-place + `Lots.ContainerSerialHistory` is built; awaits MPP Quality + Honda compliance affirmation. If MPP rejects, Phase 7 reverts to void-and-recreate (no history table). |
| **UJ-18** Print failure surfacing | ✅ Closed. Phase 7 hosts the safety-sweep timer (5-min cadence) + stranded-prints alarm at >5 (FDS-07-006b). |

## State & Workflow

### Hold placement (multi-LOT or multi-Container)

The Hold Management top-level view exposes filterable lists of open LOTs and open Containers. The supervisor selects one or many entries and places a hold. Required: AD elevation per FDS-04-007 (`@ActionCode='HoldPlace'`).

`Quality.Hold_Place` sequence:
1. Validate AD elevation (caller already authenticated; `@AppUserId` is the elevated user).
2. For each `LotId` or `ContainerId` in the batch: call `Lot_AssertNotBlocked` (or container equivalent — a hold cannot be placed on an already-held entity per B3).
3. Insert `HoldEvent` row(s) with `HoldTypeCodeId`, `Reason`, `PlacedByUserId`, `PlacedAt = SYSUTCDATETIME()`.
4. For LOTs: transition `Lot.LotStatusId` → `Hold` via `Lot_UpdateStatus` (the new status carries `BlocksProduction=1` — every downstream proc fails its `Lot_AssertNotBlocked` check).
5. For Containers in the batch that are already shipped (`ShippingLabel.PrintedAt IS NOT NULL`, `ContainerStatusCode='Complete'`): also call AIM `PlaceOnHold` per FDS-07-008 — Gateway-script-async via `system.util.sendRequestAsync('mes', 'aim-place-on-hold', {ShipperId})`. The Gateway script handles AIM signature + error recovery per Phase 0 A6.
6. Audit `HoldPlaced` per row.

### Hold release

Same pattern in reverse. `Quality.Hold_Release @HoldEventId, @ReleaseRemarks, @AppUserId, @TerminalLocationId`:
1. Validate the HoldEvent is open (`ReleasedAt IS NULL`).
2. Update the row: `ReleasedByUserId`, `ReleasedAt`.
3. For LOTs: transition `LotStatusId` back to its prior non-Hold status (read from `LotStatusHistory`).
4. For Containers that were on AIM hold: Gateway-script-async `aim-release-from-hold`.
5. Audit `HoldReleased`.

### Sort Cage re-containerization (UJ-05 default — update-in-place)

A held Container goes to the Sort Cage. Operators unpack, re-inspect each part, and re-pack into new Containers. The migration writes per-Serial migration rows to `Lots.ContainerSerialHistory` and updates `ContainerSerial.ContainerId` / `TrayPosition` to the new container in the same transaction.

`Lots.SortCage_MigrateSerial @ContainerSerialId, @NewContainerId, @NewTrayPosition, @MigrationReasonCode='SortCage', @AppUserId, @TerminalLocationId`:
1. Validate the source container is held; the destination container is open + at the Sort Cage location.
2. Insert `ContainerSerialHistory` row capturing `Old*` and `New*` values + reason.
3. Update `ContainerSerial.ContainerId` and `ContainerSerial.TrayPosition` in place.
4. The genealogy + ShippingLabel chains remain valid — backward trace from any serial number lands on the producing LOT regardless of container migrations.
5. When the destination Container reaches its capacity, normal `Container_Complete` runs (claims a fresh AIM ID; the old shipping label is voided via `ShippingLabel_Void`).
6. Audit `ContainerSerialMigrated`.

The Sort Cage Workflow Perspective view uses **Flex Repeater + Embedded View** for the per-serial migration rows — one row per serial in the held source container, each row showing serial number + old position + new container/tray dropdowns + migrate button.

### Shipping (truck-out)

The Shipping Dock view scans each Container's Shipping Label as the truck loads. Per scan:
1. Validate `ContainerStatusCode='Complete'`, no open hold (`HoldEvent` for this Container with `ReleasedAt IS NULL` rejects), `ShippingLabel.IsVoid=0`.
2. Update `Container.CurrentLocationId` → Shipping Dock (or `Shipped` location, depending on Phase 0 plant model).
3. Audit `ContainerShipped`.

A bulk variant accepts a JSON list of ShippingLabel Ids for a manifest-level scan.

### AIM Shipper ID pool — topup loop + alarms

The AIM Shipper ID pool is filled by a Gateway timer running every ~30 seconds (per FDS-07-010). The timer:
1. Calls `Lots.AimShipperIdPool_GetDepth` per Part Number — returns count of un-consumed IDs.
2. For each Part Number where depth < `TopupThreshold`: calls AIM `GetNextNumber(@PartNumber)` repeatedly via Gateway-script-async until depth reaches `TargetBufferDepth`. Each fetched ID writes an `Audit.InterfaceLog` row + a row in `AimShipperIdPool`.
3. **Tier alarms (FDS-07-010b):**
   - Depth ≤ `AlarmWarningDepth` → supervisor wallboard tile (no email/page).
   - Depth ≤ `AlarmCriticalDepth` → supervisor alarm + IT notification.
   - Depth = 0 → empty-pool state; subsequent `_Claim` calls hard-fail per OI-33 (pending validation).
4. Each alarm fires at most once per crossing (rising-edge detection); a separate clear-alarm fires when depth recovers above the threshold.

`AimPoolConfig` thresholds are exposed via the Configuration Tool (Phase 7 admin view) — `Lots.AimPoolConfig_Get` / `_Update`.

### Print Failure Safety Sweep (FDS-07-006b)

A Gateway timer runs every 5 minutes and queries:
```sql
SELECT * FROM Lots.ShippingLabel
WHERE PrintedAt IS NULL AND PrintFailedAt IS NULL
  AND CreatedAt < DATEADD(SECOND, -60, SYSUTCDATETIME())
```

These are stranded prints (Gateway restart between Container_Complete commit and message dispatch). For each, fire `print-shipping-label` again. If the same row strands twice in a row, write `PrintFailedAt`.

If the sweep finds more than **5** stranded labels at once, fire a supervisor alarm + IT notification — the Gateway likely needs investigation.

## API Layer

### Hold management

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Quality.Hold_Place` | `@LotIdsJson`, `@ContainerIdsJson`, `@HoldTypeCodeId`, `@Reason`, `@AppUserId` (elevated), `@TerminalLocationId` | Batch-place hold on N LOTs and/or N Containers. Per-row B3 enforcement. | Multi-row: header + per-row `EntityType, EntityId, HoldEventId, Status` |
| `Quality.Hold_Release` | `@HoldEventId`, `@ReleaseRemarks`, `@AppUserId` (elevated), `@TerminalLocationId` | Releases a single open hold. | `Status, Message` |
| `Quality.Hold_GetOpenByLot` | `@LotId` | Returns the open hold if any. | Single row or empty |
| `Quality.Hold_GetOpenByContainer` | `@ContainerId` | Same for containers. | Single row or empty |

### Container state transitions (Phase 7 additions)

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Lots.Container_Ship` | `@ShippingLabelId`, `@AppUserId`, `@TerminalLocationId` | Validates Complete + no hold + non-void; updates `Container.CurrentLocationId` to Shipping Dock; audits. | `Status, Message` |
| `Lots.ShippingLabel_Void` | `@ShippingLabelId`, `@VoidReason`, `@AppUserId` (elevated), `@TerminalLocationId` | Marks `IsVoid=1`, sets `VoidedAt` + `VoidedByUserId`. Used during Sort Cage re-pack. | `Status, Message` |
| `Lots.ShippingLabel_Reprint` | `@ShippingLabelId`, `@PrintReasonCode`, `@AppUserId`, `@TerminalLocationId` | Inserts a new `ShippingLabel` row (label rows are append-only) with `Initial=0` and `PrintReasonCode`. | `Status, Message, NewId` |
| `Lots.SortCage_MigrateSerial` | `@ContainerSerialId`, `@NewContainerId`, `@NewTrayPosition NULL`, `@MigrationReasonCode`, `@AppUserId`, `@TerminalLocationId` | Inserts ContainerSerialHistory row + updates ContainerSerial in place. | `Status, Message, NewHistoryId` |

### AIM pool

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Lots.AimShipperIdPool_Claim` | `@PartNumber`, `@ContainerId`, `@AppUserId` | Atomic FIFO claim by Part Number. Hard-fails on empty pool (OI-33 default). Called by Phase 6's `Container_Complete`. | `Status, Message, AimShipperId NVARCHAR(50)` |
| `Lots.AimShipperIdPool_Topup` | `@PartNumber`, `@AimShipperId NVARCHAR(50)`, `@FetchedInterfaceLogId BIGINT` | Inserts a fetched row into the pool. Called by the Gateway topup script. | `Status, Message, NewId` |
| `Lots.AimShipperIdPool_GetDepth` | `@PartNumber NULL` | Returns un-consumed depth, optionally filtered by Part Number. | Rowset: `(PartNumber, Depth)` |
| `Lots.AimShipperIdPool_GetByContainer` | `@ContainerId` | Returns the AIM ID assigned to a container. | Single row |
| `Lots.AimPoolConfig_Get` | (none) | Returns the single config row. | Single row |
| `Lots.AimPoolConfig_Update` | `@TargetBufferDepth`, `@TopupThreshold`, `@AlarmWarningDepth`, `@AlarmCriticalDepth`, `@AppUserId` (elevated) | Updates the single config row. ConfigLog audit. | `Status, Message` |

## Gateway Scripts

| Script | Purpose | Trigger | External | Audit |
|---|---|---|---|---|
| `AimPoolTopup` | Every ~30s: per Part Number, call `_GetDepth`; if below `TopupThreshold`, call AIM `GetNextNumber(@PartNumber)` repeatedly until `TargetBufferDepth` reached. Each fetch writes InterfaceLog + `_Topup` row. | Gateway timer (30s) | AIM HTTP/SOAP | InterfaceLog per call |
| `AimPoolAlarmMonitor` | Every ~60s: read pool depth per Part Number, compare to thresholds. Fire wallboard / supervisor alarm / IT notification on rising-edge crossings. Clear on falling-edge recovery. | Gateway timer (60s) | — | OperationLog on alarm fire / clear |
| `AimHoldHandler` | Receives `aim-place-on-hold` and `aim-release-from-hold` messages. Calls AIM HTTP per Phase 0 A6 contract. Retries per UJ-18 retry policy on transient failures; logs final state. | Gateway message handler | AIM HTTP/SOAP | InterfaceLog per call |
| `AimUpdateHandler` | Receives `aim-update` messages (Sort Cage re-pack with new serials per FRS Appendix L). Same retry pattern. | Gateway message handler | AIM HTTP/SOAP | InterfaceLog |
| `PrintFailureSafetySweep` | Every 5 min: query stranded `ShippingLabel` rows; re-fire `print-shipping-label`; mark `PrintFailedAt` on second strand; alarm if count > 5. | Gateway timer (5 min) | — | OperationLog on recovery; supervisor alarm on count > 5 |
| `PrintFailureBroadcaster` | Every 5s: query failed prints (`PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`); fire `system.util.sendMessage('mes', 'print-failure-alert', {...})` for each. Perspective sessions filter by their own `TerminalLocationId`. | Gateway timer (5s) | — | — (read-only broadcast) |

## Perspective Views

| View | Purpose |
|---|---|
| Hold Management (purpose-built top-level view) | Filterable lists of open LOTs + open Containers; Flex Repeater for each list; multi-select; AD-elevation modal for Hold_Place / Hold_Release. Couples to FDS-08-007a. |
| Sort Cage Workflow (purpose-built top-level view) | Held source Container shown at top; Flex Repeater per ContainerSerial in the source — each entity is the cross-cutting Cell-Selector-Repeater-Entity adapted for "destination Container + tray position selection." Bulk-migrate button submits N `SortCage_MigrateSerial` calls in sequence. |
| Shipping Dock (purpose-built top-level view) | Scan-to-ship; per-scan validates Complete + non-Hold + non-Void; bulk manifest-scan variant. |
| AIM Pool Configuration (admin top-level view) | Read + Update of the single `AimPoolConfig` row. AD-elevated. Configuration Tool surface, not operator-facing. |
| AIM Pool Wallboard Tile (cross-cutting embedded component) | Renders pool depth + warning/critical state on supervisor dashboards. |
| Print Failure Banner (cross-cutting embedded component, defined Phase 6) | Same component used here; the safety-sweep + broadcaster Gateway scripts produce the events it consumes. |

## Test Coverage

New test suite at `sql/tests/0020_PlantFloor_Hold_Sort_Shipping_Aim/`:

| File | Covers |
|---|---|
| `010_Hold_Place_release.sql` | Single-LOT and batch-LOT placement; double-place rejects per B3; release transitions LotStatus correctly; multi-Container batch with mixed pre-shipped (AIM hold path) and not-shipped. |
| `020_SortCage_MigrateSerial.sql` | Update-in-place migration writes history row + updates ContainerSerial; multiple serials per source container; deprecated/closed source container handling. |
| `030_Container_Ship.sql` | Complete + non-Hold + non-Void succeeds; held container rejects; void label rejects. |
| `040_AimShipperIdPool_Claim.sql` | Healthy pool → FIFO order; empty pool → hard-fail per OI-33; per-Part-Number isolation (Part A claim doesn't draw from Part B's depth). |
| `050_AimShipperIdPool_Topup.sql` | Insert respects UNIQUE; FetchedInterfaceLogId provenance; concurrent topups don't double-insert. |
| `060_AimPool_alarms.sql` | Rising-edge detection at Warning + Critical + Exhausted; clearing alarms on recovery. |
| `070_PrintFailure_safety_sweep.sql` | Stranded row recovered on first sweep; double-strand sets PrintFailedAt; > 5 stranded triggers alarm. |
| `080_ShippingLabel_Void_Reprint.sql` | Void marks IsVoid + VoidedAt; Reprint inserts new row with PrintReasonCode; original row unchanged. |

Target: 90–120 passing tests in suite 0020.

## Phase 7 complete when

- [ ] Migration `0020_arc2_phase7_hold_sort_shipping_aim.sql` applied. New tables CREATEd. Seeds in place.
- [ ] All Phase 7 procs delivered.
- [ ] All tests in `sql/tests/0020_PlantFloor_Hold_Sort_Shipping_Aim/` pass.
- [ ] Perspective views (Hold Management, Sort Cage Workflow, Shipping Dock, AIM Pool Config) implemented.
- [ ] All five Gateway scripts (Topup, AlarmMonitor, AimHoldHandler, AimUpdateHandler, PrintFailureSafetySweep, PrintFailureBroadcaster) implemented and tested.
- [ ] **End-to-end integration check (hold + Sort Cage + reship):** complete a Container in Phase 6 → place hold via Hold Management → AIM PlaceOnHold logs to InterfaceLog → operator at Sort Cage migrates serials to a new Container via Flex Repeater → original ShippingLabel voided → new Container completes + new AIM ID claimed + new ShippingLabel printed → AimUpdate logs to InterfaceLog → ship the new Container.
- [ ] **End-to-end integration check (pool exhaustion):** drain pool to zero → Container_Complete attempt hard-fails → operator banner → topup script refills → retry succeeds.
- [ ] **End-to-end integration check (stranded print recovery):** kill Gateway between Container_Complete commit and print dispatch → safety sweep recovers and dispatches.
- [ ] **B10 convention rewritten** with the chosen UJ-05 final pattern (default direction landed; reverts to void-and-recreate if MPP rejects).

---

# Phase 8 — Downtime + Shift Boundary (Parallel Track)

**Goal:** Deliver PLC-driven and manual downtime entry, the FDS-09-013 end-of-shift time-entry workflow (single submission, shift-schedule durations — no minute adjustments), the FDS-09-015 shift-end summary screen, the supervisor dashboard, and the Shift_End semantics that leave open events open across boundaries (UJ-10 Option D / OI-03).

**Dependencies:** Phase 1 (Shift_Start / Shift_End procs + ShiftBoundaryTicker Gateway script). Independent of Phases 2–7 — runs in parallel as soon as Phase 1 lands.

**Status:** Blocked on Phase 1.

## Data Model Changes

**Migration `sql/migrations/versioned/0021_arc2_phase8_downtime_shift.sql`** (next unclaimed).

- `Oee.DowntimeEvent` — CREATE per Data Model v1.9l §6 if not already in Phase 1: `Id`, `LocationId BIGINT FK → Location.Location.Id`, `DowntimeReasonCodeId BIGINT FK → DowntimeReasonCode.Id NULL` (per B7 — late-binding reason codes), `ShiftId BIGINT FK → Oee.Shift.Id NULL`, `StartedAt`, `EndedAt NULL`, `DowntimeSourceCodeId BIGINT FK → DowntimeSourceCode.Id`, `AppUserId BIGINT FK → AppUser.Id NULL`, `ShotCount INT NULL` (UJ-14 — warm-up shots when ReasonType=Setup), `Remarks NVARCHAR(500) NULL`, `CreatedAt`. Filtered UNIQUE for at-most-one-open per `(LocationId)` per B3.
- Seed `Audit.LogEventType` rows: `DowntimeStarted`, `DowntimeEnded`, `DowntimeReasonAssigned`, `EndOfShiftSubmitted`, `ShiftHandoverAcknowledged`.

**Tables used:** `Oee.Shift`, `Oee.ShiftSchedule`, `Oee.DowntimeEvent`, `Oee.DowntimeReasonCode`, `Oee.DowntimeReasonType`, `Oee.DowntimeSourceCode`, `Lots.PauseEvent` (read at shift end summary), `Lots.LotMovement` + `v_LotDerivedQuantities` (read at shift end summary).

## Open Items Affecting This Phase

| Item | Status |
|---|---|
| **UJ-10** Shift boundary handling | ✅ Closed (Option D). Events span boundaries naturally — no auto-close at Shift_End; the shift-end summary screen surfaces open events for operator awareness. |
| **OI-03** Shift runtime adjustments | ✅ Closed. Availability derived from event durations summed against the shift window — no minute-level adjustments. |
| **UJ-14** Warm-up shots | ✅ Closed (Option A). `DowntimeEvent.ShotCount` only — no `ProductionEventValue.WarmupShotCount`. |
| **A4** ShotCount semantics | Pending Phase 0 — affects how `ProductionEvent.ShotCount` is interpreted; orthogonal to `DowntimeEvent.ShotCount` (warm-up). |

## State & Workflow

### Manual downtime entry

The Downtime Entry top-level view exposes a list of currently-open downtime events at the operator's Cell context (or supervisor's selected scope). The operator can:

- **Start a new downtime event:** select machine, optionally enter reason code immediately (or leave for late-binding per B7), submit. `Oee.DowntimeEvent_Start @LocationId, @DowntimeReasonCodeId NULL, @DowntimeSourceCodeId='Operator', @ShotCount NULL, @AppUserId, @TerminalLocationId`.
- **End an open event:** scan or pick the open event, optionally add remarks, submit. `Oee.DowntimeEvent_End @DowntimeEventId, @Remarks NULL, @AppUserId, @TerminalLocationId`.
- **Assign a reason code to an existing open event** (when the PLC opened it without a reason): `Oee.DowntimeReasonCode_Assign @DowntimeEventId, @DowntimeReasonCodeId, @AppUserId, @TerminalLocationId`. Per B7, this proc refuses to overwrite an already-assigned reason — supervisors correct via other means.

### PLC-driven downtime

The Gateway script `DowntimePlcWatcher` (per machine) watches PLC stop/run edges. On stop edge: opens a `DowntimeEvent` with `DowntimeSourceCode='PLC'` and NULL reason. On run edge: closes the open event with `EndedAt = SYSUTCDATETIME()`. Operator-facing follow-up assigns the reason later via the manual entry view above.

### End-of-shift time entry (FDS-09-013)

About 15 minutes before the operator's shift end (window: -15 min to +15 min around `Oee.Shift.ScheduledEnd`), Perspective surfaces the End-of-Shift Time Entry control on the operator's terminal. Two UX paths per terminal mode:

- **Dedicated terminal:** single button — *"Submit shift time entry."* Tap once. Submits using shift-schedule defaults — lunch + breaks per the operator's `Oee.ShiftSchedule.LunchMinutes` / break configuration. No operator-entered durations.
- **Shared terminal:** form — initials + time category (Regular default; OT / DoubleOT / etc. per shift-schedule definition) + lunch yes/no + breaks selected (from a checkbox list of breaks defined on the shift schedule). Submit.

`Oee.EndOfShiftEntry_Submit @ShiftId, @TimeCategoryCode, @LunchTaken BIT, @BreaksSelectedJson, @AppUserId, @TerminalLocationId`:
1. Validate the shift is open (`Oee.Shift.ActualEnd IS NULL`) and `@AppUserId` is the operator on this shift.
2. For each selected lunch + break: insert a `DowntimeEvent` row with `StartedAt` and `EndedAt` populated from the shift schedule's configured break window, `DowntimeReasonCodeId` set to the appropriate `Lunch` / `Break` reason, `DowntimeSourceCode='Operator'`. **No operator-entered durations.**
3. Audit `EndOfShiftSubmitted`.

There is no `+30` / `+10` / `+110` minute adjustment anywhere — runtime is derived from event durations, not entered.

### Shift_End — open events stay open (UJ-10 Option D)

`Oee.Shift_End` (Phase 1) only updates the `Oee.Shift.ActualEnd` column. It does **not** auto-close any open `DowntimeEvent`, `Lots.PauseEvent`, or `Quality.HoldEvent` rows. Open events span shift boundaries naturally — the incoming shift's operator closes them when the machine resumes (per FDS-09-010 + OI-03).

### Shift-end summary screen (FDS-09-015)

When the operator submits the End-of-Shift Time Entry (Dedicated single-button or Shared form), Perspective navigates to the Shift-end Summary view. The view is read-only and surfaces three lists for handover awareness:

1. **Open downtime events** at the operator's Cell — `DowntimeEvent` rows with `EndedAt IS NULL` and `LocationId` matching.
2. **Open paused LOTs** at the operator's Cell — `LotPause_GetByLocation @LocationId`.
3. **In-process LOTs** at the operator's Cell — read of `Lots.Lot` filtered by `CurrentLocationId` = operator's Cell, joined to `Lots.v_LotDerivedQuantities` for header counts.

Operator-acknowledgement (a button at the bottom) writes `ShiftHandoverAcknowledged` to `Audit.OperationLog`. Acknowledgement is optional — the Submit step on the End-of-Shift Time Entry already commits the shift-time data; Acknowledge just confirms the operator reviewed the open-event lists.

**Performance.** The Shift-end Summary's three lists scale with the operator's Cell scope. The `Lots.LotMovement` recommended index `(ToLocationId, MovedAt DESC)` covers the in-process LOTs query. Per OI-35 architectural decisions, this index lives in the Phase 1 migration alongside the LotMovement table CREATE.

### Supervisor dashboard

The Supervisor Dashboard top-level view aggregates across multiple Cells (parent Area or WorkCenter scope). Surfaces:
- Open downtime events with reason / no-reason breakdown (couples to B7 — unclassified downtime is a triage signal).
- Open paused LOTs by Cell.
- Shift availability vs target — derived from event durations per OI-03.
- AIM pool depth per Part Number (couples to Phase 7's AIM Pool Wallboard Tile).
- Print failure stranded count (couples to Phase 6/7 Print Failure Banner).

## API Layer

| Procedure | Parameters | Notes | Output |
|---|---|---|---|
| `Oee.DowntimeEvent_Start` | `@LocationId`, `@DowntimeReasonCodeId NULL`, `@DowntimeSourceCodeId`, `@ShotCount NULL`, `@AppUserId`, `@TerminalLocationId` | Inserts a new event. Per B3, rejects if open event exists for this Location. | `Status, Message, NewId` |
| `Oee.DowntimeEvent_End` | `@DowntimeEventId`, `@Remarks NULL`, `@AppUserId`, `@TerminalLocationId` | Closes the event. Rejects if already closed. | `Status, Message` |
| `Oee.DowntimeReasonCode_Assign` | `@DowntimeEventId`, `@DowntimeReasonCodeId`, `@AppUserId`, `@TerminalLocationId` | Late-binding reason assignment. Refuses overwrite (B7). | `Status, Message` |
| `Oee.EndOfShiftEntry_Submit` | `@ShiftId`, `@TimeCategoryCode`, `@LunchTaken BIT`, `@BreaksSelectedJson`, `@AppUserId`, `@TerminalLocationId` | Per FDS-09-013 — writes DowntimeEvent rows for each selected lunch/break with shift-schedule durations. | `Status, Message, EventCountInserted INT` |
| `Oee.Shift_GetEndOfShiftSummary` | `@ShiftId`, `@CellLocationId NULL` (defaults to terminal's active Cell) | Returns the three lists (open downtime, open pauses, in-process LOTs). | Multi-row: open-downtime rows + open-pause rows + in-process-LOT rows |

## Gateway Scripts

| Script | Purpose | Trigger | External | Audit |
|---|---|---|---|---|
| `DowntimePlcWatcher` (per machine) | Watches PLC stop/run edges. Opens DowntimeEvent on stop with NULL reason; closes on run. | PLC tag edge | PLC (TOPServer) | OperationLog via the procs |
| `EndOfShiftWindowTrigger` (Perspective view-side) | Surfaces the End-of-Shift Time Entry control 15 min before scheduled shift end. View-side timer; no DB state. | Perspective view tick | — | — |

## Perspective Views

| View | Purpose |
|---|---|
| Downtime Entry (purpose-built top-level view) | List of open events at scope; Flex Repeater for the list (per-event embedded view: machine, source, reason-or-NULL, started-at, "End" / "Assign Reason" buttons); Start-new form. |
| End-of-Shift Time Entry (purpose-built top-level view) | Two UX paths via `session.custom.terminal.terminalMode`: Dedicated → single button submit; Shared → form (initials + time category + lunch/break selection). Routes to Shift-end Summary on success. |
| Shift-end Summary (purpose-built top-level view, FDS-09-015) | Three Flex Repeaters — open downtime, open paused LOTs, in-process LOTs at the operator's Cell. Read-only. Acknowledge button writes ShiftHandoverAcknowledged audit row. |
| Supervisor Dashboard (purpose-built top-level view) | Composes wallboard tiles — DowntimeOpenSummary, PausedLotsSummary, ShiftAvailabilityTile, AimPoolWallboardTile, PrintFailureStrandedTile. |

## Test Coverage

New test suite at `sql/tests/0021_PlantFloor_Downtime_Shift/`:

| File | Covers |
|---|---|
| `010_DowntimeEvent_lifecycle.sql` | Start + End; double-start rejects per B3; end-with-no-open rejects. |
| `020_DowntimeReasonCode_Assign.sql` | Late-binding assignment succeeds; overwrite rejects per B7. |
| `030_DowntimeEvent_PLC_pattern.sql` | PLC source code; NULL reason at start; reason assigned later. |
| `040_DowntimeEvent_warmup_shotcount.sql` | UJ-14 — DowntimeEvent.ShotCount on Setup-type events. |
| `050_EndOfShiftEntry_Submit.sql` | Lunch + selected breaks insert correct DowntimeEvent rows with shift-schedule durations; no operator-entered durations accepted; multiple submissions rejected. |
| `060_Shift_GetEndOfShiftSummary.sql` | Three lists return correctly; in-process LOTs query uses the LotMovement (ToLocationId, MovedAt DESC) index. |
| `070_OpenEvents_span_boundary.sql` | Shift_End leaves open DowntimeEvent / PauseEvent / HoldEvent rows untouched per UJ-10 / OI-03. |

Target: 60–80 passing tests in suite 0021.

## Phase 8 complete when

- [ ] Migration `0021_arc2_phase8_downtime_shift.sql` applied. DowntimeEvent CREATEd if not already. Seeds in place.
- [ ] All Phase 8 procs delivered.
- [ ] All tests in `sql/tests/0021_PlantFloor_Downtime_Shift/` pass.
- [ ] Perspective views (Downtime Entry, End-of-Shift Time Entry, Shift-end Summary, Supervisor Dashboard) implemented.
- [ ] Gateway `DowntimePlcWatcher` per machine implemented and tested against PLC simulator.
- [ ] **End-to-end integration check:** PLC opens a downtime event with NULL reason → operator assigns reason via Downtime Entry view → operator runs shift → 15 min before scheduled end, EndOfShiftWindowTrigger surfaces the time-entry control → operator submits (Dedicated single-button) → DowntimeEvent rows for lunch + breaks inserted → Shift-end Summary shows open events; operator acknowledges → next shift's operator closes the open downtime when the machine resumes.

---

## Out of Scope

Explicitly excluded from this plan — handled elsewhere or deferred:

- **OEE Snapshot calculation.** `Oee.OeeSnapshot` table exists in the data model as FUTURE scope. No Phase is dedicated to it; no stored procs, no Gateway scripts. Post-MVP workstream.
- **PD Reports replacement.** The four legacy Productivity Database reports (Die Shot, Rejects, Downtime, Production) are a separate Reporting workstream driven from the data captured here. Ignition Reporting module or an equivalent tool will consume the `ProductionEvent`, `RejectEvent`, `DowntimeEvent`, and `Shift` tables directly. Couples to **UJ-19** + **OI-30** Reports tile contents.
- **Macola integration.** FUTURE — not in this plan.
- **Intelex integration.** FUTURE — NCM / Failure Analysis remains in Intelex separately. Phase 7's hold mechanism is the operational disposition tool in MVP; formal NCM workflows stay in Intelex.
- **Pixel-level Perspective mockups and Perspective JSON project exports.** Functional view descriptions only. Mockup production, if done, is a parallel workstream.
- **Bit-level OPC tag addresses and PLC ladder logic.** See `reference/5GO_AP4_Automation_Touchpoint_Agreement.pdf` and FRS Appendix C.
- **Production-grade PLC firmware changes.** Assumed complete by PLC integrator before Phase 6 commissioning.
- **Material Allocation pre-production workflow** (OI-32). Pending Phase 0 confirmation; default closure direction is "not reproduced — Flexware concept collapses into our existing LOT-at-Lineside-Cell + ConsumptionEvent model."
- **Production schedule advanced uses** (OI-34). Current minimal use (shift-window timing only) is in scope; advanced uses (per-shift target quotas, drift detection, throughput planning) are Phase 0 / post-MVP.

---

## Open Items Affecting This Plan

| Item | Status as of 2026-04-29 | Phase affected | Resolution path |
|---|---|---|---|
| **OI-31** Identifier sequence + rollout shape | ⬜ Open | Phase 1 | Phase 0 Track A workshop |
| **OI-33** AIM pool empty-pool hard-fail | ⬜ Open (HIGH — customer validation) | Phase 6 + Phase 7 | Phase 0 Track A workshop |
| **OI-34** Production schedule leverage | ⬜ Open (MEDIUM) | Phase 8 + post-MVP | Phase 0 Track A workshop |
| **OI-35** Long-horizon scaling / retention / archiving | ⬜ Open (HIGH — gates Phase 1 SQL build) | Phase 0 → Phase 1 migration shape | Phase 0 Track B workshop |
| **FDS-06-030** WorkOrder BIT flags | ⬜ Pending | Phase 1 | Phase 0 Track A workshop |
| **Historical data migration** | ⬜ Pending | Phase 1 | Phase 0 Track A workshop |
| **A4** ShotCount semantics | ⬜ Pending | Phases 3 + 8 | Phase 0 Track A workshop |
| **A5** DefaultScreen + ConfirmationMethod seeding | ⬜ Pending | Phase 1 | Phase 0 Track A workshop |
| **A6** AIM Hold/Update contract detail | ⬜ Pending | Phase 7 | Phase 0 Track A workshop |
| **A7** Label template scope | ⬜ Pending | Phase 6 + Phase 7 | Phase 0 Track A walkthrough; couples to S-09 |
| **A8** OI-32 Material Allocation walkthrough | ⬜ Pending | Phase 6 | Phase 0 Track A walkthrough |
| **UJ-03** Sublot trigger default quantities | 🔶 In Review (Ben) | Phase 5 | Split fires at Machining OUT (per MPP, 2026-06). Default direction shipped (RequiresSubLotSplit BIT on MachiningOut template + N=2 even default); Ben confirms post-MVP whether per-Item override needed |
| **UJ-05** Sort Cage serial migration | ⬜ Open (default direction committed) | Phase 7 | Update-in-place + ContainerSerialHistory is built; awaits MPP Quality + Honda compliance affirmation. Reverts to void-and-recreate if rejected. |
| **UJ-19** PD reports replacement | ⬜ Open | Post-MVP Reporting workstream | Phase 0 Track A enumerates reports; build is separate |
| **OI-24..30 discovery items** | ⬜ Open | Various phases | Handled in respective phase walkthroughs as MPP brings input |

See `MPP_MES_Open_Issues_Register.docx` v2.16 for full text and decision history.

---

## Related Documents

| Document | Version (2026-04-29) | Relevance |
|---|---|---|
| `MPP_MES_SUMMARY.md` | current | Project index, scope matrix overview |
| `MPP_MES_DATA_MODEL.docx` | v1.9l | Every table + view + column referenced in this plan |
| `MPP_MES_FDS.docx` | v0.11m | Functional Design Specification — every FDS-XX-NNN cited |
| `MPP_MES_FDS_CHANGELOG.docx` | tracks v0.11m | Pre-release revision history companion to the FDS |
| `MPP_MES_USER_JOURNEYS.docx` | v0.9 | Arc 2 narrative — this plan is the execution map for the Arc 2 journey |
| `MPP_MES_Open_Issues_Register.docx` | v2.16 | Open items tracking (OI-XX, UJ-XX) |
| `MPP_MES_SEEDING_REGISTRY.docx` | v1.0 | External-data items S-01..S-11 and their phase coupling |
| `MPP_MES_ERD.html` | v1.9i (regen pending v1.9j+l) | Visual ERD — confirm FK linkages |
| `MPP_MES_PHASED_PLAN_CONFIG_TOOL.docx` | v1.7 | Arc 1 plan — predecessor and source of Cross-Cutting Concerns base + Stored Procedure Template |
| `sql_best_practices_mes.md` | current | SQL conventions |
| `sql_version_control_guide.md` | current | Migration + reset workflow |
| `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md` | 2026-04-29 update | Drives Phase 0 Track B (OI-35) decisions |
| `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md` | 2026-04-24 | Background memo for OI-31 rollout-shape decision |
| `reference/5GO_AP4_Automation_Touchpoint_Agreement.pdf` | source | PLC / MIP bit-level protocol |
| `reference/MPP_FRS_Draft.pdf` | Flexware v1.0 | Source FRS — Appendix C (OPC tags), Appendix L (AIM methods), Appendix B (machines), Appendix D (defect codes), Appendix E (downtime codes) |
