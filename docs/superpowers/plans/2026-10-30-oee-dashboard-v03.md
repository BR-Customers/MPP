# OEE Dashboard v0.3 (stored per-shift figures) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put availability, downtime and quality in front of supervisors on three Perspective pages (site, area, unit). Every page answers in under 2 s at any zoom, because the per-shift figures are stored, not recomputed on every read.

**Architecture:**
- One multi-statement function, `Oee.ufn_ShiftSummaryRows(@ShiftId)`, computes one shift's minutes and counts for every OEE unit, station, trim shop and area.
- `Oee.ShiftSummary_Compute` writes those rows into `Oee.ShiftSummary`.
- A 15-minute refresher recomputes the shifts whose input fingerprint changed. A nightly sweep rebuilds the last 7 days.
- Read procs pool the stored rows. For the shift in progress, and a closed shift not yet stored, they pool the function live instead.
- Finished-good LOTs carry `ShiftId` and `MintedPieceCount`, stamped at the mint.
- Ignition stays thin: Core named queries, one script module, gateway timers in MPP, and three new MPP views.

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, T-SQL tests in `sql/tests/`), Ignition 8.3 Perspective (file-based views, gateway timers), Ignition Reporting Module.

**Spec:** `docs/superpowers/specs/2026-10-27-oee-dashboard-design.md` v0.3.1 (approved 2026-10-30). Read it first; section numbers below refer to it. Mockups: `docs/superpowers/specs/2026-10-27-oee-dashboard-mockups/`. Supersedes `docs/superpowers/plans/2026-10-29-oee-dashboard.md`, whose Tasks 1-6 are built (spec 13 lists what carries forward).

## Calls in this plan (Jacques to confirm with the plan)

- **Configuration changes are detected the way facts are (extends D22).** Spec 6.8 has ~20 configuration procs call `RecomputeRange`. A change such as flipping `IsExcused` affects all history, which is too slow to recompute inside a config proc's transaction. Instead, the refresher keeps a **configuration fingerprint**: a hash over the rarely-changing configuration tables. When it changes, every stored shift is marked stale and recomputed newest-first, a bounded number per tick. No config proc is edited, and future config writers are covered. Shift overrides and tool assignments are per-day, so they go into the **per-shift** fingerprint instead. Task 7 ships the matching spec edit (v0.3.2).
- **"At shift close" = the shift ticker's next run.** `Shift_Reconcile` closes shifts. When it reports `ShiftsClosed > 0`, `tickShiftBoundary` calls `RefreshChanged`, which computes every ended shift that has no stored rows. So a closed shift is stored within about a minute.
- **The backfill is a repeatable proc, not migration SQL.** Versioned migrations run before repeatables (`Reset-DevDatabase.ps1` steps 4-5), so a migration cannot call `Oee.ufn_ShiftIdForInstant`. `Lots.Lot_BackfillMintStamp @Commit` runs once from the release runbook, rehearsable with `@Commit = 0`.

## Global Constraints

- Work on `jacques/working`; stage explicit paths only; no `Co-Authored-By` trailer. Other sessions share this checkout and may claim migration numbers: re-check `sql/migrations/versioned/` right before creating the migration (`0116` is the highest at plan time).
- Do not reset `MPP_MES_Dev`. Tests run with `sql/tests/Run-Tests.ps1` (rebuilds `MPP_MES_Test`). `-Filter` is a substring, not a regex: run one filter per call. Exit 1 with 0 failures means a file threw: compare the assertion count with the baseline.
- `sqlcmd` needs `-C -I` here.
- Read procs: ONE result set, no OUTPUT params. `EXEC` args literal or `@variable` only. A proc captured by INSERT-EXEC must not INSERT-EXEC another. Silent procs (`MarkStale`-style, audit writers) emit no result set.
- Repeatable function files deploy in filename order, and functions get no deferred name resolution. A function that calls another `Oee.ufn_*` needs a later-sorting name (`zz_`, `zzz_`, `zzzz_` prefixes, as today).
- Timestamps: `Oee.Shift.ActualStart/ActualEnd` and schedule times are LOCAL (OI-38). `DowntimeEvent.StartedAt/EndedAt`, `RejectEvent.RecordedAt`, `Lot.CreatedAt` and `ProductionEvent.EventAt` are UTC. Convert at the boundary with `AT TIME ZONE 'Eastern Standard Time'`. Displayed times are ET.
- Pooled, never averaged: `Availability = SUM(Base - Unplanned)/SUM(Base)`, `Quality = SUM(Good)/SUM(Good+Scrap)` (6.3). A roll-up line pools `EffectiveUnplannedMinutes = Base * (1 - station mean)`. Only `IsActive` pairs pool.
- Business rules in SQL, never Python. ASCII-only literals. All named queries in Core. New view folders are siblings with `view.json` + `resource.json`, registered by `.\scan.ps1`. Timers are committed **disabled**, with `def handleTimerEvent():` on line 1.
- Every bound `view.custom.*` is pre-declared with a full-shape default. The script behind it returns the full shape on empty.
- Routes: `/shop-floor/oee`, `/shop-floor/oee/area/:areaKey` (`diecast` | `trim` | `ma`), `/shop-floor/oee/unit/:locationId`. Bands from `Oee.ufn_OeeBand` only (0.85 / 0.70).
- Performance targets (6.1): any dashboard read < 2 s at any zoom; one shift's compute for the whole plant < 1 s; a 7-day rebuild < 1 min.

