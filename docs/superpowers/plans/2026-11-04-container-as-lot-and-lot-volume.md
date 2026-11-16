# Container-as-LOT and LOT Volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One finished-good LOT per container instead of per tray, with every reader handling both shapes. Also a clustered `Lots.Lot`, scalable LOT search, and a year-scale before/after benchmark on `MPP_MES_Bench`.

**Architecture:**
- **Migration `0118`** adds `Container.LotId` plus the tray stamps (`ShiftId`, `ClosedAtTerminalId`, `MintedPieceCount`), and clusters `Lots.Lot`.
- **Two inline TVFs** (`Lots.ufn_ContainerLots`, `Lots.ufn_LotContainers`) give every reader both shapes.
- **`Assembly_CompleteTray` v2.0** mints the LOT on the first tray, then appends. Repack, OEE, super-lot and search procs change in place.
- **Ignition changes** are limited to Python and named-query files. Existing views go through Designer and are listed for Jacques.

**Tech Stack:** SQL Server 2022 (repeatable + versioned migrations, `test.*` assertion framework, `sql/tests/Run-Tests.ps1`), Ignition 8.3 Jython, PowerShell.

**Spec:** `docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md` (D1-D12). Read it first. Reader inventory: section 7, and the shared note `2026-11-04_container-as-lot-reader-inventory.md`.

## Global Constraints

**Where you may work**
- Work only in the worktree `C:\Users\JacquesPotgieter\Documents\Dev\MPP\.claude\worktrees\container-as-lot-3afdfd`, on branch `claude/container-as-lot-3afdfd`.
- Never touch the main checkout, never touch `jacques/working`, never write to `MPP_MES_Dev`, never scan the gateway.

**Databases**
- Tests run on a private throwaway database: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CaL [-Filter X]`.
- Run-Tests drops and rebuilds its target, so never point it at Dev or Bench.

**Stored procedures**
- Follow CLAUDE.md conventions:
  - no `OUTPUT` params, one result set, `RAISERROR` in `CATCH`;
  - every rejecting validation runs before `BEGIN TRANSACTION`;
  - `EXEC` args are literals or variables only.
- Mutation procs captured via INSERT-EXEC do not EXEC other status-row procs; inline them and comment each block as a mirror.

**Versioning and data**
- Bump each changed repeatable's header `Version` line with date `2026-11-04` and a one-line reason naming the spec decision (e.g. "D1").
- Seed and string literals are ASCII only (no em-dash / middle-dot in literals; use `Audit.ufn_MidDot()`).
- Timestamps are stored UTC (`SYSUTCDATETIME()`); display reads convert to Eastern.

**Shapes**
- **Old shape:** `ContainerTray.FinishedGoodLotId` NOT NULL, `Container.LotId` NULL.
- **New shape:** `Container.LotId` NOT NULL, new trays `FinishedGoodLotId` NULL.
- **Mixed:** both.

**Tests and commits**
- Every changed reader gets a test per shape. Every gate also gets a mixed test.
- Commits: stage explicit paths only (never `git add -A/-u`), no Co-Authored-By trailer.

## Review Focus

1. **Mixed container** (opened before the release, then appended after): ship / CRT / AIM gates block on either LOT; AIM `LotNumber` stays the first tray LOT; OEE counts each tray exactly once. Owned by Tasks 4 and 8.
2. **A tray appended to a container whose LOT is Hold or Closed** (D10, top-up after rework): pieces are added, `InventoryAvailable` rises with `PieceCount`, nothing is refused, and `Container_Complete` leaves a held LOT unclosed. Owned by Task 3.
3. **Same source LOT drawn by several trays of one container** gives one `LotGenealogy` edge whose `PieceCount` equals the sum of the draws; closure has no duplicate ancestor rows. Owned by Task 3.
4. **Super-lot window that opens mid-skid**: the container joins from its in-window trays, and a skid whose trays all predate the window does not. Owned by Task 6.
5. **Repack scrap after the shift closed** leaves that shift's OEE good unchanged (D11), and the fingerprint is unchanged too. Owned by Task 8.

---

### Task 1: Migration 0118 schema

**Files:**
- Create: `sql/migrations/versioned/0118_container_as_lot.sql`
- Test: `sql/tests/0118_ContainerAsLot/005_schema.sql`

**Interfaces:**
- Produces:
  - `Lots.Container.LotId BIGINT NULL` (FK `Lots.Lot`, filtered unique `UX_Container_LotId`);
  - `Lots.ContainerTray.ShiftId BIGINT NULL` (FK `Oee.Shift`), `.ClosedAtTerminalId BIGINT NULL` (FK `Location.Location`), `.MintedPieceCount INT NULL`;
  - indexes `IX_ContainerTray_ShiftId` (filtered `ShiftId IS NOT NULL`, INCLUDE `MintedPieceCount, ClosedAtTerminalId, ContainerId`) and `IX_ContainerTray_ClosedAt` (INCLUDE `ContainerId, ClosedAtTerminalId`);
  - clustered `CIX_Lot_CreatedAt ON Lots.Lot (CreatedAt, Id)` on PRIMARY, with `PK_Lot` staying NONCLUSTERED.

- [ ] **Step 1: Write the failing test.** Assert each column exists with its FK, `UX_Container_LotId` rejects a duplicate non-NULL `LotId` (error 2601/2627) and allows two NULLs, `Lots.Lot` has a clustered index whose key is `(CreatedAt, Id)`, and `PK_Lot` is nonclustered.
- [ ] **Step 2: Run it to verify it fails.** Run `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CaL -Filter 0118`. Expected: FAIL on the missing column.
- [ ] **Step 3: Write the migration.** Follow the guarded, idempotent style of `0117_oee_shift_summary.sql` (`IF COL_LENGTH ... IS NULL`), plus the `SchemaVersion` insert the other migrations use. Add extended properties for the new columns in `R__Descriptions_ExtendedProperties.sql`, the same way 0117's columns are described.
- [ ] **Step 4: Run it to verify it passes.** Then run the full suite once: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CaL`. Record the assertion count as the baseline. Expected: 0 failed.
- [ ] **Step 5: Commit.** `git commit -m "feat(sql): 0118 container-as-LOT schema + clustered Lots.Lot"`

