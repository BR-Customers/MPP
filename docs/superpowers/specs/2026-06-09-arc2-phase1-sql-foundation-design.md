# Arc 2 Phase 1 — Shop Floor Foundation (SQL Build) — Design

**Date:** 2026-06-09
**Author:** Blue Ridge Automation (Jacques + Claude)
**Status:** Approved design — ready for implementation plan (`writing-plans`) + subagent-driven dispatch.
**Source docs:** `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` v1.3 (Phase 1), `MPP_MES_DATA_MODEL.md` v1.9q, `Meeting_Notes/2026-06-08_Phase0_Decision_Log.md`, `MPP_MES_FDS.md` v1.3.

---

## 1. Purpose & Scope

This spec governs the **SQL foundation** of Arc 2 Phase 1 — the cross-cutting infrastructure every downstream plant-floor phase depends on. It is the first of two pushes:

- **THIS push (in scope):** migration `0020_arc2_phase1_shop_floor_foundation.sql`, all Phase 1 stored procedures, and the `sql/tests/0020_PlantFloor_Foundation/` test suite, fully green (target 80–105 tests).
- **Follow-on push (OUT of scope here):** the Ignition layer — `Terminal_ResolveFromSession`, `ShiftBoundaryTicker`, `PartitionMaintenance` Gateway scripts + the 7 Perspective views. These need a live Designer/Perspective session to smoke and are tracked separately. **Design note:** the partition sliding-window logic lives in a testable stored proc *in this push* so the future `PartitionMaintenance` Gateway timer is a thin caller (per Cross-Cutting B4 — Gateway scripts never execute raw DML).

**Execution model:** subagent-driven-development (fresh implementer per task + two-stage spec-then-quality review per task), per the eligibility-editors precedent. The **partitioning infrastructure (Task group A) is built in-session / by a single dedicated agent** because it is the only piece with no existing pattern in the repo; the well-specified proc families parallelize cleanly.

---

## 2. Phase 0 inputs (ratified — drive this build)

From the Phase 0 Decision Log (2026-06-08). These are settled; this build implements them, it does not re-decide them.

| Ref | Decision | Phase 1 build consequence |
|---|---|---|
| **B2** | Monthly RANGE partitioning + sliding-window on Arc-2 high-volume event tables | Partition function + scheme in `0020`. **Excludes** `HoldEvent` (Phase 7) / `DowntimeEvent` (Phase 8) per C-4/C-5 pin. |
| **B3** | Columnstore on aged partitions | **Deferred** — partition design must stay columnstore-compatible; nothing built. |
| **B4** | `LotGenealogyClosure` materialized closure table | CREATE in `0020`. Phase 1 writes only the self-row (`Depth=0`) in `Lot_Create`. |
| **B5** | Materialized `TotalInProcess` / `InventoryAvailable` on `Lots.Lot` | Columns on `Lot` CREATE + `Lots.v_LotDerivedQuantities` diagnostic fallback view. `Lot_Create` seeds `0` / `@PieceCount`. Update paths are Phase 3+. |
| **B6** | Row-locked `IdentifierSequence_Next` (NOT SQL `SEQUENCE`) | Table-backed proc; gap-free; `MESL{0:D7}` / `MESI{0:D7}`; 9,999,999 rollover. **Seed floor ≈ 3,000,000** (integration constraint); exact per-sequence seed is a *cutover* gate (owed from Ben), **not a build gate** — build on the floor, mark provisional. |
| **B7** | Split `Audit.OperationLog` → 7-yr `OperationLog` + 20-yr `Lots.LotEventLog` | New `LotEventLog` (born partitioned); `Audit_LogOperation` routes lot-events to it. **Low blast radius** — `Audit_LogOperation` is currently referenced only by its own definition; Arc 1 audits to `ConfigLog`. |
| **B8** | Filtered indexes on hot subsets | Known ones at CREATE (active/non-deprecated, in-process lots, open events); add reactively later. |
| **A4** | ShotCount = cumulative counter | `ProductionEvent.ShotCount` documented as cumulative (no per-event derivation). |
| **A2/T004** | WorkOrder BIT-flag set | Ship the documented set (Camera, Scale, GroupTargetWeight+tol+UOM, RecipeNumber, TrayQuantity, ReturnableDunnage, Customer); MPP prunes dead flags before cutover. |
| **A5/T005** | Workstation `DefaultScreen` + `ConfirmationMethod` | Build the LocationAttributeDefinition seeds; per-Cell **values** owed from MPP (deployment-time seed, not a schema blocker). |
| **UJ-03/T008** | Sub-LOT split | NO auto even-split default (Phase 2+ concern; noted here only for continuity). |

---

## 3. Partitioning design (the novel piece — fully specified)

