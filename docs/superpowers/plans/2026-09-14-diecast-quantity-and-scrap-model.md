# Die Cast Quantity and Scrap Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make die-cast scrap recordable against a cavity with no basket, make the per-cavity good count operator-editable, and turn "Record Shift Output" into a reconciliation screen whose numbers are required to add up.

**Architecture:** SQL first — schema, then procs, then the reject readers — followed by the Ignition backend, then the screens in Designer. Two changes ride along as their own commits so they can be reverted alone: the Config Tool cavity-part validation (D13) and the global type-scale reduction (D12).

**Tech Stack:** SQL Server 2022 (`MPP_MES_Dev` / `MPP_MES_Test` / `MPP_MES_Prod`), Ignition 8.3.5 Perspective (file-based projects `Core` / `MPP` / `MPP_Config`), Jython 2.7, PowerShell.

**Spec:** `docs/superpowers/specs/2026-09-14-diecast-quantity-and-scrap-model-design.md`
**Mockup:** `mockup/diecast_reconcile_mock.html` (rev 7)

## Global Constraints

- **Migration number is `0084`.** `0083` is the highest on disk.
- **Repo SQL conventions** (`sql_best_practices_mes.md`): `UpperCamelCase`; `BIGINT IDENTITY` PKs; `NVARCHAR` never `VARCHAR`; `DATETIME2(3)`; `DECIMAL` never `FLOAT`; enum columns FK-backed; `DeprecatedAt` soft deletes; store UTC, convert to Eastern at every operator-facing read via `CAST(<col> AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))`.
- **Seed and migration strings are ASCII-only.** `sqlcmd` reads `.sql` in the Windows codepage; an em-dash or middle-dot becomes mojibake. Use `NCHAR(8212)` / `Audit.ufn_MidDot()` where a real character is needed.
- **FDS-11-011:** no `OUTPUT` parameters. Read procs return one result set, empty = not found. Mutation procs declare `@Status BIT`, `@Message NVARCHAR(500)`, `@NewId BIGINT` as locals and end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`.
- **A proc captured by `INSERT ... EXEC` must not `EXEC` another status-row proc and must not `ROLLBACK` inside a caller transaction.** All rejecting validations run **before** `BEGIN TRANSACTION`; `CATCH` is the only legal `ROLLBACK` site.
- **All Named Queries live in the `Core` project.** `MPP` and `MPP_Config` have zero local NQs.
- **No business logic in Python.** Domain rules live in SQL; entity scripts shape rows and nothing more.
- **Ignition file-edit boundary:** new views may be file-authored then `.\scan.ps1`. **Existing views are edited in Designer.** `DieCastBody`, `DieCastRelease` and the `MPP_Config` Tools views all exist.
- **Migration guard shape:** `IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0084_...') BEGIN PRINT '...'; RETURN; END` then `GO`, ending with a guarded `INSERT INTO dbo.SchemaVersion`.
- **Shared environment.** One Ignition gateway and one `MPP_MES_Dev` are shared across worktrees; two others were live at plan time. Never reset `MPP_MES_Dev`. Run tests against `MPP_MES_Test`.
- **Git:** commit to `jacques/working`. Stage explicit paths — never `git add -u` or `-A`. No `Co-Authored-By` trailer.
- **Build in Test, then deploy to Dev as a rehearsal for Prod.** Every task is written, run and
  proven green against `MPP_MES_Test`. Only once a task is green does its SQL go to
  `MPP_MES_Dev` — and it goes the way it will go to Prod: apply, verify, re-run to prove
  idempotency. `MPP_MES_Dev` is the dress rehearsal, not the workbench. **Never reset
  `MPP_MES_Dev`** — it holds hand-built configuration and is shared across worktrees.
- **Test command:** `.\sql\tests\Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "<substring>"`. Full suite = omit `-Filter`. Exit 1 with 0 failures means a file errored (usually cleanup FK order), not a failed assertion.

---

## File Structure

| File | Responsibility |
|---|---|
| `sql/migrations/versioned/0084_diecast_cavity_scrap_attribution.sql` | All schema change: `RejectEvent` columns + nullable `LotId` + clustered-index rebuild; `DieCastContribution` columns; `DieCastVarianceReason` table + seed; `DC-999` classification. |
| `sql/seeds/030_seed_defect_codes.sql` | `DC-999` added + classified (mirror of the migration, for a fresh reset). |
| `sql/migrations/repeatable/R__Workorder_ufn_CavityShotWatermark.sql` | v3.0 — read `ToolCavityId` directly. |
| `sql/migrations/repeatable/R__Workorder_RejectEvent_Record.sql` | v2.0 — lot-optional, stamps identity. |
| `sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql` | v3.0 — prior scrap, die-wide net, pending flag. |
| `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql` | v3.0 — cavity-keyed lines, cavity fan-out, dispositions. |
| `sql/migrations/repeatable/R__Quality_Reject_*.sql` (6) | Read `re.ItemId` / `re.ToolId` instead of joining `Lots.Lot`. |
| `sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql` | v1.2 — D13, row-scoped part requirement. |
| `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql` | New suite for everything above. |
| `ignition/projects/Core/ignition/named-query/workorder/*` | New/changed NQs. |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py` | Entity glue. |
| `ignition/projects/MPP/.../Views/ShopFloor/DieCastBody/view.json` | Two tabs (Designer). |
| `ignition/projects/MPP/.../Components/Popups/DieCastRelease/view.json` | Good box + scrap block (Designer). |
| `tools/gen_howto_views.py` | Four die-cast How-To sources rewritten. |
| `ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css` | Type scale −15% (own commit). |

---

## Task 1: Migration 0084 — schema

**Files:**
- Create: `sql/migrations/versioned/0084_diecast_cavity_scrap_attribution.sql`
- Create: `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql`
- Modify: `sql/seeds/030_seed_defect_codes.sql`

**Interfaces:**
- Produces: `Workorder.RejectEvent.{ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId}` (all `BIGINT NULL`), `RejectEvent.LotId` now `NULL`able; `Workorder.DieCastContribution.{ToolCavityId, VarianceReasonId, VarianceNote}`; `Workorder.DieCastVarianceReason(Id, Code, Name, RequiresNote, SortOrder)`; defect code `DC-999`.

- [ ] **Step 1: Write the failing schema test**

Create `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/110_CavityScrap.sql';
GO

-- =============================================
-- CAVITY-ATTRIBUTED DIE-CAST SCRAP (migration 0084).
--
-- Die-cast scrap is a fact about (Shift, Press, Tool, Cavity, Part); the LOT is
-- optional decoration. These assertions pin the SHAPE; behaviour tests follow
-- in later tasks of the same plan.
--
-- NOTE the asymmetry these tests encode, because it is the thing most likely to
-- be "tidied" later: RejectEvent.LotId becomes NULLABLE, while
-- DieCastContribution.LotId stays NOT NULL. See spec sec 3.6 -- a basketless
-- cavity must NOT advance its shot watermark, and that constraint is what
-- stops it.
-- =============================================