### Task 2: Shape helpers

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_ContainerLots.sql`, `R__Lots_ufn_LotContainers.sql` (check how existing `R__Lots_ufn_*` files are ordered by name prefix relative to their callers; use a `zz` prefix if callers that sort earlier depend on them)
- Test: `sql/tests/0118_ContainerAsLot/010_shape_helpers.sql`

**Interfaces:**
- Produces:
  - `Lots.ufn_ContainerLots(@ContainerId BIGINT)` returns `(LotId BIGINT, SortKey INT, Shape NVARCHAR(10))`. Old rows: `TrayPosition`, `'Tray'`. New row: `2147483647`, `'Container'`. So `TOP 1 ... ORDER BY SortKey` is the representative LOT in every shape: the first tray LOT when there is one (old and mixed), otherwise the container LOT.
  - `Lots.ufn_LotContainers(@LotId BIGINT)` returns `(ContainerId BIGINT, ContainerTrayId BIGINT NULL)`.
  - Both are inline TVFs.

- [ ] **Step 1: Write the failing test** with three fixture containers, built by direct insert:
  - old: 2 trays, each with a LOT;
  - new: `Container.LotId` set, 2 trays with NULL `FinishedGoodLotId`;
  - mixed: 1 tray LOT plus a container LOT.

  Assertions:
  - `ufn_ContainerLots` returns 2 / 1 / 2 rows;
  - `TOP 1 ... ORDER BY SortKey` = the first tray LOT for old and mixed, and the container LOT for new;
  - `ufn_LotContainers` returns the right container for an old tray LOT (with its tray id) and for a container LOT (tray id NULL).
- [ ] **Step 2: Run it and verify it fails.** Then implement both TVFs. Run again and verify it passes.
- [ ] **Step 3: Commit.** `git commit -m "feat(sql): ufn_ContainerLots / ufn_LotContainers shape helpers"`

### Task 3: Assembly_CompleteTray v2.0 (mint-or-append)

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_Assembly_CompleteTray.sql`
- Test: `sql/tests/0118_ContainerAsLot/020_CompleteTray_container_lot.sql`
- Update: the existing tests in `sql/tests/0028_PlantFloor_Assembly/` (092, 093, 097, 098, 100, 095), and others the suite fails on, wherever they assert one LOT per tray. Rewrite those assertions to the new shape; do not delete coverage.

