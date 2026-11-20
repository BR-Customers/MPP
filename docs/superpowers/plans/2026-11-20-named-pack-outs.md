# Named Pack-Outs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several named pack-outs per (part, closure method), one default, selectable per terminal from the station Pack-Out popup; edits create versions; every box keeps its exact version.

**Architecture:** New header `Parts.PackOut` (identity: part, method, name, default) with `Parts.ContainerConfig` rows as its immutable versions; `Lots.Container.ContainerConfigId` keeps pointing at the exact version. One inline SQL rule decides "the pack-out in force" for (terminal, part): the open box the next tray would go into -> its version; else the terminal's pick; else the default. Every reader uses that rule.

**Tech Stack:** SQL Server 2022 (versioned migration + `R__` repeatables, T-SQL test framework under `sql/tests/`), Ignition 8.3 Perspective (file-based views), Jython 2.7 Core script library, named queries in Core.

**Spec:** `docs/superpowers/specs/2026-11-20-named-pack-outs-design.md` (decisions D1-D11, section 7.1a = the open-box rule).

## Global Constraints

- Branch `sp/parts-PackOut` in worktree `.claude/worktrees/packout`, stacked on `feature/scale-part-code-map`. Never commit to `main` / `jacques/working`; never touch prod. One PR at the end (SP-rule "cannot land separately" exception, stated in the PR body).
- Migration number **`0136_named_pack_outs`**.
- CLAUDE.md SQL conventions: `BIGINT IDENTITY` PKs, `NVARCHAR`, `DATETIME2(3)` UTC via `SYSUTCDATETIME()`, `_TEMPLATE_stored_procedure.sql` error pattern, FDS-11-011 (one result set, no OUTPUT params; mutations `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId`; every rejection before `BEGIN TRANSACTION`), audit Description `<SUBJECT> · <CATEGORY?> · <ACTION>` via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity`, resolved-name FK sub-objects in JSON. Seeds ASCII-only.
- Every changed proc bumps its header version + change-log line. New tables/columns get extended properties in `R__Descriptions_ExtendedProperties.sql` (update its trailer count).
- Python: no business rules (validation lives in SQL); every mutation takes `appUserId` from its caller; `except (Exception, java.lang.Exception)` on never-throw guards; status-row procs use NQ `type: Query`.
- Ignition view edits: check with `ignition-perspective` skill's `check_view.py`; never nest a view folder inside another; new view folders need `resource.json`.
- Performance (D9): `ufn_*` are **inline** TVFs only; no new lock hints/transactions in `Assembly_CompleteTray`; resolver applied once per call, never per LOT.
- Test runs use a private DB: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_PackOut` (never `MPP_MES_Dev`). Report the assertion count (exit code alone is not proof). Baseline on the base branch: recorded in Task 1 Step 1.

## Review Focus

1. **Terminal pick on a pack-out later removed** -> the terminal silently runs the default again (no error, no stale pick). Test in Task 3.
2. **Names differing only by case or surrounding spaces** ("Tote", " tote ") -> rejected as a duplicate (trimmed in the proc; CI collation on the unique index). Test in Task 3.
3. **Two operators tap different pack-outs at the same terminal at once** -> exactly one selection row, last write wins, no PK/unique error surfaced to the operator (`UPDLOCK, HOLDLOCK` upsert). Test (sequential double-set, no duplicate) in Task 4.
4. **Pack-out edited while a box is open on it** -> the PLC piece count / setpoint / weight verdict / tray close all keep using the box's version until it completes; the next box opens on the new version. Test in Task 5.
5. **A box opened before the release** (on a backfilled version) completes and reworks normally afterwards. Test in Task 1 (backfill) + Task 6 (rework same pack-out).

---

### Task 1: Migration 0136, backfill, test helpers, fixture rewrite

