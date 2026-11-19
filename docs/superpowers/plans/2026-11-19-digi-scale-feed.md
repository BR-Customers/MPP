# Digi One SP Scale Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Assembly Out By Weight station closes trays from a Digi One SP record (`(NET)15.5<UOM>LB<TWM>1<Part>TEST3`), with the scale deciding part and good, and an on-screen pick for a press whose part cannot be determined.

**Architecture:** New `PlcDeviceType` `ScaleStationDigi` routes `LastReceiveTime` changes to a new sibling watcher `BlueRidge.Workorder.ScaleDigiWatcher`. The EPrint watcher is not edited. Part switching reuses `Location.Terminal_SetScaleRunningPart`. A held press is a row in the new `Workorder.ScalePendingPress`, resolved by new status-row procs that the scale station screen calls.

**Tech Stack:** SQL Server 2022 (migrations + repeatable procs, `sql/tests` framework), Ignition 8.3 Jython (Core project library, NQs in Core), Perspective (MPP project), CPython unittest harness for watcher code.

**Spec:** `docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md`

## Global Constraints

- Branch `feature/digi-scale-feed` off `origin/main`, worktree `.claude/worktrees/digi-scale-feed`. Never commit to `main` / `jacques/working`; never touch production. One PR into `main`. The new procs cannot land apart from the table they read, so they ship together; say so in the PR body (CLAUDE.md SP rule 2 exception).
- Procs: `_TEMPLATE_stored_procedure.sql` shape, no `OUTPUT` params, every exit `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`; rejecting validations BEFORE `BEGIN TRANSACTION`; `RAISERROR` in CATCH.
- `NVARCHAR`, `DATETIME2(3)` stored UTC via `SYSUTCDATETIME()`, read procs convert with `AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'`; `BIGINT IDENTITY` PKs; status via code table FK.
- Seed strings ASCII only.
- Gateway-scope writes pass `BlueRidge.Common.Util.systemAppUserId()`; view-triggered writes pass `BlueRidge.Common.Session.currentAppUserId(self.session)`.
- Every new InterfaceLog warning `ErrorCondition` starts with `ScaleFlags` (`ScaleFlagsPartUnknown`, `ScaleFlagsMesMismatch`, `ScaleFlagsHeld`) so `ScaleStation_GetPressLog` excludes it.
- Payload version `"v": 2`.
- `EXPECTED_UOM = "lb"`; `_MAX_AGE_SEC` and `_claim` reused from `ScaleEPrintWatcher` (call, do not copy).
- Guards on gateway code: `except (Exception, java.lang.Exception)`.

## Review Focus

1. **A press arriving while one is held** must be refused with the "A tray is waiting for its part" toast, never silently dropped, and never held twice (unique index). Task 2 (SQL second Hold refused) + Task 4 (`test_pending_blocks_press`).
2. **Two screens tapping the same held press** must close one tray only. Task 2 (second Claim refused) + Task 5 (`test_pick_claim_refused_closes_nothing`).
3. **A pick whose close fails** must leave the press Pending so the operator can try again. Task 5 (`test_pick_close_failure_releases`).
4. **A deprecated item whose PartNumber matches the scale code** must be treated as no match. Task 4 (`test_deprecated_item_is_no_match`).
5. **The EPrint path is unchanged**: `tools/test_scale_eprint_watcher.py` passes untouched and `dispatchMessage` still routes `ScaleStationEPrint`. Task 6 (`test_routes_eprint_unchanged`).

---

### Task 1: Migration 0134: device type, status code table, pending-press table

