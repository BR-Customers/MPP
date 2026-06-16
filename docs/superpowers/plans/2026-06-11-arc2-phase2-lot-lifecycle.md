# Arc 2 Phase 2 — LOT Lifecycle SQL Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the complete LOT mutation, genealogy, label, and pause surface as SQL — migration `0021` + ~15 stored procedures + test suite `0021_PlantFloor_Lot_Lifecycle/` — so downstream operator-station phases compose against a stable API.

**Architecture:** SQL-first. One versioned migration creates 5 tables + seeds; ~15 repeatable `CREATE OR ALTER` procs implement the contract; a numbered test suite asserts each via `INSERT-EXEC` into temp tables. B4 closure rows are maintained transactionally alongside every genealogy edge; B5 materialized columns are kept consistent. Perspective views are a deferred follow-on (not in this plan).

**Tech Stack:** SQL Server 2022, `sqlcmd`, the `test.Assert_*` framework, PowerShell runners (`Reset-DevDatabase.ps1`, `Run-Tests.ps1`).

**Spec:** `docs/superpowers/specs/2026-06-11-arc2-phase2-lot-lifecycle-design.md` — every implementer reads this first.

---

## Conventions every task follows (read once)

- **Proc skeleton:** copy the structure of `sql/migrations/repeatable/R__Lots_Lot_UpdateStatus.sql` (the closest reference: B1 context params, optimistic lock, `Lot`-entity audit, no OUTPUT params, nested-CATCH failure logging). The blank skeleton + rules are in `sql/scripts/_TEMPLATE_stored_procedure.sql`. Do NOT reproduce the error-handling scaffolding from memory — start from the reference file.
- **No OUTPUT params (FDS-11-011).** Mutation procs declare `@Status BIT`, `@Message NVARCHAR(500)`, and (Create-shaped) `@NewId BIGINT` as locals; every exit path ends `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId];`. Read procs SELECT their rowset directly; empty set = not found.
- **Audit:** success → `Audit.Audit_LogOperation` INSIDE the transaction with a `<LotName> · <Category> · <action>` Description (use `Audit.ufn_MidDot()` separator + `Audit.ufn_TruncateActivity()` cap) and resolved-FK `@OldValue`/`@NewValue` JSON via `JSON_QUERY((... FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))` — never a bare aliased `FOR JSON` subquery (double-encodes). Failures → `Audit.Audit_LogFailure` OUTSIDE the rolled-back transaction in a nested TRY/CATCH. `@LogEntityTypeCode` is `N'Lot'` for LOT mutations, `N'LotLabel'` for labels, `N'PauseEvent'` for pauses.
- **Guards:** every status-preserving mutation calls `Lots.Lot_AssertNotBlocked @LotId` first (it raises/returns a blocked signal — see its repeatable for the call convention). `Lot_UpdateStatus` is the SOLE owner of the status-transition matrix; do NOT add transitions elsewhere.
- **File naming:** procs → `sql/migrations/repeatable/R__Lots_<Entity>_<Verb>.sql`, one proc per file, `CREATE OR ALTER`. Tests → `sql/tests/0021_PlantFloor_Lot_Lifecycle/<NNN>_<name>.sql`.
- **ASCII-only** in all seed strings + ZPL bodies. Byte-scan before applying (`feedback_ascii_only_seed_data`).
- **Test file shape:** start with `EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/<file>';` then `GO`. Teardown fixtures FK-safe (delete child/audit rows before parents) at top AND implicitly via reset. Capture proc result via `CREATE TABLE #r (...); INSERT INTO #r EXEC <proc> ...;` then assert. Available asserts: `test.Assert_IsEqual @TestName,@Expected,@Actual`; `test.Assert_IsTrue @TestName,@Condition`(BIT); `test.Assert_IsNull @TestName,@Value`; `test.Assert_IsNotNull @TestName,@Value`; `test.Assert_RowCount @TestName,@ExpectedCount,@ActualCount`; `test.Assert_Contains @TestName,@Haystack,@Needle`.
- **Run the suite:** `powershell -File sql\tests\Run-Tests.ps1` — it resets the DB (applies all migrations + repeatables + seeds), deploys helpers, runs every numbered suite, prints pass/fail totals. There is no single-suite filter; the whole suite runs each time. Phase 1 baseline is **1308 passing**; each task must keep that green and add its own.
- **Commits:** stage explicit paths only (never `git add -A`); omit the Claude co-author trailer; branch is `jacques/working`.

## File-structure map

**Migration (Task 0):**
- Create `sql/migrations/versioned/0021_arc2_phase2_lot_lifecycle.sql` — 5 tables (`LotGenealogy`, `LotAttributeChange`, `LotLabel`, `PauseEvent`, `LabelTemplate`) + LogEventType/LogEntityType seeds + LabelTemplate seeds.

**Procs (Tasks 1–7), each `sql/migrations/repeatable/`:**
- `R__Lots_Lot_Update.sql`, `R__Lots_Lot_UpdateAttribute.sql` (Task 1)
- `R__Lots_Lot_Split.sql` (Task 2)
- `R__Lots_Lot_Merge.sql` (Task 3)
- `R__Lots_LotGenealogy_RecordConsumption.sql` (Task 4)
- `R__Lots_Lot_GetGenealogyTree.sql`, `R__Lots_Lot_GetParents.sql`, `R__Lots_Lot_GetChildren.sql`, `R__Lots_Lot_GetAttributeHistory.sql` (Task 5)
- `R__Lots_LotLabel_Print.sql`, `R__Lots_LotLabel_Reprint.sql` (Task 6)
- `R__Lots_LotPause_Place.sql`, `R__Lots_LotPause_Resume.sql`, `R__Lots_LotPause_GetByLocation.sql`, `R__Lots_LotPause_GetCountsByLocation.sql` (Task 7)

**Tests (Tasks 0–7), each `sql/tests/0021_PlantFloor_Lot_Lifecycle/`:**
- `000_schema.sql` (Task 0), `010_Lot_Update.sql` (1), `020_Lot_Split.sql` (2), `030_Lot_Merge.sql` (3), `040_LotGenealogy_RecordConsumption.sql` (4), `050_Lot_GetGenealogyTree.sql` (5), `070_Label_print_reprint.sql` (6), `060_LotPause_lifecycle.sql` + `065_LotPause_indicator.sql` (7).

**Shared test fixture note:** several suites need a saved LOT. The minimal create is `EXEC Lots.Lot_Create` — read `R__Lots_Lot_Create.sql` for its required params (ItemId, LotOriginTypeId, LotStatusId omitted→Good, PieceCount, CurrentLocationId, AppUserId, …). Reuse seeded Items/Locations/AppUsers from the Phase 1 seeds (e.g. an Item with `Code='5G0'`, a Cell location, AppUser id present in seeds). Each test file creates its own LOTs with unique `LotName` prefixes (e.g. `'P2-UPD-%'`, `'P2-SPLIT-%'`) so suites don't collide.