**Files:**
- Create: `sql/migrations/versioned/0136_named_pack_outs.sql`
- Create: `sql/tests/helpers/0136_packout_helpers.sql` (helpers `test.PackOut_Make`, used by fixtures)
- Modify: the 52 raw `INSERT INTO Parts.ContainerConfig` sites in `sql/tests/**` and `sql/seeds/020_seed_items.sql`, `sql/seeds_demo/010_demo_items_routes_boms.sql` (find with `git grep -n "INSERT INTO Parts.ContainerConfig" -- sql/tests sql/seeds sql/seeds_demo`)
- Modify: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`
- Test: `sql/tests/0136_PackOut/010_backfill_and_schema.sql`

**Interfaces:**
- Produces tables per spec section 6: `Parts.PackOut(Id, ItemId, ClosureMethod, Name, IsDefault, CreatedAt, CreatedByUserId, UpdatedAt, UpdatedByUserId, DeprecatedAt, DeprecatedByUserId)`; `Parts.ContainerConfig` + `PackOutId BIGINT NOT NULL`, `VersionNumber INT NOT NULL`, `CreatedByUserId BIGINT NULL`; `Location.TerminalPackOutSelection(Id, TerminalLocationId, ItemId, ClosureMethod, PackOutId, SetByUserId, SetAt)`.
- FK choices (fixture-friendly, prod never hard-deletes items): `PackOut.ItemId -> Parts.Item ON DELETE CASCADE`; `TerminalPackOutSelection.PackOutId -> PackOut ON DELETE CASCADE`; selection's `ItemId` / `ClosureMethod` carry **no** FK (copied from the header by the setter) to avoid multiple cascade paths. `ContainerConfig.PackOutId -> PackOut` no cascade.
- Indexes exactly as spec 6.1-6.3: `UQ_PackOut_ActiveName`, `UQ_PackOut_ActiveDefault`, `UQ_ContainerConfig_ActivePackOut (PackOutId) WHERE DeprecatedAt IS NULL INCLUDE (PartsPerTray, TraysPerContainer, TargetWeight, ToleranceWeight, IsSerialized, DunnageCode, CustomerCode, VersionNumber)`, `UQ_ContainerConfig_PackOutVersion (PackOutId, VersionNumber)`, `UQ_TerminalPackOutSelection (TerminalLocationId, ItemId, ClosureMethod) INCLUDE (PackOutId)`. Drop `UQ_ContainerConfig_ActiveItemMethod`.
- Audit codes seeded: `LogEntityType` `PackOut`; `LogEventType` `PackOutCreated`, `PackOutVersioned`, `PackOutRenamed`, `PackOutDefaultSet`, `PackOutDeprecated`, `PackOutSelected` (follow the 0113/0134 seeding pattern; idempotent `IF NOT EXISTS`).
- `test.PackOut_Make @ItemId BIGINT, @ClosureMethod NVARCHAR(20), @TraysPerContainer INT, @PartsPerTray INT, @IsSerialized BIT = 0, @TargetWeight DECIMAL(10,4) = NULL, @ToleranceWeight DECIMAL(10,4) = NULL, @Name NVARCHAR(50) = NULL, @CreatedAt DATETIME2(3) = NULL` -- silent (no result set); reuses the active header for (item, method, name) or creates it (`Name` default = method display name, `IsDefault = 1` if first active for the pair); inserts the next version. Raw inserts, not `PackOut_Save` (no status row to capture).

- [ ] **Step 1: Record the baseline.** Already running/ran on `MPP_MES_PackOutBase` at the base commit; record "N passed, 0 failed" in the PR notes. Expected: exit 0, 0 failed.
- [ ] **Step 2: Write `010_backfill_and_schema.sql`.** Build a fixture on the pre-backfill shape is impossible after migration, so test the backfill **logic** by asserting on the migration's result over seed data plus constraint behaviour:
  - `[Backfill] every ContainerConfig has a PackOutId` -> `SELECT COUNT(*) WHERE PackOutId IS NULL` = `0`
  - `[Backfill] one active default per (item, method) with an active config` -> count of (item, method) pairs with an active config and no active default = `0`
  - `[Backfill] header name is the method display name` -> for seed item `5G0-FG` (or any seeded ByCount row) `Name` = `By Count`
  - `[Schema] second active default refused` -> INSERT a 2nd `IsDefault=1` for the same pair inside TRY/CATCH -> caught error number `2601`
  - `[Schema] duplicate active name refused (case-insensitive)` -> `tote` after `Tote` -> `2601`
  - `[Schema] second active version per pack-out refused` -> `2601`
- [ ] **Step 3: Run it to see it fail.** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_PackOut -Filter 0136_PackOut` -> fails (no tables).
- [ ] **Step 4: Write `0136_named_pack_outs.sql`** (idempotent guards, SchemaVersion row like `0134`). Backfill per spec 6.4: one header per existing (ItemId, ClosureMethod) group; `Name` from `Parts.ClosureMethodCode` display name (`By Count` / `By Weight` / `By Vision` -- confirm the column in 0040); all rows become versions ordered by `CreatedAt, Id`; group with no active row -> header deprecated at the latest row's `DeprecatedAt`, `IsDefault = 0`; `CreatedByUserId = 1`. Add column NULL -> backfill -> `ALTER ... NOT NULL` -> FKs/indexes.
- [ ] **Step 5: Write the helper and rewrite fixtures.** Each raw insert becomes `EXEC test.PackOut_Make ...` with the same values (multi-row `INSERT ... SELECT` sites: a cursor-free loop or one `EXEC` per item -- implementer's choice). Fixtures that later read the config Id by `SCOPE_IDENTITY()` read it by `(ItemId, ClosureMethod, DeprecatedAt IS NULL)` instead. Seeds: same, but seeds may not depend on `test.*` -- inline the header insert there.
- [ ] **Step 6: Full suite.** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_PackOut` -> 0 failed, assertion count = baseline + the new file's assertions. Any file that throws (exit 1, 0 failed) hides later batches: fix before moving on.
- [ ] **Step 7: Extended properties** for the 2 new tables and 3 new columns; rerun the descriptions test file. Commit: `feat(sql): 0136 named pack-outs -- PackOut header, versioned ContainerConfig, terminal selection`.

### Task 2: The one rule -- resolver and open-box functions

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_ufn_ResolvePackOut.sql`, `R__Lots_ufn_ContainerForNextTray.sql`, `R__Parts_ufn_PackOutInForce.sql`
- Test: `sql/tests/0136_PackOut/020_resolve.sql`

**Interfaces (all inline TVFs):**
- `Parts.ufn_ResolvePackOut(@ItemId BIGINT, @ClosureMethod NVARCHAR(20), @TerminalLocationId BIGINT)` -> 0..1 row: `ContainerConfigId, PackOutId, PackOutName, VersionNumber, Source NVARCHAR(10) ('Selected'|'Default'), PartsPerTray, TraysPerContainer, TargetWeight, ToleranceWeight, IsSerialized, DunnageCode, CustomerCode`. Active pick (header active) wins, else active default.
- `Lots.ufn_ContainerForNextTray(@CellLocationId BIGINT, @ItemId BIGINT, @StationLocationId BIGINT)` -> 0..1 row `ContainerId, ContainerConfigId`: exactly `Assembly_CompleteTray` step 8's lookup (own box; else unowned box; NULL station -> oldest at the line), no lock hints.
- `Parts.ufn_PackOutInForce(@ItemId, @ClosureMethod, @TerminalLocationId, @CellLocationId)` -> same columns as `ufn_ResolvePackOut` with `Source` extended to `'OpenBox'`, plus `OpenContainerId`. Open box (via `ufn_ContainerForNextTray(@CellLocationId, @ItemId, <@TerminalLocationId if it is an LTD-7 terminal else NULL>)`) -> that box's config row joined to its header; else `ufn_ResolvePackOut`. `@CellLocationId` NULL -> derived as the terminal's `ParentLocationId`.

- [ ] **Step 1: Write `020_resolve.sql`** with assertions:
  - `[Resolve] no pick -> default` (Source `Default`, PartsPerTray of default)
  - `[Resolve] pick wins` (Source `Selected`)
  - `[Resolve] pick on deprecated pack-out -> default`
  - `[Resolve] NULL terminal -> default`
  - `[Resolve] pick is per part` (terminal picks Tote for item A; item B still default)
  - `[InForce] open box version wins over pick` (open a container stamped with v1, then insert v2 active + pick -> Source `OpenBox`, PartsPerTray of v1)
  - `[InForce] unowned open box at the line is used for a terminal with no own box`
  - `[InForce] no open box -> resolver`
- [ ] **Step 2: Run, see it fail.**
- [ ] **Step 3: Implement the three functions.**
- [ ] **Step 4: Run, see it pass.** Commit `feat(sql): pack-out resolver + open-box rule (inline TVFs)`.

### Task 3: Pack-out CRUD procs; drop the old writers

**Files:**
- Create: `R__Parts_PackOut_Save.sql`, `R__Parts_PackOut_SetDefault.sql`, `R__Parts_PackOut_Deprecate.sql`, `R__Parts_PackOut_ListByItem.sql`
- Modify: `R__Parts_Item_Deprecate.sql` (cascade headers + delete their selections)
- Delete: `R__Parts_ContainerConfig_Create.sql`, `_Update.sql`, `_Deprecate.sql`, `_GetByItem.sql` (add `DROP PROCEDURE IF EXISTS` for each to `0136`), and `ContainerConfig_ListHistory` (my call: drop -- the buttons replace it; its NQ goes in Task 7)
- Test: `sql/tests/0136_PackOut/030_crud.sql`; delete/replace `sql/tests/0008_Parts_Item/020_ContainerConfig_crud.sql`, `026_..multi_method`, `027_..resolve`, `028_..tolerance`, `030_..ListHistory` (port the still-relevant assertions -- tolerance validation, multi-method -- into `030_crud.sql`)

**Interfaces:**
- `Parts.PackOut_Save @PackOutId BIGINT = NULL, @ItemId BIGINT, @ClosureMethod NVARCHAR(20), @Name NVARCHAR(50), @TraysPerContainer INT, @PartsPerTray INT, @IsSerialized BIT = 0, @DunnageCode NVARCHAR(50) = NULL, @CustomerCode NVARCHAR(50) = NULL, @TargetWeight DECIMAL(10,4) = NULL, @ToleranceWeight DECIMAL(10,4) = NULL, @AppUserId BIGINT` -> `Status, Message, NewId` (= PackOutId). Rules (spec 7.1): trim name, required non-empty; positive trays/parts; ByWeight needs positive target and tolerance; create = header + v1 (default if first active for the pair); existing: name change -> header update (`PackOutRenamed`), value change -> deprecate active version + insert N+1 (`PackOutVersioned`); both may happen in one call; nothing changed -> Status 0 "No changes to save."; `@ItemId`/`@ClosureMethod` on an existing pack-out must match the header (immutable).
- `Parts.PackOut_SetDefault @PackOutId, @AppUserId` -> `Status, Message`; no-op rejected.
- `Parts.PackOut_Deprecate @PackOutId, @AppUserId` -> `Status, Message`; refuses the default while other active pack-outs exist for the pair (message: "Make another pack-out the default before removing this one."); deprecates header + active version; deletes selections on it.
- `Parts.PackOut_ListByItem @ItemId, @TerminalLocationId = NULL` -> rows `PackOutId, ClosureMethod, Name, IsDefault, IsSelected BIT, IsRunning BIT, ContainerConfigId, VersionNumber, PartsPerTray, TraysPerContainer, TargetWeight, ToleranceWeight, IsSerialized, DunnageCode, CustomerCode, UpdatedAtEt` ordered `ClosureMethod, IsDefault DESC, Name`. `IsRunning` = `ufn_PackOutInForce(...).PackOutId = PackOutId` (NULL terminal -> `IsRunning = IsDefault`).

- [ ] **Step 1: Write `030_crud.sql`** assertions: create first -> default; create second -> not default; duplicate name (case/space) refused; value edit -> new version number 2, old version deprecated, `Lots.Container` stamped with v1 still points at v1; rename only -> same version; rename + values -> one new version; no-op refused; ByWeight zero tolerance refused (message as today's Python: "positive tolerance"); SetDefault moves the flag (exactly one default after); Deprecate default with siblings refused; Deprecate non-default ok and its selection rows gone; Deprecate last one ok; ListByItem flags with and without a terminal; `Item_Deprecate` deprecates headers.
- [ ] **Step 2: Run, fail. Step 3: implement. Step 4: run file + full suite** (old tests deleted/ported). Commit `feat(sql): PackOut_Save/SetDefault/Deprecate/ListByItem; retire ContainerConfig writers`.

### Task 4: Terminal selection

**Files:** Create `R__Location_Terminal_SetPackOut.sql`; Test `sql/tests/0136_PackOut/040_terminal_select.sql`

**Interfaces:** `Location.Terminal_SetPackOut @TerminalLocationId BIGINT, @PackOutId BIGINT, @AppUserId BIGINT` -> `Status, Message`. Refuses: missing params; not an active LTD-7 terminal; pack-out missing/deprecated; **open box for that part per `ufn_ContainerForNextTray(<terminal parent>, item, terminal)`** (message: "Box #<id> is open -- finish or close it before changing pack-out."); no-op (already the explicit pick). Upsert with `UPDLOCK, HOLDLOCK` on the selection row. Audit `Audit.OperationLog` `PackOutSelected`, Description `<TerminalCode> · Pack-Out · <PartNumber> <OldName> -> <NewName>`.

- [ ] **Step 1: Test** assertions: set ok + row exists; second set to another pack-out updates the same row (count stays 1); refused with own open box; refused with an unowned open box at the line; refused for deprecated pack-out; no-op refused; audit row written.
- [ ] **Step 2-4:** fail, implement, pass. Commit `feat(sql): Terminal_SetPackOut -- refused while a box is open`.

### Task 5: Readers follow the pack-out in force

**Files (modify, version bump each):** `R__Workorder_Assembly_CompleteTray.sql`, `R__Parts_ContainerConfig_JudgeWeight.sql`, `R__Workorder_Assembly_GetTraysRemaining.sql`, `R__Workorder_ScaleStation_GetRunningPart.sql`, `R__Workorder_ufn_ScaleStationEligibleParts.sql`, `R__Parts_ContainerConfig_GetByItemAndMethod.sql`. Test: `sql/tests/0136_PackOut/050_readers.sql`; update existing tests whose captured column lists change (`0113_ScaleStation/*`, `0008_Parts_Item/029_ContainerConfig_JudgeWeight.sql`, `0028_PlantFloor_Assembly/101_*`).

**Interfaces:**
- `CompleteTray`: step 4b/8 use `ufn_PackOutInForce(@FinishedGoodItemId, @ClosureMethod, @StationLocationId, @CellLocationId)` -- `PartsPerTray` / `TraysPerContainer` come from the open box when there is one, the resolved version otherwise; B2's locked lookup unchanged; a newly opened box is stamped with the resolved `ContainerConfigId`. Result set unchanged.
- `JudgeWeight`: `+ @TerminalLocationId BIGINT = NULL` (append after existing params); window from `ufn_PackOutInForce`; result `+ PackOutName` (last column).
- `GetTraysRemaining`: `+ @TerminalLocationId BIGINT = NULL`; result unchanged.
- `GetRunningPart`: config columns from `ufn_PackOutInForce` for the chosen part; `+ PackOutId, PackOutName, PackOutSource` appended.
- `ufn_ScaleStationEligibleParts`: eligibility "has a By Weight pack-out with PartsPerTray > 0" and parts-for-a-tray via `ufn_ResolvePackOut(i.Id, N'ByWeight', @TerminalLocationId)` (CROSS APPLY per finished good, before the stock aggregate); keep v1.2's literal `LotStatusId <> 4`.
- `GetByItemAndMethod`: `+ @TerminalLocationId BIGINT = NULL`; returns `ufn_PackOutInForce` row mapped to the existing columns (`Id` = ContainerConfigId) `+ PackOutId, PackOutName, PackOutSource`.

- [ ] **Step 1: Test** assertions (Review Focus 4): with a box open on v1 and the pack-out edited to v2 + picked: `GetByItemAndMethod` PartsPerTray = v1's; `JudgeWeight` limits = v1's; `GetRunningPart` PackOutSource = `OpenBox`; `CompleteTray` with PieceCount = v1's PartsPerTray succeeds and the tray lands in the v1 box; after Complete, next `CompleteTray` needs v2's count and opens a box stamped v2. Terminal with a Tote pick and no box: `GetRunningPart` returns Tote's target; eligibility uses Tote's PartsPerTray. No pick: every reader equals pre-change behaviour (default).
- [ ] **Step 2-4:** fail, implement, pass; full suite. Commit `feat(sql): readers use the pack-out in force (open box > pick > default)`.

### Task 6: No rework across pack-outs (D11)

**Files:** Modify `R__Lots_ContainerRework_ListTargets.sql`, `R__Lots_ContainerRework_MovePieces.sql`; Test `sql/tests/0136_PackOut/060_rework.sql`.

**Interfaces:** ListTargets adds `AND tcc.PackOutId = scc.PackOutId` (target's config header = source's; any version). MovePieces refuses a different-pack-out target: message "Box #<to> is a different pack-out (<name>) -- pieces can only move between boxes of the same pack-out." Result sets unchanged.

- [ ] **Step 1: Test:** same pack-out different versions -> listed + move ok (Review Focus 5); different pack-out -> not listed + move refused. **Step 2-4** fail/implement/pass. Commit `feat(sql): rework targets limited to the same pack-out`.

### Task 7: Core Python + named queries

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/ContainerConfig/code.py`
- Create NQs (Core `named-query/parts/`): `PackOut_Save`, `PackOut_SetDefault`, `PackOut_Deprecate`, `PackOut_ListByItem`; (`location/`) `Terminal_SetPackOut`. Status-row ones `type: Query`; PIN-safe types not relevant; ids `sqlType` BIGINT as in sibling NQs.
- Modify NQs: `ContainerConfig_GetByItemAndMethod`, `ContainerConfig_JudgeWeight` (+ `terminalLocationId`). Delete NQs: `ContainerConfig_Create/_Update/_Deprecate/_GetByItem/_ListHistory`.
- Modify callers: `Workorder/Assembly/code.py` (`resolvePlcCloseContext`, `_recommendedWithPackout` pass the terminal), `Workorder/ScaleWatcher/code.py` (setpoint push), `Workorder/ScaleEPrintWatcher/code.py`, `Workorder/ScaleDigiWatcher/code.py` (`judgeWeight(..., terminalLocationId=...)`).
- Test: extend `tools/test_scale_digi_watcher.py` / `tools/test_scale_eprint_watcher.py` to assert the terminal id is passed to `judgeWeight`.

**Interfaces (module `BlueRidge.Parts.ContainerConfig`):**
- `getByItemAndMethod(itemId, method, terminalLocationId=None) -> dict|{}`; `getByItemAndMethodOrEmpty(itemId, method, _refreshToken=None, terminalLocationId=None)` (keep positional order; terminal is a keyword at the end so the existing view binding keeps working until Task 8 passes it).
- `judgeWeight(itemId, method, weight, scaleFlags=None, terminalLocationId=None) -> dict`
- `listForItem(itemId, terminalLocationId=None) -> {"ByCount": [row...], "ByWeight": [...], "ByVision": [...]}` (always full shape)
- `save(packOut: dict, appUserId) -> {Status, Message, NewId}`; `setDefault(packOutId, appUserId)`; `deprecate(packOutId, appUserId)`; `select(terminalLocationId, packOutId, appUserId)` -> `{Status, Message}`. Each calls `Common.Util.requireAppUserId`.
- Remove `add`, `update`, `saveDraft`, `getDraftForItem`, `getHistoryForItem`, `getByItem*` once Tasks 8-9 no longer call them (grep must be empty).

- [ ] **Step 1:** python tests asserting terminal passthrough (fail). **Step 2:** implement. **Step 3:** `python tools/test_scale_digi_watcher.py && python tools/test_scale_eprint_watcher.py` -> OK. **Step 4:** compile-check every touched `code.py` in memory (no `__pycache__` in the tree). Commit `feat(core): pack-out entity functions; scale/assembly callers pass the terminal`.

### Task 8: Station popup + Pack-Out button availability

**Files:** Modify `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/PackOutEdit/view.json`, `.../Views/ShopFloor/AssemblyNonSerialized/view.json`.

**Requirements (spec 8.1-8.2):**
- Per method section: a flex-repeater (or button row) of pack-out buttons from `listForItem(itemId, terminalId)`: name, `<ppt>/tray x <trays>` (+ `<target> lb` for ByWeight), default marker, running one highlighted; `+ New`.
- Tap -> `select(...)`; on Status 1 load into the form, toast success, send `packOutChanged` (page); on Status 0 toast the message (warning) and load nothing. Non-terminal session (`session.custom.terminal.terminalLocationId` empty) -> buttons disabled with caption "Pack-out can only be selected at a registered terminal."
- Form adds required **Name** field (keyboard via existing `Components/PlantFloor/Keyboard`); Save -> `save`; `Make default`, `Remove` -> `setDefault` / `deprecate`; each success sends `packOutChanged` and reloads the list. "Load a previous pack-out..." dropdowns and per-section Clear removed. Numeric keypad behaviour unchanged.
- `AssemblyNonSerialized`: Pack-Out button visible when `{view.params.allowPackOutEdit} = true || {session.custom.closureMethod} = "ByWeight"`; `fgConfig` binding passes the terminal; header shows the running pack-out name (`fgConfig.PackOutName`).
- Pre-declare every new bound `view.custom.*` with a full-shape default; `listForItem` always returns the full shape.

- [ ] **Step 1:** edit both views (popup not open in any Designer -- file edits allowed). **Step 2:** `check_view.py` clean on both. Commit `feat(mpp): Pack-Out popup -- one button per named pack-out, select per terminal`.

### Task 9: Config Tool Item Master Container Config tab

**Files:** Modify `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json`, `.../Popups/ItemContainerConfigHowTo/view.json`.

**Requirements:** per method, the part's pack-outs (name, values, version, default marker) via `listForItem(itemId)`; select one to edit in the form; Add / Save / Make default / Remove through the same entity functions; per-section ownership pattern kept (`view.custom.state = {selected, editDraft}` atomic writes, `sectionDirtyChanged`, `sectionSaveRequested` / `sectionDiscardRequested` handlers, `params.value: itemId` input-only). `appUserId=BlueRidge.Common.Session.currentAppUserId(self.session)`. How-to text rewritten for named pack-outs + defaults + versions.

- [ ] **Step 1:** edit. **Step 2:** `check_view.py` clean. Commit `feat(config): Item Master named pack-outs editor`.

### Task 10: Performance measurement (D9)

**Files:** Create `sql/scratch/2026-11-20_packout_perf.sql` (measure script), results in the PR body and `notes/2026-11-20_packout-perf.md`.

- [ ] **Step 1:** Restore/copy pattern from `notes/sp-review-handoff/perf/` onto two throwaway bench DBs: `MPP_MES_Bench` at the base commit's procs vs a copy with `0136` + this branch's repeatables applied (never `MPP_MES_Dev`).
- [ ] **Step 2:** For `ScaleStation_GetRunningPart`, `ScaleStation_ListEligibleParts`, `ContainerConfig_JudgeWeight`, `Assembly_GetTraysRemaining`, `ContainerConfig_GetByItemAndMethod`, `Assembly_CompleteTray` (BEGIN TRAN ... ROLLBACK): `SET STATISTICS IO, TIME ON` + actual plan, 5 runs each, same terminal/part.
- [ ] **Step 3:** Pass = logical reads on `Lot`, `Container`, `ContainerTray` not higher; new tables single-digit reads; no new parallelism; elapsed within noise. A failing proc gets fixed before the PR. Commit the script + note.

### Task 11: Docs, Dev apply, gateway verification, PR

- [ ] **Step 1:** `MPP_MES_DATA_MODEL.md` (new tables/columns, revision row), `PROJECT_STATUS.md` entry (built, not deployed), release pre-flight gate in `sql/scripts/Deploy-ProdRelease.ps1` gates for 0136 (resolver == old lookup for every active (item, method); BLOCK on any difference) per `prod-release-context-pack/04_preflight_gates.md`.
- [ ] **Step 2:** Apply `0136` + changed repeatables to `MPP_MES_Dev` additively (check Dev is at `0135` first; do not reset Dev). Copy the touched Ignition resources into the main checkout (the gateway reads it), record the list in the shared notes folder like the Digi session did, `.\scan.ps1`, check `wrapper.log` for script errors.
- [ ] **Step 3:** Browser walk at a By Weight terminal context: open Pack-Out, add "Tote", select it, confirm running highlight + station header; open a box and confirm select is refused; edit Tote mid-box -> box target unchanged; Config Tool Item Master tab (needs AD sign-in -- if the test browser cannot, say so). Screenshot proof.
- [ ] **Step 4:** Full suite count vs baseline; push branch; `gh pr create --base feature/scale-part-code-map` (stacked) with the SP-rule body (problem, change, result-set changes + callers, version bumps, assertion counts before/after, perf table). Do not merge.
