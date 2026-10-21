# Super-lot piece 5 — Rework at trim and Return to vendor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the super-lot's Rework and Return-to-vendor outcomes real: a supervisor-approved move back into trim becomes a tracked rework that re-arms the LOT's trim steps, and a received LOT's pieces can be marked for return (off stock at once) and later confirmed from the Supervisor Dashboard.

**Architecture:** Two new tables (`Lots.LotRework`, `Lots.VendorReturn`) in migration `0112`. Rework hooks into three existing procs (`Lot_MoveToValidated` starts it, `ufn_NextPendingRouteStep` re-arms the route, `TrimOut_Record` closes it) plus the two trim count guards. Return is three new mutation procs and two reads; the super-lot side reuses the existing "applied at record time" scrap pattern in `ControlledRunResult_Record` and the left-over function. UI is new views plus small insertions, mock-first.

**Tech Stack:** SQL Server 2022 (T-SQL procs, inline TVFs, repeatable migrations), the in-repo T-SQL test framework (`sql/tests/Run-Tests.ps1`), Ignition 8.3 Perspective (file-based views, Core named queries, Jython script modules).

**Spec:** `docs/superpowers/specs/2026-10-12-controlled-run-rework-and-return-design.md` (approved 2026-10-19). Read it, the handoff `notes/2026-10-13_super-lot-piece-5-handoff.md`, and `CLAUDE.md` before Task 1.

## Global Constraints

- Branch `jacques/controlled-run-super-lot`. Nothing deploys until all six pieces are in. **The main checkout may be on another branch** (another session switched it on 2026-10-19) — work in a worktree on this branch; never `git checkout` in the shared checkout.
- FDS-11-011: no `OUTPUT` params; one result set; every rejecting validation before `BEGIN TRANSACTION`; CATCH is the only ROLLBACK site; a status-row proc never `EXEC`s another status-row proc (inline a commented mirror instead). Mutation exits end `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId` (drop NewId where no row is created). `RAISERROR`, not `THROW`, in CATCH.
- Validation blocks: "first failing rule is the message", every rule parenthesised (handoff: an unparenthesised `OR` once escaped).
- `EXEC` arguments are literals or variables only — in tests too.
- `NVARCHAR`, `DATETIME2(3)`, `BIGINT` ids, UTC stored (`SYSUTCDATETIME()`), ET on every read that displays a time (`AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'`).
- String literals and seed values ASCII-only; build `→` with `NCHAR(8594)` and `·` with `Audit.ufn_MidDot()`.
- Audit Description shape `<SUBJECT> · <CATEGORY?> · <ACTION>`, `Audit.ufn_TruncateActivity`, Lot entity → `Lots.LotEventLog`.
- Anything that changes a LOT's quantity changes `PieceCount` and `InventoryAvailable` together, under `UPDLOCK, HOLDLOCK` with a TOCTOU re-check, mirroring `Workorder.RejectEvent_Record`'s subtractive path.
- Every mutation's `@AppUserId` comes from its caller (`BlueRidge.Common.Session.currentAppUserId(self.session)` in views); entity functions call `Common.Util.requireAppUserId`.
- Named queries live in **Core** only; status-row procs use NQ `type: "Query"`; ids `sqlType: 3`, strings `sqlType: 7`.
- New views are new folders (each with `view.json` + `resource.json`). Existing Designer-saved views (`Views/ShopFloor/LotDetail`) are edited by inserting text, never re-serialised. `ControlledRun*` views were generated and may be edited as parsed JSON.
- The FDS is not edited. `MPP_MES_DATA_MODEL.md` and `PROJECT_STATUS.md` are.
- Tests run on a private database only: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CRTest [-Filter ...]`. It DROPs its target. Never `MPP_MES_Dev`.
- Stage explicit paths; no `git add -A/-u`; no `Co-Authored-By` trailer.

## Review Focus

1. **A rework started by mistake.** An override move into trim that nobody runs leaves the rework open and blocks the super-lot's release. Expected: it closes only through a Trim OUT (a zero-scrap Trim OUT is the undo). Pinned in Task 4 (`plain move out of trim leaves the rework open`). There is no separate cancel.
2. **A second override move while a rework is open** (supervisor moves it back again). Expected: no second row, no failure, the move happens. Pinned in Task 2.
3. **Returning more than is available but not more than the LOT holds** (`InventoryAvailable` < qty ≤ `PieceCount`). Expected: allowed, `InventoryAvailable` floored at zero, the taken amounts recorded so Cancel restores exactly. Pinned in Task 6.
4. **A return marked from LOT Detail on a LOT whose super-lot membership has ended, or whose super-lot is closed.** Expected: no result row written, return still succeeds. Pinned in Task 7.
5. **A reworked LOT whose route was entered mid-way at cutover** (`EntryRouteSequence` above its TrimIn step). Expected: the pending rule still ignores steps below the entry point; a rework re-entry below it re-arms nothing below entry. Pinned in Task 3.

---

## File structure

| Path | Responsibility |
|---|---|
| `sql/migrations/versioned/0112_rework_and_vendor_return.sql` (create) | `Lots.LotRework`, `Lots.VendorReturn`, five `Audit.LogEventType` rows, SchemaVersion |
| `sql/migrations/repeatable/R__Lots_ufn_OpenLotRework.sql` (create) | Inline TVF: a LOT's open rework (one row or none) |
| `sql/migrations/repeatable/R__Workorder_ufn_TrimPassPreviousCount.sql` (create) | Inline TVF: the trim floor for the current pass |
| `R__Lots_Lot_MoveToValidated.sql`, `R__Lots_ufn_NextPendingRouteStep.sql`, `R__Workorder_TrimOut_Record.sql`, `R__Workorder_TrimPartial_Record.sql`, `R__Workorder_TrimCheckpoint_GetLatestForLot.sql` (modify) | Rework start, route re-arm, rework close, pass-scoped counting |
| `R__Lots_VendorReturn_Mark.sql`, `_Confirm.sql`, `_Cancel.sql`, `_ListOpen.sql`, `_ListByLot.sql` (create) | Return lifecycle and reads |
| `R__Quality_ControlledRunResult_Record.sql`, `R__Quality_ControlledRunResult_ListByRun.sql`, `R__Quality_ufn_zzz_ControlledRunMemberResults.sql` (modify), `R__Quality_ControlledRun_ListMemberRework.sql` (create) | Super-lot tie-in |
| `sql/tests/0112_ReworkReturn/010_schema.sql`, `020_rework_start.sql`, `030_pending_rule.sql`, `040_trim_pass.sql`, `050_superlot_rework.sql`, `060_vendor_return.sql`, `070_superlot_return.sql` (create) | Tests |
| `ignition/projects/Core/ignition/named-query/lots/VendorReturn_*`, `quality/ControlledRun_ListMemberRework` (create) | NQs |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/VendorReturn/code.py` (+ `resource.json`) (create) | Entity script |
| Views (Task 10) | LOT Detail tab, dashboard tile + popup, super-lot Results changes |

