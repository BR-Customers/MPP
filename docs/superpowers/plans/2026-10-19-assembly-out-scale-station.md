# Assembly Out Scale Station Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Assembly Out in By Weight mode a scale station screen with these parts:
- the running part, from one SQL rule shared with the scale close, plus an audited per-terminal override;
- the open box's tray progress;
- the last press;
- a press log, a shift tally and recent boxes, all read from `Audit.InterfaceLog`, which gains structured context.

**Architecture:**
- Migration `0113` adds `LocationId` / `ItemId` / `LotId` to `Audit.InterfaceLog` and seeds the `ScaleRunningItemId` terminal attribute.
- The EPrint watcher writes JSON payloads plus that context on every press, and broadcasts `scalePressRecorded`.
- One inline TVF decides eligibility (spec §5.1). Read procs feed new embedded views, which are placed into the existing Assembly Out view in Designer.

**Tech Stack:** SQL Server 2022 (T-SQL procs, `sql/tests` framework); Ignition 8.3 (Jython project library, named queries, Perspective views).

**Spec:** `docs/superpowers/specs/2026-10-19-assembly-out-scale-station-design.md` (rev 2, all questions resolved). Mockup: Artifact "Assembly Out - Scale Station" (`MultiTray`, `Main`, `Refused` screens).

## Global Constraints

- Branch off `jacques/working`. Commit with explicit paths only (`feedback_git_explicit_staging`). No `Co-Authored-By` trailer. Don't push.
- Migration number **`0113`**: `0109`–`0112` are taken on `jacques/controlled-run-super-lot`.
- Procs follow `sql/scripts/_TEMPLATE_stored_procedure.sql`:
  - FDS-11-011: no `OUTPUT` params, one result set.
  - Mutations end in `SELECT @Status AS Status, @Message AS Message`, with every rejecting validation before `BEGIN TRANSACTION`.
  - `RAISERROR` in `CATCH`; `EXEC` args are literals or variables only.
- Displayed timestamps are Eastern: `CAST(<utc> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- Seed / description strings are ASCII only (no em dash, no middle dot except via `Audit.ufn_MidDot()`).
- Audit Description shape: `<SUBJECT> · <CATEGORY> · <ACTION>` via `Audit.ufn_MidDot()`, `Audit.ufn_TruncateActivity`.
- Every NQ lives in `ignition/projects/Core/ignition/named-query/<schema>/<Name>/` (`query.sql` + `resource.json`). Status-row procs use NQ `type: Query`; silent procs use `UpdateQuery`.
- New views: write the files and run `scan.ps1`. **Existing** `view.json` (`AssemblyNonSerialized`) is edited **in Designer**, not on disk (CLAUDE.md file-edit boundary).
- Every bound `view.custom.*` gets a fully shaped default, and each binding source returns the full shape on the empty path (`getXOrEmpty`).
- Mutations take `appUserId` from the caller: `BlueRidge.Common.Session.currentAppUserId(self.session)` in views, and `Common.Util.requireAppUserId` in entity functions.
- Eligibility constants (spec §5.1):
  - **60%** of the other BOM lines.
  - **Covered** = stock `>= QtyPer * PartsPerTray`.
  - **Cast line** = child `ItemType.Code IN ('Component','SubAssembly')`, **at least one** covered.
  - The finished good must be in `Parts.v_EffectiveItemLocation` for the line or an ancestor.
- SQL suite baseline is **4434** assertions on `jacques/working` @ `102bebf5`. Run on a throwaway DB (`.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_<x>`), never Dev. Exit 1 with 0 failures means a file threw, so check the assertion **count**.

## Review Focus

1. **Override part becomes ineligible** (its stock drops below a tray). Expected: the scale falls back to the default, and the banner says so ("Override 12345 is not eligible, running default"). It is never silently ignored, and the scale never refuses because of it. Test: Task 3, `[ScaleRun] ineligible override falls back with message`.
2. **An open box of another part when an override is set.** Expected: the open box wins, so the box is never split across parts, and setting the override is refused until the box is done. Tests: Task 3 `[ScaleRun] open box beats override`, and Task 4 `[SetRun] refused with another part's box open`.
3. **Interface-log rows that aren't this feature's JSON** (pre-0113 text rows, Zebra rows at the same terminal, the `Scale flags warning` row). Expected: the press log skips them, with no `JSON_VALUE` error and no duplicate rows. Test: Task 6, `[PressLog] skips non-JSON, Zebra and flags-warning rows`.
4. **A terminal with no shift covering now.** Expected: the tally returns one row of zeros, not an empty set, so the view's binding keeps its shape. Test: Task 6, `[Tally] no covering shift returns zeros`.
5. **Multi-tray progress after a refusal.** Expected: tray progress counts only closed trays from production records (`Lots.ContainerTray`). A refused press never advances it. Test: Task 6, `[RunPart] open box trays closed ignores refusals`.