---

## Task 0: Migration 0021 — schema + seeds

**Files:**
- Create: `sql/migrations/versioned/0021_arc2_phase2_lot_lifecycle.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/000_schema.sql`

Reference the partition treatment in `0020_arc2_phase1_shop_floor_foundation.sql` (search `LotStatusHistory` for the born-partitioned `ps_MonthlyUtc` pattern: aligned composite PK `(Id, <ts>)` NONCLUSTERED `ON ps_MonthlyUtc(<ts>)` + clustered index `ON ps_MonthlyUtc(<ts>)`, plus a `Audit.PartitionRetention` registration row).

- [ ] **Step 1: Write the schema-assertion test**

Create `sql/tests/0021_PlantFloor_Lot_Lifecycle/000_schema.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/000_schema.sql';
GO

-- Each new table exists
DECLARE @n INT;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LotGenealogy' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LotGenealogy exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LotAttributeChange' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LotAttributeChange exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LotLabel' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LotLabel exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'PauseEvent' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.PauseEvent exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LabelTemplate' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LabelTemplate exists', @ExpectedCount = 1, @ActualCount = @n;
GO

-- PauseEvent open-pause filtered unique index exists
DECLARE @ix INT = (SELECT COUNT(*) FROM sys.indexes WHERE name = N'UQ_PauseEvent_OpenLotLocation'
                   AND object_id = OBJECT_ID(N'Lots.PauseEvent'));
EXEC test.Assert_RowCount @TestName = N'[Schema] PauseEvent open-pause unique index', @ExpectedCount = 1, @ActualCount = @ix;
GO

-- New LogEventType codes seeded
DECLARE @ev INT = (SELECT COUNT(*) FROM Audit.LogEventType
                   WHERE Code IN (N'LotUpdated', N'LotSplit', N'LotMerged', N'LotConsumed', N'LotPaused', N'LotResumed', N'LabelPrinted'));
EXEC test.Assert_RowCount @TestName = N'[Schema] 7 new LogEventType codes seeded', @ExpectedCount = 7, @ActualCount = @ev;
GO

-- One active LabelTemplate per active LabelTypeCode (>=1)
DECLARE @lt INT = (SELECT COUNT(*) FROM Lots.LabelTemplate WHERE DeprecatedAt IS NULL);
EXEC test.Assert_IsTrue @TestName = N'[Schema] >=1 active LabelTemplate seeded',
    @Condition = CASE WHEN @lt >= 1 THEN 1 ELSE 0 END;
GO
```

- [ ] **Step 2: Run the suite to verify the schema test fails**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: the reset step fails OR `000_schema.sql` asserts fail (tables missing) — because `0021` doesn't exist yet. Confirm failures reference the missing Lots tables.

- [ ] **Step 3: Write migration 0021 — tables**

Create `sql/migrations/versioned/0021_arc2_phase2_lot_lifecycle.sql`. Header comment block (purpose, table list, partition notes) like `0020`. Then, each guarded `IF OBJECT_ID(...) IS NULL`:

```sql
-- Lots.LotGenealogy (BORN PARTITIONED on EventAt; 20-yr Honda class)
IF OBJECT_ID(N'Lots.LotGenealogy', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotGenealogy (
        Id                 BIGINT        NOT NULL IDENTITY(1,1),
        ParentLotId        BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        ChildLotId         BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        RelationshipTypeId BIGINT        NOT NULL REFERENCES Lots.GenealogyRelationshipType(Id),
        PieceCount         INT           NULL,
        EventUserId        BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT        NULL     REFERENCES Location.Location(Id),
        EventAt            DATETIME2(3)  NOT NULL CONSTRAINT DF_LotGenealogy_EventAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotGenealogy PRIMARY KEY NONCLUSTERED (Id, EventAt) ON ps_MonthlyUtc(EventAt)
    );
    CREATE CLUSTERED INDEX CIX_LotGenealogy_ParentEventAt
        ON Lots.LotGenealogy (ParentLotId, EventAt) ON ps_MonthlyUtc(EventAt);
    CREATE INDEX IX_LotGenealogy_Child
        ON Lots.LotGenealogy (ChildLotId, EventAt) ON ps_MonthlyUtc(EventAt);
END
GO

IF NOT EXISTS (SELECT 1 FROM Audit.PartitionRetention WHERE SchemaName = N'Lots' AND TableName = N'LotGenealogy')
    INSERT INTO Audit.PartitionRetention (SchemaName, TableName, RetentionMonths, Description)
    VALUES (N'Lots', N'LotGenealogy', 240, N'20-yr Honda genealogy edge log.');
GO

-- Lots.LotAttributeChange (not partitioned)
IF OBJECT_ID(N'Lots.LotAttributeChange', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotAttributeChange (
        Id                 BIGINT        NOT NULL IDENTITY(1,1),
        LotId              BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        AttributeName      NVARCHAR(100) NOT NULL,
        OldValue           NVARCHAR(500) NULL,
        NewValue           NVARCHAR(500) NULL,
        ChangedByUserId    BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT        NULL     REFERENCES Location.Location(Id),
        ChangedAt          DATETIME2(3)  NOT NULL CONSTRAINT DF_LotAttributeChange_ChangedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotAttributeChange PRIMARY KEY NONCLUSTERED (Id)
    );
    CREATE INDEX IX_LotAttributeChange_Lot ON Lots.LotAttributeChange (LotId, ChangedAt);
END
GO

-- Lots.LotLabel (not partitioned)
IF OBJECT_ID(N'Lots.LotLabel', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LotLabel (
        Id                 BIGINT         NOT NULL IDENTITY(1,1),
        LotId              BIGINT         NOT NULL REFERENCES Lots.Lot(Id),
        LabelTypeCodeId    BIGINT         NOT NULL REFERENCES Lots.LabelTypeCode(Id),
        PrintReasonCodeId  BIGINT         NOT NULL REFERENCES Lots.PrintReasonCode(Id),
        ParentLotId        BIGINT         NULL     REFERENCES Lots.Lot(Id),
        ZplContent         NVARCHAR(MAX)  NOT NULL,
        PrinterName        NVARCHAR(100)  NULL,
        PrintedByUserId    BIGINT         NOT NULL REFERENCES Location.AppUser(Id),
        TerminalLocationId BIGINT         NULL     REFERENCES Location.Location(Id),
        PrintedAt          DATETIME2(3)   NOT NULL CONSTRAINT DF_LotLabel_PrintedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LotLabel PRIMARY KEY NONCLUSTERED (Id)
    );
    CREATE INDEX IX_LotLabel_Lot ON Lots.LotLabel (LotId, PrintedAt);
END
GO

-- Lots.PauseEvent (not partitioned)
IF OBJECT_ID(N'Lots.PauseEvent', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.PauseEvent (
        Id              BIGINT        NOT NULL IDENTITY(1,1),
        LotId           BIGINT        NOT NULL REFERENCES Lots.Lot(Id),
        LocationId      BIGINT        NOT NULL REFERENCES Location.Location(Id),
        PausedByUserId  BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
        PausedAt        DATETIME2(3)  NOT NULL CONSTRAINT DF_PauseEvent_PausedAt DEFAULT SYSUTCDATETIME(),
        PausedReason    NVARCHAR(500) NULL,
        ResumedByUserId BIGINT        NULL     REFERENCES Location.AppUser(Id),
        ResumedAt       DATETIME2(3)  NULL,
        ResumedRemarks  NVARCHAR(500) NULL,
        CONSTRAINT PK_PauseEvent PRIMARY KEY NONCLUSTERED (Id),
        CONSTRAINT CK_PauseEvent_ResumePaired CHECK (
            (ResumedByUserId IS NULL AND ResumedAt IS NULL) OR
            (ResumedByUserId IS NOT NULL AND ResumedAt IS NOT NULL))
    );
    CREATE UNIQUE INDEX UQ_PauseEvent_OpenLotLocation
        ON Lots.PauseEvent (LotId, LocationId) WHERE ResumedAt IS NULL;
    CREATE INDEX IX_PauseEvent_OpenByLocation
        ON Lots.PauseEvent (LocationId) WHERE ResumedAt IS NULL;
    CREATE INDEX IX_PauseEvent_Lot ON Lots.PauseEvent (LotId, PausedAt DESC);
END
GO

-- Lots.LabelTemplate (1:1 active per LabelTypeCode)
IF OBJECT_ID(N'Lots.LabelTemplate', N'U') IS NULL
BEGIN
    CREATE TABLE Lots.LabelTemplate (
        Id              BIGINT         NOT NULL IDENTITY(1,1),
        LabelTypeCodeId BIGINT         NOT NULL REFERENCES Lots.LabelTypeCode(Id),
        ZplBody         NVARCHAR(MAX)  NOT NULL,
        DeprecatedAt    DATETIME2(3)   NULL,
        CreatedAt       DATETIME2(3)   NOT NULL CONSTRAINT DF_LabelTemplate_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_LabelTemplate PRIMARY KEY NONCLUSTERED (Id)
    );
    CREATE UNIQUE INDEX UQ_LabelTemplate_ActiveType
        ON Lots.LabelTemplate (LabelTypeCodeId) WHERE DeprecatedAt IS NULL;
END
GO
```

