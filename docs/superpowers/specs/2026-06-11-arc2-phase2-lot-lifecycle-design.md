# Arc 2 Phase 2 — LOT Lifecycle Completion (SQL Foundation)

**Date:** 2026-06-11
**Status:** Approved (Jacques, in-session)
**Scope:** Migration `0021` + ~15 stored procedures + test suite `0021_PlantFloor_Lot_Lifecycle/`. SQL-first push; the four Perspective views (LOT Detail, LOT Search, Genealogy Viewer, Paused-LOT Indicator) are a deferred follow-on, exactly as Phase 1 ran.
**Authority:** `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` Phase 2 section; `sql_best_practices_mes.md`; `MPP_MES_FDS.md` §5 (FDS-05-*). Builds on the Phase 1 foundation (migration `0020`, suite `0020_PlantFloor_Foundation/`, currently 1308/1308).

---

## 1. Purpose

Phase 1 delivered the LOT *skeleton* — `Lots.Lot` + `LotStatusHistory` + `LotMovement` + the `LotGenealogyClosure` self-row + the B5 materialized columns + `Lot_Create` / `Lot_Get` / `Lot_List` / `Lot_MoveTo` / `Lot_UpdateStatus` / `Lot_AssertNotBlocked`. Phase 2 fills out the **complete LOT surface** so every downstream operator-station phase composes against a stable API:

- Full header-mutation surface with field-level audit (`Lot_Update`, `Lot_UpdateAttribute`).
- Full genealogy: split, merge, consumption — each maintaining the **B4 closure table** transactionally alongside the append-only `LotGenealogy` edge table.
- Genealogy + history reads (`Lot_GetGenealogyTree`, `_GetParents`, `_GetChildren`, `_GetAttributeHistory`).
- LTT label print/reprint with **SQL-side ZPL rendering** from a DB template.
- Operator-driven LOT pause lifecycle (OI-21).

## 2. Decisions locked this session

1. **Build shape — SQL-first, Ignition follow-on.** This spec/plan covers migration `0021` + procs + test suite only. The four Perspective views get their own push once the SQL contract is green.
2. **Sublot naming — parent-derived suffix.** `Lot_Split` children are named `<ParentLotName>-NN` (zero-padded `D2`). Not a separate `SL` sequence, not fresh MESL numbers. Lineage is readable on the identifier itself; the B6 `IdentifierSequence` is **not** consulted for split children (it is still used by `Lot_Merge` for the fresh primary output). See §4.1 for concurrency control.
3. **ZPL rendering — SQL renders from a DB template.** New `Lots.LabelTemplate` table holds an ASCII ZPL body per `LabelTypeCode`; `LotLabel_Print` resolves placeholders and stores + returns the final ZPL. The gateway only dispatches the returned string (B17 async, later phase). Keeps label content proc-enforced and assertable in the test suite, consistent with `feedback_no_business_logic_in_python`.
4. **Build approach — single migration `0021`, domain-grouped subagent tasks** (5 groups, fresh implementer + spec/quality review per task, integration sign-off at the end). Same pattern as Phase 1 and the eligibility editors.
5. **`LabelTemplate` is its own table**, not a `ZplTemplate` column on the `LabelTypeCode` lookup — keeps the code table a pure lookup.

## 3. Data Model — migration `0021_arc2_phase2_lot_lifecycle.sql`

All DDL guarded on current state (re-run = no-op), per the Phase 1 migration convention. `BIGINT IDENTITY` surrogate `Id`, `NVARCHAR`, `DATETIME2(3)`, `DECIMAL`, FK-backed code columns, append-only event tables.

### 3.1 New tables

**`Lots.LotGenealogy`** (FDS-05-016) — append-only edge table. Born-partitioned on `EventAt` (20-yr Honda class; mirrors `LotEventLog` / `LotStatusHistory` partition treatment: aligned composite PK `(Id, EventAt)` NONCLUSTERED `ON ps_MonthlyUtc(EventAt)` + clustered index on the hot path). Columns:

| Column | Type | Notes |
|---|---|---|
| `Id` | `BIGINT IDENTITY` | |
| `ParentLotId` | `BIGINT NOT NULL` | FK → `Lots.Lot.Id` |
| `ChildLotId` | `BIGINT NOT NULL` | FK → `Lots.Lot.Id` |
| `RelationshipTypeId` | `BIGINT NOT NULL` | FK → `Lots.GenealogyRelationshipType.Id` (Split=1, Merge=2, Consumption=3 — seeded in `0004`) |
| `PieceCount` | `INT NULL` | child's share (Split) / consumed qty (Consumption) |
| `EventUserId` | `BIGINT NOT NULL` | FK → `Location.AppUser.Id` |
| `TerminalLocationId` | `BIGINT NULL` | FK → `Location.Location.Id` |
| `EventAt` | `DATETIME2(3) NOT NULL` | `DEFAULT SYSUTCDATETIME()`; partition key |

Clustered hot path: `CIX_LotGenealogy_ParentEventAt (ParentLotId, EventAt) ON ps_MonthlyUtc(EventAt)`; aligned secondary `IX_LotGenealogy_Child (ChildLotId, EventAt) ON ps_MonthlyUtc(EventAt)` for child→parent lookups. Register in `Audit.PartitionRetention` at 240 months.

**`Lots.LotAttributeChange`** (FDS-05-021) — append-only field-diff log. Columns: `Id`, `LotId BIGINT NOT NULL FK→Lots.Lot.Id`, `AttributeName NVARCHAR(100) NOT NULL`, `OldValue NVARCHAR(500) NULL`, `NewValue NVARCHAR(500) NULL`, `ChangedByUserId BIGINT NOT NULL FK→AppUser.Id`, `TerminalLocationId BIGINT NULL FK→Location.Id`, `ChangedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()`. Not partitioned in Phase 2 (low volume; index `IX_LotAttributeChange_Lot (LotId, ChangedAt)`).

**`Lots.LotLabel`** (FDS-05-019) — append-only LTT print log. Columns: `Id`, `LotId BIGINT NOT NULL FK→Lots.Lot.Id`, `LabelTypeCodeId BIGINT NOT NULL FK→Lots.LabelTypeCode.Id`, `PrintReasonCodeId BIGINT NOT NULL FK→Lots.PrintReasonCode.Id`, `ParentLotId BIGINT NULL FK→Lots.Lot.Id` (sublot labels per FDS-05-024; NULL for non-sublot), `ZplContent NVARCHAR(MAX) NOT NULL` (the rendered, ready-to-dispatch ZPL), `PrinterName NVARCHAR(100) NULL`, `PrintedByUserId BIGINT NOT NULL FK→AppUser.Id`, `TerminalLocationId BIGINT NULL FK→Location.Id`, `PrintedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()`. Index `IX_LotLabel_Lot (LotId, PrintedAt)`.

**`Lots.PauseEvent`** (OI-21 / FDS-05-038) — place + close lifecycle, mirrors `Quality.HoldEvent`. Columns: `Id`, `LotId BIGINT NOT NULL FK→Lots.Lot.Id`, `LocationId BIGINT NOT NULL FK→Location.Location.Id` (Cell-tier), `PausedByUserId BIGINT NOT NULL FK→AppUser.Id`, `PausedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()`, `PausedReason NVARCHAR(500) NULL`, `ResumedByUserId BIGINT NULL FK→AppUser.Id`, `ResumedAt DATETIME2(3) NULL`, `ResumedRemarks NVARCHAR(500) NULL`. Constraints:
- `CK_PauseEvent_ResumePaired` — `ResumedByUserId` / `ResumedAt` set together or both NULL.
- Filtered `UQ_PauseEvent_OpenLotLocation (LotId, LocationId) WHERE ResumedAt IS NULL` — at most one open pause per `(LotId, LocationId)` (B3 open-event invariant; same LOT MAY be paused at multiple Cells concurrently).
- `IX_PauseEvent_OpenByLocation (LocationId) WHERE ResumedAt IS NULL` — Paused-LOT indicator counter.
- `IX_PauseEvent_Lot (LotId, PausedAt DESC)` — per-LOT pause history.

### 3.2 New table — `Lots.LabelTemplate`