---

### Task 1: Interface log context columns + terminal attribute (migration 0113)

**Files:**
- Create: `sql/migrations/versioned/0113_interfacelog_context.sql`
- Modify: `sql/migrations/repeatable/R__Audit_Audit_LogInterfaceCall.sql` (v+1)
- Modify: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`
- Modify: `ignition/projects/Core/ignition/named-query/audit/Audit_LogInterfaceCall/{query.sql,resource.json}`
- Test: `sql/tests/0113_ScaleStation/010_InterfaceLog_context.sql`

**Interfaces:**
- Produces:
  - `Audit.InterfaceLog.LocationId / ItemId / LotId BIGINT NULL`, with FKs to `Location.Location`, `Parts.Item` and `Lots.Lot`.
  - Index `IX_InterfaceLog_Location_LoggedAt (LocationId, LoggedAt DESC) WHERE LocationId IS NOT NULL ON ps_MonthlyUtc(LoggedAt)`.
  - `Audit.Audit_LogInterfaceCall` gains `@LocationId BIGINT = NULL, @ItemId BIGINT = NULL, @LotId BIGINT = NULL`.
  - NQ params `locationId`, `itemId`, `lotId` (sqlType 3).
  - Terminal attribute definition (LTD 7) `ScaleRunningItemId`, NVARCHAR, seeded in the `0041` shape.

- [ ] **Step 1: Write the failing test** `010_InterfaceLog_context.sql`:
  - `[IfLog] context columns written`: call `Audit_LogInterfaceCall` with all three set, then assert the row's three values.
  - `[IfLog] context columns default NULL`: call it without them, then assert all three are NULL.
  - `[IfLog] index is partition-aligned`: `sys.indexes` joined to `sys.partition_schemes` for `IX_InterfaceLog_Location_LoggedAt` returns `ps_MonthlyUtc`.
  - `[IfLog] ScaleRunningItemId attribute defined on LTD 7`.
- [ ] **Step 2: Run** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Ss1 -Filter 0113`. Expected: FAIL (invalid column `LocationId`).
- [ ] **Step 3: Implement.**
  - Write the migration (columns, FKs, index, attribute row) with a `SchemaVersion` insert like its neighbours.
  - Pass the three params through in the proc's `INSERT`. The proc stays silent.
  - Add the NQ params and the extended properties (one sentence each, from spec §3).
- [ ] **Step 4: Run** the filter again (PASS). Then run the full suite: **4434 + 4** expected, 0 failed.
- [ ] **Step 5: Commit** `feat(audit): InterfaceLog LocationId/ItemId/LotId context + ScaleRunningItemId attribute (0113)`.

### Task 2: Watcher writes JSON + context and announces every press

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/PlcWatcher/code.py` (`logInterface`)
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleEPrintWatcher/code.py` (`handleMessage`, `_refuse`)
- Test: `tools/test_scale_eprint_watcher.py`

**Interfaces:**
- Consumes: Task 1 NQ params.
- Produces:
  - `PlcWatcher.logInterface(..., locationId=None, itemId=None, lotId=None)`.
  - Page message `scalePressRecorded` with payload `{"terminalLocationId": <id>}`, sent via `PlcWatcher.broadcastPageMessage` after **every** `handleMessage` outcome (close, refusal, failure), never raising.
  - `RequestPayload` JSON keys exactly as spec §4: `v` (=1), `net`, `uom`, `cam`, `flags`, `flagsState`, `verdict`, `low`, `high`, `scaleVerdict`, `agree`. Keys not reached are omitted.
  - `ResponsePayload` = `system.util.jsonEncode(result)`.