No partition function/scheme exists anywhere in the repo today; this section is normative for every partitioned table in `0020` and for the partitioned tables in later phases.

### 3.1 Sliding-window mechanism: `TRUNCATE … WITH (PARTITIONS(…))`, not `SWITCH`

Retention (B1) is **destructive age-out** (7-yr operational / 20-yr Honda, then delete; no archive-to-coldstore in MVP — B3 deferred). Partition-level `TRUNCATE` (SQL 2016+) empties the aged partition in place — instant, minimally logged, **and requires no aligned unique indexes**, unlike `SWITCH OUT`. This preserves the project's singleton `BIGINT IDENTITY Id` PK convention.

**Accepted trade-off / one-way-door mitigation:** if archive-before-purge is ever required, the maintenance proc `SELECT`s the aging partition's rows to an archive target *then* truncates — no aligned-index requirement, trivial monthly cost over one partition. First TRUNCATE does not fire for 7 years; ample runway to revisit.

### 3.2 Index / PK structure (per partitioned table)

- **Clustered index = the partition-aligned hot-path index.** It must contain the partition column (for alignment) and should lead with the dominant access key. E.g. `ProductionEvent`: clustered `(LotId, EventAt)` on the partition scheme — this *is* the plan's required `(LotId, EventAt)` index, gained for free; inserts land at the newest partition tail (append-friendly).
- **`Id` stays a `NONCLUSTERED PRIMARY KEY`** — convention preserved, single-column FK targets preserved (the one child FK, `ProductionEventValue → ProductionEvent`, references bare `Id`).
- Accepted cost: bare-`Id` point lookups cost one extra logical lookup — negligible; real access paths are `LotId` / `EventAt`.

### 3.3 Boundaries, filegroup, function/scheme

- **`RANGE RIGHT`, monthly boundaries** at month-firsts (UTC).
- **Single `PRIMARY` filegroup** — the partition scheme maps all partitions to `PRIMARY`. Keeps dev reset trivial; design-compatible with later remap of cold partitions to cheaper storage / columnstore (a scheme change, not a table rebuild).
- One shared monthly partition **function** per datatype/grain (all these tables partition `DATETIME2(3)` monthly, so a single `pf_MonthlyUtc` function + one `ps_MonthlyUtc` scheme can be reused across tables — confirm SQL Server allows scheme reuse across tables, which it does).
- **Seed window:** boundaries from ~2 months before the cutover anchor through ~13 months ahead, created in the migration. Anchor date is a migration constant (documented; not `GETDATE()`-derived so reset is deterministic — see Risks).

### 3.4 Born-partitioned vs repartitioned tables

- **Born partitioned (net-new Arc-2 tables):** created directly on `ps_MonthlyUtc`. `ProductionEvent`, `ConsumptionEvent`, `RejectEvent` (`EventAt`); `LotMovement` (`MovedAt`); `LotStatusHistory` (`ChangedAt`); `LotEventLog` (`CreatedAt`/`LoggedAt` — confirm vs DM).
- **Repartitioned (pre-existing from `0001`):** `Audit.OperationLog`, `Audit.InterfaceLog`, `Audit.FailureLog` already exist unpartitioned. Migration rebuilds their clustered index onto `ps_MonthlyUtc` (trivial on empty/near-empty tables; at fresh prod deploy they are empty). Implementer confirms each one's existing timestamp column and existing index shape before rebuild.

### 3.5 Maintenance proc (testable now; Gateway-callable later)

`Audit.Partition_MaintainWindow @AsOfUtc DATETIME2(3)` (schema/name TBD in plan):
- `SPLIT RANGE` to ensure the next month's boundary exists.
- For each partitioned table whose retention class says the oldest partition is now past its window: `TRUNCATE … WITH (PARTITIONS(<oldest>))` then `MERGE RANGE` to collapse the empty boundary.
- Logs each partition operation to `OperationLog`.
- Covered by the `0020` test suite (drive `@AsOfUtc` across a synthetic boundary; assert split/truncate/merge effects). The follow-on `PartitionMaintenance` Gateway timer calls this proc only.

---

## 4. Migration `0020` contents

Single versioned migration `sql/migrations/versioned/0020_arc2_phase1_shop_floor_foundation.sql`. Ordering: partition function/scheme → net-new table CREATEs → repartition existing audit tables + B7 `LotEventLog` → views → filtered indexes → seeds.