## Review Focus

1. **A closed shift whose rows are not stored yet** (closed seconds ago, before the refresher ran): the read must compute it live, not show it as empty. Test in Task 8 (`[Summary] ended shift with no stored rows -> computed live`).
2. **An edit that moves a downtime entry to another shift** (`DowntimeEvent_UpdateTimes`, `ShiftOverride_Restamp`): both shifts change. Test in Task 7 (`[Refresh] moved entry -> both shifts recomputed`).
3. **A minted FG LOT that is split, and the child then scrapped:** good stays the minted quantity, the scrap counts once, and the child adds no good. Test in Task 5 (`[Good] split child then scrap -> good = minted, scrap 1x`).
4. **An entry with real times and no `EndedAt` in a closed shift** (a stop never closed): it runs to `min(now, window end)`, never 0 or NULL. Test in Task 4 (`[Avail] open entry runs to window end`).
5. **A configuration change older than the 7-day window** (a reason code's `IsExcused` flipped): it still reaches history, through the configuration fingerprint. Test in Task 7 (`[Refresh] IsExcused flip -> old shift recomputed`).

---

### Task 1: Migration -- summary tables and the mint columns (spec 6.7, 7.4, D21)

**Files:**
- Create: `sql/migrations/versioned/0117_oee_shift_summary.sql` (number re-checked first)
- Test: `sql/tests/0117_Oee_Dashboard/005_schema.sql`

**Interfaces -- Produces:**
- `Lots.Lot.ShiftId BIGINT NULL` (FK `Oee.Shift.Id`), `Lots.Lot.MintedPieceCount INT NULL`. Filtered index `IX_Lot_ShiftId` on `(ShiftId) INCLUDE (MintedPieceCount, ItemId, CreatedAtTerminalId, LotOriginTypeId) WHERE ShiftId IS NOT NULL`.
- `Oee.ShiftSummary`: `Id BIGINT IDENTITY PK`, then the spec 6.7 columns.
  - `ShiftId BIGINT NOT NULL` FK; `LocationId BIGINT NULL` FK; `RowKind NVARCHAR(15) NOT NULL` with CHECK in (`Unit`, `Station`, `AreaPlacement`, `AreaCharge`); `AreaFamily NVARCHAR(10) NULL`; `ProductionAreaId BIGINT NULL`; `ParentUnitLocationId BIGINT NULL`.
  - `INT NOT NULL DEFAULT 0` for `PlannedMinutes`, `PlannedDowntimeMinutes`, `UnplannedDowntimeMinutes`, `BaseMinutes`, `DowntimeEventCount`, `NoReasonCount`, `NoReasonMinutes`.
  - `DECIMAL(9,2) NOT NULL DEFAULT 0` for `EffectiveUnplannedMinutes`.
  - `BIGINT NOT NULL DEFAULT 0` for `Good`, `Scrap`, `NonRejectScrap`, `FoundDownstreamScrap`, `UnplacedScrap`.
  - `LastToolId BIGINT NULL`; `IsActive BIT NOT NULL`; `ComputedAt DATETIME2(3) NOT NULL`; `InputFingerprint VARBINARY(32) NOT NULL`.
  - Unique index `UX_ShiftSummary_Key (ShiftId, RowKind, AreaFamily, LocationId)`.
- `Oee.ShiftSummaryConfig`: single row (`Id` = 1 CHECK). `ConfigFingerprint VARBINARY(32) NULL`, `ConfigChangedAt DATETIME2(3) NULL`, `CheckedAt DATETIME2(3) NULL`. Seeded with one row of NULLs.
- Migration style: `0116` shape (`IF COL_LENGTH ... IS NULL` / `IF OBJECT_ID ... IS NULL` guards, `SchemaVersion` insert as the other migrations do).

- [ ] **Step 1: Write `005_schema.sql`.** Assertions:
  - `[Schema] Lot.ShiftId exists and FKs Oee.Shift` (sys.foreign_keys);
  - `[Schema] Lot.MintedPieceCount exists`;
  - `[Schema] ShiftSummary unique key rejects a duplicate (ShiftId, RowKind, AreaFamily, LocationId)` (TRY/CATCH, error 2601);
  - `[Schema] ShiftSummary RowKind CHECK rejects 'Bogus'`;
  - `[Schema] ShiftSummaryConfig has exactly 1 row`.
- [ ] **Step 2: Run** `.\sql\tests\Run-Tests.ps1 -Filter "0117_Oee_Dashboard"`. Expected: the five new assertions FAIL; the existing 0117 files still pass.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `git add` both files; `git commit -m "feat(sql): 0117 Oee.ShiftSummary + Lot.ShiftId/MintedPieceCount"`.

### Task 2: The mint stamps its shift and quantity (spec 7.4, D18, D21)

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql` (insert ~386; v1.5 -> 1.6 + change log)
- Modify: `sql/migrations/repeatable/R__Workorder_MachiningOut_Mint.sql` (Lot insert ~317; v2.8 -> 2.9)
- Test: `sql/tests/0028_PlantFloor_Assembly/092_Assembly_CompleteTray.sql`, `100_Assembly_CompleteTray_repack.sql`, `sql/tests/0027_PlantFloor_Machining/080_MachiningOut_Mint_scrap.sql` (or the file there that covers the happy-path mint), and new `sql/tests/0117_Oee_Dashboard/015_mint_stamp_not_copied.sql`

**Interfaces -- Produces:** every LOT minted by these two procs has `ShiftId = (SELECT TOP 1 ShiftId FROM Oee.ufn_ShiftIdForInstant(<loc>, SYSUTCDATETIME()))` and `MintedPieceCount = PieceCount` at insert.
- `<loc>` is `@CellLocationId` in `Assembly_CompleteTray`, and the line the proc already writes as the scrap row's `CellLocationId` in `MachiningOut_Mint`.
- Resolve the shift into a local before `BEGIN TRANSACTION`, as `RecordByPartFifo` v1.2 does (~361).

- [ ] **Step 1: Write the failing assertions.**
  - In `092`: `[Tray] FG LOT ShiftId = ufn_ShiftIdForInstant(cell, now)` and `[Tray] FG LOT MintedPieceCount = PieceCount`.
  - In `100`: the same two assertions for a pass-through repack mint.
  - In the Machining mint test: `[Mint] SubAssembly LOT ShiftId stamped`.
  - Each fixture needs an open `Oee.Shift` covering now. Reuse what the file opens, or open one the way `102_RejectEvent_RecordByPartFifo.sql` does.
  - New `015`:
    - mint a tray, then `Lots.Lot_Split` it, then `Lots.Lot_Merge` two minted LOTs, then `Lots.ContainerRework_MovePieces`;
    - assert `[Stamp] split child ShiftId NULL`, `[Stamp] merge result ShiftId NULL`, `[Stamp] rework child ShiftId NULL`;
    - assert `[Stamp] parent MintedPieceCount unchanged after split`.
- [ ] **Step 2: Run** `-Filter "Assembly_CompleteTray"`, `-Filter "MachiningOut_Mint"`, `-Filter "0117_Oee_Dashboard"`. Expected: the new assertions FAIL (NULL actual); the `015` NULL-child assertions may already pass, which is correct because they pin behaviour.
- [ ] **Step 3: Implement** the two inserts and version bumps.
- [ ] **Step 4: Run** the three filters. Expected: PASS, with prior assertions unchanged.
- [ ] **Step 5: Commit** `"feat(sql): Assembly OUT + Machining OUT mints stamp ShiftId and MintedPieceCount"`.

### Task 3: One-time backfill of minted LOTs (spec 7.5)

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_BackfillMintStamp.sql`
- Test: `sql/tests/0117_Oee_Dashboard/016_backfill_mint_stamp.sql`

**Interfaces -- Produces:** `Lots.Lot_BackfillMintStamp @Commit BIT = 0, @AppUserId BIGINT`. It returns one result set, one row per candidate LOT: `LotId, LotName, ShiftId NULL, MintedPieceCount NULL, Outcome`, where `Outcome` is `N'Stamped' | N'NoShift' | N'NotReconstructable'`.
- **Candidates:** FinishedGood or SubAssembly LOTs with `ShiftId IS NULL`, `Manufactured` origin, that are the produced side of a `Consumption` genealogy link (`RelationshipTypeId = 3`) **or** a pass-through mint (a Consumption link from a Received-origin LOT of the same Item).
- **Split / merge / rework children are never candidates.** They are the child side of a `Split`/`Merge` relationship, or created by `ContainerRework_MovePieces`.
- `ShiftId` = `ufn_ShiftIdForInstant(<line above CreatedAtTerminalId>, CreatedAt)`.
- `MintedPieceCount` = current `PieceCount` + `SUM(RejectEvent.Quantity)` on the LOT + pieces split out of it (the `Split` children's birth `PieceCount`). A LOT whose pieces were merged away is `NotReconstructable`.
- `@Commit = 0` runs the updates inside a transaction and rolls back (CLAUDE.md remediation rule). Writes go through one UPDATE inside the proc, and an `Audit.ConfigLog` row summarises the counts.

- [ ] **Step 1: Write `016`:**
  - `[Backfill] minted FG gets shift + minted qty incl. later scrap` (mint 10, scrap 2 -> MintedPieceCount 10);
  - `[Backfill] split child untouched`;
  - `[Backfill] received FG untouched`;
  - `[Backfill] @Commit=0 leaves ShiftId NULL but reports Stamped`;
  - `[Backfill] merged-away LOT -> NotReconstructable, untouched`;
  - `[Backfill] second run finds 0 candidates`.
  - Build LOTs with the real mint procs, then NULL their stamps to simulate pre-fix rows.
- [ ] **Step 2: Run** `-Filter "0117_Oee_Dashboard"`. Expected: FAIL (proc missing).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"feat(sql): Lots.Lot_BackfillMintStamp for pre-0117 minted LOTs"`.

### Task 4: Availability from summed durations (spec 6.1, D17)

**Files:**
- Modify: `sql/migrations/repeatable/R__Oee_ufn_zz_ShiftAvailability.sql` (v1.1 -> 2.0; same signature and columns)
- Modify: `sql/migrations/repeatable/R__Oee_Shift_GetAvailability.sql` (v3.0 -> 4.0; header text only, the body already selects from the function)
- Modify: `sql/tests/0117_Oee_Dashboard/010_ufn_ShiftAvailability.sql` (parity test -> worked examples). Run the existing `0059_Oee_ShiftOverride/030_availability.sql`, `0090_Oee_EnabledLocations/030_rollup_availability.sql` and `050_rollup_edge_cases.sql` unchanged first. Change an expected value only where it encoded the clock merge, and ledger each change as a ruling citing D17.

**Interfaces:** `Oee.ufn_ShiftAvailability(@ShiftId)` keeps its 25 columns, so `Shift_GetAvailability` and its NQ are unchanged. The new rule is in spec 6.1:
- entries by `DowntimeEvent.ShiftId = @ShiftId AND VoidedAt IS NULL`;
- duration = `DurationMinutes` when `IsApproximate = 1`, else `DATEDIFF(SECOND, StartedAt, COALESCE(EndedAt, LEAST(SYSUTCDATETIME(), <window end UTC>)))/60.0`;
- planned = reason `IsExcused = 1`;
- `BaseMinutes = max(0, Planned - PlannedDowntime)`, unplanned capped at Base;
- ancestor entries count against each leaf; a roll-up is the station mean;
- `DowntimeMinutes` = planned + unplanned (uncapped), `UnexcusedDowntimeMinutes` = unplanned (capped);
- single rounding to DECIMAL(5,4).

The minute grid and the covered-range CTEs are deleted.

- [ ] **Step 1: Rewrite `010` as worked examples** on one 480-minute shift. Assertions:
  - `[Avail] two 30-min approximate entries at shift start -> 60 unplanned, 0.8750`;
  - `[Avail] 30 planned + 45 unplanned -> base 450, 0.9000`;
  - `[Avail] line entry 20 min counts on each station`;
  - `[Avail] unplanned 600 capped -> 0.0000`;
  - `[Avail] open entry runs to window end` (real `StartedAt` 60 min before the window end, `EndedAt` NULL, shift closed -> 60);
  - `[Avail] entry with ShiftId of another shift ignored even if clock-inside`;
  - `[Avail] voided entry ignored`;
  - `[Avail] Base 0 -> Availability NULL`;
  - `[Avail] roll-up line = mean of stations`.
- [ ] **Step 2: Run** `-Filter "0117_Oee_Dashboard"`. Expected: the two-entries-at-start and other-shift assertions FAIL under the clock merge.
- [ ] **Step 3: Implement** v2.0 of the function and the proc header bump.
- [ ] **Step 4: Run** `-Filter "Oee"`. Expected: `010` passes. For any `0059`/`0090` failure, check whether the expectation encoded the clock merge. If yes, update it with a ledgered ruling. If no, the code is wrong.
- [ ] **Step 5: Time it** on the benchmark DB (Task 9's generator can run early): one shift for the whole plant under 200 ms. Put the number in the commit message.
- [ ] **Step 6: Commit** `"feat(sql): availability from summed durations (Shift_GetAvailability v4.0, D17)"`.

### Task 5: Good from the mint stamp (spec 6.4)

**Files:**
- Modify: `sql/migrations/repeatable/R__Oee_ufn_zzz_ShiftGood.sql` (v1.0 -> 1.1, M&A branch only; output columns unchanged)
- Modify: `sql/tests/0117_Oee_Dashboard/040_good_and_scrap.sql`

**Interfaces:** `Oee.ufn_ShiftGood(@ShiftId)` returns the same columns. The M&A branch becomes:
- `Lot.ShiftId = @ShiftId`, `ItemType = FinishedGood`, Manufactured origin;
- `Good = MintedPieceCount`;
- unit = `PlacementLocationId` of `Oee.ufn_AreaFamily(CreatedAtTerminalId)`.

The per-LOT `ufn_ShiftIdForInstant` resolution and its window CTE are deleted.

- [ ] **Step 1: Write the failing assertions** in `040`:
  - `[Good] M&A good = MintedPieceCount, not current PieceCount` (mint 10, then decrement `PieceCount` to 7 through the reject proc -> 10);
  - `[Good] split child then scrap -> good = minted, scrap 1x`;
  - `[Good] FG LOT with ShiftId NULL not counted`.
  - Update the existing M&A fixture rows to set `ShiftId` / `MintedPieceCount`.
- [ ] **Step 2: Run** `-Filter "0117_Oee_Dashboard"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS, including the Die Cast / Trim / scrap assertions already in the file.
- [ ] **Step 5: Commit** `"feat(sql): M&A good from minted quantity by Lot.ShiftId"`.

### Task 6: One shift's rows, computed and stored (spec 6.3, 6.7)

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_ufn_zzzz_ShiftSummaryRows.sql`, `R__Oee_ufn_zzzz_ShiftInputFingerprint.sql`, `R__Oee_ShiftSummary_ComputeCore.sql`, `R__Oee_ShiftSummary_Compute.sql`, `R__Oee_ShiftSummary_RecomputeRange.sql`
- Test: `sql/tests/0117_Oee_Dashboard/060_shift_summary.sql`

**Interfaces -- Produces:**
- `Oee.ufn_ShiftSummaryRows(@ShiftId)` (multi-statement TVF) returns exactly `Oee.ShiftSummary`'s columns minus `Id`, `ComputedAt` and `InputFingerprint`. Rows:
  - `Unit` -- one per `ufn_OeeUnits` unit. Availability minutes from `ufn_ShiftAvailability`. A roll-up line stores its own Base and `EffectiveUnplannedMinutes = Base * (1 - Availability)` (0 when Availability is NULL); every other unit stores `EffectiveUnplannedMinutes = UnplannedDowntimeMinutes`. Good/scrap come from `ufn_ShiftGood`/`ufn_ShiftScrap` landed on the unit. Trim presses carry Good/Scrap 0.
  - `Station` -- one per OEE-enabled station, minutes only, `ParentUnitLocationId` = its line.
  - `AreaPlacement` -- one per trim shop with good or scrap.
  - `AreaCharge` -- one per family with found-downstream or no-cell scrap (`FoundDownstreamScrap`); `UnplacedScrap` counts Non-Specific no-cell rejects.
  - `IsActive` = good + scrap > 0, or `DowntimeEventCount > 0`. A trim press is active when its shop's `AreaPlacement` row has good or scrap.
  - `LastToolId` = the die of the latest `DieCastContribution` in the shift.
  - `NoReason*` = entries with `DowntimeReasonCodeId IS NULL`.
- `Oee.ufn_ShiftInputFingerprint(@ShiftId)` (inline TVF) returns `(Fingerprint VARBINARY(32))`. It is `HASHBYTES('SHA2_256', ...)` over, for that shift:
  - `COUNT`, `SUM` of quantities, and `CHECKSUM_AGG(CHECKSUM(<every column the calc reads, incl. VoidedAt, DowntimeReasonCodeId, DurationMinutes, Quantity, DefectCodeId, CellLocationId, PieceDelta, ShotCount, MintedPieceCount>))` of the rows in `DowntimeEvent`, `RejectEvent` (by `ShiftId`, plus `ShiftId IS NULL` rows inside the shift's window), `DieCastContribution`, trim `ProductionEvent`, `Lots.Lot` (by `ShiftId`);
  - the `Oee.Shift` row (`ActualStart`, `ActualEnd`);
  - `ShiftOverride` rows for the shift's `BusinessDate`;
  - `ToolAssignment` rows overlapping the window.
- `Oee.ShiftSummary_ComputeCore @ShiftId BIGINT` is **silent** (no result set, no transaction of its own, like the `Audit.Audit_Log*` writers). It deletes the shift's rows and inserts `ufn_ShiftSummaryRows` with `ComputedAt = SYSUTCDATETIME()` and the fingerprint. Status-row procs EXEC it inside their own transaction, so the body exists once.
- `Oee.ShiftSummary_Compute @ShiftId BIGINT, @AppUserId BIGINT` is a status-row proc (`Status, Message`). It refuses a shift with `ActualEnd IS NULL` (the shift in progress is never stored, 6.7) before `BEGIN TRANSACTION` (CLAUDE.md INSERT-EXEC rule), then EXECs ComputeCore.
- `Oee.ShiftSummary_RecomputeRange @FromUtc, @ToUtc, @AppUserId` EXECs ComputeCore for every ended shift whose window starts in the range, one transaction per shift. It returns `Status, Message, ShiftsComputed`.

- [ ] **Step 1: Write `060`** on the `test.OeeDashFixture_Build` fixture:
  - `[Rows] unit minutes equal ufn_ShiftAvailability`;
  - `[Rows] roll-up line EffectiveUnplanned = Base*(1-mean)`;
  - `[Rows] DC-charged scrap found on line -> AreaCharge diecast, not on line Unit`;
  - `[Rows] trim scrap on AreaPlacement shop, trim press Unit Good/Scrap 0`;
  - `[Rows] idle press IsActive 0`;
  - `[Rows] NULL-reason entry -> NoReasonCount 1, in Unplanned`;
  - `[Rows] two dies -> LastToolId = latest`;
  - `[Compute] stores rows with fingerprint = ufn_ShiftInputFingerprint`;
  - `[Compute] second run replaces, row count unchanged`;
  - `[Compute] open shift refused, nothing stored`;
  - `[Fingerprint] changes when a DowntimeEvent DurationMinutes changes`;
  - `[Fingerprint] unchanged by an edit to another shift`;
  - `[Range] computes every ended shift in range`.
- [ ] **Step 2: Run** `-Filter "0117_Oee_Dashboard"`. Expected: FAIL.
- [ ] **Step 3: Implement** the five objects.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Time** `Compute` for one shift on the benchmark DB. **Gate: < 1 s.** If it misses, profile per CTE before going on; do not proceed past Task 9 with it unmet.
- [ ] **Step 6: Commit** `"feat(sql): Oee.ShiftSummary compute, fingerprint, recompute range"`.

### Task 7: The refresher and the writer inventory (spec 6.8, D19, D22)

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_ufn_ShiftSummaryConfigFingerprint.sql`, `R__Oee_ShiftSummary_RefreshChanged.sql`
- Modify: the spec, 6.8 + D22 wording for the configuration fingerprint (v0.3.2, the "Calls in this plan" item)
- Test: `sql/tests/0117_Oee_Dashboard/070_refresh.sql`, `075_writer_inventory.sql`

**Interfaces -- Produces:**
- `Oee.ufn_ShiftSummaryConfigFingerprint()` returns `(Fingerprint VARBINARY(32))`. It is the same hash shape, over:
  - `ShiftSchedule` (times, `DeprecatedAt`);
  - `DowntimeReasonCode` (`IsExcused`, `DeprecatedAt`);
  - `Quality.DefectCode` (`ChargeToPartyId`, `IsNonRejectScrap`, `DeprecatedAt`);
  - `Location.Location` (`IsOeeEnabled`, `ParentLocationId`, `LocationTypeDefinitionId`, `DeprecatedAt`);
  - `LocationTypeDefinition` (`Code`).
- `Oee.ShiftSummary_RefreshChanged @AppUserId BIGINT, @MaxShifts INT = 60` returns `Status, Message, ShiftsComputed, ShiftsStillStale`. In order:
  1. If the config fingerprint differs from `ShiftSummaryConfig.ConfigFingerprint`, store it and set `ConfigChangedAt = now`.
  2. Collect stale ended shifts:
     - (a) ended with no stored rows (this is the shift-close compute);
     - (b) window in the last 7 days and stored fingerprint differs from `ufn_ShiftInputFingerprint`;
     - (c) `ComputedAt < ConfigChangedAt`.
  3. Recompute up to `@MaxShifts`, newest first, by EXEC-ing `ShiftSummary_ComputeCore` (one transaction per shift).
- **Nightly sweep** = `RecomputeRange(now - 7 days, now)`. No new proc.

- [ ] **Step 1: Write `070`:**
  - `[Refresh] newly ended shift computed`;
  - `[Refresh] unchanged shift not recomputed (ComputedAt same)`;
  - `[Refresh] late downtime entry -> recomputed, minutes updated`;
  - `[Refresh] moved entry -> both shifts recomputed` (`DowntimeEvent_UpdateTimes` across shifts);
  - `[Refresh] IsExcused flip -> old shift recomputed` (a shift 30 days back, via `DowntimeReasonCode_Update`);
  - `[Refresh] @MaxShifts bounds the work, ShiftsStillStale reports the rest`;
  - `[Refresh] shift older than 7 days with a late edit NOT recomputed` (pins the documented limit, spec 10).
- [ ] **Step 2: Write `075`.** One assertion per fact writer in the spec 6.8 inventory, named `[Inventory] <proc> -> fingerprint changes`. Each runs the real proc against a stored shift and asserts `ufn_ShiftInputFingerprint` differs from the stored one. The proc list is the spec's table, verbatim (downtime: 9 procs; reject: 9; die-cast contribution: 3; trim checkpoints: 2; minted LOTs: `Assembly_CompleteTray`). Reuse each proc's existing test fixture helper where one exists (search `sql/tests/helpers/`). Where a proc needs a fixture no helper builds, write a minimal one in the file and note it.
- [ ] **Step 3: Run** `-Filter "0117_Oee_Dashboard"`. Expected: `070` FAILS (proc missing). `075` assertions may pass already, because the fingerprint is Task 6's; a writer that does NOT change it is a fingerprint gap: fix `ufn_ShiftInputFingerprint` until every inventory line passes.
- [ ] **Step 4: Implement** the function, the proc, and the spec 6.8 / D22 edit (status line -> v0.3.2, revision row).
- [ ] **Step 5: Run.** Expected: PASS.
- [ ] **Step 6: Commit** `"feat(sql): ShiftSummary_RefreshChanged -- input + configuration fingerprints, writer inventory tests"`.

### Task 8: `Oee.Dashboard_GetUnitSummary` v2.0 reads the table (spec 6.3, 8)

**Files:**
- Modify: `sql/migrations/repeatable/R__Oee_Dashboard_GetUnitSummary.sql` (v1.0 -> 2.0; signature and columns unchanged)
- Modify: `sql/tests/0117_Oee_Dashboard/050_unit_summary.sql`

**Interfaces:** unchanged from the old plan's Task 6: `@Zoom, @AnchorShiftId, @AreaFamily = NULL` -> `RowKind` `Unit | Station | Group | Area | Plant` with the same column list.
- The source becomes `Oee.ShiftSummary` for ended shifts in `ufn_ShiftsForPeriod`.
- For the period's shifts with no stored rows (the shift in progress, or ended-not-yet-stored), use `CROSS APPLY Oee.ufn_ShiftSummaryRows`.
- `IncludesInProgressShift` = any period shift with `ActualEnd IS NULL`.
- Pool only `IsActive` rows. `LastToolCode` comes from the latest shift's `LastToolId`.

- [ ] **Step 1: Update `050`.**
  - Its fixture now calls `ShiftSummary_Compute` for ended shifts. Keep every existing assertion.
  - Add `[Summary] ended shift with no stored rows -> computed live`, `[Summary] open shift included live, IncludesInProgressShift 1`, `[Summary] stored and live give identical rows for the same shift`.
- [ ] **Step 2: Run** `-Filter "0117_Oee_Dashboard"`. Expected: the new assertions FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"feat(sql): Dashboard_GetUnitSummary v2.0 pools stored shift rows"`.

### Task 9: Benchmark gate (spec 6.1, G7)

**Files:**
- Modify: `sql/scratch/2026-10-29_oee_dashboard_benchmark.sql`. The generator stamps FG LOTs with `ShiftId`/`MintedPieceCount`, then times a whole-month `RecomputeRange`, one `Compute`, and `Dashboard_GetUnitSummary` at Shift/Day/Week, cold and warm. Keep its `MPP_MES_Test` guard.

- [ ] **Step 1: Run** `sqlcmd -S localhost -E -C -I -i sql/scratch/2026-10-29_oee_dashboard_benchmark.sql -o <workspace>/bench.log`.
- [ ] **Step 2: Compare** with the targets:
  - every read < 2 s warm;
  - Compute < 1 s;
  - 7-day rebuild < 1 min.
  - Expected: all met.
  - If any read misses, stop and report the stepped timings to Jacques before Task 10. That is the same gate as v0.2, and it decides whether views get built.
- [ ] **Step 3: Commit** the script with the numbers in the message and in spec Section 13's table (a "v0.3 measured" column).

### Task 10: Period navigation (spec 5.1)

**Files:** Create `R__Oee_Dashboard_GetPeriod.sql`; Test `sql/tests/0117_Oee_Dashboard/080_period.sql`.

**Interfaces:** `Oee.Dashboard_GetPeriod @Zoom NVARCHAR(5), @AnchorShiftId BIGINT = NULL, @Step INT = 0` returns one row:
- `AnchorShiftId`, `Zoom`;
- `PeriodLabel`: `N'2nd shift - Tue 10/27'` | `N'Production day Tue 10/27'` | `N'Week of Mon 10/26'`;
- `IsInProgress`, `HasNext`;
- `IsRecentlyClosed BIT`: 1 when the anchor shift ended < 60 min ago (the "entries may still be arriving" label, 6.8).

A NULL anchor means the last ended shift. `@Step` of -1/+1 moves one shift, day or week. Stepping past the open shift is refused (`HasNext = 0`, anchor unchanged).

- [ ] **Step 1: Tests**:
  - `[Period] default anchor is last ENDED shift`;
  - `[Period] Step -1 at Day -> previous production day`;
  - `[Period] Step +1 onto the open shift -> IsInProgress 1`;
  - `[Period] Step +1 from the open shift -> HasNext 0, anchor unchanged`;
  - `[Period] shift ended 20 min ago -> IsRecentlyClosed 1`;
  - `[Period] labels`;
  - `[Period] unknown anchor -> 0 rows`.
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.** **Step 4: Run** -> PASS. **Step 5: Commit.**

### Task 11: Remaining read procs (spec 8)

**Files:** Create `R__Oee_Dashboard_GetTrend.sql`, `_GetBreakdown.sql`, `_GetDowntimeByReason.sql`, `_GetScrap.sql`, `_GetDowntimeEntries.sql`; Test `sql/tests/0117_Oee_Dashboard/090_read_procs.sql`.

**Interfaces:** the column lists of the old plan's Task 8 (`docs/superpowers/plans/2026-10-29-oee-dashboard.md`, Task 8 "Interfaces"), verbatim, with these sources:
- `_GetTrend` and `_GetBreakdown` pool `Oee.ShiftSummary`, plus the live function for unstored shifts, with the same union as Task 8. Put that union in an inline TVF `Oee.ufn_zzzzz_PeriodSummaryRows(@Zoom, @AnchorShiftId)` and switch Task 8's proc to it in this task, so the rule lives once.
- `_GetDowntimeByReason`, `_GetScrap` and `_GetDowntimeEntries` read source rows by `ShiftId` over `ufn_ShiftsForPeriod` (6.7: detail panels read source rows). Downtime duration uses the Task 4 rule.
  - Put the duration expression in an inline `Oee.ufn_DowntimeMinutes(@DowntimeEventId)`, or a column-level inline TVF, shared with `ufn_ShiftAvailability`.
  - `_GetDowntimeEntries`: check `Oee.DowntimeEvent_GetByScope` first and reuse it if it already returns the needed columns.

- [ ] **Step 1: Tests:**
  - `[Trend] 7 rows, gap day NULL`;
  - `[Trend] equals GetUnitSummary Day per day`;
  - `[Breakdown] Day order 3rd,1st,2nd`;
  - `[Reason] NULL reason row IsNoReason`;
  - `[Reason] station entries included for a line`;
  - `[Reason] two approximate entries summed`;
  - `[Scrap] Part grouping per trim shop`;
  - `[Scrap] Line grouping with top defect`;
  - `[Scrap] found-here-charged-to-DC greyed, excluded from Quality`;
  - `[Entries] Approximate flag passes through`.
- [ ] **Step 2: Run** -> FAIL. **Step 3: Implement.**
- [ ] **Step 4: Run the whole suite** `.\sql\tests\Run-Tests.ps1 > <workspace>/suite.log`. Expected: 0 failures, and an assertion count equal to the baseline plus the new ones.
- [ ] **Step 5: Commit.**

### Task 12: Gateway -- refresh timers, shift-close hook, named queries, script module

**Files:**
- Create Core NQs `ignition/projects/Core/ignition/named-query/oee/{ShiftSummary_RefreshChanged, ShiftSummary_RecomputeRange, Dashboard_GetUnitSummary, Dashboard_GetPeriod, Dashboard_GetTrend, Dashboard_GetBreakdown, Dashboard_GetDowntimeByReason, Dashboard_GetScrap, Dashboard_GetDowntimeEntries}/{query.sql,resource.json}`:
  - `type: Query` (status-row and read procs alike);
  - ids `sqlType 8`, strings `sqlType 7`, datetimes as the sibling `oee/` NQs do.
- Create `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/Dashboard/{code.py,resource.json}` and `.../BlueRidge/Oee/Summary/{code.py,resource.json}`.
- Create MPP timers `ignition/projects/MPP/ignition/timer/OeeSummaryRefresh/` (delay 900000) and `OeeSummaryNightly/` (delay 86400000). Shape as `PartitionMaintenance`, **`enabled: false`**.
- Modify `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/Shift/code.py` `tickShiftBoundary` (~222): after `reconcile`, when `ShiftsClosed > 0`, call `BlueRidge.Oee.Summary.refreshChanged(systemAppUserId)` inside the same guard.

**Interfaces:**
- `BlueRidge.Oee.Summary`: `refreshChanged(appUserId)`, `recomputeRange(fromUtc, toUtc, appUserId)`, `nightly(appUserId)` (= recomputeRange of the last 7 days). Each calls `Common.Util.requireAppUserId`, is never-throw (`except (Exception, java.lang.Exception)`), and returns the status dict.
- `BlueRidge.Oee.Dashboard`: `period`, `unitSummary`, `trend`, `breakdown`, `downtimeByReason`, `scrap`, `downtimeEntries`, with the signatures of the old plan's Task 9. On empty or error, `period` returns `_EMPTY_PERIOD` (every key incl. `IsRecentlyClosed`) and the list functions return `[]`.

- [ ] **Step 1:** Write the NQs, both modules and the timers. Check there is no `__pycache__` under the project tree. **Step 2:** `.\scan.ps1`.
- [ ] **Step 3: Verify** in the gateway Script Console against `MPP_MES_Dev` (read-only calls only):
  - `BlueRidge.Oee.Dashboard.period('Day', None, 0)` returns a label;
  - `period('Day', -1, 0)` returns `_EMPTY_PERIOD`;
  - `unitSummary('Shift', None, None)` returns rows.
  - Then run `BlueRidge.Oee.Summary.refreshChanged(<SYS>)` once, and confirm `Oee.ShiftSummary` has rows (Dev is shared: this only adds summary rows; say so in the commit).
- [ ] **Step 4: Commit.** The timers stay disabled; enabling them is a deployment step (Task 16).

### Task 13: Shared components + Site page (spec 5.1, 5.2; mockup 1)

As the old plan's Task 10 (`2026-10-29-oee-dashboard.md`), same files and interfaces, plus:
- `PeriodHeader` shows "entries may still be arriving" when `IsRecentlyClosed`, and the in-progress note when `IsInProgress`.

- [ ] **Step 1:** Build. **Step 2:** `.\scan.ps1`.
- [ ] **Step 3: Verify** in the browser pane:
  - `/shop-floor/oee` opens on the last completed shift with no Component Error;
  - `‹`/`›` step;
  - Day/Week regroup;
  - the browser's network/console shows no read slower than 2 s.
  - Take a screenshot.
- [ ] **Step 4: Commit.**

### Task 14: Area page and unit drill-down (spec 5.3, 5.4; mockups 2, 3)

As the old plan's Tasks 11 and 12, same files, interfaces and verification. The drill-down's **Edit** -> `Popups/DowntimeEditor` -> close refreshes the page. The edited shift's stored figures then lag until the next refresh (≤ 15 min), so the drill-down reads that shift live while `ComputedAt` is older than the newest edit.
- Simplest form: the Unit page always reads the *anchor* shift live at Shift zoom.
- Ruling for the builder: do that.

- [ ] **Steps:** build Area, verify the three keys plus a bogus key, and commit. Then build Unit, verify a press, a trim press, a line and Edit -> refresh, take a screenshot, and commit.

### Task 15: Supervisor Dashboard tile + "OEE Summary" report (spec 5.5, 5.6)

As the old plan's Task 13, unchanged.

### Task 16: Docs, status, release notes

**Files:**
- `MPP_MES_DATA_MODEL.md`: Oee section covering `ShiftSummary`, `ShiftSummaryConfig`, `Lot.ShiftId`/`MintedPieceCount`, the functions and procs, the counting, charge, duration and refresh rules. Lots section: the two columns.
- `PROJECT_STATUS.md`: the OEE entry (append-only; other sessions edit this file).
- The spec revision table: v1.0 = built.
- `notes/2026-10-28_handoff-oee-dashboard.md`: closed.
- `notes/2026-10-30_oee-dashboard-release-steps.md`: the steps the prod release runbook must contain:
  1. migration `0117`;
  2. `Lots.Lot_BackfillMintStamp @Commit=0`, read the report, then `@Commit=1`;
  3. `Oee.ShiftSummary_RecomputeRange` over all history;
  4. enable `OeeSummaryRefresh` and `OeeSummaryNightly`.
  - Core imports first, per the deployment contract. The full five-part release is planned separately.
- Regenerate the `.docx` for any doc that has one. The FDS is untouched.

- [ ] **Step 1:** Write the docs. **Step 2: Commit.**