- [ ] **Step 1: Write the failing tests** (in `HandleMessageTests`; the stub's `logInterface` already records kwargs). Stub `system.util.jsonEncode` as `json.dumps`, and add `broadcastPageMessage` to the recorder.
  - `test_payload_is_json_v1`: `json.loads(log["requestPayload"])` has `v == 1`, `net == 50.0`, `verdict == "Ok"`, `flags == {"under":0,"over":0,"ok":1}`, `agree is True`.
  - `test_refusal_before_judging_omits_verdict`: wrong units leads to no `verdict` key and `itemId is None`.
  - `test_context_on_close`: `locationId == 106`, `itemId == 110`, `lotId == 77` (stub close result `{"Status":1,"FinishedGoodLotId":77,...}`).
  - `test_context_on_refusal`: Under gives `locationId == 106`, `itemId == 110`, `lotId is None`.
  - `test_press_broadcast_every_outcome`: close, Under, unreadable and failed close each send exactly one `scalePressRecorded` with `terminalLocationId == 106`.
  - `test_flags_warning_row_carries_context`: a mismatch warning row has `locationId == 106`, `itemId == 110`.
- [ ] **Step 2: Run** `python tools/test_scale_eprint_watcher.py`. Expected: the 6 new tests FAIL.
- [ ] **Step 3: Implement.**
  - Build the payload as a dict and `jsonEncode` it once per log call.
  - Thread `terminalLocationId` (and `ctx["finishedGoodItemId"]` once resolved) into every `logInterface` / `_refuse` call.
  - Send one broadcast at the single exit of `handleMessage`.
  - Keep the existing human-readable `Description` strings unchanged.
- [ ] **Step 4: Run** the harness. Expected: all PASS (20 + 6).
- [ ] **Step 5: Commit** `feat(scale): press rows carry JSON + LocationId/ItemId/LotId; scalePressRecorded on every press`.

### Task 3: Eligibility rule and running part (SQL)

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_ufn_ScaleStationEligibleParts.sql`
- Create: `sql/migrations/repeatable/R__Workorder_ScaleStation_ListEligibleParts.sql`
- Create: `sql/migrations/repeatable/R__Workorder_ScaleStation_GetRunningPart.sql`
- Create NQs: `workorder/ScaleStation_ListEligibleParts`, `workorder/ScaleStation_GetRunningPart` (`type: Query`, `terminalLocationId` sqlType 3)
- Test: `sql/tests/0113_ScaleStation/020_EligibleParts.sql`, `030_GetRunningPart.sql`

**Interfaces:**
- Produces:
  - `Workorder.ufn_ScaleStationEligibleParts(@TerminalLocationId BIGINT)`, an inline TVF.
    - Columns: `ItemId, PartNumber, Description, PartsPerTray, TraysPerContainer, TargetWeight, ToleranceWeight, LinesTotal, LinesCovered, ShareCovered DECIMAL(5,4), CastLinesCovered, TraysCovered, ReadyRank`.
    - Rows: only eligible parts. `ReadyRank` 1 = closest to ready: `ShareCovered DESC`, then earliest ready stock, then `PartNumber`.
    - The line is the terminal's zone cell: the `ZoneId` that `Location.Terminal_List` reports and `resolvePlcCloseContext` uses. Read how `Terminal_List` derives it and use the same expression; don't assume it's the direct parent.
  - `Workorder.ScaleStation_ListEligibleParts(@TerminalLocationId)`: the TVF rows plus `LowLimit`, `HighLimit`, ordered by `ReadyRank`.
  - `Workorder.ScaleStation_GetRunningPart(@TerminalLocationId)`: **exactly one row**, columns as spec §5 plus:
    - `OverrideItemId`, `OverrideSetBy`, `OverrideSetAtEt`;
    - `OpenContainerId`, `OpenTraysClosed`, `OpenPartsClosed`.

- [ ] **Step 1: Write the failing tests.** Fixture: one line, one terminal, three FGs, built through `Parts.Item_Create`, `Bom` / `BomLine`, `ContainerConfig_Create` ByWeight, `ItemLocation`, and `Lots.Lot_Create` Received.
  - `[Elig] cast line uncovered -> not eligible`.
  - `[Elig] one of two cast lines covered + 60% others -> eligible`.
  - `[Elig] 59% of other lines -> not eligible` and `60% -> eligible`, using a 5-other-line BOM where 3/5 covered = 60% and 2/5 is not.
  - `[Elig] covered needs QtyPer*PartsPerTray` (stock one short of a tray = uncovered).
  - `[Elig] no ByWeight pack-out -> not eligible`.
  - `[Elig] not in v_EffectiveItemLocation for the line -> not eligible`.
  - `[Elig] ReadyRank 1 = highest ShareCovered`.
  - `[ScaleRun] default = ReadyRank 1, Source Default`.
  - `[ScaleRun] override honoured, Source Override`.
  - `[ScaleRun] ineligible override falls back with message` (`Source = 'Default'`, `Message LIKE '%not eligible%'`).
  - `[ScaleRun] open box beats override`.
  - `[ScaleRun] nothing eligible -> Source None, one row, Message set`.
  - `[ScaleRun] EligibleCount`.
- [ ] **Step 2: Run** `-Filter 0113`. Expected: FAIL (object not found).
- [ ] **Step 3: Implement** the TVF (CTEs: eligible FGs at the line, active published BOM, per-line availability vs `QtyPer * PartsPerTray`, aggregates), then the two procs over it. Read the override from the `ScaleRunningItemId` attribute (`TRY_CAST` to BIGINT). Take the open box from the station's open `Lots.Container` with ByWeight config (`StationLocationId = @TerminalLocationId`). The pass-through repack rule follows `Item_ListEligibleFinishedGoodsRanked` v1.1.
- [ ] **Step 4: Run** `-Filter 0113`, then the full suite (count = previous + 13).
- [ ] **Step 5: Commit** `feat(scale): eligibility TVF (cast good + 60% at one tray) + ScaleStation_GetRunningPart/ListEligibleParts`.

### Task 4: Set / clear the override (audited)

**Files:**
- Create: `sql/migrations/repeatable/R__Location_Terminal_SetScaleRunningPart.sql`
- Create NQ: `location/Terminal_SetScaleRunningPart` (`type: Query`; `terminalLocationId`, `itemId`, `appUserId` sqlType 3)
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleStation/{code.py,resource.json}`
- Test: `sql/tests/0113_ScaleStation/040_SetScaleRunningPart.sql`

**Interfaces:**
- Consumes: `Workorder.ufn_ScaleStationEligibleParts` (Task 3).
- Produces:
  - `Location.Terminal_SetScaleRunningPart(@TerminalLocationId BIGINT, @ItemId BIGINT = NULL, @AppUserId BIGINT)`. It returns `Status, Message`; `NULL` clears the override.
  - Its `Audit.ConfigLog` Description reads `<TerminalCode> · Scale running part · <OldPN or Default> -> <NewPN or Default>`, with `OldValue` / `NewValue` JSON `{ItemId:{Id,PartNumber,Description}}`.
  - Python `BlueRidge.Workorder.ScaleStation`:
    - `setRunningPart(terminalLocationId, itemId, appUserId)` returns `{Status, Message}`;
    - `getRunningPartOrEmpty(terminalLocationId, _token=None)` returns a dict of every `GetRunningPart` column (`None` / `0` / `""` when empty);
    - `listEligibleParts(terminalLocationId, _token=None)` returns a list.

- [ ] **Step 1: Write the failing tests:**
  - `[SetRun] set eligible part -> Status 1, attribute value, ConfigLog row`.
  - `[SetRun] clear -> attribute removed or NULL, Source Default`.
  - `[SetRun] refused: not eligible`.
  - `[SetRun] refused with another part's box open`.
  - `[SetRun] refused: not a terminal`.
  - `[SetRun] refused: missing AppUserId`.
  - `[SetRun] no-op (same part) refused`, matching house no-op behaviour.
- [ ] **Step 2: Run** `-Filter 0113`. Expected: FAIL.
- [ ] **Step 3: Implement** the proc. Mirror the `LocationAttribute` upsert in `R__Location_Terminal_SetClosureMethod.sql`, with every validation before `BEGIN TRANSACTION`. Write the Python wrapper, calling `Common.Util.requireAppUserId`.
- [ ] **Step 4: Run** `-Filter 0113`, then the full suite (count + 7).
- [ ] **Step 5: Commit** `feat(scale): audited per-terminal running-part override`.

### Task 5: The scale close uses the same rule

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/Assembly/code.py` (`resolvePlcCloseContext`)

**Interfaces:**
- Consumes: `BlueRidge.Workorder.ScaleStation.getRunningPartOrEmpty` (Task 4).
- Produces: for `closureMethod == "ByWeight"`, `resolvePlcCloseContext` returns `finishedGoodItemId` = `GetRunningPart.ItemId`, `containerId` = `OpenContainerId`, `pieceCount` = `PartsPerTray`. `Source == 'None'` returns `{"error": Message}`. ByVision is unchanged.

- [ ] **Step 1: Write the failing test** in `tools/test_scale_eprint_watcher.py`: load `Assembly/code.py` the same way, stub `ScaleStation.getRunningPartOrEmpty`, then:
  - `test_byweight_close_uses_running_part` (stub ItemId 222 gives `finishedGoodItemId == 222`);
  - `test_byweight_none_is_error` (`Source "None"` gives a dict with `error == Message`);
  - `test_byvision_path_unchanged` (the ScaleStation stub is never called).
- [ ] **Step 2: Run** the harness. Expected: FAIL.
- [ ] **Step 3: Implement** the ByWeight branch. Leave `_recommendedWithPackout` for ByVision.
- [ ] **Step 4: Run** the harness. Expected: PASS.
- [ ] **Step 5: Commit** `refactor(scale): ByWeight close resolves its part through ScaleStation_GetRunningPart`.

### Task 6: Screen reads: press log, shift tally, recent boxes

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_ScaleStation_GetPressLog.sql`, `R__Workorder_ScaleStation_GetShiftTally.sql`, `R__Workorder_ScaleStation_GetRecentBoxes.sql`
- Create NQs: `workorder/ScaleStation_GetPressLog` (`terminalLocationId`, `top`), `workorder/ScaleStation_GetShiftTally`, `workorder/ScaleStation_GetRecentBoxes` (`terminalLocationId`, `top`)
- Modify: `BlueRidge/Workorder/ScaleStation/code.py` (`getPressLog`, `getShiftTallyOrEmpty`, `getRecentBoxes`, each taking `_token`)
- Test: `sql/tests/0113_ScaleStation/050_PressLog.sql`, `060_ShiftTally.sql`, `070_RecentBoxes.sql`

**Interfaces:**
- Consumes: Task 1 columns; the JSON keys from Task 2.
- Produces: the columns listed in spec §7, exactly.
  - Press log filter:
    - `LocationId = @t`;
    - `SystemName LIKE N'PLC:%'`;
    - `ISJSON(RequestPayload) = 1`;
    - `JSON_VALUE(RequestPayload,'$.v') IS NOT NULL`;
    - `(ErrorCondition IS NULL OR ErrorCondition NOT LIKE N'ScaleFlags%')`.
  - `Outcome`: `Closed` when `LotId IS NOT NULL`, `Refused` when the verdict is not Ok, `Failed` otherwise.
  - Tally window comes from `Oee.ufn_ShiftIdForInstant(@TerminalLocationId, SYSUTCDATETIME())` `StartLocal` / `EndLocal`, converted Eastern to UTC. No row means zeros.

- [ ] **Step 1: Write the failing tests:**
  - `[PressLog] close row joins LOT, box, AIM, label status`.
  - `[PressLog] refusal row has Detail and no LOT`.
  - `[PressLog] skips non-JSON, Zebra and flags-warning rows`.
  - `[PressLog] newest first, @Top honoured`.
  - `[PressLog] LoggedAtEt is Eastern`.
  - `[Tally] counts trays/parts/boxes/refused under+over in window`.
  - `[Tally] rows outside the shift excluded`.
  - `[Tally] no covering shift returns zeros`.
  - `[RunPart] open box trays closed ignores refusals`: `GetRunningPart.OpenTraysClosed` = 3 after 3 closes + 2 refusals.
  - `[Boxes] completed boxes newest first with LabelStatus Sent/Failed`.
  - `[Boxes] open box not listed`.
- [ ] **Step 2: Run** `-Filter 0113`. Expected: FAIL.
- [ ] **Step 3: Implement** the three read procs and the Python wrappers. Each `OrEmpty` returns the full key shape.
- [ ] **Step 4: Run** `-Filter 0113`, then the full suite (count + 11).
- [ ] **Step 5: Commit** `feat(scale): press log, shift tally and recent boxes reads`.

### Task 7: Scale station views (new files)

**Files (all new, under `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/`). Sibling folders, never nested (`feedback_ignition_no_view_inside_view`):**
- `ScaleStationRunningPart/`, `ScaleStationOpenBox/`, `ScaleStationLastPress/`, `ScaleStationPressLog/`, `ScaleStationShiftTally/`, `ScaleStationRecentBoxes/`, `ScaleStationStrip/`, each with `view.json` + `resource.json` (scope G)
- `../Popups/ScaleStationPartPicker/` (`view.json` + `resource.json`)

**Interfaces:**
- Consumes: the Task 4 and 6 Python wrappers.
- Produces:
  - Every card view takes `params.terminalLocationId` (input) and `params.pressToken` (input, int), and keys its runScript bindings on `pressToken`.
  - The picker popup sends a page-scoped `scaleRunningPartChanged` message after a successful set.
  - `ScaleStationStrip` also takes `params.instancePath` and reads `<instancePath>/LastReceiveTime` and the device connection.

- [ ] **Step 1: Read** `ignition-context-pack/02_perspective_views.md`, `06_component_quirks.md`, `07_conventions_and_antipatterns.md`, and the `psc-pf-*` classes in the Core stylesheet. Use those classes; add no MPP stylesheet override.
- [ ] **Step 2: Author** each view to the matching mockup card:
  - the open box is a 16-cell tray strip (`TraysPerContainer` cells; closed / next / to fill);
  - last press shows a pill coloured by verdict (Ok `#1f8f5f`, Under `#b9771a`, Over `#c4472f`);
  - the part picker lists `listEligibleParts` and calls `setRunningPart(..., appUserId=BlueRidge.Common.Session.currentAppUserId(self.session))`, toasting the result.

  Pre-declare every bound custom prop with a full-shape default.
- [ ] **Step 3: Run** `.\scan.ps1`, then open each view on its own in a Dev session against terminal 106 (`MA2-6MAOP-AOUT`). Expected: no red Component Error; values match `EXEC Workorder.ScaleStation_GetRunningPart 106` etc.
- [ ] **Step 4: Commit** the new view folders `feat(ignition): scale station cards + part picker`, after checking `git diff --stat` for pickled live data (`feedback_designer_pickles_live_data`).

### Task 8: Wire the cards into Assembly Out (Designer) and remove Weigh & Close

**Files:**
- Modify (in **Designer**): `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json`

**Interfaces:**
- Consumes: the Task 7 views, and the `scalePressRecorded` / `scaleRunningPartChanged` messages.
- Produces:
  - `view.custom.pressToken` (int, default 0).
  - Root message handlers `scalePressRecorded` and `scaleRunningPartChanged` (page scope). Each one bumps `pressToken` when `payload.terminalLocationId == session.custom.terminal.terminalLocationId` (or the payload has none).

- [ ] **Step 1: In Designer, delete** `WeighCloseTrayButton`, the "Waiting for scale…" label, and `custom.scaleInstancePath` with its binding.
- [ ] **Step 2: In Designer, replace** the By Weight content of `WeightPane` with the Task 7 embeds, in the mockup's `MultiTray` layout, each passing `terminalLocationId` and `pressToken`. Hide `PartBanner` and `EmptyHint` when `session.custom.closureMethod = "ByWeight"`; the By Count / By Vision layouts are untouched.
- [ ] **Step 3: Add** the two handlers and `pressToken`. Save and run `scan.ps1`.
- [ ] **Step 4: Verify on Dev** with the office scale on `6C2_6MA_OilPan` → terminal 106:
  - an Under, an Over and a good press each update the last press card and the press log within 2 s, without Refresh;
  - the tally moves;
  - the good press shows in recent boxes with label status.

  Then switch the part with the picker. Expected: the `ConfigLog` row is present, and the next close mints the chosen part.
- [ ] **Step 5: Commit** the view (explicit path), after checking `git diff --stat` for pickled data.

### Task 9: Docs

**Files:**
- Modify: `MPP_MES_DATA_MODEL.md`: add `InterfaceLog` columns `LocationId` / `ItemId` / `LotId`, the `ScaleRunningItemId` terminal attribute, and a revision row.
- Modify: `docs/superpowers/specs/2026-10-19-assembly-out-scale-station-design.md`: set Status to "Built" with commit refs.
- Modify: `PROJECT_STATUS.md`: append one line; no journal.

- [ ] **Step 1: Write** the three edits. Don't edit the FDS (`feedback_fds_is_plan_not_state`).
- [ ] **Step 2: Commit** `docs: scale station built -- data model, spec status, project status`.