**Net-new tables** (full column contracts per Data Model v1.9q — implementer pulls exact columns from DM, does not invent):
- `Workorder.WorkOrder` (+ A2 BIT flags), `Workorder.WorkOrderOperation`, `Workorder.ProductionEvent` (+ `(LotId, EventAt)` clustered/partitioned), `Workorder.ProductionEventValue`, `Workorder.ConsumptionEvent`, `Workorder.RejectEvent`.
- `Lots.IdentifierSequence` (seed `Lot` / `SerializedItem` rows at ~3,000,000 floor, flagged provisional-for-cutover).
- `Lots.Lot` — full v1.9q contract incl. `ToolId` / `ToolCavityId` (NULL FK), `CrtActive BIT NOT NULL DEFAULT 0` (FDS-10-012 hook; CRT workflow is Phase 9), B5 `TotalInProcess` / `InventoryAvailable`.
- `Lots.LotStatusHistory`, `Lots.LotMovement` (born partitioned).
- `Lots.LotGenealogyClosure` (B4) — `(AncestorLotId, DescendantLotId, Depth)`, PK `(AncestorLotId, DescendantLotId)`, indexed both directions. **Note:** `LotGenealogy` / `LotAttributeChange` / `LotLabel` themselves are **Phase 2** (first writers there); only the closure self-row path is exercised here.
- `Lots.LotEventLog` (B7) — `OperationLog` row shape + `LotId BIGINT NOT NULL FK → Lots.Lot.Id`, born partitioned, 20-yr class.

**Views:**
- `Parts.v_EffectiveItemLocation` — Direct ∪ BOM-derived eligibility (FDS-02-012), read by `Lot_Create`.
- `Lots.v_LotDerivedQuantities` — B5 diagnostic fallback (aggregates events → derived quantities).

**Seeds:**
- LocationAttributeDefinition on `Terminal` type: `DefaultScreen` (NVARCHAR), `RequiresCompletionConfirm` (BIT, OI-16). No `TerminalMode` (derived from parent tier, OI-08). No `IdleTimeoutSeconds` / `RequiresReauthForSensitive` (Perspective-layer / per-action AD).
- LocationAttributeDefinition on Cell-tier types: `ConfirmationMethod` (Vision/Barcode/Both). (`CoupledDownstreamCellLocationId` is already a typed column from `0019` — not re-seeded.)
- Fallback `Terminal` Location row (global default for unregistered IP).
- `Audit.LogEventType` rows as needed: `ShiftStarted`, `ShiftEnded`, `LotCreated`, `LotStatusChanged`, `LotMoved`, `ElevationGranted`, `ElevationDenied` (+ any partition-op event type).
- `IpAddress` attribute index on `Location.LocationAttribute` if missing.

**ASCII-only** seed strings (project convention — byte-scan before apply).

---

## 5. Stored procedures

Contracts are fully specified in the Phase 1 plan §"API Layer" (do not redefine — implement to that table). Families:

| Family | Procs |
|---|---|
| Terminal | `Location.Terminal_GetByIpAddress`, `Location.Terminal_List` |
| AppUser | `Location.AppUser_GetByInitials`, `Location.AppUser_AuthenticateAd`, `Location.AppUser_GetRoles` |
| Shift | `Oee.Shift_Start`, `Oee.Shift_End`, `Oee.Shift_GetActive`, `Oee.Shift_GetOpen` |
| Lot core | `Lots.Lot_Create`, `Lots.IdentifierSequence_Next`, `Lots.Lot_Get`, `Lots.Lot_List`, `Lots.Lot_UpdateStatus`, `Lots.Lot_MoveTo`, `Lots.Lot_AssertNotBlocked` |
| Audit | `Audit.Audit_LogOperation` (B7 routing) |
| Maintenance | `Audit.Partition_MaintainWindow` (§3.5) |

