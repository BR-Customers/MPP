# Arc 2 Phase 3 — Die-Cast SQL Deltas + Operator-Station Front-End — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three Phase-3 SQL deltas (migration `0023`) the die-cast front-end depends on, fix one confirmed reject-concurrency bug, then build the single-screen Die Cast Operator Station (Perspective views + Core NQs + entity scripts + routes) that wraps the shipped + delta procs.

**Architecture:** SQL-first. **Part A** extends shipped SQL: a new `Parts.DataCollectionFieldDataType` code table + `DataCollectionField.DataType` FK column (typed-widget driver), a `Workorder.ProductionEvent_ListByLot` read proc (cumulative-cavity card + last-shot hint), additive `@LotName` + `@CavityNote` params on `Lots.Lot_Create` (D4 pre-printed-LTT seam + D2 manual cavity), and a defensive in-transaction guard fixing a reject TOCTOU. **Part B** is the thin, business-logic-free Ignition layer: one no-tabs two-column `DieCastEntry` page (matching the customer-approved mockup) with embedded Checkpoint + Reject cards, five Core NQs, four Core entity modules, and three routes. SQL is authoritative; the UI never enforces a rule the proc doesn't.

**Tech Stack:** SQL Server 2022 (versioned + repeatable migrations, `test.*` assertion harness, `Run-Tests.ps1`); Ignition 8.3 Perspective (file-authored views + `scan.ps1`), Core/MPP project split (NQs + entity scripts in Core, views in MPP).

---

## Source specs (read before starting)

- **Part A:** `docs/superpowers/specs/2026-06-15-arc2-phase3-sql-deltas-design.md` (the authoritative SQL design — full proc bodies + decisions DT-1/DT-2/DT-3/PE-1/D4/D2).
- **Part B:** `docs/superpowers/specs/2026-06-15-arc2-phase3-die-cast-frontend-design.md` (the authoritative FE design — D1–D5 settled, view/NQ/entity-script layout).
- **Predecessor (already built, migration `0022`):** `docs/superpowers/specs/2026-06-12-arc2-phase3-die-cast-sql-design.md`.

## Reconciliation findings — VERIFIED against as-built code (do not re-derive)

These three facts were checked against the working tree on 2026-06-16. They override any spec text that conflicts.

1. **Migration number is `0023`.** Disk is versioned through `0022_arc2_phase3_die_cast.sql`. Phase 4 specs were renumbered to `0024`/`0025` (2026-06-16) so `0023` is uncontested. Audit high-water after `0022`: `LogEventType` max = 33, `LogEntityType` max = 46. **`0023` adds NO audit-lookup rows** (no LogEventType/LogEntityType) — it is table + column + proc changes only, so it cannot collide on audit Ids.

2. **`ProductionEvent_Record` (as-built `R__Workorder_ProductionEvent_Record.sql`) has NO `@EventAt` param**, and its JSON-children param is **`@FieldValuesJson`** — NOT `@DataCollectionValuesJson`. The FE spec §5/§6 NQ + entity script name both wrongly. **Part B authors the NQ + entity script against the real signature:** drop `@EventAt` (the proc stamps `SYSUTCDATETIME()` itself), and use `@FieldValuesJson` (`:fieldValuesJson`). The as-built signature is:
   ```
   Workorder.ProductionEvent_Record
       @LotId BIGINT, @OperationTemplateId BIGINT,
       @ShotCount INT = NULL, @ScrapCount INT = NULL, @ScrapSourceId BIGINT = NULL,
       @WeightValue DECIMAL(12,4) = NULL, @WeightUomId BIGINT = NULL,
       @WorkOrderOperationId BIGINT = NULL, @Remarks NVARCHAR(500) = NULL,
       @FieldValuesJson NVARCHAR(MAX) = NULL,
       @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
     → Status, Message, NewId
   ```

3. **`RejectEvent_Record` has a real TOCTOU (Task A5 fixes it).** The `IF @Quantity > @PieceCount` gate reads `PieceCount` **unlocked, before `BEGIN TRANSACTION`** (the SELECT at the "held-LOT guard" block). The decrement runs later under `UPDLOCK/HOLDLOCK`. Two concurrent over-rejects both pass the stale gate, then the second drives `PieceCount` negative — and skips close-at-zero because `@NewPieceCount` is `< 0`, not `= 0`. This is outside the deltas spec's literal scope (§10 lists `RejectEvent_Record` as "shipped, unchanged") but is a correctness bug in a Honda-traceability system; the project-status addendum explicitly lists "the TOCTOU race on the reject quantity check" as a finding to fold in. The fix is a 2-line in-transaction guard that throws to the existing CATCH.

## File structure

**Part A (SQL):**
- Create: `sql/migrations/versioned/0023_arc2_phase3_sql_deltas.sql` — DataType code table + column + backfill + FK + SchemaVersion row.
- Modify: `sql/migrations/repeatable/R__Parts_DataCollectionField_List.sql` — v3.0, join DataType.
- Create: `sql/migrations/repeatable/R__Workorder_ProductionEvent_ListByLot.sql` — new read proc.
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql` — `@LotName` + `@CavityNote`.
- Modify: `sql/migrations/repeatable/R__Workorder_RejectEvent_Record.sql` — TOCTOU guard.
- Create: `sql/tests/0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql`
- Create: `sql/tests/0023_PlantFloor_DieCast_Deltas/020_ProductionEvent_ListByLot.sql`
- Create: `sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql`
- Create: `sql/tests/0023_PlantFloor_DieCast_Deltas/040_RejectEvent_concurrency_guard.sql`

**Part B (Ignition — Core NQs + entity scripts):**
- Create: `ignition/projects/Core/ignition/named-query/workorder/ProductionEvent_Record/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/workorder/RejectEvent_Record/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/workorder/ProductionEvent_ListByLot/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/tools/ToolCavity_ListActiveByTool/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/tools/ToolAssignment_ListActiveByCell/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql` — add `:lotName` (+ `:cavityNote` if FE passes it).
- Create: `ignition/projects/Core/.../script-python/BlueRidge/Workorder/ProductionEvent/code.py`
- Create: `ignition/projects/Core/.../script-python/BlueRidge/Workorder/RejectEvent/code.py`
- Create: `ignition/projects/Core/.../script-python/BlueRidge/Tools/ToolCavity/code.py`
- Create: `ignition/projects/Core/.../script-python/BlueRidge/Tools/ToolAssignment/code.py`
- Modify: `ignition/projects/Core/.../script-python/BlueRidge/Lots/Lot/code.py` — `create(..., lotName=None, cavityNote=None)` forward.

**Part B (Ignition — MPP views):**
- Create: `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/DieCastEntry/view.json`
- Create: `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DieCastEntry/CheckpointPanel/view.json`
- Create: `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DieCastEntry/RejectPanel/view.json`
- Create: `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DieCastEntry/FieldInputRow/view.json`
- Create: `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DieCastEntry/PeerTallyRow/view.json`
- Modify: `ignition/projects/MPP/.../page-config/config.json` — three `/shop-floor/die-cast*` routes.
- Modify: `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/HomeRouter/view.json` — Die Cast tile.
- Create (dev aid): `sql/scratch/smoke_seed_phase3_diecast.sql`

---

# PART A — SQL DELTAS (migration 0023)

> Execution mode: **in-session TDD** (well-specified pattern SQL where context is already held — per `feedback_subagent_flow_cost_calibration`). Apply each change to `MPP_MES_Dev`, run the targeted test file, then the full suite.

## Task A1: `DataCollectionFieldDataType` table + `DataCollectionField.DataType` FK column

**Files:**
- Create: `sql/migrations/versioned/0023_arc2_phase3_sql_deltas.sql`
- Test: `sql/tests/0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql`

- [ ] **Step 1: Write the migration** (`0023_arc2_phase3_sql_deltas.sql`). Mirror the `0022` header style + idempotent guards + `SchemaVersion` insert. ASCII-only seeds (byte-scan before applying — `feedback_ascii_only_seed_data`).

```sql
-- ============================================================
-- Migration:   0023_arc2_phase3_sql_deltas.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-06-16
-- Description: Arc 2 Phase 3 SQL deltas (die-cast front-end dependencies).
--              Schema + seed only (procs are repeatable migrations):
--                1. NEW code table Parts.DataCollectionFieldDataType (5 rows:
--                   String/Integer/Decimal/Boolean/Date) — FK code-table for the
--                   typed-widget driver (DT-1: a real FK table, NOT the legacy
--                   Tools.ToolAttributeDefinition.DataType CHECK string).
--                2. Parts.DataCollectionField.DataTypeId BIGINT — added NULL,
--                   backfilled by Code, then ALTER NOT NULL + FK (DT-2: deliberate
--                   typing, not a silent NOT NULL DEFAULT).
--              Adds NO audit-lookup rows. Idempotent (re-apply = no-op).
-- ============================================================