---

### Task 1: Migration 0112 — tables and audit codes

**Files:**
- Create: `sql/migrations/versioned/0112_rework_and_vendor_return.sql`
- Create: `sql/tests/0112_ReworkReturn/010_schema.sql`
- Modify: the audit `LogEventType` count-pin test (find it with `Grep "LogEventType" sql/tests` for a `COUNT(*)` assertion) and any other pin that fails in Step 4

**Interfaces:**
- Produces: tables below; LogEventType codes `LotReworkStarted`, `LotReworkCompleted`, `VendorReturnMarked`, `VendorReturnConfirmed`, `VendorReturnCancelled`.

- [ ] **Step 1: Write the failing schema test** `010_schema.sql` (open with `EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/010_schema.sql';`). Assertions:
  - `OBJECT_ID('Lots.LotRework','U')` and `OBJECT_ID('Lots.VendorReturn','U')` not null.
  - `Lots.LotRework` columns: `Id, LotId, ReEntrySequenceNumber, LotMovementId, StartedAt, MovedByUserId, ApprovedByUserId, TerminalLocationId, CompletedAt, CompletedProductionEventId`.
  - filtered unique index `UQ_LotRework_OpenPerLot` exists with `has_filter = 1`.
  - `Lots.VendorReturn` columns: `Id, LotId, Quantity, PieceCountTaken, InventoryTaken, Remarks, ControlledRunResultId, MarkedByUserId, MarkedAt, TerminalLocationId, ConfirmedAt, ConfirmedByUserId, CancelledAt, CancelledByUserId, CancelRemarks`.
  - inserting a VendorReturn with both `ConfirmedAt` and `CancelledAt` set fails (TRY/CATCH, assert caught).
  - the five LogEventType codes exist.

- [ ] **Step 2: Run it, expect FAIL** — `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CRTest -Filter 0112_ReworkReturn` → table-missing assertions fail.

- [ ] **Step 3: Write the migration**, shaped like `0111_container_rework.sql` (idempotent `IF ... IS NULL` guards, `sp_addextendedproperty` descriptions, the `@Base + ROW_NUMBER()` LogEventType insert, post-condition THROW, SchemaVersion row `0112_rework_and_vendor_return` with "Do NOT deploy alone."). Key DDL decisions:
  - `LotRework`: FKs to `Lots.Lot`, `Location.AppUser` (MovedBy, ApprovedBy), `Location.Location` (Terminal). `LotMovementId`, `CompletedProductionEventId` are pointers with no FK (comment why). `CK_LotRework_Completed` pairs `CompletedAt`/`CompletedProductionEventId`. `CREATE UNIQUE INDEX UQ_LotRework_OpenPerLot ON Lots.LotRework (LotId) WHERE CompletedAt IS NULL;` plus `IX_LotRework_Lot (LotId, StartedAt DESC) INCLUDE (ReEntrySequenceNumber, CompletedAt)`.
  - `VendorReturn`: `CK_VendorReturn_Quantity CHECK (Quantity > 0)`, `CK_VendorReturn_Taken CHECK (PieceCountTaken >= 0 AND InventoryTaken >= 0)`, `CK_VendorReturn_OneEnd CHECK (ConfirmedAt IS NULL OR CancelledAt IS NULL)`, paired-column CHECKs for confirm and cancel. FK `ControlledRunResultId → Quality.ControlledRunResult`. `IX_VendorReturn_Open (MarkedAt) WHERE ConfirmedAt IS NULL AND CancelledAt IS NULL`, `IX_VendorReturn_Lot (LotId)`.