DECLARE @v NVARCHAR(20);

SET @v = CAST((SELECT is_nullable FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent') AND name = N'LotId') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] RejectEvent.LotId is nullable',
    @Expected = N'1', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent')
                 AND name IN (N'ItemId', N'ToolId', N'ToolCavityId', N'ShiftId', N'CellLocationId')) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] RejectEvent gained 5 attribution columns',
    @Expected = N'5', @Actual = @v;

SET @v = CAST((SELECT is_nullable FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.DieCastContribution') AND name = N'LotId') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] DieCastContribution.LotId stays NOT NULL (spec 3.6)',
    @Expected = N'0', @Actual = @v;

-- every index on RejectEvent must remain partition-aligned, or sliding-window
-- TRUNCATE retention (B2) breaks silently at the next maintenance run
SET @v = CAST((SELECT COUNT(*) FROM sys.indexes i
               JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
               WHERE i.object_id = OBJECT_ID(N'Workorder.RejectEvent')
                 AND i.index_id > 0 AND ds.name <> N'ps_MonthlyUtc') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] every RejectEvent index still ON ps_MonthlyUtc',
    @Expected = N'0', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastVarianceReason) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] DieCastVarianceReason seeded with 5 reasons',
    @Expected = N'5', @Actual = @v;

SET @v = (SELECT CAST(RequiresNote AS NVARCHAR(20)) FROM Workorder.DieCastVarianceReason WHERE Code = N'Unknown');
EXEC test.Assert_IsEqual @TestName = N'[0084] Unknown requires a note',
    @Expected = N'1', @Actual = @v;