-- 1. Code table
IF OBJECT_ID(N'Parts.DataCollectionFieldDataType', N'U') IS NULL
    CREATE TABLE Parts.DataCollectionFieldDataType (
        Id           BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Code         NVARCHAR(20)  NOT NULL,
        Name         NVARCHAR(50)  NOT NULL,
        Description  NVARCHAR(200) NULL,
        SortOrder    INT           NOT NULL DEFAULT 0,
        CreatedAt    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_DataCollectionFieldDataType_Code UNIQUE (Code)
    );
GO

-- 2. Seed the 5 datatype rows (manual Id, idempotent on Id/Code)
SET IDENTITY_INSERT Parts.DataCollectionFieldDataType ON;
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 1 OR Code = N'String')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (1, N'String',  N'Text',           1);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 2 OR Code = N'Integer')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (2, N'Integer', N'Whole Number',   2);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 3 OR Code = N'Decimal')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (3, N'Decimal', N'Decimal Number', 3);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 4 OR Code = N'Boolean')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (4, N'Boolean', N'Yes / No',       4);
IF NOT EXISTS (SELECT 1 FROM Parts.DataCollectionFieldDataType WHERE Id = 5 OR Code = N'Date')
    INSERT INTO Parts.DataCollectionFieldDataType (Id, Code, Name, SortOrder) VALUES (5, N'Date',    N'Date',           5);
SET IDENTITY_INSERT Parts.DataCollectionFieldDataType OFF;
GO

-- 3. Add the FK column NULL (temporarily) for backfill
IF COL_LENGTH(N'Parts.DataCollectionField', N'DataTypeId') IS NULL
    ALTER TABLE Parts.DataCollectionField ADD DataTypeId BIGINT NULL;
GO

-- 4. Backfill the 7 shipped rows by Code (resolve FK Id by Code — no hard-coded Ids)
UPDATE dcf
SET DataTypeId = dt.Id
FROM Parts.DataCollectionField dcf
INNER JOIN (VALUES
    (N'MaterialVerification', N'Boolean'),
    (N'SerialNumber',         N'String'),
    (N'DieInfo',              N'String'),
    (N'CavityInfo',           N'String'),
    (N'Weight',               N'Decimal'),
    (N'GoodCount',            N'Integer'),
    (N'BadCount',             N'Integer')
) AS m(FieldCode, TypeCode) ON m.FieldCode = dcf.Code
INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Code = m.TypeCode
WHERE dcf.DataTypeId IS NULL;
GO

-- 5. Defensive: fail loudly if any row stayed unclassified (else the NOT NULL ALTER throws opaquely)
IF EXISTS (SELECT 1 FROM Parts.DataCollectionField WHERE DataTypeId IS NULL)
    RAISERROR(N'0023 backfill incomplete: a Parts.DataCollectionField row has a NULL DataTypeId.', 16, 1);
GO

-- 6. Lock the column NOT NULL + add the FK (guarded)
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Parts.DataCollectionField')
           AND name = N'DataTypeId' AND is_nullable = 1)
    ALTER TABLE Parts.DataCollectionField ALTER COLUMN DataTypeId BIGINT NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_DataCollectionField_DataType')
    ALTER TABLE Parts.DataCollectionField
        ADD CONSTRAINT FK_DataCollectionField_DataType
            FOREIGN KEY (DataTypeId) REFERENCES Parts.DataCollectionFieldDataType(Id);
GO

-- 7. Record migration
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0023_arc2_phase3_sql_deltas')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0023_arc2_phase3_sql_deltas',
            N'Arc 2 Phase 3 SQL deltas: Parts.DataCollectionFieldDataType code table (5 rows) + DataCollectionField.DataTypeId NOT NULL FK (backfilled). Procs (DataCollectionField_List v3.0, ProductionEvent_ListByLot, Lot_Create @LotName/@CavityNote) are repeatable. No audit-lookup rows.');
GO
PRINT 'Migration 0023 (Arc 2 Phase 3 SQL deltas) applied.';
GO
```

- [ ] **Step 2: Byte-scan the seed strings for non-ASCII**

Run: `python -c "b=open(r'sql/migrations/versioned/0023_arc2_phase3_sql_deltas.sql','rb').read(); bad=[(i,hex(c)) for i,c in enumerate(b) if c>127]; print('NON-ASCII:',bad[:20] if bad else 'none')"`
Expected: `NON-ASCII: none`

- [ ] **Step 3: Apply the migration to the dev DB**

Run (PowerShell): `sqlcmd -S localhost -d MPP_MES_Dev -E -b -i sql/migrations/versioned/0023_arc2_phase3_sql_deltas.sql`
Expected: `Migration 0023 (Arc 2 Phase 3 SQL deltas) applied.` and no errors. (If your dev harness uses a wrapper such as `Reset-DevDatabase.ps1` / a numbered apply script, use that instead — match the project's established apply path.)

- [ ] **Step 4: Re-apply once to prove idempotency**

Run the same `sqlcmd` line again.
Expected: same PRINT, no errors (every step guarded → no-op).

- [ ] **Step 5: Write the test file** `010_DataCollectionFieldDataType.sql`. Mirror the `0022` harness exactly (`test.BeginTestFile` / `test.Assert_IsEqual @TestName,@Expected,@Actual` string-compare / GO batches / `test.EndTestFile`).

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql';
GO

-- Test 1: the 5 datatype codes exist
DECLARE @Cnt INT = (SELECT COUNT(*) FROM Parts.DataCollectionFieldDataType
                    WHERE Code IN (N'String',N'Integer',N'Decimal',N'Boolean',N'Date'));
DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[DT] 5 datatype codes present', @Expected = N'5', @Actual = @CntStr;
GO

-- Test 2: no DataCollectionField row is untyped
DECLARE @Null INT = (SELECT COUNT(*) FROM Parts.DataCollectionField WHERE DataTypeId IS NULL);
DECLARE @NullStr NVARCHAR(10) = CAST(@Null AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[DT] no untyped DataCollectionField', @Expected = N'0', @Actual = @NullStr;
GO

-- Test 3: backfill correctness (spot-check each datatype)
DECLARE @W NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'Weight');
EXEC test.Assert_IsEqual @TestName = N'[DT] Weight->Decimal', @Expected = N'Decimal', @Actual = @W;
DECLARE @G NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'GoodCount');
EXEC test.Assert_IsEqual @TestName = N'[DT] GoodCount->Integer', @Expected = N'Integer', @Actual = @G;
DECLARE @D NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'DieInfo');
EXEC test.Assert_IsEqual @TestName = N'[DT] DieInfo->String', @Expected = N'String', @Actual = @D;
DECLARE @M NVARCHAR(20) = (SELECT dt.Code FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId WHERE dcf.Code = N'MaterialVerification');
EXEC test.Assert_IsEqual @TestName = N'[DT] MaterialVerification->Boolean', @Expected = N'Boolean', @Actual = @M;
GO

-- Test 4: FK rejects an invalid DataTypeId
DECLARE @Threw NVARCHAR(10) = N'0';
BEGIN TRY
    INSERT INTO Parts.DataCollectionField (Code, Name, DataTypeId)
    VALUES (N'ZZ-DT-NEG-TEST', N'neg', 999999999);
END TRY
BEGIN CATCH
    SET @Threw = N'1';
END CATCH
DELETE FROM Parts.DataCollectionField WHERE Code = N'ZZ-DT-NEG-TEST';
EXEC test.Assert_IsEqual @TestName = N'[DT] FK rejects invalid DataTypeId', @Expected = N'1', @Actual = @Threw;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 6: Run the test file**

Run: `./Run-Tests.ps1` (or the project's test runner) targeting the suite; confirm `0023_PlantFloor_DieCast_Deltas/010_*` assertions pass.
Expected: all `[DT]` assertions PASS; exit 0.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/versioned/0023_arc2_phase3_sql_deltas.sql sql/tests/0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql
git commit -m "feat(sql): 0023 DataCollectionFieldDataType code table + DataType FK column (Phase 3 delta)"
```