- [ ] **Step 4: Write migration 0021 — seeds**

Append to `0021`. Insert-if-missing by Code (idempotent re-run). For `LogEventType` / `LogEntityType`, match the column shape used by `0004`/`0020` seeds (read `R__Audit_LogEventType_List.sql` to confirm columns — typically `Code`, `Name`, plus a severity/category if present). ASCII-only ZPL.

```sql
-- New operational LogEventType codes
INSERT INTO Audit.LogEventType (Code, Name)
SELECT v.Code, v.Name
FROM (VALUES
    (N'LotUpdated',   N'LOT Updated'),
    (N'LotSplit',     N'LOT Split'),
    (N'LotMerged',    N'LOT Merged'),
    (N'LotConsumed',  N'LOT Consumed'),
    (N'LotPaused',    N'LOT Paused'),
    (N'LotResumed',   N'LOT Resumed'),
    (N'LabelPrinted', N'LOT Label Printed')
) v(Code, Name)
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEventType e WHERE e.Code = v.Code);
GO

-- New LogEntityType codes (insert-if-missing)
INSERT INTO Audit.LogEntityType (Code, Name)
SELECT v.Code, v.Name
FROM (VALUES (N'LotLabel', N'LOT Label'), (N'PauseEvent', N'Pause Event'), (N'LotGenealogy', N'LOT Genealogy')) v(Code, Name)
WHERE NOT EXISTS (SELECT 1 FROM Audit.LogEntityType e WHERE e.Code = v.Code);
GO

-- LabelTemplate seed: one ASCII ZPL body per active LabelTypeCode.
-- Tokens resolved at print time: {LotName} {ParentLotNumber} {ItemCode} {PieceCount} {PrintedAt}
INSERT INTO Lots.LabelTemplate (LabelTypeCodeId, ZplBody)
SELECT ltc.Id,
       N'^XA^FO40,40^A0N,40,40^FDLOT {LotName}^FS' +
       N'^FO40,90^A0N,30,30^FDItem {ItemCode}  Qty {PieceCount}^FS' +
       N'^FO40,130^A0N,30,30^FDParent {ParentLotNumber}^FS' +
       N'^FO40,170^A0N,24,24^FD{PrintedAt}^FS' +
       N'^FO40,210^BY2^BCN,80,Y,N,N^FD{LotName}^FS^XZ'
FROM Lots.LabelTypeCode ltc
WHERE ltc.DeprecatedAt IS NULL
  AND NOT EXISTS (SELECT 1 FROM Lots.LabelTemplate t WHERE t.LabelTypeCodeId = ltc.Id AND t.DeprecatedAt IS NULL);
GO

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES (N'0021_arc2_phase2_lot_lifecycle', N'Arc 2 Phase 2: LotGenealogy, LotAttributeChange, LotLabel, PauseEvent, LabelTemplate + seeds.');
GO
```

Note: if `LabelTypeCode` has no `DeprecatedAt` column, drop that predicate (verify against `0004`). Verify the `LogEventType`/`LogEntityType` column list against the actual table before finalizing — adjust the `INSERT` column list to match.

- [ ] **Step 5: Byte-scan the migration for non-ASCII**

Run: `powershell -Command "$b=[IO.File]::ReadAllBytes('sql/migrations/versioned/0021_arc2_phase2_lot_lifecycle.sql'); ($b | Where-Object {$_ -gt 127}).Count"`
Expected: `0` (no non-ASCII bytes). If nonzero, find and replace the offending character with ASCII.

- [ ] **Step 6: Run the suite — schema test passes**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: reset applies `0021` cleanly; `000_schema.sql` asserts all PASS; Phase 1 total still 1308; new schema asserts added. No failures.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/versioned/0021_arc2_phase2_lot_lifecycle.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/000_schema.sql
git commit -m "feat(sql): Phase 2 migration 0021 - LOT lifecycle tables + seeds"
```

---

## Task 1 (G1): Lot_Update + Lot_UpdateAttribute

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_Update.sql`, `sql/migrations/repeatable/R__Lots_Lot_UpdateAttribute.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/010_Lot_Update.sql`