SET @v = (SELECT CAST(dc.IsNonRejectScrap AS NVARCHAR(20)) FROM Quality.DefectCode dc WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 Warmup is non-reject scrap',
    @Expected = N'1', @Actual = @v;

SET @v = (SELECT oc.Code FROM Quality.DefectCode dc
          JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 is categorised DieCast',
    @Expected = N'DieCast', @Actual = @v;

SET @v = (SELECT cp.Code FROM Quality.DefectCode dc
          JOIN Quality.ChargeToParty cp ON cp.Id = dc.ChargeToPartyId WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 charges to DieCast',
    @Expected = N'DieCast', @Actual = @v;

-- backfill: every pre-existing reject must now carry its LOT's part
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent re
               JOIN Lots.Lot l ON l.Id = re.LotId
               WHERE re.ItemId IS NULL OR re.ItemId <> l.ItemId) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] ItemId backfilled to match every existing LOT',
    @Expected = N'0', @Actual = @v;
GO
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "110_CavityScrap"
```

Expected: FAIL — `Invalid object name 'Workorder.DieCastVarianceReason'`, and the nullability assertions report `0` where `1` is expected.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0084_diecast_cavity_scrap_attribution.sql`:

```sql
-- ============================================================
-- Migration:   0084_diecast_cavity_scrap_attribution.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-14
-- Description: Die-cast scrap becomes a fact about (Shift, Press, Tool, Cavity,
--              Part) with the LOT optional. Spec:
--              docs/superpowers/specs/2026-09-14-diecast-quantity-and-scrap-model-design.md
--
--              1. Workorder.RejectEvent.LotId NOT NULL -> NULL, so a cavity
--                 with no basket can be scrapped at all. LotId is the leading
--                 key of a CLUSTERED index on a PARTITIONED table, so this is
--                 drop-FK / drop-index / alter / rebuild. THE REBUILD MUST
--                 STAY ON ps_MonthlyUtc(RecordedAt): every index on this table
--                 is partition-aligned and sliding-window TRUNCATE retention
--                 (B2) depends on that. Rebuilding on PRIMARY breaks partition
--                 maintenance silently.
--
--              2. RejectEvent gains ItemId / ToolId / ToolCavityId / ShiftId /
--                 CellLocationId. ItemId is stamped, not derived: two reject
--                 reports reach the part via INNER JOIN Lots.Lot, and an inner
--                 join on a NULL key DROPS THE ROW -- lot-free scrap would
--                 vanish from the Part Matrix and the Transaction Detail with
--                 no error. ToolId is denormalised for the same reason one
--                 level up: several dies make the same part number and are
--                 distinguishable only by code.
--
--              3. Workorder.DieCastContribution gains ToolCavityId +
--                 VarianceReasonId + VarianceNote. Its LotId STAYS NOT NULL --
--                 a basketless cavity must not advance its shot watermark,
--                 because those castings go into the next physical basket and
--                 crediting them there is correct (spec 3.6). Unpartitioned
--                 table, so a plain ALTER.
--
--              4. Workorder.DieCastVarianceReason, shaped like
--                 DieCastCounterAnchorReason (0074).
--
--              5. Quality.DefectCode DC-999 'Warmup'. Prod carries it and this
--                 repo never has; it is also uncategorised and counted inside
--                 the reject percentage. Added + classified here AND in seed
--                 030 (0048 / 0067 / 0075 precedent: a reset runs migrations
--                 before seeds, an in-place upgrade never re-runs seeds).
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0084_diecast_cavity_scrap_attribution')
BEGIN PRINT 'Migration 0084 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. RejectEvent: new attribution columns ----
IF COL_LENGTH('Workorder.RejectEvent', 'ItemId')         IS NULL ALTER TABLE Workorder.RejectEvent ADD ItemId         BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ToolId')         IS NULL ALTER TABLE Workorder.RejectEvent ADD ToolId         BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ToolCavityId')   IS NULL ALTER TABLE Workorder.RejectEvent ADD ToolCavityId   BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'ShiftId')        IS NULL ALTER TABLE Workorder.RejectEvent ADD ShiftId        BIGINT NULL;
GO
IF COL_LENGTH('Workorder.RejectEvent', 'CellLocationId') IS NULL ALTER TABLE Workorder.RejectEvent ADD CellLocationId BIGINT NULL;
GO

-- ---- 2. Backfill ItemId from the LOT before anything can be written NULL ----
UPDATE re SET re.ItemId = l.ItemId
FROM Workorder.RejectEvent re
INNER JOIN Lots.Lot l ON l.Id = re.LotId
WHERE re.ItemId IS NULL;
GO

-- ---- 3. RejectEvent.LotId -> NULLable ----
-- LotId is the leading key of CIX_RejectEvent_LotRecordedAt (CLUSTERED, on
-- ps_MonthlyUtc). SQL Server will not ALTER COLUMN an indexed column's
-- nullability in place, so: drop FK, drop index, alter, rebuild ALIGNED, re-add.
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Lot')
    ALTER TABLE Workorder.RejectEvent DROP CONSTRAINT FK_RejectEvent_Lot;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'CIX_RejectEvent_LotRecordedAt'
             AND object_id = OBJECT_ID(N'Workorder.RejectEvent'))
    DROP INDEX CIX_RejectEvent_LotRecordedAt ON Workorder.RejectEvent;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent')
             AND name = N'LotId' AND is_nullable = 0)
    ALTER TABLE Workorder.RejectEvent ALTER COLUMN LotId BIGINT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'CIX_RejectEvent_LotRecordedAt'
                 AND object_id = OBJECT_ID(N'Workorder.RejectEvent'))
    CREATE CLUSTERED INDEX CIX_RejectEvent_LotRecordedAt
        ON Workorder.RejectEvent (LotId, RecordedAt)
        ON ps_MonthlyUtc(RecordedAt);   -- ALIGNED. Do not change to PRIMARY.
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Lot')
    ALTER TABLE Workorder.RejectEvent
        ADD CONSTRAINT FK_RejectEvent_Lot FOREIGN KEY (LotId) REFERENCES Lots.Lot(Id);
GO

-- ---- 4. RejectEvent FKs + the cavity-keyed read path (B8 filtered index) ----
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Item')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_Item
        FOREIGN KEY (ItemId) REFERENCES Parts.Item(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Tool')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_Tool
        FOREIGN KEY (ToolId) REFERENCES Tools.Tool(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_ToolCavity')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_ToolCavity
        FOREIGN KEY (ToolCavityId) REFERENCES Tools.ToolCavity(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_Shift')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_Shift
        FOREIGN KEY (ShiftId) REFERENCES Oee.Shift(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_RejectEvent_CellLocation')
    ALTER TABLE Workorder.RejectEvent ADD CONSTRAINT FK_RejectEvent_CellLocation
        FOREIGN KEY (CellLocationId) REFERENCES Location.Location(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_RejectEvent_ShiftCavity'
                 AND object_id = OBJECT_ID(N'Workorder.RejectEvent'))
    CREATE INDEX IX_RejectEvent_ShiftCavity
        ON Workorder.RejectEvent (ShiftId, ToolCavityId, RecordedAt)
        WHERE ShiftId IS NOT NULL
        ON ps_MonthlyUtc(RecordedAt);
GO

-- ---- 5. DieCastVarianceReason ----
IF OBJECT_ID(N'Workorder.DieCastVarianceReason', N'U') IS NULL
    CREATE TABLE Workorder.DieCastVarianceReason (
        Id           BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
        Code         NVARCHAR(50)  NOT NULL,
        Name         NVARCHAR(100) NOT NULL,
        RequiresNote BIT           NOT NULL CONSTRAINT DF_DCVR_RequiresNote DEFAULT 0,
        SortOrder    INT           NOT NULL CONSTRAINT DF_DCVR_SortOrder DEFAULT 0,
        CONSTRAINT UQ_DieCastVarianceReason_Code UNIQUE (Code)
    );
GO
MERGE Workorder.DieCastVarianceReason AS t
USING (VALUES
    (N'MiscountedBasket',     N'Basket count corrected',          0, 1),
    (N'CounterSuspect',       N'Press counter reading suspect',   0, 2),
    (N'ScrapNotRecorded',     N'Scrap produced but not recorded', 0, 3),
    (N'PartsRemovedFromLine', N'Parts removed from the line',     1, 4),
    (N'Unknown',              N'Unknown',                         1, 5)
) AS s (Code, Name, RequiresNote, SortOrder)
ON t.Code = s.Code
WHEN MATCHED THEN UPDATE SET t.Name = s.Name, t.RequiresNote = s.RequiresNote, t.SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (Code, Name, RequiresNote, SortOrder)
                      VALUES (s.Code, s.Name, s.RequiresNote, s.SortOrder);
GO

-- ---- 6. DieCastContribution: stamped cavity + disposition ----
-- LotId deliberately UNCHANGED (NOT NULL) -- spec 3.6.
IF COL_LENGTH('Workorder.DieCastContribution', 'ToolCavityId') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD ToolCavityId BIGINT NULL;
GO
IF COL_LENGTH('Workorder.DieCastContribution', 'VarianceReasonId') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD VarianceReasonId BIGINT NULL;
GO
IF COL_LENGTH('Workorder.DieCastContribution', 'VarianceNote') IS NULL
    ALTER TABLE Workorder.DieCastContribution ADD VarianceNote NVARCHAR(500) NULL;
GO
UPDATE c SET c.ToolCavityId = l.ToolCavityId
FROM Workorder.DieCastContribution c
INNER JOIN Lots.Lot l ON l.Id = c.LotId
WHERE c.ToolCavityId IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_DieCastContribution_ToolCavity')
    ALTER TABLE Workorder.DieCastContribution ADD CONSTRAINT FK_DieCastContribution_ToolCavity
        FOREIGN KEY (ToolCavityId) REFERENCES Tools.ToolCavity(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_DieCastContribution_VarianceReason')
    ALTER TABLE Workorder.DieCastContribution ADD CONSTRAINT FK_DieCastContribution_VarianceReason
        FOREIGN KEY (VarianceReasonId) REFERENCES Workorder.DieCastVarianceReason(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DieCastContribution_Cavity'
                 AND object_id = OBJECT_ID(N'Workorder.DieCastContribution'))
    CREATE INDEX IX_DieCastContribution_Cavity
        ON Workorder.DieCastContribution (ToolCavityId, ShiftId);
GO

-- ---- 7. DC-999 Warmup ----
DECLARE @ocDieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @cpDieCast BIGINT = (SELECT Id FROM Quality.ChargeToParty    WHERE Code = N'DieCast');

IF NOT EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = N'DC-999')
    INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused)
    VALUES (N'DC-999', N'Warmup', @ocDieCast, 0);

UPDATE Quality.DefectCode
   SET OperationCategoryId = @ocDieCast,
       ChargeToPartyId     = @cpDieCast,
       IsNonRejectScrap    = 1
 WHERE Code = N'DC-999';
GO

-- ---- 8. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0084_diecast_cavity_scrap_attribution')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0084_diecast_cavity_scrap_attribution',
            N'Die-cast scrap attributed to (Shift, Press, Tool, Cavity, Part): RejectEvent.LotId nullable (clustered index rebuilt aligned) plus ItemId/ToolId/ToolCavityId/ShiftId/CellLocationId; DieCastContribution gains ToolCavityId + variance disposition (LotId stays NOT NULL per spec 3.6); Workorder.DieCastVarianceReason seeded; DC-999 Warmup added, categorised DieCast, charged to DieCast, flagged non-reject scrap.');
GO
PRINT 'Migration 0084 (diecast_cavity_scrap_attribution) applied.';
GO
```

- [ ] **Step 4: Mirror `DC-999` into the seed**

In `sql/seeds/030_seed_defect_codes.sql`, add to the `@Defects` `VALUES` list (after the `260` row):

```sql
(N'DC-999', N'Warmup', @DieCast, 0)
```

Then inside the existing `IF COL_LENGTH(N'Quality.DefectCode', N'ChargeToPartyId') IS NOT NULL` block, after the three process-family updates, add:

```sql
    -- DC-999 Warmup: process necessity, not a defect. Counted for material and
    -- yield, excluded from the reject percentage, charged to Die Cast so it
    -- stays visible as a departmental cost rather than sitting in Unassigned.
    UPDATE Quality.DefectCode SET IsNonRejectScrap = 1
    WHERE Code = N'DC-999' AND IsNonRejectScrap = 0;
```

- [ ] **Step 5: Apply to `MPP_MES_Test` and run the test**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "110_CavityScrap"
```

Expected: PASS, 10 assertions.

- [ ] **Step 6: Run the FULL suite as the regression gate**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

Expected: exit 0, zero failures. Nothing here changes behaviour, so any failure is this migration.

- [ ] **Step 7: Apply to Dev (never reset it) and verify alignment**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/migrations/versioned/0084_diecast_cavity_scrap_attribution.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -W -s"|" -Q "SELECT i.name, ds.name FROM sys.indexes i JOIN sys.data_spaces ds ON ds.data_space_id=i.data_space_id WHERE i.object_id=OBJECT_ID('Workorder.RejectEvent') AND i.index_id>0"
```

Expected: every row's second column reads `ps_MonthlyUtc`. **If any reads `PRIMARY`, stop** — partition maintenance is broken and the index must be dropped and recreated with the `ON ps_MonthlyUtc(RecordedAt)` clause.

- [ ] **Step 8: Re-run the migration to prove idempotency**

Run the same `sqlcmd` line again. Expected: `Migration 0084 already applied -- skipping.` and nothing else.

- [ ] **Step 9: Commit**

```bash
git add sql/migrations/versioned/0084_diecast_cavity_scrap_attribution.sql sql/seeds/030_seed_defect_codes.sql sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql
git commit -m "feat(diecast): 0084 -- cavity-attributed scrap schema + DC-999 Warmup"
```

---

## Task 2: `ufn_CavityShotWatermark` v3.0

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_ufn_CavityShotWatermark.sql`
- Modify: `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql`

**Interfaces:**
- Consumes: `DieCastContribution.ToolCavityId` (Task 1).
- Produces: `Workorder.ufn_CavityShotWatermark(@ToolCavityId BIGINT, @ShiftId BIGINT, @CellLocationId BIGINT) RETURNS INT` — signature unchanged.

- [ ] **Step 1: Write the failing neutrality + gap tests**

Append to `110_CavityScrap.sql`. **Test 1 is the important one**: without it the whole die-cast suite could pass for a new reason.

```sql
-- ---- fixtures: one tool, one cavity, one shift, two baskets with a gap ----
DECLARE @Usr BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @ToolId BIGINT, @CavId BIGINT, @ShiftId BIGINT, @ItemId BIGINT, @CellId BIGINT;

SELECT TOP 1 @CellId = Id FROM Location.Location l
  JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
  WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id;
SELECT TOP 1 @ItemId = Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id;
SELECT TOP 1 @ShiftId = Id FROM Oee.Shift ORDER BY Id DESC;

INSERT INTO Tools.Tool (Code, Name, ToolTypeId, StatusCodeId, CreatedByUserId)
SELECT N'CS-DIE', N'Cavity scrap test die',
       (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id),
       (SELECT TOP 1 Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), @Usr;
SET @ToolId = SCOPE_IDENTITY();

INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedByUserId)
SELECT @ToolId, N'a', (SELECT TOP 1 Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active'),
       N'CS cavity a', @ItemId, @Usr;
SET @CavId = SCOPE_IDENTITY();
GO
```

```sql
-- Test 1 -- NEUTRALITY. No basketless rows exist, so v3.0 must agree with v2.0
-- on every existing fixture. Asserted against the recorded MAX directly.
DECLARE @CavId BIGINT = (SELECT Id FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId
                         WHERE t.Code = N'CS-DIE' AND tc.CavityCode = N'a');
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift ORDER BY Id DESC);
DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
  JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
  WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @v NVARCHAR(20);

SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavId, @ShiftId, @CellId) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Watermark] no contributions -> 0',
    @Expected = N'0', @Actual = @v;
GO
```

Full fixture chain (open a basket, contribute at reading 1900, release it, run a gap, open a second
basket, contribute at 3000) plus these assertions:

```sql
-- Test 2 -- THE RULE JACQUES CORRECTED (spec 3.6). After a basket is released
-- at reading 1900 and 116 shots run with NO basket, the NEXT basket must be
-- credited THROUGH the gap -- because the castings are physically in it.
-- A timing gap must not cost the operator production.
EXEC test.Assert_IsEqual @TestName = N'[Watermark] gap shots credit to the next basket',
    @Expected = N'1100', @Actual = @creditedToSecondBasket;

-- Test 3 -- a basketless cavity writes NO contribution row.
EXEC test.Assert_IsEqual @TestName = N'[Watermark] basketless cavity writes no contribution',
    @Expected = N'0', @Actual = @contributionsWithoutLot;
```

- [ ] **Step 2: Run and confirm the new tests fail**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "110_CavityScrap"
```

Expected: tests 2 and 3 FAIL (the fixture chain does not exist yet); test 1 passes.

- [ ] **Step 3: Change the function to read the cavity directly**

In `R__Workorder_ufn_CavityShotWatermark.sql`, bump the header to **v3.0** with the reason, then replace the contribution lookup:

```sql
    -- v3.0: read the stamped cavity instead of traversing the LOT. Behaviour-
    -- identical -- every contribution row still has a LOT (spec 3.6) -- so this
    -- is a simplification, asserted neutral by test 1.
    SELECT @Watermark = MAX(c.ShotCounterReading)
    FROM Workorder.DieCastContribution c
    WHERE c.ToolCavityId = @ToolCavityId
      AND (@ShiftId IS NULL OR c.ShiftId = @ShiftId)
      AND (@CellLocationId IS NULL OR c.CellLocationId = @CellLocationId);
```

- [ ] **Step 4: Run the die-cast suite**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "0022_PlantFloor_DieCast"
```

Expected: PASS, including `080_ShotReadingChain`, `090_ReleasePreview` and `100_CounterAnchor` unchanged.

- [ ] **Step 5: Run the FULL suite**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

Expected: exit 0, zero failures.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_ufn_CavityShotWatermark.sql sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql
git commit -m "refactor(diecast): ufn_CavityShotWatermark v3.0 reads the stamped cavity"
```

---