## Task A2: `DataCollectionField_List` v3.0 — surface DataType

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_DataCollectionField_List.sql`
- Test: extend `sql/tests/0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql`

- [ ] **Step 1: Add a failing assertion to `010_*` (before `EXEC test.EndTestFile`)**

```sql
-- Test 5: DataCollectionField_List surfaces DataTypeCode/Name
DECLARE @Cols TABLE (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
                     DataTypeId BIGINT, DataTypeCode NVARCHAR(20), DataTypeName NVARCHAR(50),
                     CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO @Cols EXEC Parts.DataCollectionField_List @IncludeDeprecated = 0;
DECLARE @WDt NVARCHAR(20) = (SELECT DataTypeCode FROM @Cols WHERE Code = N'Weight');
EXEC test.Assert_IsEqual @TestName = N'[DT] _List returns DataTypeCode for Weight', @Expected = N'Decimal', @Actual = @WDt;
DECLARE @Untyped INT = (SELECT COUNT(*) FROM @Cols WHERE DataTypeCode IS NULL);
DECLARE @UntypedStr NVARCHAR(10) = CAST(@Untyped AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[DT] _List rows all carry a DataTypeCode', @Expected = N'0', @Actual = @UntypedStr;
GO
```

- [ ] **Step 2: Run to verify it FAILS** (current `_List` is v2.0 and the INSERT-EXEC shape won't match — the temp table has 9 cols, the proc returns 6).
Run: the test runner on `010_*`. Expected: FAIL (column count mismatch on `INSERT ... EXEC`).

- [ ] **Step 3: Rewrite `R__Parts_DataCollectionField_List.sql` to v3.0**

```sql
-- ... (keep header; bump to Version 3.0; add change-log line:
--   2026-06-16 - 3.0 - Join Parts.DataCollectionFieldDataType; return DataTypeId/Code/Name)
CREATE OR ALTER PROCEDURE Parts.DataCollectionField_List
    @IncludeDeprecated BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        dcf.Id, dcf.Code, dcf.Name, dcf.Description,
        dcf.DataTypeId,
        dt.Code AS DataTypeCode,
        dt.Name AS DataTypeName,
        dcf.CreatedAt, dcf.DeprecatedAt
    FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId
    WHERE (@IncludeDeprecated = 1 OR dcf.DeprecatedAt IS NULL)
    ORDER BY dcf.Code;
END;
GO
```

- [ ] **Step 4: Apply the repeatable proc**

Run: `sqlcmd -S localhost -d MPP_MES_Dev -E -b -i sql/migrations/repeatable/R__Parts_DataCollectionField_List.sql`
Expected: no errors.

- [ ] **Step 5: Run the test file — verify PASS**
Expected: `[DT] _List ...` assertions PASS.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Parts_DataCollectionField_List.sql sql/tests/0023_PlantFloor_DieCast_Deltas/010_DataCollectionFieldDataType.sql
git commit -m "feat(sql): DataCollectionField_List v3.0 returns DataType (Phase 3 delta)"
```

## Task A3: `Workorder.ProductionEvent_ListByLot` read proc (header-only, PE-1a)

**Files:**
- Create: `sql/migrations/repeatable/R__Workorder_ProductionEvent_ListByLot.sql`
- Test: `sql/tests/0023_PlantFloor_DieCast_Deltas/020_ProductionEvent_ListByLot.sql`

- [ ] **Step 1: Write the test file FIRST** (proc does not exist yet → first batch errors). Use `Lot_Create` + `ProductionEvent_Record` to build fixtures; FK-safe teardown per `feedback_arc2_lot_test_teardown_fk_order` (closure → genealogy → ProductionEventValue → ProductionEvent → RejectEvent → LotEventLog/Movement/StatusHistory → Lot).

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/020_ProductionEvent_ListByLot.sql';
GO

-- ---- teardown prior fixtures (FK-safe) ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN
    (SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

-- fixture: an eligible Cell with NO active tool (so Lot_Create needs no Tool/Cavity)
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @DcsTemplate BIGINT = (SELECT TOP 1 Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot' AND DeprecatedAt IS NULL);

DECLARE @LotId BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=100, @AppUserId=1;
SELECT @LotId = NewId FROM #C; DROP TABLE #C;

-- two checkpoints, increasing cumulative shots
CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P EXEC Workorder.ProductionEvent_Record @LotId=@LotId, @OperationTemplateId=@DcsTemplate, @ShotCount=50, @ScrapCount=1, @AppUserId=1;
DELETE FROM #P;
INSERT INTO #P EXEC Workorder.ProductionEvent_Record @LotId=@LotId, @OperationTemplateId=@DcsTemplate, @ShotCount=120, @ScrapCount=3, @AppUserId=1;
DROP TABLE #P;
GO

-- Test 1: ordering + promoted columns
DECLARE @LotId BIGINT = (SELECT TOP 1 Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' ORDER BY Id DESC);
DECLARE @R TABLE (Id BIGINT, LotId BIGINT, OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50),
    OperationTemplateName NVARCHAR(100), WorkOrderOperationId BIGINT, EventAt DATETIME2(3),
    ShotCount INT, ScrapCount INT, ScrapSourceId BIGINT, WeightValue DECIMAL(12,4), WeightUomId BIGINT,
    WeightUomCode NVARCHAR(50), AppUserId BIGINT, ByUser NVARCHAR(200), TerminalLocationId BIGINT, Remarks NVARCHAR(500));
INSERT INTO @R EXEC Workorder.ProductionEvent_ListByLot @LotId = @LotId;
DECLARE @Cnt INT = (SELECT COUNT(*) FROM @R); DECLARE @CntStr NVARCHAR(10) = CAST(@Cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PEL] 2 checkpoints returned', @Expected = N'2', @Actual = @CntStr;
-- chronological: first row is the 50-shot checkpoint
DECLARE @FirstShots NVARCHAR(10) = (SELECT CAST(ShotCount AS NVARCHAR(10)) FROM
    (SELECT ShotCount, ROW_NUMBER() OVER (ORDER BY EventAt ASC, Id ASC) rn FROM @R) x WHERE rn = 1);
EXEC test.Assert_IsEqual @TestName = N'[PEL] first row is earliest (50 shots)', @Expected = N'50', @Actual = @FirstShots;
-- resolved OperationTemplate code populated
DECLARE @AnyNullCode INT = (SELECT COUNT(*) FROM @R WHERE OperationTemplateCode IS NULL);
DECLARE @AnyNullCodeStr NVARCHAR(10) = CAST(@AnyNullCode AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PEL] OperationTemplateCode resolved', @Expected = N'0', @Actual = @AnyNullCodeStr;
GO

-- Test 2: empty LOT -> 0 rows, no error
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @EmptyLot BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1;
SELECT @EmptyLot = NewId FROM #C2; DROP TABLE #C2;
DECLARE @E TABLE (Id BIGINT, LotId BIGINT, OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50),
    OperationTemplateName NVARCHAR(100), WorkOrderOperationId BIGINT, EventAt DATETIME2(3),
    ShotCount INT, ScrapCount INT, ScrapSourceId BIGINT, WeightValue DECIMAL(12,4), WeightUomId BIGINT,
    WeightUomCode NVARCHAR(50), AppUserId BIGINT, ByUser NVARCHAR(200), TerminalLocationId BIGINT, Remarks NVARCHAR(500));
INSERT INTO @E EXEC Workorder.ProductionEvent_ListByLot @LotId = @EmptyLot;
DECLARE @ECnt INT = (SELECT COUNT(*) FROM @E); DECLARE @ECntStr NVARCHAR(10) = CAST(@ECnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[PEL] empty LOT returns 0 rows', @Expected = N'0', @Actual = @ECntStr;
GO

-- ---- teardown ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN
    (SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to verify FAIL** (proc missing). Expected: error "Could not find stored procedure 'Workorder.ProductionEvent_ListByLot'".

- [ ] **Step 3: Write the read proc** `R__Workorder_ProductionEvent_ListByLot.sql`. Single result set, no status row, no OUTPUT (FDS-11-011). **`ByUser` must use the same `Location.AppUser` display column the audit-display procs use** — check `R__*` audit reader procs / `Location.AppUser` columns and use `DisplayName` if present, else the established initials/name expression (do NOT invent one). **EventAt returned raw UTC** (matches `ProductionEvent_Record` storage; the FE formats). [If a later decision wants ET, add `CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))` per OI-36 — flag, don't silently choose.]

```sql
-- ============================================================
-- Repeatable:  R__Workorder_ProductionEvent_ListByLot.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 3 delta (PE-1a). Header-only checkpoint list for one
--              LOT, chronological. Feeds the FE cumulative-cavity card + last-shot
--              hint. Read proc: single result set, no status row, no OUTPUT params
--              (FDS-11-011). Empty result = LOT has no checkpoints. EventAt is raw
--              UTC (FE formats); resolved-name joins for display.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.ProductionEvent_ListByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pe.Id, pe.LotId, pe.OperationTemplateId,
        ot.Code AS OperationTemplateCode,
        ot.Name AS OperationTemplateName,
        pe.WorkOrderOperationId, pe.EventAt,
        pe.ShotCount, pe.ScrapCount, pe.ScrapSourceId,
        pe.WeightValue, pe.WeightUomId,
        u.Code AS WeightUomCode,
        pe.AppUserId,
        au.DisplayName AS ByUser,        -- VERIFY column name against Location.AppUser before applying
        pe.TerminalLocationId, pe.Remarks
    FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    LEFT  JOIN Parts.Uom u             ON u.Id  = pe.WeightUomId
    LEFT  JOIN Location.AppUser au     ON au.Id = pe.AppUserId
    WHERE pe.LotId = @LotId
    ORDER BY pe.EventAt ASC, pe.Id ASC;
END;
GO
```

- [ ] **Step 4: Verify the `Location.AppUser` display column** before applying.
Run: `sqlcmd -S localhost -d MPP_MES_Dev -E -b -Q "SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('Location.AppUser') AND name IN ('DisplayName','FullName','Initials','Name')"`
If `DisplayName` is absent, replace `au.DisplayName AS ByUser` with whatever the audit-display procs use (grep an existing audit reader for `AppUser` join). Apply the proc.

- [ ] **Step 5: Apply + run the test file — verify PASS.** Expected: `[PEL]` assertions PASS.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_ProductionEvent_ListByLot.sql sql/tests/0023_PlantFloor_DieCast_Deltas/020_ProductionEvent_ListByLot.sql
git commit -m "feat(sql): Workorder.ProductionEvent_ListByLot read proc (Phase 3 delta, PE-1a)"
```

## Task A4: `Lots.Lot_Create` — `@LotName` (D4) + `@CavityNote` (D2)

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql`
- Test: `sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql`

> **Backward-compat is the prime directive:** every existing caller/test passes the new params as NULL (default) and behaves byte-for-byte as today. The `0021`/`0022` LOT tests SHALL pass **unmodified**.

- [ ] **Step 1: Write the test file** `030_*` covering: `@LotName` NULL mints + advances `IdentifierSequence 'Lot'` by 1 (the critical regression guard); `@LotName` supplied stores the name + does NOT advance the sequence; duplicate `@LotName` → Status=0 clean message + no row; blank `@LotName` → Status=0; D2 manual cavity (active tool, `@ToolCavityId` NULL + `@CavityNote='C3'`) → Status=1, `Lot.ToolCavityId` NULL + `Lot.CavityNumber='C3'` + `Lot.ToolId` set; D2 reject (active tool, both NULL) → Status=0; D2 validated path unchanged (active tool + valid cavity → Status=1, `CavityNumber` NULL). Use the same fixture idiom as `020_*`. For the die-cast-branch tests, find a Cell WITH an active `ToolAssignment` (invert the `NOT EXISTS` fixture query) and resolve its Tool + an Active `ToolCavity`.

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql';
GO
-- ---- teardown (FK-safe; both MESL% mints and explicit TEST-LTT% names) ----
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%';
GO

-- Test 1 (REGRESSION): @LotName NULL mints + advances the 'Lot' sequence by 1
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Minted NVARCHAR(50);
CREATE TABLE #C1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C1 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1;
SELECT @Minted = MintedLotName FROM #C1; DROP TABLE #C1;
DECLARE @SeqAfter BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Delta NVARCHAR(10) = CAST(@SeqAfter - @SeqBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] NULL LotName advances sequence by 1', @Expected = N'1', @Actual = @Delta;
DECLARE @MintedNonEmpty NVARCHAR(10) = CASE WHEN @Minted IS NOT NULL AND LEN(@Minted) > 0 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LC] NULL LotName returns a minted name', @Expected = N'1', @Actual = @MintedNonEmpty;
GO

-- Test 2: @LotName supplied -> stored + sequence NOT advanced
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Minted NVARCHAR(50); DECLARE @S BIT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1, @LotName=N'TEST-LTT-0001';
SELECT @S = Status, @Minted = MintedLotName FROM #C2; DROP TABLE #C2;
DECLARE @SeqAfter BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DECLARE @Delta NVARCHAR(10) = CAST(@SeqAfter - @SeqBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] supplied LotName does NOT advance sequence', @Expected = N'0', @Actual = @Delta;
EXEC test.Assert_IsEqual @TestName = N'[LC] supplied LotName echoed in MintedLotName', @Expected = N'TEST-LTT-0001', @Actual = @Minted;
DECLARE @Exists NVARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = N'TEST-LTT-0001') THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[LC] supplied LotName stored', @Expected = N'1', @Actual = @Exists;
GO

-- Test 3: duplicate @LotName -> Status=0, clean message, no second row
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @S BIT;
CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1, @LotName=N'TEST-LTT-0001';
SELECT @S = Status FROM #C3; DROP TABLE #C3;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] duplicate LotName rejected', @Expected = N'0', @Actual = @SStr;
DECLARE @Cnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Lots.Lot WHERE LotName = N'TEST-LTT-0001') AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] duplicate LotName: still one row', @Expected = N'1', @Actual = @Cnt;
GO

-- Test 4: blank @LotName -> Status=0
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @S BIT;
CREATE TABLE #C4 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C4 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=5, @AppUserId=1, @LotName=N'   ';
SELECT @S = Status FROM #C4; DROP TABLE #C4;
DECLARE @SStr NVARCHAR(10) = CAST(@S AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[LC] blank LotName rejected', @Expected = N'0', @Actual = @SStr;
GO

-- Test 5/6/7: D2 manual-cavity paths on a die-cast Cell (active ToolAssignment)
DECLARE @DcCell BIGINT, @ToolId BIGINT, @CavId BIGINT, @ItemId BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT TOP 1 @DcCell = ta.CellLocationId, @ToolId = ta.ToolId
FROM Tools.ToolAssignment ta WHERE ta.ReleasedAt IS NULL ORDER BY ta.CellLocationId;
SELECT TOP 1 @CavId = tc.Id FROM Tools.ToolCavity tc
    INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.ToolId = @ToolId AND sc.Code = N'Active' ORDER BY tc.Id;
SELECT TOP 1 @ItemId = eil.ItemId FROM Parts.v_EffectiveItemLocation eil WHERE eil.LocationId = @DcCell ORDER BY eil.ItemId;
-- (If the dev DB has no active ToolAssignment+Cavity+eligible Item, the smoke seed / a fixture must establish one;
--  these three tests assert only when @DcCell/@ToolId/@CavId/@ItemId resolved.)

-- Test 5: manual cavity (ToolCavityId NULL + CavityNote) -> Status=1, CavityNumber stored, ToolCavityId NULL
IF @DcCell IS NOT NULL AND @ToolId IS NOT NULL AND @ItemId IS NOT NULL
BEGIN
    DECLARE @S5 BIT, @New5 BIGINT;
    CREATE TABLE #C5 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
    INSERT INTO #C5 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@DcCell,
        @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=NULL, @CavityNote=N'C3';
    SELECT @S5 = Status, @New5 = NewId FROM #C5; DROP TABLE #C5;
    DECLARE @S5Str NVARCHAR(10) = CAST(@S5 AS NVARCHAR(10));
    EXEC test.Assert_IsEqual @TestName = N'[LC][D2] manual cavity accepted', @Expected = N'1', @Actual = @S5Str;
    DECLARE @CavNum NVARCHAR(50) = (SELECT CavityNumber FROM Lots.Lot WHERE Id = @New5);
    EXEC test.Assert_IsEqual @TestName = N'[LC][D2] CavityNumber stored', @Expected = N'C3', @Actual = @CavNum;
    DECLARE @TcNull NVARCHAR(10) = CASE WHEN (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @New5) IS NULL THEN N'1' ELSE N'0' END;
    EXEC test.Assert_IsEqual @TestName = N'[LC][D2] ToolCavityId NULL on manual path', @Expected = N'1', @Actual = @TcNull;
END
GO

-- Test 6: D2 reject (active tool, ToolCavityId NULL + CavityNote NULL) -> Status=0
DECLARE @DcCell BIGINT, @ToolId BIGINT, @ItemId BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT TOP 1 @DcCell = ta.CellLocationId, @ToolId = ta.ToolId FROM Tools.ToolAssignment ta WHERE ta.ReleasedAt IS NULL ORDER BY ta.CellLocationId;
SELECT TOP 1 @ItemId = eil.ItemId FROM Parts.v_EffectiveItemLocation eil WHERE eil.LocationId = @DcCell ORDER BY eil.ItemId;
IF @DcCell IS NOT NULL AND @ToolId IS NOT NULL AND @ItemId IS NOT NULL
BEGIN
    DECLARE @S6 BIT;
    CREATE TABLE #C6 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
    INSERT INTO #C6 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@DcCell,
        @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=NULL, @CavityNote=NULL;
    SELECT @S6 = Status FROM #C6; DROP TABLE #C6;
    DECLARE @S6Str NVARCHAR(10) = CAST(@S6 AS NVARCHAR(10));
    EXEC test.Assert_IsEqual @TestName = N'[LC][D2] no cavity + no note rejected', @Expected = N'0', @Actual = @S6Str;
END
GO

-- Test 7: D2 validated path unchanged (active tool + valid cavity) -> Status=1, CavityNumber NULL
DECLARE @DcCell BIGINT, @ToolId BIGINT, @CavId BIGINT, @ItemId BIGINT;
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
SELECT TOP 1 @DcCell = ta.CellLocationId, @ToolId = ta.ToolId FROM Tools.ToolAssignment ta WHERE ta.ReleasedAt IS NULL ORDER BY ta.CellLocationId;
SELECT TOP 1 @CavId = tc.Id FROM Tools.ToolCavity tc INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = tc.StatusCodeId
    WHERE tc.ToolId = @ToolId AND sc.Code = N'Active' ORDER BY tc.Id;
SELECT TOP 1 @ItemId = eil.ItemId FROM Parts.v_EffectiveItemLocation eil WHERE eil.LocationId = @DcCell ORDER BY eil.ItemId;
IF @DcCell IS NOT NULL AND @ToolId IS NOT NULL AND @CavId IS NOT NULL AND @ItemId IS NOT NULL
BEGIN
    DECLARE @S7 BIT, @New7 BIGINT;
    CREATE TABLE #C7 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
    INSERT INTO #C7 EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginMfg, @CurrentLocationId=@DcCell,
        @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=@CavId;
    SELECT @S7 = Status, @New7 = NewId FROM #C7; DROP TABLE #C7;
    DECLARE @S7Str NVARCHAR(10) = CAST(@S7 AS NVARCHAR(10));
    EXEC test.Assert_IsEqual @TestName = N'[LC][D2] validated cavity path still works', @Expected = N'1', @Actual = @S7Str;
    DECLARE @CavNull NVARCHAR(10) = CASE WHEN (SELECT CavityNumber FROM Lots.Lot WHERE Id = @New7) IS NULL THEN N'1' ELSE N'0' END;
    EXEC test.Assert_IsEqual @TestName = N'[LC][D2] validated path leaves CavityNumber NULL', @Expected = N'1', @Actual = @CavNull;
END
GO

-- ---- teardown ----
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'TEST-LTT%';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to verify FAIL** (proc rejects unknown params `@LotName`/`@CavityNote`). Expected: error on the supplied-param EXECs.

- [ ] **Step 3: Edit `R__Lots_Lot_Create.sql`.** Make these precise edits:

  **(a) Signature** — append after `@TerminalLocationId BIGINT = NULL`:
  ```sql
      @TerminalLocationId BIGINT        = NULL,
      @LotName            NVARCHAR(50)  = NULL,   -- D4: caller-supplied identity; NULL = mint server-side
      @CavityNote         NVARCHAR(50)  = NULL    -- D2: free-text cavity when no active ToolCavity; stored in legacy Lot.CavityNumber
  ```

  **(b) D4 validation** — BEFORE `BEGIN TRANSACTION` (after the existing FK/eligibility validations, before the die-cast block or alongside it — anywhere pre-transaction). Add:
  ```sql
      -- ---- D4: @LotName (caller-supplied identity) validation ----
      IF @LotName IS NOT NULL
      BEGIN
          SET @LotName = LTRIM(RTRIM(@LotName));
          IF @LotName = N''
          BEGIN
              SET @Message = N'LotName cannot be blank.';
              EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
                  @LogEventTypeCode=N'LotCreated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
              SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName; RETURN;
          END
          IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @LotName)
          BEGIN
              SET @Message = N'LOT name ''' + @LotName + N''' already exists.';
              EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
                  @LogEventTypeCode=N'LotCreated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
              SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName; RETURN;
          END
      END
  ```

  **(c) D2 die-cast branch** — replace the existing `IF @ToolId IS NULL OR @ToolCavityId IS NULL` block (lines ~194-204) so that a NULL `@ToolCavityId` is allowed when `@CavityNote` is supplied, and the cavity-FK checks are skipped on that path:
  ```sql
      IF @CellHasActiveTool = 1
      BEGIN
          -- Tool is always required for a die-cast LOT.
          IF @ToolId IS NULL
          BEGIN
              SET @Message = N'Die-cast-origin LOT requires Tool (FDS-05-034).';
              EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
                  @LogEventTypeCode=N'LotCreated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
              SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName; RETURN;
          END
          -- Tool must be mounted on this Cell (unchanged).
          IF NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment WHERE ToolId=@ToolId AND CellLocationId=@CurrentLocationId AND ReleasedAt IS NULL)
          BEGIN
              SET @Message = N'Tool is not mounted on the specified Cell.';
              EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
                  @LogEventTypeCode=N'LotCreated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
              SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName; RETURN;
          END
          IF @ToolCavityId IS NULL
          BEGIN
              -- D2 manual-cavity path: require a free-text note; skip the cavity-FK checks.
              IF @CavityNote IS NULL OR LTRIM(RTRIM(@CavityNote)) = N''
              BEGIN
                  SET @Message = N'Die-cast-origin LOT requires a Cavity (select a configured cavity or enter one manually) (FDS-05-034).';
                  EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
                      @LogEventTypeCode=N'LotCreated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
                  SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName; RETURN;
              END
          END
          ELSE
          BEGIN
              -- Validated path (unchanged): cavity must belong to the tool + be Active.
              IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity WHERE Id=@ToolCavityId AND ToolId=@ToolId)
              BEGIN
                  SET @Message = N'Cavity does not belong to the specified Tool.';
                  EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
                      @LogEventTypeCode=N'LotCreated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
                  SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName; RETURN;
              END
              IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity tc INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id=tc.StatusCodeId
                             WHERE tc.Id=@ToolCavityId AND sc.Code=N'Active')
              BEGIN
                  SET @Message = N'Cavity is not in Active status.';
                  EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'Lot', @EntityId=NULL,
                      @LogEventTypeCode=N'LotCreated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
                  SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName; RETURN;
              END
          END
      END
  ```

  **(d) Mint branch** — inside the transaction, gate the inline mint on the NULL path; on the supplied path set `@MintedLotName = @LotName` and skip the sequence read/update entirely:
  ```sql
      -- Mint the LotName INSIDE the tran (NULL path) OR use the caller-supplied name (D4).
      IF @LotName IS NOT NULL
      BEGIN
          SET @MintedLotName = @LotName;   -- D4: pre-printed LTT carries its own identity; do NOT burn the 'Lot' counter.
      END
      ELSE
      BEGIN
          -- [existing inline mint block: SELECT ... IdentifierSequence WITH (ROWLOCK,UPDLOCK,HOLDLOCK) ... UPDATE ... set @MintedLotName]
      END
  ```

  **(e) Manual-cavity value into the INSERT** — precompute a local (no inline CASE in VALUES, per SP template) just before the `INSERT INTO Lots.Lot`:
  ```sql
      DECLARE @CavityNumberToStore NVARCHAR(50) =
          CAST(CASE WHEN @ToolCavityId IS NULL THEN @CavityNote ELSE NULL END AS NVARCHAR(50));
  ```
  Add `CavityNumber` to the INSERT column list and `@CavityNumberToStore` to the VALUES list.

  **(f) Audit prose** — extend `@ToolSuffix` so a manual cavity is named:
  ```sql
      DECLARE @ToolSuffix NVARCHAR(200) =
          CASE WHEN @ToolId IS NOT NULL
               THEN N'; Tool ' + ISNULL(@ToolCode, N'?') + N', Cavity '
                    + ISNULL(@CavityNum, ISNULL(@CavityNote + N' (manual)', N'?'))
               ELSE N'' END;
  ```

- [ ] **Step 4: Byte-scan the proc for non-ASCII** (the prose strings are ASCII; verify).
Run: `python -c "b=open(r'sql/migrations/repeatable/R__Lots_Lot_Create.sql','rb').read(); print('NON-ASCII:', [(i,hex(c)) for i,c in enumerate(b) if c>127][:10] or 'none')"`
Expected: `NON-ASCII: none`

- [ ] **Step 5: Apply the proc + run `030_*` — verify PASS.** Then **run the full suite** and confirm the `0021`/`0022` LOT tests pass **unmodified** (the backward-compat proof).
Expected: `[LC]` assertions PASS; suite green.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql
git commit -m "feat(sql): Lot_Create @LotName (D4) + @CavityNote (D2) additive params (Phase 3 delta)"
```

## Task A5: `RejectEvent_Record` — in-transaction concurrency guard (TOCTOU fix)

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_RejectEvent_Record.sql`
- Test: `sql/tests/0023_PlantFloor_DieCast_Deltas/040_RejectEvent_concurrency_guard.sql`

> Scope note: this is a correctness fix beyond the deltas spec's literal scope (the spec lists `RejectEvent_Record` as "shipped, unchanged"). It is included because the project-status addendum names the reject TOCTOU as a finding to fold in, and negative piece counts are unacceptable in a Honda-traceability system. The change is a defensive in-transaction guard only — it does not alter the happy path.

- [ ] **Step 1: Write the test.** A true concurrent race isn't deterministically reproducible in a single-session test, so assert the **guard invariant** directly: after the UPDLOCK decrement, `PieceCount` is never negative, and a guard-triggering path returns Status=0. The deterministic proxy: confirm the proc still rejects an over-quantity reject (existing behavior) AND that `PieceCount` is unchanged — plus add an assertion that no LOT ever has a negative `PieceCount` after a batch of valid rejects. (The in-transaction guard is verified by code review + the invariant; document that a real race needs the gateway integration test.)

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0023_PlantFloor_DieCast_Deltas/040_RejectEvent_concurrency_guard.sql';
GO
-- teardown
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-CG';
GO
DECLARE @AreaId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, AreaLocationId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-CG', N'Concurrency guard test', @AreaId, 0, SYSUTCDATETIME());
GO

-- Build a 10-piece LOT, valid reject of 4, then assert PieceCount=6 and never negative.
DECLARE @CellId BIGINT, @ItemId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;
DECLARE @LotId BIGINT;
CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellId, @PieceCount=10, @AppUserId=1;
SELECT @LotId = NewId FROM #C; DROP TABLE #C;
DECLARE @Defect BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-CG');
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R EXEC Workorder.RejectEvent_Record @LotId=@LotId, @DefectCodeId=@Defect, @Quantity=4, @AppUserId=1;
DROP TABLE #R;
DECLARE @Pc NVARCHAR(10) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id=@LotId) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CG] valid reject 10-4=6', @Expected = N'6', @Actual = @Pc;
-- invariant: no negative piece counts anywhere
DECLARE @Neg NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Lots.Lot WHERE PieceCount < 0) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[CG] no negative PieceCount in Lots.Lot', @Expected = N'0', @Actual = @Neg;
GO
-- teardown
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-CG';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run — verify PASS on current proc** (the happy path already works; this establishes the invariant baseline before the guard is added).