**Contract (from spec §4.1):**
- `Lots.Lot_UpdateAttribute(@LotId, @AttributeName NVARCHAR(100), @NewValue NVARCHAR(500), @AppUserId, @TerminalLocationId=NULL)` — single-field helper. Reads current value of the named field (support at minimum `PieceCount`), `Lot_AssertNotBlocked`, writes one `LotAttributeChange` row, UPDATEs the column, audits `LotUpdated`. Returns `Status, Message`.
- `Lots.Lot_Update(@LotId, @PieceCount INT=NULL, @Weight DECIMAL(12,4)=NULL, @WeightUomId BIGINT=NULL, @VendorLotNumber NVARCHAR(100)=NULL, @RowVersion BINARY(8)=NULL, @AppUserId, @TerminalLocationId=NULL)` — `Lot_AssertNotBlocked`; optimistic-lock check (lenient when `@RowVersion` NULL, like `Lot_UpdateStatus`); for each provided param that differs from current, insert a `LotAttributeChange` row; UPDATE `Lot`; if `PieceCount` changed, set `InventoryAvailable = @PieceCount - <consumed>` (B5; consumed = `ISNULL((SELECT SUM(ConsumedPieceCount-ish) ...),0)` — for Phase 2 with no consumption yet, this equals `@PieceCount`); audit `LotUpdated` with field-diff Description. Returns `Status, Message`.

**NULL semantics:** a NULL incoming param means "leave unchanged" (partial update), NOT "set to NULL". Document this in the proc header.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0021_PlantFloor_Lot_Lifecycle/010_Lot_Update.sql`. Build a LOT via `Lot_Create`, then:

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/010_Lot_Update.sql';
GO
-- Fixture: create a LOT (read R__Lots_Lot_Create.sql for exact params)
DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @LocId  BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'DC1-M01');
DECLARE @User   BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'DieCast');
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId=@ItemId, @LotOriginTypeId=@OriginId, @PieceCount=100,
    @CurrentLocationId=@LocId, @AppUserId=@User /* + Tool/Cavity per proc reqs for DieCast */;
DECLARE @LotId BIGINT = (SELECT NewId FROM @cr);
GO
-- Test 1: PieceCount change writes a LotAttributeChange row + updates the column
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id DESC);
DECLARE @User BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r EXEC Lots.Lot_Update @LotId=@LotId, @PieceCount=80, @AppUserId=@User;
DECLARE @ok BIT = (SELECT Status FROM @r);
EXEC test.Assert_IsTrue @TestName=N'[LotUpdate] update succeeds', @Condition=@ok;
DECLARE @pc INT = (SELECT PieceCount FROM Lots.Lot WHERE Id=@LotId);
EXEC test.Assert_IsEqual @TestName=N'[LotUpdate] PieceCount now 80', @Expected=N'80', @Actual=CAST(@pc AS NVARCHAR(20));
DECLARE @chg INT = (SELECT COUNT(*) FROM Lots.LotAttributeChange WHERE LotId=@LotId AND AttributeName=N'PieceCount');
EXEC test.Assert_RowCount @TestName=N'[LotUpdate] one PieceCount change row', @ExpectedCount=1, @ActualCount=@chg;
GO
-- Test 2: stale RowVersion rejected
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id DESC);
DECLARE @User BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r2 EXEC Lots.Lot_Update @LotId=@LotId, @PieceCount=70,
    @RowVersion=0x0000000000000001, @AppUserId=@User;
DECLARE @s2 BIT = (SELECT Status FROM @r2);
EXEC test.Assert_IsTrue @TestName=N'[LotUpdate] stale RowVersion rejected', @Condition=CASE WHEN @s2=0 THEN 1 ELSE 0 END;
GO
-- Test 3: no-change call is a clean no-op (zero new change rows) — assert count unchanged
-- Test 4: blocked LOT rejected (set status Hold via direct UPDATE for the fixture, call Lot_Update, expect Status=0)
```

Fill in Tests 3 and 4 concretely following the same capture-and-assert shape (Test 4: directly `UPDATE Lots.Lot SET LotStatusId=(Hold id)` on a throwaway LOT, call `Lot_Update`, assert `Status=0` and message mentions blocked).

- [ ] **Step 2: Run suite, verify 010 fails**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: `010_Lot_Update.sql` errors/fails — `Lots.Lot_Update` does not exist.

- [ ] **Step 3: Write `R__Lots_Lot_UpdateAttribute.sql`**

Start from `R__Lots_Lot_UpdateStatus.sql` structure. Body: validate params; `Lot_AssertNotBlocked`; read current column value (a small `CASE @AttributeName` to pick the column, supporting `PieceCount`); insert `LotAttributeChange (LotId, AttributeName, OldValue, NewValue, ChangedByUserId, TerminalLocationId, ChangedAt)`; UPDATE the column; `Audit_LogOperation` `N'LotUpdated'`; `SELECT @Status, @Message`. Wrap mutation in a transaction.

- [ ] **Step 4: Write `R__Lots_Lot_Update.sql`**

Start from `R__Lots_Lot_UpdateStatus.sql`. Read current row (`PieceCount`, `Weight`, `WeightUomId`, `VendorLotNumber`, `RowVersion`) into locals. Validate LOT exists; `Lot_AssertNotBlocked`; optimistic-lock check (`IF @RowVersion IS NOT NULL AND @RowVersion <> @CurrentRowVer` → reject). Open transaction. For each of the four fields, `IF @Param IS NOT NULL AND @Param <> @Current` → insert a `LotAttributeChange` row and include in the UPDATE SET list. If `PieceCount` changed, also `SET InventoryAvailable = @PieceCount` (Phase 2 simplification — no consumption yet; add the `- consumed` term only if a consumption source exists). Build a field-diff Description (`@LotName + ufn_MidDot + N'Update' + ufn_MidDot + <changed field summary>`), capped via `ufn_TruncateActivity`. `Audit_LogOperation` `N'LotUpdated'` with resolved Old/New JSON. COMMIT. `SELECT @Status, @Message`. If nothing changed, COMMIT a no-op with a "no changes" message and `Status=1`.

- [ ] **Step 5: Run suite — 010 passes**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: `010_Lot_Update.sql` all PASS; full suite green (1308 + 000 + 010 asserts).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Update.sql sql/migrations/repeatable/R__Lots_Lot_UpdateAttribute.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/010_Lot_Update.sql
git commit -m "feat(sql): Lot_Update + Lot_UpdateAttribute with field-level audit"
```

---

## Task 2 (G2): Lot_Split

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_Split.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/020_Lot_Split.sql`

