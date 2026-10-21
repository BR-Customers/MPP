# Super-lot piece 6 — Visibility — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make everything pieces 1-5 record about a super-lot visible off the super-lot page: on the LOT's own history, on LOT Detail, in genealogy and trace, at the terminals, on the dashboard and in a per-super-lot report.

**Architecture:** One migration (`0114`) adds two columns to `Audit.LogEventType` (an exclude flag and a timeline label) and six per-LOT event codes. A silent helper writes per-LOT rows from every super-lot writer; one inline function defines which super-lots a LOT belongs to (tray LOTs fold to their container, point in time). `Lot_GetAttributeHistory` gains the audit stream. New reads feed new and changed views; one Reporting Module report. No quality rule changes.

**Tech Stack:** SQL Server 2022 (T-SQL procs, inline TVFs, repeatable migrations), the in-repo T-SQL test framework (`sql/tests/Run-Tests.ps1`), Ignition 8.3 Perspective (file-based views, Core named queries, Jython), Ignition Reporting Module (`data.bin` via the global `ignition-reporting` skill).

**Spec:** `docs/superpowers/specs/2026-10-12-controlled-run-visibility-design.md` (approved 2026-10-21; decisions in section 6, builder-check answers in 6c). Mocks: `notes/2026-10-21_super-lot-piece-6-screen-mocks.html` (approved as drawn). Read both, and `CLAUDE.md`, before Task 1.

## Global Constraints

- Branch `claude/super-lot-piece-6` (off `jacques/controlled-run-super-lot`), merged back into it. Nothing deploys until all six pieces are in. Work in this worktree; never `git checkout` in the shared main checkout.
- FDS-11-011: no `OUTPUT` params; one result set; read procs return no status row, empty set = not found. Mutation procs: every rejecting validation before `BEGIN TRANSACTION`, CATCH the only ROLLBACK site, `RAISERROR` not `THROW` in CATCH, exits `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`. A status-row proc never `EXEC`s another status-row proc; silent `*Internal` helpers and `Audit.Audit_Log*` emit nothing and never roll back.
- `EXEC` arguments are literals or variables only, in tests too.
- `NVARCHAR`, `DATETIME2(3)`, `BIGINT` ids. Stored UTC; every read that displays a time converts with `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- `.sql` string literals ASCII-only; middle dot via `Audit.ufn_MidDot()`, arrow `->` in history Detail text.
- Audit Description `<SUBJECT> · <CATEGORY> · <ACTION>` through `Audit.ufn_TruncateActivity`; JSON Old/New values carry resolved-name sub-objects `{Id, Code, Name}`. Entity `Lot` routes to `Lots.LotEventLog`.
- No rule in Python or a view expression. Python entity functions are thin wrappers; views read SQL's answers (`CanClose`, kind labels, states).
- Every mutation's `@AppUserId` comes from its caller (`BlueRidge.Common.Session.currentAppUserId(self.session)` in views).
- Named queries in **Core** only; status-row procs NQ `type: "Query"`; ids `sqlType: 3`, strings `sqlType: 7`. A list argument to `runScript` arrives as `QualifiedValue[]` and throws: pass id lists as one comma-separated string.
- Views: every bound `view.custom.*` pre-declared with a fully shaped default; binding sources return the shaped empty object (`...OrEmpty`), never `None`. New views are new sibling folders (`view.json` + `resource.json`), never nested. Designer-saved views (`LotDetail`, `SupervisorDashboard`, `GenealogyViewer`, `GlobalTrace`, `Views/Reports`) are edited by inserting text, never re-serialised; generated `ControlledRun*` views may be edited as parsed JSON. No drag-and-drop.
- The FDS is not edited. `MPP_MES_DATA_MODEL.md`, `PROJECT_STATUS.md` and the spec's build notes are.
- Tests run on a private database only: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CRTest [-Filter ...]` (it DROPs its target; never `MPP_MES_Dev`). Baseline before this piece: **5,024 assertions, 0 failed**. Exit 1 with 0 failures means a file threw: compare the assertion count.
- Stage explicit paths; no `git add -A/-u`; no `Co-Authored-By` trailer.
- **No backfill** of per-LOT rows for super-lots already on Dev.

## Review Focus

1. **A LOT that was never in a super-lot.** Every new read returns an empty set, every changed view renders with no Component Error (the empty-shape case). Pinned in Tasks 5 and 11-14 (`never in a super-lot` assertions and the gateway walk).
2. **A tray moved into a container by a repack.** Moved in after the container's membership ended: no rows, not listed. Moved in while the membership was open: listed on the Super-lots tab, but no back-dated Joined row. Pinned in Task 2.
3. **The same LOT in several super-lots over time, including re-joining a super-lot after removal.** One Super-lots row per membership, newest first. Pinned in Task 5.
4. **An audit event type added later with no flag.** It shows on the History tab with kind `Event`. Pinned in Task 4.
5. **A CRT LOT in no open super-lot** (tagged on LOT Detail, or its super-lot closed). The refusal message is exactly today's text, with no `(super-lot )` fragment. Pinned in Task 8.

