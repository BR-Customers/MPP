# Die Cast Shift Reconciliation -- SQL Layer Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the database layer that lets a team lead reconcile one past shift x press x die against its press sheet -- add missing production, move entries filed against the wrong shift, and close numeric gaps in either direction -- with the live die cast procs refactored onto shared write workers.

**Architecture:** Five write blocks are lifted out of four live procs into internal "worker" procs (no result set, no transaction -- the `Oee.ShiftOverride_Restamp` pattern), plus one new restamp worker. The live procs keep their checks and call the workers; a new `Workorder.DieCastShiftReconciliation_Save` has its own checks and calls the same workers inside one transaction. New single-result-set read procs feed the screen, which is built in Plan 2.

**Tech Stack:** SQL Server 2022, T-SQL repeatable + versioned migrations, the in-repo `test.*` assertion framework (`sql/tests/helpers/0001_test_framework.sql`), `sql/tests/Run-Tests.ps1`.

**Spec:** `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md` (review items settled 2026-09-22). **Plan 2** (Ignition screen, named queries, entity script, dashboard tile) is written after this plan lands.

## Global Constraints

- Migration number **`0097`** (`0096` is the trim partial checkpoint, committed `eb35fe95`). Re-check `sql/migrations/versioned/` before creating the file; take the next free number if `0097` is gone and rename every reference in this plan.
- Follow `sql/scripts/_TEMPLATE_stored_procedure.sql` and CLAUDE.md: `RAISERROR` not `THROW`; no `OUTPUT` parameters; mutation procs end every path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId`; all rejecting validations run **before** `BEGIN TRANSACTION`; `CATCH` is the only `ROLLBACK` site.
- **Workers** emit no result set, own no transaction, have no `TRY/CATCH`, and never `ROLLBACK`. Errors propagate to the caller's `CATCH`.
- `EXEC` arguments are literals or `@variables` only -- never inline `CAST`, arithmetic or `CASE`.
- `.sql` files are **ASCII-only** (sqlcmd reads them in the Windows codepage). Non-ASCII characters in stored text come from `NCHAR(n)` / `Audit.ufn_MidDot()` at runtime.
- Timestamps: event columns are UTC. `Oee.Shift.ActualStart/ActualEnd` are **Eastern wall clock** (OI-38) -- convert with `CAST(x AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))`. Read procs return Eastern: `CAST(x AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- Language in operator-facing text: **LTT** is the ticket number, **LOT** is the record. Never "tag" or "basket" in new strings. A die is named by its name, then `Asset # <Tools.Tool.Code>`.
- `Workorder.RejectEvent` is partitioned: any new index on it must be created `ON ps_MonthlyUtc(RecordedAt)`.
- Tests run on a **throwaway database**, never `MPP_MES_Dev` and never the shared `MPP_MES_Test` (other sessions reset it): `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "<filter>"`. The runner resets the database with `-SkipDemoSeed` on every run. Exit code 1 with 0 failures means a file's sqlcmd errored -- read the output.
- Commit to `jacques/working`. Stage explicit paths only (never `git add -u` / `-A`; other sessions share this working tree). No `Co-Authored-By` trailer (CLAUDE.md).

## File Structure

**Create -- migration and tests**
- `sql/migrations/versioned/0097_diecast_shift_reconciliation.sql` -- tables, columns, CHECK, code rows.
- `sql/tests/helpers/0097_fixture_diecast_reconciliation.sql` -- fixture procs shared by the new test files.
- `sql/tests/0097_DieCast_Reconciliation/010_Schema.sql`
- `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql`
- `sql/tests/0097_DieCast_Reconciliation/030_Functions.sql`
- `sql/tests/0097_DieCast_Reconciliation/040_Reads.sql`
- `sql/tests/0097_DieCast_Reconciliation/050_Landing.sql`
- `sql/tests/0097_DieCast_Reconciliation/060_Save_Refusals.sql`
- `sql/tests/0097_DieCast_Reconciliation/070_Save_Writes.sql`

**Create -- workers (one responsibility each)**
- `sql/migrations/repeatable/R__Workorder_DieCastCredit_Write.sql` -- one contribution row, optionally applied to the LOT.
- `sql/migrations/repeatable/R__Workorder_DieCastScrap_Write.sql` -- reject rows for explicit LOT/cavity lines and die-wide fan-out.
- `sql/migrations/repeatable/R__Lots_DieCastLot_Mint.sql` -- creates an Open die cast LOT.
- `sql/migrations/repeatable/R__Lots_DieCastLot_ReleaseMove.sql` -- Open -> Good, moved to storage.
- `sql/migrations/repeatable/R__Lots_Lot_ApplyPieceCountCorrection.sql` -- the audited count change.
- `sql/migrations/repeatable/R__Workorder_DieCastEntry_Restamp.sql` -- moves rows to another shift and records the move.

**Create -- functions and procs**
- `sql/migrations/repeatable/R__Lots_ufn_DieCastLotCountLock.sql` -- is a LOT's count settled downstream, and why.
- `sql/migrations/repeatable/R__Workorder_ufn_DieCastShiftStamp.sql` -- stale guard token.
- `sql/migrations/repeatable/R__Oee_ufn_ShiftNeighbours.sql` -- closed shifts within N instances.
- `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_GetHeader.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListEntries.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListLots.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListRejects.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListMoveTargets.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListShifts.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastShift_ListUnreconciled.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastReconciliationReason_List.sql`
- `sql/migrations/repeatable/R__Lots_DieCastLot_ResolveLtt.sql`
- `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql`

**Modify**
- `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql` -- v3.1, calls credit + scrap workers.
- `sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql` -- v2.3, calls credit, scrap, release-move workers.
- `sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql` -- v1.2, calls the mint worker.
- `sql/migrations/repeatable/R__Lots_Lot_RectifyPieceCount.sql` -- v1.1, calls the correction worker.
- `sql/migrations/repeatable/R__Oee_ShiftOverride_Restamp.sql` -- v1.1, skips reconciliation and moved rows.
- `sql/migrations/repeatable/R__Workorder_DieCastCounterAnchorReason_List.sql` -- v1.1, hides the reconciliation reason.
- `sql/tests/0062_Oee_ShiftAttribution/030_restamp.sql` -- adds the exclusion rows.
- `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md` -- §14 amendments.
- `MPP_MES_DATA_MODEL.md`, `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` (regenerated), `PROJECT_STATUS.md`.

---

### Task 1: Record the spec amendments

Writing this plan against the code surfaced twelve points the spec did not settle. Record them before any code so the spec stays the authority.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md` (append a section at the end)

- [ ] **Step 1: Append §14 to the spec**

Append exactly this after the last line of the spec:

```markdown

---

## 14. Amendments from the implementation plan (2026-09-22)

Found while writing `docs/superpowers/plans/2026-09-22-diecast-shift-reconciliation-sql.md`
against the code. Where these disagree with earlier sections, these win.

| # | Amendment | Why |
|---|---|---|
| A1 | Backfilled rows are stamped **one second before** the shift's `ActualEnd` (UTC), not at it. | Shift windows are `[start, end)`: a row stamped exactly at the end resolves to the *next* shift. |
| A2 | `Oee.ShiftOverride_Restamp` **skips** contribution rows that carry a `ReconciliationId` or appear in `Workorder.DieCastReconciliationMove`. | The restamp re-derives the shift from `EventAt`. A moved entry keeps its real `EventAt` (09-17 09:35), so the next override on that press would silently move it back. The team lead's decision wins over the time-based resolver. |
| A3 | The shift's counter reading is set by **an anchor written at save** (`DieCastCounterAnchor`, new reason `ShiftReconciliation`, `EventAt` = the save time), up or down. Reconciliation credit rows carry **no** reading. | The latest anchor floors both watermarks and discards earlier readings -- one mechanism for increases and decreases. The new reason is hidden from the operators' *Fix counter* list. |
| A4 | Moves cover **contribution and reject rows** only. | Anchors are counter resets; filed against the wrong shift is not a case the evidence showed. |
| A5 | **No `@CountsJson`.** Every released, not-locked LOT with a gap has its count corrected; the confirmation lists them. | The state decides, not the team lead -- one fewer decision on the critical path. |
| A6 | The single `_Load` proc is replaced by `_GetHeader`, `_ListEntries`, `_ListLots`, `_ListRejects`, `_ListMoveTargets`, plus `Lots.DieCastLot_ResolveLtt`. | One result set per proc (FDS-11-011). |
| A7 | Reject and warm-up gaps are computed **per active cavity**. A reject line's amount must divide evenly across the cavities it covers ("All" = every active cavity; a part = that part's cavities), else it is refused with a plain message. | The recorded rows are per cavity; so is the comparison. |
| A8 | Header columns are `ActualTotalShots`, `ActualGoodShots`, `ActualWarmUpShots` (were `Sheet*`). | "Actual, never Sheet" (2026-09-21). |
| A9 | A new LOT's part is **not** required to have a published Die Cast route. | A configuration gap must not stop production that happened from being recorded -- the `0084` D4 principle. |
| A10 | The count lock also covers LOTs whose status blocks production (Hold, Scrap). | `Lot_RectifyPieceCount` refuses them too. |
| A11 | LOT or reject lines require the three actual totals; a save with only moves does not. | The blocking checks (§7.4) cannot run without them. |
| A12 | The six workers are named `Workorder.DieCastCredit_Write`, `Workorder.DieCastScrap_Write`, `Lots.DieCastLot_Mint`, `Lots.DieCastLot_ReleaseMove`, `Lots.Lot_ApplyPieceCountCorrection`, `Workorder.DieCastEntry_Restamp`. | Final names. |
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md
git commit -m "docs(spec): shift reconciliation -- amendments found while planning the SQL layer"
```

---

### Task 2: Migration 0097 -- tables, columns, codes

**Files:**
- Create: `sql/migrations/versioned/0097_diecast_shift_reconciliation.sql`
- Modify: `sql/migrations/repeatable/R__Workorder_DieCastCounterAnchorReason_List.sql`
- Test: `sql/tests/0097_DieCast_Reconciliation/010_Schema.sql`

**Interfaces:**
- Produces: tables `Workorder.DieCastReconciliationReason (Id, Code, Name, RequiresNote, SortOrder)`, `Workorder.DieCastShiftReconciliation (Id, ShiftId, CellLocationId, ToolId, ReasonId, Note, ActualTotalShots, ActualGoodShots, ActualWarmUpShots, DieShotCountBefore, DieShotCountAfter, AppUserId, TerminalLocationId, CreatedAt)`, `Workorder.DieCastReconciliationMove (Id, ReconciliationId, LogEntityTypeId, EntityId, FromShiftId, ToShiftId)`; columns `DieCastContribution.ReconciliationId`, `RejectEvent.ReconciliationId`, `RejectEvent.ApprovedByUserId`, `DieCastCounterAnchor.ReconciliationId`; reason codes `MissedEntry`, `WrongShift`, `WrongNumbers`, `Other`; anchor reason `ShiftReconciliation`; `LogEntityType` codes `DieCastContribution`, `DieCastShiftReconciliation`; `LogEventType` codes `DieCastShiftReconciled`, `DieCastEntryMoved`.

- [ ] **Step 1: Write the failing schema test**

Create `sql/tests/0097_DieCast_Reconciliation/010_Schema.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/010_Schema.sql
-- Migration 0097 -- die cast shift reconciliation (spec 2026-09-21 sec 4 + sec 14).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/010_Schema.sql';
GO

DECLARE @v NVARCHAR(50);

SET @v = CAST((SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
               WHERE s.name = N'Workorder' AND t.name IN (N'DieCastReconciliationReason', N'DieCastShiftReconciliation', N'DieCastReconciliationMove')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] three new tables exist', @Expected = N'3', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationReason) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] four reconciliation reasons seeded', @Expected = N'4', @Actual = @v;

SET @v = (SELECT CAST(RequiresNote AS NVARCHAR(50)) FROM Workorder.DieCastReconciliationReason WHERE Code = N'Other');
EXEC test.Assert_IsEqual @TestName = N'[0097] Other requires a note', @Expected = N'1', @Actual = @v;

SET @v = (SELECT Name FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
EXEC test.Assert_IsEqual @TestName = N'[0097] WrongNumbers says "actual", never "sheet"',
    @Expected = N'Recorded numbers did not match actual', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM sys.columns WHERE
      (object_id = OBJECT_ID(N'Workorder.DieCastContribution') AND name = N'ReconciliationId')
   OR (object_id = OBJECT_ID(N'Workorder.RejectEvent')         AND name IN (N'ReconciliationId', N'ApprovedByUserId'))
   OR (object_id = OBJECT_ID(N'Workorder.DieCastCounterAnchor') AND name = N'ReconciliationId')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] four new columns on existing tables', @Expected = N'4', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
               WHERE i.object_id = OBJECT_ID(N'Workorder.RejectEvent') AND i.index_id > 0 AND ds.name <> N'ps_MonthlyUtc') AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] every RejectEvent index still ON ps_MonthlyUtc', @Expected = N'0', @Actual = @v;

SET @v = (SELECT Code FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'ShiftReconciliation');
EXEC test.Assert_IsEqual @TestName = N'[0097] anchor reason ShiftReconciliation exists', @Expected = N'ShiftReconciliation', @Actual = @v;

CREATE TABLE #AR (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), RequiresNote BIT);
INSERT INTO #AR EXEC Workorder.DieCastCounterAnchorReason_List;
SET @v = CAST((SELECT COUNT(*) FROM #AR WHERE Code = N'ShiftReconciliation') AS NVARCHAR(50));
DROP TABLE #AR;
EXEC test.Assert_IsEqual @TestName = N'[0097] Fix counter list does not offer ShiftReconciliation', @Expected = N'0', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Audit.LogEntityType WHERE Code IN (N'DieCastContribution', N'DieCastShiftReconciliation')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] two audit entity types', @Expected = N'2', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Audit.LogEventType WHERE Code IN (N'DieCastShiftReconciled', N'DieCastEntryMoved')) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[0097] two audit event types', @Expected = N'2', @Actual = @v;
GO

-- The CHECK: a negative credit is legal ONLY on a reconciliation row. Live paths stay non-negative.
DECLARE @Lot BIGINT = (SELECT TOP 1 Id FROM Lots.Lot ORDER BY Id);
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift ORDER BY Id);
DECLARE @Err NVARCHAR(4000) = N'(no error)';
IF @Lot IS NOT NULL AND @Shift IS NOT NULL
BEGIN
    BEGIN TRY
        BEGIN TRAN;
        INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt)
        VALUES (@Lot, @Shift, -1, 1, SYSUTCDATETIME());
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Err = ERROR_MESSAGE();
    END CATCH
    EXEC test.Assert_Contains @TestName = N'[0097] negative credit without a reconciliation is refused',
        @HaystackStr = @Err, @NeedleStr = N'CK_DieCastContribution_DeltaNonNeg';
END
GO

EXEC test.EndTestFile;
GO
```

The CHECK assertion is skipped on a database with no LOT or shift yet; `020_Workers.sql` proves the other half (a negative row *with* a reconciliation id is accepted) against its own fixture.

- [ ] **Step 2: Run it to see it fail**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
Expected: the `[0097]` assertions FAIL (tables and codes do not exist yet).

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0097_diecast_shift_reconciliation.sql`:

```sql
-- ============================================================
-- Migration:   0097_diecast_shift_reconciliation.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-22
-- Description: Die cast shift reconciliation. Spec:
--              docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md
--              (sec 4, amendments sec 14).
--
--              1. Workorder.DieCastReconciliationReason -- why a team lead is
--                 reconciling a past shift (shaped like DieCastVarianceReason).
--              2. Workorder.DieCastShiftReconciliation -- one header row per
--                 save. It is the late-entry marker, the audit anchor, and what
--                 clears the dashboard's "not reconciled" signal.
--              3. Workorder.DieCastReconciliationMove -- the durable record of
--                 every row moved to another shift (the ShiftId is re-stamped
--                 in place, as Oee.ShiftOverride_Restamp does).
--              4. ReconciliationId on DieCastContribution, RejectEvent and
--                 DieCastCounterAnchor; RejectEvent.ApprovedByUserId (the press
--                 sheet's QAS column).
--              5. CK_DieCastContribution_DeltaNonNeg relaxed: a negative credit
--                 is legal only on a reconciliation row (compensating rows,
--                 spec D13). Live paths still cannot write one.
--              6. Anchor reason ShiftReconciliation (amendment A3).
--              7. Audit vocabulary.
--
--              RejectEvent is partitioned: the new columns are nullable with
--              no default (metadata-only), and its new filtered index is
--              created ON ps_MonthlyUtc(RecordedAt) so sliding-window TRUNCATE
--              retention (B2) keeps working.
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0097_diecast_shift_reconciliation')
BEGIN PRINT 'Migration 0097 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. reasons ----
IF OBJECT_ID(N'Workorder.DieCastReconciliationReason', N'U') IS NULL
    CREATE TABLE Workorder.DieCastReconciliationReason (
        Id           BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_DieCastReconciliationReason PRIMARY KEY,
        Code         NVARCHAR(50)  NOT NULL,
        Name         NVARCHAR(100) NOT NULL,
        RequiresNote BIT           NOT NULL CONSTRAINT DF_DCRR_RequiresNote DEFAULT 0,
        SortOrder    INT           NOT NULL CONSTRAINT DF_DCRR_SortOrder DEFAULT 0,
        CONSTRAINT UQ_DieCastReconciliationReason_Code UNIQUE (Code)
    );
GO
MERGE Workorder.DieCastReconciliationReason AS t
USING (VALUES
    (N'MissedEntry',  N'Shift not entered',                     0, 1),
    (N'WrongShift',   N'Entered against the wrong shift',       0, 2),
    (N'WrongNumbers', N'Recorded numbers did not match actual', 0, 3),
    (N'Other',        N'Other',                                 1, 4)
) AS s (Code, Name, RequiresNote, SortOrder)
ON t.Code = s.Code
WHEN MATCHED THEN UPDATE SET t.Name = s.Name, t.RequiresNote = s.RequiresNote, t.SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (Code, Name, RequiresNote, SortOrder) VALUES (s.Code, s.Name, s.RequiresNote, s.SortOrder);
GO

-- ---- 2. header ----
IF OBJECT_ID(N'Workorder.DieCastShiftReconciliation', N'U') IS NULL
    CREATE TABLE Workorder.DieCastShiftReconciliation (
        Id                 BIGINT         NOT NULL IDENTITY(1,1) CONSTRAINT PK_DieCastShiftReconciliation PRIMARY KEY,
        ShiftId            BIGINT         NOT NULL CONSTRAINT FK_DCSR_Shift    REFERENCES Oee.Shift(Id),
        CellLocationId     BIGINT         NOT NULL CONSTRAINT FK_DCSR_Cell     REFERENCES Location.Location(Id),
        ToolId             BIGINT         NOT NULL CONSTRAINT FK_DCSR_Tool     REFERENCES Tools.Tool(Id),
        ReasonId           BIGINT         NOT NULL CONSTRAINT FK_DCSR_Reason   REFERENCES Workorder.DieCastReconciliationReason(Id),
        Note               NVARCHAR(500)  NULL,
        ActualTotalShots   INT            NULL,
        ActualGoodShots    INT            NULL,
        ActualWarmUpShots  INT            NULL,
        DieShotCountBefore INT            NOT NULL,
        DieShotCountAfter  INT            NOT NULL,
        AppUserId          BIGINT         NOT NULL CONSTRAINT FK_DCSR_AppUser  REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT         NULL     CONSTRAINT FK_DCSR_Terminal REFERENCES Location.Location(Id),
        CreatedAt          DATETIME2(3)   NOT NULL CONSTRAINT DF_DCSR_CreatedAt DEFAULT SYSUTCDATETIME()
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastShiftReconciliation_ShiftCell')
    CREATE INDEX IX_DieCastShiftReconciliation_ShiftCell
        ON Workorder.DieCastShiftReconciliation (ShiftId, CellLocationId) INCLUDE (ToolId, AppUserId, CreatedAt);
GO

-- ---- 3. moves ----
IF OBJECT_ID(N'Workorder.DieCastReconciliationMove', N'U') IS NULL
    CREATE TABLE Workorder.DieCastReconciliationMove (
        Id               BIGINT NOT NULL IDENTITY(1,1) CONSTRAINT PK_DieCastReconciliationMove PRIMARY KEY,
        ReconciliationId BIGINT NOT NULL CONSTRAINT FK_DCRM_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id),
        LogEntityTypeId  BIGINT NOT NULL CONSTRAINT FK_DCRM_EntityType     REFERENCES Audit.LogEntityType(Id),
        EntityId         BIGINT NOT NULL,
        FromShiftId      BIGINT NOT NULL CONSTRAINT FK_DCRM_FromShift      REFERENCES Oee.Shift(Id),
        ToShiftId        BIGINT NOT NULL CONSTRAINT FK_DCRM_ToShift        REFERENCES Oee.Shift(Id)
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastReconciliationMove_Entity')
    CREATE INDEX IX_DieCastReconciliationMove_Entity ON Workorder.DieCastReconciliationMove (LogEntityTypeId, EntityId);
GO

-- ---- 4. columns on existing tables ----
IF COL_LENGTH('Workorder.DieCastContribution', 'ReconciliationId') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD ReconciliationId BIGINT NULL
        CONSTRAINT FK_DieCastContribution_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id);
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ReconciliationId') IS NULL
    ALTER TABLE Workorder.RejectEvent ADD ReconciliationId BIGINT NULL
        CONSTRAINT FK_RejectEvent_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id);
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ApprovedByUserId') IS NULL
    ALTER TABLE Workorder.RejectEvent ADD ApprovedByUserId BIGINT NULL
        CONSTRAINT FK_RejectEvent_ApprovedBy REFERENCES Location.AppUser(Id);
GO
IF COL_LENGTH('Workorder.DieCastCounterAnchor', 'ReconciliationId') IS NULL
    ALTER TABLE Workorder.DieCastCounterAnchor ADD ReconciliationId BIGINT NULL
        CONSTRAINT FK_DieCastCounterAnchor_Reconciliation REFERENCES Workorder.DieCastShiftReconciliation(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastContribution_Reconciliation')
    CREATE INDEX IX_DieCastContribution_Reconciliation
        ON Workorder.DieCastContribution (ReconciliationId) WHERE ReconciliationId IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_RejectEvent_Reconciliation')
    CREATE INDEX IX_RejectEvent_Reconciliation
        ON Workorder.RejectEvent (ReconciliationId, RecordedAt) WHERE ReconciliationId IS NOT NULL
        ON ps_MonthlyUtc(RecordedAt);
GO

-- ---- 5. the CHECK (spec D13) ----
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_DieCastContribution_DeltaNonNeg')
    ALTER TABLE Workorder.DieCastContribution DROP CONSTRAINT CK_DieCastContribution_DeltaNonNeg;
GO
ALTER TABLE Workorder.DieCastContribution WITH CHECK ADD CONSTRAINT CK_DieCastContribution_DeltaNonNeg
    CHECK (PieceDelta >= 0 OR ReconciliationId IS NOT NULL);
GO

-- ---- 6. anchor reason (amendment A3) ----
IF NOT EXISTS (SELECT 1 FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'ShiftReconciliation')
    INSERT INTO Workorder.DieCastCounterAnchorReason (Code, Name, Description, SortOrder)
    VALUES (N'ShiftReconciliation', N'Set by a shift reconciliation',
            N'A team lead reconciled the shift against its press sheet and declared its actual total shots. Not offered on the Fix counter dialog.',
            99);
GO

-- ---- 7. audit vocabulary ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'DieCastContribution')
BEGIN
    DECLARE @e1 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@e1, N'DieCastContribution', N'Die Cast Contribution', N'One credit of good pieces to a die cast LOT in a shift.');
END
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEntityType WHERE Code = N'DieCastShiftReconciliation')
BEGIN
    DECLARE @e2 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEntityType);
    INSERT INTO Audit.LogEntityType (Id, Code, Name, Description)
    VALUES (@e2, N'DieCastShiftReconciliation', N'Die Cast Shift Reconciliation', N'A team lead reconciling one past shift x press x die against its press sheet.');
END
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'DieCastShiftReconciled')
BEGIN
    DECLARE @v1 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@v1, N'DieCastShiftReconciled', N'Die Cast Shift Reconciled', N'A past shift was reconciled: production added, moved or corrected after the fact.');
END
GO
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'DieCastEntryMoved')
BEGIN
    DECLARE @v2 BIGINT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@v2, N'DieCastEntryMoved', N'Die Cast Entry Moved', N'Recorded die cast rows were re-filed against the shift they belong to.');
END
GO

-- ---- 8. record ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0097_diecast_shift_reconciliation')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0097_diecast_shift_reconciliation',
            N'Die cast shift reconciliation: reason code table, header and move tables; ReconciliationId on DieCastContribution/RejectEvent/DieCastCounterAnchor; RejectEvent.ApprovedByUserId; negative credits allowed on reconciliation rows only; anchor reason ShiftReconciliation; audit vocabulary.');
GO
PRINT 'Migration 0097 (diecast_shift_reconciliation) applied.';
GO
```

- [ ] **Step 4: Hide the reconciliation reason from Fix counter**

In `sql/migrations/repeatable/R__Workorder_DieCastCounterAnchorReason_List.sql`, change the header version and the query:

Replace:
```sql
-- Version:     1.0
```
with:
```sql
-- Version:     1.1
-- Change:      v1.1 (2026-09-22) -- ShiftReconciliation (migration 0097) is
--              written only by Workorder.DieCastShiftReconciliation_Save and
--              is not an operator's reason, so the Fix counter list omits it.
```
Replace:
```sql
    FROM Workorder.DieCastCounterAnchorReason r
    ORDER BY r.SortOrder, r.Name;
```
with:
```sql
    FROM Workorder.DieCastCounterAnchorReason r
    WHERE r.Code <> N'ShiftReconciliation'
    ORDER BY r.SortOrder, r.Name;
```