**Contract (spec §4.2 + §2.2 + Option A return):**
`Lots.Lot_Split(@ParentLotId, @ChildrenJson NVARCHAR(MAX), @AppUserId, @TerminalLocationId=NULL)`.
- `@ChildrenJson` = `[{"pieceCount":25,"currentLocationId":N}, ...]`. Parse with `OPENJSON(... WITH (pieceCount INT, currentLocationId BIGINT))`.
- BEGIN TRAN; `SELECT @ParentName=LotName, @ParentItem=ItemId, @ParentPc=PieceCount FROM Lots.Lot WITH (UPDLOCK, HOLDLOCK) WHERE Id=@ParentLotId;` (serializes concurrent splits of this parent).
- `Lot_AssertNotBlocked @ParentLotId`.
- Validate ≥1 child; `SUM(child.pieceCount) <= @ParentPc`.
- Next suffix ordinal:
  ```sql
  DECLARE @NextOrd INT = ISNULL((
      SELECT MAX(TRY_CAST(RIGHT(LotName, 2) AS INT))
      FROM Lots.Lot
      WHERE ParentLotId = @ParentLotId
        AND LotName LIKE @ParentName + N'-[0-9][0-9]'
  ), 0) + 1;
  IF @NextOrd + (child count) - 1 > 99  -> reject "exceeds 99 sublots".
  ```
- For each child (cursor or numbered loop over the parsed `@ChildrenJson`): build `@ChildName = @ParentName + N'-' + RIGHT(N'0' + CAST(@NextOrd AS NVARCHAR(2)), 2)`; `EXEC Lots.Lot_Create` for the child (ItemId=@ParentItem, ToolId=NULL, ToolCavityId=NULL, PieceCount=child share, CurrentLocationId=child loc, ParentLotId=@ParentLotId, LotName forced to @ChildName — **verify `Lot_Create` accepts an explicit `@LotName`; if it only auto-mints, add an optional `@LotNameOverride` param to `Lot_Create` in this task and default it NULL so existing callers are unaffected**); capture child Id; insert `LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId=1 /*Split*/, PieceCount, EventUserId, ...)`; insert closure rows:
  ```sql
  INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
  SELECT c.AncestorLotId, @ChildId, c.Depth + 1
  FROM Lots.LotGenealogyClosure c
  WHERE c.DescendantLotId = @ParentLotId;
  ```
  increment `@NextOrd`; append `(@ChildId, @ChildName, child pc)` to a `@Children` table var.
- Reduce parent: `EXEC Lots.Lot_UpdateAttribute @LotId=@ParentLotId, @AttributeName=N'PieceCount', @NewValue=<residual>, ...`. If residual=0, `EXEC Lots.Lot_UpdateStatus @LotId=@ParentLotId, @NewLotStatusId=(Closed id), ...`.
- `Audit_LogOperation` `N'LotSplit'`. COMMIT.
- **Return (Option A):** `SELECT @Status AS Status, @Message AS Message, ChildLotId, ChildLotName, PieceCount FROM @Children;` — one row per child, status repeated. On any validation/error exit (before the loop), `SELECT @Status, @Message, CAST(NULL AS BIGINT) AS ChildLotId, CAST(NULL AS NVARCHAR(50)) AS ChildLotName, CAST(NULL AS INT) AS PieceCount;` (single row).

- [ ] **Step 1: Write the failing test**

Create `020_Lot_Split.sql`. Fixtures: a parent LOT with PieceCount 50. Capture the multi-row result into a temp table matching the Option A shape:

```sql
CREATE TABLE #s (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #s EXEC Lots.Lot_Split @ParentLotId=@LotId,
    @ChildrenJson=N'[{"pieceCount":25,"currentLocationId":<loc>},{"pieceCount":25,"currentLocationId":<loc>}]',
    @AppUserId=@User;
```

Assertions:
- `[Split] succeeds` — `Status` on first row = 1.
- `[Split] two children returned` — `Assert_RowCount @ExpectedCount=2` over `#s`.
- `[Split] child names are <parent>-01 / -02` — assert the two `ChildLotName` values match `@ParentName + '-01'` and `'-02'`.
- `[Split] parent reduced to 0 and Closed` — query `Lots.Lot` parent: PieceCount 0, status Closed.
- `[Split] closure has parent->child depth 1` — `SELECT Depth FROM LotGenealogyClosure WHERE AncestorLotId=@ParentLotId AND DescendantLotId=<child1>` = 1.
- `[Split] sum-exceeds-parent rejected` — fresh parent PieceCount 10, split `[{6},{6}]`, assert single-row `Status=0`.
- `[Split] re-split appends suffix` — split child `-01` again, assert new grandchild name ends `-01-01`.
- `[Split] >99 rejected` — hard to drive 99 inserts; instead seed one child named `<parent>-99` directly, then call split, assert `Status=0` message mentions 99. (Document this shortcut in a comment.)

- [ ] **Step 2: Run suite, verify 020 fails**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: `020_Lot_Split.sql` fails — proc missing.

- [ ] **Step 3 (if needed): add `@LotNameOverride` to Lot_Create**

If `R__Lots_Lot_Create.sql` only auto-mints `LotName`, add `@LotNameOverride NVARCHAR(50) = NULL` and use it when non-NULL (skip the `IdentifierSequence_Next` mint in that branch). Re-deploy is automatic via the next suite run. Keep the auto-mint default path byte-for-byte unchanged so the 1308 baseline holds. Commit this as part of Task 2.

- [ ] **Step 4: Write `R__Lots_Lot_Split.sql`**

Implement per the contract. Use a `@Children TABLE (Ord INT IDENTITY, ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT)` and a `WHILE` loop over the parsed children (numbered via a `ROW_NUMBER()` materialized into a table var) — avoid a cursor. All inside one transaction; the `UPDLOCK, HOLDLOCK` read is the first statement after BEGIN TRAN.

- [ ] **Step 5: Run suite — 020 passes**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: `020_Lot_Split.sql` all PASS; full suite green.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Split.sql sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/020_Lot_Split.sql
git commit -m "feat(sql): Lot_Split - parent-derived sublot suffix + closure maintenance"
```

---

## Task 3 (G2): Lot_Merge

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_Lot_Merge.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/030_Lot_Merge.sql`