- [ ] **Step 3: Add the in-transaction guard.** In `R__Workorder_RejectEvent_Record.sql`, immediately AFTER the `UPDATE l SET ... FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) WHERE l.Id = @LotId;` block (which computes `@NewPieceCount` from the locked current value), insert:
  ```sql
      -- Concurrency guard (TOCTOU): the @Quantity > @PieceCount check above read
      -- PieceCount UNLOCKED before the transaction. Re-check against the value read
      -- under UPDLOCK; a concurrent reject that slipped between gate and lock would
      -- drive PieceCount negative. RAISERROR here lands in the CATCH (the only legal
      -- ROLLBACK site under INSERT-EXEC / Msg-3915), returning a clean Status=0.
      IF @NewPieceCount < 0
          RAISERROR(N'Reject Quantity exceeds the LOT''s remaining pieces (concurrent update). Reload and retry.', 16, 1);
  ```
  Update the proc header change-log: `2026-06-16 - 1.1 - TOCTOU guard: re-check decremented PieceCount under UPDLOCK.`

- [ ] **Step 4: Apply + run `040_*` + the existing `0022/020_RejectEvent_Record.sql` — verify both PASS** (the guard must not perturb the existing reject tests).

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_RejectEvent_Record.sql sql/tests/0023_PlantFloor_DieCast_Deltas/040_RejectEvent_concurrency_guard.sql
git commit -m "fix(sql): RejectEvent_Record in-transaction guard against reject TOCTOU (negative PieceCount)"
```

## Task A6: Full suite green + Part A integration commit

- [ ] **Step 1: Run the FULL SQL suite.**
Run: `./Run-Tests.ps1`
Expected: exit 0, 0 failures. Suite total ≥ prior count + the new `0023_*` assertions (spec target ~30–40 net-new). If `Run-Tests` exits 1 with 0 failures, a fixture threw — check FK teardown order (`feedback_runtests_exit1_zero_failures`).

- [ ] **Step 2: Update `PROJECT_STATUS.md`** — add a "Phase 3 SQL deltas built" entry under Recently closed (migration `0023`, the 4 changes + the TOCTOU fix, suite count). Note the two still-open dispositions for Part B: D4 MPP confirmation (server-mint default until then) and the `ByUser`/EventAt format choices.

- [ ] **Step 3: Commit the status update.**
```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): Phase 3 SQL deltas (0023) built + tested"
```

---

# PART B — DIE CAST OPERATOR STATION (Ignition Perspective)

> Execution mode: **parallel-view-authoring + convergence** for the NEW views (per `feedback_parallel_view_authoring_convergence`); the NQ + entity-script layers are authored serially first (the views bind to them). NQs live in **Core**; views in **MPP**. **`scan.ps1` registers new NQs — no gateway restart needed** (corrected 2026-06-12; if an inherited NQ is "not found" after scan, the cause is topology — it's in a sibling, not Core — not a stale registry).

> **Pre-flight (do once, before B1):** re-read `pull.ps1` + ALL `ignition-context-pack/*` + `git log --oneline -- ignition/` (session-start checks, `feedback_ignition_session_start_checks`). Confirm `mpp/qr_code_scanner` exists in `ignition/icons/mpp/mpp.svg` (`feedback_mpp_icon_paths_verify`).

## Task B1: Core Named Queries (5 new + 1 edit), reconciled to as-built proc signatures

**Files:** the 5 new NQ folders + the `lots/Lot_Create/query.sql` edit (see File structure). Each `resource.json` clones the v2 shape from `lots/Lot_Create/resource.json`; `database: "MPP"`; mutation NQs set `attributes.type: "Query"` (NOT `UpdateQuery` — `feedback_ignition_nq_type_for_status_row_procs`); reads set `type: "Query"`. sqlType codes: `3`=BIGINT, `2`=INTEGER, `5`=DECIMAL, `7`=NVARCHAR, `6`=BIT, `8`=DateTime.

- [ ] **Step 1: `workorder/ProductionEvent_Record/query.sql`** — **reconciled** (no `@EventAt`; `@FieldValuesJson` not `@DataCollectionValuesJson`):
```sql
EXEC Workorder.ProductionEvent_Record
    @LotId                = :lotId,
    @OperationTemplateId  = :operationTemplateId,
    @ShotCount            = :shotCount,
    @ScrapCount           = :scrapCount,
    @ScrapSourceId        = :scrapSourceId,
    @WeightValue          = :weightValue,
    @WeightUomId          = :weightUomId,
    @WorkOrderOperationId = :workOrderOperationId,
    @Remarks              = :remarks,
    @FieldValuesJson      = :fieldValuesJson,
    @AppUserId            = :appUserId,
    @TerminalLocationId   = :terminalLocationId
```
`resource.json` params: `lotId`/`operationTemplateId`/`scrapSourceId`/`weightUomId`/`workOrderOperationId`/`appUserId`/`terminalLocationId` = sqlType 3; `shotCount`/`scrapCount` = 2; `weightValue` = 5; `remarks`/`fieldValuesJson` = 7. `attributes.type: "Query"`.

- [ ] **Step 2: `workorder/RejectEvent_Record/query.sql`** — matches as-built (`@Quantity`, `@ChargeToArea NVARCHAR(100)`):
```sql
EXEC Workorder.RejectEvent_Record
    @LotId              = :lotId,
    @DefectCodeId       = :defectCodeId,
    @Quantity           = :quantity,
    @ProductionEventId  = :productionEventId,
    @ChargeToArea       = :chargeToArea,
    @Remarks            = :remarks,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
```
params: `lotId`/`defectCodeId`/`productionEventId`/`appUserId`/`terminalLocationId` = 3; `quantity` = 2; `chargeToArea`/`remarks` = 7. `attributes.type: "Query"`.

- [ ] **Step 3: `workorder/ProductionEvent_ListByLot/query.sql`** (read):
```sql
EXEC Workorder.ProductionEvent_ListByLot @LotId = :lotId
```
param `lotId` = 3. `attributes.type: "Query"`.

- [ ] **Step 4: `tools/ToolCavity_ListActiveByTool/query.sql`** (read):
```sql
EXEC Tools.ToolCavity_ListActiveByTool @ToolId = :toolId
```
param `toolId` = 3. (Confirm the as-built proc's param name; the FE spec names it `@ToolId`.) `attributes.type: "Query"`.

- [ ] **Step 5: `tools/ToolAssignment_ListActiveByCell/query.sql`** (read):
```sql
EXEC Tools.ToolAssignment_ListActiveByCell @CellLocationId = :cellLocationId
```
param `cellLocationId` = 3. (Confirm the as-built proc's param name.) `attributes.type: "Query"`.

- [ ] **Step 6: Edit `lots/Lot_Create/query.sql`** — add the two D4/D2 lines (only if the entity layer forwards them; `:cavityNote` is optional — include it so the free-entry path works end-to-end):
```sql
    @LotName    = :lotName,
    @CavityNote = :cavityNote
```
Add `lotName` (sqlType 7, nullable) + `cavityNote` (sqlType 7, nullable) to `lots/Lot_Create/resource.json` params.

- [ ] **Step 7: `scan.ps1`** so the new Core NQs register (no gateway restart needed).
Run: `./scan.ps1`.

- [ ] **Step 8: Commit.**
```bash
git add ignition/projects/Core/ignition/named-query/workorder ignition/projects/Core/ignition/named-query/tools ignition/projects/Core/ignition/named-query/lots/Lot_Create
git commit -m "feat(ignition): Core NQs for die-cast checkpoint/reject/cavity + Lot_Create lotName/cavityNote (reconciled to as-built signatures)"
```

## Task B2: Core entity scripts (4 new modules + Lot.create forward)

**Files:** the 4 new `code.py` modules + the `BlueRidge/Lots/Lot/code.py` edit. Standard module shape (`03`): `_u()` unwrap at the boundary, `_currentAppUserId()` default, route every call through `BlueRidge.Common.Db.*`, no `system.db.*`, no business logic.

- [ ] **Step 1: `BlueRidge/Workorder/ProductionEvent/code.py`** — `record(data, appUserId=None, terminalLocationId=None)` building the params dict with the **reconciled** key `"fieldValuesJson"` (NOT `dataCollectionValuesJson`) via `BlueRidge.Common.Util.convertWrapperObjectToJson(d.get("dcValues") or {})`, **omitting** any `eventAt` key (proc stamps it); `scrapSourceId`/`weightUomId`/`workOrderOperationId` forwarded from `data`. `→ execMutation("workorder/ProductionEvent_Record", params)`. Plus `listByLot(lotId)` → `execList("workorder/ProductionEvent_ListByLot", {"lotId": _u(lotId)})`. (Use the FE spec §6.1 body, changing the JSON key to `fieldValuesJson` and dropping `eventAt`.)

- [ ] **Step 2: `BlueRidge/Workorder/RejectEvent/code.py`** — `record(data, appUserId=None, terminalLocationId=None)` per FE spec §6.2 (`lotId`/`defectCodeId`/`quantity`/`chargeToArea`/`productionEventId`/`remarks`) → `execMutation("workorder/RejectEvent_Record", params)`.

- [ ] **Step 3: `BlueRidge/Tools/ToolCavity/code.py`** — `getActiveForDropdown(toolId)` per FE spec §6.3 → `[{"label": "Cavity %s" % r.get("CavityNumber"), "value": r.get("Id")} for r in rows]`.

- [ ] **Step 4: `BlueRidge/Tools/ToolAssignment/code.py`** — `getActiveByCell(cellLocationId)` + binding-safe `getActiveByCellOrEmpty(cellLocationId)` (returns `{"ToolId":None,"ToolCode":"","ToolName":"","AssignmentId":None}` when none) per FE spec §6.4. (Verify the column names `ToolCode`/`ToolName` match what `ToolAssignment_ListActiveByCell` returns; adjust the shaped-empty dict to match the real columns.)

- [ ] **Step 5: Edit `BlueRidge/Lots/Lot/code.py` `create(...)`** — add `lotName=None, cavityNote=None` params; forward into the params dict as `"lotName": lotName, "cavityNote": cavityNote`. No other behavior changes. (The Die Cast view passes `lotName=None` by default — server mint, §3.1.1 — and `cavityNote` only on the free-entry path.)

- [ ] **Step 6: `scan.ps1`** (entity scripts register on scan; no restart needed for scripts).

- [ ] **Step 7: Commit.**
```bash
git add ignition/projects/Core/.../script-python/BlueRidge/Workorder ignition/projects/Core/.../script-python/BlueRidge/Tools ignition/projects/Core/.../script-python/BlueRidge/Lots/Lot
git commit -m "feat(ignition): Core entity scripts for die-cast (ProductionEvent/RejectEvent/ToolCavity/ToolAssignment) + Lot.create lotName/cavityNote forward"
```

## Task B3: MPP views (parallel authoring + convergence)

> Author the 5 views (1 page + 4 components). Each is a self-contained `view.json` with `meta.name:"root"`, pre-declared shaped custom props (`feedback_ignition_predeclare_bound_custom_props`), `editDraft` pre-seeded full shape (`feedback_ignition_bidi_nested_path_init`), event scripts under the correct domain (`events.system.onStartup`; `scope:"G"` on any `system.perspective.*` DOM-event script; bodies start with `\t`), `ia.input.numeric-entry-field` for numbers, `ia.input.dropdown` with `allowCustomOptions:true` for the cavity free-entry, `position.display` for conditional visibility, ≥44px touch targets, no drag-and-drop. Row sub-views live under `Components/PlantFloor/DieCastEntry/<Row>` (never nested under the page view).

**Layout contract (D1 — mockup `mockup/plantFloor.html` `terminal/diecast`):** root flex column → header band (title + PausedLotIndicator + Close) → context bar (ACTIVE CELL + Change + Tool-mounted summary) → two-column body flex row wrap: LEFT NEW-LOT form (`grow:1`), RIGHT ~320px rail with two stacked cards (cumulative-cavity KPIs + RejectPanel). Narrow viewport: right cards stack below the form.

- [ ] **Step 1: Author `FieldInputRow` + `PeerTallyRow`** (leaf row sub-views; no dependencies). `FieldInputRow`: `params.field` (input-only, carries `DataType`); four `position.display`-gated widgets (text / numeric-entry-field / checkbox / date) keyed off `field.DataType` (String→text, Integer/Decimal→numeric-entry-field, Boolean→checkbox, Date→date picker; NULL→text); value crosses back to parent via page-scoped message. `PeerTallyRow`: display-only (cavity #, LotName, count).

- [ ] **Step 2: Author `CheckpointPanel`** — `params.lotId` input-only; `view.custom.fields` ← `BlueRidge.Parts.OperationTemplate.getFieldsForTemplate(dieCastShotTemplateId)`; flex-repeater over `FieldInputRow`; `view.custom.dcValues` keyed by DataCollectionFieldId; Submit → `BlueRidge.Workorder.ProductionEvent.record(...)` → `Common.Ui.notifyResult`; on success broadcast `checkpointRecorded` (page scope). Cumulative-shots labels + last-shot hint via `ProductionEvent.listByLot`.

- [ ] **Step 3: Author `RejectPanel`** — `params.lotId` input-only; Defect Code dropdown (`BlueRidge.Quality.DefectCode.getForDropdown()`); Quantity (`numeric-entry-field`); optional ChargeToArea + Remarks; Add → `BlueRidge.Workorder.RejectEvent.record(...)` → `notifyResult`; close-at-zero warning copy; broadcast `rejectRecorded` (page scope).

- [ ] **Step 4: Author `DieCastEntry` page** — the layout contract above. LEFT form bidi-bound to pre-seeded `view.custom.editDraft` (scannedLtt, itemId, toolCavityId/cavityNote, pieceCount, weight, weightUomId); embeds InitialsField + CellContextSelector (popup) + PausedLotIndicator. Cavity dropdown `allowCustomOptions:true` with options from `BlueRidge.Tools.ToolCavity.getActiveForDropdown(toolId)` (free-entry when empty). Submit → `BlueRidge.Lots.Lot.create(editDraft, appUserId, terminalLocationId, lotName=None)` → notifyResult → set `view.custom.activeLotId` → mismatch warning if scannedLtt≠minted. "Create LOT from another cavity" keeps Cell/Tool/Item sticky, clears Cavity+PieceCount+LTT+Weight, bumps `peersThisSession`. RIGHT rail: cumulative-cavity card (`ProductionEvent.listByLot(activeLotId)` latest row) + embedded RejectPanel (`params.lotId = activeLotId`). Subscribe to `cellContextChanged`/`checkpointRecorded`/`rejectRecorded` (page scope) to reload context/LOT header.

- [ ] **Step 5: Converge** — `scan.ps1`; verify each view registers (gateway log: no "view not found" / unresolved-icon errors). Fix any flex-repeater ROW sub-view registration (must exist under `Components/PlantFloor/DieCastEntry/`).

- [ ] **Step 6: Commit.**
```bash
git add ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/DieCastEntry ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DieCastEntry
git commit -m "feat(ignition): Die Cast Operator Station views (no-tabs two-column, D1) + Checkpoint/Reject/row sub-views"
```

## Task B4: Routes + HomeRouter tile

**Files:** `page-config/config.json`, `HomeRouter/view.json`.

- [ ] **Step 1: Add three routes** under `/shop-floor/*` (each with a `title`), path-params not query dicts:
```jsonc
"/shop-floor/die-cast":                   { "title": "Die Cast Entry", "viewPath": "BlueRidge/Views/ShopFloor/DieCastEntry" },
"/shop-floor/die-cast/checkpoint/:lotId": { "title": "Checkpoint",     "viewPath": "BlueRidge/Views/ShopFloor/DieCastEntry" },
"/shop-floor/die-cast/reject/:lotId":     { "title": "Reject",         "viewPath": "BlueRidge/Views/ShopFloor/DieCastEntry" }
```

- [ ] **Step 2: Add a Die Cast tile/action to `HomeRouter`** navigating to `/shop-floor/die-cast`, gated by the same terminal-context model the other shop-floor pages use (Die Cast Cell context). `system.perspective.navigate` from a DOM-event script needs `scope:"G"`.

- [ ] **Step 3: `scan.ps1`; commit.**
```bash
git add ignition/projects/MPP/.../page-config/config.json ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/HomeRouter
git commit -m "feat(ignition): /shop-floor/die-cast routes + HomeRouter Die Cast tile"
```

## Task B5: Smoke seed + operator walkthrough (the FE verification gate)

**Files:** `sql/scratch/smoke_seed_phase3_diecast.sql`.

- [ ] **Step 1: Write the smoke seed** (dev aid, idempotent, FK-safe wipe of `Lots.*`/`Workorder.ProductionEvent*`/`RejectEvent` then build: an active `ToolAssignment` on a Die Cast Cell with ≥2 Active `ToolCavity` rows; two cavity-peer LOTs; one `ProductionEvent` checkpoint; one + one reject to zero a peer). `PRINT` lotIds + the three URLs. Follow FE spec §10.

- [ ] **Step 2: Run the smoke seed; open a Perspective session and walk §10 steps 1–7:** two-column layout + narrow-stack; minimal-tap create (scan→Submit) + mismatch warning; cavity-peer (sticky Cell/Tool/Item, flat genealogy); free-entry cavity (no active mount); data-driven checkpoint widgets + unchanged inventory (D2); reject + close-at-zero warning + over-quantity rejection; `notifyResult` toasts on every outcome; Edit-Tool opens ElevationModal. Fix issues in Designer/files as found.

- [ ] **Step 3: Final commit + PROJECT_STATUS update** (Phase 3 front-end built + smoked; note any deferred items — Tool re-assign auth policy, D4 disposition).
```bash
git add sql/scratch/smoke_seed_phase3_diecast.sql PROJECT_STATUS.md
git commit -m "feat(ignition): Phase 3 die-cast smoke seed + status; Phase 3 front-end complete"
```

---

## Open dispositions (carry through the build — none block it)

1. **D4 — canonical LOT id (MPP, expected 2026-06-16).** Until confirmed, ship server-mint default (`lotName=None`) + mismatch warning. "Scanned LTT IS the name" = pass `editDraft.scannedLtt` at the single `Lot.create` call site (one line).
2. **`ProductionEvent_ListByLot.EventAt` timezone** — shipped raw UTC (FE formats). If MPP wants ET, add the `AT TIME ZONE` conversion (OI-36 pattern) — flag, don't silently choose.
3. **`ByUser` display column** — match whatever the audit-display procs use on `Location.AppUser`; do not invent a new expression.
4. **Tool re-assign from the plant floor** — an auth-policy question (is the elevated operator role authorized to mutate `ToolAssignment` from the operator station vs config-tool only?). Reuse the existing `BlueRidge.Parts.Tool` procs; do not author new ones.

## Self-review checklist (run before executing)

- **Spec coverage:** Change 1 (DataType) → A1+A2; Change 2 (ProductionEvent_ListByLot) → A3; Change 3 (@LotName/@CavityNote) → A4; FE D1 layout → B3-Step4; D2 free-entry → A4 + B3; D3 cavity-peer → B3-Step4; D4 mint seam → A4 + B1/B2; D5 typed widgets → B3-Step1/Step2. TOCTOU finding → A5. EventAt/FieldValuesJson reconciliation → B1-Step1 + B2-Step1.
- **No placeholders:** every SQL step carries full bodies; FE steps name exact files + the reconciled param contracts.
- **Type consistency:** `@FieldValuesJson`/`:fieldValuesJson`/`"fieldValuesJson"` used uniformly (never `dataCollectionValuesJson`); `@LotName`/`:lotName`/`lotName` and `@CavityNote`/`:cavityNote`/`cavityNote` uniform; `ProductionEvent_ListByLot` result-shape temp tables match the proc SELECT column-for-column.