**Convention compliance (Cross-Cutting + CLAUDE.md):** no OUTPUT params (`SELECT @Status, @Message, @NewId[, @MintedLotName]` terminal row on mutations; empty result set = not-found on reads); `RAISERROR` in nested CATCH; schema-qualified; B1 operator/terminal context params (`@AppUserId`, `@TerminalLocationId`) on mutations; B2 `Lot_AssertNotBlocked` guard on every LOT-advancing proc; audit-readable `Description` convention via `Audit.ufn_MidDot` / `ufn_TruncateActivity`. `IdentifierSequence_Next` mints **inside** the `Lot_Create` transaction (rollback doesn't burn a counter — the whole point of B6 row-lock over `SEQUENCE`).

**Explicitly NOT delivered:** clock#/PIN auth procs (columns dropped in `0011`). Grep gate: `ClockNumber` / `PinHash` → zero hits in active SQL.

---

## 6. Test suite `sql/tests/0020_PlantFloor_Foundation/`

Per the plan §"Test Coverage" (target 80–105). Files: `010_Terminal_GetByIpAddress`, `020_AppUser_GetByInitials`, `025_AppUser_AuthenticateAd`, `030_Shift_lifecycle`, `035_IdentifierSequence`, `040_Lot_Create`, `045_LotGenealogyClosure_self`, `050_Lot_Get_List`, `060_Lot_UpdateStatus`, `070_Lot_MoveTo`, `080_Lot_AssertNotBlocked`, **`090_Partition_MaintainWindow`** (new — split/truncate/merge across a synthetic boundary; assert aged partition emptied, next boundary created, no data loss in in-window partitions). Use the `test.Assert_*` framework (not raw RAISERROR). INSERT-EXEC into temp tables matching each proc's SELECT shape.

---

## 7. Subagent task decomposition (for dispatch)

Dependency-ordered. **A is in-session / single dedicated agent** (novel); B–F parallelize after A lands; G is integration.

- **Task A — Partitioning infrastructure + migration skeleton.** Partition function/scheme, the maintenance proc, and the migration file skeleton with ordering. Net-new tables created born-partitioned here as stubs OR coordinated with B (see plan). Includes `090_Partition_MaintainWindow` tests. *In-session.*
- **Task B — Lot core tables + procs + tests.** `Lot`, `LotStatusHistory`, `LotMovement`, `IdentifierSequence`, `LotGenealogyClosure`, `v_LotDerivedQuantities`; `Lot_Create` / `IdentifierSequence_Next` / `Lot_Get` / `Lot_List` / `Lot_UpdateStatus` / `Lot_MoveTo` / `Lot_AssertNotBlocked`; tests `035/040/045/050/060/070/080`. (Depends on A for partition scheme + on `v_EffectiveItemLocation` from E.)
- **Task C — Terminal resolution.** `Terminal_GetByIpAddress` / `Terminal_List` + seeds (Terminal attr defs, fallback Terminal, IP index); test `010`.
- **Task D — AppUser presence + AD elevation.** `AppUser_GetByInitials` / `AppUser_AuthenticateAd` / `AppUser_GetRoles`; tests `020/025`. Includes `LogEventType` elevation seeds.
- **Task E — WorkOrder family + eligibility view.** `WorkOrder` (+ A2 flags) / `WorkOrderOperation` / `ProductionEvent` / `ProductionEventValue` / `ConsumptionEvent` / `RejectEvent` (born partitioned, clustered `(LotId, EventAt)`); `Parts.v_EffectiveItemLocation`. (No procs in Phase 1 beyond CREATE; events are written Phase 3+.)
- **Task F — Audit split + Shift runtime.** `Audit_LogOperation` B7 routing + `LotEventLog` CREATE + repartition existing audit tables; `Shift_*` procs; test `030`. Seed remaining `LogEventType` rows.
- **Task G — Integration + full-suite green + sign-off checks.** Reset-DevDatabase discovers `0020`; full suite green to target; `ClockNumber`/`PinHash` grep gate; `Audit_LogOperation` event-type resolution check; holistic cross-cutting review.

---

## 8. Risks & verify-items

1. **Dev edition supports partitioning.** SQL 2022 Standard/Dev does (since 2016 SP1). Confirm dev isn't Express before Task A. *Mitigation:* a one-line `SERVERPROPERTY('EngineEdition')` check.
2. **Deterministic reset with date-based boundaries.** Partition boundaries must NOT derive from `GETDATE()` at migration time (non-deterministic reset / drifting tests). Use a fixed documented **anchor constant** in the migration; the maintenance proc takes `@AsOfUtc` so tests are deterministic.
3. **Shared partition scheme across many tables.** Confirm a single `ps_MonthlyUtc` can back all partitioned tables (it can — schemes are reusable). Keeps maintenance uniform.
4. **Repartitioning existing audit tables** is a clustered-index rebuild — verify each existing index shape (`0001`) before the rebuild statement; ensure no Arc-1 proc/test depends on the current clustered key.
5. **B6 seed is provisional.** `IdentifierSequence` seeded at ~3M floor with a clear comment; exact cutover seed (Ben) reconciled at deployment, not now.
6. **`Lot_Create` depends on `v_EffectiveItemLocation`** (Task E output) — sequence E's view before B's `Lot_Create` tests, or stub the view.

---

## 9. Out of scope (follow-on push)

Gateway scripts (`Terminal_ResolveFromSession`, `ShiftBoundaryTicker`, `PartitionMaintenance`) and the 7 Perspective views (Initials Entry, Terminal Selector, Cell Context Selector, Home Router, Idle Re-Confirm, per-mutation Initials field, Elevation Modal). They consume the procs delivered here and require a live Designer/Perspective session to smoke.

**Phase 0 doc tail (non-blocking):** the T009 staged sign-off Blocks 1–5 still need pasting into the canonical docs (DM § Scaling Decisions, FDS §11 retention + B10, OIR closure, plan validation pins). Decisions are already captured in the decision log; this is documentation hygiene, trackable independently.