**Contract (spec §4.2):**
`Lots.Lot_Merge(@SourceLotIdsJson NVARCHAR(MAX), @OutputItemId BIGINT, @OutputLocationId BIGINT, @AppUserId, @TerminalLocationId=NULL, @SupervisorOverride BIT = 0)`.
- Parse `@SourceLotIdsJson` (`[id, id, ...]`) via `OPENJSON` into a `@Sources TABLE (LotId BIGINT)`.
- Validate ≥2 sources; each exists; `Lot_AssertNotBlocked` per source; all same `ItemId` = `@OutputItemId`; all `Good` status.
- Die-rank compat: if sources have differing `ToolId`, look up `Tools.DieRankCompatibility` for each pair; if any incompatible AND `@SupervisorOverride=0` → reject with a clear message (matrix unpopulated counts as incompatible). `@SupervisorOverride=1` bypasses.
- BEGIN TRAN. `EXEC Lots.Lot_Create` the output: fresh MESL (auto-mint, no override), ItemId=@OutputItemId, ToolId=NULL, ToolCavityId=NULL, PieceCount = SUM(source PieceCount), CurrentLocationId=@OutputLocationId. Capture `@OutputId`.
- For each source: insert `LotGenealogy (ParentLotId=source, ChildLotId=@OutputId, RelationshipTypeId=2 /*Merge*/, PieceCount=source pc, ...)`; `EXEC Lots.Lot_UpdateStatus source -> Closed`.
- Closure ancestor-dedup:
  ```sql
  INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
  SELECT c.AncestorLotId, @OutputId, MIN(c.Depth) + 1
  FROM Lots.LotGenealogyClosure c
  WHERE c.DescendantLotId IN (SELECT LotId FROM @Sources)
    AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogyClosure x
                    WHERE x.AncestorLotId = c.AncestorLotId AND x.DescendantLotId = @OutputId)
  GROUP BY c.AncestorLotId;
  ```
  (The output self-row `(O,O,0)` is written by `Lot_Create`; the `NOT EXISTS` guard prevents colliding with it when a source equals nothing — defensive.)
- `Audit_LogOperation` `N'LotMerged'`. COMMIT. `SELECT @Status, @Message, @NewId` (`@NewId=@OutputId`).

- [ ] **Step 1: Write the failing test**

Create `030_Lot_Merge.sql`. Fixtures need `Tools.Tool` rows + `Tools.DieRankCompatibility` rows — read those table defs first; reuse seeded tools where possible. Tests:
- `[Merge] same-Item same-Tool succeeds` — two Good source LOTs, same Item, same ToolId; assert `Status=1`, output exists with NULL ToolId, both sources Closed.
- `[Merge] output carries summed PieceCount`.
- `[Merge] cross-Tool rank-compat=1 succeeds` — seed a compatible pair in `DieRankCompatibility`.
- `[Merge] cross-Tool rank-compat=0 rejects` — incompatible pair, `@SupervisorOverride=0`, assert `Status=0`.
- `[Merge] supervisor override bypasses` — same incompatible pair, `@SupervisorOverride=1`, assert `Status=1`.
- `[Merge] shared ancestor deduped` — give two sources a common ancestor (split a grandparent into the two sources first), merge them, assert exactly one closure row `(ancestor, output)` with the MIN depth.

- [ ] **Step 2: Run suite, verify 030 fails**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: `030_Lot_Merge.sql` fails — proc missing.

- [ ] **Step 3: Write `R__Lots_Lot_Merge.sql`** per the contract.

- [ ] **Step 4: Run suite — 030 passes**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: `030_Lot_Merge.sql` all PASS; full suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Merge.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/030_Lot_Merge.sql
git commit -m "feat(sql): Lot_Merge - rank-compat rules + closure ancestor-dedup"
```

---

## Task 4 (G2): LotGenealogy_RecordConsumption

**Files:**
- Create: `sql/migrations/repeatable/R__Lots_LotGenealogy_RecordConsumption.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/040_LotGenealogy_RecordConsumption.sql`

**Contract (spec §4.2):**
`Lots.LotGenealogy_RecordConsumption(@SourceLotId, @ConsumedPieceCount INT, @ProducedLotId BIGINT=NULL, @ProducedContainerId BIGINT=NULL, @ProducedSerialNumber NVARCHAR(100)=NULL, @AppUserId, @TerminalLocationId=NULL)`.
- Validate `@SourceLotId` exists; `@ConsumedPieceCount > 0`; exactly one produced target supplied (LOT xor container xor serial).
- `Lot_AssertNotBlocked @SourceLotId`.
- BEGIN TRAN. Insert `LotGenealogy (ParentLotId=@SourceLotId, ChildLotId=@ProducedLotId, RelationshipTypeId=3 /*Consumption*/, PieceCount=@ConsumedPieceCount, ...)` (`@ProducedLotId` is required — see the resolution note below, so `ChildLotId` is never NULL). Insert the single-edge closure rows (same shape as one Split edge: every ancestor of source → produced at depth+1).
- `Audit_LogOperation` `N'LotConsumed'`. COMMIT. `SELECT @Status, @Message, @NewId` (`@NewId` = the new `LotGenealogy.Id`).

Note: `LotGenealogy.ChildLotId` is `NOT NULL` per the table. For container/serial consumption with no produced LOT, set `ChildLotId = @SourceLotId` is WRONG. Resolve in this task: either (a) make `ChildLotId` nullable in `0021` (preferred — update Task 0's table + re-reason), or (b) require `@ProducedLotId` for the genealogy write and handle container/serial trace in the Phase 6 consumption-event path. **Decision for this plan: require `@ProducedLotId` NOT NULL for `LotGenealogy_RecordConsumption`; container/serial-only consumption is recorded by the Phase 6 `ConsumptionEvent` table, not here.** Validate `@ProducedLotId IS NOT NULL` and reject otherwise. (This keeps `ChildLotId NOT NULL` intact; container/serial params stay in the signature for forward-compat but are currently informational.)

- [ ] **Step 1: Write the failing test**

Create `040_LotGenealogy_RecordConsumption.sql`. Tests:
- `[Consume] LOT-to-LOT edge recorded` — source + produced LOT; assert one `LotGenealogy` Consumption row; `NewId` returned.
- `[Consume] closure rows inserted` — assert `(source, produced)` closure row depth 1 (plus ancestors if source has any).
- `[Consume] multi-source consumption` — two sources consumed into one produced LOT; assert two Consumption edges + both ancestor sets in closure.
- `[Consume] missing produced LOT rejected` — `@ProducedLotId=NULL`, assert `Status=0`.
- `[Consume] zero piece count rejected`.

- [ ] **Step 2: Run suite, verify 040 fails.** `powershell -File sql\tests\Run-Tests.ps1` → fail (proc missing).

- [ ] **Step 3: Write `R__Lots_LotGenealogy_RecordConsumption.sql`** per the contract.

- [ ] **Step 4: Run suite — 040 passes.** `powershell -File sql\tests\Run-Tests.ps1` → all PASS; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_LotGenealogy_RecordConsumption.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/040_LotGenealogy_RecordConsumption.sql
git commit -m "feat(sql): LotGenealogy_RecordConsumption - consumption edge + closure"
```

---

## Task 5 (G3): Genealogy + history reads