- [ ] **Step 4: Run the filter, expect PASS; then run the full suite** (`.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_CRTest`). Expected: only count pins fail (LogEventType +5). Update each pin, re-run full, expect 0 failures and an assertion count of baseline (4,795 + new).

- [ ] **Step 5: Commit** — `git add` the migration, the test, each pin file; `git commit -m "feat(lots): super-lot piece 5 schema -- LotRework, VendorReturn, audit codes (migration 0112)"`.

---

### Task 2: Rework starts at the Trim IN override move

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_OpenLotRework.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_MoveToValidated.sql` (→ v1.2)
- Note: the spec's `VendorReturn_Mark @ControlledRunResultId` parameter is dropped in this plan — a super-lot Return is applied when it is recorded (Task 7), so Mark never needs to be told about a result. Record this in the spec's Build notes (Task 11).
- Create: `sql/tests/0112_ReworkReturn/020_rework_start.sql`

**Interfaces:**
- Consumes: Task 1 tables.
- Produces: `Lots.ufn_OpenLotRework(@LotId BIGINT)` → inline TVF, 0 or 1 row `(Id, LotId, ReEntrySequenceNumber, StartedAt)`; `Lot_MoveToValidated` signature unchanged.

**Fixture (shared shape for Tasks 2–5):** a test Item whose published route has `DieCast → TrimIn → TrimOut → MachiningIn → …` (find one with `Parts.RouteStep_GetSequenceForItemRole` / the route tables; skip with a fixture assertion like 010_rework.sql does if none). LOTs named `TEST-RWK-%`. Drive a LOT through first-pass trim with the real procs: move into the trim area (`Lot_MoveToValidated @OperationTypeCode='TrimIn'`), TrimIn checkpoint (`Workorder.ProductionEvent_Record`), `Workorder.TrimOut_Record` with ShotCount 95 + 5 scrap on a 100-piece LOT. Teardown: copy 010_rework.sql's block and add `Lots.LotRework`, `Lots.VendorReturn`, `Workorder.ProductionEvent` for the test LOTs, deleted before `Lots.Lot`.

- [ ] **Step 1: Write the failing tests** in `020_rework_start.sql`:
  - `[RwkStart] reproduce: override move back into trim succeeds today` — status 1 (documents the starting point).
  - `[RwkStart] override TrimIn backward move writes one LotRework` — count = 1; `ReEntrySequenceNumber` = the route's TrimIn sequence; `ApprovedByUserId` = override user; `MovedByUserId` = @AppUserId; `LotMovementId` = the newest `LotMovement.Id` for the LOT; `CompletedAt IS NULL`.
  - `[RwkStart] audit reads as a trim rework` — newest `LotEventLog` Description for the LOT contains `trim rework`.
  - `[RwkStart] second override move while open: no second row, move succeeds` — status 1, count still 1.
  - `[RwkStart] forward TrimIn move with an override supplied writes no rework` (fresh LOT never trimmed).
  - `[RwkStart] backward move for another operation writes no rework` (use `MachiningIn` backward with override on a LOT past it, if the fixture route allows; else assert with `TrimOut`-coded op is not treated as rework).
  - `[RwkStart] no override: still blocked, no rework` — status 0, message starts `Backward move blocked`.
  - `[RwkStart] CRT LOT: override rework move into trim succeeds` — set `Lot.CrtActive = 1` through the existing CRT proc used by `110_review_fixes.sql`; status 1, rework row written.
  - `[RwkStart] CRT LOT: plain move to a production location still refused` — unchanged message.
  - `[RwkStart] Hold LOT: override move still refused`.

- [ ] **Step 2: Run** `-Filter 0112_ReworkReturn` → the rework-row and CRT assertions FAIL (the CRT failure is the spec's gap 2 reproduced).

- [ ] **Step 3: Implement.**
  - `ufn_OpenLotRework`: `SELECT Id, LotId, ReEntrySequenceNumber, StartedAt FROM Lots.LotRework WHERE LotId = @LotId AND CompletedAt IS NULL` (unique index guarantees ≤ 1).
  - `Lot_MoveToValidated` v1.2 (header change log entry): before rule 4b, compute `@AttemptedSeq` / `@NextPendingSeq` **regardless of override** (move the two DECLAREs out of the `IF`) and set `@IsRework BIT = 1` when `@OverrideAppUserId IS NOT NULL AND @OperationTypeCode = N'TrimIn' AND @AttemptedSeq < @NextPendingSeq` (both non-null). Rule 4b keeps its current condition. Rule 6 (CRT) becomes `IF @IsRework = 0 AND (SELECT Blocked ...) = 1`. Validate `@OverrideAppUserId` exists in `Location.AppUser` when supplied (new rule, parenthesised, placed before 4b). In the transaction after the `LotMovement` insert: `SET @MovementId = SCOPE_IDENTITY();` and, when `@IsRework = 1 AND NOT EXISTS (SELECT 1 FROM Lots.ufn_OpenLotRework(@LotId))`, insert the `LotRework` row and an `Audit_LogOperation` with code `LotReworkStarted`. The movement Description suffix becomes ` (trim rework, approved by <Initials>)` when `@IsRework = 1`, else the existing override suffix.

- [ ] **Step 4: Run the filter → PASS; run `-Filter Movement` and `-Filter ControlledRun` → PASS** (existing move and CRT tests unaffected).

- [ ] **Step 5: Commit** — `feat(lots): super-lot piece 5 -- trim rework starts at the Trim IN override move`.

---

### Task 3: Route pending rule re-armed after a rework

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_ufn_NextPendingRouteStep.sql` (→ v1.2)
- Create: `sql/tests/0112_ReworkReturn/030_pending_rule.sql`