---

## File structure

| Path | Responsibility |
|---|---|
| `sql/migrations/versioned/0114_super_lot_visibility.sql` (create) | `LogEventType.RepeatsLotTimeline`, `.LotTimelineKind`; six event codes; flag + label seeding |
| `R__Quality_ufn_zz_ControlledRunMembershipsForLot.sql` (create) | Which memberships a LOT has, tray -> container point in time |
| `R__Quality_ufn_OpenControlledRunForLot.sql` (create) | The open super-lot of a LOT (tray folded), for refusal text and the chip |
| `R__Quality_ControlledRun_LogMemberLotEventsInternal.sql` (create) | Silent helper: one `Lot` audit row per LOT behind each member |
| `R__Quality_ufn_ControlledRunCloseCheck.sql` (create) | `CanClose` + reason, shared by `_Get` and `_Close` |
| Writers (modify): `ControlledRun_ApplyMembersInternal`, `_RemoveMember`, `_Close`, `_Cancel`, `_Release`, `ControlledRunResult_Record`, `_Void`, `ControlledRunDeviation_Raise` | Call the helper |
| `R__Lots_Lot_GetAttributeHistory.sql` (modify, v1.5) | Stream 11: the LOT audit log, unflagged types only |
| Reads (create): `ControlledRun_ListByLot`, `_ListMarkers`, `_ListHistory`, `_GetOpenSummary`, `_ReportMembers`, `_ReportOutcomes` | LOT Detail tab, trace markers, page History, dashboard tile, report |
| Reads (modify): `ControlledRun_Get`, `_GetOpenByMember`, `_ListMembers`, `_ListMemberResults`; trace `Container_GetTraceDetail`, `SerializedPart_GetTraceDetail`, `GlobalTrace_Resolve`, `Container_ListShipped`, `Quality.Hold_ListAssociatedContainers` | CanClose, fold reuse, WasCompleteAtJoin, AppliedReturnQty, scrapped serials + repack |
| Refusals (modify): `Lot_MoveTo`, `Lot_MoveToValidated`, `Lot_Split`, `Lot_Merge`, `Assembly_ScanIn`, `MachiningIn_RecordPick`, `MachiningOut_Mint` | Run number in the CRT message |
| Timing (modify): `ControlledRunResult_Record`, `ControlledRun_Release` | Re-check under the lock |
| `sql/tests/0114_SuperLotVisibility/010..120_*.sql` (create) | Tests |
| Core NQs `quality/ControlledRun_ListByLot`, `_ListMarkers`, `_ListHistory`, `_GetOpenSummary`; `BlueRidge.Quality.ControlledRun` (modify) | Ignition access |
| Views (Tasks 11-14), report `Super-lot` (Task 15) | Screens and PDF |

---

### Task 1: Migration 0114 — timeline flag, labels, per-LOT event codes

**Files:**
- Create: `sql/migrations/versioned/0114_super_lot_visibility.sql`
- Create: `sql/tests/0114_SuperLotVisibility/010_schema.sql`
- Modify: every `LogEventType` count pin the full suite trips (find with `Grep "LogEventType" sql/tests`)

**Interfaces:**
- Produces: `Audit.LogEventType.RepeatsLotTimeline BIT NOT NULL DEFAULT 0`, `Audit.LogEventType.LotTimelineKind NVARCHAR(20) NULL`. Event codes (entity `Lot`): `ControlledRunLotJoined`, `ControlledRunLotLeft`, `ControlledRunLotResult`, `ControlledRunLotResultVoided`, `ControlledRunLotDeviation`, `ControlledRunLotReleased`.