## Task 3: `RejectEvent_Record` v2.0 — lot-optional

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_RejectEvent_Record.sql`
- Modify: `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql`

**Interfaces:**
- Produces: `Workorder.RejectEvent_Record` with `@LotId BIGINT = NULL` and new `@ItemId`, `@ToolId`, `@ToolCavityId`, `@ShiftId`, `@CellLocationId` (all `BIGINT = NULL`). Status row unchanged.

- [ ] **Step 1: Write the failing behaviour tests**

Append to `110_CavityScrap.sql`, capturing the status row per the INSERT-EXEC pattern:

```sql
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- lot-free scrap against a cavity
DELETE FROM @R;
INSERT INTO @R EXEC Workorder.RejectEvent_Record
    @LotId = NULL, @DefectCodeId = @DefectId, @Quantity = 12,
    @ToolCavityId = @CavId, @ShiftId = @ShiftId, @CellLocationId = @CellId,
    @AppUserId = @Usr, @OperationTypeCode = N'DieCast';
SET @v = (SELECT CAST(Status AS NVARCHAR(20)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[LotFree] scrap with no LOT is accepted', @Expected = N'1', @Actual = @v;

-- the part came from the cavity, not from a LOT
SET @v = (SELECT CAST(COUNT(*) AS NVARCHAR(20)) FROM Workorder.RejectEvent re
          WHERE re.ToolCavityId = @CavId AND re.LotId IS NULL AND re.ItemId = @ItemId);
EXEC test.Assert_IsEqual @TestName = N'[LotFree] ItemId resolved from ToolCavity.ItemId', @Expected = N'1', @Actual = @v;

-- neither identifier supplied -> rejected before any transaction
DELETE FROM @R;
INSERT INTO @R EXEC Workorder.RejectEvent_Record
    @LotId = NULL, @DefectCodeId = @DefectId, @Quantity = 5, @AppUserId = @Usr,
    @OperationTypeCode = N'DieCast';
SET @v = (SELECT CAST(Status AS NVARCHAR(20)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[LotFree] neither LotId nor ToolCavityId rejects', @Expected = N'0', @Actual = @v;

-- an unmapped cavity still records, with a NULL part (spec 4.1)
EXEC test.Assert_IsEqual @TestName = N'[LotFree] unmapped cavity records with NULL ItemId', @Expected = N'1', @Actual = @vUnmapped;

-- subtractive scrap still demands a LOT -- there is nothing to decrement without one
EXEC test.Assert_IsEqual @TestName = N'[LotFree] subtractive scrap without a LOT rejects', @Expected = N'0', @Actual = @vSubtractive;
```

- [ ] **Step 2: Run and confirm failure**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "110_CavityScrap"
```

Expected: FAIL — `@LotId` is not optional, so the proc rejects on the required-parameter branch.

- [ ] **Step 3: Change the proc**

Bump the header to **v2.0**. Make `@LotId` default `NULL`, add the five identity parameters, and insert **before** `BEGIN TRANSACTION` (Msg-3915 rule):

```sql
    -- v2.0: die-cast scrap is a fact about a CAVITY; the LOT is optional
    -- decoration (spec D1). Exactly one identifier is required -- a reject that
    -- names neither a basket nor a cavity is not a fact about anything.
    IF @LotId IS NULL AND @ToolCavityId IS NULL
    BEGIN SET @Message = N'Supply either a LOT or a cavity.'; GOTO Fail; END

    -- Subtractive scrap decrements Lot.PieceCount, so it cannot work without a
    -- LOT. This is a validation, not an oversight.
    IF @Additive = 0 AND @LotId IS NULL
    BEGIN SET @Message = N'Scrap at this operation must be recorded against a LOT.'; GOTO Fail; END

    -- Identity is STAMPED, never derived at read time: two reject reports reach
    -- the part via INNER JOIN Lots.Lot, and an inner join on NULL drops the row.
    DECLARE @ResolvedItemId BIGINT = @ItemId;
    DECLARE @ResolvedToolId BIGINT = @ToolId;
    IF @ResolvedItemId IS NULL AND @LotId        IS NOT NULL SELECT @ResolvedItemId = ItemId FROM Lots.Lot        WHERE Id = @LotId;
    IF @ResolvedItemId IS NULL AND @ToolCavityId IS NOT NULL SELECT @ResolvedItemId = ItemId FROM Tools.ToolCavity WHERE Id = @ToolCavityId;
    IF @ResolvedToolId IS NULL AND @ToolCavityId IS NOT NULL SELECT @ResolvedToolId = ToolId FROM Tools.ToolCavity WHERE Id = @ToolCavityId;
    IF @ResolvedToolId IS NULL AND @LotId        IS NOT NULL SELECT @ResolvedToolId = ToolId FROM Lots.Lot        WHERE Id = @LotId;
```

`@ResolvedItemId` may legitimately remain `NULL` (an unmapped cavity, spec §4.1) — do **not** reject on it. Add the five columns to the `INSERT INTO Workorder.RejectEvent` column list and values. Guard every existing `Lots.Lot` lookup and the `Lot_AssertNotBlocked` call with `IF @LotId IS NOT NULL`.

- [ ] **Step 4: Run the die-cast suite, then the full suite**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "0022_PlantFloor_DieCast"
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

Expected: both green. `020_RejectEvent_Record` must pass unmodified — every existing caller passes a LOT.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_RejectEvent_Record.sql sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql
git commit -m "feat(diecast): RejectEvent_Record v2.0 -- lot-optional, stamps part and die"
```

---

## Task 4: `DieCast_GetShiftOutputBreakdown` v3.0

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql`
- Modify: `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql`

**Interfaces:**
- Produces: three **appended** trailing columns — `PriorScrapThisShift INT`, `DieWideShots INT`, `IsPending BIT`. `ProposedGood` becomes net of die-wide. New parameter `@DieWideShots INT = 0`.

- [ ] **Step 1: Write the failing tests**

```sql
-- prior scrap is SHIFT-scoped, not lifetime. A cross-shift basket must not
-- over-report -- the exact defect Lot_GetShiftCavityTally.RejectSum has.
EXEC test.Assert_IsEqual @TestName = N'[Breakdown] PriorScrapThisShift excludes a prior shift',
    @Expected = N'12', @Actual = @vPrior;

-- die-wide comes off the proposal, so a clean shift balances to zero variance
EXEC test.Assert_IsEqual @TestName = N'[Breakdown] ProposedGood is net of die-wide',
    @Expected = N'842', @Actual = @vProposed;

-- a cavity with no basket is PENDING, not a variance (spec 3.5 / 3.6)
EXEC test.Assert_IsEqual @TestName = N'[Breakdown] basketless cavity reports IsPending',
    @Expected = N'1', @Actual = @vPending;
```

- [ ] **Step 2: Run, confirm failure**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "110_CavityScrap"
```

Expected: FAIL — `Invalid column name 'PriorScrapThisShift'`.

- [ ] **Step 3: Change the proc**

Bump to **v3.0**. Add `@DieWideShots INT = 0`. Append the three columns **last** (existing consumers capture positionally via `INSERT-EXEC`):

```sql
        -- APPENDED (v3.0). Shift-scoped, cavity-keyed -- the number that exists
        -- nowhere today. Reads the new IX_RejectEvent_ShiftCavity path.
        ISNULL((SELECT SUM(re.Quantity) FROM Workorder.RejectEvent re
                WHERE re.ShiftId = @ShiftId AND re.ToolCavityId = tc.Id), 0) AS PriorScrapThisShift,
        @DieWideShots AS DieWideShots,
        CAST(CASE WHEN lo.LotId IS NULL THEN 1 ELSE 0 END AS BIT) AS IsPending
```

and subtract die-wide inside `ProposedGood`, floored at 0.

- [ ] **Step 4: Widen every `INSERT-EXEC` scratch table that captures this proc**

```bash
grep -rn "DieCast_GetShiftOutputBreakdown" sql/tests/
```

Each temp table needs three more trailing columns: `PriorScrapThisShift INT, DieWideShots INT, IsPending BIT`. Missing this is Msg 213 and it aborts the whole file under `sqlcmd -b`.

- [ ] **Step 5: Run die-cast, then full**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "0022_PlantFloor_DieCast"
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCast_GetShiftOutputBreakdown.sql sql/tests/
git commit -m "feat(diecast): breakdown v3.0 -- prior scrap, die-wide net, pending cavities"
```

---

## Task 5: `DieCastShiftOutput_Record` v3.0

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql`
- Modify: `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql`

**Interfaces:**
- Produces: `@LinesJson` elements gain `toolCavityId`, `varianceReasonId`, `varianceNote`; `lotId` becomes optional per line.

- [ ] **Step 1: Write the failing tests**

```sql
-- die-wide fans out across ACTIVE CAVITIES, not open LOTs -- today it silently
-- skips any cavity without a basket
EXEC test.Assert_IsEqual @TestName = N'[ShiftOutput] die-wide reaches a cavity with no basket',
    @Expected = N'1', @Actual = @vFanout;

-- a line with a cavity and no LOT writes scrap and NO contribution row (3.6)
EXEC test.Assert_IsEqual @TestName = N'[ShiftOutput] basketless line writes scrap, no contribution',
    @Expected = N'1', @Actual = @vNoContrib;

-- pieces on a basketless line are rejected -- nothing to credit
EXEC test.Assert_IsEqual @TestName = N'[ShiftOutput] pieces on a basketless line reject',
    @Expected = N'0', @Actual = @vPieces;

-- a reason whose RequiresNote is 1 must carry one
EXEC test.Assert_IsEqual @TestName = N'[ShiftOutput] Unknown without a note rejects',
    @Expected = N'0', @Actual = @vNote;
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Change the proc**

Bump to **v3.0**. Parse the new line fields; validate dispositions pre-transaction; re-key the fan-out:

```sql
        -- v3.0: fan out across ACTIVE CAVITIES, not open LOTs. The old form
        -- (WHERE l.ToolId = @ToolId AND sc.Code = 'Open') reached only cavities
        -- that happened to hold a basket and silently skipped the rest.
        INSERT INTO Workorder.RejectEvent
            (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
             DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
        SELECT NULL, ol.LotId, tc.ItemId, @ToolId, tc.Id, @ShiftId, @ResolvedCellLocationId,
               sl.defectCodeId, sl.quantity, NULL, N'Die-cast die-wide scrap',
               @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
        FROM OPENJSON(@ShotLossJson) WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') sl
        CROSS JOIN Tools.ToolCavity tc
        INNER JOIN Tools.ToolCavityStatusCode csc ON csc.Id = tc.StatusCodeId
        OUTER APPLY (SELECT TOP 1 l.Id AS LotId FROM Lots.Lot l
                     INNER JOIN Lots.LotStatusCode lsc ON lsc.Id = l.LotStatusId
                     WHERE l.ToolCavityId = tc.Id AND lsc.Code = N'Open') ol
        WHERE tc.ToolId = @ToolId AND tc.DeprecatedAt IS NULL AND csc.Code = N'Active';
```

Validate pre-transaction that any supplied `varianceReasonId` exists, and that a reason with
`RequiresNote = 1` carries a non-blank `varianceNote`. Keep every scrap write **inlined** — this proc
is captured by `INSERT-EXEC`.

- [ ] **Step 4: Run die-cast, then full**

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql
git commit -m "feat(diecast): shift output v3.0 -- cavity lines, cavity fan-out, dispositions"
```

---

## Task 6: Repoint the reject readers

**Files:**
- Modify: `sql/migrations/repeatable/R__Quality_Reject_GetPartMatrix.sql`, `_GetPartMatrixByParty.sql`, `_GetPartMatrixDefects.sql`, `_SearchDetail.sql`, `_GetPlantSummary.sql`, `_GetNonRejectScrap.sql`
- Modify: `sql/tests/0069_Aggregate_Reports/` (existing suite)

**Interfaces:**
- Consumes: `RejectEvent.ItemId` (Task 1/3).

- [ ] **Step 1: Write the failing test**

```sql
-- THE REGRESSION THIS TASK EXISTS FOR. With an INNER JOIN to Lots.Lot, a
-- lot-free reject is DROPPED from the report with no error -- a smaller number
-- that looks plausible. Assert it is present and attributed to the right part.
EXEC test.Assert_IsEqual @TestName = N'[Reports] lot-free scrap appears in the Part Matrix',
    @Expected = N'1', @Actual = @vMatrix;
EXEC test.Assert_IsEqual @TestName = N'[Reports] lot-free scrap appears in Transaction Detail',
    @Expected = N'1', @Actual = @vDetail;
EXEC test.Assert_IsEqual @TestName = N'[Reports] unmapped-cavity scrap buckets as unassigned, not dropped',
    @Expected = N'1', @Actual = @vUnassigned;
```

- [ ] **Step 2: Run, confirm failure** — the rows are silently absent.

- [ ] **Step 3: Repoint each reader**

Replace in all six:

```sql
-- BEFORE
FROM Workorder.RejectEvent re
INNER JOIN Lots.Lot   l ON l.Id = re.LotId
INNER JOIN Parts.Item i ON i.Id = l.ItemId

-- AFTER: identity is on the fact row (spec 4.2). LEFT so an unmapped cavity
-- buckets as unassigned rather than vanishing.
FROM Workorder.RejectEvent re
LEFT JOIN Parts.Item i ON i.Id = re.ItemId
```

Group on `ISNULL(i.PartNumber, N'(unassigned part)')` so the bucket has a label.

- [ ] **Step 4: Run the reports suite, then full**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "Aggregate_Reports"
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

- [ ] **Step 5: Render the three reject reports to PDF and LOOK at them**

Follow `ignition-context-pack/10_reporting_module.md` § "Verify-by-render". A report that renders proves nothing — confirm a lot-free row **appears** and sits under the right part. Composite the PNG onto white first; report PNGs are RGBA with a transparent ground.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Quality_Reject_*.sql sql/tests/0069_Aggregate_Reports/
git commit -m "fix(reports): reject readers take identity from the fact row, not the LOT"
```

---

## Task 7: Ignition backend — named queries and entity glue

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/workorder/DieCastVarianceReason_List/{query.sql,resource.json}`
- Modify: `ignition/projects/Core/ignition/named-query/workorder/DieCast_GetShiftOutputBreakdown/*`, `.../DieCastShiftOutput_Record/*`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py`

**Interfaces:**
- Produces: `BlueRidge.Workorder.DieCast.listVarianceReasons()` → `[{label, value, requiresNote}]`; `recordShiftOutput(data, appUserId, terminalLocationId)` accepting `toolCavityId` / `varianceReasonId` / `varianceNote` per line.

- [ ] **Step 1: Add the new NQ** — `type: "Query"` (status-row and read procs both), `version: 2`, params `sqlType: 3` for BIGINT and `7` for NVARCHAR. Clone the shape from a Designer-saved sibling.

- [ ] **Step 2: Add `@DieWideShots` to the breakdown NQ** and the three new per-line fields to the record NQ's JSON payload.

- [ ] **Step 3: Extend the entity script** — thin glue only, no domain decisions:

```python
def listVarianceReasons():
    """Dropdown shape for the variance disposition picker."""
    BlueRidge.Common.Util.log("running")
    rows = BlueRidge.Common.Db.execList("workorder/DieCastVarianceReason_List")
    return [{"label": r["Name"], "value": r["Id"], "requiresNote": bool(r["RequiresNote"])} for r in rows]
```

- [ ] **Step 4: Scan and confirm clean**

```bash
powershell -File scan.ps1
```

Expected: no `Named query not found` in `logs/wrapper.log`. A missing NQ fails **silently** and shows up as an editor that saves but never refreshes.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/workorder/ ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/
git commit -m "feat(diecast): NQs and entity glue for cavity scrap and dispositions"
```

---

## Task 8: `DieCastBody` — two tabs (Designer)

**Files:**
- Modify (Designer): `ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/DieCastBody/view.json`
- Modify (Designer): `ignition/projects/MPP/.../Components/PlantFloor/DieCastEntry/CavityLotRow/view.json`

**This is a Designer task.** `DieCastBody` is an existing view and file-editing it invites the Files-vs-Gateway conflict. Work in Designer; commit the resulting diff.

**Reference rendering:** `mockup/diecast_reconcile_mock.html` rev 7.

- [ ] **Step 1: Collapse three tabs to two.** `Open Baskets` + `Currently Open` merge into **Lot Management**, one cavity-keyed row per cavity with Open / Release / Void inline. `Record Shift Output` becomes **Reconcile Shift**. Remember `ia.container.tab` maps panes by `position.tabIndex`, not array order.

- [ ] **Step 2: Group both grids by part, then cavity letter.** A cavity letter is unique per `(Tool, Item, CavityCode)` — a family die repeats letters once per part. `DM0124` in prod is 11 cavities = 3 letters × 4 parts.

- [ ] **Step 3: Pair the entry bar and die-wide block on one row**, each with its own section heading.

- [ ] **Step 4: Add the Good input** to each cavity row, pre-filled from `ProposedGood`, marked when overwritten, **disabled** where `IsPending`.

- [ ] **Step 5: Add `PriorScrapThisShift` as the Shift-scrap column**, and the die-wide subtraction into the Shots cell as `net` over `raw − dieWide`.

- [ ] **Step 6: Variance cell → inline disposition (D17).** Non-zero variance expands in place to the reason picker plus a note field when `requiresNote`.

- [ ] **Step 7: Pending rows.** `IsPending` renders *"N shots since HH:MM — credits to the next basket"*, sits outside the identity, never gates submit, and carries an inline **Open basket** action.

- [ ] **Step 8: Fix `submitShiftOutput`.** Delete `if not r.get("IsOpen"): continue` — it discards scrap on a basket released earlier in the shift, which the proc has accepted since v2.1. Key `breakdownEntries` on `ToolCavityId`, not `"%s" % lotId` — every basketless cavity currently collides on the string `"None"`.

- [ ] **Step 9: Fold shot loss into the one Submit** and remove its immediate proc call.

- [ ] **Step 10: Remove the right rail.** Die life becomes a header pill; shots / good / scrap / unaccounted become the totals equation, plus a separate Pending figure.

- [ ] **Step 11: Smoke on the gateway** — reconcile a shift on a multi-cavity die with one pending cavity and one operator-counted good; confirm the totals balance and Submit gates on the disposition.

- [ ] **Step 12: Check the diff for pickled data before committing**

```bash
git diff --stat ignition/projects/MPP/
```

Designer embeds runtime rows into a view saved with live data. A diff far larger than the edit means pickling — restore and re-apply.

- [ ] **Step 13: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/DieCastBody/ ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastEntry/
git commit -m "feat(diecast): Lot Management + Reconcile Shift, cavity-keyed and part-grouped"
```

---

## Task 9: `DieCastRelease` — good box and scrap block (Designer)

**Files:**
- Modify (Designer): `ignition/projects/MPP/.../Components/Popups/DieCastRelease/view.json`

**No SQL.** `Lots.DieCastLot_Release` already accepts `@FinalPieceDelta` as an explicit override and `@ScrapLinesJson` for a closing batch. The dialog has never offered either — its only input is `ReadingInput`.

- [ ] **Step 1: Add a Good input** beside the existing `MathStrip`, pre-filled with the derived `NewShots` and passed as `@FinalPieceDelta` when the operator overwrites it.

- [ ] **Step 2: Add a scrap block** — the same reason/qty rows, passed as `@ScrapLinesJson`.

- [ ] **Step 3: Leave die-wide out** (spec §11.2 — release is one cavity's closing number).

- [ ] **Step 4: Smoke** — release a basket with a counted good figure and one scrap line; confirm `PieceCount`, the contribution row and the `RejectEvent` all land.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DieCastRelease/
git commit -m "feat(diecast): release dialog offers the counted good figure and closing scrap"
```

---

## Task 10: Cleanup and How-To regeneration

**Files:**
- Delete: `sql/migrations/repeatable/R__Lots_Lot_GetShiftCavityTally.sql`, its NQ, its entity wrapper
- Delete: `ignition/projects/MPP/.../Components/PlantFloor/DieCastEntry/RejectPanel/`
- Modify: `tools/gen_howto_views.py`

- [ ] **Step 1: Grep-verify zero references before deleting either**

```bash
grep -rn "Lot_GetShiftCavityTally\|DieCastEntry/RejectPanel" --include=*.json --include=*.py --include=*.sql .
```

Expected after Task 8: no hits outside the files being deleted. `RejectPanel` has been dead since the 2026-07-29 rebuild.

- [ ] **Step 2: Rewrite the four die-cast How-To sources** in `tools/gen_howto_views.py` — `die_cast_open_source()`, `die_cast_shift_output_source()`, `die_cast_lot_release_source()`, `die_cast_supervisor_source()` — for the renamed tabs, the editable good figure, the die-wide block, pending cavities and the disposition.

- [ ] **Step 3: Regenerate and let the built-in verifier run**

```bash
python tools/gen_howto_views.py
powershell -File scan.ps1
```

The generator checks for empty `source`, a string in `markdown`, `escapeHtml` left true, unbalanced tags, missing `resource.json`, and unresolvable `openPopup` paths — resolving the latter across the **inheritance chain**, since MPP declares `"parent": "Core"`.

- [ ] **Step 4: Full suite**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

- [ ] **Step 5: Commit**

```bash
git add -- sql/migrations/repeatable tools/gen_howto_views.py ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ ignition/projects/Core/ignition/named-query ignition/projects/Core/ignition/script-python
git commit -m "chore(diecast): retire the shift tally and RejectPanel, refresh the How-To guides"
```

---

## Task 11: D13 — `ToolCavity_SaveAll` requires a part (own commit)

**Files:**
- Modify: `sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql`
- Modify: `sql/tests/0014_Tools/020_ToolCavity_SaveAll.sql`
- Modify (Designer): `ignition/projects/MPP_Config/.../Components/Parts/Tools/Cavities/view.json`

**Ships separately so it can be reverted without touching the plant floor.**

- [ ] **Step 1: Write the failing tests** — including the one this design exists to avoid:

```sql
EXEC test.Assert_IsEqual @TestName = N'[D13] a new cavity with no part rejects', @Expected = N'0', @Actual = @v1;
EXEC test.Assert_IsEqual @TestName = N'[D13] an existing row edited to no part rejects', @Expected = N'0', @Actual = @v2;
-- THE REGRESSION GUARD: a bundled reconcile carries EVERY row, so a blanket
-- check would reject a save because an UNTOUCHED sibling is unmapped.
EXEC test.Assert_IsEqual @TestName = N'[D13] editing a mapped row saves with an unmapped sibling present', @Expected = N'1', @Actual = @v3;
EXEC test.Assert_IsEqual @TestName = N'[D13] the untouched unmapped row keeps its NULL', @Expected = N'1', @Actual = @v4;
EXEC test.Assert_IsEqual @TestName = N'[D13] Tool_Duplicate of a deprecated-part cavity still succeeds', @Expected = N'1', @Actual = @v5;
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add the row-scoped validation** to `ToolCavity_SaveAll` (v1.2), pre-transaction, naming the offending cavity letters. Compare each incoming row against its current values and reject only where `Id IS NULL` (new) or the row's values differ (changed).

- [ ] **Step 4: Add a "no part configured" flag** to the Cavities editor row so the gap is visible before a save is attempted.

- [ ] **Step 5: Run Tools suite, then full**

```bash
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test -Filter "0014_Tools"
powershell -File sql/tests/Run-Tests.ps1 -DatabaseName MPP_MES_Test
```

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql sql/tests/0014_Tools/020_ToolCavity_SaveAll.sql ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools/
git commit -m "feat(tools): a cavity row this save touches must carry a part"
```

---

## Task 12: D12 — type scale −15% (own commit)

**Files:**
- Modify: `ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css`

**Global — this moves every MPP plant-floor screen, not just die cast.**

- [ ] **Step 1: Replace the type scale**

```css
    --mpp-fs-xs:   14px;   /* was 16 */
    --mpp-fs-sm:   15px;   /* was 17 -- nudged off 0.85 so xs and sm stay distinct */
    --mpp-fs-base: 17px;   /* was 20 */
    --mpp-fs-md:   19px;   /* was 22 */
    --mpp-fs-lg:   22px;   /* was 26 */
    --mpp-fs-xl:   27px;   /* was 32 */
    --mpp-fs-2xl:  34px;   /* was 40 */
    --mpp-fs-3xl:  42px;   /* was 50 */
```

`sm` is deliberately off the arithmetic: `xs` and `sm` were 1px apart, so a straight ×0.85 rounds both to 14 and collapses two steps of the scale into one.

- [ ] **Step 2: Narrow the comment above it.** It currently asserts the floor runs on 1920×1200 tablets and instructs the reader to tune from the tablet. Some terminals are touch and some are not — say that, so the next person neither re-inflates the scale citing gloves nor assumes there is no touch at all. Record that `--pf-touch-min` rides the scale to 34px and that this was a decision.

- [ ] **Step 3: Scan and walk the screens**

```bash
powershell -File scan.ps1
```

Open Die Cast, Trim, Machining, Assembly, Downtime, Hold Management and the Reports landing page. Anything hard-coded in px inside a view rather than taken from a token will **not** move and will read large beside everything that did — that is what this pass is looking for.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/com.inductiveautomation.perspective/stylesheet/stylesheet.css
git commit -m "style(plant-floor): type scale -15% across every MPP screen"
```

---

## Self-review

**Spec coverage.** D1 → Tasks 1/3; D2 → 1/3/6; D3 → 4/8/9; D4 + D17 → 5/8; D5 → 8/9; D6 → 8; D7 → 5/8; D8 → 5; D9 → 1; D10 → 8; D11 → 8; D12 → 12; D13 → 11; D14 + D15 → 1/2/5; D16 → 1 (column) with the report remodel deferred to spec §13. §7's five bugs: (1) Task 8 step 8, (2) Task 8 step 8, (3) Task 5, (4) Task 10, (5) Task 10.

**Gap accepted deliberately:** spec §12's standing cavity-mapping check is a seeding activity with its own script (`sql/scratch/2026-09-14_cavity_part_mapping_evidence.sql`) and no task here. Prod currently has zero unmapped cavities.

**Type consistency.** `ToolCavityId` / `VarianceReasonId` / `VarianceNote` / `PriorScrapThisShift` / `DieWideShots` / `IsPending` are spelled identically in Tasks 1, 4, 5, 7 and 8. `ufn_CavityShotWatermark` keeps its three-parameter signature throughout.

**Ordering.** Tasks 1–6 are SQL and sequential. 7 depends on 4/5. 8 depends on 7. 9 is independent of 8. 11 and 12 are independent of everything and of each other.