- [ ] **Step 5: Run the test to see it pass**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
Expected: every `[0097]` assertion PASSES, summary reports 0 failed.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/versioned/0097_diecast_shift_reconciliation.sql sql/migrations/repeatable/R__Workorder_DieCastCounterAnchorReason_List.sql sql/tests/0097_DieCast_Reconciliation/010_Schema.sql
git commit -m "feat(sql): 0097 -- die cast shift reconciliation tables, columns and codes"
```

---

### Task 3: Test fixture + regression baseline

The worker extraction in Tasks 4-8 must not change live behaviour. Record the full suite's result **before** touching a live proc, so any later failure is unambiguously this work.

**Files:**
- Create: `sql/tests/helpers/0097_fixture_diecast_reconciliation.sql`

**Interfaces:**
- Produces (test-only): `test.ufn_RC(@Key NVARCHAR(20)) RETURNS BIGINT` for keys `Tool`, `CavA`, `CavB`, `ItemA`, `ItemB`, `Cell`, `Usr`, `Usr2`, `S1`..`S5`, `Whse`; procs `test.DieCastRecon_Setup`, `test.DieCastRecon_Cleanup`, `test.DieCastRecon_SeedLot @Ltt, @CavKey, @StatusCode = 'Open'`, `test.DieCastRecon_SeedCredit @Ltt, @ShiftKey, @Pieces, @Reading = NULL, @AtUtc, @UserId = NULL`, `test.DieCastRecon_SeedReject @ShiftKey, @CavKey, @DefectCode, @Qty, @AtUtc, @UserId = NULL`.
- Fixture facts every later test relies on: die `RC-DIE` ("Reconciliation Test Die", `ShotCount` 10000) with two active cavities `a` (part `ItemA`) and `b` (part `ItemB`), mounted on the first `DieCastMachine` from 2020-01-01 to 2020-02-01 (a *closed* assignment, so it never collides with another suite's live mount); five consecutive closed shifts in Eastern wall clock: **S1** 2020-01-06 07:00-15:00, **S2** 15:00-23:00, **S3** 23:00-2020-01-07 07:00, **S4** 2020-01-07 07:00-15:00, **S5** 15:00-23:00. January is EST (UTC-5): S1 = 12:00-20:00 UTC, S4 = 2020-01-07 12:00-20:00 UTC, S5 ends 2020-01-08 04:00 UTC.

- [ ] **Step 1: Write the fixture helper**

Create `sql/tests/helpers/0097_fixture_diecast_reconciliation.sql`:

```sql
-- =============================================
-- Fixture for sql/tests/0097_DieCast_Reconciliation/*.
-- Deployed by Run-Tests.ps1 step 2 (helpers). Self-contained: builds its own
-- die, cavities, mount and shifts in January 2020 so no other suite's shifts,
-- mounts or LOTs can interleave with it. The mount is CLOSED (ReleasedAt set)
-- because UQ_ToolAssignment_ActiveCell allows one live die per press.
-- =============================================
CREATE OR ALTER FUNCTION test.ufn_RC (@Key NVARCHAR(20))
RETURNS BIGINT
AS
BEGIN
    RETURN CASE @Key
        WHEN N'Tool'  THEN (SELECT Id FROM Tools.Tool WHERE Code = N'RC-DIE')
        WHEN N'CavA'  THEN (SELECT tc.Id FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'a')
        WHEN N'CavB'  THEN (SELECT tc.Id FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'b')
        WHEN N'ItemA' THEN (SELECT tc.ItemId FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'a')
        WHEN N'ItemB' THEN (SELECT tc.ItemId FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'RC-DIE' AND tc.CavityCode = N'b')
        WHEN N'Cell'  THEN (SELECT TOP 1 ta.CellLocationId FROM Tools.ToolAssignment ta JOIN Tools.Tool t ON t.Id = ta.ToolId WHERE t.Code = N'RC-DIE')
        WHEN N'Usr'   THEN (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id)
        WHEN N'Usr2'  THEN (SELECT TOP 1 Id FROM Location.AppUser WHERE Id > (SELECT MIN(Id) FROM Location.AppUser) ORDER BY Id)
        WHEN N'Whse'  THEN (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id)
        WHEN N'S1'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 1)
        WHEN N'S2'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 2)
        WHEN N'S3'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 3)
        WHEN N'S4'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 4)
        WHEN N'S5'    THEN (SELECT Id FROM (SELECT Id, ROW_NUMBER() OVER (ORDER BY ActualStart) AS rn FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE') x WHERE rn = 5)
    END;
END;
GO

CREATE OR ALTER PROCEDURE test.DieCastRecon_Cleanup
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Tool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RC-DIE');
    DECLARE @Lots TABLE (Id BIGINT PRIMARY KEY);
    INSERT INTO @Lots (Id) SELECT Id FROM Lots.Lot WHERE ToolId = @Tool OR LotName LIKE N'99700%';

    DELETE m FROM Workorder.DieCastReconciliationMove m
      JOIN Workorder.DieCastShiftReconciliation h ON h.Id = m.ReconciliationId WHERE h.ToolId = @Tool;
    DELETE FROM Workorder.DieCastCounterAnchor WHERE ToolId = @Tool;
    DELETE FROM Workorder.DieCastContribution  WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Workorder.RejectEvent          WHERE ToolId = @Tool OR LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool;
    DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Lots) OR DescendantLotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotGenealogy        WHERE ParentLotId  IN (SELECT Id FROM @Lots) OR ChildLotId      IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotAttributeChange  WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotEventLog         WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotLabel            WHERE LotId IN (SELECT Id FROM @Lots) OR ParentLotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotMovement         WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.LotStatusHistory    WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.PauseEvent          WHERE LotId IN (SELECT Id FROM @Lots);
    DELETE FROM Lots.Lot                 WHERE Id IN (SELECT Id FROM @Lots);
    DELETE FROM Tools.ToolCavity     WHERE ToolId = @Tool;
    DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
    DELETE FROM Tools.Tool           WHERE Id = @Tool;
    DELETE FROM Oee.Shift         WHERE Remarks = N'RC-FIXTURE';
    DELETE FROM Oee.ShiftSchedule WHERE Name = N'RC-FIXTURE-SCHED';
END;
GO

CREATE OR ALTER PROCEDURE test.DieCastRecon_Setup
AS
BEGIN
    SET NOCOUNT ON;
    EXEC test.DieCastRecon_Cleanup;

    DECLARE @Usr   BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
    DECLARE @Cell  BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                             JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
                             WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
    DECLARE @ItemA BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
    DECLARE @ItemB BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id > @ItemA ORDER BY Id);

    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId, DeprecatedAt)
    VALUES (N'RC-FIXTURE-SCHED', '07:00:00', '15:00:00', 127, '2020-01-01', @Usr, '2020-01-01');
    DECLARE @Sched BIGINT = SCOPE_IDENTITY();

    -- Eastern wall clock (OI-38). Deprecated schedule: the shift RESOLVER
    -- (Oee.ufn_ShiftIdForInstant) must not start using it for other suites.
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks) VALUES
        (@Sched, '2020-01-06T07:00:00', '2020-01-06T15:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-06T15:00:00', '2020-01-06T23:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-06T23:00:00', '2020-01-07T07:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-07T07:00:00', '2020-01-07T15:00:00', N'RC-FIXTURE'),
        (@Sched, '2020-01-07T15:00:00', '2020-01-07T23:00:00', N'RC-FIXTURE');

    INSERT INTO Tools.Tool (Code, Name, ToolTypeId, StatusCodeId, CreatedByUserId, ShotCount)
    VALUES (N'RC-DIE', N'Reconciliation Test Die',
            (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id),
            (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), @Usr, 10000);
    DECLARE @Tool BIGINT = SCOPE_IDENTITY();

    DECLARE @Active BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedByUserId)
    VALUES (@Tool, N'a', @Active, N'RC cavity a', @ItemA, @Usr),
           (@Tool, N'b', @Active, N'RC cavity b', @ItemB, @Usr);

    INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, ReleasedAt, AssignedByUserId, ReleasedByUserId)
    VALUES (@Tool, @Cell, '2020-01-01T00:00:00', '2020-02-01T00:00:00', @Usr, @Usr);
END;
GO

-- A die cast LOT on the fixture die, inserted directly (the live Open proc
-- requires the die to be mounted NOW). 'Good' also writes the Open->Good
-- history row that Lots.ufn_DieCastLotCountLock reads as "released".
CREATE OR ALTER PROCEDURE test.DieCastRecon_SeedLot
    @Ltt NVARCHAR(50), @CavKey NVARCHAR(10), @StatusCode NVARCHAR(20) = N'Open'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cav BIGINT = test.ufn_RC(@CavKey);
    DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
    DECLARE @Loc BIGINT = CASE WHEN @StatusCode = N'Open' THEN test.ufn_RC(N'Cell') ELSE test.ufn_RC(N'Whse') END;
    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                          CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
    SELECT @Ltt, tc.ItemId, (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured'),
           (SELECT Id FROM Lots.LotStatusCode WHERE Code = @StatusCode), 0, 0, @Loc, tc.ToolId, tc.Id,
           '2020-01-06T12:00:00', @Usr
    FROM Tools.ToolCavity tc WHERE tc.Id = @Cav;
    IF @StatusCode <> N'Open'
        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, ChangedAt)
        SELECT l.Id, (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open'), l.LotStatusId, N'fixture release', @Usr, '2020-01-06T13:00:00'
        FROM Lots.Lot l WHERE l.LotName = @Ltt;
END;
GO

-- A live-style credit: the contribution row plus the LOT count, as
-- DieCastShiftOutput_Record would have written it at @AtUtc.
CREATE OR ALTER PROCEDURE test.DieCastRecon_SeedCredit
    @Ltt NVARCHAR(50), @ShiftKey NVARCHAR(10), @Pieces INT, @Reading INT = NULL,
    @AtUtc DATETIME2(3), @UserId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = @Ltt);
    INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId)
    SELECT @Lot, test.ufn_RC(@ShiftKey), @Pieces, ISNULL(@UserId, test.ufn_RC(N'Usr')), @AtUtc,
           test.ufn_RC(N'Cell'), @Reading, l.ToolCavityId
    FROM Lots.Lot l WHERE l.Id = @Lot;
    UPDATE Lots.Lot SET PieceCount = PieceCount + @Pieces, InventoryAvailable = InventoryAvailable + @Pieces WHERE Id = @Lot;
END;
GO

-- A live-style scrap row against a cavity (no LOT), as the die-wide fan-out writes it.
CREATE OR ALTER PROCEDURE test.DieCastRecon_SeedReject
    @ShiftKey NVARCHAR(10), @CavKey NVARCHAR(10), @DefectCode NVARCHAR(20), @Qty INT,
    @AtUtc DATETIME2(3), @UserId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                       DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
    SELECT NULL, NULL, tc.ItemId, tc.ToolId, tc.Id, test.ufn_RC(@ShiftKey), test.ufn_RC(N'Cell'),
           (SELECT Id FROM Quality.DefectCode WHERE Code = @DefectCode), @Qty, NULL, N'fixture',
           ISNULL(@UserId, test.ufn_RC(N'Usr')), NULL, @AtUtc
    FROM Tools.ToolCavity tc WHERE tc.Id = test.ufn_RC(@CavKey);
END;
GO
```

- [ ] **Step 2: Run the full suite and record the baseline**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter ""`
Expected: the summary's passed/failed counts. **Write them down** (e.g. in the commit message). Any failure here predates this plan -- note which files; they are not yours to fix, but they are the baseline every later full run is compared with. (PROJECT_STATUS 2026-09-17 notes four `0022` die-cast files that error in fixture setup on a fresh test DB; check whether they still do.)

- [ ] **Step 3: Commit**

```bash
git add sql/tests/helpers/0097_fixture_diecast_reconciliation.sql
git commit -m "test(sql): shift reconciliation fixture; full-suite baseline <passed>/<failed> before the worker extraction"
```

---

### Task 4: Worker `Workorder.DieCastCredit_Write` + live procs onto it

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCastCredit_Write.sql`
- Modify: `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql:299-314` (the `IF @Delta > 0` block) and header
- Modify: `sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql:225-247` (the contribution block) and header
- Test: `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql` (created here; later tasks add sections)

**Interfaces:**
- Produces: `Workorder.DieCastCredit_Write @LotId BIGINT, @ShiftId BIGINT, @PieceDelta INT, @CounterReading INT = NULL, @CellLocationId BIGINT = NULL, @ApplyToLot BIT = 1, @VarianceReasonId BIGINT = NULL, @VarianceNote NVARCHAR(500) = NULL, @ReconciliationId BIGINT = NULL, @EventAt DATETIME2(3) = NULL, @AuditLocationId BIGINT = NULL, @AuditSuffix NVARCHAR(100) = N'', @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL`. Writes one `DieCastContribution` row (cavity taken from the LOT); when `@ApplyToLot = 1` and the delta is non-zero, moves `PieceCount` and `InventoryAvailable` by it; writes one `DieCastPieceContributed` LOT audit row "`<LTT> · Die Cast · Added <n> pc<suffix>`". No result set, no transaction.

- [ ] **Step 1: Write the failing worker test**

Create `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/020_Workers.sql
-- The six write workers (spec sec 5.1, amendment A12), called directly.
-- The fixture is rebuilt once at the top; sections run in order.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/020_Workers.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700101', @CavKey = N'CavA';
GO

-- ---- DieCastCredit_Write ----
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700101');
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @CavA NVARCHAR(20) = CAST(test.ufn_RC(N'CavA') AS NVARCHAR(20));
DECLARE @v NVARCHAR(200), @Want NVARCHAR(200);

EXEC Workorder.DieCastCredit_Write @LotId = @Lot, @ShiftId = @S1, @PieceDelta = 40, @CounterReading = 40,
    @CellLocationId = @Cell, @AppUserId = @Usr;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] applied to the LOT by default', @Expected = N'40', @Actual = @v;
SET @v = (SELECT CONCAT(ToolCavityId, N'|', ShotCounterReading, N'|', CellLocationId) FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 40);
SET @Want = CONCAT(@CavA, N'|40|', @Cell);
EXEC test.Assert_IsEqual @TestName = N'[Credit] row stamps the LOT cavity, the reading and the press', @Expected = @Want, @Actual = @v;

EXEC Workorder.DieCastCredit_Write @LotId = @Lot, @ShiftId = @S1, @PieceDelta = 25, @CellLocationId = @Cell,
    @ApplyToLot = 0, @AppUserId = @Usr;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] ApplyToLot = 0 leaves the LOT count alone', @Expected = N'40', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 25) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] ...but still writes the production row', @Expected = N'1', @Actual = @v;

INSERT INTO Workorder.DieCastShiftReconciliation (ShiftId, CellLocationId, ToolId, ReasonId, DieShotCountBefore, DieShotCountAfter, AppUserId)
VALUES (@S1, @Cell, test.ufn_RC(N'Tool'), (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry'), 0, 0, @Usr);
DECLARE @H BIGINT = SCOPE_IDENTITY();
DECLARE @At DATETIME2(3) = '2020-01-06T19:59:59';
DECLARE @Sfx NVARCHAR(100) = N' (shift reconciliation #1)';
EXEC Workorder.DieCastCredit_Write @LotId = @Lot, @ShiftId = @S1, @PieceDelta = -5, @CellLocationId = @Cell,
    @ReconciliationId = @H, @EventAt = @At, @AuditSuffix = @Sfx, @AppUserId = @Usr;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(200));
EXEC test.Assert_IsEqual @TestName = N'[Credit] a negative reconciliation credit is accepted and applied', @Expected = N'35', @Actual = @v;
SET @v = (SELECT CONCAT(ReconciliationId, N'|', CONVERT(NVARCHAR(19), EventAt, 126)) FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = -5);
SET @Want = CONCAT(@H, N'|2020-01-06T19:59:59');
EXEC test.Assert_IsEqual @TestName = N'[Credit] carries the reconciliation and the given EventAt', @Expected = @Want, @Actual = @v;
SET @v = (SELECT TOP 1 Description FROM Lots.LotEventLog WHERE (LotId = @Lot OR EntityId = @Lot) ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Credit] audit text carries the delta and the suffix',
    @HaystackStr = @v, @NeedleStr = N'Added -5 pc (shift reconciliation #1)';
GO

EXEC test.EndTestFile;
GO
```

Later tasks insert their sections **above** the final `EXEC test.EndTestFile;`.

- [ ] **Step 2: Run it to see it fail**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
Expected: `[Credit]` FAILS -- "Could not find stored procedure 'Workorder.DieCastCredit_Write'".

- [ ] **Step 3: Write the worker**

Create `sql/migrations/repeatable/R__Workorder_DieCastCredit_Write.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastCredit_Write.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- writes ONE die cast credit: a
--              Workorder.DieCastContribution row and, when @ApplyToLot = 1,
--              the matching move of the LOT's materialized PieceCount /
--              InventoryAvailable (B5). Extracted from
--              Workorder.DieCastShiftOutput_Record v3.0 and
--              Lots.DieCastLot_Release v2.2 so the live procs and
--              Workorder.DieCastShiftReconciliation_Save write credits one
--              way (spec 2026-09-21 sec 5.1).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH -- the
--              Oee.ShiftOverride_Restamp pattern. Callers are status-row procs
--              captured via INSERT-EXEC; they validate first, open the
--              transaction, and their CATCH handles anything raised here.
--              This worker validates nothing.
--
--              @ApplyToLot = 0 is the reconciliation's "record the production,
--              leave the count": the LOT is released (its count is corrected
--              through Lots.Lot_ApplyPieceCountCorrection, which leaves the
--              LotAttributeChange trail) or already counted downstream (the
--              count stands -- spec sec 3.3).
--
--              A negative @PieceDelta is legal only with @ReconciliationId;
--              CK_DieCastContribution_DeltaNonNeg enforces it (migration 0097).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastCredit_Write
    @LotId              BIGINT,
    @ShiftId            BIGINT,
    @PieceDelta         INT,
    @CounterReading     INT            = NULL,
    @CellLocationId     BIGINT         = NULL,
    @ApplyToLot         BIT            = 1,
    @VarianceReasonId   BIGINT         = NULL,
    @VarianceNote       NVARCHAR(500)  = NULL,
    @ReconciliationId   BIGINT         = NULL,
    @EventAt            DATETIME2(3)   = NULL,
    @AuditLocationId    BIGINT         = NULL,
    @AuditSuffix        NVARCHAR(100)  = N'',
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @At DATETIME2(3) = ISNULL(@EventAt, SYSUTCDATETIME());

    INSERT INTO Workorder.DieCastContribution
        (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId,
         ShotCounterReading, ToolCavityId, VarianceReasonId, VarianceNote, ReconciliationId)
    SELECT @LotId, @ShiftId, @PieceDelta, @AppUserId, @TerminalLocationId, @At, @CellLocationId,
           @CounterReading, l.ToolCavityId, @VarianceReasonId, @VarianceNote, @ReconciliationId
    FROM Lots.Lot l
    WHERE l.Id = @LotId;

    IF @ApplyToLot = 1 AND @PieceDelta <> 0
        UPDATE Lots.Lot WITH (UPDLOCK, HOLDLOCK)
        SET PieceCount = PieceCount + @PieceDelta, InventoryAvailable = InventoryAvailable + @PieceDelta,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

    DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
    DECLARE @Act NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Added ' + CAST(@PieceDelta AS NVARCHAR(10)) + N' pc'
        + ISNULL(@AuditSuffix, N''));
    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = @AuditLocationId, @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
        @LogEventTypeCode = N'DieCastPieceContributed', @LogSeverityCode = N'Info',
        @Description = @Act, @OldValue = NULL, @NewValue = NULL;
END;
GO
```

- [ ] **Step 4: Point `DieCastShiftOutput_Record` at the worker**

In `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql`, change `-- Version:     3.0` to `-- Version:     3.1` and add directly under it:

```sql
-- Change:      v3.1 (2026-09-22) -- the writes moved into shared workers
--              (spec 2026-09-21 sec 5.1): the contribution + LOT count +
--              audit block is now Workorder.DieCastCredit_Write. Behaviour
--              unchanged; this proc keeps every validation, the watermark
--              guard and the die shot-count update.
```

Replace the block that starts `            IF @Delta > 0` and ends with the `END` after `@OldValue=NULL, @NewValue=NULL;` (lines 299-314) with:

```sql
            IF @Delta > 0
                EXEC Workorder.DieCastCredit_Write @LotId = @LotId, @ShiftId = @ShiftId, @PieceDelta = @Delta,
                    @CounterReading = @CounterReading, @CellLocationId = @ResolvedCellLocationId, @ApplyToLot = 1,
                    @VarianceReasonId = @VReasonId, @VarianceNote = @VNote, @AuditLocationId = @CellLocationId,
                    @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
```

`@AuditLocationId = @CellLocationId` (the caller's value, not the resolved press) is deliberate: it is what v3.0 passed to the audit row.

- [ ] **Step 5: Point `DieCastLot_Release` at the worker**

In `sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql`, change `-- Version:     2.2` to `-- Version:     2.3` and add under it:

```sql
-- Change:      v2.3 (2026-09-22) -- the writes moved into shared workers
--              (spec 2026-09-21 sec 5.1): the final-delta contribution is now
--              Workorder.DieCastCredit_Write. Behaviour unchanged.
```

Replace lines 225-247 (from `        IF @CounterReading IS NOT NULL OR (@FinalPieceDelta IS NOT NULL AND @FinalPieceDelta > 0)` through the `END` that closes that block) with:

```sql
        IF @CounterReading IS NOT NULL OR (@FinalPieceDelta IS NOT NULL AND @FinalPieceDelta > 0)
        BEGIN
            DECLARE @CreditDelta INT = ISNULL(@FinalPieceDelta, 0);
            DECLARE @FinalSuffix NVARCHAR(100) = N' (final)';
            EXEC Workorder.DieCastCredit_Write @LotId = @LotId, @ShiftId = @ShiftId, @PieceDelta = @CreditDelta,
                @CounterReading = @CounterReading, @CellLocationId = @ResolvedCellLocationId, @ApplyToLot = 1,
                @AuditLocationId = NULL, @AuditSuffix = @FinalSuffix,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;

            -- die life advances with the reading (see header)
            DECLARE @RelShotDelta INT = ISNULL(@CounterReading, 0) - @RelDieWatermark;
            IF @RelShotDelta > 0
                UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
                SET ShotCount = ShotCount + @RelShotDelta,
                    UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @RelToolId;
        END
```

A zero delta still writes the row (the watermark anchor v2.0 depends on) and skips the count update -- the worker's `@PieceDelta <> 0` guard reproduces v2.2's `IF ISNULL(@FinalPieceDelta, 0) > 0`.

- [ ] **Step 6: Run the new test and the live die cast suites**

Run each:
```
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0022_PlantFloor_DieCast"
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0045_DieCast_Lifecycle"
```
Expected: `[Credit]` passes; `0022` and `0045` match the Task 3 baseline exactly (same pass count, no new failures).

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastCredit_Write.sql sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql sql/tests/0097_DieCast_Reconciliation/020_Workers.sql
git commit -m "refactor(sql): die cast credit write extracted into Workorder.DieCastCredit_Write"
```

---

### Task 5: Worker `Workorder.DieCastScrap_Write` + live procs onto it

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCastScrap_Write.sql`
- Modify: `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql` (cursor loop + die-wide block)
- Modify: `sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql` (closing scrap block)
- Test: `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql` (new section)

**Interfaces:**
- Produces: `Workorder.DieCastScrap_Write @ToolId BIGINT, @ShiftId BIGINT, @CellLocationId BIGINT = NULL, @LinesJson NVARCHAR(MAX) = NULL, @DieWideJson NVARCHAR(MAX) = NULL, @Remarks NVARCHAR(200) = N'Die-cast per-cavity scrap', @NoLotRemarks NVARCHAR(200) = NULL, @ReconciliationId BIGINT = NULL, @RecordedAt DATETIME2(3) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL`.
  - `@LinesJson`: `[{"lotId":<id|null>,"toolCavityId":<id|null>,"scrapLines":[{"defectCodeId":<id>,"quantity":<int>,"approvedByUserId":<id|null>}]}]`. A line with `lotId` takes part and cavity from the LOT; a line without takes them from `toolCavityId` and uses `@NoLotRemarks` (default `@Remarks + ' (no basket)'` -- v3.0's stored text, kept byte-identical for existing rows' neighbours; new callers pass their own).
  - `@DieWideJson`: `[{"defectCodeId":<id>,"quantity":<int>}]` -- one row per Active, non-deprecated cavity of `@ToolId`, the cavity's Open LOT attached when there is one, remarks `Die-cast die-wide scrap`.

- [ ] **Step 1: Add the failing section to `020_Workers.sql`** (above the final `EXEC test.EndTestFile;`)

```sql
-- ---- DieCastScrap_Write ----
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Tool BIGINT = test.ufn_RC(N'Tool'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @Code BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700101');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

DECLARE @Lines NVARCHAR(MAX) =
      N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"scrapLines":[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20)) + N',"quantity":3}]},'
    + N'{"toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"scrapLines":[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20))
    + N',"quantity":4,"approvedByUserId":' + CAST(@Usr AS NVARCHAR(20)) + N'}]}]';
DECLARE @DieWide NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20)) + N',"quantity":2}]';
EXEC Workorder.DieCastScrap_Write @ToolId = @Tool, @ShiftId = @S1, @CellLocationId = @Cell,
    @LinesJson = @Lines, @DieWideJson = @DieWide, @AppUserId = @Usr;

SET @v = (SELECT CONCAT(ItemId, N'|', ToolCavityId, N'|', Remarks) FROM Workorder.RejectEvent WHERE LotId = @Lot AND Quantity = 3);
SET @Want = CONCAT(test.ufn_RC(N'ItemA'), N'|', test.ufn_RC(N'CavA'), N'|Die-cast per-cavity scrap');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a LOT line takes part and cavity from the LOT', @Expected = @Want, @Actual = @v;

SET @v = (SELECT CONCAT(ISNULL(CAST(LotId AS NVARCHAR(20)), N'null'), N'|', ItemId, N'|', ApprovedByUserId, N'|', Remarks)
          FROM Workorder.RejectEvent WHERE ToolCavityId = @CavB AND Quantity = 4);
SET @Want = CONCAT(N'null|', test.ufn_RC(N'ItemB'), N'|', @Usr, N'|Die-cast per-cavity scrap (no basket)');
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a cavity line: no LOT, the cavity part, Approved by stamped', @Expected = @Want, @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ToolId = @Tool AND Remarks = N'Die-cast die-wide scrap' AND Quantity = 2) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Scrap] die-wide fans out to both active cavities', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT LotId FROM Workorder.RejectEvent WHERE ToolCavityId = test.ufn_RC(N'CavA') AND Remarks = N'Die-cast die-wide scrap') AS NVARCHAR(400));
SET @Want = CAST(@Lot AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Scrap] die-wide attaches the cavity''s open LOT', @Expected = @Want, @Actual = @v;

DECLARE @Rem NVARCHAR(200) = N'Die-cast shift reconciliation';
DECLARE @OneLine NVARCHAR(MAX) = N'[{"toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"scrapLines":[{"defectCodeId":' + CAST(@Code AS NVARCHAR(20)) + N',"quantity":-1}]}]';
EXEC Workorder.DieCastScrap_Write @ToolId = @Tool, @ShiftId = @S1, @CellLocationId = @Cell,
    @LinesJson = @OneLine, @Remarks = @Rem, @NoLotRemarks = @Rem, @AppUserId = @Usr;
SET @v = (SELECT Remarks FROM Workorder.RejectEvent WHERE ToolCavityId = @CavB AND Quantity = -1);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] @NoLotRemarks overrides the no-LOT text', @Expected = N'Die-cast shift reconciliation', @Actual = @v;
GO
```

- [ ] **Step 2: Run to see it fail**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
Expected: `[Scrap]` FAILS -- procedure not found.

- [ ] **Step 3: Write the worker**

Create `sql/migrations/repeatable/R__Workorder_DieCastScrap_Write.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastScrap_Write.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- writes die cast scrap as additive
--              Workorder.RejectEvent rows (record only: never decrements a
--              LOT, never closes one -- the 0042 ScrapIsAdditive rule).
--              Extracted from Workorder.DieCastShiftOutput_Record v3.0 (the
--              per-LOT, per-cavity and die-wide inserts) and
--              Lots.DieCastLot_Release v2.2 (closing scrap), so the live procs
--              and Workorder.DieCastShiftReconciliation_Save write scrap one
--              way (spec 2026-09-21 sec 5.1).
--
--              Every row STAMPS its identity (ItemId, ToolId, ToolCavityId,
--              ShiftId, CellLocationId) -- 0084: the reject reports read
--              re.ItemId and never reach the part through the LOT.
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. The
--              caller validates the JSON and the defect codes first.
--              A negative quantity is written as given: only the
--              reconciliation passes one (a compensating row, spec D13).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastScrap_Write
    @ToolId             BIGINT,
    @ShiftId            BIGINT,
    @CellLocationId     BIGINT         = NULL,
    @LinesJson          NVARCHAR(MAX)  = NULL,
    @DieWideJson        NVARCHAR(MAX)  = NULL,
    @Remarks            NVARCHAR(200)  = N'Die-cast per-cavity scrap',
    @NoLotRemarks       NVARCHAR(200)  = NULL,
    @ReconciliationId   BIGINT         = NULL,
    @RecordedAt         DATETIME2(3)   = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @At DATETIME2(3) = ISNULL(@RecordedAt, SYSUTCDATETIME());
    DECLARE @NoLotText NVARCHAR(200) = ISNULL(@NoLotRemarks, @Remarks + N' (no basket)');

    IF @LinesJson IS NOT NULL AND ISJSON(@LinesJson) = 1
    BEGIN
        -- with a LOT: part and cavity come from the LOT (authoritative for what is in it)
        INSERT INTO Workorder.RejectEvent
            (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
             DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt,
             ApprovedByUserId, ReconciliationId)
        SELECT NULL, l.Id, l.ItemId, @ToolId, l.ToolCavityId, @ShiftId, @CellLocationId,
               s.defectCodeId, s.quantity, NULL, @Remarks, @AppUserId, @TerminalLocationId, @At,
               s.approvedByUserId, @ReconciliationId
        FROM OPENJSON(@LinesJson) WITH (lotId BIGINT N'$.lotId', scrapLines NVARCHAR(MAX) N'$.scrapLines' AS JSON) ln
        CROSS APPLY OPENJSON(ln.scrapLines) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity',
                                                  approvedByUserId BIGINT N'$.approvedByUserId') s
        INNER JOIN Lots.Lot l ON l.Id = ln.lotId
        WHERE ln.lotId IS NOT NULL;

        -- without a LOT: a fact about the CAVITY (0084 spec sec 3.6)
        INSERT INTO Workorder.RejectEvent
            (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
             DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt,
             ApprovedByUserId, ReconciliationId)
        SELECT NULL, NULL, tc.ItemId, @ToolId, tc.Id, @ShiftId, @CellLocationId,
               s.defectCodeId, s.quantity, NULL, @NoLotText, @AppUserId, @TerminalLocationId, @At,
               s.approvedByUserId, @ReconciliationId
        FROM OPENJSON(@LinesJson) WITH (lotId BIGINT N'$.lotId', toolCavityId BIGINT N'$.toolCavityId',
                                        scrapLines NVARCHAR(MAX) N'$.scrapLines' AS JSON) ln
        CROSS APPLY OPENJSON(ln.scrapLines) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity',
                                                  approvedByUserId BIGINT N'$.approvedByUserId') s
        INNER JOIN Tools.ToolCavity tc ON tc.Id = ln.toolCavityId
        WHERE ln.lotId IS NULL;
    END

    -- die-wide: every ACTIVE cavity, the LOT attached only where one is open (0084 D8)
    IF @DieWideJson IS NOT NULL AND ISJSON(@DieWideJson) = 1
        INSERT INTO Workorder.RejectEvent
            (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
             DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt,
             ApprovedByUserId, ReconciliationId)
        SELECT NULL, ol.LotId, tc.ItemId, @ToolId, tc.Id, @ShiftId, @CellLocationId,
               sl.defectCodeId, sl.quantity, NULL, N'Die-cast die-wide scrap',
               @AppUserId, @TerminalLocationId, @At, NULL, @ReconciliationId
        FROM OPENJSON(@DieWideJson) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') sl
        CROSS JOIN Tools.ToolCavity tc
        INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
        OUTER APPLY (SELECT TOP 1 l.Id AS LotId FROM Lots.Lot l
                     INNER JOIN Lots.LotStatusCode lsc ON lsc.Id = l.LotStatusId
                     WHERE l.ToolCavityId = tc.Id AND lsc.Code = N'Open') ol
        WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND csc.Code = N'Active';
END;
GO
```

- [ ] **Step 4: Point `DieCastShiftOutput_Record` at it**

Extend the v3.1 header note from Task 4 with:

```sql
--              The per-LOT, per-cavity and die-wide scrap inserts are now
--              Workorder.DieCastScrap_Write, called once after the credits.
```

Replace everything from `        DECLARE @LotId BIGINT, @CavId BIGINT, @Delta INT, @Scrap NVARCHAR(MAX), @VReasonId BIGINT, @VNote NVARCHAR(500);` through the end of the die-wide insert (`WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND csc.Code = N'Active';`) with:

```sql
        DECLARE @LotId BIGINT, @Delta INT, @VReasonId BIGINT, @VNote NVARCHAR(500);
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT LotId, PieceDelta, VarianceReasonId, VarianceNote FROM @Lines;
        OPEN cur; FETCH NEXT FROM cur INTO @LotId, @Delta, @VReasonId, @VNote;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- pieces on a basketless line were rejected pre-transaction, so a
            -- credit is only ever written for a line with a LOT (spec 3.6)
            IF @Delta > 0
                EXEC Workorder.DieCastCredit_Write @LotId = @LotId, @ShiftId = @ShiftId, @PieceDelta = @Delta,
                    @CounterReading = @CounterReading, @CellLocationId = @ResolvedCellLocationId, @ApplyToLot = 1,
                    @VarianceReasonId = @VReasonId, @VarianceNote = @VNote, @AuditLocationId = @CellLocationId,
                    @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
            FETCH NEXT FROM cur INTO @LotId, @Delta, @VReasonId, @VNote;
        END
        CLOSE cur; DEALLOCATE cur;

        -- per-LOT, per-cavity and die-wide scrap, additive (record only)
        EXEC Workorder.DieCastScrap_Write @ToolId = @ToolId, @ShiftId = @ShiftId, @CellLocationId = @ResolvedCellLocationId,
            @LinesJson = @LinesJson, @DieWideJson = @ShotLossJson,
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
```

- [ ] **Step 5: Point `DieCastLot_Release` at it**

Extend its v2.3 note with: `The closing scrap insert is now Workorder.DieCastScrap_Write.`

Replace the closing scrap insert (from `        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1` through `FROM OPENJSON(@ScrapLinesJson) WITH (defectCodeId BIGINT '$.defectCodeId', quantity INT '$.quantity') s;`) with:

```sql
        IF @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) = 1
        BEGIN
            DECLARE @ReleaseScrap NVARCHAR(MAX) =
                N'[{"lotId":' + CAST(@LotId AS NVARCHAR(20)) + N',"scrapLines":' + @ScrapLinesJson + N'}]';
            DECLARE @ReleaseRemarks NVARCHAR(200) = N'Die-cast final release scrap';
            EXEC Workorder.DieCastScrap_Write @ToolId = @RelToolId, @ShiftId = @ShiftId,
                @CellLocationId = @ResolvedCellLocationId, @LinesJson = @ReleaseScrap, @Remarks = @ReleaseRemarks,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END
```

- [ ] **Step 6: Run the new test and the live suites**

Run the three commands from Task 4 Step 6.
Expected: `[Scrap]` passes; `0022` (including `110_CavityScrap.sql` and `090_ReleasePreview.sql`) and `0045` match the baseline.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastScrap_Write.sql sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql sql/tests/0097_DieCast_Reconciliation/020_Workers.sql
git commit -m "refactor(sql): die cast scrap writes extracted into Workorder.DieCastScrap_Write"
```

---

### Task 6: Worker `Lots.DieCastLot_Mint` + `DieCastLot_Open` onto it

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_DieCastLot_Mint.sql`
- Modify: `sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql` (declarations + mutation block, header to v1.2)
- Test: `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql` (new section)

**Interfaces:**
- Produces: `Lots.DieCastLot_Mint @LotName NVARCHAR(50), @ItemId BIGINT, @ToolId BIGINT, @ToolCavityId BIGINT, @CurrentLocationId BIGINT, @ProducedAtLocationId BIGINT = NULL, @CastDate DATE = NULL, @AuditNote NVARCHAR(100) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL`. Creates the `Open` LOT at `PieceCount 0` with its status-history row, genealogy self-row, first movement and `DieCastLotOpened` audit. **Returns nothing** -- the caller reads the id back with `SELECT Id FROM Lots.Lot WHERE LotName = @LotName` (LotName is unique).

- [ ] **Step 1: Add the failing section to `020_Workers.sql`** (above the final `EXEC test.EndTestFile;`)

```sql
-- ---- DieCastLot_Mint ----
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Tool BIGINT = test.ufn_RC(N'Tool'), @CavB BIGINT = test.ufn_RC(N'CavB'), @ItemB BIGINT = test.ufn_RC(N'ItemB');
DECLARE @Cast DATE = '2020-01-06';
DECLARE @Note NVARCHAR(100) = N' (shift reconciliation #9)';
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

EXEC Lots.DieCastLot_Mint @LotName = N'99700102', @ItemId = @ItemB, @ToolId = @Tool, @ToolCavityId = @CavB,
    @CurrentLocationId = @Cell, @ProducedAtLocationId = @Cell, @CastDate = @Cast, @AuditNote = @Note,
    @AppUserId = @Usr;

DECLARE @New BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700102');
SET @v = (SELECT CONCAT(sc.Code, N'|', l.PieceCount, N'|', CONVERT(NVARCHAR(10), l.CastDate, 23), N'|', l.ProducedAtLocationId, N'|', l.ToolCavityId)
          FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @New);
SET @Want = CONCAT(N'Open|0|2020-01-06|', @Cell, N'|', @CavB);
EXEC test.Assert_IsEqual @TestName = N'[Mint] Open at zero, with cast date, press and cavity', @Expected = @Want, @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @New AND DescendantLotId = @New AND Depth = 0) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Mint] genealogy self-row', @Expected = N'1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @New AND FromLocationId IS NULL AND ToLocationId = @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Mint] first placement movement', @Expected = N'1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Lots.LotStatusHistory h JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
               WHERE h.LotId = @New AND h.OldStatusId IS NULL AND n.Code = N'Open') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Mint] status history opens the LOT', @Expected = N'1', @Actual = @v;
SET @v = (SELECT TOP 1 Description FROM Lots.LotEventLog WHERE (LotId = @New OR EntityId = @New) ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[Mint] audit carries the caller''s note', @HaystackStr = @v, @NeedleStr = N'(shift reconciliation #9)';
GO
```

- [ ] **Step 2: Run to see it fail**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
Expected: `[Mint]` FAILS -- procedure not found.

- [ ] **Step 3: Write the worker**

Create `sql/migrations/repeatable/R__Lots_DieCastLot_Mint.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_Mint.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- creates ONE die cast accumulator LOT in
--              status 'Open' at PieceCount 0, with its status-history row,
--              genealogy self-row, first-placement movement and
--              'DieCastLotOpened' audit. Extracted from Lots.DieCastLot_Open
--              v1.1 so the live press path and
--              Workorder.DieCastShiftReconciliation_Save mint one way
--              (spec 2026-09-21 sec 5.1).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH.
--              The caller validates first -- LTT format and uniqueness, the
--              cavity, and (live only) that the die is mounted right now and
--              the cavity has no open LOT. Those two guards are exactly what a
--              past shift cannot satisfy, which is why they stay in the live
--              wrapper (spec sec 5.1).
--
--              @CastDate / @ProducedAtLocationId are NULL on the live path
--              (v1.1 never set them) and carry the shift's business date and
--              the press when a reconciliation mints after the fact.
--
--              CRT is resolved here (Lots.ufn_CrtForMint) because this IS the
--              die cast ORIGIN mint -- see DieCastLot_Open v1.1's note.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_Mint
    @LotName              NVARCHAR(50),
    @ItemId               BIGINT,
    @ToolId               BIGINT,
    @ToolCavityId         BIGINT,
    @CurrentLocationId    BIGINT,
    @ProducedAtLocationId BIGINT        = NULL,
    @CastDate             DATE          = NULL,
    @AuditNote            NVARCHAR(100) = NULL,
    @AppUserId            BIGINT,
    @TerminalLocationId   BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OpenStatusId        BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @ManufacturedOrigin  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
    DECLARE @MaxLotSize          INT    = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);
    DECLARE @CellCode            NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @CurrentLocationId);
    DECLARE @CrtActive           BIT    = (SELECT CrtActive FROM Lots.ufn_CrtForMint(@ItemId, @TerminalLocationId, NULL));

    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
        ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
        CreatedByUserId, CreatedAtTerminalId, CreatedAt, CrtActive, CastDate, ProducedAtLocationId)
    VALUES (@LotName, @ItemId, @ManufacturedOrigin, @OpenStatusId, 0, @MaxLotSize,
        @ToolId, @ToolCavityId, @CurrentLocationId, 0, 0,
        @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @CrtActive, @CastDate, @ProducedAtLocationId);
    DECLARE @NewId BIGINT = SCOPE_IDENTITY();

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES (@NewId, NULL, @OpenStatusId, N'Die-cast basket opened.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());
    INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@NewId, @NewId, 0);
    INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
    VALUES (@NewId, NULL, @CurrentLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Basket opened at ' + ISNULL(@CellCode, N'?') + ISNULL(@AuditNote, N''));
    DECLARE @NewValue NVARCHAR(MAX) = (SELECT l.Id, l.LotName,
        JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = l.ItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
        JSON_QUERY((SELECT tc.Id, tc.CavityCode AS Code, tc.CavityCode AS Name FROM Tools.ToolCavity tc WHERE tc.Id = l.ToolCavityId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Cavity
        FROM Lots.Lot l WHERE l.Id = @NewId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = @CurrentLocationId, @LogEntityTypeCode = N'Lot', @EntityId = @NewId,
        @LogEventTypeCode = N'DieCastLotOpened', @LogSeverityCode = N'Info',
        @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;
END;
GO
```

The stored strings (`Die-cast basket opened.`, `Basket opened at ...`) are carried over verbatim: they already exist on thousands of prod rows, and changing them would split the audit history on a word. New text this feature writes uses LOT/LTT.

- [ ] **Step 4: Point `DieCastLot_Open` at the worker**

In `sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql`, change `-- Version:     1.1` to `-- Version:     1.2` and add under it:

```sql
-- Change:      v1.2 (2026-09-22) -- the mint moved into Lots.DieCastLot_Mint
--              (spec 2026-09-21 sec 5.1) so the reconciliation creates LOTs
--              the same way. Every validation stays here, including the two a
--              past shift cannot satisfy: the die must be mounted NOW, and the
--              cavity must have no open basket.
```

Delete the three now-unused declarations (lines 65-67):
```sql
    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @ManufacturedOriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
    DECLARE @MaxLotSize INT, @CellCode NVARCHAR(50);
```

Replace everything from `        SET @MaxLotSize = (SELECT MaxLotSize FROM Parts.Item WHERE Id = @ItemId);` (line 105) through `        COMMIT TRANSACTION;` (line 142) with:

```sql
        -- ===== mutation =====
        BEGIN TRANSACTION;
        EXEC Lots.DieCastLot_Mint @LotName = @LotName, @ItemId = @ItemId, @ToolId = @ToolId,
            @ToolCavityId = @ToolCavityId, @CurrentLocationId = @CurrentLocationId,
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        SET @NewId = (SELECT Id FROM Lots.Lot WHERE LotName = @LotName);
        COMMIT TRANSACTION;
```

`SCOPE_IDENTITY()` is not visible across the `EXEC`, which is why the id is read back by LTT.

- [ ] **Step 5: Run the new test and the live suites**

Run:
```
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0022_PlantFloor_DieCast"
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0045_DieCast_Lifecycle"
```
Expected: `[Mint]` passes; the live suites match the baseline.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_DieCastLot_Mint.sql sql/migrations/repeatable/R__Lots_DieCastLot_Open.sql sql/tests/0097_DieCast_Reconciliation/020_Workers.sql
git commit -m "refactor(sql): die cast LOT mint extracted into Lots.DieCastLot_Mint"
```

---

### Task 7: Worker `Lots.DieCastLot_ReleaseMove` + `DieCastLot_Release` onto it

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_DieCastLot_ReleaseMove.sql`
- Modify: `sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql` (status/move/audit block, unused declarations)
- Test: `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql` (new section)

**Interfaces:**
- Produces: `Lots.DieCastLot_ReleaseMove @LotId BIGINT, @StorageLocationId BIGINT, @AuditNote NVARCHAR(100) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL`. Open -> Good, moves the LOT to storage, writes the movement row and the `DieCastLotReleased` audit.

- [ ] **Step 1: Add the failing section to `020_Workers.sql`**

```sql
-- ---- DieCastLot_ReleaseMove ----
DECLARE @New BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700102');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr'), @Whse BIGINT = test.ufn_RC(N'Whse');
DECLARE @S1 BIGINT = test.ufn_RC(N'S1');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

EXEC Workorder.DieCastCredit_Write @LotId = @New, @ShiftId = @S1, @PieceDelta = 50, @CellLocationId = @Cell, @AppUserId = @Usr;
EXEC Lots.DieCastLot_ReleaseMove @LotId = @New, @StorageLocationId = @Whse, @AppUserId = @Usr;

SET @v = (SELECT CONCAT(sc.Code, N'|', l.CurrentLocationId, N'|', l.PieceCount)
          FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @New);
SET @Want = CONCAT(N'Good|', @Whse, N'|50');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseMove] Good, at storage, count untouched', @Expected = @Want, @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @New AND FromLocationId = @Cell AND ToLocationId = @Whse) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[ReleaseMove] movement press -> storage', @Expected = N'1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Lots.LotStatusHistory h
               JOIN Lots.LotStatusCode o ON o.Id = h.OldStatusId JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
               WHERE h.LotId = @New AND o.Code = N'Open' AND n.Code = N'Good') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[ReleaseMove] status history Open -> Good', @Expected = N'1', @Actual = @v;
GO
```

- [ ] **Step 2: Run to see it fail.** Same command; `[ReleaseMove]` FAILS -- procedure not found.

- [ ] **Step 3: Write the worker**

Create `sql/migrations/repeatable/R__Lots_DieCastLot_ReleaseMove.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_ReleaseMove.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- the closing half of a die cast release:
--              Open -> Good, the LOT moved to storage, the movement row and
--              the 'DieCastLotReleased' audit. Extracted from
--              Lots.DieCastLot_Release v2.2 so a LOT created by a shift
--              reconciliation leaves the press exactly as a live release does
--              (spec 2026-09-21 D4 / sec 5.1).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. The
--              caller resolves storage and validates the LOT first.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_ReleaseMove
    @LotId              BIGINT,
    @StorageLocationId  BIGINT,
    @AuditNote          NVARCHAR(100) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OpenStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
    DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @FromLocationId BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
    DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES (@LotId, @OpenStatusId, @GoodStatusId, N'Die-cast basket released to storage.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    UPDATE Lots.Lot
    SET LotStatusId = @GoodStatusId, CurrentLocationId = @StorageLocationId,
        UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    WHERE Id = @LotId;

    INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
    VALUES (@LotId, @FromLocationId, @StorageLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@LotName + N' ' + Audit.ufn_MidDot()
        + N' Die Cast ' + Audit.ufn_MidDot() + N' Released to storage' + ISNULL(@AuditNote, N''));
    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = @StorageLocationId, @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
        @LogEventTypeCode = N'DieCastLotReleased', @LogSeverityCode = N'Info',
        @Description = @Activity, @OldValue = NULL, @NewValue = NULL;
END;
GO
```

- [ ] **Step 4: Point `DieCastLot_Release` at it**

Extend the v2.3 header note with: `The status change, move and release audit are now Lots.DieCastLot_ReleaseMove.`

Delete the two now-unused declarations near the top (`@OpenStatusId`, `@GoodStatusId`) and the `@FromLocationId` line in the pre-transaction block (`DECLARE @FromLocationId BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);`) -- the worker reads it under the transaction instead. Keep `@LotName`: the success message uses it.

Replace the status-history insert, the `UPDATE Lots.Lot`, the `LotMovement` insert and the `DieCastLotReleased` audit (from `        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)` through the `EXEC Audit.Audit_LogOperation ... @LogEventTypeCode=N'DieCastLotReleased', ... @NewValue=NULL;`) with:

```sql
        EXEC Lots.DieCastLot_ReleaseMove @LotId = @LotId, @StorageLocationId = @ResolvedStorageLocationId,
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
```

- [ ] **Step 5: Run the new test and the live suites.** Same three commands as Task 6 Step 5, plus `-Filter "0024_PlantFloor_Movement_Trim"` (it releases die cast LOTs on the way to trim). Expected: `[ReleaseMove]` passes, live suites match the baseline.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_DieCastLot_ReleaseMove.sql sql/migrations/repeatable/R__Lots_DieCastLot_Release.sql sql/tests/0097_DieCast_Reconciliation/020_Workers.sql
git commit -m "refactor(sql): die cast release move extracted into Lots.DieCastLot_ReleaseMove"
```

---

### Task 8: Worker `Lots.Lot_ApplyPieceCountCorrection` + `Lot_RectifyPieceCount` onto it

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_ApplyPieceCountCorrection.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_RectifyPieceCount.sql` (mutation block, header to v1.1)
- Test: `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql` (new section)

**Interfaces:**
- Produces: `Lots.Lot_ApplyPieceCountCorrection @LotId BIGINT, @NewPieceCount INT, @Reason NVARCHAR(500), @ExpectedPieceCount INT = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL`. Takes the LOT row under `UPDLOCK, HOLDLOCK`; raises if `@ExpectedPieceCount` no longer matches; moves `InventoryAvailable` by the same delta (clamped to `[0, @NewPieceCount]`, raising if it would go below zero); writes the `LotAttributeChange` row carrying the reason and the `LotUpdated` audit. The caller reads the new `LotAttributeChange` id back if it needs it.

- [ ] **Step 1: Add the failing section to `020_Workers.sql`**

```sql
-- ---- Lot_ApplyPieceCountCorrection ----
DECLARE @New BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700102');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason NVARCHAR(500) = N'Shift reconciliation #9: Shift not entered';
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @New, @NewPieceCount = 60, @Reason = @Reason,
    @ExpectedPieceCount = 50, @AppUserId = @Usr;
SET @v = (SELECT CONCAT(PieceCount, N'|', InventoryAvailable) FROM Lots.Lot WHERE Id = @New);
EXEC test.Assert_IsEqual @TestName = N'[Correct] count and availability move by the same delta', @Expected = N'60|60', @Actual = @v;
SET @v = (SELECT TOP 1 CONCAT(OldValue, N'|', NewValue, N'|', Reason) FROM Lots.LotAttributeChange
          WHERE LotId = @New AND AttributeName = N'PieceCount' ORDER BY Id DESC);
SET @Want = N'50|60|Shift reconciliation #9: Shift not entered';
EXEC test.Assert_IsEqual @TestName = N'[Correct] the change row carries old, new and the reason', @Expected = @Want, @Actual = @v;

DECLARE @Err NVARCHAR(4000) = N'(no error)';
BEGIN TRY
    EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @New, @NewPieceCount = 70, @Reason = @Reason,
        @ExpectedPieceCount = 50, @AppUserId = @Usr;
END TRY
BEGIN CATCH
    SET @Err = ERROR_MESSAGE();
END CATCH
EXEC test.Assert_Contains @TestName = N'[Correct] a stale expected count is refused',
    @HaystackStr = @Err, @NeedleStr = N'changed while the correction was being entered';
GO
```

- [ ] **Step 2: Run to see it fail.** `[Correct]` FAILS -- procedure not found.

- [ ] **Step 3: Write the worker**

Create `sql/migrations/repeatable/R__Lots_Lot_ApplyPieceCountCorrection.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Lots_Lot_ApplyPieceCountCorrection.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- the audited change of a LOT's materialized
--              PieceCount (B5). Extracted from Lots.Lot_RectifyPieceCount v1.0
--              so the LOT Detail count panel and
--              Workorder.DieCastShiftReconciliation_Save correct a count one
--              way (spec 2026-09-21 sec 3.3 / 5.1).
--
--              History is preserved the way the model already preserves it:
--              ONE append-only Lots.LotAttributeChange row carrying the reason,
--              plus a routed 'Lot'/'LotUpdated' audit operation. The count
--              itself is mutated in place -- every writer in the system does
--              that and nothing re-derives it (see Lot_RectifyPieceCount's
--              header for the full argument).
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. It
--              RAISERRORs on a stale expected count or on availability going
--              negative; the caller's CATCH turns that into its status row.
--              The caller validates status, MaxLotSize and the no-op case.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_ApplyPieceCountCorrection
    @LotId              BIGINT,
    @NewPieceCount      INT,
    @Reason             NVARCHAR(500),
    @ExpectedPieceCount INT    = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LotName NVARCHAR(50), @OldPieceCount INT, @OldInvAvail INT;
    SELECT @LotName = l.LotName, @OldPieceCount = l.PieceCount, @OldInvAvail = l.InventoryAvailable
    FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
    WHERE l.Id = @LotId;

    IF @ExpectedPieceCount IS NOT NULL AND @OldPieceCount <> @ExpectedPieceCount
        RAISERROR(N'The LOT piece count changed while the correction was being entered. Reload and retry.', 16, 1);

    DECLARE @Delta INT = @NewPieceCount - @OldPieceCount;
    DECLARE @NewInvAvail INT = @OldInvAvail + @Delta;
    IF @NewInvAvail < 0
        RAISERROR(N'The corrected piece count is below the pieces already consumed (concurrent update). Reload and retry.', 16, 1);
    IF @NewInvAvail > @NewPieceCount SET @NewInvAvail = @NewPieceCount;

    DECLARE @OldValue NVARCHAR(500) = CAST(@OldPieceCount AS NVARCHAR(500));
    DECLARE @NewValue NVARCHAR(500) = CAST(@NewPieceCount AS NVARCHAR(500));
    DECLARE @ActivityRaw NVARCHAR(MAX) =
        @LotName + N' ' + Audit.ufn_MidDot() + N' Rectify ' + Audit.ufn_MidDot()
        + N' PieceCount ' + @OldValue + NCHAR(8594) + @NewValue + N' (' + @Reason + N')';
    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

    INSERT INTO Lots.LotAttributeChange
        (LotId, AttributeName, OldValue, NewValue, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES
        (@LotId, N'PieceCount', @OldValue, @NewValue, @Reason, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    UPDATE Lots.Lot
    SET PieceCount = @NewPieceCount, InventoryAvailable = @NewInvAvail,
        UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    WHERE Id = @LotId;

    DECLARE @OldJson NVARCHAR(MAX) = (
        SELECT N'PieceCount' AS Attribute, @OldPieceCount AS Value, @OldInvAvail AS InventoryAvailable
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @NewJson NVARCHAR(MAX) = (
        SELECT N'PieceCount' AS Attribute, @NewPieceCount AS Value,
               @NewInvAvail AS InventoryAvailable, @Reason AS Reason,
               JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                           FROM Lots.Lot l WHERE l.Id = @LotId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
               JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                           FROM Location.Location loc
                           INNER JOIN Lots.Lot l2 ON l2.CurrentLocationId = loc.Id
                           WHERE l2.Id = @LotId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    EXEC Audit.Audit_LogOperation
        @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
        @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'LotUpdated',
        @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldJson, @NewValue = @NewJson;
END;
GO
```

- [ ] **Step 4: Point `Lot_RectifyPieceCount` at it**

Change `-- Version:     1.0` to `-- Version:     1.1` and add under it:

```sql
-- Change:      v1.1 (2026-09-22) -- the mutation moved into
--              Lots.Lot_ApplyPieceCountCorrection (spec 2026-09-21 sec 5.1) so
--              a die cast shift reconciliation corrects a count the same way,
--              with the same LotAttributeChange trail. Every validation --
--              status, MaxLotSize, the no-op, availability -- stays here.
```

Replace the whole mutation section (from `        -- ===== Mutation (atomic) =====` through `        COMMIT TRANSACTION;`) with:

```sql
        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;
        EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @LotId, @NewPieceCount = @NewPieceCount,
            @Reason = @Reason, @ExpectedPieceCount = @OldPieceCount,
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        SET @NewId = (SELECT TOP 1 Id FROM Lots.LotAttributeChange
                      WHERE LotId = @LotId AND AttributeName = N'PieceCount' ORDER BY Id DESC);
        COMMIT TRANSACTION;
```

The success message below it already builds from `@OldValue` / `@NewValue`; leave it untouched.

- [ ] **Step 5: Run the new test and the rectify suite**

Run:
```
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0061_Lot_ScrapAndRectify"
```
Expected: `[Correct]` passes; `0061` matches the baseline (its no-op, status, MaxLotSize and consumed-pieces refusals all still come from the wrapper).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_ApplyPieceCountCorrection.sql sql/migrations/repeatable/R__Lots_Lot_RectifyPieceCount.sql sql/tests/0097_DieCast_Reconciliation/020_Workers.sql
git commit -m "refactor(sql): LOT count correction extracted into Lots.Lot_ApplyPieceCountCorrection"
```

---

### Task 9: Worker `Workorder.DieCastEntry_Restamp` + the override-restamp exclusion

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCastEntry_Restamp.sql`
- Modify: `sql/migrations/repeatable/R__Oee_ShiftOverride_Restamp.sql` (contribution scope, header to v1.1)
- Test: `sql/tests/0097_DieCast_Reconciliation/020_Workers.sql` (new section)
- Test: `sql/tests/0062_Oee_ShiftAttribution/030_restamp.sql` (fixture rows + two assertions)

**Interfaces:**
- Produces: `Workorder.DieCastEntry_Restamp @ReconciliationId BIGINT, @MovesJson NVARCHAR(MAX), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL`, where `@MovesJson` is `[{"entityType":"Contribution"|"Reject","entityId":<id>,"toShiftId":<id>}]`. Re-stamps `ShiftId` in place, writes one `DieCastReconciliationMove` row per moved row, and one `DieCastEntryMoved` audit row naming the shift pair. The caller validates that every row belongs to the shift x press x die being reconciled and that each target is a closed shift within two of it.

- [ ] **Step 1: Add the failing section to `020_Workers.sql`**

```sql
-- ---- DieCastEntry_Restamp ----
DECLARE @H BIGINT = (SELECT TOP 1 Id FROM Workorder.DieCastShiftReconciliation ORDER BY Id);
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700101');
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @S2 BIGINT = test.ufn_RC(N'S2'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @C BIGINT = (SELECT Id FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 40);
DECLARE @R BIGINT = (SELECT Id FROM Workorder.RejectEvent WHERE LotId = @Lot AND Quantity = 3);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

DECLARE @Moves NVARCHAR(MAX) =
      N'[{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S2 AS NVARCHAR(20)) + N'},'
    + N'{"entityType":"Reject","entityId":' + CAST(@R AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S2 AS NVARCHAR(20)) + N'}]';
EXEC Workorder.DieCastEntry_Restamp @ReconciliationId = @H, @MovesJson = @Moves, @AppUserId = @Usr;

SET @v = CAST((SELECT ShiftId FROM Workorder.DieCastContribution WHERE Id = @C) AS NVARCHAR(400));
SET @Want = CAST(@S2 AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Restamp] the contribution now belongs to the target shift', @Expected = @Want, @Actual = @v;
SET @v = CAST((SELECT ShiftId FROM Workorder.RejectEvent WHERE Id = @R) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Restamp] so does the reject row', @Expected = @Want, @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationMove m
               WHERE m.ReconciliationId = @H AND m.FromShiftId = @S1 AND m.ToShiftId = @S2) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Restamp] both moves are recorded with where they came from', @Expected = N'2', @Actual = @v;

SET @v = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol
          JOIN Audit.LogEntityType et ON et.Id = ol.LogEntityTypeId
          JOIN Audit.LogEventType  ev ON ev.Id = ol.LogEventTypeId
          WHERE ol.EntityId = @H AND et.Code = N'DieCastShiftReconciliation' AND ev.Code = N'DieCastEntryMoved'
          ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[Restamp] one audit row naming what moved', @HaystackStr = @v, @NeedleStr = N'Moved 2 rows';
GO
```

- [ ] **Step 2: Run to see it fail.** `[Restamp]` FAILS -- procedure not found.

- [ ] **Step 3: Write the worker**

Create `sql/migrations/repeatable/R__Workorder_DieCastEntry_Restamp.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastEntry_Restamp.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- re-files recorded die cast rows against the
--              shift they belong to (spec 2026-09-21 sec 3.5, amendment A4).
--              Modelled on Oee.ShiftOverride_Restamp: the ShiftId is re-stamped
--              IN PLACE, and the durable record of where the row came from is
--              a Workorder.DieCastReconciliationMove row.
--
--              The facts do not change -- shots, pieces, LOTs and die life are
--              untouched. Only which shift is credited moves.
--
--              A row moved here is EXCLUDED from Oee.ShiftOverride_Restamp
--              from then on (amendment A2): that proc re-derives the shift
--              from EventAt, and an entry made at 09:35 for the night shift
--              would otherwise be dragged back the next time an override is
--              applied to the press. The team lead's reading of the press
--              sheet outranks the time-based resolver.
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. The
--              caller validates every row and target shift first.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastEntry_Restamp
    @ReconciliationId   BIGINT,
    @MovesJson          NVARCHAR(MAX),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @MovesJson IS NULL OR ISJSON(@MovesJson) <> 1 RETURN;

    DECLARE @ContribTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DieCastContribution');
    DECLARE @RejectTypeId  BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'RejectEvent');

    DECLARE @M TABLE (EntityTypeId BIGINT, EntityId BIGINT, FromShiftId BIGINT, ToShiftId BIGINT);
    INSERT INTO @M (EntityTypeId, EntityId, FromShiftId, ToShiftId)
    SELECT CASE j.entityType WHEN N'Contribution' THEN @ContribTypeId ELSE @RejectTypeId END,
           j.entityId, COALESCE(c.ShiftId, r.ShiftId), j.toShiftId
    FROM OPENJSON(@MovesJson) WITH (entityType NVARCHAR(20) N'$.entityType', entityId BIGINT N'$.entityId',
                                    toShiftId BIGINT N'$.toShiftId') j
    LEFT JOIN Workorder.DieCastContribution c ON j.entityType = N'Contribution' AND c.Id = j.entityId
    LEFT JOIN Workorder.RejectEvent         r ON j.entityType = N'Reject'       AND r.Id = j.entityId
    WHERE COALESCE(c.ShiftId, r.ShiftId) IS NOT NULL
      AND COALESCE(c.ShiftId, r.ShiftId) <> j.toShiftId;

    UPDATE c SET c.ShiftId = m.ToShiftId
    FROM Workorder.DieCastContribution c
    INNER JOIN @M m ON m.EntityTypeId = @ContribTypeId AND m.EntityId = c.Id;

    UPDATE r SET r.ShiftId = m.ToShiftId
    FROM Workorder.RejectEvent r
    INNER JOIN @M m ON m.EntityTypeId = @RejectTypeId AND m.EntityId = r.Id;

    INSERT INTO Workorder.DieCastReconciliationMove (ReconciliationId, LogEntityTypeId, EntityId, FromShiftId, ToShiftId)
    SELECT @ReconciliationId, m.EntityTypeId, m.EntityId, m.FromShiftId, m.ToShiftId FROM @M m;

    -- ---- one audit row per apply, naming the pair when there is only one ----
    DECLARE @Total INT = (SELECT COUNT(*) FROM @M);
    IF @Total = 0 RETURN;
    DECLARE @PairCount INT = (SELECT COUNT(*) FROM (SELECT DISTINCT FromShiftId, ToShiftId FROM @M) p);
    DECLARE @FromLabel NVARCHAR(120) = NULL, @ToLabel NVARCHAR(120) = NULL;
    IF @PairCount = 1
        SELECT TOP 1
               @FromLabel = CONVERT(NVARCHAR(5), sf.ActualStart, 110) + N' ' + ssf.Name,
               @ToLabel   = CONVERT(NVARCHAR(5), st.ActualStart, 110) + N' ' + sst.Name
        FROM @M m
        INNER JOIN Oee.Shift sf ON sf.Id = m.FromShiftId INNER JOIN Oee.ShiftSchedule ssf ON ssf.Id = sf.ShiftScheduleId
        INNER JOIN Oee.Shift st ON st.Id = m.ToShiftId   INNER JOIN Oee.ShiftSchedule sst ON sst.Id = st.ShiftScheduleId;

    DECLARE @PressCode NVARCHAR(50) = (SELECT loc.Code FROM Workorder.DieCastShiftReconciliation h
                                       INNER JOIN Location.Location loc ON loc.Id = h.CellLocationId
                                       WHERE h.Id = @ReconciliationId);
    DECLARE @ActivityRaw NVARCHAR(MAX) =
        ISNULL(@PressCode, N'(unknown)') + N' ' + Audit.ufn_MidDot() + N' Die Cast ' + Audit.ufn_MidDot()
        + N' Moved ' + CAST(@Total AS NVARCHAR(10)) + N' rows'
        + CASE WHEN @PairCount = 1 THEN N' from ' + @FromLabel + N' to ' + @ToLabel
               ELSE N' across ' + CAST(@PairCount AS NVARCHAR(10)) + N' shift pairs' END;
    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
    DECLARE @NewValue NVARCHAR(MAX) = (
        SELECT @Total AS RowsMoved, @PairCount AS DistinctShiftPairs,
               (SELECT COUNT(*) FROM @M WHERE EntityTypeId = @ContribTypeId) AS Contributions,
               (SELECT COUNT(*) FROM @M WHERE EntityTypeId = @RejectTypeId)  AS Rejects
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = NULL, @LogEntityTypeCode = N'DieCastShiftReconciliation', @EntityId = @ReconciliationId,
        @LogEventTypeCode = N'DieCastEntryMoved', @LogSeverityCode = N'Warning',
        @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;
END;
GO
```

- [ ] **Step 4: Exclude reconciliation rows from the override restamp**

In `sql/migrations/repeatable/R__Oee_ShiftOverride_Restamp.sql`, change `-- Version:     1.0` to `-- Version:     1.1` and add to the Change Log at the bottom of the header:

```sql
--   2026-09-22 - 1.1 - Die cast shift reconciliation (spec 2026-09-21,
--                      amendment A2): a contribution row a reconciliation
--                      WROTE (ReconciliationId) or MOVED
--                      (Workorder.DieCastReconciliationMove) is excluded. This
--                      proc re-derives a row's shift from EventAt, and a
--                      backfilled or re-filed row's EventAt is deliberately
--                      not when the work happened -- re-deriving it would undo
--                      the team lead's reading of the press sheet the next
--                      time an override is applied to that press.
```

In the `INSERT INTO @Moves ... SELECT 2, dc.Id, ...` block, add two predicates after `AND (dc.ShiftId IS NULL OR dc.ShiftId <> r.ShiftId);`, replacing that line with:

```sql
      AND (dc.ShiftId IS NULL OR dc.ShiftId <> r.ShiftId)
      AND dc.ReconciliationId IS NULL
      AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastReconciliationMove mv
                      INNER JOIN Audit.LogEntityType et ON et.Id = mv.LogEntityTypeId
                      WHERE et.Code = N'DieCastContribution' AND mv.EntityId = dc.Id);
```

- [ ] **Step 5: Prove the exclusion in the existing restamp test**

In `sql/tests/0062_Oee_ShiftAttribution/030_restamp.sql`:

Add to the cleanup block, immediately after the `DELETE FROM Workorder.DieCastContribution WHERE LotId IN (...)` statement:

```sql
DELETE m FROM Workorder.DieCastReconciliationMove m
  INNER JOIN Workorder.DieCastShiftReconciliation h ON h.Id = m.ReconciliationId WHERE h.Note = N'TEST_AT';
DELETE FROM Workorder.DieCastShiftReconciliation WHERE Note = N'TEST_AT';
DELETE FROM Tools.Tool WHERE Code = N'TEST_AT_DIE';
```

At the end of the batch that inserts the two fixture contributions (after the `INSERT INTO Workorder.DieCastContribution ... VALUES (@LotId, @SecondShift, 5, ...), (@LotId, @SecondShift, 3, ...);` statement, before its `GO`), add:

```sql
-- 0097 / amendment A2: rows a shift reconciliation WROTE or MOVED are the team
-- lead's decision and must survive an override restamp untouched.
DECLARE @FirstShift BIGINT = (SELECT sh.Id FROM Oee.Shift sh
                              INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
                              WHERE ss.Name = N'TEST_AT_First' AND CAST(sh.ActualStart AS DATE) = '2026-10-19');
INSERT INTO Tools.Tool (Code, Name, ToolTypeId, StatusCodeId, CreatedByUserId)
VALUES (N'TEST_AT_DIE', N'TEST_AT die',
        (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id),
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
INSERT INTO Workorder.DieCastShiftReconciliation
    (ShiftId, CellLocationId, ToolId, ReasonId, Note, DieShotCountBefore, DieShotCountAfter, AppUserId)
VALUES (@SecondShift, @EqA, (SELECT Id FROM Tools.Tool WHERE Code = N'TEST_AT_DIE'),
        (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongShift'), N'TEST_AT', 0, 0, 1);
DECLARE @RcH BIGINT = SCOPE_IDENTITY();

INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ReconciliationId)
VALUES (@LotId, @SecondShift, 7, 1, @At15, @EqA, @RcH);          -- written by a reconciliation
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId)
VALUES (@LotId, @SecondShift, 9, 1, @At15, @EqA);                 -- moved by a reconciliation
DECLARE @RcMoved BIGINT = SCOPE_IDENTITY();
INSERT INTO Workorder.DieCastReconciliationMove (ReconciliationId, LogEntityTypeId, EntityId, FromShiftId, ToShiftId)
VALUES (@RcH, (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DieCastContribution'), @RcMoved, @FirstShift, @SecondShift);
```

Add these assertions at the end of Test 1's batch (after the existing `[RS.create]` assertions):

```sql
DECLARE @nameRcW NVARCHAR(100) = (
    SELECT ss.Name FROM Workorder.DieCastContribution dc
    INNER JOIN Oee.Shift sh ON sh.Id = dc.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE dc.PieceDelta = 7 AND dc.CellLocationId = @EqA1);
DECLARE @nameRcM NVARCHAR(100) = (
    SELECT ss.Name FROM Workorder.DieCastContribution dc
    INNER JOIN Oee.Shift sh ON sh.Id = dc.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE dc.PieceDelta = 9 AND dc.CellLocationId = @EqA1);
EXEC test.Assert_IsEqual @TestName = N'[RS.create] a row a reconciliation WROTE is not re-derived',
     @Expected = N'TEST_AT_Second', @Actual = @nameRcW;
EXEC test.Assert_IsEqual @TestName = N'[RS.create] a row a reconciliation MOVED is not re-derived',
     @Expected = N'TEST_AT_Second', @Actual = @nameRcM;
```

The existing `Reattributed 2 events` assertion is the other half of this test: the two excluded rows must not be counted either.

- [ ] **Step 6: Run both suites**

Run:
```
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0062_Oee_ShiftAttribution"
```
Expected: `[Restamp]` passes; `0062` passes including the two new `[RS.create]` assertions and the unchanged `Reattributed 2 events`.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastEntry_Restamp.sql sql/migrations/repeatable/R__Oee_ShiftOverride_Restamp.sql sql/tests/0097_DieCast_Reconciliation/020_Workers.sql sql/tests/0062_Oee_ShiftAttribution/030_restamp.sql
git commit -m "feat(sql): re-file die cast rows to the right shift, and keep the override restamp off them"
```

---

### Task 10: The three functions the reconciliation reads through

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_ufn_DieCastLotCountLock.sql`
- Create: `sql/migrations/repeatable/R__Workorder_ufn_DieCastShiftStamp.sql`
- Create: `sql/migrations/repeatable/R__Oee_ufn_ShiftNeighbours.sql`
- Test: `sql/tests/0097_DieCast_Reconciliation/030_Functions.sql`

**Interfaces:**
- Produces: `Lots.ufn_DieCastLotCountLock(@LotId BIGINT)` -- inline TVF, one row, columns `IsLocked BIT`, `LockReason NVARCHAR(200)`. Locked when the LOT has a production event at any operation other than Die Cast, when its count was corrected by anything other than a reconciliation after it was released, when it is Closed or consumed, or when its status blocks production (A10).
- Produces: `Workorder.ufn_DieCastShiftStamp(@ShiftId BIGINT, @CellLocationId BIGINT, @ToolId BIGINT) RETURNS NVARCHAR(100)` -- counts and max ids of the contribution, reject and anchor rows for that shift x press x die. The screen loads it and the save refuses a different one (spec sec 8).
- Produces: `Oee.ufn_ShiftNeighbours(@ShiftId BIGINT, @Radius INT)` -- inline TVF, columns `ShiftId BIGINT`, `Offset INT`: the **closed** shift instances within `@Radius` positions of `@ShiftId`, excluding itself.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0097_DieCast_Reconciliation/030_Functions.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/030_Functions.sql
-- The count lock (spec sec 3.3), the stale-guard stamp (sec 8) and the
-- +/-2 shift neighbourhood (sec 7.3).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/030_Functions.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700201', @CavKey = N'CavA';                        -- open
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700202', @CavKey = N'CavA', @StatusCode = N'Good'; -- released, clean
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700203', @CavKey = N'CavB', @StatusCode = N'Good'; -- released, counted at trim
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700204', @CavKey = N'CavB', @StatusCode = N'Good'; -- released, count corrected
GO

-- ---- Lots.ufn_DieCastLotCountLock ----
DECLARE @Open BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700201');
DECLARE @Rel  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700202');
DECLARE @Trim BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700203');
DECLARE @Corr BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700204');
DECLARE @Usr  BIGINT = test.ufn_RC(N'Usr');
DECLARE @v NVARCHAR(400);

SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Open)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] an open LOT is not locked', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Rel)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a released LOT with nothing downstream is not locked', @Expected = N'0', @Actual = @v;

-- a production event at any operation other than Die Cast = counted downstream
DECLARE @Tmpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
                        INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
                        WHERE oty.Code <> N'DieCast' ORDER BY ot.Id);
IF @Tmpl IS NOT NULL
BEGIN
    INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
    VALUES (@Trim, @Tmpl, '2020-01-07T14:02:00', @Usr);
    SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Trim)) AS NVARCHAR(400));
    EXEC test.Assert_IsEqual @TestName = N'[Lock] a LOT counted downstream is locked', @Expected = N'1', @Actual = @v;
    SET @v = (SELECT LockReason FROM Lots.ufn_DieCastLotCountLock(@Trim));
    EXEC test.Assert_Contains @TestName = N'[Lock] ...and says where', @HaystackStr = @v, @NeedleStr = N'Counted at';
END

-- a count correction after release locks it; a reconciliation's own does not
INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, Reason, ChangedByUserId, ChangedAt)
VALUES (@Corr, N'PieceCount', N'10', N'12', N'Recount at the dock', @Usr, '2020-01-07T16:00:00');
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Corr)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a count corrected after release locks it', @Expected = N'1', @Actual = @v;

INSERT INTO Lots.LotAttributeChange (LotId, AttributeName, OldValue, NewValue, Reason, ChangedByUserId, ChangedAt)
VALUES (@Rel, N'PieceCount', N'10', N'12', N'Shift reconciliation #4: Shift not entered', @Usr, '2020-01-07T16:00:00');
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Rel)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a reconciliation''s own correction does not lock the LOT', @Expected = N'0', @Actual = @v;

UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed') WHERE Id = @Open;
SET @v = CAST((SELECT IsLocked FROM Lots.ufn_DieCastLotCountLock(@Open)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lock] a closed LOT is locked', @Expected = N'1', @Actual = @v;
GO

-- ---- Workorder.ufn_DieCastShiftStamp ----
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Before NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
DECLARE @Same NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
EXEC test.Assert_IsEqual @TestName = N'[Stamp] stable while nothing changes', @Expected = @Before, @Actual = @Same;

EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700202', @ShiftKey = N'S1', @Pieces = 10, @Reading = 10, @AtUtc = '2020-01-06T16:00:00';
DECLARE @After NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
DECLARE @Changed BIT = CASE WHEN @After <> @Before THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Stamp] changes when a row lands in the shift', @Condition = @Changed,
    @Detail = N'stamp did not change after a contribution was added';
GO

-- ---- Oee.ufn_ShiftNeighbours ----
DECLARE @S3 BIGINT = test.ufn_RC(N'S3');
DECLARE @v NVARCHAR(400);
SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2)
               WHERE ShiftId IN (test.ufn_RC(N'S1'), test.ufn_RC(N'S2'), test.ufn_RC(N'S4'), test.ufn_RC(N'S5'))) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] two either side', @Expected = N'4', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = @S3) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] never itself', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT Offset FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = test.ufn_RC(N'S1')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] offsets are signed distances', @Expected = N'-2', @Actual = @v;

UPDATE Oee.Shift SET ActualEnd = NULL WHERE Id = test.ufn_RC(N'S5');
SET @v = CAST((SELECT COUNT(*) FROM Oee.ufn_ShiftNeighbours(@S3, 2) WHERE ShiftId = test.ufn_RC(N'S5')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Neighbours] an open shift is not a target', @Expected = N'0', @Actual = @v;
UPDATE Oee.Shift SET ActualEnd = '2020-01-07T23:00:00' WHERE Id = test.ufn_RC(N'S5');
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to see it fail.** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"` -- the `[Lock]`, `[Stamp]` and `[Neighbours]` assertions fail (functions do not exist).

- [ ] **Step 3: Write `Lots.ufn_DieCastLotCountLock`**

```sql
-- ============================================================
-- Repeatable:  R__Lots_ufn_DieCastLotCountLock.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Is this die cast LOT's piece count settled downstream, and why
--              (spec 2026-09-21 sec 3.3)? At trim a total count is entered and
--              that number is what goes forward; once it has been, a die cast
--              shift reconciliation records the production but leaves the count
--              alone. The rule is derived from what is stored, never asked:
--
--                * a Workorder.ProductionEvent at any operation other than
--                  Die Cast -- trim has counted it;
--                * a Lots.LotAttributeChange on PieceCount after the LOT was
--                  released, other than a reconciliation's own (those carry
--                  'Shift reconciliation #...', so reconciling twice is not
--                  self-blocking);
--                * status Closed, or the LOT consumed into another;
--                * any status that blocks production -- Hold, Scrap (A10);
--                  Lots.Lot_RectifyPieceCount refuses those too.
--
--              Inline TVF: ONE row always, so an OUTER APPLY in a read proc
--              never drops a LOT. A NULL @LotId returns IsLocked = 0.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_DieCastLotCountLock (@LotId BIGINT)
RETURNS TABLE
AS
RETURN
SELECT CAST(CASE WHEN x.Reason IS NULL THEN 0 ELSE 1 END AS BIT) AS IsLocked,
       x.Reason AS LockReason
FROM (
    SELECT COALESCE(
        (SELECT TOP 1 N'Counted at ' + oty.Name + N' '
                + CONVERT(NVARCHAR(16), CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120)
         FROM Workorder.ProductionEvent pe
         INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
         INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
         WHERE pe.LotId = @LotId AND oty.Code <> N'DieCast'
         ORDER BY pe.EventAt),
        (SELECT TOP 1 N'Count corrected '
                + CONVERT(NVARCHAR(16), CAST(ac.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120)
         FROM Lots.LotAttributeChange ac
         WHERE ac.LotId = @LotId AND ac.AttributeName = N'PieceCount'
           AND ac.Reason NOT LIKE N'Shift reconciliation #%'
           AND ac.ChangedAt > ISNULL((SELECT MIN(h.ChangedAt) FROM Lots.LotStatusHistory h
                                      INNER JOIN Lots.LotStatusCode o ON o.Id = h.OldStatusId
                                      INNER JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
                                      WHERE h.LotId = @LotId AND o.Code = N'Open' AND n.Code = N'Good'), '9999-12-31')
         ORDER BY ac.ChangedAt),
        (SELECT TOP 1 CASE WHEN sc.Code = N'Closed' THEN N'LOT is closed'
                           ELSE N'LOT is ' + sc.Name END
         FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
         WHERE l.Id = @LotId AND (sc.Code = N'Closed' OR sc.BlocksProduction = 1)),
        (SELECT TOP 1 N'Consumed into another LOT'
         FROM Lots.LotGenealogy g WHERE g.ParentLotId = @LotId)
    ) AS Reason
) x;
GO
```

- [ ] **Step 4: Write `Workorder.ufn_DieCastShiftStamp`**

```sql
-- ============================================================
-- Repeatable:  R__Workorder_ufn_DieCastShiftStamp.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The stale guard for the shift reconciliation screen (spec
--              2026-09-21 sec 8). The screen reads this when it loads and
--              hands it back at save; a different value means somebody wrote
--              to -- or moved something out of -- this shift x press x die in
--              between, and the save is refused rather than applied to a
--              picture that has moved.
--
--              COUNTS as well as MAX ids: a row moved OUT lowers the count
--              without lowering any maximum.
--
--              Rows with a NULL CellLocationId are invisible to this (as they
--              are to the screen): the press is how the whole surface is
--              scoped, and a row without one is not attributable to a press.
-- ============================================================
CREATE OR ALTER FUNCTION Workorder.ufn_DieCastShiftStamp
(
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
)
RETURNS NVARCHAR(100)
AS
BEGIN
    DECLARE @CCount INT, @CMax BIGINT, @RCount INT, @RMax BIGINT, @AMax BIGINT;

    SELECT @CCount = COUNT(*), @CMax = ISNULL(MAX(c.Id), 0)
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId;

    SELECT @RCount = COUNT(*), @RMax = ISNULL(MAX(r.Id), 0)
    FROM Workorder.RejectEvent r
    WHERE r.ShiftId = @ShiftId AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId;

    SELECT @AMax = ISNULL(MAX(a.Id), 0)
    FROM Workorder.DieCastCounterAnchor a
    WHERE a.ShiftId = @ShiftId AND a.ToolId = @ToolId
      AND ISNULL(a.CellLocationId, -1) = ISNULL(@CellLocationId, -1);

    RETURN CONCAT(@CCount, N'.', @CMax, N'.', @RCount, N'.', @RMax, N'.', @AMax);
END;
GO
```

- [ ] **Step 5: Write `Oee.ufn_ShiftNeighbours`**

```sql
-- ============================================================
-- Repeatable:  R__Oee_ufn_ShiftNeighbours.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The CLOSED shift instances within @Radius positions of a given
--              shift, with their signed distance. One definition, used by the
--              shift reconciliation's move targets and by the save's guard
--              that an entry only moves within two shifts of the one being
--              reconciled (spec 2026-09-21 sec 7.3).
--
--              Position is Oee.Shift ordered by ActualStart -- the B3
--              single-open invariant makes that a straight line. The open
--              shift is never a target: the live screen owns it.
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftNeighbours (@ShiftId BIGINT, @Radius INT)
RETURNS TABLE
AS
RETURN
WITH o AS (
    SELECT s.Id, s.ActualEnd, ROW_NUMBER() OVER (ORDER BY s.ActualStart, s.Id) AS rn
    FROM Oee.Shift s
)
SELECT o.Id AS ShiftId, o.rn - me.rn AS Offset
FROM o
CROSS JOIN (SELECT rn FROM o WHERE Id = @ShiftId) me
WHERE o.rn BETWEEN me.rn - @Radius AND me.rn + @Radius
  AND o.Id <> @ShiftId
  AND o.ActualEnd IS NOT NULL;
GO
```

- [ ] **Step 6: Run the test.** Same command. Expected: every `[Lock]`, `[Stamp]`, `[Neighbours]` assertion passes.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_ufn_DieCastLotCountLock.sql sql/migrations/repeatable/R__Workorder_ufn_DieCastShiftStamp.sql sql/migrations/repeatable/R__Oee_ufn_ShiftNeighbours.sql sql/tests/0097_DieCast_Reconciliation/030_Functions.sql
git commit -m "feat(sql): count lock, shift stamp and shift neighbourhood functions"
```

---

### Task 11: The reconciliation screen's reads

**Files:**
- Create: `R__Workorder_DieCastShiftReconciliation_GetHeader.sql`, `..._ListEntries.sql`, `..._ListLots.sql`, `..._ListRejects.sql`, `..._ListMoveTargets.sql`, `R__Workorder_DieCastReconciliationReason_List.sql`, `R__Lots_DieCastLot_ResolveLtt.sql` (all in `sql/migrations/repeatable/`)
- Test: `sql/tests/0097_DieCast_Reconciliation/040_Reads.sql`

**Interfaces (one result set each, no OUTPUT params, Eastern at the boundary):**
- `Workorder.DieCastShiftReconciliation_GetHeader @ShiftId, @CellLocationId, @ToolId` -> `ShiftId, ShiftLabel, StartEt, EndEt, IsOpen, CellLocationId, PressCode, PressName, ToolId, AssetNumber, DieName, ActiveCavities, DieShotCount, RecordedTotalShots, RecordedWarmUpShots, RecordedNoGood, RecordedGood, HasShiftEndNumber, Stamp, LastReconciledAtEt, LastReconciledBy`.
- `..._ListEntries @ShiftId, @CellLocationId, @ToolId` -> one row per **entry** (rows by the same user within 10 seconds, reconciliation rows grouped by their reconciliation): `EntryKey, EnteredAtEt, EnteredBy, ReconciliationId, EnteredDuringShiftId, EnteredDuringShift, Reading, Pieces, Lots, WarmUpPieces, OtherScrapPieces, RowCount, ContributionIds, RejectIds`.
- `..._ListLots @ShiftId, @CellLocationId, @ToolId` -> `LotId, Ltt, ItemId, PartNumber, PartDescription, ToolCavityId, CavityCode, Recorded, PieceCount, InventoryAvailable, StatusCode, StatusName, NowAt, ReleasedAtEt, IsLocked, LockReason`, ordered by part then cavity then LTT.
- `..._ListRejects @ShiftId, @CellLocationId, @ToolId` -> `DefectCodeId, DefectCode, Defect, IsNonRejectScrap, ItemId, PartNumber, Quantity, Cavities, ApprovedBy` (warm-up `999` excluded -- it is a field of its own on the screen).
- `..._ListMoveTargets @ShiftId, @CellLocationId, @ToolId` -> `ShiftId, ShiftLabel, StartEt, EndEt, Offset, GoodRecorded`.
- `Workorder.DieCastReconciliationReason_List` -> `Id, Code, Name, RequiresNote`.
- `Lots.DieCastLot_ResolveLtt @Ltt NVARCHAR(50), @ToolId BIGINT` -> `Ltt, Result ('New' | 'OnThisDie' | 'Elsewhere' | 'Invalid'), LotId, ToolCavityId, CavityCode, ItemId, PartNumber, PieceCount, Message`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0097_DieCast_Reconciliation/040_Reads.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/040_Reads.sql
-- The reads behind the reconciliation screen (spec sec 6.2, amendment A6).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/040_Reads.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700301', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700302', @CavKey = N'CavB', @StatusCode = N'Good';
GO
-- One entry: two credits and two warm-up rows by the same user, seconds apart,
-- all filed under S4 but entered during S4's morning (08:35 ET = 13:35 UTC).
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700301', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700302', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:03';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:03';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'008', @Qty = 3,  @AtUtc = '2020-01-07T13:35:04';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavB', @DefectCode = N'008', @Qty = 3,  @AtUtc = '2020-01-07T13:35:04';
GO

DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- ---- GetHeader ----
CREATE TABLE #H (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3), IsOpen BIT,
                 CellLocationId BIGINT, PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT,
                 AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ActiveCavities INT, DieShotCount INT,
                 RecordedTotalShots INT, RecordedWarmUpShots INT, RecordedNoGood INT, RecordedGood INT,
                 HasShiftEndNumber BIT, Stamp NVARCHAR(100), LastReconciledAtEt DATETIME2(3), LastReconciledBy NVARCHAR(20));
INSERT INTO #H EXEC Workorder.DieCastShiftReconciliation_GetHeader @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = (SELECT CONCAT(ActiveCavities, N'|', DieShotCount, N'|', RecordedTotalShots, N'|', RecordedWarmUpShots, N'|', RecordedNoGood, N'|', RecordedGood, N'|', HasShiftEndNumber) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[Header] cavities, die life and what is on record', @Expected = N'2|10000|991|35|6|1906|1', @Actual = @v;
SET @v = (SELECT AssetNumber + N' / ' + DieName FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[Header] the die by asset number and name', @Expected = N'RC-DIE / Reconciliation Test Die', @Actual = @v;
SET @v = (SELECT CONVERT(NVARCHAR(19), StartEt, 126) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[Header] shift window is Eastern, as stored', @Expected = N'2020-01-07T07:00:00', @Actual = @v;
DROP TABLE #H;

-- ---- ListEntries ----
CREATE TABLE #E (EntryKey NVARCHAR(100), EnteredAtEt DATETIME2(3), EnteredBy NVARCHAR(20), ReconciliationId BIGINT,
                 EnteredDuringShiftId BIGINT, EnteredDuringShift NVARCHAR(120), Reading INT, Pieces INT, Lots INT,
                 WarmUpPieces INT, OtherScrapPieces INT, RowCount INT, ContributionIds NVARCHAR(MAX), RejectIds NVARCHAR(MAX));
INSERT INTO #E EXEC Workorder.DieCastShiftReconciliation_ListEntries @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #E) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Entries] six rows seconds apart are ONE entry', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CONCAT(Reading, N'|', Pieces, N'|', Lots, N'|', WarmUpPieces, N'|', OtherScrapPieces, N'|', RowCount) FROM #E);
EXEC test.Assert_IsEqual @TestName = N'[Entries] its reading, pieces, LOTs, warm-up, scrap and row count', @Expected = N'991|1906|2|70|6|6', @Actual = @v;
SET @v = (SELECT CONVERT(NVARCHAR(19), EnteredAtEt, 126) FROM #E);
EXEC test.Assert_IsEqual @TestName = N'[Entries] entered-at is Eastern', @Expected = N'2020-01-07T08:35:00', @Actual = @v;
SET @v = CAST((SELECT EnteredDuringShiftId FROM #E) AS NVARCHAR(400));
SET @Want = CAST(@S4 AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Entries] entered-during resolves from the clock', @Expected = @Want, @Actual = @v;
SET @v = CAST((SELECT LEN(ContributionIds) - LEN(REPLACE(ContributionIds, N',', N'')) + 1 FROM #E) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Entries] carries both contribution ids for the move', @Expected = N'2', @Actual = @v;
DROP TABLE #E;
GO

DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- ---- ListLots ----
CREATE TABLE #L (LotId BIGINT, Ltt NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50), PartDescription NVARCHAR(200),
                 ToolCavityId BIGINT, CavityCode NVARCHAR(10), Recorded INT, PieceCount INT, InventoryAvailable INT,
                 StatusCode NVARCHAR(20), StatusName NVARCHAR(100), NowAt NVARCHAR(200), ReleasedAtEt DATETIME2(3),
                 IsLocked BIT, LockReason NVARCHAR(200));
INSERT INTO #L EXEC Workorder.DieCastShiftReconciliation_ListLots @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #L) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lots] both LOTs credited in the shift', @Expected = N'2', @Actual = @v;
SET @v = (SELECT CONCAT(Recorded, N'|', PieceCount, N'|', StatusCode, N'|', IsLocked) FROM #L WHERE Ltt = N'99700301');
EXEC test.Assert_IsEqual @TestName = N'[Lots] recorded in THIS shift, plus the LOT''s own count and lock', @Expected = N'953|953|Good|0', @Actual = @v;
DROP TABLE #L;

-- ---- ListRejects ----
CREATE TABLE #R (DefectCodeId BIGINT, DefectCode NVARCHAR(20), Defect NVARCHAR(200), IsNonRejectScrap BIT,
                 ItemId BIGINT, PartNumber NVARCHAR(50), Quantity INT, Cavities INT, ApprovedBy NVARCHAR(20));
INSERT INTO #R EXEC Workorder.DieCastShiftReconciliation_ListRejects @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #R WHERE DefectCode = N'999') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Rejects] warm-up is not a reject line', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT SUM(Quantity) FROM #R WHERE DefectCode = N'008') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Rejects] the test parts, per part', @Expected = N'6', @Actual = @v;
DROP TABLE #R;

-- ---- ListMoveTargets ----
CREATE TABLE #M (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3), Offset INT, GoodRecorded INT);
INSERT INTO #M EXEC Workorder.DieCastShiftReconciliation_ListMoveTargets @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #M) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Targets] four shifts within two of S4', @Expected = N'4', @Actual = @v;
SET @v = CAST((SELECT GoodRecorded FROM #M WHERE ShiftId = test.ufn_RC(N'S3')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Targets] each target shows what it already holds', @Expected = N'0', @Actual = @v;
DROP TABLE #M;

-- ---- Reason_List ----
CREATE TABLE #Rs (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), RequiresNote BIT);
INSERT INTO #Rs EXEC Workorder.DieCastReconciliationReason_List;
SET @v = CAST((SELECT COUNT(*) FROM #Rs) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Reasons] four, in order', @Expected = N'4', @Actual = @v;
DROP TABLE #Rs;
GO

-- ---- ResolveLtt ----
DECLARE @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @v NVARCHAR(400);
CREATE TABLE #X (Ltt NVARCHAR(50), Result NVARCHAR(20), LotId BIGINT, ToolCavityId BIGINT, CavityCode NVARCHAR(10),
                 ItemId BIGINT, PartNumber NVARCHAR(50), PieceCount INT, Message NVARCHAR(400));
INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'99700999', @ToolId = @Tool;
SET @v = (SELECT Result FROM #X);
EXEC test.Assert_IsEqual @TestName = N'[Ltt] an unused, valid LTT is New', @Expected = N'New', @Actual = @v;
DELETE FROM #X;
INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'12345', @ToolId = @Tool;
SET @v = (SELECT Result FROM #X);
EXEC test.Assert_IsEqual @TestName = N'[Ltt] five digits is not an LTT', @Expected = N'Invalid', @Actual = @v;
DELETE FROM #X;
INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'99700301', @ToolId = @Tool;
SET @v = (SELECT CONCAT(Result, N'|', CavityCode) FROM #X);
EXEC test.Assert_IsEqual @TestName = N'[Ltt] a LOT on this die resolves to its cavity', @Expected = N'OnThisDie|a', @Actual = @v;
DELETE FROM #X;
DECLARE @Other BIGINT = (SELECT TOP 1 Id FROM Tools.Tool WHERE Code <> N'RC-DIE' ORDER BY Id);
IF @Other IS NOT NULL
BEGIN
    INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'99700301', @ToolId = @Other;
    SET @v = (SELECT Result FROM #X);
    EXEC test.Assert_IsEqual @TestName = N'[Ltt] a LOT from another die is refused', @Expected = N'Elsewhere', @Actual = @v;
    SET @v = (SELECT Message FROM #X);
    EXEC test.Assert_Contains @TestName = N'[Ltt] ...naming where it belongs', @HaystackStr = @v, @NeedleStr = N'Asset # RC-DIE';
END
DROP TABLE #X;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to see it fail.** All `[Header]`, `[Entries]`, `[Lots]`, `[Rejects]`, `[Targets]`, `[Reasons]`, `[Ltt]` assertions fail.

- [ ] **Step 3: Write `_GetHeader`**

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_GetHeader.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: What the reconciliation screen puts in its banner and its
--              Recorded column (spec 2026-09-21 sec 6.2, amendment A6).
--              ONE result set, no OUTPUT params; an empty result set means the
--              shift, press or die does not exist.
--
--              Oee.Shift times are Eastern already (OI-38) and are returned
--              raw. Everything else here is a count, not a time.
--
--              RecordedTotalShots is the die watermark -- anchor-aware, so a
--              previous reconciliation's declared total is what shows.
--              RecordedWarmUpShots divides the 999 pieces by the ACTIVE cavity
--              count, which is how they were fanned out in the first place.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_GetHeader
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @WarmCodeId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
    DECLARE @Cavities INT = (SELECT COUNT(*) FROM Tools.ToolCavity tc
                             INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
                             WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND cs.Code = N'Active');

    SELECT
        s.Id                                                              AS ShiftId,
        CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name         AS ShiftLabel,
        s.ActualStart                                                     AS StartEt,
        s.ActualEnd                                                       AS EndEt,
        CAST(CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS BIT)      AS IsOpen,
        loc.Id                                                            AS CellLocationId,
        loc.Code                                                          AS PressCode,
        loc.Name                                                          AS PressName,
        t.Id                                                              AS ToolId,
        t.Code                                                            AS AssetNumber,
        t.Name                                                            AS DieName,
        @Cavities                                                         AS ActiveCavities,
        t.ShotCount                                                       AS DieShotCount,
        Workorder.ufn_DieShotWatermark(t.Id, s.Id, loc.Id)                AS RecordedTotalShots,
        CASE WHEN @Cavities > 0 THEN ISNULL(sc.WarmUpPieces, 0) / @Cavities ELSE 0 END AS RecordedWarmUpShots,
        ISNULL(sc.NoGoodPieces, 0)                                        AS RecordedNoGood,
        ISNULL(cr.Good, 0)                                                AS RecordedGood,
        CAST(CASE WHEN cr.Readings > 0 OR an.Anchors > 0 THEN 1 ELSE 0 END AS BIT) AS HasShiftEndNumber,
        Workorder.ufn_DieCastShiftStamp(s.Id, loc.Id, t.Id)               AS Stamp,
        lr.LastReconciledAtEt,
        lr.LastReconciledBy
    FROM Oee.Shift s
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    INNER JOIN Location.Location loc ON loc.Id = @CellLocationId
    INNER JOIN Tools.Tool t ON t.Id = @ToolId
    OUTER APPLY (SELECT ISNULL(SUM(c.PieceDelta), 0) AS Good, COUNT(c.ShotCounterReading) AS Readings
                 FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
                 WHERE c.ShiftId = s.Id AND c.CellLocationId = loc.Id AND l.ToolId = t.Id) cr
    OUTER APPLY (SELECT ISNULL(SUM(CASE WHEN r.DefectCodeId = @WarmCodeId THEN r.Quantity ELSE 0 END), 0) AS WarmUpPieces,
                        ISNULL(SUM(CASE WHEN r.DefectCodeId = @WarmCodeId THEN 0 ELSE r.Quantity END), 0) AS NoGoodPieces
                 FROM Workorder.RejectEvent r
                 WHERE r.ShiftId = s.Id AND r.CellLocationId = loc.Id AND r.ToolId = t.Id) sc
    OUTER APPLY (SELECT COUNT(*) AS Anchors FROM Workorder.DieCastCounterAnchor a
                 WHERE a.ShiftId = s.Id AND a.ToolId = t.Id AND a.CellLocationId = loc.Id) an
    OUTER APPLY (SELECT TOP 1
                        CAST(h.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastReconciledAtEt,
                        u.Initials AS LastReconciledBy
                 FROM Workorder.DieCastShiftReconciliation h
                 INNER JOIN Location.AppUser u ON u.Id = h.AppUserId
                 WHERE h.ShiftId = s.Id AND h.CellLocationId = loc.Id AND h.ToolId = t.Id
                 ORDER BY h.CreatedAt DESC, h.Id DESC) lr
    WHERE s.Id = @ShiftId;
END;
GO
```

- [ ] **Step 4: Write `_ListEntries`**

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListEntries.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: What is already on record for this shift x press x die, grouped
--              into ENTRIES (spec 2026-09-21 sec 3.7, 6.2).
--
--              Nothing stored identifies one submission: every INSERT called
--              SYSUTCDATETIME() separately, so one entry's rows differ by
--              milliseconds. The grouping is therefore gaps-and-islands: same
--              user, same reconciliation (or none), each row within 10 seconds
--              of the previous one. It is PRESENTATION only -- the move takes
--              explicit row ids, which this proc hands back in
--              ContributionIds / RejectIds, so a wrong grouping can never
--              produce a wrong write.
--
--              EnteredDuringShift is the shift the clock says the entry was
--              made in. For releases typed at the press it is reliable and
--              disagreeing with the filed shift is the tell; for a shift-end
--              entry typed the next morning it is not, which is why the screen
--              shows it as information rather than a suggestion.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListEntries
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @WarmCodeId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');

    ;WITH r AS (
        SELECT CAST(N'Contribution' AS NVARCHAR(20)) AS EntityType, c.Id AS EntityId, c.AppUserId,
               c.EventAt AS At, c.ShotCounterReading AS Reading, c.PieceDelta AS Pieces,
               0 AS WarmUp, 0 AS OtherScrap, c.LotId, c.ReconciliationId
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId
        UNION ALL
        SELECT N'Reject', re.Id, re.AppUserId, re.RecordedAt, NULL, 0,
               CASE WHEN re.DefectCodeId = @WarmCodeId THEN re.Quantity ELSE 0 END,
               CASE WHEN re.DefectCodeId = @WarmCodeId THEN 0 ELSE re.Quantity END,
               re.LotId, re.ReconciliationId
        FROM Workorder.RejectEvent re
        WHERE re.ShiftId = @ShiftId AND re.CellLocationId = @CellLocationId AND re.ToolId = @ToolId
    ),
    g AS (
        SELECT r.*,
               CASE WHEN DATEDIFF(SECOND, LAG(r.At) OVER (PARTITION BY r.AppUserId, ISNULL(r.ReconciliationId, 0)
                                                          ORDER BY r.At, r.EntityId), r.At) <= 10
                    THEN 0 ELSE 1 END AS NewGrp
        FROM r
    ),
    k AS (
        SELECT g.*, SUM(g.NewGrp) OVER (PARTITION BY g.AppUserId, ISNULL(g.ReconciliationId, 0)
                                        ORDER BY g.At, g.EntityId ROWS UNBOUNDED PRECEDING) AS Grp
        FROM g
    ),
    e AS (
        SELECT CONCAT(k.AppUserId, N'-', ISNULL(k.ReconciliationId, 0), N'-', k.Grp) AS EntryKey,
               k.AppUserId, k.ReconciliationId,
               MIN(k.At) AS FirstAt, MAX(k.Reading) AS Reading, SUM(k.Pieces) AS Pieces,
               SUM(k.WarmUp) AS WarmUpPieces, SUM(k.OtherScrap) AS OtherScrapPieces,
               COUNT(DISTINCT CASE WHEN k.EntityType = N'Contribution' THEN k.LotId END) AS Lots,
               COUNT(*) AS RowCount,
               STRING_AGG(CASE WHEN k.EntityType = N'Contribution' THEN CAST(k.EntityId AS NVARCHAR(MAX)) END, N',') AS ContributionIds,
               STRING_AGG(CASE WHEN k.EntityType = N'Reject'       THEN CAST(k.EntityId AS NVARCHAR(MAX)) END, N',') AS RejectIds
        FROM k
        GROUP BY k.AppUserId, k.ReconciliationId, k.Grp
    )
    SELECT e.EntryKey,
           CAST(e.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EnteredAtEt,
           u.Initials AS EnteredBy,
           e.ReconciliationId,
           ds.ShiftId AS EnteredDuringShiftId,
           ds.ShiftLabel AS EnteredDuringShift,
           e.Reading, e.Pieces, e.Lots, e.WarmUpPieces, e.OtherScrapPieces, e.RowCount,
           e.ContributionIds, e.RejectIds
    FROM e
    INNER JOIN Location.AppUser u ON u.Id = e.AppUserId
    OUTER APPLY (
        SELECT TOP 1 s.Id AS ShiftId, CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS ShiftLabel
        FROM Oee.Shift s
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.ActualStart <= CAST(e.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
          AND ISNULL(s.ActualEnd, '9999-12-31') > CAST(e.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
        ORDER BY s.ActualStart DESC) ds
    ORDER BY e.FirstAt;
END;
GO
```

- [ ] **Step 5: Write `_ListLots`, `_ListRejects`, `_ListMoveTargets`, `Reason_List`**

`R__Workorder_DieCastShiftReconciliation_ListLots.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListLots.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Every LOT the reconciliation screen lists for this shift x
--              press x die: the ones credited in the shift, plus any opened on
--              this die during it (an Open LOT at zero still belongs on the
--              list). Recorded is what this SHIFT credited; PieceCount is the
--              LOT's own total. IsLocked / LockReason come from
--              Lots.ufn_DieCastLotCountLock -- spec sec 3.3's three states are
--              Open (credit), released-and-clean (correct), locked (stands).
--              Ordered part, then cavity, then LTT -- the press sheet's order.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListLots
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StartEt DATETIME2(3), @EndEt DATETIME2(3);
    SELECT @StartEt = s.ActualStart, @EndEt = s.ActualEnd FROM Oee.Shift s WHERE s.Id = @ShiftId;
    DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @EndUtc DATETIME2(3) = CASE WHEN @EndEt IS NULL THEN SYSUTCDATETIME()
                                        ELSE CAST(@EndEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END;

    ;WITH rec AS (
        SELECT c.LotId, SUM(c.PieceDelta) AS Recorded
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId
        GROUP BY c.LotId
    ),
    ids AS (
        SELECT LotId FROM rec
        UNION
        SELECT l.Id FROM Lots.Lot l
        WHERE l.ToolId = @ToolId AND l.CreatedAt >= @StartUtc AND l.CreatedAt < @EndUtc
          AND ISNULL(l.ProducedAtLocationId, @CellLocationId) = @CellLocationId
    )
    SELECT l.Id AS LotId, l.LotName AS Ltt, l.ItemId, i.PartNumber, i.Description AS PartDescription,
           l.ToolCavityId, tc.CavityCode, ISNULL(rec.Recorded, 0) AS Recorded,
           l.PieceCount, l.InventoryAvailable, sc.Code AS StatusCode, sc.Name AS StatusName,
           cl.Name AS NowAt, rel.ReleasedAtEt, lk.IsLocked, lk.LockReason
    FROM ids
    INNER JOIN Lots.Lot l ON l.Id = ids.LotId
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
    LEFT JOIN Location.Location cl ON cl.Id = l.CurrentLocationId
    LEFT JOIN rec ON rec.LotId = l.Id
    OUTER APPLY (SELECT MIN(CAST(h.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))) AS ReleasedAtEt
                 FROM Lots.LotStatusHistory h
                 INNER JOIN Lots.LotStatusCode o ON o.Id = h.OldStatusId
                 INNER JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
                 WHERE h.LotId = l.Id AND o.Code = N'Open' AND n.Code = N'Good') rel
    OUTER APPLY Lots.ufn_DieCastLotCountLock(l.Id) lk
    ORDER BY i.PartNumber, tc.CavityCode, l.LotName;
END;
GO
```

`R__Workorder_DieCastShiftReconciliation_ListRejects.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListRejects.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The reject block's Recorded side: scrap on record for this
--              shift x press x die, by reason and part (spec sec 6.2).
--              Warm-up (999) is excluded -- it is its own field on the screen
--              and is entered in shots, not as a reject line (A7).
--              A net-zero pair (a reconciliation's compensating row cancelling
--              an earlier one) drops out: nothing is on record any more.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListRejects
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT re.DefectCodeId, dc.Code AS DefectCode, dc.Description AS Defect, dc.IsNonRejectScrap,
           re.ItemId, i.PartNumber, SUM(re.Quantity) AS Quantity,
           COUNT(DISTINCT re.ToolCavityId) AS Cavities, MAX(u.Initials) AS ApprovedBy
    FROM Workorder.RejectEvent re
    INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
    LEFT JOIN Parts.Item i ON i.Id = re.ItemId
    LEFT JOIN Location.AppUser u ON u.Id = re.ApprovedByUserId
    WHERE re.ShiftId = @ShiftId AND re.CellLocationId = @CellLocationId AND re.ToolId = @ToolId
      AND dc.Code <> N'999'
    GROUP BY re.DefectCodeId, dc.Code, dc.Description, dc.IsNonRejectScrap, re.ItemId, i.PartNumber
    HAVING SUM(re.Quantity) <> 0
    ORDER BY dc.Code, i.PartNumber;
END;
GO
```

`R__Workorder_DieCastShiftReconciliation_ListMoveTargets.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListMoveTargets.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Where an entry filed against the wrong shift may move: the
--              CLOSED shifts within two of this one (Oee.ufn_ShiftNeighbours),
--              each with what it already holds for this press and die, so
--              moving onto a shift that already has an entry is visible before
--              it happens (spec sec 7.3). Nothing is pre-selected on screen.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListMoveTargets
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id AS ShiftId,
           CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS ShiftLabel,
           s.ActualStart AS StartEt, s.ActualEnd AS EndEt, n.Offset,
           ISNULL(g.Good, 0) AS GoodRecorded
    FROM Oee.ufn_ShiftNeighbours(@ShiftId, 2) n
    INNER JOIN Oee.Shift s ON s.Id = n.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    OUTER APPLY (SELECT SUM(c.PieceDelta) AS Good
                 FROM Workorder.DieCastContribution c
                 INNER JOIN Lots.Lot l ON l.Id = c.LotId
                 WHERE c.ShiftId = s.Id AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId) g
    ORDER BY s.ActualStart;
END;
GO
```

`R__Workorder_DieCastReconciliationReason_List.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastReconciliationReason_List.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Why a team lead is reconciling a past shift (migration 0097).
--              Read-only code table; feeds the Reason dropdown. RequiresNote
--              is surfaced so the screen can demand the note at the field
--              instead of letting the save reject.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastReconciliationReason_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.Id, r.Code, r.Name, r.RequiresNote
    FROM Workorder.DieCastReconciliationReason r
    ORDER BY r.SortOrder, r.Name;
END;
GO
```

- [ ] **Step 6: Write `Lots.DieCastLot_ResolveLtt`**

```sql
-- ============================================================
-- Repeatable:  R__Lots_DieCastLot_ResolveLtt.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: What happens if this LTT is added to this die's reconciliation
--              (spec 2026-09-21 sec 6.3). Called as the team lead scans or
--              types each LTT off the physical LOT, so the answer arrives at
--              the field and never at the save:
--
--                New        -- not in the MES and a valid 8-9 digit LTT: a new
--                              LOT, created and released to Warehouse at save;
--                OnThisDie  -- already a LOT on this die: adds to that LOT;
--                Elsewhere  -- a LOT on another press or die, or not a die cast
--                              LOT at all: refused, naming where it belongs;
--                Invalid    -- not an LTT.
--
--              ONE result set with the same shape on every branch (the screen
--              binds one table). A die is named name-first, then Asset #.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.DieCastLot_ResolveLtt
    @Ltt    NVARCHAR(50),
    @ToolId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Ltt = LTRIM(RTRIM(ISNULL(@Ltt, N'')));

    IF NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @Ltt)
    BEGIN
        DECLARE @Valid BIT = Lots.ufn_IsValidExternalLtt(@Ltt);
        SELECT @Ltt AS Ltt,
               CASE WHEN @Valid = 1 THEN N'New' ELSE N'Invalid' END AS Result,
               CAST(NULL AS BIGINT) AS LotId, CAST(NULL AS BIGINT) AS ToolCavityId,
               CAST(NULL AS NVARCHAR(10)) AS CavityCode, CAST(NULL AS BIGINT) AS ItemId,
               CAST(NULL AS NVARCHAR(50)) AS PartNumber, CAST(NULL AS INT) AS PieceCount,
               CASE WHEN @Valid = 1 THEN N'New LOT ' + @Ltt + N' -- created and released to Warehouse when you save.'
                    ELSE N'An LTT is 8 or 9 digits. Check the number on the ticket.' END AS Message;
        RETURN;
    END

    SELECT l.LotName AS Ltt,
           CASE WHEN l.ToolId = @ToolId THEN N'OnThisDie' ELSE N'Elsewhere' END AS Result,
           l.Id AS LotId, l.ToolCavityId, tc.CavityCode, l.ItemId, i.PartNumber, l.PieceCount,
           CASE
               WHEN l.ToolId = @ToolId
                   THEN l.LotName + N' is already on this die, cavity ' + ISNULL(tc.CavityCode, N'?')
                        + N' -- its actual adds to that LOT.'
               WHEN l.ToolId IS NULL
                   THEN l.LotName + N' is ' + ISNULL(i.PartNumber, N'another part') + N' at '
                        + ISNULL(cl.Name, N'an unknown location') + N', not a die cast LOT.'
               ELSE l.LotName + N' is ' + ISNULL(pl.Name, N'another press') + N' ' + Audit.ufn_MidDot() + N' '
                    + ot.Name + N' (Asset # ' + ot.Code + N')'
                    + ISNULL(N', cavity ' + tc.CavityCode, N'') + N'.'
           END AS Message
    FROM Lots.Lot l
    LEFT JOIN Parts.Item i ON i.Id = l.ItemId
    LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
    LEFT JOIN Tools.Tool ot ON ot.Id = l.ToolId
    LEFT JOIN Location.Location cl ON cl.Id = l.CurrentLocationId
    OUTER APPLY (SELECT TOP 1 x.Name FROM (
                     SELECT loc.Name, 1 AS Pri FROM Location.Location loc WHERE loc.Id = l.ProducedAtLocationId
                     UNION ALL
                     SELECT loc.Name, 2 FROM Workorder.DieCastContribution c
                       INNER JOIN Location.Location loc ON loc.Id = c.CellLocationId WHERE c.LotId = l.Id
                     UNION ALL
                     SELECT loc.Name, 3 FROM Tools.ToolAssignment ta
                       INNER JOIN Location.Location loc ON loc.Id = ta.CellLocationId
                       WHERE ta.ToolId = l.ToolId AND ta.ReleasedAt IS NULL) x
                 ORDER BY x.Pri) pl
    WHERE l.LotName = @Ltt;
END;
GO
```

- [ ] **Step 7: Run the test.** Expected: every assertion in `040_Reads.sql` passes.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_GetHeader.sql sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListEntries.sql sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListLots.sql sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListRejects.sql sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListMoveTargets.sql sql/migrations/repeatable/R__Workorder_DieCastReconciliationReason_List.sql sql/migrations/repeatable/R__Lots_DieCastLot_ResolveLtt.sql sql/tests/0097_DieCast_Reconciliation/040_Reads.sql
git commit -m "feat(sql): reads behind the die cast shift reconciliation screen"
```

---

### Task 12: The landing list and the dashboard signal

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListShifts.sql`
- Create: `sql/migrations/repeatable/R__Workorder_DieCastShift_ListUnreconciled.sql`
- Test: `sql/tests/0097_DieCast_Reconciliation/050_Landing.sql`

**Interfaces:**
- `Workorder.DieCastShiftReconciliation_ListShifts @CellLocationId BIGINT, @Days INT = 7, @AtMoment DATETIME2(3) = NULL` -> one row per shift x die mounted or producing on that press, newest first: `ShiftId, ShiftLabel, StartEt, EndEt, ToolId, AssetNumber, DieName, ContributionRows, GoodRecorded, ShiftEndReading, StatusCode, ReconciledBy, ReconciledAtEt`. `StatusCode` is `Open` | `Reconciled` | `ReleasedNoShiftEnd` | `EntryRecorded` | `NoEntry`.
- `Workorder.DieCastShift_ListUnreconciled @Days INT = 7, @AtMoment DATETIME2(3) = NULL` -> the dashboard tile's rows: closed shift x press x die with production recorded, **no** counter reading, no anchor and no reconciliation: `ShiftId, ShiftLabel, StartEt, CellLocationId, PressCode, PressName, ToolId, AssetNumber, DieName, ContributionRows, GoodRecorded`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0097_DieCast_Reconciliation/050_Landing.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/050_Landing.sql
-- The landing list (spec sec 6.1) and the dashboard signal (sec 6.4).
-- "No entry" is neutral -- the MES cannot tell a missed entry from a press
-- that did not run. Amber is only ever a positive finding: production
-- released with no shift-end number.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/050_Landing.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700401', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700402', @CavKey = N'CavB', @StatusCode = N'Good';
GO
-- S1: a proper shift-end entry (a reading). S2: releases only, no reading.
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700401', @ShiftKey = N'S1', @Pieces = 100, @Reading = 110, @AtUtc = '2020-01-06T19:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700402', @ShiftKey = N'S2', @Pieces = 66,  @Reading = NULL, @AtUtc = '2020-01-07T01:00:00';
GO

DECLARE @Cell BIGINT = test.ufn_RC(N'Cell');
DECLARE @At DATETIME2(3) = '2020-01-08T12:00:00';   -- UTC "now" for the window
DECLARE @v NVARCHAR(400);

CREATE TABLE #S (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3),
                 ToolId BIGINT, AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ContributionRows INT,
                 GoodRecorded INT, ShiftEndReading INT, StatusCode NVARCHAR(30),
                 ReconciledBy NVARCHAR(20), ReconciledAtEt DATETIME2(3));
INSERT INTO #S EXEC Workorder.DieCastShiftReconciliation_ListShifts @CellLocationId = @Cell, @Days = 7, @AtMoment = @At;

SET @v = (SELECT StatusCode FROM #S WHERE ShiftId = test.ufn_RC(N'S1'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] a shift with a reading reads Entry recorded', @Expected = N'EntryRecorded', @Actual = @v;
SET @v = (SELECT StatusCode FROM #S WHERE ShiftId = test.ufn_RC(N'S2'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] released with no shift-end number is the amber case', @Expected = N'ReleasedNoShiftEnd', @Actual = @v;
SET @v = (SELECT StatusCode FROM #S WHERE ShiftId = test.ufn_RC(N'S3'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] a quiet shift is neutral, not amber', @Expected = N'NoEntry', @Actual = @v;
SET @v = (SELECT CONCAT(AssetNumber, N'|', GoodRecorded, N'|', ShiftEndReading) FROM #S WHERE ShiftId = test.ufn_RC(N'S1'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] die asset number, good recorded and the reading', @Expected = N'RC-DIE|100|110', @Actual = @v;
DROP TABLE #S;

CREATE TABLE #U (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), CellLocationId BIGINT,
                 PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT, AssetNumber NVARCHAR(50),
                 DieName NVARCHAR(200), ContributionRows INT, GoodRecorded INT);
INSERT INTO #U EXEC Workorder.DieCastShift_ListUnreconciled @Days = 7, @AtMoment = @At;
SET @v = CAST((SELECT COUNT(*) FROM #U WHERE ShiftId = test.ufn_RC(N'S2')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] flags the shift with no shift-end number', @Expected = N'1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM #U WHERE ShiftId = test.ufn_RC(N'S1')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] does not flag a shift that has its number', @Expected = N'0', @Actual = @v;
DROP TABLE #U;
GO

-- A reconciliation clears both the status and the flag.
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @At DATETIME2(3) = '2020-01-08T12:00:00';
DECLARE @v NVARCHAR(400);
INSERT INTO Workorder.DieCastShiftReconciliation (ShiftId, CellLocationId, ToolId, ReasonId, DieShotCountBefore, DieShotCountAfter, AppUserId)
VALUES (test.ufn_RC(N'S2'), @Cell, test.ufn_RC(N'Tool'),
        (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry'), 10000, 10000, test.ufn_RC(N'Usr'));

CREATE TABLE #U2 (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), CellLocationId BIGINT,
                  PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT, AssetNumber NVARCHAR(50),
                  DieName NVARCHAR(200), ContributionRows INT, GoodRecorded INT);
INSERT INTO #U2 EXEC Workorder.DieCastShift_ListUnreconciled @Days = 7, @AtMoment = @At;
SET @v = CAST((SELECT COUNT(*) FROM #U2 WHERE ShiftId = test.ufn_RC(N'S2')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] a reconciliation clears the flag', @Expected = N'0', @Actual = @v;
DROP TABLE #U2;

CREATE TABLE #S2 (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3),
                  ToolId BIGINT, AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ContributionRows INT,
                  GoodRecorded INT, ShiftEndReading INT, StatusCode NVARCHAR(30),
                  ReconciledBy NVARCHAR(20), ReconciledAtEt DATETIME2(3));
INSERT INTO #S2 EXEC Workorder.DieCastShiftReconciliation_ListShifts @CellLocationId = @Cell, @Days = 7, @AtMoment = @At;
SET @v = (SELECT CONCAT(StatusCode, N'|', ISNULL(ReconciledBy, N'?')) FROM #S2 WHERE ShiftId = test.ufn_RC(N'S2'));
DECLARE @Want NVARCHAR(400) = CONCAT(N'Reconciled|', (SELECT Initials FROM Location.AppUser WHERE Id = test.ufn_RC(N'Usr')));
EXEC test.Assert_IsEqual @TestName = N'[Landing] ...and the row says who reconciled it', @Expected = @Want, @Actual = @v;
DROP TABLE #S2;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to see it fail.** `[Landing]` and `[Dashboard]` fail -- procedures do not exist.

- [ ] **Step 3: Write `_ListShifts`**

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListShifts.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The reconciliation landing list: the last @Days of shifts on
--              one press, one row per die that was mounted during the shift or
--              produced in it (spec 2026-09-21 sec 6.1). Newest first; nothing
--              is pre-selected on screen.
--
--              StatusCode, and what each one MEANS:
--                Open               the live screen owns it -- not reconcilable
--                Reconciled         a reconciliation header exists
--                ReleasedNoShiftEnd production recorded, no counter reading and
--                                   no anchor: the amber case, and the same
--                                   rule the dashboard tile counts
--                EntryRecorded      a shift-end number is on record
--                NoEntry            nothing recorded -- NEUTRAL. The MES cannot
--                                   tell a missed entry from a press that did
--                                   not run, and colouring that amber would
--                                   train people to ignore amber.
--
--              @AtMoment is a UTC "now" override for tests.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListShifts
    @CellLocationId BIGINT,
    @Days           INT          = 7,
    @AtMoment       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(3) = ISNULL(@AtMoment, SYSUTCDATETIME());
    DECLARE @NowEt  DATETIME2(3) = CAST(@NowUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
    DECLARE @FromEt DATETIME2(3) = DATEADD(DAY, -@Days, @NowEt);

    ;WITH sh AS (
        SELECT s.Id, s.ActualStart, s.ActualEnd, ss.Name,
               CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc,
               CASE WHEN s.ActualEnd IS NULL THEN @NowUtc
                    ELSE CAST(s.ActualEnd AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END AS EndUtc
        FROM Oee.Shift s
        INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.ActualStart >= @FromEt AND s.ActualStart <= @NowEt
    ),
    dies AS (
        SELECT sh.Id AS ShiftId, ta.ToolId
        FROM sh
        INNER JOIN Tools.ToolAssignment ta
            ON ta.CellLocationId = @CellLocationId
           AND ta.AssignedAt < sh.EndUtc
           AND ISNULL(ta.ReleasedAt, '9999-12-31') > sh.StartUtc
        UNION
        SELECT c.ShiftId, l.ToolId
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.CellLocationId = @CellLocationId AND c.ShiftId IN (SELECT Id FROM sh) AND l.ToolId IS NOT NULL
    )
    SELECT sh.Id AS ShiftId,
           CONVERT(NVARCHAR(5), sh.ActualStart, 110) + N' ' + sh.Name AS ShiftLabel,
           sh.ActualStart AS StartEt, sh.ActualEnd AS EndEt,
           t.Id AS ToolId, t.Code AS AssetNumber, t.Name AS DieName,
           ISNULL(a.Rows, 0) AS ContributionRows, ISNULL(a.Good, 0) AS GoodRecorded,
           Workorder.ufn_DieShotWatermark(t.Id, sh.Id, @CellLocationId) AS ShiftEndReading,
           CASE WHEN sh.ActualEnd IS NULL                                THEN N'Open'
                WHEN lr.CreatedAt IS NOT NULL                            THEN N'Reconciled'
                WHEN ISNULL(a.Rows, 0) = 0                               THEN N'NoEntry'
                WHEN ISNULL(a.Readings, 0) = 0 AND ISNULL(an.Anchors, 0) = 0 THEN N'ReleasedNoShiftEnd'
                ELSE N'EntryRecorded' END AS StatusCode,
           lr.Initials AS ReconciledBy,
           CAST(lr.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReconciledAtEt
    FROM dies d
    INNER JOIN sh ON sh.Id = d.ShiftId
    INNER JOIN Tools.Tool t ON t.Id = d.ToolId
    OUTER APPLY (SELECT COUNT(*) AS Rows, SUM(c.PieceDelta) AS Good, COUNT(c.ShotCounterReading) AS Readings
                 FROM Workorder.DieCastContribution c
                 INNER JOIN Lots.Lot l ON l.Id = c.LotId
                 WHERE c.ShiftId = sh.Id AND c.CellLocationId = @CellLocationId AND l.ToolId = t.Id) a
    OUTER APPLY (SELECT COUNT(*) AS Anchors FROM Workorder.DieCastCounterAnchor x
                 WHERE x.ShiftId = sh.Id AND x.ToolId = t.Id AND x.CellLocationId = @CellLocationId) an
    OUTER APPLY (SELECT TOP 1 h.CreatedAt, u.Initials
                 FROM Workorder.DieCastShiftReconciliation h
                 INNER JOIN Location.AppUser u ON u.Id = h.AppUserId
                 WHERE h.ShiftId = sh.Id AND h.CellLocationId = @CellLocationId AND h.ToolId = t.Id
                 ORDER BY h.CreatedAt DESC, h.Id DESC) lr
    ORDER BY sh.ActualStart DESC, t.Code;
END;
GO
```

- [ ] **Step 4: Write `DieCastShift_ListUnreconciled`**

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShift_ListUnreconciled.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The supervisor dashboard's "shifts not reconciled" tile (spec
--              2026-09-21 sec 6.4): a CLOSED shift x press x die with
--              production on record but no shift-end number -- no counter
--              reading on any contribution, no counter anchor, and no
--              reconciliation header.
--
--              This is a positive finding, not an absence: those LOTs were
--              released with a count and the shift was never settled, which is
--              exactly what Machine 202 did every shift of the week the design
--              was written against. A shift with nothing recorded at all is
--              NOT here -- the MES cannot tell it from a press that did not run.
--
--              One row per shift x press x die; the tile counts them.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShift_ListUnreconciled
    @Days     INT          = 7,
    @AtMoment DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(3) = ISNULL(@AtMoment, SYSUTCDATETIME());
    DECLARE @NowEt  DATETIME2(3) = CAST(@NowUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
    DECLARE @FromEt DATETIME2(3) = DATEADD(DAY, -@Days, @NowEt);

    ;WITH g AS (
        SELECT c.ShiftId, c.CellLocationId, l.ToolId,
               COUNT(*) AS Rows, SUM(c.PieceDelta) AS Good, COUNT(c.ShotCounterReading) AS Readings
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        INNER JOIN Oee.Shift s ON s.Id = c.ShiftId
        WHERE s.ActualEnd IS NOT NULL AND s.ActualStart >= @FromEt AND s.ActualStart <= @NowEt
          AND c.CellLocationId IS NOT NULL AND l.ToolId IS NOT NULL
        GROUP BY c.ShiftId, c.CellLocationId, l.ToolId
    )
    SELECT g.ShiftId,
           CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS ShiftLabel,
           s.ActualStart AS StartEt,
           g.CellLocationId, loc.Code AS PressCode, loc.Name AS PressName,
           g.ToolId, t.Code AS AssetNumber, t.Name AS DieName,
           g.Rows AS ContributionRows, g.Good AS GoodRecorded
    FROM g
    INNER JOIN Oee.Shift s ON s.Id = g.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    INNER JOIN Location.Location loc ON loc.Id = g.CellLocationId
    INNER JOIN Tools.Tool t ON t.Id = g.ToolId
    WHERE g.Readings = 0
      AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastCounterAnchor a
                      WHERE a.ShiftId = g.ShiftId AND a.ToolId = g.ToolId AND a.CellLocationId = g.CellLocationId)
      AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastShiftReconciliation h
                      WHERE h.ShiftId = g.ShiftId AND h.ToolId = g.ToolId AND h.CellLocationId = g.CellLocationId)
    ORDER BY s.ActualStart DESC, loc.Code;
END;
GO
```

- [ ] **Step 5: Run the test.** Expected: every `[Landing]` and `[Dashboard]` assertion passes.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListShifts.sql sql/migrations/repeatable/R__Workorder_DieCastShift_ListUnreconciled.sql sql/tests/0097_DieCast_Reconciliation/050_Landing.sql
git commit -m "feat(sql): reconciliation landing list and the unreconciled-shift dashboard read"
```

---

### Task 13: `Workorder.DieCastShiftReconciliation_Save`

The one write. Every rejection happens before `BEGIN TRANSACTION` (Msg 3915 rule); everything inside is one transaction in the order moves -> new LOTs -> credits -> scrap -> reading -> release -> count corrections (spec sec 3.5).

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql`
- Test: `sql/tests/0097_DieCast_Reconciliation/060_Save_Refusals.sql`
- Test: `sql/tests/0097_DieCast_Reconciliation/070_Save_Writes.sql`

**Interfaces:**
- Produces: `Workorder.DieCastShiftReconciliation_Save @ShiftId BIGINT, @CellLocationId BIGINT, @ToolId BIGINT, @ReasonId BIGINT, @Note NVARCHAR(500) = NULL, @ActualJson NVARCHAR(MAX) = NULL, @MovesJson NVARCHAR(MAX) = NULL, @LotsJson NVARCHAR(MAX) = NULL, @RejectsJson NVARCHAR(MAX) = NULL, @LoadedStamp NVARCHAR(100), @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL` -> one row `Status BIT, Message NVARCHAR(500), NewId BIGINT` (the reconciliation id).
  - `@ActualJson`: `{"totalShots":1121,"goodShots":1083,"warmUpShots":38}`
  - `@MovesJson`: `[{"entityType":"Contribution","entityId":12,"toShiftId":52}]`
  - `@LotsJson`: `[{"lotId":null,"ltt":"10628574","toolCavityId":30,"quantity":66}]` -- the **actual** quantity for that LOT in this shift, not a delta.
  - `@RejectsJson`: `[{"defectCodeId":8,"itemId":null,"quantity":36,"approvedByUserId":7}]` -- `itemId` null means "All".

- [ ] **Step 1: Write the refusal tests**

Create `sql/tests/0097_DieCast_Reconciliation/060_Save_Refusals.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/060_Save_Refusals.sql
-- Everything the save refuses, and the words it refuses with (spec sec 5.2,
-- 7.4, sec 8). Every one of these is a clean Status = 0 row -- no exception,
-- no open transaction (the Msg 3915 rule).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/060_Save_Refusals.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700501', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700501', @ShiftKey = N'S4', @Pieces = 100, @Reading = 110, @AtUtc = '2020-01-07T13:00:00';
GO

CREATE TABLE #Res (Status BIT, Message NVARCHAR(500), NewId BIGINT);
GO

DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @S1 BIGINT = test.ufn_RC(N'S1');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700501');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Other  BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'Other');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Code999 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
DECLARE @m NVARCHAR(500);

-- a stale stamp
DELETE FROM #Res;
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @LoadedStamp = N'0.0.0.0.0', @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a shift that changed since it was loaded', @HaystackStr = @m, @NeedleStr = N'changed since you opened it';

-- Other without a note
DELETE FROM #Res;
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Other,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] Other needs a note', @HaystackStr = @m, @NeedleStr = N'needs a note';

-- the die was never mounted on that press
DECLARE @OtherCell BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                             INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
                             WHERE d.Code = N'DieCastMachine' AND l.Id <> @Cell ORDER BY l.Id);
IF @OtherCell IS NOT NULL
BEGIN
    DECLARE @StampOther NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @OtherCell, @Tool);
    DELETE FROM #Res;
    INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
        @ShiftId = @S4, @CellLocationId = @OtherCell, @ToolId = @Tool, @ReasonId = @Reason,
        @LoadedStamp = @StampOther, @AppUserId = @Usr;
    SET @m = (SELECT Message FROM #Res);
    EXEC test.Assert_Contains @TestName = N'[Refuse] the die was not mounted on that press', @HaystackStr = @m, @NeedleStr = N'was not mounted on';
END

-- production on record with no actual figure (the orphan check)
DELETE FROM #Res;
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = N'[]', @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a LOT on record with no actual figure', @HaystackStr = @m, @NeedleStr = N'no actual figure';
EXEC test.Assert_Contains @TestName = N'[Refuse] ...naming it', @HaystackStr = @m, @NeedleStr = N'99700501';

-- the totals do not add up
DELETE FROM #Res;
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":190}]';
SET @Actual = N'{"totalShots":111,"goodShots":100,"warmUpShots":10}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] total shots must equal good + warm-up', @HaystackStr = @m, @NeedleStr = N'has a typo';

-- the LOT list does not equal total good
DELETE FROM #Res;
SET @Actual = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":150}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] the LOT list must equal actual total good', @HaystackStr = @m, @NeedleStr = N'LOT list totals';

-- one LOT holding more than the shift made
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":200}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a LOT cannot hold more than the shift''s good shots', @HaystackStr = @m, @NeedleStr = N'More pieces than';

-- an LTT from another die
DELETE FROM #Res;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700502', @CavKey = N'CavA', @StatusCode = N'Good';
UPDATE Lots.Lot SET ToolId = NULL WHERE LotName = N'99700502';
SET @Lots = N'[{"ltt":"99700502","quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] an LTT that is not a LOT from this die', @HaystackStr = @m, @NeedleStr = N'Not a LOT from';

-- a malformed LTT
DELETE FROM #Res;
SET @Lots = N'[{"ltt":"12345","toolCavityId":' + CAST(test.ufn_RC(N'CavA') AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] not a valid LTT', @HaystackStr = @m, @NeedleStr = N'8 or 9 digits';

-- a reject amount that does not divide across the cavities it covers
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":189}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":11}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a reject amount that will not divide across the cavities', @HaystackStr = @m, @NeedleStr = N'does not divide evenly';

-- warm-up is not a reject line
DELETE FROM #Res;
SET @Rej = N'[{"defectCodeId":' + CAST(@Code999 AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] warm-up belongs in warm-up shots', @HaystackStr = @m, @NeedleStr = N'entered as warm-up shots';

-- a move to a shift more than two away
DELETE FROM #Res;
DECLARE @C BIGINT = (SELECT Id FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 100);
DECLARE @Moves NVARCHAR(MAX) = N'[{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20))
    + N',"toShiftId":' + CAST(@S1 AS NVARCHAR(20)) + N'}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @MovesJson = @Moves, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a move further than two shifts away', @HaystackStr = @m, @NeedleStr = N'within two shifts';

-- nothing to do
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":100}]';
SET @Actual = N'{"totalShots":110,"goodShots":100,"warmUpShots":5}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] totals that still do not add up', @HaystackStr = @m, @NeedleStr = N'has a typo';

-- nothing was written by ANY of the refusals
DECLARE @v NVARCHAR(50) = CAST((SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] not one refusal wrote a header row', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] and no LOT count moved', @Expected = N'100', @Actual = @v;
GO

DROP TABLE #Res;
EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Write the write tests**

Create `sql/tests/0097_DieCast_Reconciliation/070_Save_Writes.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/070_Save_Writes.sql
-- The three shapes the design was written against, on the fixture die:
--   A  an entry filed against the wrong shift, and the shift's own production
--      missing (Machine 11, 09-17);
--   B  a shift with NOTHING recorded, entered from its LTTs (Machine 202);
--   C  a reduction -- recorded is higher than actual.
-- Shift end S4 = 15:00 ET = 20:00 UTC, so backfilled rows land at 19:59:59 (A1).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/070_Save_Writes.sql';
GO
EXEC test.DieCastRecon_Setup;
-- the two LOTs the misfiled entry credited (released, then counted at trim)
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700601', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700602', @CavKey = N'CavB', @StatusCode = N'Good';
-- the two LOTs this shift's production belongs in: one correctable, one locked
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700603', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700604', @CavKey = N'CavB', @StatusCode = N'Good';
GO
-- the misfiled entry: the NIGHT shift's numbers, filed under S4, entered 08:35 ET
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700601', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700602', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:01';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:02';
-- earlier production already in the two S4 LOTs, from S2
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700603', @ShiftKey = N'S2', @Pieces = 500, @Reading = 500, @AtUtc = '2020-01-06T22:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700604', @ShiftKey = N'S2', @Pieces = 500, @Reading = 500, @AtUtc = '2020-01-06T22:00:01';
GO
-- 99700604 has been counted at trim: its count stands (spec 3.3)
DECLARE @Tmpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
                        INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
                        WHERE oty.Code <> N'DieCast' ORDER BY ot.Id);
IF @Tmpl IS NOT NULL
    INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
    SELECT l.Id, @Tmpl, '2020-01-08T14:00:00', test.ufn_RC(N'Usr') FROM Lots.Lot l WHERE l.LotName = N'99700604';
GO

-- ============ A: move the misfiled entry, then backfill the shift ============
DECLARE @S3 BIGINT = test.ufn_RC(N'S3'), @S4 BIGINT = test.ufn_RC(N'S4');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @L3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700603');
DECLARE @L4 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700604');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

DECLARE @Moves NVARCHAR(MAX) = (
    SELECT STRING_AGG(x.j, N',') FROM (
        SELECT N'{"entityType":"Contribution","entityId":' + CAST(c.Id AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'}' AS j
        FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @S4 AND l.LotName IN (N'99700601', N'99700602')
        UNION ALL
        SELECT N'{"entityType":"Reject","entityId":' + CAST(r.Id AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'}'
        FROM Workorder.RejectEvent r WHERE r.ShiftId = @S4 AND r.ToolId = @Tool) x);
SET @Moves = N'[' + @Moves + N']';

-- actual: 1121 shots, 1083 good, 38 warm-up; 6 test parts across 2 cavities;
-- total good = 1083 x 2 - 6 = 2160, so 1080 in each of the two LOTs.
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":1121,"goodShots":1083,"warmUpShots":38}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@L3 AS NVARCHAR(20)) + N',"quantity":1080},'
                            + N'{"lotId":' + CAST(@L4 AS NVARCHAR(20)) + N',"quantity":1080}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":6,"approvedByUserId":' + CAST(@Usr AS NVARCHAR(20)) + N'}]';

CREATE TABLE #A (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @MovesJson = @Moves, @LotsJson = @Lots, @RejectsJson = @Rej,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecId BIGINT = (SELECT NewId FROM #A);
SET @v = CAST((SELECT Status FROM #A) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the save succeeds', @Expected = N'1', @Actual = @v;
DROP TABLE #A;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
               WHERE c.ShiftId = @S3 AND l.LotName IN (N'99700601', N'99700602')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the misfiled credits now belong to the night shift', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ShiftId = @S3 AND ToolId = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] so did its warm-up rows', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationMove WHERE ReconciliationId = @RecId) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] every moved row is recorded', @Expected = N'4', @Actual = @v;

SET @v = (SELECT CONCAT(SUM(PieceDelta), N'|', COUNT(*)) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] the shift''s own 2,160 pieces are credited, one row per LOT', @Expected = N'2160|2', @Actual = @v;
SET @v = (SELECT CONVERT(NVARCHAR(19), MIN(EventAt), 126) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] backfilled one second inside the shift (A1)', @Expected = N'2020-01-07T19:59:59', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId AND ShotCounterReading IS NOT NULL) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] a reconciliation credit carries no reading -- the anchor does (A3)', @Expected = N'0', @Actual = @v;

SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L3) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the released, unlocked LOT is corrected 500 -> 1,580', @Expected = N'1580', @Actual = @v;
SET @v = (SELECT TOP 1 Reason FROM Lots.LotAttributeChange WHERE LotId = @L3 ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[A] ...with the reconciliation named in the reason', @HaystackStr = @v, @NeedleStr = N'Shift reconciliation #';
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L4) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the LOT counted at trim keeps its count', @Expected = N'500', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId AND LotId = @L4) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] ...but its production is still recorded in full', @Expected = N'1', @Actual = @v;

SET @v = CAST((SELECT SUM(Quantity) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND DefectCodeId = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] warm-up: 38 shots on each of two cavities', @Expected = N'76', @Actual = @v;
SET @v = CAST((SELECT SUM(Quantity) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND DefectCodeId = @Code008) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the 6 test parts, spread across the cavities', @Expected = N'6', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND ApprovedByUserId = @Usr) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] Approved by is stamped on the reject rows', @Expected = N'2', @Actual = @v;

SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S4, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the shift''s reading is now the actual total', @Expected = N'1121', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] die life advanced by the shift''s shots', @Expected = N'11121', @Actual = @v;
SET @v = (SELECT CONCAT(DieShotCountBefore, N'|', DieShotCountAfter) FROM Workorder.DieCastShiftReconciliation WHERE Id = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] the header records die life either side', @Expected = N'10000|11121', @Actual = @v;

-- re-running the same reconciliation writes nothing
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
CREATE TABLE #A2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #A2 EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @v = (SELECT Message FROM #A2);
EXEC test.Assert_Contains @TestName = N'[A] running it again finds nothing to do', @HaystackStr = @v, @NeedleStr = N'already matches actual';
DROP TABLE #A2;
GO

-- ============ B: a shift with nothing recorded, entered from its LTTs ============
DECLARE @S5 BIGINT = test.ufn_RC(N'S5'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr'), @CavA BIGINT = test.ufn_RC(N'CavA'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S5, @Cell, @Tool);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- actual 110 shots, 100 good, 10 warm-up, 2 test parts => total good 198
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
DECLARE @Lots NVARCHAR(MAX) =
      N'[{"ltt":"99700611","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":66},'
    + N'{"ltt":"99700612","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":33},'
    + N'{"ltt":"99700613","toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"quantity":99}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":2}]';

CREATE TABLE #B (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #B EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecB BIGINT = (SELECT NewId FROM #B);
SET @v = CAST((SELECT Status FROM #B) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] a shift with nothing on record saves', @Expected = N'1', @Actual = @v;
DROP TABLE #B;

SET @v = (SELECT CONCAT(COUNT(*), N'|', SUM(l.PieceCount)) FROM Lots.Lot l WHERE l.LotName IN (N'99700611', N'99700612', N'99700613'));
EXEC test.Assert_IsEqual @TestName = N'[B] three LOTs created, holding what the sheet says', @Expected = N'3|198', @Actual = @v;
SET @v = (SELECT CONCAT(sc.Code, N'|', loc.Code, N'|', CONVERT(NVARCHAR(10), l.CastDate, 23), N'|', l.ProducedAtLocationId)
          FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
          JOIN Location.Location loc ON loc.Id = l.CurrentLocationId WHERE l.LotName = N'99700611');
SET @Want = CONCAT(N'Good|WHSE|2020-01-07|', @Cell);
EXEC test.Assert_IsEqual @TestName = N'[B] released to Warehouse, cast-dated, produced at the press', @Expected = @Want, @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S5, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] the shift now has its reading', @Expected = N'110', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] die life advanced again', @Expected = N'11231', @Actual = @v;
GO

-- ============ C: a reduction ============
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @v NVARCHAR(400);

EXEC test.DieCastRecon_SeedLot @Ltt = N'99700621', @CavKey = N'CavA';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700622', @CavKey = N'CavB';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700621', @ShiftKey = N'S1', @Pieces = 590, @Reading = 600, @AtUtc = '2020-01-06T16:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700622', @ShiftKey = N'S1', @Pieces = 590, @Reading = 600, @AtUtc = '2020-01-06T16:00:01';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S1', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 10, @AtUtc = '2020-01-06T16:00:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S1', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 10, @AtUtc = '2020-01-06T16:00:02';

DECLARE @L1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700621');
DECLARE @L2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700622');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
-- actual is LOWER: 580 shots, 570 good, 10 warm-up => 1,140 total good, 570 each
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":580,"goodShots":570,"warmUpShots":10}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@L1 AS NVARCHAR(20)) + N',"quantity":570},'
                            + N'{"lotId":' + CAST(@L2 AS NVARCHAR(20)) + N',"quantity":570}]';

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #C EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S1, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecC BIGINT = (SELECT NewId FROM #C);
SET @v = CAST((SELECT Status FROM #C) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] a reduction saves', @Expected = N'1', @Actual = @v;
DROP TABLE #C;

SET @v = (SELECT CONCAT(SUM(PieceDelta), N'|', COUNT(*)) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecC);
EXEC test.Assert_IsEqual @TestName = N'[C] written as compensating rows, not by editing history', @Expected = N'-40|2', @Actual = @v;
SET @v = (SELECT CONCAT(PieceCount, N'|', InventoryAvailable) FROM Lots.Lot WHERE Id = @L1);
EXEC test.Assert_IsEqual @TestName = N'[C] the open LOT comes down to actual', @Expected = N'570|570', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution c WHERE c.ReconciliationId = @RecC AND c.PieceDelta < 0) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] the CHECK allows a negative only because it is a reconciliation', @Expected = N'2', @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S1, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] the anchor lowers the shift''s reading 600 -> 580', @Expected = N'580', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] die life comes down by the same 20', @Expected = N'11211', @Actual = @v;
SET @v = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol
          JOIN Audit.LogEventType ev ON ev.Id = ol.LogEventTypeId
          WHERE ol.EntityId = @RecC AND ev.Code = N'DieCastShiftReconciled' ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[C] the audit row names what came off', @HaystackStr = @v, @NeedleStr = N'-40 good';
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 3: Run both to see them fail.** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"` -- every `[Refuse]`, `[A]`, `[B]`, `[C]` fails; the procedure does not exist.

- [ ] **Step 4: Write the proc -- part 1, the validations**

Create `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql` with this header and validation half (the transaction half follows in Step 5, in the same file):

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_Save.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Reconciles ONE past shift x press x die against its press sheet
--              (spec docs/superpowers/specs/2026-09-21-diecast-shift-
--              reconciliation-design.md sec 5.2, amendments sec 14): adds the
--              production that is missing, re-files entries that went to the
--              wrong shift, and closes numeric gaps in EITHER direction.
--
--              THE CALLER SENDS WHAT IS ACTUAL, NEVER A DELTA. This proc reads
--              what is on record, works out every gap itself, and writes only
--              the difference -- so re-running the same reconciliation is a
--              no-op, and a partly-applied screen state cannot double-count.
--
--              Order inside the transaction is load-bearing (sec 3.5): moves
--              first, because the watermark and every "recorded" figure are
--              per shift; then new LOTs, credits, scrap, the reading, the
--              release of new LOTs, and last the count corrections.
--
--              The count rule (sec 3.3): an Open LOT is credited; a released
--              LOT that nothing downstream has counted is credited AND
--              corrected; a LOT trim has counted keeps its count and still
--              gets its production recorded. Lots.ufn_DieCastLotCountLock
--              decides which, from what is stored.
--
--              The reading is declared by an ANCHOR written here (A3), which
--              floors both watermarks and works for a decrease as well as an
--              increase. Reconciliation credit rows therefore carry no reading.
--
--              FDS-11-011 + Msg-3915: no OUTPUT params, ONE result set, all
--              rejecting validations BEFORE BEGIN TRANSACTION, CATCH the only
--              ROLLBACK site, RAISERROR not THROW. Every write goes through a
--              worker (sec 5.1) so the live screens and this proc write the
--              same rows.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_Save
    @ShiftId            BIGINT,
    @CellLocationId     BIGINT,
    @ToolId             BIGINT,
    @ReasonId           BIGINT,
    @Note               NVARCHAR(500)  = NULL,
    @ActualJson         NVARCHAR(MAX)  = NULL,
    @MovesJson          NVARCHAR(MAX)  = NULL,
    @LotsJson           NVARCHAR(MAX)  = NULL,
    @RejectsJson        NVARCHAR(MAX)  = NULL,
    @LoadedStamp        NVARCHAR(100),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.DieCastShiftReconciliation_Save';
    DECLARE @Params NVARCHAR(MAX) = (
        SELECT @ShiftId AS ShiftId, @CellLocationId AS CellLocationId, @ToolId AS ToolId,
               @ReasonId AS ReasonId, LEFT(@ActualJson, 500) AS ActualJson, LEFT(@MovesJson, 1000) AS MovesJson,
               LEFT(@LotsJson, 2000) AS LotsJson, LEFT(@RejectsJson, 1000) AS RejectsJson, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Bad NVARCHAR(400);

    BEGIN TRY
        -- ---- 1. shape ----
        IF @ShiftId IS NULL OR @CellLocationId IS NULL OR @ToolId IS NULL OR @ReasonId IS NULL
           OR @LoadedStamp IS NULL OR @AppUserId IS NULL
        BEGIN SET @Message = N'Required parameter missing.'; GOTO Fail; END
        IF (@ActualJson  IS NOT NULL AND ISJSON(@ActualJson)  <> 1)
        OR (@MovesJson   IS NOT NULL AND ISJSON(@MovesJson)   <> 1)
        OR (@LotsJson    IS NOT NULL AND ISJSON(@LotsJson)    <> 1)
        OR (@RejectsJson IS NOT NULL AND ISJSON(@RejectsJson) <> 1)
        BEGIN SET @Message = N'One of the JSON inputs is not valid JSON.'; GOTO Fail; END
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN SET @Message = N'AppUser not found.'; GOTO Fail; END

        -- ---- 2. the shift, the press, the die ----
        DECLARE @StartEt DATETIME2(3), @EndEt DATETIME2(3), @ShiftLabel NVARCHAR(120);
        SELECT @StartEt = s.ActualStart, @EndEt = s.ActualEnd,
               @ShiftLabel = CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name
        FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
        WHERE s.Id = @ShiftId;
        IF @StartEt IS NULL BEGIN SET @Message = N'Shift not found.'; GOTO Fail; END
        IF @EndEt IS NULL
        BEGIN SET @Message = N'This shift is still open. The live die cast screen records the current shift.'; GOTO Fail; END

        DECLARE @PressCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @CellLocationId);
        IF @PressCode IS NULL BEGIN SET @Message = N'Press not found.'; GOTO Fail; END
        DECLARE @Asset NVARCHAR(50), @DieName NVARCHAR(200);
        SELECT @Asset = Code, @DieName = Name FROM Tools.Tool WHERE Id = @ToolId;
        IF @Asset IS NULL BEGIN SET @Message = N'Die not found.'; GOTO Fail; END

        -- Oee.Shift is Eastern wall clock (OI-38); everything compared with it here is UTC.
        DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
        DECLARE @EndUtc   DATETIME2(3) = CAST(@EndEt   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
        -- one second INSIDE the shift, so every time-based resolver puts these rows in it (A1)
        DECLARE @EventAt  DATETIME2(3) = DATEADD(SECOND, -1, @EndUtc);

        IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment
                       WHERE ToolId = @ToolId AND CellLocationId = @CellLocationId
                         AND AssignedAt < @EndUtc AND ISNULL(ReleasedAt, '9999-12-31') > @StartUtc)
        BEGIN
            SET @Message = @DieName + N' (Asset # ' + @Asset + N') was not mounted on ' + @PressCode
                         + N' during ' + @ShiftLabel + N'.';
            GOTO Fail;
        END

        -- ---- 3. reason ----
        DECLARE @ReasonName NVARCHAR(100), @RequiresNote BIT;
        SELECT @ReasonName = Name, @RequiresNote = RequiresNote
        FROM Workorder.DieCastReconciliationReason WHERE Id = @ReasonId;
        IF @ReasonName IS NULL BEGIN SET @Message = N'Reconciliation reason not found.'; GOTO Fail; END
        IF @RequiresNote = 1 AND LEN(LTRIM(RTRIM(ISNULL(@Note, N'')))) = 0
        BEGIN SET @Message = N'This reason needs a note saying what happened.'; GOTO Fail; END

        -- ---- 4. stale guard (sec 8) ----
        IF Workorder.ufn_DieCastShiftStamp(@ShiftId, @CellLocationId, @ToolId) <> @LoadedStamp
        BEGIN SET @Message = N'This shift changed since you opened it. Reload it and check again.'; GOTO Fail; END

        -- ---- 5. parse ----
        DECLARE @Total INT, @Good INT, @Warm INT;
        IF @ActualJson IS NOT NULL
            SELECT @Total = j.totalShots, @Good = j.goodShots, @Warm = j.warmUpShots
            FROM OPENJSON(@ActualJson) WITH (totalShots INT N'$.totalShots', goodShots INT N'$.goodShots',
                                             warmUpShots INT N'$.warmUpShots') j;
        DECLARE @HasActual BIT = CASE WHEN @Total IS NOT NULL OR @Good IS NOT NULL OR @Warm IS NOT NULL THEN 1 ELSE 0 END;

        DECLARE @Moves TABLE (EntityType NVARCHAR(20), EntityId BIGINT, ToShiftId BIGINT);
        IF @MovesJson IS NOT NULL
            INSERT INTO @Moves (EntityType, EntityId, ToShiftId)
            SELECT j.entityType, j.entityId, j.toShiftId
            FROM OPENJSON(@MovesJson) WITH (entityType NVARCHAR(20) N'$.entityType', entityId BIGINT N'$.entityId',
                                            toShiftId BIGINT N'$.toShiftId') j;

        DECLARE @Lots TABLE (Seq INT IDENTITY(1,1), LotId BIGINT NULL, Ltt NVARCHAR(50) NULL,
                             ToolCavityId BIGINT NULL, Qty INT NULL);
        IF @LotsJson IS NOT NULL
            INSERT INTO @Lots (LotId, Ltt, ToolCavityId, Qty)
            SELECT j.lotId, LTRIM(RTRIM(j.ltt)), j.toolCavityId, j.quantity
            FROM OPENJSON(@LotsJson) WITH (lotId BIGINT N'$.lotId', ltt NVARCHAR(50) N'$.ltt',
                                           toolCavityId BIGINT N'$.toolCavityId', quantity INT N'$.quantity') j;

        DECLARE @Rej TABLE (DefectCodeId BIGINT, ItemId BIGINT NULL, Qty INT, ApprovedByUserId BIGINT NULL);
        IF @RejectsJson IS NOT NULL
            INSERT INTO @Rej (DefectCodeId, ItemId, Qty, ApprovedByUserId)
            SELECT j.defectCodeId, j.itemId, j.quantity, j.approvedByUserId
            FROM OPENJSON(@RejectsJson) WITH (defectCodeId BIGINT N'$.defectCodeId', itemId BIGINT N'$.itemId',
                                              quantity INT N'$.quantity', approvedByUserId BIGINT N'$.approvedByUserId') j;

        -- ---- 6. moves ----
        IF EXISTS (SELECT 1 FROM @Moves WHERE EntityType NOT IN (N'Contribution', N'Reject') OR EntityId IS NULL OR ToShiftId IS NULL)
        BEGIN SET @Message = N'A move must name a contribution or reject row and a target shift.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Moves m WHERE m.EntityType = N'Contribution' AND NOT EXISTS (
                        SELECT 1 FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
                        WHERE c.Id = m.EntityId AND c.ShiftId = @ShiftId
                          AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId))
           OR EXISTS (SELECT 1 FROM @Moves m WHERE m.EntityType = N'Reject' AND NOT EXISTS (
                        SELECT 1 FROM Workorder.RejectEvent r
                        WHERE r.Id = m.EntityId AND r.ShiftId = @ShiftId
                          AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId))
        BEGIN SET @Message = N'A row being moved is not recorded against this shift, press and die. Reload and try again.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Moves m
                   WHERE NOT EXISTS (SELECT 1 FROM Oee.ufn_ShiftNeighbours(@ShiftId, 2) n WHERE n.ShiftId = m.ToShiftId))
        BEGIN SET @Message = N'An entry can only move to a closed shift within two shifts of ' + @ShiftLabel + N'.'; GOTO Fail; END

        DECLARE @MovedC TABLE (Id BIGINT PRIMARY KEY);
        INSERT INTO @MovedC (Id) SELECT DISTINCT EntityId FROM @Moves WHERE EntityType = N'Contribution';
        DECLARE @MovedR TABLE (Id BIGINT PRIMARY KEY);
        INSERT INTO @MovedR (Id) SELECT DISTINCT EntityId FROM @Moves WHERE EntityType = N'Reject';

        -- ---- 7. the LOTs ----
        UPDATE lt SET lt.LotId = l.Id
        FROM @Lots lt INNER JOIN Lots.Lot l ON l.LotName = lt.Ltt
        WHERE lt.LotId IS NULL;

        IF EXISTS (SELECT 1 FROM @Lots WHERE Qty IS NULL OR Qty < 0)
        BEGIN SET @Message = N'Every LOT needs an actual quantity of zero or more.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(l.LotName, N', ')
        FROM @Lots lt INNER JOIN Lots.Lot l ON l.Id = lt.LotId
        WHERE ISNULL(l.ToolId, -1) <> @ToolId;
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Not a LOT from ' + @DieName + N' (Asset # ' + @Asset + N'): ' + @Bad + N'.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(ISNULL(Ltt, N'(blank)'), N', ')
        FROM @Lots WHERE LotId IS NULL AND (Ltt IS NULL OR Lots.ufn_IsValidExternalLtt(Ltt) = 0);
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Not a valid LTT (8 or 9 digits): ' + @Bad + N'.'; GOTO Fail; END

        IF EXISTS (SELECT 1 FROM @Lots GROUP BY ISNULL(CAST(LotId AS NVARCHAR(50)), Ltt) HAVING COUNT(*) > 1)
        BEGIN SET @Message = N'The same LTT is in the list twice.'; GOTO Fail; END

        UPDATE lt SET lt.ToolCavityId = l.ToolCavityId
        FROM @Lots lt INNER JOIN Lots.Lot l ON l.Id = lt.LotId;

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(lt.Ltt, N', ')
        FROM @Lots lt LEFT JOIN Tools.ToolCavity tc ON tc.Id = lt.ToolCavityId
        WHERE lt.LotId IS NULL AND (tc.Id IS NULL OR tc.ToolId <> @ToolId OR tc.DeprecatedAt IS NOT NULL);
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Choose a cavity on this die for: ' + @Bad + N'.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(lt.Ltt, N', ')
        FROM @Lots lt INNER JOIN Tools.ToolCavity tc ON tc.Id = lt.ToolCavityId
        WHERE lt.LotId IS NULL AND tc.ItemId IS NULL;
        IF @Bad IS NOT NULL
        BEGIN
            SET @Message = N'That cavity has no part configured, so no LOT can be created for: ' + @Bad
                         + N'. Map the cavity to its part on the Tools screen first.';
            GOTO Fail;
        END

        IF EXISTS (SELECT 1 FROM @Lots WHERE LotId IS NULL AND Qty = 0)
        BEGIN SET @Message = N'A new LOT needs a quantity above zero.'; GOTO Fail; END

        -- what this shift has on record AFTER the moves
        DECLARE @Rec TABLE (LotId BIGINT PRIMARY KEY, Recorded INT);
        INSERT INTO @Rec (LotId, Recorded)
        SELECT c.LotId, SUM(c.PieceDelta)
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId
          AND c.Id NOT IN (SELECT Id FROM @MovedC)
        GROUP BY c.LotId;

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(l.LotName, N', ')
        FROM @Rec r INNER JOIN Lots.Lot l ON l.Id = r.LotId
        WHERE r.Recorded <> 0 AND NOT EXISTS (SELECT 1 FROM @Lots lt WHERE lt.LotId = r.LotId);
        IF @Bad IS NOT NULL
        BEGIN
            SET @Message = N'These LOTs have production on record for this shift but no actual figure: ' + @Bad
                         + N'. Enter the actual, or move the entry they came from.';
            GOTO Fail;
        END

        -- ---- 8. the actual totals must add up (sec 7.4) ----
        DECLARE @Cavities INT = (SELECT COUNT(*) FROM Tools.ToolCavity tc
                                 INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
                                 WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND cs.Code = N'Active');
        IF @HasActual = 0 AND (EXISTS (SELECT 1 FROM @Lots) OR EXISTS (SELECT 1 FROM @Rej))
        BEGIN SET @Message = N'Enter the actual total shots, good shots and warm-up shots.'; GOTO Fail; END

        DECLARE @NoGood INT = ISNULL((SELECT SUM(Qty) FROM @Rej), 0);
        DECLARE @LotSum INT = ISNULL((SELECT SUM(Qty) FROM @Lots), 0);
        DECLARE @TotalGood INT = NULL;
        IF @HasActual = 1
        BEGIN
            IF @Total IS NULL OR @Good IS NULL OR @Warm IS NULL OR @Total < 0 OR @Good < 0 OR @Warm < 0
            BEGIN SET @Message = N'Enter the actual total shots, good shots and warm-up shots.'; GOTO Fail; END
            IF @Cavities = 0
            BEGIN SET @Message = N'This die has no active cavities, so there is nothing to reconcile against.'; GOTO Fail; END
            IF @Total <> @Good + @Warm
            BEGIN
                SET @Message = N'Total shots ' + CAST(@Total AS NVARCHAR(10)) + N' should equal good shots '
                             + CAST(@Good AS NVARCHAR(10)) + N' + warm-up ' + CAST(@Warm AS NVARCHAR(10))
                             + N' = ' + CAST(@Good + @Warm AS NVARCHAR(10)) + N'. One of them has a typo.';
                GOTO Fail;
            END
            SET @TotalGood = @Good * @Cavities - @NoGood;
            IF @LotSum <> @TotalGood
            BEGIN
                SET @Message = N'LOT list totals ' + CAST(@LotSum AS NVARCHAR(10)) + N'; actual total good is '
                             + CAST(@TotalGood AS NVARCHAR(10)) + N' (' + CAST(@Good AS NVARCHAR(10)) + N' good shots x '
                             + CAST(@Cavities AS NVARCHAR(10)) + N' - ' + CAST(@NoGood AS NVARCHAR(10))
                             + N' no-good). One of them has a typo.';
                GOTO Fail;
            END
            SET @Bad = NULL;
            SELECT @Bad = STRING_AGG(ISNULL(l.LotName, lt.Ltt), N', ')
            FROM @Lots lt LEFT JOIN Lots.Lot l ON l.Id = lt.LotId
            WHERE lt.Qty > @Good;
            IF @Bad IS NOT NULL
            BEGIN
                SET @Message = N'More pieces than the shift''s ' + CAST(@Good AS NVARCHAR(10))
                             + N' good shots made: ' + @Bad + N'. Check the figure.';
                GOTO Fail;
            END
        END
```

- [ ] **Step 5: Write the proc -- part 2, the plan and the transaction**

Continue the same file:

```sql
        -- ---- 9. rejects and warm-up, per active cavity (A7) ----
        DECLARE @WarmCodeId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
        IF EXISTS (SELECT 1 FROM @Rej WHERE DefectCodeId = @WarmCodeId)
        BEGIN SET @Message = N'Warm-up is entered as warm-up shots, not as a reject line.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @Rej r WHERE r.Qty IS NULL OR r.Qty < 0
                   OR NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc WHERE dc.Id = r.DefectCodeId AND dc.DeprecatedAt IS NULL))
        BEGIN SET @Message = N'A reject line has an unknown reason or a missing amount.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @Rej r WHERE r.ApprovedByUserId IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM Location.AppUser u WHERE u.Id = r.ApprovedByUserId))
        BEGIN SET @Message = N'Approved by: that user was not found.'; GOTO Fail; END

        DECLARE @ActiveCav TABLE (ToolCavityId BIGINT PRIMARY KEY, ItemId BIGINT NULL);
        INSERT INTO @ActiveCav (ToolCavityId, ItemId)
        SELECT tc.Id, tc.ItemId FROM Tools.ToolCavity tc
        INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
        WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND cs.Code = N'Active';

        DECLARE @RejSpan TABLE (DefectCodeId BIGINT, ItemId BIGINT NULL, Qty INT, ApprovedByUserId BIGINT NULL, Span INT);
        INSERT INTO @RejSpan (DefectCodeId, ItemId, Qty, ApprovedByUserId, Span)
        SELECT r.DefectCodeId, r.ItemId, r.Qty, r.ApprovedByUserId,
               (SELECT COUNT(*) FROM @ActiveCav ac WHERE r.ItemId IS NULL OR ac.ItemId = r.ItemId)
        FROM @Rej r;
        IF EXISTS (SELECT 1 FROM @RejSpan WHERE Span = 0)
        BEGIN SET @Message = N'A reject line names a part that no active cavity on this die makes.'; GOTO Fail; END
        IF EXISTS (SELECT 1 FROM @RejSpan WHERE Qty % Span <> 0)
        BEGIN
            SELECT TOP 1 @Message = CAST(Qty AS NVARCHAR(10)) + N' does not divide evenly across '
                                  + CAST(Span AS NVARCHAR(10)) + N' cavities. Enter it against each part instead.'
            FROM @RejSpan WHERE Qty % Span <> 0;
            GOTO Fail;
        END

        DECLARE @RejTarget TABLE (DefectCodeId BIGINT, ToolCavityId BIGINT, Qty INT, ApprovedByUserId BIGINT NULL,
                                  PRIMARY KEY (DefectCodeId, ToolCavityId));
        INSERT INTO @RejTarget (DefectCodeId, ToolCavityId, Qty, ApprovedByUserId)
        SELECT rs.DefectCodeId, ac.ToolCavityId, SUM(rs.Qty / rs.Span), MAX(rs.ApprovedByUserId)
        FROM @RejSpan rs
        INNER JOIN @ActiveCav ac ON rs.ItemId IS NULL OR ac.ItemId = rs.ItemId
        GROUP BY rs.DefectCodeId, ac.ToolCavityId;

        -- gaps: actual minus recorded, per (reason, active cavity) and per cavity for warm-up
        DECLARE @Scrap TABLE (ToolCavityId BIGINT, DefectCodeId BIGINT, Qty INT, ApprovedByUserId BIGINT NULL);
        IF @HasActual = 1
        BEGIN
            ;WITH rec AS (
                SELECT r.DefectCodeId, r.ToolCavityId, SUM(r.Quantity) AS Qty
                FROM Workorder.RejectEvent r
                WHERE r.ShiftId = @ShiftId AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId
                  AND r.DefectCodeId <> @WarmCodeId
                  AND r.Id NOT IN (SELECT Id FROM @MovedR)
                  AND r.ToolCavityId IN (SELECT ToolCavityId FROM @ActiveCav)
                GROUP BY r.DefectCodeId, r.ToolCavityId)
            INSERT INTO @Scrap (ToolCavityId, DefectCodeId, Qty, ApprovedByUserId)
            SELECT COALESCE(t.ToolCavityId, rec.ToolCavityId), COALESCE(t.DefectCodeId, rec.DefectCodeId),
                   ISNULL(t.Qty, 0) - ISNULL(rec.Qty, 0), t.ApprovedByUserId
            FROM @RejTarget t
            FULL JOIN rec ON rec.DefectCodeId = t.DefectCodeId AND rec.ToolCavityId = t.ToolCavityId
            WHERE ISNULL(t.Qty, 0) <> ISNULL(rec.Qty, 0);

            ;WITH recw AS (
                SELECT r.ToolCavityId, SUM(r.Quantity) AS Qty
                FROM Workorder.RejectEvent r
                WHERE r.ShiftId = @ShiftId AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId
                  AND r.DefectCodeId = @WarmCodeId
                  AND r.Id NOT IN (SELECT Id FROM @MovedR)
                GROUP BY r.ToolCavityId)
            INSERT INTO @Scrap (ToolCavityId, DefectCodeId, Qty, ApprovedByUserId)
            SELECT ac.ToolCavityId, @WarmCodeId, @Warm - ISNULL(recw.Qty, 0), NULL
            FROM @ActiveCav ac
            LEFT JOIN recw ON recw.ToolCavityId = ac.ToolCavityId
            WHERE @Warm <> ISNULL(recw.Qty, 0);
        END

        -- ---- 10. the LOT plan: the gap, and what it does to each count (sec 3.3) ----
        DECLARE @Plan TABLE (Seq INT IDENTITY(1,1), LotId BIGINT NULL, Ltt NVARCHAR(50), ToolCavityId BIGINT,
                             ItemId BIGINT NULL, IsNew BIT, Gap INT, IsLocked BIT, PieceCount INT, InvAvail INT,
                             ApplyToLot BIT, CorrectCount BIT);
        INSERT INTO @Plan (LotId, Ltt, ToolCavityId, ItemId, IsNew, Gap, IsLocked, PieceCount, InvAvail, ApplyToLot, CorrectCount)
        SELECT lt.LotId, COALESCE(l.LotName, lt.Ltt), lt.ToolCavityId, COALESCE(l.ItemId, tc.ItemId),
               CASE WHEN lt.LotId IS NULL THEN 1 ELSE 0 END,
               lt.Qty - ISNULL(r.Recorded, 0),
               ISNULL(lk.IsLocked, 0), ISNULL(l.PieceCount, 0), ISNULL(l.InventoryAvailable, 0),
               CASE WHEN lt.LotId IS NULL OR sc.Code = N'Open' THEN 1 ELSE 0 END,
               CASE WHEN sc.Code = N'Good' AND ISNULL(lk.IsLocked, 0) = 0 THEN 1 ELSE 0 END
        FROM @Lots lt
        LEFT JOIN Lots.Lot l ON l.Id = lt.LotId
        LEFT JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        LEFT JOIN Tools.ToolCavity tc ON tc.Id = lt.ToolCavityId
        LEFT JOIN @Rec r ON r.LotId = lt.LotId
        OUTER APPLY Lots.ufn_DieCastLotCountLock(lt.LotId) lk;

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(Ltt, N', ') FROM @Plan
        WHERE Gap < 0 AND (ApplyToLot = 1 OR CorrectCount = 1) AND (PieceCount + Gap < 0 OR InvAvail + Gap < 0);
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'Taking these LOTs down that far would go below what has already been used from them: ' + @Bad + N'.'; GOTO Fail; END

        SET @Bad = NULL;
        SELECT @Bad = STRING_AGG(Ltt, N', ') FROM @Plan WHERE CorrectCount = 1 AND Gap <> 0 AND PieceCount + Gap <= 0;
        IF @Bad IS NOT NULL
        BEGIN SET @Message = N'A released LOT cannot be corrected to zero: ' + @Bad + N'. Scrap or void it from LOT Detail.'; GOTO Fail; END

        DECLARE @StorageId BIGINT = (SELECT TOP 1 Id FROM Location.Location
                                     WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);
        IF @StorageId IS NULL AND EXISTS (SELECT 1 FROM @Plan WHERE IsNew = 1)
        BEGIN SET @Message = N'No storage/warehouse location configured for release.'; GOTO Fail; END

        DECLARE @DieWmBefore INT = Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @CellLocationId);
        IF NOT EXISTS (SELECT 1 FROM @Moves)
           AND NOT EXISTS (SELECT 1 FROM @Plan WHERE Gap <> 0 OR IsNew = 1)
           AND NOT EXISTS (SELECT 1 FROM @Scrap)
           AND (@Total IS NULL OR @Total = @DieWmBefore)
        BEGIN SET @Message = N'Nothing to save: the record already matches actual.'; GOTO Fail; END

        DECLARE @ShotBefore INT = (SELECT ShotCount FROM Tools.Tool WHERE Id = @ToolId);
        DECLARE @AnchorReasonId BIGINT = (SELECT Id FROM Workorder.DieCastCounterAnchorReason WHERE Code = N'ShiftReconciliation');

        -- ===================== mutation =====================
        BEGIN TRANSACTION;

        INSERT INTO Workorder.DieCastShiftReconciliation
            (ShiftId, CellLocationId, ToolId, ReasonId, Note, ActualTotalShots, ActualGoodShots, ActualWarmUpShots,
             DieShotCountBefore, DieShotCountAfter, AppUserId, TerminalLocationId)
        VALUES (@ShiftId, @CellLocationId, @ToolId, @ReasonId, NULLIF(LTRIM(RTRIM(@Note)), N''),
                @Total, @Good, @Warm, @ShotBefore, @ShotBefore, @AppUserId, @TerminalLocationId);
        SET @NewId = SCOPE_IDENTITY();

        DECLARE @Suffix NVARCHAR(100) = N' (shift reconciliation #' + CAST(@NewId AS NVARCHAR(20)) + N')';

        -- (a) moves first: every "recorded" figure below was computed without them
        IF EXISTS (SELECT 1 FROM @Moves)
        BEGIN
            DECLARE @MovesOut NVARCHAR(MAX) = (SELECT EntityType AS entityType, EntityId AS entityId,
                                                      ToShiftId AS toShiftId FROM @Moves FOR JSON PATH);
            EXEC Workorder.DieCastEntry_Restamp @ReconciliationId = @NewId, @MovesJson = @MovesOut,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (b) new LOTs, minted at the press with the shift's business date
        DECLARE @Seq INT = 0, @PLotId BIGINT, @PLtt NVARCHAR(50), @PCav BIGINT, @PItem BIGINT,
                @PGap INT, @PApply BIT, @PCount INT, @NewCount INT;
        DECLARE @CastDate DATE = CAST(@StartEt AS DATE);
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLtt = Ltt, @PCav = ToolCavityId, @PItem = ItemId
            FROM @Plan WHERE IsNew = 1 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC Lots.DieCastLot_Mint @LotName = @PLtt, @ItemId = @PItem, @ToolId = @ToolId, @ToolCavityId = @PCav,
                @CurrentLocationId = @CellLocationId, @ProducedAtLocationId = @CellLocationId, @CastDate = @CastDate,
                @AuditNote = @Suffix, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
            UPDATE @Plan SET LotId = (SELECT Id FROM Lots.Lot WHERE LotName = @PLtt) WHERE Seq = @Seq;
        END

        -- (c) credits: the gap only, stamped one second inside the shift
        SET @Seq = 0;
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLotId = LotId, @PGap = Gap, @PApply = ApplyToLot
            FROM @Plan WHERE Gap <> 0 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC Workorder.DieCastCredit_Write @LotId = @PLotId, @ShiftId = @ShiftId, @PieceDelta = @PGap,
                @CounterReading = NULL, @CellLocationId = @CellLocationId, @ApplyToLot = @PApply,
                @ReconciliationId = @NewId, @EventAt = @EventAt, @AuditLocationId = @CellLocationId,
                @AuditSuffix = @Suffix, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (d) scrap and warm-up gaps, per cavity
        IF EXISTS (SELECT 1 FROM @Scrap)
        BEGIN
            DECLARE @ScrapOut NVARCHAR(MAX) = (
                SELECT c.ToolCavityId AS toolCavityId,
                       JSON_QUERY((SELECT s.DefectCodeId AS defectCodeId, s.Qty AS quantity,
                                          s.ApprovedByUserId AS approvedByUserId
                                   FROM @Scrap s WHERE s.ToolCavityId = c.ToolCavityId FOR JSON PATH)) AS scrapLines
                FROM (SELECT DISTINCT ToolCavityId FROM @Scrap) c
                FOR JSON PATH);
            DECLARE @RecRemark NVARCHAR(200) = N'Die-cast shift reconciliation';
            EXEC Workorder.DieCastScrap_Write @ToolId = @ToolId, @ShiftId = @ShiftId, @CellLocationId = @CellLocationId,
                @LinesJson = @ScrapOut, @Remarks = @RecRemark, @NoLotRemarks = @RecRemark,
                @ReconciliationId = @NewId, @RecordedAt = @EventAt,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (e) the reading, declared as an anchor, and die life with it (A3)
        DECLARE @DieWm INT = Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @CellLocationId);
        IF @Total IS NOT NULL AND @Total <> @DieWm
        BEGIN
            DECLARE @AnchorNote NVARCHAR(500) = N'Shift reconciliation #' + CAST(@NewId AS NVARCHAR(20))
                                              + N': ' + @ReasonName;
            INSERT INTO Workorder.DieCastCounterAnchor
                (ToolId, ShiftId, CellLocationId, DeclaredReading, ReasonId, Note, AppUserId, TerminalLocationId, EventAt, ReconciliationId)
            VALUES (@ToolId, @ShiftId, @CellLocationId, @Total, @AnchorReasonId, @AnchorNote,
                    @AppUserId, @TerminalLocationId, SYSUTCDATETIME(), @NewId);

            DECLARE @ShotDelta INT = @Total - @DieWm;
            UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
            SET ShotCount = ShotCount + @ShotDelta, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ToolId;
            IF (SELECT ShotCount FROM Tools.Tool WHERE Id = @ToolId) < 0
                RAISERROR(N'That would take this die''s lifetime shot count below zero. Check the actual total shots.', 16, 1);
        END

        -- (f) new LOTs leave the press, exactly as a live release does (D4)
        SET @Seq = 0;
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLotId = LotId FROM @Plan WHERE IsNew = 1 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            EXEC Lots.DieCastLot_ReleaseMove @LotId = @PLotId, @StorageLocationId = @StorageId,
                @AuditNote = @Suffix, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (g) released LOTs nothing downstream has counted: correct the count
        DECLARE @CountReason NVARCHAR(500) = N'Shift reconciliation #' + CAST(@NewId AS NVARCHAR(20)) + N': ' + @ReasonName;
        SET @Seq = 0;
        WHILE 1 = 1
        BEGIN
            SELECT TOP 1 @Seq = Seq, @PLotId = LotId, @PGap = Gap, @PCount = PieceCount
            FROM @Plan WHERE CorrectCount = 1 AND Gap <> 0 AND Seq > @Seq ORDER BY Seq;
            IF @@ROWCOUNT = 0 BREAK;
            SET @NewCount = @PCount + @PGap;
            EXEC Lots.Lot_ApplyPieceCountCorrection @LotId = @PLotId, @NewPieceCount = @NewCount,
                @Reason = @CountReason, @ExpectedPieceCount = @PCount,
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
        END

        -- (h) close the header and audit the reconciliation
        DECLARE @ShotAfter INT = (SELECT ShotCount FROM Tools.Tool WHERE Id = @ToolId);
        UPDATE Workorder.DieCastShiftReconciliation SET DieShotCountAfter = @ShotAfter WHERE Id = @NewId;

        DECLARE @Added INT = ISNULL((SELECT SUM(Gap) FROM @Plan WHERE Gap > 0), 0);
        DECLARE @Removed INT = ISNULL((SELECT -SUM(Gap) FROM @Plan WHERE Gap < 0), 0);
        DECLARE @NewLots INT = (SELECT COUNT(*) FROM @Plan WHERE IsNew = 1);
        DECLARE @MovedRows INT = (SELECT COUNT(*) FROM @Moves);
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @PressCode + N' ' + Audit.ufn_MidDot() + N' Die Cast ' + Audit.ufn_MidDot() + N' ' + @ShiftLabel
            + N' reconciled: +' + CAST(@Added AS NVARCHAR(10)) + N' good'
            + CASE WHEN @Removed > 0  THEN N', -' + CAST(@Removed AS NVARCHAR(10)) + N' good' ELSE N'' END
            + CASE WHEN @NewLots > 0  THEN N', ' + CAST(@NewLots AS NVARCHAR(10)) + N' new LOTs' ELSE N'' END
            + CASE WHEN @MovedRows > 0 THEN N', ' + CAST(@MovedRows AS NVARCHAR(10)) + N' rows moved' ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT h.Id,
                   JSON_QUERY((SELECT s.Id, @ShiftLabel AS Code, @ShiftLabel AS Name FROM Oee.Shift s
                               WHERE s.Id = h.ShiftId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ShiftId,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc
                               WHERE loc.Id = h.CellLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS CellLocationId,
                   JSON_QUERY((SELECT t.Id, t.Code, t.Name FROM Tools.Tool t
                               WHERE t.Id = h.ToolId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ToolId,
                   JSON_QUERY((SELECT rr.Id, rr.Code, rr.Name FROM Workorder.DieCastReconciliationReason rr
                               WHERE rr.Id = h.ReasonId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ReasonId,
                   h.Note, h.ActualTotalShots, h.ActualGoodShots, h.ActualWarmUpShots,
                   h.DieShotCountBefore, h.DieShotCountAfter,
                   @Added AS PiecesAdded, @Removed AS PiecesRemoved, @NewLots AS NewLots, @MovedRows AS RowsMoved
            FROM Workorder.DieCastShiftReconciliation h WHERE h.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
            @LocationId = @CellLocationId, @LogEntityTypeCode = N'DieCastShiftReconciliation', @EntityId = @NewId,
            @LogEventTypeCode = N'DieCastShiftReconciled', @LogSeverityCode = N'Warning',
            @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = @ShiftLabel + N' reconciled.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0; SET @NewId = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'DieCastShiftReconciliation',
                @EntityId = NULL, @LogEventTypeCode = N'DieCastShiftReconciled', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
        RETURN;
    END CATCH
Fail:
    IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'DieCastShiftReconciliation',
            @EntityId = NULL, @LogEventTypeCode = N'DieCastShiftReconciled', @FailureReason = @Message,
            @ProcedureName = @ProcName, @AttemptedParameters = @Params;
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
END;
GO
```

- [ ] **Step 6: Run both test files**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
Expected: every `[Refuse]`, `[A]`, `[B]` and `[C]` assertion passes, 0 failed.

If `[A]`'s die-life assertions fail by the amount of an earlier scenario, check that the file runs A, then B, then C in order -- they share one die and each advances `ShotCount`.

- [ ] **Step 7: Run every die cast and LOT suite**

Run each of: `-Filter "0022_PlantFloor_DieCast"`, `-Filter "0045_DieCast_Lifecycle"`, `-Filter "0061_Lot_ScrapAndRectify"`, `-Filter "0062_Oee_ShiftAttribution"`, `-Filter "0024_PlantFloor_Movement_Trim"`.
Expected: all match the Task 3 baseline.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql sql/tests/0097_DieCast_Reconciliation/060_Save_Refusals.sql sql/tests/0097_DieCast_Reconciliation/070_Save_Writes.sql
git commit -m "feat(sql): reconcile a past die cast shift -- one save, one transaction"
```

---

### Task 14: The data model document and the database's own descriptions

`MPP_MES_DATA_MODEL.md` is the source of truth for what every table and column means, and `sql/scripts/gen_extended_properties.js` lifts that prose into `sys.extended_properties`. A new table that never reaches the document is undocumented in SSMS, in Ignition and in the ERD.

**Files:**
- Modify: `MPP_MES_DATA_MODEL.md`
- Regenerate: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`

- [ ] **Step 1: Add the three new tables to the data model**

In the Workorder section, directly after the `### DieCastCounterAnchor` block, add:

```markdown
### DieCastReconciliationReason

**Added migration `0097` (2026-09-22) — die cast shift reconciliation** (spec `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md`). Why a team lead is reconciling a past shift. Shaped like `DieCastVarianceReason`: a code, a name, and a `RequiresNote` flag the screen enforces at the field.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK, IDENTITY | Surrogate key. |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | `MissedEntry`, `WrongShift`, `WrongNumbers`, `Other`. |
| Name | NVARCHAR(100) | NOT NULL | What the team lead reads in the dropdown. |
| RequiresNote | BIT | NOT NULL, default 0 | 1 for `Other`: the reason alone does not say what happened. |
| SortOrder | INT | NOT NULL, default 0 | Dropdown order. |

### DieCastShiftReconciliation

**Added migration `0097` (2026-09-22).** One row per save of the shift reconciliation screen: the team lead settling one past `(Shift, Press, Die)` against its press sheet. It is three things at once — the **late-entry marker** every row it wrote points back to, the **audit anchor** for "what did this reconciliation change", and what **clears the dashboard's not-reconciled signal** for that shift.

The actual figures are stored as typed, alongside the die's lifetime shot count either side, so the decision is legible years later without recomputing anything.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK, IDENTITY | Surrogate key. Quoted in every row it wrote (`ReconciliationId`) and in the reasons on its `LotAttributeChange` rows. |
| ShiftId | BIGINT | NOT NULL, FK → Oee.Shift | The shift being reconciled. Always closed — the live screen owns the open one. |
| CellLocationId | BIGINT | NOT NULL, FK → Location.Location | The press. |
| ToolId | BIGINT | NOT NULL, FK → Tools.Tool | The die, by asset number. |
| ReasonId | BIGINT | NOT NULL, FK → Workorder.DieCastReconciliationReason | Why. |
| Note | NVARCHAR(500) | NULL | Required when the reason says so. |
| ActualTotalShots | INT | NULL | The press sheet's total shots, as typed. |
| ActualGoodShots | INT | NULL | Good shots, as typed. |
| ActualWarmUpShots | INT | NULL | Warm-up shots, as typed. |
| DieShotCountBefore | INT | NOT NULL | `Tools.Tool.ShotCount` before the save. |
| DieShotCountAfter | INT | NOT NULL | And after — the shift's shots, added or removed. |
| AppUserId | BIGINT | NOT NULL, FK → Location.AppUser | The team lead, from the AD sign-in that opened the screen. |
| TerminalLocationId | BIGINT | NULL, FK → Location.Location | Where it was done. |
| CreatedAt | DATETIME2(3) | NOT NULL, default SYSUTCDATETIME() | The real time of entry (UTC). The rows it writes are stamped one second inside the shift instead — that is the point of keeping both. |

### DieCastReconciliationMove

**Added migration `0097` (2026-09-22).** The durable record of a row re-filed against another shift. The `ShiftId` itself is re-stamped in place — the same thing `Oee.ShiftOverride_Restamp` does — so this table is how the system remembers where the row came from, and how `ShiftOverride_Restamp` knows to leave it alone afterwards (a time-based resolver would otherwise drag a re-filed row back the next time an override is applied to that press).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK, IDENTITY | Surrogate key. |
| ReconciliationId | BIGINT | NOT NULL, FK → Workorder.DieCastShiftReconciliation | The save that moved it. |
| LogEntityTypeId | BIGINT | NOT NULL, FK → Audit.LogEntityType | Which table: `DieCastContribution` or `RejectEvent`. |
| EntityId | BIGINT | NOT NULL | The row's id in that table. |
| FromShiftId | BIGINT | NOT NULL, FK → Oee.Shift | Where it was filed. |
| ToShiftId | BIGINT | NOT NULL, FK → Oee.Shift | Where it belongs. |
```

- [ ] **Step 2: Add the new columns to the three existing tables' column tables**

In `### DieCastContribution`, add:

```markdown
| ReconciliationId | BIGINT | NULL, FK → Workorder.DieCastShiftReconciliation | Set when a shift reconciliation wrote this row (migration `0097`). It is also what makes a **negative** `PieceDelta` legal: `CK_DieCastContribution_DeltaNonNeg` is `PieceDelta >= 0 OR ReconciliationId IS NOT NULL`, so a compensating row can take production back off a shift while no live screen can. Rows carrying it are excluded from `Oee.ShiftOverride_Restamp`. |
```

In `### RejectEvent`, add:

```markdown
| ApprovedByUserId | BIGINT | NULL, FK → Location.AppUser | The press sheet's QAS column: who signed off the reject. Recorded by the shift reconciliation (migration `0097`); the live Reconcile Shift screen can adopt it later. |
| ReconciliationId | BIGINT | NULL, FK → Workorder.DieCastShiftReconciliation | Set when a shift reconciliation wrote this row, including a compensating row with a negative `Quantity` that cancels scrap recorded in error. |
```

In `### DieCastCounterAnchor`, add:

```markdown
| ReconciliationId | BIGINT | NULL, FK → Workorder.DieCastShiftReconciliation | Set when the anchor was written by a shift reconciliation declaring the shift's actual total shots (migration `0097`), rather than by an operator at the press. The reason code is `ShiftReconciliation`, which the Fix counter dialog does not offer. |
```

- [ ] **Step 3: Add a revision-history row**

At the top of `MPP_MES_DATA_MODEL.md`, add to the revision table:

```markdown
| 2.7 | 2026-09-22 | Blue Ridge Automation | **Die cast shift reconciliation** (migration `0097`, spec `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md`). A team lead settles one past `(Shift, Press, Die)` against its press sheet: production that was never entered, entries filed against the wrong shift, and numbers that disagree — in either direction. New `Workorder.DieCastShiftReconciliation` (header), `DieCastReconciliationMove` (what was re-filed) and `DieCastReconciliationReason`; `ReconciliationId` on `DieCastContribution`, `RejectEvent` and `DieCastCounterAnchor`; `RejectEvent.ApprovedByUserId` (the sheet's QAS). `CK_DieCastContribution_DeltaNonNeg` relaxed so a **reconciliation row, and only a reconciliation row**, may carry a negative delta — corrections are compensating rows, never edits to recorded history. |
```

- [ ] **Step 4: Regenerate the descriptions**

```bash
node sql/scripts/gen_extended_properties.js --stats
node sql/scripts/gen_extended_properties.js
git diff --stat sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
```

**Check the diff before staging.** Another session may have uncommitted work in that generated file (it is regenerated from the whole document). If the diff contains anything but the new die cast reconciliation entries, stop and ask rather than committing somebody else's regeneration.

- [ ] **Step 5: Commit**

```bash
git add MPP_MES_DATA_MODEL.md sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
git commit -m "docs(data-model): die cast shift reconciliation tables and columns (0097)"
```

---

### Task 15: Verification -- the whole suite, Dev, and the real press sheet

**Files:**
- Create: `sql/scratch/2026-09-22_reconcile_m11_0917_prodsim.sql`

- [ ] **Step 1: Full suite on a throwaway database**

Run: `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter ""`
Expected: the Task 3 baseline's pass count **plus** the new `0097_DieCast_Reconciliation` assertions, and no new failures. If anything outside `0097_*` and `0062_*` fails, it is a regression from the worker extraction -- bisect by task.

- [ ] **Step 2: Apply to `MPP_MES_Dev`**

Dev is Jacques's working database: apply the change, never reset it.

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/versioned/0097_diecast_shift_reconciliation.sql
```
Then each new or changed repeatable, functions first:
```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Lots_ufn_DieCastLotCountLock.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Workorder_ufn_DieCastShiftStamp.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Oee_ufn_ShiftNeighbours.sql
```
then the six workers, then the changed live procs (`DieCastShiftOutput_Record`, `DieCastLot_Open`, `DieCastLot_Release`, `Lot_RectifyPieceCount`, `ShiftOverride_Restamp`, `DieCastCounterAnchorReason_List`), then the reads and `..._Save`, then `R__Descriptions_ExtendedProperties.sql`.

Expected: each prints its `GO` batches without error. Then confirm the live path still works on Dev by opening and releasing a die cast basket from the die cast screen (the screens are unchanged; this is checking the refactor did not break the press).

- [ ] **Step 3: Rehearse the real sheet on a ProdSim database**

This is the acceptance test the design was written for: reconcile Machine 11's 09-17 press sheet on a copy of prod and see the record come out matching the paper.

Build the ProdSim database from the latest prod backup per `prod-release-context-pack/05_local_rehearsal.md`, apply `0097` and every repeatable above, then write `sql/scratch/2026-09-22_reconcile_m11_0917_prodsim.sql`, which for die `DMO125` on `DC1-M11`:

1. **09-17 1st shift** -- moves the 09:35 entry's rows to 09-16 3rd, and enters actual 1,121 / 1,083 / 38 with 1,080 against each of the twelve LTTs on the sheet and 36 test parts (code `008`, All, approved by `CW`).
2. **09-17 2nd shift** -- actual 732 / 711 / 25, 711 against each LTT (the quantities already match; this one only corrects the reading and the warm-up).

Each call reads `Workorder.ufn_DieCastShiftStamp` first and passes it as `@LoadedStamp`, and the script runs **inside a transaction that it rolls back** unless run with `@Commit = 1` -- the one-off remediation shape from `prod-release-context-pack/09_one_off_remediation.md`. A preview that skips the writes proves nothing, so the rollback still executes them.

Then re-run the evidence script against ProdSim:

```bash
.\sql\scratch\Run-DieCastOnRecord.ps1 -ServerInstance localhost -DatabaseName MPP_MES_ProdSim -Username "" -Hours 168
```

Expected, on Machine 11 / `DMO125`:
- 09-16 3rd shift: **11,436** good, reading **991**;
- 09-17 1st shift: **12,960** good, reading **1,121**;
- 09-17 2nd shift: **8,532** good, reading **732**, warm-up 300 pieces;
- LOTs 10628131-134 at **2,868** each;
- the eight LOTs already past trim unchanged at 4,926;
- `DMO125` die life up by **1,121 + 6**;
- every Machine 202 shift still flagged by `DieCastShift_ListUnreconciled` (nothing here touches it).

Record the actual numbers in the commit message. A mismatch here is the design being wrong, not the test.

- [ ] **Step 4: Commit**

```bash
git add sql/scratch/2026-09-22_reconcile_m11_0917_prodsim.sql
git commit -m "test(sql): reconcile the 09-17 Machine 11 press sheet on ProdSim -- <result>"
```

---

### Task 16: Status, and the handoff to Plan 2

**Files:**
- Modify: `PROJECT_STATUS.md`

- [ ] **Step 1: Add the entry**

Add a dated block under the current "Last updated" section (append; do not rewrite other sessions' entries):

```markdown
> ### Die cast shift reconciliation -- SQL layer (2026-09-22)
>
> Migration `0097` + six write workers + the reconciliation reads and `Workorder.DieCastShiftReconciliation_Save`. Spec `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md`; plan `docs/superpowers/plans/2026-09-22-diecast-shift-reconciliation-sql.md`. **Not deployed.**
>
> A team lead reconciles one past shift x press x die against its press sheet: adds production that was never entered (including a shift with nothing recorded, entered from its LTTs), re-files entries filed against the wrong shift, and closes numeric gaps in either direction as compensating rows. The count rule follows trim: an Open LOT is credited, a released LOT nothing has counted is credited and corrected, a LOT trim has counted keeps its count and still gets its production recorded.
>
> **The live die cast procs now call shared workers** (`DieCastCredit_Write`, `DieCastScrap_Write`, `DieCastLot_Mint`, `DieCastLot_ReleaseMove`, `Lot_ApplyPieceCountCorrection`, `DieCastEntry_Restamp`). Behaviour is unchanged and the existing suites are the gate. `Oee.ShiftOverride_Restamp` now skips rows a reconciliation wrote or moved.
>
> **Next:** Plan 2 -- the Ignition screen (`/shop-floor/die-cast/reconcile`), its named queries and entity script, and the supervisor dashboard tile.
```

- [ ] **Step 2: Commit**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): die cast shift reconciliation SQL layer built, not deployed"
```

---

### Task 17: The die's cavity-and-part list, resolved as of the shift

> **Sequencing: this lands AFTER Task 15's verification**, not before it. Task 15 is the gate that
> proves the arithmetic against the 2026-09-17 Machine 11 press sheet, and it runs against a clean
> tree. Nothing in this task is touched until that verification has reported.

Writing Plan 2's scope (`docs/superpowers/plans/2026-09-28-diecast-reconciliation-screen-plan2-scope.md`
§9 question 1) found a read the screen needs and this plan did not build. The reconciliation sheet
has two controls with nothing to bind to:

- the **LTT entry bar's Cavity picker** -- a team lead typing in a basket the shift made has to name
  the cavity that cast it;
- the **reject block's Part dropdown** -- "All", or one part.

Neither can come from what exists. `..._GetHeader` returns the active-cavity **count**
(`ActiveCavities`), not the set. `..._ListLots` lists LOTs, so it is **empty in exactly the case the
entry bar exists for**: a shift where nothing was recorded at all -- the Machine 202 shape this
whole feature is aimed at. A shift with no LOTs would offer no cavities and no parts, and the team
lead could enter nothing.

**The constraint that decides the whole task.** Commit `d65ac22c` (`Workorder.DieCastShiftReconciliation_Save`
1.7, `..._GetHeader` 1.1) moved the cavity set from *as of now* to *as of the shift*, by a half-open
interval overlap on `Tools.ToolCavity.CreatedAt` / `DeprecatedAt`. **This read SHALL use that same
window, character for character:**

```sql
    cs.Code = N'Active'
AND tc.CreatedAt < @EndUtc
AND (tc.DeprecatedAt IS NULL OR tc.DeprecatedAt > @StartUtc)
```

A third source resolved as of *now* would offer a cavity the save then refuses (`Choose a cavity
that was on this die during <shift>`), or hide one the save would have accepted -- the precise
disagreement 1.7 and 1.1 were written to close, and the one `sql/tests/0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql`
already pins for the other two. Three resolvers now share one predicate; if it ever moves, all three
move in the same commit.

**What this read is NOT.** `..._ListLots`, `..._ListRejects`, `..._ListEntries`, `..._ListMoveTargets`
and `..._ListShifts` deliberately carry **no** cavity predicate, and `d65ac22c` documented why in
`R__Workorder_DieCastShiftReconciliation_ListLots.sql` 1.2: a basket cast on a since-deprecated
cavity is still a basket, and it must appear on the list the team lead reconciles from. **Do not add
a cavity predicate to any of them.** This proc answers *what may be CHOSEN*; those answer *what is
SHOWN*, and they are not the same question.

> **A live risk this read inherits, and must not try to design around.**
> `Tools.ToolCavity.CreatedAt` is a **configuration** timestamp -- when the cavity row was entered
> into the MES -- not a manufacturing one. A die whose cavities were configured *after* a shift had
> already physically run resolves to **zero** cavities for that shift, and the save refuses it with
> `This die had no active cavities during <shift>`. That is the Save's behaviour as of `d65ac22c`
> and this read inherits it exactly, which is the point: both refuse the same shift rather than
> disagreeing about it.
>
> **Task 15 is currently measuring whether prod's real `CreatedAt` values pre-date 2026-09-17.** If
> they do not, the Save's predicate is wrong for the target shifts -- and **the Save's predicate and
> this read change together, in one commit, with `..._GetHeader` alongside them.** Do not "fix" this
> read on its own. Its whole value is that it agrees with the save.

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListCavities.sql`
- Modify (test): `sql/tests/0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql` -- append section 6

**Interfaces:**
- Produces: `Workorder.DieCastShiftReconciliation_ListCavities @ShiftId BIGINT, @ToolId BIGINT` ->
  one row per cavity that was on the die during the shift:
  `ToolCavityId, CavityCode, ItemId, PartNumber, PartDescription, CanMintLot, DeprecatedAtEt, IsOffDieNow`,
  ordered **part, then cavity letter**.
- **Two parameters, not three. `@CellLocationId` is deliberately absent:** the cavity set depends on
  the die and the shift window and on nothing else -- the Save's `@ActiveCav` does not reference the
  press either. Adding a press parameter that the query ignores would tell the next reader it
  matters.
- One result set, no `OUTPUT` parameters (FDS-11-011). **Empty means the die had no active cavities
  in that window** -- the same condition the save refuses with `This die had no active cavities
  during <shift>`, so the screen shows that sentence rather than an empty picker with no
  explanation. An unknown shift is also empty (not-found).
- The Part dropdown is a `DISTINCT` over `ItemId` / `PartNumber` **on the screen**. That is
  rendering, not a domain decision, and it is the reason there is one proc rather than two.

- [ ] **Step 1: Write the failing test**

Append to `sql/tests/0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql`, **before** the closing
`EXEC test.DieCastRecon_Cleanup;`. That file already builds the only fixture this needs: cavities
`{a, b, c, e}` were on the die during the January 2020 shifts and `{a, b, d}` are on it today, so
every assertion below flips if the window is reverted.

```sql
-- ============ 6: the cavity-and-part list the screen picks from ============
-- Workorder.DieCastShiftReconciliation_ListCavities exists because the screen's
-- Cavity picker and Part dropdown had no backing read: _GetHeader returns a
-- COUNT and _ListLots is empty for a shift where nothing was recorded, which is
-- the case the LTT entry bar exists for. It resolves the same set the save does
-- -- so a cavity it offers is a cavity the save accepts, and one it hides is one
-- the save would have refused.
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @v NVARCHAR(400), @m NVARCHAR(500);

CREATE TABLE #CV (ToolCavityId BIGINT, CavityCode NVARCHAR(4), ItemId BIGINT, PartNumber NVARCHAR(50),
                  PartDescription NVARCHAR(200), CanMintLot BIT, DeprecatedAtEt DATETIME2(3), IsOffDieNow BIT);
INSERT INTO #CV EXEC Workorder.DieCastShiftReconciliation_ListCavities @ShiftId = @S4, @ToolId = @Tool;

SET @v = (SELECT STRING_AGG(CavityCode, N',') WITHIN GROUP (ORDER BY CavityCode) FROM #CV);
EXEC test.Assert_IsEqual @TestName = N'[Cav] the list is the set that was on the die THEN',
    @Expected = N'a,b,c,e', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM #CV WHERE CavityCode = N'd') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...and a cavity fitted AFTER the shift is not in it',
    @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM #CV WHERE IsOffDieNow = 1) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...and says which of them have since come off the die',
    @Expected = N'2', @Actual = @v;

-- the list and the header must not be able to disagree about how many
CREATE TABLE #H6 (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3), IsOpen BIT,
                  CellLocationId BIGINT, PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT,
                  AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ActiveCavities INT, DieShotCount INT,
                  RecordedTotalShots INT, RecordedWarmUpShots INT, RecordedNoGood INT, RecordedGood INT,
                  HasShiftEndNumber BIT, Stamp NVARCHAR(100), LastReconciledAtEt DATETIME2(3), LastReconciledBy NVARCHAR(20));
INSERT INTO #H6 EXEC Workorder.DieCastShiftReconciliation_GetHeader
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #CV) AS NVARCHAR(400));
DECLARE @WantCav NVARCHAR(400) = CAST((SELECT ActiveCavities FROM #H6) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] the list and the header count the same set',
    @Expected = @WantCav, @Actual = @v;
DROP TABLE #H6;

-- every cavity carries the part it was making -- this is the Part dropdown's source
SET @v = CAST((SELECT COUNT(*) FROM #CV WHERE PartNumber IS NULL) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] every cavity on the list names its part',
    @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT COUNT(DISTINCT ItemId) FROM #CV) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] the Part dropdown has both parts this die makes',
    @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM #CV WHERE CanMintLot = 0) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...so every one of them can take a new LOT',
    @Expected = N'0', @Actual = @v;

-- ordered part, then letter: a letter is unique per (Tool, Item, CavityCode),
-- never per tool, so the letter alone is ambiguous on a family die.
SET @v = (SELECT STRING_AGG(CONCAT(PartNumber, N'/', CavityCode), N' ') FROM
          (SELECT TOP 100 PartNumber, CavityCode FROM #CV ORDER BY PartNumber, CavityCode) o);
DECLARE @WantOrder NVARCHAR(400) = (SELECT STRING_AGG(CONCAT(PartNumber, N'/', CavityCode), N' ') FROM #CV);
EXEC test.Assert_IsEqual @TestName = N'[Cav] ordered by part, then cavity letter',
    @Expected = @WantOrder, @Actual = @v;

-- THE POINT OF THE READ: what it offers, the save accepts. Cavity c is on the
-- list and is deprecated today; feeding it back in must get PAST the cavity gate
-- and be refused by the NEXT gate instead.
DECLARE @OfferedC BIGINT = (SELECT ToolCavityId FROM #CV WHERE CavityCode = N'c');
DECLARE @S2 BIGINT = test.ufn_RC(N'S2');
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S2, @Cell, @Tool);
DECLARE @LotsOffered NVARCHAR(MAX) = N'[{"ltt":"99700903","toolCavityId":' + CAST(@OfferedC AS NVARCHAR(20)) + N',"quantity":10}]';
CREATE TABLE #O (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #O EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @LotsJson = @LotsOffered, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #O);
DECLARE @CavRefused NVARCHAR(50) = CASE WHEN @m LIKE N'%Choose a cavity that was on this die%' THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Cav] a cavity the list OFFERS is a cavity the save ACCEPTS',
    @Expected = N'no', @Actual = @CavRefused;
DROP TABLE #O;
DROP TABLE #CV;

-- an unknown shift is empty, not an invented row
CREATE TABLE #CX (ToolCavityId BIGINT, CavityCode NVARCHAR(4), ItemId BIGINT, PartNumber NVARCHAR(50),
                  PartDescription NVARCHAR(200), CanMintLot BIT, DeprecatedAtEt DATETIME2(3), IsOffDieNow BIT);
INSERT INTO #CX EXEC Workorder.DieCastShiftReconciliation_ListCavities @ShiftId = -1, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #CX) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] an unknown shift returns no rows', @Expected = N'0', @Actual = @v;
DROP TABLE #CX;
GO
```

- [ ] **Step 2: Run to see it fail.**
`.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
-- the new `[Cav]` assertions in section 6 fail because the proc does not exist. Everything in
sections 1-5 still passes.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListCavities.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListCavities.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-29
-- Version:     1.0
-- Description: The cavities that were on this die DURING the shift, one row
--              each, with the part each was making. Two controls on the
--              reconciliation screen have nothing else to read from:
--
--                * the LTT entry bar's Cavity picker -- a team lead typing in a
--                  basket the shift made has to name the cavity that cast it;
--                * the reject block's Part dropdown -- "All", or one part.
--
--              Neither can come from Workorder.DieCastShiftReconciliation_
--              ListLots, which lists LOTs and is EMPTY in precisely the case the
--              entry bar exists for: a shift where nothing was recorded. And
--              neither can come from _GetHeader, which returns the cavity COUNT,
--              not the set.
--
--              THE WINDOW IS THE SAVE'S WINDOW, CHARACTER FOR CHARACTER:
--                  cs.Code = N'Active'
--                  AND tc.CreatedAt < @EndUtc
--                  AND (tc.DeprecatedAt IS NULL OR tc.DeprecatedAt > @StartUtc)
--              the predicate Workorder.DieCastShiftReconciliation_Save 1.7 sec 8
--              builds @ActiveCav from, and Workorder.DieCastShiftReconciliation_
--              GetHeader 1.1 counts. A third source resolved as of NOW would
--              offer a cavity the save then refuses ("Choose a cavity that was on
--              this die during ...") or hide one it would have accepted -- the
--              exact disagreement 1.7 and 1.1 were written to close. Three
--              resolvers now share one predicate. If it moves, all three move in
--              the same commit.
--
--              NOT A CAVITY FILTER FOR ANYTHING ELSE. _ListLots, _ListRejects,
--              _ListEntries, _ListMoveTargets and _ListShifts deliberately carry
--              NO cavity predicate and must keep none (see _ListLots 1.2): a
--              basket cast on a since-deprecated cavity is still a basket and
--              still belongs on the list the team lead reconciles from. This proc
--              answers "what may be CHOSEN"; those answer "what is SHOWN".
--
--              ORDER: part, then cavity letter. A cavity letter is unique per
--              (Tool, Item, CavityCode), not per tool -- a family die repeats its
--              letters once per part -- so the letter alone is ambiguous and the
--              part has to lead. Same order _ListLots uses.
--
--              TWO PARAMETERS, NOT THREE. The press is deliberately not one: the
--              cavity set depends on the die and the shift window and on nothing
--              else, exactly as @ActiveCav does. A parameter the query ignores
--              would tell the next reader it matters.
--
--              ONE result set, no OUTPUT params (FDS-11-011). EMPTY means this die
--              had no active cavities in the window -- the same condition the save
--              refuses with "This die had no active cavities during <shift>", so
--              the screen shows that sentence rather than an empty picker with no
--              explanation. An unknown shift is empty too.
--
--              An OPEN shift has no ActualEnd and takes "now" as its end, the
--              substitution _GetHeader, _ListLots and _ListShifts all make.
--
--              KNOWN LIMITATIONS, INHERITED ON PURPOSE. Both are documented at
--              length in R__Workorder_DieCastShiftReconciliation_Save.sql and
--              neither is solved here:
--                * cs.Code = 'Active' is evaluated as of NOW, because
--                  Tools.ToolCavityStatusCode has no history -- nothing records
--                  when a cavity became Closed or Scrapped;
--                * CreatedAt is when the cavity ROW was CONFIGURED, not when the
--                  physical cavity started running, so a die whose cavities were
--                  entered into the MES after a shift had already run resolves to
--                  zero cavities for it.
--              Do not fix either one here alone. The value of this read is that it
--              agrees with the save; a unilateral fix would end that.
--
-- Parameters (input):
--   @ShiftId BIGINT - the shift whose cavity set is wanted.
--   @ToolId  BIGINT - the die.
--
-- Result set (one row per cavity, ordered part then letter):
--   ToolCavityId, CavityCode, ItemId, PartNumber, PartDescription,
--   CanMintLot BIT, DeprecatedAtEt, IsOffDieNow BIT
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListCavities
    @ShiftId BIGINT,
    @ToolId  BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- Oee.Shift is Eastern wall clock (OI-38); Tools.ToolCavity's stamps are UTC.
    DECLARE @StartEt DATETIME2(3), @EndEt DATETIME2(3);
    SELECT @StartEt = s.ActualStart, @EndEt = s.ActualEnd FROM Oee.Shift s WHERE s.Id = @ShiftId;
    DECLARE @StartUtc DATETIME2(3) = CAST(@StartEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @EndUtc   DATETIME2(3) = CASE WHEN @EndEt IS NULL THEN SYSUTCDATETIME()
                                          ELSE CAST(@EndEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) END;

    SELECT
        tc.Id                                                            AS ToolCavityId,
        tc.CavityCode,
        tc.ItemId,
        i.PartNumber,
        i.Description                                                    AS PartDescription,
        -- Workorder.DieCastShiftReconciliation_Save refuses a NEW LOT on a cavity
        -- with no part configured ("That cavity has no part configured..."), so the
        -- picker can grey it rather than let the team lead find out at save.
        CAST(CASE WHEN tc.ItemId IS NULL THEN 0 ELSE 1 END AS BIT)       AS CanMintLot,
        CAST(tc.DeprecatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DeprecatedAtEt,
        CAST(CASE WHEN tc.DeprecatedAt IS NULL THEN 0 ELSE 1 END AS BIT) AS IsOffDieNow
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
    LEFT JOIN Parts.Item i ON i.Id = tc.ItemId
    WHERE tc.ToolId = @ToolId
      AND cs.Code = N'Active'
      AND tc.CreatedAt < @EndUtc
      AND (tc.DeprecatedAt IS NULL OR tc.DeprecatedAt > @StartUtc)
    ORDER BY i.PartNumber, tc.CavityCode;
END;
GO
```

- [ ] **Step 4: Run the test.** Same command. Expected: every `[Cav]` assertion in sections 1-6
passes, and nothing else in `0097_*` changed.

- [ ] **Step 5: Byte-scan the new file for non-ASCII**

```bash
python -c "d=open('sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListCavities.sql','rb').read(); bad=[(i,b) for i,b in enumerate(d) if b>127]; print('non-ascii:', bad[:10], len(bad))"
```
Expected: `non-ascii: [] 0`.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_ListCavities.sql sql/tests/0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql
git commit -m "feat(sql): the die's cavity and part list, resolved as of the shift"
```

---

### Task 18: The confirmation panel's preview -- the same computation, stopped one statement short

> **Sequencing: this lands AFTER Task 15's verification**, for the same reason as Task 17 -- it
> changes `Workorder.DieCastShiftReconciliation_Save`, which is the proc Task 15 verifies.

Before a team lead commits, the screen must show them what will change: entries moved, production
added, production reduced, new LOTs, LOT counts changed, counts left standing and why, die life
before -> after, and whether anything here is a **reduction** (spec §7.5's amber tick box). Plan 2's
scope raised this as an open question (§9 question 3) with two candidates: recompute the Save's
arithmetic in Python on the screen, or preview it in SQL.

**The decision is SQL, for two reasons, and both belong in the record.**

1. **This project forbids business logic in Python entity scripts and bindings.** Which LOTs get a
   count correction, which stand and why, what die life becomes -- these are domain rules, and
   domain rules live in SQL (`feedback_no_business_logic_in_python`, Plan 2 scope §2.9).
2. **Duplicating the Save's arithmetic in a second language is exactly how the two drift apart.** A
   confirmation that promises something the save does not do is worse than no confirmation: it is a
   team lead signing off on a picture that is not what happens. Plan 2 scope §10 names this as the
   screen's second-biggest risk, and the 2026-09-28 cavity-set change (`d65ac22c`) is the same
   failure already caught once.

**The design decision, and the justification.** Reason 2 does not stop at Python. Writing a second
*procedure* that recomputes the plan would move the drift risk, not remove it -- two T-SQL bodies
drift as readily as one T-SQL and one Jython, just more quietly. Three shapes were considered:

| Option | Why not |
|---|---|
| **A separate `_Preview` proc that recomputes the plan.** | The thing we are trying to prevent, in a second file. |
| **Extract the plan into inline TVFs (`ufn_DieCastReconciliationPlan`, `ufn_...ScrapPlan`) that both procs select from.** | Matches the `ufn_` convention and genuinely deduplicates the *arithmetic* -- but the arithmetic is the small half. The preview must also reproduce every **refusal**, because a confirmation panel that shows a plan the save will reject is useless; and the refusals are ~300 ordered lines of `GOTO Fail` with specific prose, which no TVF can carry. This option removes duplication from the arithmetic and creates it in the validations. It is a net loss, and it is an invasive rewrite of a 923-line proc that has just been through code review. |
| **A `@PreviewOnly` mode on the Save itself.** | **Chosen.** |

**`Workorder.DieCastShiftReconciliation_Save` gains `@PreviewOnly BIT = 0`.** Not one line of
arithmetic and not one refusal moves. A single `IF @PreviewOnly = 1 ... RETURN` is inserted at the
one point where the whole plan is known and nothing has happened yet: **after section 12, immediately
before `BEGIN TRANSACTION`**. Everything above that line is already pure computation -- sections 1-12
read, parse and validate, and the proc's own standing rule is that *every* rejecting validation runs
before `BEGIN TRANSACTION` (FDS-11-011 / Msg-3915). That rule, written for a different reason, is
what makes this possible: the Save already has a clean seam at exactly the right place.

So the preview and the save **cannot** disagree, because there is one computation, not two. The
preview *is* the save, stopped one statement short.

**And it stays true over time, not just over code.** A preview is only binding if the picture it
showed is still the picture at save time. The stale-guard (`Workorder.ufn_DieCastShiftStamp`, §8)
already does that job: the screen loads a stamp, the preview is checked against it, and the real save
refuses a stamp that has changed. So between a preview and its save either nothing moved -- and the
plan is identical -- or the save refuses outright. There is no third outcome in which the save
quietly applies something else.

**No second procedure is created, and that is deliberate.** The separation the screen needs -- a
control that previews and physically cannot save -- belongs in the **named query**, not in a second
body of SQL: Plan 2 binds `workorder/DieCastShiftReconciliation_Preview` to this proc with
`@PreviewOnly` fixed at `1`, and `workorder/DieCastShiftReconciliation_Save` with it fixed at `0`.
Two named queries, one procedure, one computation.

**Two consequences that must be built, not assumed.**

- **A preview must not write a `Audit.FailureLog` row.** The `Fail:` label logs one on every
  refusal. A team lead previewing a half-typed sheet would flood the failure log with their own
  typing. The `Fail:` audit call is therefore gated on `@PreviewOnly = 0`. A refused *save* still
  logs, exactly as now.
- **The result set gains a fourth column, `PlanJson`, on every exit path.** One shape, always --
  `Status, Message, NewId, PlanJson` -- so a named query and an `INSERT ... EXEC` see the same
  columns whichever mode ran. On a refusal it is `NULL`; on a preview it is the plan that *would* be
  applied; on a save it is the plan that *was* applied, built from the same variable at the same
  line. This is a breaking change to seven `CREATE TABLE #x (Status BIT, Message NVARCHAR(500),
  NewId BIGINT)` declarations in the existing tests, all listed below.

`PlanJson` is **transport, not logic**: the screen renders the numbers in it and recomputes nothing
from it. In particular `hasReduction` -- the amber tick box -- is a fact computed in SQL, which is
what Plan 2 scope §9.3 asked for ("A preview proc would also make the tick box a fact rather than a
guess"). It covers a reduction in **production, die life or a count**, per spec §7.5, and nothing
else: a negative *scrap* delta is scrap being backed out, which raises good production rather than
reducing it, so it is deliberately not amber.

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql` -- v1.8
- Modify: `sql/tests/0097_DieCast_Reconciliation/060_Save_Refusals.sql` -- `#Res` gains `PlanJson`
- Modify: `sql/tests/0097_DieCast_Reconciliation/070_Save_Writes.sql` -- `#A`, `#A2`, `#B`, `#C`, `#D`, `#E` each gain `PlanJson`
- Modify: `sql/tests/0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql` -- `#R`, `#S`, `#W`, `#N`, `#O` each gain `PlanJson`
- Create: `sql/tests/0097_DieCast_Reconciliation/090_Preview.sql`

**Interfaces:**
- Changes: `Workorder.DieCastShiftReconciliation_Save` gains a **last** parameter
  `@PreviewOnly BIT = 0` (last, so no existing named-parameter call site changes) and a **fourth**
  result column `PlanJson NVARCHAR(MAX)`, present on every exit path.
- `@PreviewOnly = 1`: runs sections 1-12 unchanged -- every refusal, every figure -- then returns
  `Status = 1`, `Message = 'Nothing is saved yet. Check the changes, then save.'`, `NewId = NULL`,
  `PlanJson = <the plan>`. It opens no transaction, writes nothing, and logs no failure.
- `PlanJson` shape (keys always present; `moves` / `lots` / `scrap` are `[]` when empty, never
  absent):

```json
{
  "shiftLabel": "01-07 RC-FIXTURE-SCHED", "pressCode": "...", "dieName": "...",
  "assetNumber": "...", "activeCavities": 4, "hasReduction": true,
  "dieLife":  {"before": 10000, "delta": 1121, "after": 11121},
  "totals":   {"piecesAdded": 0, "piecesRemoved": 0, "newLots": 0,
               "countsCorrected": 0, "countsStanding": 0, "rowsMoved": 0},
  "moves":    [{"entityType": "Contribution", "entityId": 1, "toShiftId": 2, "toShiftLabel": "..."}],
  "lots":     [{"ltt": "...", "partNumber": "...", "cavityCode": "a", "isNew": false,
                "gap": 0, "isLocked": false, "countChanges": false,
                "pieceCountBefore": 0, "pieceCountAfter": 0, "lockReason": null}],
  "scrap":    [{"cavityCode": "a", "partNumber": "...", "defectCode": "008",
                "defect": "...", "delta": -9, "isWarmUp": false}]
}
```

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0097_DieCast_Reconciliation/090_Preview.sql`:

```sql
-- =============================================
-- File: 0097_DieCast_Reconciliation/090_Preview.sql
-- The confirmation panel's preview. The team lead sees what will change before
-- they commit, and the only way that promise can be kept is for the preview and
-- the save to BE the same computation: Workorder.DieCastShiftReconciliation_Save
-- with @PreviewOnly = 1 runs sections 1-12 and returns immediately before
-- BEGIN TRANSACTION.
--
-- The load-bearing assertion in this file is [Preview] the plan the preview
-- showed is the plan the save applied -- the two PlanJson values compared
-- character for character. If a future change reintroduces a second computation
-- anywhere, that one assertion fails.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/090_Preview.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700701', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700702', @CavKey = N'CavB', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700701', @ShiftKey = N'S4', @Pieces = 100, @Reading = 100, @AtUtc = '2020-01-07T13:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700702', @ShiftKey = N'S4', @Pieces = 100, @Reading = 100, @AtUtc = '2020-01-07T13:00:01';
GO

-- ============ 1: a preview writes nothing at all ============
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @v NVARCHAR(400), @m NVARCHAR(500);

DECLARE @Before NVARCHAR(400) = (
    SELECT CONCAT((SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastContribution c JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Lots.Lot WHERE ToolId = @Tool), N'|',
                  (SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool)));

-- 120 good shots x 2 cavities = 240 good, 20 warm-up, so 140 per LOT: an
-- ADDITION on both LOTs, plus a reading that raises die life.
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @Lots NVARCHAR(MAX) = N'[{"ltt":"99700701","quantity":120},{"ltt":"99700702","quantity":120}]';
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":140,"goodShots":120,"warmUpShots":20}';

CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #P EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr,
    @PreviewOnly = 1;

DECLARE @After NVARCHAR(400) = (
    SELECT CONCAT((SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastContribution c JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Lots.Lot WHERE ToolId = @Tool), N'|',
                  (SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool)));
EXEC test.Assert_IsEqual @TestName = N'[Preview] a preview writes nothing', @Expected = @Before, @Actual = @After;
SET @v = CAST((SELECT Status FROM #P) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and reports that it would save', @Expected = N'1', @Actual = @v;
SET @v = CAST(ISNULL((SELECT CAST(NewId AS NVARCHAR(20)) FROM #P), N'(null)') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...with no reconciliation id, because none was created',
    @Expected = N'(null)', @Actual = @v;
SET @m = (SELECT Message FROM #P);
EXEC test.Assert_Contains @TestName = N'[Preview] ...and says so in plain words',
    @HaystackStr = @m, @NeedleStr = N'Nothing is saved yet';

-- ============ 2: the plan the preview showed is the plan the save applied ============
-- THE assertion. One computation, so one answer.
DECLARE @PreviewPlan NVARCHAR(MAX) = (SELECT PlanJson FROM #P);
CREATE TABLE #Sv (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #Sv EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @SavePlan NVARCHAR(MAX) = (SELECT PlanJson FROM #Sv);
DECLARE @RecId BIGINT = (SELECT NewId FROM #Sv);
SET @v = CAST((SELECT Status FROM #Sv) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] the same payload saves', @Expected = N'1', @Actual = @v;
DECLARE @Same NVARCHAR(50) = CASE WHEN @PreviewPlan = @SavePlan THEN N'identical' ELSE N'DIFFERENT' END;
EXEC test.Assert_IsEqual @TestName = N'[Preview] the plan the preview showed is the plan the save applied',
    @Expected = N'identical', @Actual = @Same;

-- and the plan was not a description of nothing
SET @v = JSON_VALUE(@PreviewPlan, N'$.totals.piecesAdded');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...20 pieces added to each of two LOTs', @Expected = N'40', @Actual = @v;
SET @v = JSON_VALUE(@PreviewPlan, N'$.hasReduction');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and nothing here is a reduction', @Expected = N'false', @Actual = @v;

-- the predicted die life is the die life the save landed on
SET @v = JSON_VALUE(@PreviewPlan, N'$.dieLife.after');
DECLARE @WantShot NVARCHAR(400) = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] die life before -> after is a prediction the save kept',
    @Expected = @WantShot, @Actual = @v;
DROP TABLE #Sv;
DROP TABLE #P;
GO

-- ============ 3: a preview refuses exactly what the save refuses ============
-- Word for word, because it is the same GOTO Fail.
DECLARE @S2 BIGINT = test.ufn_RC(N'S2'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @v NVARCHAR(400);
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S2, @Cell, @Tool);
-- total <> good + warm-up: a typo the team lead must see before they commit
DECLARE @BadActual NVARCHAR(MAX) = N'{"totalShots":100,"goodShots":80,"warmUpShots":15}';

CREATE TABLE #PF (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PF EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @BadActual, @LoadedStamp = @Stamp2, @AppUserId = @Usr, @PreviewOnly = 1;
DECLARE @PreviewMsg NVARCHAR(500) = (SELECT Message FROM #PF);
DECLARE @PreviewStatus NVARCHAR(10) = CAST((SELECT Status FROM #PF) AS NVARCHAR(10));

CREATE TABLE #SF (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #SF EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @BadActual, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
DECLARE @SaveMsg NVARCHAR(500) = (SELECT Message FROM #SF);

EXEC test.Assert_IsEqual @TestName = N'[Preview] a preview refuses what the save refuses, word for word',
    @Expected = @SaveMsg, @Actual = @PreviewMsg;
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...as a refusal, not as a plan',
    @Expected = N'0', @Actual = @PreviewStatus;
SET @v = ISNULL((SELECT PlanJson FROM #PF), N'(null)');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...with no plan attached to it', @Expected = N'(null)', @Actual = @v;
DROP TABLE #PF;
DROP TABLE #SF;
GO

-- ============ 4: a refused preview leaves no FailureLog row ============
-- A team lead previews a half-typed sheet repeatedly; their typing is not a
-- system failure and must not fill Audit.FailureLog. A refused SAVE still logs.
DECLARE @S2 BIGINT = test.ufn_RC(N'S2'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @v NVARCHAR(400);
DECLARE @Proc NVARCHAR(200) = N'Workorder.DieCastShiftReconciliation_Save';
DECLARE @LogBefore INT = (SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = @Proc);
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S2, @Cell, @Tool);

CREATE TABLE #PL (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PL EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":100,"goodShots":80,"warmUpShots":15}',
    @LoadedStamp = @Stamp2, @AppUserId = @Usr, @PreviewOnly = 1;
SET @v = CAST((SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = @Proc) - @LogBefore AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] a refused preview logs no failure', @Expected = N'0', @Actual = @v;
DELETE FROM #PL;

INSERT INTO #PL EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":100,"goodShots":80,"warmUpShots":15}',
    @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @v = CAST((SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = @Proc) - @LogBefore AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...but a refused SAVE still does', @Expected = N'1', @Actual = @v;
DROP TABLE #PL;
GO

-- ============ 5: the amber tick box is a fact, not a guess ============
-- Spec sec 7.5: amber covers a reduction in PRODUCTION, DIE LIFE or a COUNT.
-- Backing scrap OUT is none of those -- it raises good production -- so it is
-- deliberately not amber, and the screen must not decide that for itself.
DECLARE @S5 BIGINT = test.ufn_RC(N'S5'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @v NVARCHAR(400);

-- 12 pieces of 008 on record for S5 against cavity a, basketless (the 0084 shape)
DECLARE @CavA BIGINT = test.ufn_RC(N'CavA');
INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                   DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
SELECT NULL, NULL, tc.ItemId, @Tool, tc.Id, @S5, @Cell, @Code008, 12, NULL, N'fixture', @Usr, NULL, '2020-01-07T20:00:00'
FROM Tools.ToolCavity tc WHERE tc.Id = @CavA;

DECLARE @Stamp5 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S5, @Cell, @Tool);
CREATE TABLE #PS (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PS EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":0,"goodShots":0,"warmUpShots":0}',
    @LoadedStamp = @Stamp5, @AppUserId = @Usr, @PreviewOnly = 1;
DECLARE @ScrapPlan NVARCHAR(MAX) = (SELECT PlanJson FROM #PS);
SET @v = JSON_VALUE(@ScrapPlan, N'$.hasReduction');
EXEC test.Assert_IsEqual @TestName = N'[Preview] backing scrap out is not a reduction',
    @Expected = N'false', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM OPENJSON(@ScrapPlan, N'$.scrap')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and the scrap line is on the plan for the team lead to see',
    @Expected = N'1', @Actual = @v;
SET @v = (SELECT TOP 1 CAST(JSON_VALUE(value, N'$.delta') AS NVARCHAR(400)) FROM OPENJSON(@ScrapPlan, N'$.scrap'));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...as a negative delta against its cavity',
    @Expected = N'-12', @Actual = @v;
-- the empty groups are [] and not missing keys: a binding that reads $.moves
-- must get a list, on every plan, or the screen errors on the empty path.
SET @v = ISNULL(JSON_QUERY(@ScrapPlan, N'$.moves'), N'(missing)');
EXEC test.Assert_IsEqual @TestName = N'[Preview] an empty group is [], never a missing key',
    @Expected = N'[]', @Actual = @v;
DROP TABLE #PS;
GO

-- ============ 6: a reduction IS flagged ============
-- 99700701 carries 120 from section 2. Declaring 100 takes it DOWN, which is
-- production reduced and must arm the tick box.
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @v NVARCHAR(400);
DECLARE @Stamp4 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @Down NVARCHAR(MAX) = N'[{"ltt":"99700701","quantity":100},{"ltt":"99700702","quantity":120}]';

CREATE TABLE #PD (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PD EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":130,"goodShots":110,"warmUpShots":20}',
    @LotsJson = @Down, @LoadedStamp = @Stamp4, @AppUserId = @Usr, @PreviewOnly = 1;
DECLARE @DownPlan NVARCHAR(MAX) = (SELECT PlanJson FROM #PD);
SET @v = JSON_VALUE(@DownPlan, N'$.hasReduction');
EXEC test.Assert_IsEqual @TestName = N'[Preview] taking a LOT down is a reduction, and the plan says so',
    @Expected = N'true', @Actual = @v;
SET @v = JSON_VALUE(@DownPlan, N'$.totals.piecesRemoved');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...naming how many pieces come off', @Expected = N'20', @Actual = @v;
SET @v = (SELECT TOP 1 CAST(JSON_VALUE(value, N'$.pieceCountAfter') AS NVARCHAR(400))
          FROM OPENJSON(@DownPlan, N'$.lots') WHERE JSON_VALUE(value, N'$.ltt') = N'99700701');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and what each LOT''s count becomes', @Expected = N'120', @Actual = @v;
DROP TABLE #PD;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
```

> The `pieceCountAfter` figure in section 6 depends on what section 2's save left on `99700701`.
> Compute it from the fixture when you write the file rather than trusting the number quoted here --
> and if it differs, the number in this plan is what is wrong, not the proc.

- [ ] **Step 2: Widen the existing `INSERT ... EXEC` temp tables**

Every test that captures the Save must match its new four-column shape, or `sqlcmd` errors and
`Run-Tests.ps1` exits 1 with zero reported failures. Twelve declarations, in three files:

```bash
python - <<'PY'
import io, re
files = ["sql/tests/0097_DieCast_Reconciliation/060_Save_Refusals.sql",
         "sql/tests/0097_DieCast_Reconciliation/070_Save_Writes.sql",
         "sql/tests/0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql"]
old = "(Status BIT, Message NVARCHAR(500), NewId BIGINT)"
new = "(Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX))"
for f in files:
    s = io.open(f, encoding="utf-8", newline="").read()
    n = s.count(old)
    io.open(f, "w", encoding="utf-8", newline="").write(s.replace(old, new))
    print(f, n)
PY
```
Expected: `060` 1, `070` 6, `080` 5. Confirm nothing else in those files matched that literal.

- [ ] **Step 3: Run to see it fail.**
`.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter "0097_DieCast_Reconciliation"`
-- `090_Preview.sql` fails at the first `@PreviewOnly` call (`Procedure ... has no parameter named
'@PreviewOnly'`), and `060` / `070` / `080` now fail on the column-count mismatch. Both are the
expected red.

- [ ] **Step 4: Change the Save to v1.8**

Seven edits to `sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql`. Nothing
else moves -- **no validation and no arithmetic is relocated, reordered or rewritten.** That is the
whole design.

**(a) Header.** Bump to `Version: 1.8`, add the parameter and result-set lines, and add this
Description section after "THE CAVITIES ARE RESOLVED AS OF THE SHIFT":

```
--              THE PREVIEW IS THIS PROC, STOPPED ONE STATEMENT SHORT (1.8).
--              @PreviewOnly = 1 runs sections 1-12 exactly as a save does --
--              every refusal, every figure -- builds the plan as one JSON
--              object, returns it, and RETURNs before BEGIN TRANSACTION. It
--              opens no transaction, writes nothing and logs no failure.
--
--              It is a MODE and not a second procedure on purpose. The
--              confirmation panel's whole value is that what it promises is what
--              happens, and a second body of SQL would be free to drift from
--              this one just as quietly as a Python reimplementation would --
--              which is the option the project's "no business logic in Python"
--              rule already closes. An inline TVF pair was considered and
--              rejected: it would deduplicate the ARITHMETIC (sections 10-11),
--              which is the small half, while leaving the ~300 lines of ordered,
--              prose-carrying refusals to be written twice -- and a panel that
--              shows a plan the save will reject is worse than no panel.
--              Sections 1-12 are already pure computation, because every
--              rejecting validation must run before BEGIN TRANSACTION (the
--              Msg-3915 rule), so the seam was already here.
--
--              AND IT STAYS TRUE OVER TIME. A preview only binds if its picture
--              is still the picture at save. The stale guard (sec 4) is what
--              makes that so: the real save refuses a stamp that has changed, so
--              between a preview and its save either nothing moved and the plan
--              is identical, or the save refuses outright. There is no third
--              outcome in which the save quietly applies something else.
--
--              PlanJson is on EVERY exit path -- NULL on a refusal, the plan that
--              WOULD be applied on a preview, the plan that WAS applied on a save
--              -- so the result set has one shape whichever mode ran. It is
--              transport, not logic: the screen renders the numbers in it and
--              recomputes nothing. hasReduction is the spec sec 7.5 amber tick
--              box, decided HERE so it is a fact rather than a guess, and it
--              covers a reduction in PRODUCTION, DIE LIFE or a COUNT and nothing
--              else -- a negative scrap delta is scrap being BACKED OUT, which
--              raises good production rather than reducing it.
--
--              A PREVIEW LOGS NO FAILURE. The Fail: label's Audit.Audit_LogFailure
--              is gated on @PreviewOnly = 0. A team lead previewing a half-typed
--              sheet is typing, not failing, and would otherwise fill the failure
--              log with it. A refused SAVE still logs, unchanged.
```

and this change-log row:

```
--   2026-09-29 - 1.8 - @PreviewOnly BIT = 0, and a fourth result column PlanJson
--                      on every exit path. The confirmation panel previews
--                      through THIS proc rather than through a second
--                      computation in SQL or in Python. See the header section
--                      "THE PREVIEW IS THIS PROC, STOPPED ONE STATEMENT SHORT".
```

**(b) Signature** -- `@PreviewOnly` goes **last**, so no existing call site changes:

```sql
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT         = NULL,
    -- 1.8: run every check and build the plan, then stop before BEGIN TRANSACTION.
    @PreviewOnly        BIT            = 0
```

**(c) Declare `@PlanJson`** beside `@Status`:

```sql
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error', @NewId BIGINT = NULL;
    DECLARE @PlanJson NVARCHAR(MAX) = NULL;
```

**(d) Hoist `@PlannedDelta`.** Section 12 declares it inside its `IF`, so its value is unavailable to
the plan when no reading is declared. Replace

```sql
            DECLARE @PlannedDelta INT = @Total - @DieWmAfterMoves;
```
with a declaration above the `IF` and an assignment inside it:

```sql
        DECLARE @PlannedDelta INT = 0;
        IF @Total IS NOT NULL AND @Total <> @DieWmAfterMoves
        BEGIN
            SET @PlannedDelta = @Total - @DieWmAfterMoves;
```
(the `IF`'s body and its refusal are otherwise untouched.)

**(e) Section 13: build the plan and, in preview mode, return it.** Insert immediately after
section 12's `END`, immediately before `-- ===================== mutation =====================`:

```sql
        -- ---- 13. the plan, as one object (1.8) ----
        -- Built HERE because this is the one line at which every figure is known
        -- and none of it has happened yet. The preview returns it and stops; the
        -- save returns the same object and goes on to apply it. There is no
        -- second computation to drift.
        DECLARE @PlanAdded   INT = ISNULL((SELECT SUM(Gap) FROM @Plan WHERE Gap > 0), 0);
        DECLARE @PlanRemoved INT = ISNULL((SELECT -SUM(Gap) FROM @Plan WHERE Gap < 0), 0);
        DECLARE @PlanNew     INT = (SELECT COUNT(*) FROM @Plan WHERE IsNew = 1);
        DECLARE @PlanCorr    INT = (SELECT COUNT(*) FROM @Plan WHERE CorrectCount = 1 AND Gap <> 0);
        DECLARE @PlanStand   INT = (SELECT COUNT(*) FROM @Plan WHERE IsLocked = 1 AND Gap <> 0);
        DECLARE @PlanMoves   INT = (SELECT COUNT(*) FROM @Moves);
        -- spec sec 7.5: amber covers a reduction in PRODUCTION, DIE LIFE or a
        -- COUNT. A negative scrap delta is scrap being backed OUT -- it raises
        -- good production -- so it is deliberately not here.
        DECLARE @HasReduction BIT = CASE WHEN EXISTS (SELECT 1 FROM @Plan WHERE Gap < 0)
                                           OR @PlannedDelta < 0 THEN 1 ELSE 0 END;

        SET @PlanJson = (
            SELECT @ShiftLabel AS shiftLabel, @PressCode AS pressCode, @DieName AS dieName,
                   @Asset AS assetNumber, @Cavities AS activeCavities, @HasReduction AS hasReduction,
                   JSON_QUERY((SELECT @ShotBefore AS [before], @PlannedDelta AS delta,
                                      @ShotBefore + @PlannedDelta AS [after]
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS dieLife,
                   JSON_QUERY((SELECT @PlanAdded AS piecesAdded, @PlanRemoved AS piecesRemoved,
                                      @PlanNew AS newLots, @PlanCorr AS countsCorrected,
                                      @PlanStand AS countsStanding, @PlanMoves AS rowsMoved
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS totals,
                   -- ISNULL INSIDE the JSON_QUERY: FOR JSON over zero rows returns
                   -- NULL, the outer FOR JSON PATH then omits the key entirely, and
                   -- a Perspective binding that reads $.moves gets nothing at all
                   -- on exactly the ordinary path. Always a list, never a missing key.
                   JSON_QUERY(ISNULL((SELECT m.EntityType AS entityType, m.EntityId AS entityId,
                                             m.ToShiftId AS toShiftId,
                                             CONVERT(NVARCHAR(5), ts.ActualStart, 110) + N' ' + tss.Name AS toShiftLabel
                                      FROM @Moves m
                                      INNER JOIN Oee.Shift ts ON ts.Id = m.ToShiftId
                                      INNER JOIN Oee.ShiftSchedule tss ON tss.Id = ts.ShiftScheduleId
                                      ORDER BY m.EntityType, m.EntityId
                                      FOR JSON PATH), N'[]')) AS moves,
                   JSON_QUERY(ISNULL((SELECT p.Ltt AS ltt, i.PartNumber AS partNumber,
                                             tc.CavityCode AS cavityCode, p.IsNew AS isNew,
                                             p.Gap AS gap, p.IsLocked AS isLocked,
                                             p.CorrectCount AS countChanges,
                                             p.PieceCount AS pieceCountBefore,
                                             CASE WHEN p.CorrectCount = 1 THEN p.PieceCount + p.Gap
                                                  ELSE p.PieceCount END AS pieceCountAfter,
                                             lk.LockReason AS lockReason
                                      FROM @Plan p
                                      LEFT JOIN Parts.Item i ON i.Id = p.ItemId
                                      LEFT JOIN Tools.ToolCavity tc ON tc.Id = p.ToolCavityId
                                      OUTER APPLY Lots.ufn_DieCastLotCountLock(p.LotId) lk
                                      ORDER BY i.PartNumber, tc.CavityCode, p.Ltt
                                      FOR JSON PATH), N'[]')) AS lots,
                   JSON_QUERY(ISNULL((SELECT tc.CavityCode AS cavityCode, i.PartNumber AS partNumber,
                                             dc.Code AS defectCode, dc.Description AS defect,
                                             sp.Qty AS delta,
                                             CAST(CASE WHEN sp.DefectCodeId = @WarmCodeId THEN 1 ELSE 0 END AS BIT) AS isWarmUp
                                      FROM @Scrap sp
                                      INNER JOIN Tools.ToolCavity tc ON tc.Id = sp.ToolCavityId
                                      INNER JOIN Quality.DefectCode dc ON dc.Id = sp.DefectCodeId
                                      LEFT JOIN Parts.Item i ON i.Id = tc.ItemId
                                      ORDER BY i.PartNumber, tc.CavityCode, dc.Code
                                      FOR JSON PATH), N'[]')) AS scrap
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ---- 13a. the preview stops here (1.8) ----
        -- Nothing above this line has written anything: sections 1-12 read, parse
        -- and refuse, and they must, because every rejecting validation runs
        -- before BEGIN TRANSACTION. So a preview is a save that returns one
        -- statement early -- not a second implementation of one.
        IF @PreviewOnly = 1
        BEGIN
            SET @Status = 1;
            SET @Message = N'Nothing is saved yet. Check the changes, then save.';
            SET @NewId = NULL;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @PlanJson AS PlanJson;
            RETURN;
        END
```

**(f) The fourth column on the three existing exit paths.** Each `SELECT @Status AS Status, @Message
AS Message, @NewId AS NewId;` becomes

```sql
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @PlanJson AS PlanJson;
```

-- the success path after `COMMIT TRANSACTION`, the `CATCH` path (which also gains
`SET @PlanJson = NULL;` beside its `SET @NewId = NULL;`, because a rolled-back plan describes
nothing), and the `Fail:` path (where `@PlanJson` is still `NULL`, since section 13 is never
reached by a refusal).

**(g) `Fail:` does not log a preview.** The label's guard becomes:

```sql
Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter branch
    -- above can reach here with @AppUserId itself NULL -- guard the audit call
    -- so that case returns cleanly instead of throwing.
    -- 1.8: a PREVIEW never logs. A team lead previewing a half-typed sheet is
    -- typing, not failing; logging it would bury the real failures. A refused
    -- SAVE logs exactly as it always has.
    IF @PreviewOnly = 0 AND @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
```

- [ ] **Step 5: Run the test.** Same command. Expected: every `[Preview]` assertion passes, and
`060` / `070` / `080` are back to green with no assertion changed -- only their temp-table shapes.

- [ ] **Step 6: Full 0097 suite plus the procs that call the Save**

```powershell
.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test_Recon -Filter ""
```
Expected: Task 15's pass count plus the Task 17 and Task 18 assertions, no new failures. Exit code 1
with zero reported failures means a file's `sqlcmd` errored -- read the output; the likeliest cause
here is a temp table Step 2 missed.

- [ ] **Step 7: Byte-scan the changed files for non-ASCII**

```bash
python -c "
import io
for f in ['sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql','sql/tests/0097_DieCast_Reconciliation/090_Preview.sql']:
    d=open(f,'rb').read(); print(f, len([b for b in d if b>127]))
"
```
Expected: `0` for both.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftReconciliation_Save.sql sql/tests/0097_DieCast_Reconciliation/090_Preview.sql sql/tests/0097_DieCast_Reconciliation/060_Save_Refusals.sql sql/tests/0097_DieCast_Reconciliation/070_Save_Writes.sql sql/tests/0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql
git commit -m "feat(sql): the confirmation panel previews through the Save itself, not a second computation"
```

**What Plan 2 inherits from this, and what it must not do.**

- Two named queries, one procedure: `workorder/DieCastShiftReconciliation_Preview` with
  `@PreviewOnly` fixed at `1`, `workorder/DieCastShiftReconciliation_Save` with it fixed at `0`.
  Both are status-row procs and both take named-query `type: Query`.
- The confirmation panel renders `PlanJson` and **computes nothing from it**. The tick box reads
  `hasReduction`; the groups read `totals`, `moves`, `lots` and `scrap`; "counts left standing"
  reads the `lots` rows with `isLocked: true`, and each one's `lockReason` is the sentence to show.
- Plan 2 scope §9 question 3 is answered by this task. **Question 4 is not** -- whether the screen's
  own pre-save blocking checks (computed from `ActiveCavities`) are a sanctioned exception to "no
  business logic in Python" is still open, and now has an obvious alternative: a preview call is
  cheap, writes nothing, and returns the refusal verbatim, so the blocking checks could simply *be*
  a preview. Decide it once, in Plan 2, and write it down.

---

## What Plan 2 covers (not this plan)

The Ignition half, against the procs this plan builds:

- Core named queries for each read and for `..._Save` (status-row procs need `type: Query`; see `feedback_ignition_nq_type_for_status_row_procs`), all in **Core** -- MPP and MPP_Config have none of their own.
- `BlueRidge.Workorder.DieCastReconciliation` entity script: thin glue, zero domain decisions, `appUserId` passed by the caller (`BlueRidge.Common.Session.currentAppUserId(self.session)`).
- The screen at `/shop-floor/die-cast/reconcile`: landing list, the sheet-shaped reconciliation, the LTT entry bar, the move popup, the blocking checks, and the save confirmation with its reduction tick box -- all as built in `mockup/diecast_shift_reconciliation_mock.html`.
- The AD sign-in that opens the screen (`beginElevatedWindow`), and the "Shifts not reconciled" tile on the supervisor dashboard.
- Live smoke on the Dev gateway, then the full release contract: preview, rehearsal, fingerprint-guarded execute, scoped exports built from git, and a published runbook.