- [ ] **Step 1: Inventory.** List every `@LogEventTypeCode` written with `@LogEntityTypeCode = N'Lot'` across `sql/migrations/repeatable` (named and positional `EXEC Audit.Audit_LogOperation` calls; also `Audit_LogFailure` does not write `LotEventLog`, skip it). For each, decide `RepeatsLotTimeline` = 1 when `Lot_GetAttributeHistory` already draws the same fact from a record table (expected at least `LotCreated`, `LotMoved`, `LotStatusChanged`, `LotUpdated`, `DieCastPieceContributed`; die-cast open/release and label-print codes if their record table is a stream), and a `LotTimelineKind` label: `CRT` for `CrtActivated`/`CrtCleared`/`MissedCrtInspect`, `Vendor return` for `VendorReturn*`, `Rework` for `LotRework*` and container-rework codes written against a LOT, `Super-lot` for the six new codes, `Event` left NULL for the rest. Write the table into the migration header comment.
- [ ] **Step 2: Write the failing test** `010_schema.sql`: both columns exist with the stated types/default; the six codes exist with `LotTimelineKind = N'Super-lot'`; every code in the Step 1 "repeats" list has the flag set; `CrtActivated` has kind `CRT` and flag 0.
- [ ] **Step 3: Run** `-Filter 0114_SuperLotVisibility` → FAIL (columns missing).
- [ ] **Step 4: Write the migration**, shaped like `0112_rework_and_vendor_return.sql` (idempotent guards, extended properties, the `@Base + ROW_NUMBER()` LogEventType insert, flag/label UPDATEs by `Code`, post-condition check, SchemaVersion row with "Do NOT deploy alone.").
- [ ] **Step 5: Run the filter → PASS; full suite → only count pins fail; update them; re-run → 0 failures, count = 5,024 + new.**
- [ ] **Step 6: Commit** — `feat(audit): super-lot piece 6 schema -- LotEventLog timeline flag and labels, per-LOT super-lot codes (migration 0114)`.

---

### Task 2: Membership fold and the per-LOT event helper

**Files:**
- Create: `R__Quality_ufn_zz_ControlledRunMembershipsForLot.sql`, `R__Quality_ufn_OpenControlledRunForLot.sql`, `R__Quality_ControlledRun_LogMemberLotEventsInternal.sql`
- Modify: `R__Quality_ControlledRun_GetOpenByMember.sql` (v1.1: LOT path reads `ufn_OpenControlledRunForLot`; output unchanged)
- Create: `sql/tests/0114_SuperLotVisibility/020_fold_and_helper.sql`

**Interfaces:**
- Produces:
  - `Quality.ufn_ControlledRunMembershipsForLot(@LotId BIGINT)` inline TVF → `(ControlledRunMemberId, ControlledRunId, RunNumber, ViaContainerId BIGINT NULL, AddedAt, EndedAt)` (UTC). A row when `m.LotId = @LotId`, or when `m.ContainerId` is a container that held the LOT as a tray (`Lots.ContainerTray.FinishedGoodLotId = @LotId`) **while the membership was open**: `COALESCE(t.ClosedAt, m.AddedAt) <= COALESCE(m.EndedAt, '9999-12-31')`.
  - `Quality.ufn_OpenControlledRunForLot(@LotId BIGINT)` inline TVF → 0/1 row `(ControlledRunId, RunNumber)`: open membership of the LOT, or of its current container.
  - `Quality.ControlledRun_LogMemberLotEventsInternal @MemberIdsJson NVARCHAR(MAX), @LogEventTypeCode NVARCHAR(50), @ActionText NVARCHAR(400), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL` — silent. `@MemberIdsJson` = JSON array of `ControlledRunMember.Id`. For each member: a LOT member → that LOT; a container member → the tray LOTs **in the container now** (`ContainerTray.FinishedGoodLotId`). One `Audit_LogOperation` per LOT, entity `Lot`, Description `<LotName> · Super-lot <RunNumber> · <ActionText>`, prefixed `Container <ContainerName> · ` inside ActionText's place for container members (`<LotName> · Super-lot CR000014 · Container 20031 · Result recorded · Scrap 3 (Porosity)`); NewValue JSON `{Lot:{Id,Code,Name}, ControlledRun:{Id,Code,Name}, Container:{...}|null}`. Cursor loop like `ApplyMembersInternal`'s.

- [ ] **Step 1: Write the failing tests** (`TEST-SLV-%` LOTs; fixture and teardown copied from `0112_ReworkReturn/070_superlot_return.sql`, plus `Lots.LotEventLog` rows for test LOTs):
  - `[Fold] LOT member listed`; `[Fold] never in a super-lot: empty`.
  - `[Fold] tray in container at join: listed via container`.
  - `[Fold] tray moved in (ClosedAt) after the membership ended: not listed`.
  - `[Fold] tray moved in while the membership was open: listed`.
  - `[Open] tray LOT resolves its container's open run`; `[Open] ended membership: empty`.
  - `[Helper] LOT member: one row, Description contains 'Super-lot CR'`; `[Helper] container member with 2 trays: 2 rows, each names the container`. (That it emits no result set is proven in Task 3: every writer that calls it is captured by INSERT-EXEC in its tests.)
  - `[GetOpenByMember] unchanged output for LOT, tray LOT and container` (same captures as `0109_ControlledRun/050_reads.sql`).
- [ ] **Step 2: Run** filter → FAIL. **Step 3: Implement.** **Step 4: Run** filter and `-Filter 0109_ControlledRun` → PASS.
- [ ] **Step 5: Commit** — `feat(quality): super-lot piece 6 -- membership fold and per-LOT event helper`.