**Files:**
- Create: `R__Lots_Lot_GetGenealogyTree.sql`, `R__Lots_Lot_GetParents.sql`, `R__Lots_Lot_GetChildren.sql`, `R__Lots_Lot_GetAttributeHistory.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/050_Lot_GetGenealogyTree.sql`

**Contracts (spec §4.3) — all READ procs (no status row):**
- `Lot_GetGenealogyTree(@LotId, @Direction NVARCHAR(20)=N'Both')` — closure-backed. `Ancestors`: rows from `LotGenealogyClosure` where `DescendantLotId=@LotId AND Depth > 0`, joined to `Lot`/`Item`, `Direction='Ancestor'`. `Descendants`: where `AncestorLotId=@LotId AND Depth > 0`, `Direction='Descendant'`. `Both` = UNION ALL. Columns: `LotId, LotName, ItemId, ItemCode, Depth, Direction`. Honor `@Direction` IN (`'Ancestors'`/`'Descendants'`/`'Both'`).
- `Lot_GetParents(@LotId)` — one-hop up: `LotGenealogy` rows where `ChildLotId=@LotId` (distinct parents), resolved to `Lot`/`Item`, plus the `RelationshipType` code/name.
- `Lot_GetChildren(@LotId)` — one-hop down: `LotGenealogy` rows where `ParentLotId=@LotId`.
- `Lot_GetAttributeHistory(@LotId)` — UNION of `LotAttributeChange`, `LotStatusHistory`, `LotMovement`, normalized to `(EventAt, EventKind NVARCHAR(20), Detail NVARCHAR(500), ByUserId)`, ordered by `EventAt`.

- [ ] **Step 1: Write the failing test**

Create `050_Lot_GetGenealogyTree.sql`. Build a 3-level tree: grandparent → split into 2 parents → split one parent into 2 children. Then:
- `[Tree] descendants of grandparent` — `Lot_GetGenealogyTree @LotId=<gp>, @Direction='Descendants'` returns all 4 below it; assert row count + that a depth-2 child is present with `Depth=2`.
- `[Tree] ancestors of a leaf` — `@Direction='Ancestors'` from a leaf returns its parent (depth 1) + grandparent (depth 2).
- `[Tree] both` — union count.
- `[Parents] one-hop` — `Lot_GetParents` of a child returns exactly its direct parent.
- `[Children] one-hop` — `Lot_GetChildren` of a parent returns its direct children only (not grandchildren).
- `[History] unions three streams` — after an update + a move on a LOT, `Lot_GetAttributeHistory` returns ≥2 rows ordered by time.

Capture each read via `INSERT INTO #t EXEC ...` with a temp table matching the documented columns, then `Assert_RowCount` / `Assert_IsEqual`.

- [ ] **Step 2: Run suite, verify 050 fails.** `powershell -File sql\tests\Run-Tests.ps1` → fail.

- [ ] **Step 3: Write the four read procs.** No status row; SELECT directly; empty set = not found.

- [ ] **Step 4: Run suite — 050 passes.** `powershell -File sql\tests\Run-Tests.ps1` → all PASS; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_GetGenealogyTree.sql sql/migrations/repeatable/R__Lots_Lot_GetParents.sql sql/migrations/repeatable/R__Lots_Lot_GetChildren.sql sql/migrations/repeatable/R__Lots_Lot_GetAttributeHistory.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/050_Lot_GetGenealogyTree.sql
git commit -m "feat(sql): genealogy + attribute-history read procs (closure-backed tree)"
```

---

## Task 6 (G4): LotLabel_Print + LotLabel_Reprint

**Files:**
- Create: `R__Lots_LotLabel_Print.sql`, `R__Lots_LotLabel_Reprint.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/070_Label_print_reprint.sql`

**Contract (spec §4.4):**
- `LotLabel_Print(@LotId, @LabelTypeCodeId, @PrintReasonCodeId, @AppUserId, @TerminalLocationId=NULL)`:
  - Resolve active `ZplBody` for `@LabelTypeCodeId` (reject if none active).
  - Resolve fields: `@LotName`, `@ItemCode` (from `Item`), `@PieceCount`, `@PrintedAt = CONVERT(NVARCHAR(19), SYSUTCDATETIME(), 120)`, `@ParentLotNumber` = parent LOT's `LotName` when `Lot.ParentLotId` is set else `''`. Set `@LabelParentLotId = Lot.ParentLotId`.
  - Render: chained `REPLACE(@Zpl, N'{LotName}', @LotName)` etc. for all five tokens.
  - INSERT `LotLabel (LotId, LabelTypeCodeId, PrintReasonCodeId, ParentLotId, ZplContent, PrintedByUserId, TerminalLocationId, PrintedAt)`; capture `@NewId`.
  - `Audit_LogOperation` `N'LabelPrinted'` (`@LogEntityTypeCode=N'LotLabel'`, `@EntityId=@NewId`).
  - `SELECT @Status, @Message, @NewId, @Zpl AS ZplContent`.
- `LotLabel_Reprint(@LotId, @PrintReasonCodeId, @AppUserId, @TerminalLocationId=NULL)` — resolve the LOT's most recent `LotLabel.LabelTypeCodeId` (or default to `Primary`), then perform the same render+insert with the supplied reason. Same return shape.

- [ ] **Step 1: Write the failing test**

Create `070_Label_print_reprint.sql`. Tests (capture into `#l (Status BIT, Message NVARCHAR(500), NewId BIGINT, ZplContent NVARCHAR(MAX))`):
- `[Label] initial print succeeds + returns ZPL` — `Status=1`, `ZplContent` not null.
- `[Label] all tokens substituted` — `Assert_IsTrue` that `ZplContent NOT LIKE '%{%}%'` (no leftover `{Token}`), via `CASE WHEN CHARINDEX(N'{', ZplContent)=0 THEN 1 ELSE 0 END`.
- `[Label] LotName rendered into ZPL` — `Assert_Contains @Haystack=ZplContent, @Needle=<lotname>`.
- `[Label] sublot label carries ParentLotId + parent number` — print a label for a split child; assert the inserted `LotLabel.ParentLotId` is the parent and `ZplContent` contains the parent LotName.
- `[Label] reprint records a second row with reason` — `Assert_RowCount` over `LotLabel` for the LOT = 2; second row's `PrintReasonCodeId` is the reprint reason.
- `[Label] missing active template rejected` — call print with a `@LabelTypeCodeId` that has no active template, assert `Status=0`.

- [ ] **Step 2: Run suite, verify 070 fails.** `powershell -File sql\tests\Run-Tests.ps1` → fail.

- [ ] **Step 3: Write the two label procs** per the contract.