1:1 with `LabelTypeCode`, holds the ASCII ZPL body. Columns: `Id BIGINT IDENTITY`, `LabelTypeCodeId BIGINT NOT NULL FK→Lots.LabelTypeCode.Id`, `ZplBody NVARCHAR(MAX) NOT NULL` (ASCII-only — verified by byte scan per `feedback_ascii_only_seed_data`), `DeprecatedAt DATETIME2(3) NULL`, plus the standard `CreatedAt`/`CreatedByUserId` if a writer proc is later added (Phase 2 seeds them directly). `UQ_LabelTemplate_ActiveType` filtered UNIQUE on `(LabelTypeCodeId) WHERE DeprecatedAt IS NULL` — one active template per label type. The `ZplBody` uses `{Placeholder}` tokens (see §4.4).

### 3.3 Seeds (in-migration)

- `Audit.LogEventType` rows (insert-if-missing by Code): `LotUpdated`, `LotSplit`, `LotMerged`, `LotConsumed`, `LotPaused`, `LotResumed`, `LabelPrinted`.
- `Audit.LogEntityType` rows (insert-if-missing): `LotLabel`, `PauseEvent` (and `LotGenealogy` if not already present).
- `Lots.LabelTemplate` rows: one ASCII ZPL body per active `LabelTypeCode` (Primary, Container, Master, Void). Bodies are minimal valid ZPL with `{LotName}`, `{ParentLotNumber}`, `{ItemCode}`, `{PieceCount}`, `{PrintedAt}` tokens — refined when the physical Zebra format is confirmed, but functional + assertable now.

### 3.4 Not touched

`v_LotDerivedQuantities` (B5 diagnostic view) and the `Lot.TotalInProcess` / `Lot.InventoryAvailable` materialized columns already shipped in `0020`. Phase 2 **maintains** the materialized columns where a Phase 2 proc changes `PieceCount` (see §4.1); it does not recreate the view. Precise OEE-grade event-driven recalculation stays with the Phase 3+ `ProductionEvent_Record` / `ConsumptionEvent_Record` writers, per the `0020` view comment.

## 4. State & Workflow

### 4.1 Mutations — `Lot_Update`, `Lot_UpdateAttribute`

`Lot_Update(@LotId, @PieceCount NULL, @Weight NULL, @WeightUomId NULL, @VendorLotNumber NULL, @RowVersion, @AppUserId, @TerminalLocationId)`:
1. `Lot_AssertNotBlocked` (B2 — even corrections on a held LOT are rejected; release the hold first).
2. Optimistic-lock check against `@RowVersion`; reject on stale.
3. Compare each mutable field to current; for each change, insert a `LotAttributeChange` row (`AttributeName`, `OldValue`, `NewValue`).
4. `UPDATE Lots.Lot` with new values; `UpdatedAt` / `UpdatedByUserId` set; `RowVersion` auto-bumps.
5. **B5:** if `PieceCount` changed, recompute `InventoryAvailable` consistently (Phase 2 keeps it equal to `PieceCount` net of any already-recorded consumption; precise event-driven formula is Phase 3).
6. `Audit_LogOperation` with `LogEventType='LotUpdated'`, resolved-FK Old/New JSON.

`Lot_UpdateAttribute(@LotId, @AttributeName, @NewValue, @AppUserId, @TerminalLocationId)` — single-field helper used internally by `Lot_Split` to reduce parent `PieceCount`; writes one `LotAttributeChange` row.

### 4.2 Genealogy writes — `Lot_Split`, `Lot_Merge`, `LotGenealogy_RecordConsumption`