**Files:**
- Create: `sql/migrations/versioned/0134_scale_digi_and_pending_press.sql`
- Modify: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` (table + column descriptions; bump its trailer count)
- Test: `sql/tests/0134_ScaleDigi/010_schema.sql`

**Interfaces:**
- Produces: `Location.PlcDeviceType` row `Code = N'ScaleStationDigi'`, `Name = N'Scale Station (Digi)'`, `ClosureMethodCode = N'ByWeight'`. `Workorder.ScalePendingPressStatus (Id BIGINT IDENTITY PK, Code NVARCHAR(20) UNIQUE, Name NVARCHAR(50))` seeded `Pending`, `Closed`, `Discarded` (in that order). `Workorder.ScalePendingPress` columns per spec §5, `StatusId` FK, filtered unique index `UX_ScalePendingPress_Terminal_Pending ON (TerminalLocationId) WHERE StatusId = 1` (guard: the migration THROWs if `Pending` is not Id 1). `Audit.LogEventType` rows `ScalePressHeld`, `ScalePressPicked`, `ScalePressDiscarded` (check the column set of existing rows first). `dbo.SchemaVersion` row `0134_scale_digi_and_pending_press`.

- [ ] **Step 1:** Write `010_schema.sql` asserting: the device type row and its closure method; three status codes with `Pending` = Id 1; the table exists; inserting two `Pending` rows for one terminal fails (catch error 2601 → assert); one `Pending` + one `Closed` for one terminal succeeds; the SchemaVersion row. Clean up its rows.
- [ ] **Step 2:** Run `sql/tests/Run-Tests.ps1` against a throwaway DB built by `Reset-DevDatabase.ps1` (name `MPP_MES_Test_Digi`), BEFORE adding the migration; record the baseline assertion count and confirm 010 fails.
- [ ] **Step 3:** Write the migration (idempotent `IF NOT EXISTS` blocks, 0105 pattern, post-checks that THROW).
- [ ] **Step 4:** Rebuild the throwaway DB, run the suite; 010 passes, nothing else changes.
- [ ] **Step 5:** Commit `feat(sql): 0134 ScaleStationDigi device type + Workorder.ScalePendingPress`.

### Task 2: Pending-press procs + NQs

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_ScalePendingPress_Hold.sql`, `_GetForTerminal.sql`, `_Claim.sql`, `_Release.sql`, `_Complete.sql`, `_Discard.sql`
- Create: NQs `ignition/projects/Core/ignition/named-query/workorder/ScalePendingPress_<Name>/{query.sql,resource.json}` (all `type: Query`, the `ScaleStation_ListEligibleParts` resource as template; `sqlType` 3 for ids, 4 for decimals? use the type an existing decimal param uses, 7 for strings)
- Test: `sql/tests/0134_ScaleDigi/020_pending_press.sql`