---

### Task 3: Every super-lot event lands on the LOT

**Files:**
- Modify (version bump + change-log line each): `R__Quality_ControlledRun_ApplyMembersInternal.sql`, `_RemoveMember.sql`, `_Close.sql`, `_Cancel.sql`, `_Release.sql`, `R__Quality_ControlledRunResult_Record.sql`, `_Void.sql`, `R__Quality_ControlledRunDeviation_Raise.sql`
- Create: `sql/tests/0114_SuperLotVisibility/030_lot_events.sql`

**Interfaces:**
- Consumes: Task 2 helper; Task 1 codes.
- Produces (ActionText per writer; code in brackets):
  - Apply: `Joined (<JoinMethod.Name>)` [`ControlledRunLotJoined`] for **every** member it inserts, tagged or not; existing `CrtActivated` rows unchanged.
  - RemoveMember: `Left (removed: <remarks>)`; Close: `Left (super-lot closed)`; Cancel: `Left (super-lot cancelled)` [`ControlledRunLotLeft`] — Close/Cancel only for members whose `EndedAt` they set.
  - Result_Record: `Result recorded · <Disposition.Name> <qty>[ (<Defect.Name>)]` [`ControlledRunLotResult`]; Void: `Result voided · <Disposition.Name> <qty> (<remarks>)` [`ControlledRunLotResultVoided`].
  - Deviation_Raise: `Deviation <DV> raised` [`ControlledRunLotDeviation`] for every member with `EndedAt IS NULL` at signing.
  - Release: `Released · signed <Initials>[ · Deviation <DV>[, <DV>]]` [`ControlledRunLotReleased`] for each released member (deviation numbers = the run's deviations raised while the member was open).

- [ ] **Step 1: Write the failing tests**, one per writer, each asserting the count of new `LotEventLog` rows by code for the test LOT(s) and the Description fragment: `[Events] join by Open (selected)`, `[Events] join by AddMembers (scanned in)`, `[Events] join by sync (auto-joined) writes Joined`, `[Events] already-tagged LOT joining gets Joined and no CrtActivated`, `[Events] container join: each tray gets Joined`, `[Events] removed`, `[Events] closed: only open members`, `[Events] cancelled`, `[Events] result scrap on LOT`, `[Events] result on container names the container on each tray`, `[Events] result voided`, `[Events] deviation: open members only, released-then-removed member gets none`, `[Events] release names signer and deviation`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** each call inside the writer's existing transaction, after its own rows. **Step 4: Run** filter + `-Filter 0109_ControlledRun` + `-Filter 0111` + `-Filter 0112` → PASS (existing tests that count `LotEventLog` rows by LOT may need their expected count raised; change only those, and say which in the commit body).
- [ ] **Step 5: Commit** — `feat(quality): super-lot piece 6 -- every super-lot event written onto its LOTs`.

---

### Task 4: LOT History shows all history

**Files:**
- Modify: `R__Lots_Lot_GetAttributeHistory.sql` (v1.5; replace the "audit stream intentionally NOT unioned" paragraph with the 2026-10-21 reversal and why)
- Create: `sql/tests/0114_SuperLotVisibility/040_history.sql`

**Interfaces:**
- Produces: stream 11, `SortRank 11`, from `Lots.LotEventLog` joined to `Audit.LogEventType` `WHERE RepeatsLotTimeline = 0 AND l.LotId = @LotId AND l.LoggedAt >= <Lot.CreatedAt>` (read `CreatedAt` into a variable first); `EventKind = ISNULL(et.LotTimelineKind, N'Event')`; `Detail = CAST(l.Description AS NVARCHAR(500))`; `ByUserId`/`ByUserName` via **LEFT** join to `Location.AppUser` (UserId is nullable). Columns and ordering unchanged.

- [ ] **Step 1: Failing tests:** `[History] super-lot rows appear with kind Super-lot`; `[History] CrtActivated appears with kind CRT`; `[History] LotMoved does not appear twice` (count of rows for a moved LOT whose Detail matches the move = 1); `[History] unflagged unlabelled code shows as Event` (insert a test LogEventType with no flag, write one row through `Audit_LogOperation`, assert kind `Event`; delete it in teardown); `[History] never-in-a-super-lot LOT: no Super-lot rows, record streams unchanged`; `[History] times are Eastern` (compare to `LoggedAt` converted).
- [ ] **Step 2-4:** run → FAIL, implement, run filter + `-Filter Lot_GetAttributeHistory` + `-Filter 0007` (or whichever folder holds the existing history tests; find with Grep) → PASS.
- [ ] **Step 5: Commit** — `feat(lots): super-lot piece 6 -- LOT history includes the LOT audit log`.

---

### Task 5: Reads for LOT Detail, trace markers, page History, dashboard, close check

**Files:**
- Create: `R__Quality_ufn_ControlledRunCloseCheck.sql`, `R__Quality_ControlledRun_ListByLot.sql`, `_ListMarkers.sql`, `_ListHistory.sql`, `_GetOpenSummary.sql`
- Modify: `R__Quality_ControlledRun_Get.sql` (+`CanClose BIT`, `CloseBlockedReason NVARCHAR(200)` last), `R__Quality_ControlledRun_Close.sql` (rules 3-5 read the check; its pre-check sync stays), `R__Quality_ControlledRun_ListMembers.sql` (+`WasCompleteAtJoin` last), `R__Quality_ControlledRun_ListMemberResults.sql` (+`AppliedReturnQty` last)
- Create: `sql/tests/0114_SuperLotVisibility/050_reads.sql`; modify the column-list captures of `_Get`, `_ListMembers`, `_ListMemberResults` in `sql/tests/0109_ControlledRun/*` and `0112_ReworkReturn/*`

**Interfaces:**
- `Quality.ufn_ControlledRunCloseCheck(@Id)` → `(CanClose BIT, Reason NVARCHAR(200))`; reasons exactly Close's messages (`Super-lot <RN> is not open.`, `End the window before closing.`, `<n> of <m> members are still CRT-tagged.`), NULL when closable.
- `ControlledRun_ListByLot @LotId` → one row per membership from the fold, newest `AddedAt` first: `ControlledRunId, RunNumber, Reason, RunStatusCode, MembershipState (Open|Released|Removed|Closed|Cancelled), JoinMethodName, JoinedAt, LeftAt, LeftReason, ResultsText` (non-voided results for that member, `'<Disposition> <qty>[ (<Defect>)]'` joined with `', '`), `ReleasedByInitials, ReleasedAt, DeviationNumbers` (`', '`-joined, deviations raised while the member was open), `ViaContainerName`. Times ET.
- `ControlledRun_ListMarkers @LotIdsCsv NVARCHAR(MAX), @ContainerIdsCsv NVARCHAR(MAX)` → `NodeKind (Lot|Container), NodeId, RunNumber, ControlledRunId, MembershipState`; LOTs through the fold, containers through `ControlledRunMember.ContainerId`. `STRING_SPLIT`, ignore blanks/non-numeric.
- `ControlledRun_ListHistory @Id` → `EventAt (ET), Kind, Detail, ByInitials` newest first: `Audit.OperationLog` rows entity `ControlledRun`, `EntityId = @Id`, kind from the event code (`Opened`, `Member`, `Window`, `Label`, `Result`, `Deviation`, `Released`, `Closed`, `Cancelled`), plus `Quality.Signature` rows for this run's release(s) and deviation(s) as kind `Signature`, Detail `<Meaning.Name> · "<Statement>"`.
- `ControlledRun_GetOpenSummary` → one row always: `OpenCount INT, OldestOpenedAt (ET, NULL when none), OldestAgeDays INT NULL, MembersStillTagged INT`.
- Close behaviour unchanged (same messages, same order).

- [ ] **Step 1: Failing tests:** `[ListByLot] never in a super-lot: empty`; `[ListByLot] two memberships newest first incl. re-join after removal`; `[ListByLot] tray LOT shows container's run with ViaContainerName`; `[ListByLot] ResultsText excludes voided`; `[ListByLot] release + deviation`; `[Markers] csv with blanks and junk`; `[Markers] tray LOT via container`; `[History] newest first, signature rows carry the statement`; `[Summary] none open: 0, NULL, NULL, 0`; `[Summary] two open`; `[CloseCheck] each reason equals Close's message for the same state`; `[Get] CanClose 1 exactly when Close succeeds`.
- [ ] **Step 2-4:** run → FAIL; implement; run filter + `0109` + `0112` → PASS.
- [ ] **Step 5: Commit** — `feat(quality): super-lot piece 6 -- by-LOT, marker, history, summary reads; CanClose from SQL`.

---

### Task 6: Repacked containers and scrapped serials in trace

**Files:**
- Modify: `R__Lots_Container_GetTraceDetail.sql`, `R__Lots_SerializedPart_GetTraceDetail.sql`, `R__Lots_GlobalTrace_Resolve.sql`, `R__Lots_Container_ListShipped.sql`, `R__Quality_Hold_ListAssociatedContainers.sql`
- Create: `sql/tests/0114_SuperLotVisibility/060_trace.sql`

**Interfaces:**
- Serial-bearing rows gain `RemovedAt` (ET, NULL when packed) and `RemovedReason NVARCHAR(100)` (`Scrapped (<Defect>)` from `RemovedRejectEventId`, or `Moved to container <Name>` from `ContainerSerialHistory`); rows are kept, not filtered. Serials moved **in** carry `MovedInFromContainerName`. `Container_GetTraceDetail` header row gains `ReplacedSerial` (the voided `AimShipperIdPool` serial from `ContainerRework.OriginalAimShipperId`), `ReplacedSerialVoidedAt` (ET), `ReworkOpenedAt` (ET), `ReworkOpenedByInitials`. New columns go last; existing column order unchanged.

- [ ] **Step 1: Failing tests** on a container driven through `ContainerRework_Open`, `_Scrap` (by serial), `_MovePieces` (a serial in), re-completion (fixture from `0111_ContainerRework/010_rework.sql`): each of the five reads shows the scrapped serial with `RemovedReason LIKE 'Scrapped (%'`; the moved-in serial carries its source; the header carries the old and new serial; an untouched container returns NULL in every new column.
- [ ] **Step 2-4:** FAIL → implement → filter + `0111` + any trace test folder (Grep `GetTraceDetail` in `sql/tests`) → PASS, updating column-list captures.
- [ ] **Step 5: Commit** — `feat(lots): super-lot piece 6 -- trace shows scrapped serials and repacked serials`.

---

### Task 7: Timing gaps and small result gaps

**Files:**
- Modify: `R__Quality_ControlledRunResult_Record.sql` (inlined vendor-return mirror refuses, under the lock, a LOT whose status turned `Closed`/`Scrap`/`Open` since validation: `RAISERROR` into CATCH, as `VendorReturn_Mark` v1.2 does); `R__Quality_ControlledRun_Release.sql` (inside the transaction, re-read each member's ready state from `ufn_ControlledRunMemberResults` under `UPDLOCK, HOLDLOCK` on the member rows; any not ready → `RAISERROR` into CATCH, message `Super-lot results changed while releasing; refresh and try again.`)
- Create: `sql/tests/0114_SuperLotVisibility/070_timing.sql`

- [ ] **Step 1: Tests** — the race itself cannot be produced in one session, so pin the ordinary paths and leave the locked re-check to review: `[Timing] Record return on a Good received LOT still succeeds`; `[Timing] Release of ready members still succeeds`; `[Timing] Release with a not-ready member is still refused before the transaction`.
- [ ] **Step 2-4:** implement; run filter + `0109` + `0112` → PASS.
- [ ] **Step 5: Commit** — `fix(quality): super-lot piece 6 -- re-check under the lock in Record (return) and Release`.

---

### Task 8: CRT refusals name the super-lot

**Files:**
- Modify: `R__Lots_Lot_MoveTo.sql`, `R__Lots_Lot_MoveToValidated.sql`, `R__Lots_Lot_Split.sql`, `R__Lots_Lot_Merge.sql`, `R__Workorder_Assembly_ScanIn.sql`, `R__Workorder_MachiningIn_RecordPick.sql`, `R__Workorder_MachiningOut_Mint.sql`
- Create: `sql/tests/0114_SuperLotVisibility/080_refusals.sql`; update existing assertions that compare the exact text (Grep the message fragments in `sql/tests`)

**Interfaces:** each message inserts ` (super-lot <RN>)` right after `is marked CRT` (`... is marked CRT (super-lot CR000014) and cannot ...`) using `Quality.ufn_OpenControlledRunForLot`; `Lot_Merge` appends it per named LOT. No open super-lot → the text is byte-for-byte today's.

- [ ] **Step 1: Failing tests:** for each proc, a LOT in an open super-lot gets the run number; a CRT LOT in no open super-lot gets today's exact message.
- [ ] **Step 2-4:** FAIL → implement → full suite → PASS (count noted).
- [ ] **Step 5: Commit** — `feat(lots): super-lot piece 6 -- CRT refusals name the super-lot`.

---

### Task 9: Report reads

**Files:**
- Create: `R__Quality_ControlledRun_ReportMembers.sql`, `R__Quality_ControlledRun_ReportOutcomes.sql`, `sql/tests/0114_SuperLotVisibility/090_report_reads.sql`

**Interfaces:**
- `ControlledRun_ReportMembers @Id` → one row per member (ended included), oldest first: `MemberName, PartNumber, PieceCount, JoinedText ('<method> <MM/dd>'), LeftText, AcceptedQty, ScrapQty, OtherText` (repack `old -> new` serial, `trim rework <MM/dd>`, `returned <qty>`).
- `ControlledRun_ReportOutcomes @Id` → `Section ('Outcome'|'Defect'), Label, Pieces`, outcomes from non-voided results by disposition, defects from Scrap results.
- Header, deviations and signatures come from existing `_Get`, `ControlledRunDeviation_ListByRun`, `_ListSignatures`.

- [ ] **Step 1: Failing test:** `[Report] outcome totals equal ControlledRun_ListMemberResults totals for the same run`; `[Report] voided results excluded`; `[Report] repacked container shows old -> new serial`.
- [ ] **Step 2-5:** FAIL → implement → PASS → commit `feat(quality): super-lot piece 6 -- report reads`.

---

### Task 10: Named queries and script wrappers

**Files:**
- Create Core NQs (folder per NQ, `query.sql` + `resource.json`, shaped like `quality/ControlledRun_ListMemberRework`): `quality/ControlledRun_ListByLot`, `_ListMarkers`, `_ListHistory`, `_GetOpenSummary`, `_ReportMembers`, `_ReportOutcomes` (`_GetOpenByMember` and `_GetByNumber` already exist).
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Quality/ControlledRun/code.py`

**Interfaces (thin wrappers, `_refreshToken=None` last on reads):** `listByLot(lotId)`, `listByLotInstances(lotId)` (repeater shape, times pre-formatted like `Lot.mapHistoryInstances`), `openForLotOrEmpty(lotId)` → `{"Id": None, "RunNumber": ""}` shape, `markers(lotIdsCsv, containerIdsCsv)`, `historyInstances(runId)`, `openSummaryOrEmpty()` → `{"OpenCount":0,"OldestAgeDays":None,"MembersStillTagged":0}`, `getRunByNumber(runNumber)` (existing `_GetByNumber` NQ). No rule code: labels and states come from SQL.

- [ ] **Step 1:** write; compile in memory (never `py_compile` in the project tree); `.\scan.ps1`. **Step 2:** call each NQ once from the gateway script console against Dev; empty LOT returns the shaped empty. **Step 3: Commit** — `feat(ignition): super-lot piece 6 -- named queries and ControlledRun wrappers`.

---

### Task 11: LOT Detail — chip, Super-lots tab, toggle wording

**Files:**
- Create: `views/BlueRidge/Components/PlantFloor/LotDetail/SuperLotsPanel/` (view + resource) and a row view `SuperLotRow/` (siblings)
- Modify (text insertion): `views/BlueRidge/Views/ShopFloor/LotDetail/view.json`

- [ ] **Step 1:** custom prop `openSuperLot` (default `{"Id": null, "RunNumber": ""}`) bound to `openForLotOrEmpty(view.params.lotId)`; chip label after `CrtPill`, `meta.visible` on `RunNumber != ""`, click → `system.perspective.navigate('/shop-floor/controlled-runs/' + RunNumber)`.
- [ ] **Step 2:** Super-lots tab between Vendor return and Notes (`position.tabIndex` updated for Notes), embedding `SuperLotsPanel` with `params.lotId`; empty text `This LOT has never been part of a super-lot.`; columns as mock 1.
- [ ] **Step 3:** `doCrtToggle`: when releasing and `openSuperLot.RunNumber` is set, pass the elevation label `Release the Controlled Run Tag. <LOT> is in open super-lot <RN>. This clears the tag on this LOT only; the super-lot is released from the super-lot page.` (copy from mock 3). Applying unchanged.
- [ ] **Step 4:** `.\scan.ps1`; render LOT Detail on Dev for a LOT with no super-lot (no Component Error) and the walkthrough fixture LOT (chip + tab rows); check `wrapper.log`. **Step 5: Commit** — `feat(ignition): super-lot piece 6 -- LOT Detail super-lot chip, Super-lots tab, toggle wording`.

---

### Task 12: Super-lot page — address by run number, History tab, CanClose, member columns

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json` (add `/shop-floor/controlled-runs/:runNumber` → same view); `views/BlueRidge/Views/ShopFloor/ControlledRuns/view.json` (parsed-JSON edit); `ControlledRunMemberRow`, `ControlledRunResultHeader` (columns)
- Create: `views/BlueRidge/Components/PlantFloor/ControlledRunHistoryRow/`

- [ ] **Step 1:** view param `runNumber` (default `""`); `events.system.onStartup` (existing handler) resolves it with `getRunByNumber` and sets `selectedRunId` when found.
- [ ] **Step 2:** History tab enabled; repeater of `ControlledRunHistoryRow` bound to `historyInstances(selectedRunId, refreshToken)`; empty text `No history yet.`
- [ ] **Step 3:** Close button `enabled` ← `{view.custom.run.CanClose}`; tooltip ← `CloseBlockedReason`. Remove the old expression. `getRunOrEmpty`'s empty shape gains `CanClose: False, CloseBlockedReason: ""`.
- [ ] **Step 4:** Members row shows `Pulled back from finished stock` when `WasCompleteAtJoin`; Results header shows applied returns when `AppliedReturnQty > 0`.
- [ ] **Step 5:** scan; open `/shop-floor/controlled-runs/CR000001` on Dev → fixture selected; History rows render; no `wrapper.log` errors. **Commit** — `feat(ignition): super-lot piece 6 -- page opens by run number, History tab, CanClose from SQL`.

---

### Task 13: Genealogy viewer and Global Trace — markers and repack detail

**Files:**
- Modify (text insertion): `views/BlueRidge/Views/ShopFloor/GenealogyViewer/view.json`, `views/BlueRidge/Views/ShopFloor/GlobalTrace/view.json` and their node/row component views (find via each view's repeater `path`); `BlueRidge/Lots/GlobalTrace` (Core) for the detail fields

- [ ] **Step 1:** each tree builds `lotIdsCsv`/`containerIdsCsv` from its rows and binds `markers(...)` once per tree load (not per node); a node shows a chip per marker, amber when `MembershipState = 'Open'`, grey otherwise, text `<RN> · <state lower-case>`.
- [ ] **Step 2:** Global Trace container detail shows `ReplacedSerial` struck through with its void date, and the serial list's `RemovedReason` / `MovedInFromContainerName` as in mock 4. The LOT detail panel (today: production events + genealogy, `GlobalTrace.loadDetail`) gains the LOT's History list, reusing `BlueRidge.Lots.Lot.getHistory` + `mapHistoryInstances` and the `LotDetail/HistoryRow` view, so vendor returns, trim reworks and super-lot rows show in trace (spec 3.3, third bullet).
- [ ] **Step 3:** scan; render both on Dev for a plain LOT and for the fixture; no errors. **Commit** — `feat(ignition): super-lot piece 6 -- trace markers and repack detail`.

---

### Task 14: Supervisor Dashboard — Open super-lots tile

**Files:** Modify (text insertion): `views/BlueRidge/Views/ShopFloor/SupervisorDashboard/view.json`

- [ ] **Step 1:** tile beside Parts to Return, same 30 s poll pattern, bound to `openSummaryOrEmpty()`; value `OpenCount`; sub-text `oldest <n> d · <m> members still CRT · tap to open`, or `none open`; amber class when `OpenCount > 0`; click navigates to `/shop-floor/controlled-runs`.
- [ ] **Step 2:** scan; render with and without open runs. **Commit** — `feat(ignition): super-lot piece 6 -- Open super-lots dashboard tile`.

---

### Task 15: Super-lot report

**Files:**
- Create: `ignition/projects/MPP/com.inductiveautomation.reporting/reports/Super-lot/` (via the global `ignition-reporting` skill; read `ignition-context-pack/10_reporting_module.md` first)
- Modify: `BlueRidge/Reports/code.py` (registry entry `{"key": "super_lot", "title": "Super-lot", "project": "MPP", "reportPath": "Super-lot", "params": [{"id": "ControlledRunId", "label": "Super-lot", "kind": "controlledRun", "required": True}]}`, `controlledRunOptions()` from `ControlledRun_List`, `composeParams` handles the kind); `Views/Reports/view.json` (text insertion: the picker for `controlledRun` and a `selectReport('super_lot')` button); `ControlledRuns` view (a **Print report** button calling the existing print-PDF path with `ControlledRunId`)

- [ ] **Step 1:** report parameter `ControlledRunId`; data sources call `ControlledRun_Get`, `_ReportOutcomes`, `_ReportMembers`, `ControlledRunDeviation_ListByRun`, `_ListSignatures`. Layout as mock 7 (member summary only, no per-member event history). Nested tables only inside `<table-group>`.
- [ ] **Step 2:** deploy by `.\scan.ps1`; render the PDF for `CR000001` and a run with no results; confirm the outcome totals equal the super-lot page's. **Commit** — `feat(reporting): super-lot piece 6 -- Super-lot report`.

---

### Task 16: Docs, full suite, gateway walk

**Files:** `MPP_MES_DATA_MODEL.md` (new revision row; `LogEventType` columns; new codes; fix the stale "v2.2 working draft" header line), `MPP_MES_DATA_MODEL.docx` (regenerate: `pandoc MPP_MES_DATA_MODEL.md -o MPP_MES_DATA_MODEL.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_DATA_MODEL.docx`), `PROJECT_STATUS.md` (2026-10-2x piece 6 entry: what exists, tests, what was and was not walked), spec "Build notes" section, `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md` revision row (all six pieces built).

- [ ] **Step 1:** full suite on `MPP_MES_CRTest` → 0 failures; record the count.
- [ ] **Step 2:** apply `0114` + changed repeatables to `MPP_MES_Dev` (additive); walk every changed screen with the existing walkthrough fixture; list what needed a typed credential and was not walked.
- [ ] **Step 3:** docs as above; **Commit** — `docs: super-lot piece 6 -- data model, status, build notes`.