**`Lot_Split(@ParentLotId, @ChildrenJson, @AppUserId, @TerminalLocationId)`** — `@ChildrenJson` = array of `{pieceCount, currentLocationId}`.
1. `BEGIN TRANSACTION`; read the parent `Lot` row with `UPDLOCK, HOLDLOCK` — this **serializes concurrent splits of the same parent** so child suffix allocation cannot collide.
2. `Lot_AssertNotBlocked` on parent.
3. Validate: `SUM(child.pieceCount) <= parent.PieceCount`; ≥1 child.
4. Determine the next suffix ordinal: `MAX` existing `-NN` suffix among direct children of `@ParentLotId` (parse from `LotName`), default 0 → start at 1. Reject if it would exceed 99.
5. For each child spec, in order:
   - `Lot_Create` the child (inherits parent's machined `ItemId`; `ToolId`/`ToolCavityId` = NULL per FDS-05-023 note — sublots are Machining LOTs) with `LotName = '<ParentLotName>-' + FORMAT(ordinal,'00')`, `ParentLotId = @ParentLotId`. `Lot_Create` already seeds the closure self-row `(C,C,0)` + first `LotMovement` + `Good` status row.
   - Insert `LotGenealogy (ParentLotId, ChildLotId, RelationshipType=Split, PieceCount=child share, ...)`.
   - **Closure (B4):** `INSERT INTO LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) SELECT AncestorLotId, @ChildId, Depth + 1 FROM LotGenealogyClosure WHERE DescendantLotId = @ParentLotId` (every ancestor of P, including P's own self-row, becomes an ancestor of C at depth+1).
   - increment ordinal.
6. Reduce parent `PieceCount` by `SUM(children)` via `Lot_UpdateAttribute`. If residual = 0, `Lot_UpdateStatus` parent → `Closed`.
7. `Audit_LogOperation` `LogEventType='LotSplit'`. `COMMIT`.
8. Return the minted children. **Single result set** (JDBC rule): the caller needs `ChildLotId, ChildLotName, PieceCount` per child plus the operation status — the plan resolves the exact shape (status columns on each child row, vs. status-only + a sibling `Lot_GetChildren` read). See §8.

**`Lot_Merge(@SourceLotIdsJson, @OutputItemId, @OutputLocationId, @AppUserId, @TerminalLocationId)`** — per FDS-05-025..030 + UJ-08 (Option A):
1. Validate ≥2 sources; `Lot_AssertNotBlocked` on each.
2. Rules: all sources same `ItemId`; all sources `Good`; die-rank-compat check when sources differ in `ToolId` (consult `Tools.DieRankCompatibility`, S-08; reject with a clear message until the matrix is populated — supervisor AD override from FDS-04-007 is the escape hatch and is honored when the caller supplies an elevated context).
3. `Lot_Create` the merged output: **fresh MESL** from `IdentifierSequence_Next` (merge output is a new primary LOT, not a sublot), `ToolId = NULL`, `ToolCavityId = NULL` (blended origin; Tool-specific trace reconstructed via the genealogy walk per FDS-05-030).
4. For each source: insert `LotGenealogy (Parent=source, Child=output, RelationshipType=Merge, ...)`; `Lot_UpdateStatus` source → `Closed`.
5. **Closure (B4), ancestor-dedup:** `INSERT INTO LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) SELECT AncestorLotId, @OutputId, MIN(Depth) + 1 FROM LotGenealogyClosure WHERE DescendantLotId IN (<sources>) GROUP BY AncestorLotId` — shared ancestors across sources collapse to one row at the minimum depth (closure PK `(Ancestor, Descendant)` forbids duplicates).
6. `Audit_LogOperation` `LogEventType='LotMerged'`. Return `Status, Message, NewId`.

**`LotGenealogy_RecordConsumption(@SourceLotId, @ConsumedPieceCount, @ProducedLotId NULL, @ProducedContainerId NULL, @ProducedSerialNumber NULL, @AppUserId, @TerminalLocationId)`** — narrow internal proc (called by Phase 5 Machining IN + Phase 6 Assembly). Inserts the `LotGenealogy (Parent=source, Child=produced, RelationshipType=Consumption, PieceCount=consumed)` row; closure rows when `@ProducedLotId` is present (single-edge insert as for one merge source). Returns `Status, Message, NewId`.

### 4.3 Genealogy + history reads

- **`Lot_GetGenealogyTree(@LotId, @Direction = 'Both')`** — **closure-backed** (B4 elected): `Ancestors` = `closure WHERE DescendantLotId=@LotId`; `Descendants` = `closure WHERE AncestorLotId=@LotId`; `Both` = union. Flat rowset with `LotId, LotName, ItemCode, Depth, RelationshipType, Direction`. O(1) per row — no recursion; Honda year-15 audits stay fast regardless of partition count. (The recursive-CTE variant is the documented fallback if B4 were ever disabled; not built, since B4 is elected.)
- **`Lot_GetParents(@LotId)`** / **`Lot_GetChildren(@LotId)`** — one-hop, from `LotGenealogy` (Depth-1 closure rows).
- **`Lot_GetAttributeHistory(@LotId)`** — UNION of `LotAttributeChange` + `LotStatusHistory` + `LotMovement`, ordered by time, normalized to a common `(EventAt, EventKind, Detail, ByUser)` shape.

### 4.4 Labels — `LotLabel_Print`, `LotLabel_Reprint`

**`LotLabel_Print(@LotId, @LabelTypeCodeId, @PrintReasonCodeId, @AppUserId, @TerminalLocationId)`**:
1. Resolve the active `LabelTemplate.ZplBody` for `@LabelTypeCodeId` (reject if none active).
2. Resolve label fields from `Lot` + `Item` (+ parent LOT name when `Lot.ParentLotId` is set → also set `LotLabel.ParentLotId` for the FDS-05-024 sublot rule).
3. Render: `REPLACE` each `{Token}` in `ZplBody` with its resolved value (`{LotName}`, `{ParentLotNumber}`, `{ItemCode}`, `{PieceCount}`, `{PrintedAt}`). Rendering is deterministic string substitution — no business logic.
4. Insert the `LotLabel` row with the rendered `ZplContent`.
5. `Audit_LogOperation` `LogEventType='LabelPrinted'`. Return `Status, Message, NewId, ZplContent`.

**`LotLabel_Reprint(@LotId, @PrintReasonCodeId, @AppUserId, @TerminalLocationId)`** — convenience wrapper resolving the LOT's existing/primary `LabelTypeCode`, forcing a non-`Initial` reason; same return shape. Original `LotLabel` rows are never modified (append-only).

### 4.5 Pause lifecycle — 4 procs

- **`LotPause_Place(@LotId, @LocationId, @PausedReason NULL, @AppUserId, @TerminalLocationId)`** — `Lot_AssertNotBlocked`; reject if an open pause already exists for `(LotId, LocationId)` (B3, enforced by the filtered UNIQUE + a pre-check for a clean message). Insert open `PauseEvent`. `Audit_LogOperation` `LotPaused`. Return `Status, Message, NewId`.
- **`LotPause_Resume(@PauseEventId, @ResumedRemarks NULL, @AppUserId, @TerminalLocationId)`** — reject if already resumed; set the resume columns (resumer MAY differ from pauser). `Audit_LogOperation` `LotResumed`. Return `Status, Message`.
- **`LotPause_GetByLocation(@LocationId)`** — open pauses at a Cell, ordered by `PausedAt`: `PauseEventId, LotId, LotName, ItemId, ItemCode, PausedAt, PausedByUserId, PausedReason`.
- **`LotPause_GetCountsByLocation(@LocationId)`** — single row `OpenPauseCount INT` for the indicator badge.

No TTL — paused LOTs persist across shifts/operators; never auto-resumed/auto-cancelled.

## 5. Conventions & error handling

- **Stored proc template** `sql/scripts/_TEMPLATE_stored_procedure.sql`: three-tier error hierarchy, `RAISERROR` (not `THROW`) in CATCH with nested TRY/CATCH for failure logging, schema-qualified references, `EXEC` params literals/`@vars` only.
- **Ignition JDBC (FDS-11-011):** no `OUTPUT` params. Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId` (drop `@NewId` for Update/Resume). Reads return an empty result set on not-found. **One result set per proc** — `Lot_Split` does not emit a separate header SELECT plus a child SELECT; it returns a single rowset whose shape the plan pins down (see §8) and the test asserts via INSERT-EXEC.
- **Audit readability:** success → `Audit_LogOperation` with the `<SUBJECT> · <CATEGORY> · <ACTION>` `Description` (via `Audit.ufn_MidDot` + `Audit.ufn_TruncateActivity`) and resolved-FK Old/New JSON (`JSON_QUERY((... FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))` — never a bare aliased `FOR JSON` subquery, which double-encodes). Validation failures → `Audit_LogFailure`. Mirrors `Lot_Create` exactly.
- **ASCII-only** seed strings + ZPL bodies; byte-scan before applying.
- **Repeatable procs** live under `sql/migrations/repeatable/R__Lots_*.sql`, one per proc, `CREATE OR ALTER`. Named queries (the Ignition follow-on, not this push) all land in Core per `project_mpp_nq_core_topology`.

## 6. Test Coverage — `sql/tests/0021_PlantFloor_Lot_Lifecycle/`

`test.Assert_*` framework. **Target 90–120 passing.** Files:

| File | Covers |
|---|---|
| `010_Lot_Update.sql` | Field-level change → `LotAttributeChange` rows; stale `@RowVersion` rejection; blocked-LOT rejection; B5 `InventoryAvailable` recompute on PieceCount change. |
| `020_Lot_Split.sql` | N-way split; `SUM(children) > parent` rejection; closure rows inserted at correct depth; parent reduced / closed at residual 0; **suffix uniqueness + `-NN` format**; re-split appends suffix; >99 cap rejection. |
| `030_Lot_Merge.sql` | Same-Item/same-Tool succeeds; cross-Tool rank-compat=1 succeeds; cross-Tool rank-compat=0 rejects; supervisor-override path; output carries NULL Tool/Cavity + fresh MESL; closure ancestor-dedup (shared ancestor → one row, MIN depth). |
| `040_LotGenealogy_RecordConsumption.sql` | Consumption edge + closure rows; multi-source consumption; produced-LOT vs container/serial variants. |
| `050_Lot_GetGenealogyTree.sql` | Ancestors / Descendants / Both; depth values correct; multi-level tree (split-then-split) walks fully. |
| `060_LotPause_lifecycle.sql` | Place + resume; double-place rejection (B3); cross-Cell concurrent pauses allowed; resumer ≠ pauser; resume-already-resumed rejection. |
| `065_LotPause_indicator.sql` | `_GetCountsByLocation` open count; `_GetByLocation` list ordered by `PausedAt`. |
| `070_Label_print_reprint.sql` | Initial print renders ZPL with all tokens substituted; sublot label carries `ParentLotId` + `{ParentLotNumber}`; reprint with reason; missing-active-template rejection. |

Test fixtures avoid free-text names that collide with other suites' `@DescriptionLike` greps (e.g. keep `'SaveAll'` out of Descriptions). Audit-row cleanup deletes child audit rows before `AppUser` per `feedback_runtests_exit1_zero_failures`.

## 7. Phase 2 complete when

- [ ] `0021_arc2_phase2_lot_lifecycle.sql` applied to dev. `LotGenealogy`, `LotAttributeChange`, `LotLabel`, `PauseEvent`, `LabelTemplate` CREATEd; LogEventType/LogEntityType + LabelTemplate seeds loaded.
- [ ] All 15 procs delivered as `R__Lots_*.sql` repeatable migrations.
- [ ] `sql/tests/0021_PlantFloor_Lot_Lifecycle/` passes; full suite green (1308 + new).
- [ ] `Reset-DevDatabase.ps1` discovers `0021` + the new suite and runs clean.
- [ ] B4 closure rows verified for split / merge / consumption (depth + ancestor-dedup); B5 materialized columns stay consistent across `Lot_Update` / `Lot_Split`.
- [ ] Downstream phases can call `Lot_Split`, `Lot_Merge`, `LotGenealogy_RecordConsumption`, `LotLabel_Print`, `LotPause_Place`, `LotPause_Resume`, `Lot_GetGenealogyTree` against the delivered contract.

## 8. Risks & open notes

- **`Lot_Split` result-set shape.** The plan lists "header `Status, Message` + per-child rowset." Under the one-result-set JDBC rule the implementer returns the child rowset as the single SELECT and conveys failure via an empty rowset + a status column on each child row, OR returns status-only and exposes children via a sibling `Lot_GetChildren` call. Pick one in the plan and assert it via INSERT-EXEC; do not emit two result sets.
- **Supervisor override mechanics for `Lot_Merge`.** FDS-04-007 AD elevation is default-deny until the gateway IdP is wired (Phase 1 carry-forward). The proc accepts an elevated-context signal (param/flag) and trusts it; the *enforcement* of who may elevate is the gateway's job. Until S-08 `DieRankCompatibility` is populated, cross-rank merges reject without override — acceptable per UJ-08.
- **Materialized-column precision.** Phase 2 keeps `InventoryAvailable` / `TotalInProcess` internally consistent but does not implement the full event-driven OEE formula — that lands with the Phase 3+ event writers. Flagged so a reviewer doesn't read the simplified recompute as a bug.
- **Partition family.** `LotGenealogy` joins the born-partitioned 20-yr Honda family (`ps_MonthlyUtc`, aligned composite PK). `LotAttributeChange` / `LotLabel` / `PauseEvent` are left non-partitioned in Phase 2 (lower volume, no incoming bare-Id FK pressure); revisit if volume warrants, consistent with `project_mpp_partition_aligned_pk`.