**Interfaces (all status-row unless noted):**
- `Workorder.ScalePendingPress_Hold(@TerminalLocationId BIGINT, @NetWeight DECIMAL(10,3), @Uom NVARCHAR(10), @ScalePartCode NVARCHAR(50), @AppUserId BIGINT)` → `Status, Message, NewId`. Refuses a missing param, a non-terminal (LTD 7), and an existing Pending row at the terminal ("A tray is already waiting for its part at this scale."). Unique-index collision in the INSERT (race) → CATCH returns Status 0 with the same message. Audit `ScalePressHeld`.
- `Workorder.ScalePendingPress_GetForTerminal(@TerminalLocationId BIGINT)` read → 0 or 1 row: `Id, TerminalLocationId, ReceivedAtEt, NetWeight, Uom, ScalePartCode`. Pending only.
- `Workorder.ScalePendingPress_Claim(@Id BIGINT, @AppUserId BIGINT)` → `Status, Message`. `UPDATE ... SET StatusId = Closed, ResolvedAt, ResolvedByAppUserId WHERE Id = @Id AND StatusId = Pending`; 0 rows → Status 0 "This tray has already been dealt with."
- `Workorder.ScalePendingPress_Release(@Id BIGINT, @AppUserId BIGINT)` → `Status, Message`. Closed-with-no-`FinishedGoodLotId` → Pending, clears Resolved*. Anything else refused.
- `Workorder.ScalePendingPress_Complete(@Id BIGINT, @ItemId BIGINT, @FinishedGoodLotId BIGINT NULL, @AppUserId BIGINT)` → `Status, Message`. Stamps `ResolvedItemId`, `FinishedGoodLotId` on a Closed row. Audit `ScalePressPicked` (`<terminal> · Scale held press · Picked <PartNumber> (<net> lb)`).
- `Workorder.ScalePendingPress_Discard(@Id BIGINT, @AppUserId BIGINT)` → `Status, Message`. Pending → Discarded. Audit `ScalePressDiscarded`.
- Audit rows through `Audit.Audit_LogOperation` with the SetScaleRunningPart call shape (`R__Location_Terminal_SetScaleRunningPart.sql:167`), Description via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity`.

- [ ] **Step 1:** Write `020_pending_press.sql` (fixture: the `TST-SS-AOUT` terminal from `sql/tests/0113_ScaleStation`; check the file that creates it runs earlier, else build an equivalent). Assert: Hold → 1 and NewId; second Hold → 0, message contains `already waiting`; GetForTerminal returns 1 row with the net and code; Claim → 1; second Claim → 0; Release → 1 and GetForTerminal shows it again; Claim + Complete → 1, row has ItemId + LotId; Release after Complete → 0; Hold on a fresh press then Discard → 1; Discard again → 0; audit rows for Held / Picked / Discarded exist.
- [ ] **Step 2:** Run; expect failures (procs missing).
- [ ] **Step 3:** Write the six procs + six NQs.
- [ ] **Step 4:** Rebuild the throwaway DB, run the full suite; record the count (baseline + Task 1 + Task 2), 0 failures.
- [ ] **Step 5:** Commit `feat(sql): Workorder.ScalePendingPress_* procs + NQs`.

### Task 3: Digi record parser

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/ScaleDigiWatcher/{code.py,resource.json}` (resource.json copied from ScaleEPrintWatcher's, adjusted)
- Test: `tools/test_scale_digi_watcher.py` (harness: copy `_stubModules` / `_load` pattern from `tools/test_scale_eprint_watcher.py`)

**Interfaces:**
- `decodeBytes(raw) -> str or None`: list / Java byte[] of signed or unsigned ints → ASCII text (`chr(b & 0xFF)`); None stays None.
- `parse(message) -> {"ok": True, "net": float, "netText": str, "uom": str, "twm": int, "part": str}` or `{"ok": False, "reason": str}`. Grammar after stripping CR/LF/whitespace both ends: `^\(NET\)\s*(-?\d+(?:\.\d+)?)\s*<UOM>\s*([A-Za-z]+)\s*<TWM>\s*(\d)\s*<Part>(.*)$` (DOTALL off; part = group stripped). Count of `(NET)` occurrences must be exactly 1.
- `digiRecord(net, part, twm=1, uom="LB") -> str`: `"\n\n(NET)%s<UOM>%s<TWM>%d<Part>%s\r"` with net formatted `%.1f` (the record as the driver delivers it), for the simulator.

- [ ] **Step 1:** Tests in `ParseTests`: `test_bench_record` (`"(NET)15.5<UOM>LB<TWM>1<Part>TEST3"` → net 15.5, uom `LB`, twm 1, part `TEST3`); `test_leading_lf_from_previous_record` (`"\n\n" + rec + "\r"`); `test_fragments_reassembled` (join `["(N","ET)1","5.5<U","OM>LB<","TWM>1<Pa","rt>TEST3","\r"]` → same result); `test_part_with_spaces_and_dashes` (`12270-6NA -A000` kept exactly); `test_two_records_refused` (reason mentions `2`); `test_no_record_refused`; `test_twm_zero_parsed` (twm 0, ok True: TWM is judged by the watcher); `test_empty_part` (part `""`, ok True); `test_decode_signed_bytes` (`[40,78,69,84,41,-1]` → ends with `\xff`), `test_decode_none`; `test_digi_record_roundtrip` (`parse(digiRecord(15.5,"TEST3"))`).
- [ ] **Step 2:** `python tools/test_scale_digi_watcher.py` → fails (module missing).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run → pass; `python tools/test_scale_eprint_watcher.py` still passes.
- [ ] **Step 5:** Commit `feat(scale): Digi One SP record parser`.

### Task 4: Watcher press flow

**Files:**
- Modify: `.../ScaleDigiWatcher/code.py`
- Test: `tools/test_scale_digi_watcher.py` (`HandleMessageTests`, Recorder stub extended with `getRunningPartOrEmpty`, `getByPartNumber`, `setRunningPart`, `holdPress`, `getPendingPress`)

**Interfaces:**
- Consumes: `ScaleEPrintWatcher._claim`, `._num`, `._encode`, `.EXPECTED_UOM`; `PlcWatcher.logInterface / notifyAlarm / broadcastPageMessage`; `ScaleStation.getRunningPartOrEmpty`, `ScaleStation.setRunningPart`; `Parts.Item` lookup by part number (find the existing Python wrapper of `parts/Item_GetByPartNumber`, else call `BlueRidge.Common.Db.execOne("parts/Item_GetByPartNumber", {"partNumber": code})`); `Assembly.resolvePlcCloseContext`, `Assembly.plcCompleteTray`; `ContainerConfig.judgeWeight(itemId, "ByWeight", net)`; `ScaleStation.getPendingPressOrEmpty` / `holdPress` (Task 5 defines them; stub here).
- Produces: `onReceive(instancePath, terminalLocationId, stamp, initialChange=False)`; `handleMessage(instancePath, terminalLocationId, message) -> {"Status", "Message", "ContainerId"}` (also `"Held": True` when held); `_readMessage(instancePath)` reads `MessageBytes` via `system.opc.readValue` using `MessageBytes.OpcServer` / `.OpcItemPath`, then `decodeBytes`; `closeAs(device, terminalLocationId, body, itemId)` shared with Task 5.

Order of checks is spec §6 steps 1-8, exactly. Refusal titles: `Scale weighment not read`, `Scale weighment not understood`, `Scale is in the wrong units`, `Scale did not pass this tray`, `Tray waiting for its part`, `Tray not closed`.

- [ ] **Step 1:** Tests: `test_match_same_part_closes` (no setRunningPart call, close called, payload `partSource == "Scale"`, `v == 2`); `test_match_other_part_switches_then_closes` (setRunningPart(term, item, 1) then close); `test_switch_refused_closes_nothing` (setRunningPart Status 0 → Status 0, its message toasted, no close); `test_unknown_code_with_open_box_closes_with_warning` (warning row `ScaleFlagsPartUnknown`, `partSource == "Running"`); `test_unknown_code_with_override_closes_with_warning`; `test_unknown_code_default_holds` (holdPress called with net, uom, code, SYS id; no close; toast level `warning`; log row `ScaleFlagsHeld`; result `Held`); `test_deprecated_item_is_no_match`; `test_pending_blocks_press` (getPendingPress returns a row → refused `Tray waiting for its part`, no hold, no close); `test_twm_zero_refused`; `test_wrong_units_refused`; `test_mes_mismatch_logs_warning_and_closes` (judge Under → row `ScaleFlagsMesMismatch`, close still called, payload `mesVerdict == "Under"`, `agree is False`); `test_unreadable_message_refused` (None); `test_broadcast_on_every_outcome`.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run both harnesses → pass.
- [ ] **Step 5:** Commit `feat(scale): Digi watcher press flow (scale decides part + good)`.

### Task 5: Held-press pick and discard; ScaleStation wrappers

**Files:**
- Modify: `.../ScaleDigiWatcher/code.py`, `.../BlueRidge/Workorder/ScaleStation/code.py`
- Test: `tools/test_scale_digi_watcher.py` (`PickTests`), `tools/test_scale_eprint_watcher.py` StationHelperTests if `scaleInstancePath` changes break it

**Interfaces:**
- `ScaleStation.getPendingPressOrEmpty(terminalLocationId, _token=None) -> dict` with keys `Id, ReceivedAtEt, NetWeight, Uom, ScalePartCode` (shape `{"Id": None, ...}` when none).
- `ScaleStation.holdPress(terminalLocationId, net, uom, code, appUserId) -> {Status, Message, NewId}`.
- `ScaleDigiWatcher.pickPart(pendingId, terminalLocationId, itemId, appUserId) -> {Status, Message, ContainerId}`: Claim → (if running part ≠ item) setRunningPart → plcCompleteTray → Complete; on a refusal after Claim, Release and return it. Logs one InterfaceLog `ByWeight tray close` row with `partSource = "Picked"` and the held net. Broadcasts `scalePressRecorded`.
- `ScaleDigiWatcher.discardPress(pendingId, terminalLocationId, appUserId) -> {Status, Message}`.
- `ScaleStation.applyPendingPick(session, terminalLocationId, pendingId, itemId)` / `applyPendingDiscard(session, terminalLocationId, pendingId)`: view entry points; toast via `BlueRidge.Common.Ui.notifyResult`.
- `ScaleStation.pendingPartButtons(terminalLocationId, _token=None) -> list` of `{"itemId", "label"}` from `listEligibleParts`.
- `ScaleStation.scaleInstancePath` returns the instance of type `ScaleStationEPrint` OR `ScaleStationDigi`.
- `ScaleStation.shouldRefresh`: unchanged; the pick broadcasts `scalePressRecorded`.

- [ ] **Step 1:** Tests: `test_pick_closes_and_completes` (Claim, close, Complete with lot id; payload `partSource == "Picked"`); `test_pick_switches_part_when_different`; `test_pick_claim_refused_closes_nothing`; `test_pick_close_failure_releases`; `test_pick_switch_refused_releases`; `test_discard`; `test_scale_instance_path_finds_digi`.
- [ ] **Step 2:** Run → fail. **Step 3:** Implement. **Step 4:** Run both harnesses → pass.
- [ ] **Step 5:** Commit `feat(scale): held press pick / discard`.

### Task 6: Routing, simulator, tag-change path

**Files:**
- Modify: `.../BlueRidge/Workorder/PlcWatcher/code.py` (`dispatchMessage`: `ScaleStationEPrint` → EPrint watcher as now; `ScaleStationDigi` → `ScaleDigiWatcher.onReceive`; else the existing warning)
- Modify: `.../BlueRidge/Sim/code.py` (`fireScaleDigi(terminalLocationId, net, part, twm=1)`, pattern of `fireScaleEPrint`, record from `ScaleDigiWatcher.digiRecord`)
- Modify: `ignition/projects/MPP/ignition/tag-change/ScaleEPrintMessage/resource.json` (add the Dev Digi instance's `LastReceiveTime` path, Task 8 names it)
- Test: `tools/test_scale_digi_watcher.py` (`DispatchTests`, loading PlcWatcher with stubs)

- [ ] **Step 1:** Tests `test_routes_digi`, `test_routes_eprint_unchanged`, `test_other_type_ignored`. **Step 2:** fail. **Step 3:** implement. **Step 4:** pass.
- [ ] **Step 5:** Commit `feat(scale): route ScaleStationDigi; Dev simulator`.

### Task 7: Held-press banner on the scale station screen

Use the `ignition-perspective` skill. Read `ignition-context-pack/07_conventions_and_antipatterns.md` first.

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/ScaleStationPendingPress/{view.json,resource.json}` (params `terminalLocationId`, `pressToken`; custom `pending` bound to `getPendingPressOrEmpty`, full-shape default; `buttons` bound to `pendingPartButtons`; root `meta.visible` when `pending.Id` not null; text "Tray waiting: <net> lb. The scale said '<code>', which is not a part here. Choose the part:"; a flex-repeater of part buttons calling `applyPendingPick`; a Discard button calling `applyPendingDiscard`)
- Create: `.../Components/PlantFloor/ScaleStationPendingButton/{view.json,resource.json}` (one button; the repeater instance)
- Modify: `.../Components/PlantFloor/ScaleStation/view.json` (embed the banner first in the column, passing `terminalLocationId` and `pressToken`). File edit only if no Designer has it open; ask Jacques before editing.

- [ ] **Step 1:** Author views; `check_view.py` clean; `.\scan.ps1`.
- [ ] **Step 2:** Browser: `/dev/scale-station/<terminal>` with a held press from the simulator shows the banner; tapping a part closes the tray and the banner disappears; Discard clears it. Screenshot.
- [ ] **Step 3:** Commit `feat(ui): scale station held-press banner`.

### Task 8: Dev end to end on `digiTest`

- [ ] **Step 1:** Ask Jacques which Dev terminal to bind and whether the `MPP_MES_Dev` changes (0134 + procs applied additively) are OK, per `project_mpp_dev_db_testing_env`.
- [ ] **Step 2:** Apply 0134 + repeatables to Dev; `.\scan.ps1`.
- [ ] **Step 3:** UDT instance `[MPP]PlcDevices/digiTest` of `ScaleStationEPrint`, `Device = digiTest`, `BasePath = ""` (check the driver folder name in the OPC browser first); `TerminalPlcDevice` row type `ScaleStationDigi`; tag-change path added; terminal `CurrentClosureMethod = ByWeight`.
- [ ] **Step 4:** With Tom: a press on a part code that matches a Dev part → tray closes; `TEST3` → held, pick → closes; a second press while held → refused. Evidence: InterfaceLog rows, `ScalePendingPress` rows, screenshot.
- [ ] **Step 5:** Record in `notes/2026-11-19_digi-one-sp-scale-capture.md` §6 and `PROJECT_STATUS.md` (append-only).

### Task 9: Docs, suite, PR

- [ ] Data Model doc (`MPP_MES_DATA_MODEL.md`): the new table, code table, device type; revision row.
- [ ] Full `Run-Tests.ps1` on a fresh throwaway build: assertion count vs the Task 1 baseline, 0 failures.
- [ ] Both Python harnesses pass.
- [ ] `gh pr create --base main`: problem, what changed, procs new (none changed), result sets unchanged for existing procs, test counts before/after, why procs + migration ship together.

### Task 10: Prod release package

Follow `prod-release-context-pack/` (read 01, 02, 04, 05, 06, 07).

- [ ] Pre-flight gate for 0134 (`ScaleStationDigi` absent or identical; `ScalePendingPress` absent).
- [ ] ProdSim at prod's state (latest prod migration per `PROJECT_STATUS.md`), Preview + Rehearse clean, real Execute on a second sim. Note the fingerprint.
- [ ] Scoped exports from git via `tools/Build-ChangeExport.ps1` (Core: ScaleDigiWatcher, ScaleStation, PlcWatcher, Sim, six NQs; MPP: the two new views, ScaleStation view, tag-change resource) + rollback pair.
- [ ] Runbook `notes/2026-11-19_prod-release-runbook-digi-scale-feed.md`, published as an Artifact, including per-head commissioning (spec §9).