**Interfaces:**
- Consumes: `Lots.LotRework`.
- Produces: same function signature and columns. Readers that change with it: `Lot_GetWipQueueByLocation`, `Lot_GetComponentsAtCell`, `Lot_GetTrimStorageQueueForLine`, `Lot_MoveToValidated`, `Workorder.MachiningIn_RecordPick`, `Workorder.MachiningOut_Mint`.

- [ ] **Step 1: Write the failing tests:**
  - `[Pending] reworked LOT is listed in the Trim queue after the override move` — this is the spec's gap 1; confirm it FAILS in Step 2 before any change (that failure is the reproduction).
  - `[Pending] reworked LOT next pending = TrimIn` (`SELECT OperationTypeCode FROM Lots.ufn_NextPendingRouteStep(@Lot)`).
  - `[Pending] reworked LOT listed by Lot_GetWipQueueByLocation for the trim area, TrimIn`.
  - `[Pending] after TrimIn checkpoint, next pending = TrimOut`.
  - `[Pending] LOT that was picked at Machining IN before rework: after re-run Trim OUT, next pending = MachiningIn and it is listed by Lot_GetTrimStorageQueueForLine`.
  - `[Pending] LOT with no rework rows: next pending unchanged` (compare against a never-reworked twin).
  - `[Pending] EntryRouteSequence above TrimIn: rework re-arms nothing below entry` (Review Focus 5) — set `EntryRouteSequence` on a fixture LOT to MachiningIn's sequence, insert a `LotRework` with the TrimIn sequence directly, assert next pending = MachiningIn.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** (keep it an inline TVF; add a v1.2 header note). The algorithm the signature does not determine:

```sql
    FROM Lots.Lot l
    OUTER APPLY (SELECT TOP (1) lr.ReEntrySequenceNumber, lr.StartedAt
                 FROM Lots.LotRework lr WHERE lr.LotId = l.Id
                 ORDER BY lr.StartedAt DESC, lr.Id DESC) rw
    ...
           OR (rk.Code = N'Advance' AND NOT EXISTS (
                  SELECT 1 FROM Workorder.ProductionEvent pe
                  WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId
                    AND (rw.StartedAt IS NULL
                         OR rs.SequenceNumber < rw.ReEntrySequenceNumber
                         OR pe.EventAt >= rw.StartedAt)))
```

- [ ] **Step 4: Run the filter → PASS; run `-Filter Machining`, `-Filter Trim`, `-Filter Assembly`, `-Filter WipQueue` → PASS.** Check the actual plan of `Lot_GetWipQueueByLocation` for one location with `SET STATISTICS IO ON` before and after; note logical reads in the commit message.

- [ ] **Step 5: Commit** — `feat(lots): super-lot piece 5 -- route steps re-armed after a trim rework`.

---