**Interfaces:**
- Consumes: Task 1 columns.
- Produces: the same signature, and the same result columns (`Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull, TraysPerContainer` — check the existing final SELECT and keep it). `FinishedGoodLotId` now = the container's LOT.

Behaviour (spec 7.1):
- **Mint-or-append.** Resolve the container first. If `LotId` is NULL, mint (today's B1, but with `Lot.ShiftId` / `MintedPieceCount` NULL) and set `Container.LotId`. Otherwise `UPDLOCK` the LOT and add `@PieceCount` to `PieceCount` and `InventoryAvailable`, whatever its status.
- **Tray row:** `FinishedGoodLotId` NULL, with `ShiftId`, `ClosedAtTerminalId` and `MintedPieceCount` stamped.
- **Consume:** `ConsumptionEvent` as today. Genealogy edge per D4: UPDATE `PieceCount += @Take` where `(ParentLotId, ChildLotId, RelationshipTypeId=3)` exists, else INSERT. Closure only when new.
- **CRT re-resolve every tray:** `ufn_CrtForMint(item, terminal, CSV of this tray's consumed LOTs)`; raise 0 to 1 only, and audit when raised on append.
- **The `LotCreated` audit fires on mint only.**

- [ ] **Step 1: Write the failing tests:**
  - `[D1] first tray mints; Container.LotId set; LOT PieceCount = 4`
  - `[D1] second tray appends; same LOT; PieceCount = 8, InventoryAvailable = 8; IdentifierSequence advanced once`
  - `[D2] tray rows FinishedGoodLotId NULL; MintedPieceCount = 4; ShiftId = ufn_ShiftIdForInstant; ClosedAtTerminalId = terminal`
  - `[D3] ConsumptionEvent.ProducedLotId = container LOT; TrayId = each tray`
  - `[D4] two trays drawing the same source LOT -> one edge, PieceCount = sum; closure ancestors not duplicated`
  - `[D10] LOT on Hold -> next tray appends, LOT stays Hold`
  - `[7.4] container LOT Closed + container Open (resumed) -> tray appends`
  - `[CRT] tray 2 consumes a CRT input -> container LOT CrtActive 1`
  - `[mixed] open old-shape container with a tray LOT -> next tray mints the container LOT, old tray LOT untouched`
  - `[Lot] Lot.ShiftId / MintedPieceCount NULL on the container LOT`
- [ ] **Step 2: Run them and verify they fail.** Run `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CaL -Filter 0118`.
- [ ] **Step 3: Implement v2.0.** Update the header's `WHY EVERY SUB-MUTATION IS INLINED` text for append.
- [ ] **Step 4: Run** `-Filter 0118`, then `-Filter 0028`, `-Filter 0064`, `-Filter 0109` and `-Filter 0117`. Fix the old-shape assertions in those folders. Expected: 0 failed.
- [ ] **Step 5: Commit.**

### Task 4: Complete, ship gates, AIM, label

**Files (modify):**
- `R__Lots_Container_Complete.sql` (close loop over `ufn_ContainerLots`, Good only; AIM `LotNumber` = `TOP 1 ... ORDER BY SortKey`)
- `R__Lots_Container_Ship.sql`
- `R__Lots_AimShipperIdPool_ListUnposted.sql`
- `R__Lots_Container_ListPendingValidation.sql` (pieces from the tray sum)
- `R__Lots_Container_ValidateCrt.sql`
- `R__Lots_Container_GetLabelData.sql`
- `R__Tools_ufn_ContainerOriginDieRankCode.sql` (new shape: first tray's `ConsumptionEvent` sources, then the deepest closure ancestor with a `ToolId`; old shape unchanged)
- `R__Workorder_ScaleStation_GetRecentBoxes.sql`

**Test:** `sql/tests/0118_ContainerAsLot/030_gates_label_aim.sql` (old, new and mixed fixtures; reuse Task 2's fixture builder by copying its setup block).

- [ ] **Step 1: Write the failing tests**, for each shape:
  - `Container_Ship` refuses a held LOT and names it;
  - `Container_Ship` refuses CRT;
  - `ListUnposted` excludes CRT;
  - `ListPendingValidation` lists a CRT container with pieces = the tray sum;
  - `ValidateCrt` clears every LOT;
  - `Container_Complete` closes the Good LOT(s), leaves a Hold LOT open, and gives AIM `LotNumber` = first tray LOT (old/mixed) or the container LOT (new);
  - `GetLabelData.MfgLotNumber` is non-empty;
  - die rank resolves for the new shape from the first tray's castings, not a later tray with a different die (fixture: two trays drawing from different dies' castings).
- [ ] **Step 2: Run, implement, run.** Then run `-Filter 0029`, `0049`, `0056`, `0028` and `0111`, and fix the old-shape assertions.
- [ ] **Step 3: Commit.**

### Task 5: Trace, hold and LOT-to-container readers

**Files (modify):**
- `R__Lots_Container_GetTraceDetail.sql`, `R__Lots_Container_ListShipped.sql`, `R__Lots_GlobalTrace_Resolve.sql`
- `R__Quality_Hold_ListAssociatedContainers.sql`, `R__Quality_Hold_Release.sql`
- `R__Lots_Lot_GetShippedContainers.sql` (Quantity = the tray sum)
- `R__Lots_Lot_GetLinkedContainer.sql`: for a container LOT return the container, `TrayCount`, and NULL tray fields. Keep the columns; add `TrayCount INT` as the last column, and update the matching NQ.
- `R__Workorder_ScaleStation_GetPressLog.sql`
- `tools/reports/lot_detail/queries.py`

**Test:** `sql/tests/0118_ContainerAsLot/040_trace_hold_readers.sql`

- [ ] **Step 1: Write the failing tests**, one per reader per shape:
  - GlobalTrace by container and by shipper ID returns the LOT(s);
  - `Hold_ListAssociatedContainers(container LOT)` returns the container;
  - `Hold_Release` on a container LOT whose container is Complete closes the LOT;
  - `GetShippedContainers` quantity = 8 for a 2x4 container;
  - `GetLinkedContainer` returns `TrayCount`;
  - `SourceLotCount` = 1 for a new container.
- [ ] **Step 2: Run, implement, run.** Then run `-Filter 0029`, `0055`, `0068`, `0113` and `0114`.
- [ ] **Step 3: For the press log**, `ScaleEPrintWatcher` now logs `lotId` = the container LOT (Task 10). Resolve the tray through `InterfaceLog` payload JSON `containerTrayId` first, falling back to the old `FinishedGoodLotId` join. Test both.
- [ ] **Step 4: Commit.**

### Task 6: Super-lot (ControlledRun) readers and the D9 time rule

**Files (modify):** every `R__Quality_*ControlledRun*` object listed in the reader inventory (`ufn_zz_ControlledRunResolveMembers`, `ufn_zz_ControlledRunMemberState`, `ufn_zz_ControlledRunMembershipsForLot`, `ControlledRun_ApplyMembersInternal`, `_Release`, `_SyncInternal`, `_LogMemberLotEventsInternal`, `_PreviewSelection`), the window-conflict check in `ControlledRun_Open`, and `ContainerRework_Void`'s CRT clear.

**Interfaces:**
- Consumes: Task 2 helpers.
- Produces: no signature changes.

**Rules:**
- Container pieces = the tray sum. "Any CRT" and set/clear go over `ufn_ContainerLots`.
- **D9.** A container LOT is in a time window when `EXISTS` a tray of its container with `ClosedAt` in `[OpenedAt, EndedAt)`, and the location filter is on that tray's `ClosedAtTerminalId`. Old tray LOTs keep `CreatedAt` / `CreatedAtTerminalId`.

**Test:** `sql/tests/0118_ContainerAsLot/050_controlled_run.sql`

- [ ] **Step 1: Write the failing tests:**
  - window opened between tray 1 and tray 2: the container LOT auto-joins via `SyncInternal`;
  - window that ended before tray 1: not joined;
  - location filter on another line: not joined;
  - release clears CRT on the container LOT and logs one LOT event;
  - container member Pieces = the tray sum;
  - a container LOT folds to its container member;
  - an old-shape container still behaves as in `0109` tests.
- [ ] **Step 2: Run, implement, run.** Then run `-Filter 0109`, `0110`, `0111`, `0112` and `0114`.
- [ ] **Step 3: Commit.**

### Task 7: Repack (container rework)

**Files (modify):**
- `R__Lots_ContainerRework_Scrap.sql`: decrement the container LOT (new shape) or the tray LOT (old) and the tray `PartsClosedCount`; `RejectEvent.LotId` = that LOT.
- `R__Lots_ContainerRework_MovePieces.sql`: D6 + D12.
  - Decrement the donor LOT and the donor tray.
  - Increment the receiver's LOT, minting one if the receiver has none, which makes an old-shape receiver mixed.
  - Insert the receiver tray with `ShiftId`/`MintedPieceCount` NULL.
  - Write a `ConsumptionEvent` (`TrayId` = the new tray) and a D4 edge from the donor LOT to the receiver LOT.
- `R__Lots_ContainerRework_ListTrays.sql`: per-tray `LotId`/`LotName` = the tray LOT, or the container LOT for new trays.

**Test:** `sql/tests/0118_ContainerAsLot/060_repack.sql`

- [ ] **Step 1: Write the failing tests:**
  - scrap 2 from a new-shape container: LOT and tray both -2, RejectEvent on the container LOT;
  - move 3 from new A to new B: A LOT -3, B LOT +3, one edge A->B with 3 pieces, and a second move adds to the same edge (6);
  - move into an emptied receiver with no LOT mints one;
  - `ListTrays` "moved from" names A's LOT;
  - old-shape cases still pass (`-Filter 0111`).
- [ ] **Step 2: Run, implement, run.**
- [ ] **Step 3: Commit.**

### Task 8: OEE and FG KPI

**Files (modify):** `R__Oee_ufn_zzz_ShiftGood.sql`, `R__Oee_ufn_zzzz_ShiftInputFingerprint.sql`, `R__Lots_Lot_BackfillMintStamp.sql` (skip LOTs that are some `Container.LotId`), `R__Workorder_FinishedGoods_GetProducedSummary.sql`

**Rules (spec 7.5):**
- **`ufn_ShiftGood`:** the M&A branch = (old) FG LOTs with `Lot.ShiftId`, `UNION ALL` (new) trays with `ContainerTray.ShiftId = @ShiftId`. The new branch uses good = `MintedPieceCount`, `ItemId` from `Container`, area via `Oee.ufn_AreaFamily(t.ClosedAtTerminalId)`, `EventAt` = `ClosedAt`, and the same `AreaFamily = 'ma'` filter.
- **Fingerprint:** add the tray set.
- **`GetProducedSummary`:** pieces from the trays by `ClosedAt` window. Count containers (new) plus tray LOTs (old) in the "LOTs" column, keeping the column name.

**Test:** `sql/tests/0118_ContainerAsLot/070_oee.sql`

- [ ] **Step 1: Write the failing tests:**
  - a container with trays in shift A (2 trays) and shift B (1 tray): good A = 8, B = 4;
  - a mixed container: the old tray LOT counts once (via the LOT), new trays once each, total correct;
  - repack scrap after the shift: good unchanged and fingerprint unchanged (D11);
  - a rework-move tray (`ShiftId` NULL) never counts;
  - `BackfillMintStamp` leaves the container LOT's `ShiftId` NULL.
- [ ] **Step 2: Run, implement, run.** Then run `-Filter 0117` (expected 0 failed).
- [ ] **Step 3: Commit.**

### Task 9: LOT search

**Files (modify):** `R__Lots_Lot_Search.sql`, `R__Lots_Lot_SearchAdvanced.sql`, Core NQs `named-query/lots/Lot_Search/` and `Lot_SearchAdvanced/` (add the parameter, `sqlType` per the existing params)

**Interfaces:**
- **New last parameter** `@IncludeOlder BIT = 0`.
- **Result:** keep all columns. `TotalCount` becomes the rows returned (capped at `@LimitRows`), plus a new last column `HasMore BIT`.

**Rules (spec 8.2):**
- An exact `LotName` hit is always returned, whatever the window.
- Otherwise the window is `CreatedAt >= now - 90 days` unless `@IncludeOlder = 1`, or Advanced's own `@CreatedFromEt` / `@CreatedToEt` are given (they win).
- Prefix `LotName LIKE q + '%'`.
- Part match through `Parts.Item` first (`PartNumber`/`Description` `LIKE '%q%'`, then `ItemId IN`). The vendor LOT is matched inside the window.
- Fetch `TOP (@LimitRows + 1)` to set `HasMore`. No `COUNT(*) OVER()`.

**Test:** `sql/tests/0118_ContainerAsLot/080_lot_search.sql` (and update existing search tests that assert `TotalCount` > limit)

- [ ] **Step 1: Write the failing tests:**
  - a 200-day-old LOT is found by exact name, not by a partial name unless `@IncludeOlder = 1`;
  - with 101 matches, 100 rows are returned and `HasMore = 1`;
  - a part number search returns that part's recent LOTs;
  - Advanced's date range overrides the window.
- [ ] **Step 2: Run, implement, run.** Then grep `ignition/` for callers that read `TotalCount` and list them for Task 10.
- [ ] **Step 3: Commit.**

### Task 10: Ignition (files only) and docs

**Files (modify):**
- `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleEPrintWatcher/code.py`: add `containerTrayId` to the interface-log payload.
- `.../Workorder/Assembly/code.py`, `TrayInspectionWatcher`, `NonSerializedMipWatcher`: read-only check that nothing assumes a new LOT per tray. Change comments and messages only if they say "tray LOT".
- `.../Lots/AimPost/code.py`: the comment at line 77.
- NQ files changed in Tasks 5 and 9.
- `MPP_MES_DATA_MODEL.md`: rewrite the `Container` / `ContainerTray` sections from the live schema plus the new columns; add `Lot` clustered index notes; add a revision row.
- `PROJECT_STATUS.md`: append an entry for this branch.

**Rules:**
- Existing `view.json` files are NOT edited by file. List the Designer edits for Jacques in the status entry: LotDetail tray fields to "Container #n (k trays)", and the search screens' "Search older" toggle plus "100+".
- Compile-check changed Python in memory. Never leave a `__pycache__` in the project tree.

- [ ] **Step 1: Make the edits.**
- [ ] **Step 2: Byte-scan the changed SQL and NQ files for non-ASCII string literals.**
- [ ] **Step 3: Commit.**

### Task 11: Full suite

- [ ] **Step 1: Run** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CaL`. Expected: 0 failed, exit 0, and an assertion count of at least the Task 1 baseline plus the new 0118 assertions. Exit 1 with 0 failures means a file threw; check the count against the baseline.
- [ ] **Step 2: Fix and re-run until green.** Commit test fixes.

### Task 12: Year-scale benchmark

**Files:**
- Create: `sql/scratch/bench_lot_volume_seed.sql`. It starts with a guard that RAISERRORs and `SET NOEXEC ON` unless `DB_NAME() LIKE N'MPP_MES_Bench%'`, and has no `USE`.
- Create: `sql/scratch/Measure-LotVolume.ps1`, with `-Database` (no default) and `-Label`.
- Use the existing `sql/scratch/Measure-OeeDevVolume.ps1` with `-Database`.

**Databases:**
- **`MPP_MES_Bench`** (before; current code, tray shape).
- **`MPP_MES_Bench_After`**: restore `MPP_MES_Dev_for_Bench_2026-11-04.bak` again, then apply `0118` plus every repeatable changed on this branch (by file, via sqlcmd), and seed the container shape.
- **Run B** uses `MPP_MES_BenchB` / `MPP_MES_BenchB_After` the same way.

**Seed parameters (spec section 10):**
- `@Shape` `'Tray'|'Container'`; `@Run` `'A'|'B'`; `@Days = 365` ending at the last closed shift.
- **Calendar:** 3 x 8 h shifts, Mon-Fri, 7.5 productive hours per shift. Create missing `Oee.Shift` rows the way `seed_oee_history.sql` STEP 1 does.
- **Lines and rates:**
  - cam holders (`MA2-59B`, `MA2-6MACH`, `MA2-RPYCAM1`, `MA2-RPYCAM2`): 24 trays x 4 per container, one container every 30-40 min (random uniform);
  - oil pans (`MA2-64AOP`, `MA2-6MAOP`, `MA2-V6OP`): 6-8 x 60-pc containers per shift, one tray each;
  - every other line with an FG `ContainerConfig`: one tray every 3 min, container size from its config.
  - **Run B:** every line one tray every 3 min.
- **Sources:** per BOM line (or 1:1 for no-BOM parts), draw FIFO from a synthetic pool of source LOTs per component item. Each pool LOT holds 500 pcs and has a 2-level ancestry (a die-cast LOT parent, written into genealogy and closure), so closure depth matches real data.
- **Rows written per tray / container** mirror what `Assembly_CompleteTray` writes in that shape: Lot, LotStatusHistory, LotMovement, closure self-row, ConsumptionEvent, LotGenealogy (per draw for Tray; per pair for Container), closure, the tray row with stamps, and a `LotEventLog` `LotCreated` row per mint.
- **Set-based** (number tables, not cursors), committed in monthly batches with `CHECKPOINT`, so the log stays small (SIMPLE recovery).

**Measure (`Measure-LotVolume.ps1`):**
- rows and reserved MB per table (spec section 10 list);
- MESL numbers used per year, and years left in 3,000,000-9,999,999;
- cold/warm timings:
  - `Lot_Search` exact / prefix / part / vendor / empty, plus Advanced by part + date;
  - `GlobalTrace_Resolve` by container;
  - `Hold_ListAssociatedContainers`;
  - `Lot_GetLinkedContainer`;
  - `Oee.ShiftSummary_RecomputeRange` for one week;
  - `Assembly_CompleteTray` on the busiest line inside `BEGIN TRAN ... ROLLBACK`.

**Steps:**
- [ ] **Step 1: Write the seed.** Dry-run it with `@Days = 7` on `MPP_MES_Bench`, and check the per-tray row counts against one real `Assembly_CompleteTray` call (in a rolled-back transaction) on the same database.
- [ ] **Step 2: Run A before.** Full seed on `MPP_MES_Bench`, in the background. Then run `Measure-LotVolume.ps1 -Database MPP_MES_Bench -Label A-before` and `Measure-OeeDevVolume.ps1 -Database MPP_MES_Bench -Label A-before`.
- [ ] **Step 3: Run A after.** Build `MPP_MES_Bench_After`, seed the Container shape, and measure (`A-after`).
- [ ] **Step 4: Run B** before and after the same way.
- [ ] **Step 5: Write up the results.** Put the tables in spec section 12 and a summary row in `PROJECT_STATUS.md`. Commit the seed, the measure script and the docs. Drop the bench databases only if Jacques says so.

---

## Notes for the executor

- **Task order:** 1 -> 2 -> 3 -> {4, 5, 6, 7, 8} -> 9 -> 10 -> 11 -> 12.
- **Task 12 Steps 1-2** (seed, then run A on `MPP_MES_Bench`) need only today's code, so they can run in the background from the start.
- **Bench databases are throwaways.** `MPP_MES_Bench*` are never the gateway's database.