- [ ] **Step 4: Run suite — 070 passes.** `powershell -File sql\tests\Run-Tests.ps1` → all PASS; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_LotLabel_Print.sql sql/migrations/repeatable/R__Lots_LotLabel_Reprint.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/070_Label_print_reprint.sql
git commit -m "feat(sql): LotLabel_Print + Reprint - SQL-side ZPL render from LabelTemplate"
```

---

## Task 7 (G5): Pause lifecycle

**Files:**
- Create: `R__Lots_LotPause_Place.sql`, `R__Lots_LotPause_Resume.sql`, `R__Lots_LotPause_GetByLocation.sql`, `R__Lots_LotPause_GetCountsByLocation.sql`
- Test: `sql/tests/0021_PlantFloor_Lot_Lifecycle/060_LotPause_lifecycle.sql`, `sql/tests/0021_PlantFloor_Lot_Lifecycle/065_LotPause_indicator.sql`

**Contracts (spec §4.5):**
- `LotPause_Place(@LotId, @LocationId, @PausedReason NVARCHAR(500)=NULL, @AppUserId, @TerminalLocationId=NULL)` — `Lot_AssertNotBlocked`; pre-check no open pause for `(LotId, LocationId)` (clean message before hitting the filtered-unique violation); INSERT open `PauseEvent`; audit `LotPaused` (`@LogEntityTypeCode=N'PauseEvent'`, `@EntityId=@NewId`); `SELECT @Status, @Message, @NewId`.
- `LotPause_Resume(@PauseEventId, @ResumedRemarks NVARCHAR(500)=NULL, @AppUserId, @TerminalLocationId=NULL)` — reject if not found or already resumed; SET resume columns; audit `LotResumed`; `SELECT @Status, @Message`.
- `LotPause_GetByLocation(@LocationId)` — READ: open pauses ordered by `PausedAt`: `PauseEventId, LotId, LotName, ItemId, ItemCode, PausedAt, PausedByUserId, PausedReason`.
- `LotPause_GetCountsByLocation(@LocationId)` — READ: single row `OpenPauseCount INT`.

- [ ] **Step 1: Write the failing tests (both files)**

`060_LotPause_lifecycle.sql`:
- `[Pause] place succeeds + open row exists`.
- `[Pause] double-place same (LotId,Location) rejected` — second `LotPause_Place` returns `Status=0`.
- `[Pause] same LOT paused at two Cells allowed` — place at location A and location B; both `Status=1`.
- `[Pause] resume closes it` — `LotPause_Resume` sets `ResumedAt`; assert the row's `ResumedAt` not null; resumer id recorded.
- `[Pause] resumer differs from pauser allowed` — resume with a different AppUser; `Status=1`.
- `[Pause] resume-already-resumed rejected` — second resume `Status=0`.

`065_LotPause_indicator.sql`:
- `[Indicator] count reflects open pauses` — place 2 at a location, resume 1, assert `LotPause_GetCountsByLocation` returns `OpenPauseCount=1`.
- `[Indicator] list ordered by PausedAt` — place 2 (with distinct timestamps), assert `LotPause_GetByLocation` returns them oldest-first.

- [ ] **Step 2: Run suite, verify 060 + 065 fail.** `powershell -File sql\tests\Run-Tests.ps1` → fail (procs missing).

- [ ] **Step 3: Write the four pause procs** per the contracts.

- [ ] **Step 4: Run suite — 060 + 065 pass.** `powershell -File sql\tests\Run-Tests.ps1` → all PASS; suite green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_LotPause_Place.sql sql/migrations/repeatable/R__Lots_LotPause_Resume.sql sql/migrations/repeatable/R__Lots_LotPause_GetByLocation.sql sql/migrations/repeatable/R__Lots_LotPause_GetCountsByLocation.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/060_LotPause_lifecycle.sql sql/tests/0021_PlantFloor_Lot_Lifecycle/065_LotPause_indicator.sql
git commit -m "feat(sql): LotPause lifecycle + indicator read procs (OI-21)"
```

---

## Task 8: Integration sign-off

**Files:** none new — verification + status doc.

- [ ] **Step 1: Full clean run**

Run: `powershell -File sql\tests\Run-Tests.ps1`
Expected: reset applies migrations `0001`…`0021` + all repeatables + seeds with zero errors; every suite passes; **total ≥ ~1400** (1308 baseline + ~90–120 new Phase 2 asserts). Record the exact total.

- [ ] **Step 2: Verify the "Phase 2 complete when" checklist (spec §7)**

Confirm each box: 5 tables created; all 15 procs deployed (`SELECT COUNT(*) FROM sys.procedures WHERE name LIKE 'Lot%' OR name LIKE 'LotPause%' OR name LIKE 'LotLabel%' OR name LIKE 'LotGenealogy%'` sanity check); B4 closure verified by the split/merge/consume tests; B5 columns consistent (010 + 020 asserts). Downstream contract callable.

- [ ] **Step 3: Confirm no ClockNumber/PinHash regressions + ASCII**

Run: `powershell -Command "Get-ChildItem sql\migrations\versioned\0021*.sql,sql\migrations\repeatable\R__Lots_*.sql | ForEach-Object { $b=[IO.File]::ReadAllBytes($_.FullName); if (($b | Where-Object {$_ -gt 127}).Count -gt 0) { $_.Name } }"`
Expected: no output (all Phase 2 files ASCII-clean).

- [ ] **Step 4: Update PROJECT_STATUS.md**

Add a "Recently closed" entry: Phase 2 LOT lifecycle SQL foundation landed, suite total, the parent-derived suffix + closure-maintenance + SQL-ZPL decisions, and the deferred follow-on (the 4 Perspective views). Note migration `0021` is now taken.

- [ ] **Step 5: Commit**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): Arc 2 Phase 2 LOT lifecycle SQL foundation complete"
```

---

## Notes for the executor

- **B5 precision is intentionally deferred** (spec §8). `InventoryAvailable`/`TotalInProcess` are kept *consistent* (a PieceCount correction tracks through), not driven by the full event formula — that lands with Phase 3 event writers. Don't "fix" the simplified recompute as if it were a bug.
- **Supervisor override** (`Lot_Merge.@SupervisorOverride`) is trusted by the proc; the gateway owns *who* may elevate (FDS-04-007, default-deny until the IdP is wired). The proc just honors the flag.
- **`LabelTypeCode.DeprecatedAt`** may not exist — verify against `0004_phase3_reference_lookups.sql` before using it in the `LabelTemplate` seed/join; drop the predicate if absent.
- **`Lot_Create` param surface** — every task that creates fixture LOTs must read `R__Lots_Lot_Create.sql` for the current required params (DieCast origin requires Tool/Cavity; use a non-DieCast `LotOriginType` for simple fixtures to avoid Tool setup where the test doesn't care about Tool).
- **One result set per proc** — `Lot_Split` is the only multi-row mutation (Option A). Assert it via a temp table with the exact 5-column shape.
```