### Task 4: Trim pass counting and rework completion

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_ufn_TrimPassPreviousCount.sql`
- Modify: `R__Workorder_TrimOut_Record.sql`, `R__Workorder_TrimPartial_Record.sql`, `R__Workorder_TrimCheckpoint_GetLatestForLot.sql`
- Create: `sql/tests/0112_ReworkReturn/040_trim_pass.sql`

**Interfaces:**
- Consumes: `Lots.ufn_OpenLotRework`.
- Produces: `Workorder.ufn_TrimPassPreviousCount(@LotId BIGINT)` → inline TVF, 0 or 1 row `(ShotCount INT, ProductionEventId BIGINT)`: the newest TrimIn/TrimOut checkpoint with a non-null ShotCount, restricted to `EventAt >= open rework StartedAt` when a rework is open.

- [ ] **Step 1: Write the failing tests** (100-piece LOT, first pass 95 good + 5 scrap → LOT at 95, then override move back):
  - `[TrimPass] re-run Trim OUT 94 + 1 scrap succeeds` — status 1 (94 + 1 ≤ 95, and 94 is not compared with the first pass's 95); LOT `PieceCount` 94; one new `RejectEvent` with `ShiftId` not null.
  - `[TrimPass] re-run checkpoint carries ShiftId NULL` (not credited to a shift).
  - `[TrimPass] first-pass checkpoint carries a ShiftId` (unchanged behaviour).
  - `[TrimPass] Trim OUT completes the rework` — `CompletedAt` set, `CompletedProductionEventId` = the new checkpoint; a `LotReworkCompleted` audit row.
  - `[TrimPass] partial on the re-run: 40 accepted, then Trim OUT 94 accepted` — `TrimPartial_Record` ShotCount 40 succeeds with checkpoint `ShiftId NULL`; Trim OUT 94 succeeds; Trim OUT 30 after the partial is refused (monotonic within the pass).
  - `[TrimPass] TrimCheckpoint_GetLatestForLot returns nothing right after the rework move` (popup shows no prior count for the new pass), then returns the partial.
  - `[TrimPass] plain move out of trim leaves the rework open` (Review Focus 1).
  - `[TrimPass] no rework: guard 7 unchanged` — a first-pass Trim OUT lower than a partial still refused.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.**
  - `ufn_TrimPassPreviousCount`: the guard-7 query of `TrimOut_Record` plus `OUTER APPLY Lots.ufn_OpenLotRework(@LotId) rw` and `AND (rw.StartedAt IS NULL OR pe.EventAt >= rw.StartedAt)`.
  - `TrimOut_Record`: guard 7's `@PrevShot` read becomes `SELECT @PrevShot = ShotCount FROM Workorder.ufn_TrimPassPreviousCount(@ParentLotId)`. Read `@OpenReworkId` before the transaction. In the transaction: the checkpoint's `ShiftId` is `CASE WHEN @OpenReworkId IS NULL THEN @ShiftId END`; scrap rows keep `@ShiftId`; after the checkpoint insert, `UPDATE Lots.LotRework SET CompletedAt = SYSUTCDATETIME(), CompletedProductionEventId = @NewId WHERE Id = @OpenReworkId AND CompletedAt IS NULL` and the `LotReworkCompleted` audit. Header: change-log line + a note that rework-pass output is not shift trim production.
  - `TrimPartial_Record` guard 8: same function; checkpoint `ShiftId` NULL while a rework is open (the required `@ShiftId` still validates and still stamps the scrap rows).
  - `TrimCheckpoint_GetLatestForLot`: add the same since-rework filter.

- [ ] **Step 4: Run the filter → PASS; `-Filter Trim` (0024, 0096 suites) → PASS.**

- [ ] **Step 5: Commit** — `feat(workorder): super-lot piece 5 -- rework pass starts its own trim count, not shift production; Trim OUT closes the rework`.

---

### Task 5: Super-lot side of rework

**Files:**
- Modify: `R__Quality_ufn_zzz_ControlledRunMemberResults.sql` (→ v1.2), `R__Quality_ControlledRunResult_Record.sql` (→ v1.1)
- Create: `R__Quality_ControlledRun_ListMemberRework.sql`, `sql/tests/0112_ReworkReturn/050_superlot_rework.sql`
- Modify: `sql/tests/0109_ControlledRun/130_results.sql` (any assertion that records a `Rework` entry)

**Interfaces:**
- Produces: `Quality.ControlledRun_ListMemberRework(@ControlledRunId BIGINT)` → rows `(MemberId BIGINT, LotReworkId BIGINT, StartedAt DATETIME2(3) /*ET*/, ApprovedByInitials NVARCHAR)` for current LOT members with an open rework. Read proc, empty = none.

- [ ] **Step 1: Write the failing tests** (open a super-lot with the fixture LOT as member, reusing 130_results.sql's opening sequence):
  - `[SlRwk] member with open rework: ReleaseBlockReason = 'At trim rework'`.
  - `[SlRwk] ControlledRun_Release refuses while a member is at trim rework`.
  - `[SlRwk] after re-run Trim OUT, block reason is back to 'No results yet'`.
  - `[SlRwk] ListMemberRework returns the member with ET StartedAt` (assert `StartedAt` = `CAST(lr.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`).
  - `[SlRwk] recording a Rework entry is refused` — message `<DisplayName>: rework is recorded by moving the LOT back into trim, not as a result.`
  - `[SlRwk] ReworkQty column still present and 0`.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.** Function: new `WHEN` after "No longer in the super-lot" and before "Being reworked": `ms.LotId IS NOT NULL AND EXISTS (SELECT 1 FROM Lots.ufn_OpenLotRework(ms.LotId))` → `N'At trim rework'`. (Mind the file's three-z deploy-order note; `ufn_OpenLotRework` sorts before `ufn_zzz_`… it is in the Lots schema file `R__Lots_ufn_OpenLotRework.sql`, which sorts before `R__Quality_*` — fine.) Record proc: new parenthesised rule after "unknown outcome": `e.DispositionCode = N'Rework'` → the message above; update the header's outcome list.

- [ ] **Step 4: Run the filter and `-Filter 0109_ControlledRun` → PASS** (fix the 130_results.sql Rework entries to another disposition).

- [ ] **Step 5: Commit** — `feat(quality): super-lot piece 5 -- release blocked at trim rework; Rework is no longer a result entry`.

---

### Task 6: Return to vendor — mark, confirm, cancel, reads

**Files:**
- Create: `R__Lots_VendorReturn_Mark.sql`, `R__Lots_VendorReturn_Confirm.sql`, `R__Lots_VendorReturn_Cancel.sql`, `R__Lots_VendorReturn_ListOpen.sql`, `R__Lots_VendorReturn_ListByLot.sql`, `sql/tests/0112_ReworkReturn/060_vendor_return.sql`

**Interfaces:**
- Produces:
  - `Lots.VendorReturn_Mark(@LotId BIGINT, @Quantity INT, @Remarks NVARCHAR(500) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → Status, Message, NewId (VendorReturn.Id).
  - `Lots.VendorReturn_Confirm(@VendorReturnId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → Status, Message.
  - `Lots.VendorReturn_Cancel(@VendorReturnId BIGINT, @CancelRemarks NVARCHAR(500), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL)` → Status, Message.
  - `Lots.VendorReturn_ListOpen()` → `VendorReturnId, LotId, LotName, ItemPartNumber, VendorLotNumber, Quantity, Remarks, MarkedByInitials, MarkedAt (ET), CurrentLocationName`, oldest first.
  - `Lots.VendorReturn_ListByLot(@LotId BIGINT)` → `VendorReturnId, Quantity, Remarks, MarkedByInitials, MarkedAt (ET), ConfirmedByInitials, ConfirmedAt (ET), CancelledByInitials, CancelledAt (ET), CancelRemarks, StateCode ('Open'|'Confirmed'|'Cancelled'), CanCancel BIT`, newest first.

- [ ] **Step 1: Write the failing tests** (Received-origin LOT `TEST-VR-R1` 50 pieces, ReceivedOffsite `TEST-VR-R2`, Manufactured `TEST-VR-M1`; create with `Lots.Lot_Create` as `0109_Lot_ListByVendorLot` tests do):
  - `[VR] mark 10 on Received: status 1, PieceCount 40, InventoryAvailable 40, PieceCountTaken 10, InventoryTaken 10`.
  - `[VR] mark on ReceivedOffsite allowed`.
  - `[VR] Manufactured refused` — `LOT <name> was made at MPP; only purchased or received material can be returned to a vendor.`
  - `[VR] over PieceCount refused`; `[VR] quantity 0 refused`; `[VR] Closed / Scrap / Open LOT refused`; `[VR] Hold LOT allowed`.
  - `[VR] InventoryAvailable below qty: floored at 0, InventoryTaken = old InventoryAvailable` (Review Focus 3).
  - `[VR] no RejectEvent written`.
  - `[VR] Good LOT marked to zero closes with a LotStatusHistory row; Hold LOT to zero stays Hold`.
  - `[VR] VendorReturnMarked audit row on LotEventLog`.
  - `[VR] ListOpen lists it with ET MarkedAt`; `[VR] confirm: stamped, gone from ListOpen, quantities unchanged`; `[VR] confirm twice refused`.
  - `[VR] cancel restores exactly the taken amounts`; `[VR] cancel after confirm refused`; `[VR] cancel on a now-Closed LOT refused`; `[VR] Hold-at-zero cancel allowed`.
  - `[VR] ListByLot StateCode and CanCancel per row`.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** the five procs from `_TEMPLATE_stored_procedure.sql`. Mark's decrement + close-at-zero is an INLINED MIRROR of `RejectEvent_Record`'s subtractive path (cite file + version in a comment), with `UPDLOCK, HOLDLOCK` and a re-check that `@Quantity <= PieceCount` inside the transaction. Cancel takes the same lock and adds `PieceCountTaken` / `InventoryTaken` back. Audit Descriptions: `<LotName> · Vendor return · Marked <qty>` / `Confirmed returned <qty>` / `Cancelled <qty>`.

- [ ] **Step 4: Run the filter → PASS.**

- [ ] **Step 5: Commit** — `feat(lots): super-lot piece 5 -- return to vendor: mark, confirm, cancel, reads`.

---

### Task 7: Super-lot side of return

**Files:**
- Modify: `R__Quality_ControlledRunResult_Record.sql`, `R__Quality_ControlledRunResult_ListByRun.sql`, `R__Quality_ufn_zzz_ControlledRunMemberResults.sql`, `R__Quality_ControlledRunResult_Void.sql` (only if it would void an applied return), `R__Lots_VendorReturn_Mark.sql`, `R__Lots_VendorReturn_Cancel.sql`
- Create: `sql/tests/0112_ReworkReturn/070_superlot_return.sql`
- Modify: every test capture table that reads `ufn_ControlledRunMemberResults` / `ControlledRun_ListMemberResults` by column list (`Grep "AppliedScrapQty" sql`)

**Interfaces:**
- Consumes: Task 6 procs' logic (inlined, not EXEC'd).
- Produces: `ufn_ControlledRunMemberResults` gains `AppliedReturnQty INT` as the LAST column; `LeftOver = PieceCount + AppliedScrapQty + AppliedReturnQty - ResultQty`. `ControlledRunResult_ListByRun.IsApplied` is 1 when `RejectEventId IS NOT NULL` or a `VendorReturn` points at the result.

- [ ] **Step 1: Write the failing tests** (super-lot with Received LOT member `TEST-VR-S1` 50 pieces, a Manufactured member, a container member):
  - `[SlVR] Return 10 on Received member: one VendorReturn with ControlledRunResultId, PieceCount 40`.
  - `[SlVR] LeftOver after Return 10 + Accepted 40 = 0`.
  - `[SlVR] Return on Manufactured member refused` / `on container member refused`.
  - `[SlVR] applied return: IsApplied 1, CanVoid 0`; `[SlVR] Void of the applied return result refused`.
  - `[SlVR] cancel the return voids its result in the same transaction` (`VoidedAt` set, `VoidRemarks` = the cancel remarks).
  - `[SlVR] VendorReturn_Mark on a current member writes an applied ReturnToSupplier result` (`RecordedByUserId` = marker).
  - `[SlVR] VendorReturn_Mark after membership ended / super-lot closed writes no result` (Review Focus 4).

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.** In `ControlledRunResult_Record`: the `@E` build already joins the LOT; add `LotOriginCode`. New rules after the scrap rules: ReturnToSupplier on a container member → `<DisplayName>: a container cannot be returned to a vendor.`; on a non-received LOT → the Task 6 Manufactured message; total return + scrap above the LOT's pieces → refused like the scrap total. In the transaction, after scrap: for each ReturnToSupplier entry on a LOT member, the inlined mark (comment: mirror of `R__Lots_VendorReturn_Mark.sql`), then set the VendorReturn's `ControlledRunResultId` after the result rows are inserted (insert results first if simpler — the builder orders it, but both must be in the one transaction). In `VendorReturn_Mark`: inside the transaction, when the LOT is a current member of an OPEN super-lot (`Quality.ufn_ControlledRunMemberState` via `Quality.ControlledRun_GetOpenByMember`'s query, inlined), insert an applied `ReturnToSupplier` result and link it. In `VendorReturn_Cancel`: void the linked result (`VoidedAt`, `VoidedByUserId`, `VoidRemarks`).

- [ ] **Step 4: Run the filter, `-Filter 0109_ControlledRun`, `-Filter 0111` → PASS**, fixing capture tables for the new last column.

- [ ] **Step 5: Commit** — `feat(quality): super-lot piece 5 -- Return result takes pieces off the LOT; left-over counts applied returns`.

---

### Task 8: Named queries and script module

**Files:**
- Create (Core): `named-query/lots/VendorReturn_Mark|Confirm|Cancel|ListOpen|ListByLot/{query.sql,resource.json}`, `named-query/quality/ControlledRun_ListMemberRework/{query.sql,resource.json}`
- Create: `script-python/BlueRidge/Lots/VendorReturn/{code.py,resource.json}`
- Modify: `script-python/BlueRidge/Quality/ControlledRun/code.py` (add `memberRework`)

**Interfaces:**
- Produces (Jython): `BlueRidge.Lots.VendorReturn.mark(lotId, quantity, remarks, appUserId, terminalLocationId)`, `.confirm(vendorReturnId, appUserId, terminalLocationId)`, `.cancel(vendorReturnId, cancelRemarks, appUserId, terminalLocationId)` → status dict via `Common.Db.execMutation`; `.listOpen(_refreshToken=None)` → list[dict]; `.openCount(_refreshToken=None)` → int; `.listByLot(lotId, _refreshToken=None)` → list[dict] (`[]` when none). `BlueRidge.Quality.ControlledRun.memberRework(controlledRunId, _refreshToken=None)` → dict `{memberId: {"startedAt": str, "approvedBy": str}}` (empty dict when none).

- [ ] **Step 1:** Write the NQs (shape of `lots/ContainerRework_Void`; mutations `type: "Query"`, reads `type: "Query"`).
- [ ] **Step 2:** Write the module following `BlueRidge/Lots/ContainerRework/code.py` (`_u`, `_int`, `requireAppUserId`, log line per mutation). Compile in memory only (`python -c "compile(open(p).read(), p, 'exec')"`) — never `py_compile` in the project tree.
- [ ] **Step 3:** Deploy to the dev gateway (`.\scan.ps1`), then in the Script Console call `BlueRidge.Lots.VendorReturn.listOpen()` and `BlueRidge.Quality.ControlledRun.memberRework(<CR000001 id>)`. Expected: lists, no "Named query not found" in the gateway log.
- [ ] **Step 4: Commit** — `feat(ignition): super-lot piece 5 -- vendor return + member rework named queries and script module`.

---

### Task 9: Mocks for Jacques (gate before any view)

**Files:**
- Create: `notes/2026-10-19_super-lot-piece-5-screen-mocks.html`

- [ ] **Step 1:** One static HTML page with three mocks at plant-terminal size: (a) LOT Detail "Vendor return" tab (form: quantity, remarks, Return button; history list with Cancel on the open row; refused-origin message for a manufactured LOT); (b) Supervisor Dashboard "Parts to return" tile (count) and its popup (rows: LOT, part, vendor lot, qty, marked by/at, location, Confirm returned); (c) super-lot Results entry without the Rework tile, Return tile only on received members, and a member row showing "At trim rework since 10/19 13:05 (JP)".
- [ ] **Step 2:** Publish it as an Artifact and give Jacques the link. **Stop until he approves or changes it.** Fold his changes into Task 10's steps.
- [ ] **Step 3: Commit** the HTML.

---

### Task 10: Views

**Files:**
- Create: `views/BlueRidge/Components/PlantFloor/LotDetail/VendorReturnPanel/{view.json,resource.json}`, `views/BlueRidge/Components/Popups/VendorReturnConfirm/{view.json,resource.json}`, `views/BlueRidge/Components/PlantFloor/VendorReturnRow/{view.json,resource.json}` (popup row)
- Modify: `views/BlueRidge/Views/ShopFloor/LotDetail/view.json` (text insertion: one `tabs` entry `{"disabled": false, "runWhileHidden": true, "text": "Vendor return"}` and one pane mirroring `PanelScrap` with `position.tabIndex` = the new index, embedding `VendorReturnPanel` with `props.params.lotId` bound to `view.params.lotId`)
- Modify: `views/BlueRidge/Views/ShopFloor/SupervisorDashboard/view.json` (plain JSON; add `TileReturns` beside `TileReconcile`)
- Modify: `views/BlueRidge/Components/PlantFloor/ControlledRunResultEntry` (+ `ControlledRunEntryTile` if the tile list lives there), `ControlledRunMemberRow`
- Modify: `script-python/BlueRidge/Common/Session/code.py` — `_ELEVATED_REPLAY_MESSAGES["VendorReturn"] = "vendorReturnRequested"`

- [ ] **Step 1:** `VendorReturnPanel` (params `lotId`): per the approved mock. Return button → `requireElevation(self.session, "VendorReturn", "Return to vendor", {...})`; the page-scoped `vendorReturnRequested` handler re-tests `isElevated` and calls `VendorReturn.mark(..., appUserId=Common.Session.currentAppUserId(self.session), ...)`, then `Common.Ui.notifyResult` and reloads. Pre-declare every bound custom prop with a full-shape default. Cancel row action goes through the same elevation code.
- [ ] **Step 2:** LOT Detail insertion — open the file, insert the two text blocks, validate with `python -c "import json; json.load(open(p, encoding='utf-8'))"`, check the pane's `tabIndex` against the tab array position. If Jacques has LOT Detail open in Designer, ask him to close it first.
- [ ] **Step 3:** Dashboard tile: value bound to `runScript("BlueRidge.Lots.VendorReturn.openCount", 30000)`, click opens `Popups/VendorReturnConfirm` (`scope: "G"`). The popup's repeater uses `VendorReturnRow`; Confirm calls `VendorReturn.confirm` with the session user, no elevation, then refreshes via a direct write to the list prop (not `refreshBinding`).
- [ ] **Step 4:** Super-lot Results: drop the Rework tile; show the Return tile only when the member's LOT origin is received (add `LotOriginCode` to the member data the entry view already receives — check which read feeds it and prefer adding to a non-captured read); member row shows the `memberRework` status line.
- [ ] **Step 5:** Deploy (`.\scan.ps1`), drive each screen in the browser pane against the walkthrough fixture (`CR000001`, `WALK-CR-*`) plus a Received LOT: mark, see LOT Detail and the tile update, confirm, cancel; on Trim do the override move on a fixture LOT and see it in the Trim list and the super-lot member row. Report honestly anything not driven past a password prompt.
- [ ] **Step 6: Commit** each view folder and modified file by explicit path — `feat(ignition): super-lot piece 5 -- vendor return tab, dashboard tile, super-lot results changes`.

---

### Task 11: Documentation and full verification

**Files:**
- Modify: `MPP_MES_DATA_MODEL.md` (revision row 3.6; `LotRework`, `VendorReturn` sections; `ControlledRunResult` disposition note), `PROJECT_STATUS.md` (2026-10-19 entry: built / verified / not verified), the spec (append "Build notes" listing where the build differs), `notes/` handoff for piece 6 if the session ends here.

- [ ] **Step 1:** Run the full suite on the private DB. Expected: 0 failures, assertion count = baseline + this piece's. Record the number.
- [ ] **Step 2:** Write the docs; byte-scan new SQL and seed text for non-ASCII outside comments.
- [ ] **Step 3: Commit** — `docs: super-lot piece 5 -- data model 3.6, status entry, build notes`.
