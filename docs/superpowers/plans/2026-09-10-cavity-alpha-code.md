# Cavity Alpha Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the die-wide integer `Tools.ToolCavity.CavityNumber` with a per-part lowercase alphabetic `CavityCode`, so a 12-cavity family die carries four cavities called `a` — one per part — the way MPP names them on the floor.

**Architecture:** Two forward-only migrations bracket the rename. `0075` is **additive** — it adds `CavityCode`, backfills letters per `(Tool, Item)` group, cross-checks each derived letter against the one operators already typed into `Description`, re-scopes the unique index to `(ToolId, ItemId, CavityCode)`, and makes `CavityNumber` nullable. Procs, named queries, Python and views then migrate across a green test suite. `0076` drops `CavityNumber` and `Lots.Lot.CavityNumber` once nothing reads them. Both migrations ship in the same deployment.

**Tech Stack:** SQL Server 2022, T-SQL stored procedures (repeatable `R__` files), Ignition 8.3 Perspective (file-based project, Jython 2.7 script modules, named queries), PowerShell test runner, Python 3 audit script.

---

## Deviation from the spec — read this first

The spec (§3.1) describes **one** migration `0075` that adds `CavityCode` *and* drops `CavityNumber`. This plan splits that into `0075` (additive) + `0076` (drop).

**Why:** dropping `CavityNumber` in the first migration puts the entire SQL test suite red from Task 2 until Task 6 — four tasks with no signal, because every read proc and 26 test files reference the dropped column. Splitting keeps the suite **green at every task boundary**: both columns coexist during the window, so a task's tests either pass or the task isn't done.

**Cost:** none at deploy. `Update-Prod.ps1` applies both in one run, in order. The transient state where old rows carry a `CavityNumber` and new rows carry `NULL` never reaches a deployed system on its own.

Spec §6.3 already contemplated this for `Lots.Lot.CavityNumber` ("splittable"). This applies the same reasoning to the main column. **If you'd rather have the single migration, collapse Tasks 2 and 8 and accept the red window** — nothing else in the plan changes.

---

## Global Constraints

Copied verbatim from `CLAUDE.md` and the spec. Every task's requirements implicitly include this section.

- **Branch:** `jacques/working`. Never commit to `main`. Confirm with `git rev-parse --abbrev-ref HEAD` before the first commit.
- **Staging:** stage **explicit paths only**. Never `git add -u` or `git add -A` — another engineer commits into this tree concurrently and a sweep will capture their files.
- **Commit trailer:** omit `Co-Authored-By: Claude`.
- **Naming:** `UpperCamelCase` tables and columns. `NVARCHAR` never `VARCHAR`. `DATETIME2(3)`. `BIGINT IDENTITY` surrogate `Id` PKs.
- **Codes are lowercase**, 1–4 characters, letters `a`–`z` only. Database collation is `SQL_Latin1_General_CP1_CI_AS` (case-insensitive), so `'A'` and `'a'` collide in the unique index by design.
- **No OUTPUT parameters** (FDS-11-011). Mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. Read procs return an empty result set for "not found".
- **All rejecting validations run BEFORE `BEGIN TRANSACTION`.** A `ROLLBACK` inside a proc invoked via `INSERT-EXEC` throws Msg 3915.
- **`EXEC` parameters must be literals or `@variables`** — never inline `CAST` / arithmetic / `CASE`.
- **Seed and code string values are ASCII-only.** `sqlcmd` reads `.sql` in the Windows codepage; an em-dash becomes mojibake.
- **Existing Perspective views are edited in Designer, not on disk.** File edits to existing `view.json` are unreliable (Designer GSON writes `=` `'` `<` `>` as 6-char unicode escapes, and Designer's in-memory model can overwrite disk). New views, stylesheets, named queries, Python and SQL are safe to file-edit.
- **After any named-query or script-python change, run `.\scan.ps1`.**
- **Test runner targets `MPP_MES_Test`** (throwaway, reset on every run) — never `MPP_MES_Dev` (hand-built data, no backups).

### Pre-existing test failures — NOT regressions

These five already error on a stale `ToolAssignment.CellLocationId` fixture (the 2026-07-06 eligibility-tier decision). They make the runner exit 1 while assertion counts stay green. Do not chase them:

`0022_PlantFloor_DieCast/030`, `/040`, `/050`, `/070`, and `0020_PlantFloor_Foundation/040_Lot_Create.sql`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `sql/migrations/versioned/0075_toolcavity_alpha_code.sql` | **Create.** Add `CavityCode`, backfill, cross-check, re-scope unique index, relax `CavityNumber` | 2 |
| `sql/tests/0015_Tools_Cavity/040_CavityCode_migration.sql` | **Create.** Asserts the backfill, the index scope, the guard | 2 |
| `R__Tools_ToolCavity_Create.sql` | Modify. `@CavityCode NVARCHAR(4)`, format check, per-part uniqueness | 3 |
| `R__Tools_ToolCavity_SaveAll.sql` | Modify. Same rules, set-based, plus the ItemId-collision rejection | 3 |
| `sql/tests/0015_Tools_Cavity/010`, `/020`, `/030` | Modify. Rename + 7 new cases | 3 |
| `R__Tools_ToolCavity_ListByTool.sql`, `_ListActiveByTool.sql`, `R__Tools_Tool_Duplicate.sql` | Modify. Rename + `ORDER BY PartNumber, CavityCode` | 4 |
| 12 `R__Lots_*` / `R__Workorder_*` procs | Modify. Rename; `Lot_Get`'s alias → `ToolCavityCode` | 5 |
| `R__Lots_Lot_Create.sql`, `R__Lots_Lot_GetTerminalRecentCreations.sql` | Modify. Retire the D2 free-text fallback | 6 |
| `lots/Lot_Create`, `parts/ToolCavity_Create` named queries | Modify. Param rename, `sqlType` 2 → 7, drop `cavityNote` | 7 |
| `Parts/Tool/code.py`, `Workorder/DieCast/code.py`, `Lots/Lot/code.py` | Modify. Rename; delete both `int()` coercions | 7 |
| `Parts/Tools/Cavities`, `_Tools/CavityRow` views | Modify **in Designer**. Numeric → text input | 8 |
| 13 plant-floor views | Modify **in Designer**. Param / key / binding renames | 9 |
| `sql/migrations/versioned/0076_drop_cavity_number.sql` | **Create.** Drop both legacy columns | 10 |
| `MPP_MES_DATA_MODEL.md`, `MPP_MES_SUMMARY.md`, `MPP_MES_FDS.md`, `R__Descriptions_ExtendedProperties.sql` | Modify. Prose + extended properties | 11 |

---

## Task 1: Pre-flight gate

**Files:**
- Modify: `tools/cavity_rename_baseline.json` (regenerate)
- Create: `notes/2026-09-10_cavity-rename-preflight.md`

**Interfaces:**
- Consumes: nothing
- Produces: a recorded go/no-go. Later tasks assume `Unmapped = 0` on every family die.

This task writes no product code. It exists because **the backfill silently corrupts data if it runs early** — one unmapped cavity mis-letters its peers (spec §6.2.1). A reviewer can reject this task by pointing at a non-zero count.

- [ ] **Step 1: Confirm the punch-list dependency landed**

The Tools punch list (`docs/superpowers/specs/2026-09-10-tools-screen-punch-list-design.md`) must be merged first — it edits the same four files this plan edits, and its §2 is what makes an unmappable Scrapped cavity mappable.

```bash
git log --oneline -12
```

Expected: commits equivalent to `8da3b9af` (*duplicating a die lost every cavity's part number*) and `258a0ab2` (*a scrapped cavity can be returned to Active*) are present.

Verify both landed in the code, not just the log:

```bash
grep -c "No transition OUT of Scrapped" sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql
grep -c "ItemId" sql/migrations/repeatable/R__Tools_Tool_Duplicate.sql
```

Expected: `0` (the guard is deleted) and a non-zero count (the copy exists). If the first is not `0`, **stop** — the punch list has not landed and Task 3 will conflict with it.

- [ ] **Step 2: Re-baseline the audit against the corrected tree**

```bash
python tools/verify_cavity_rename.py --mode baseline
```

Expected: `Baseline written: tools\cavity_rename_baseline.json  (67 files, 371 occurrences)`

The count may differ if more punch-list work landed. That is fine — the baseline is a fingerprint of *now*, and later tasks measure progress against it.

- [ ] **Step 3: Run the prod pre-flight queries**

Against `MPP_MES_Prod` on `MESDBSRV` / `172.17.10.148` (SQL login `Ignition`). **Read-only.** Ask Jacques for the password; do not guess, and do not write anything.

```sql
-- 1. Size and mapping coverage
SELECT COUNT(*) AS Cavities,
       SUM(CASE WHEN ItemId IS NULL THEN 1 ELSE 0 END) AS Unmapped
FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL;

-- 2. Would the 26-per-group guard fire?
SELECT ToolId, ISNULL(ItemId,-1) AS ItemGrp, COUNT(*) n
FROM Tools.ToolCavity WHERE DeprecatedAt IS NULL
GROUP BY ToolId, ISNULL(ItemId,-1) HAVING COUNT(*) > 26;

-- 3. THE GATE: derived letters next to what operators typed
SELECT t.Code AS Tool, i.PartNumber, tc.CavityNumber, tc.Description,
       CHAR(96 + ROW_NUMBER() OVER (PARTITION BY tc.ToolId, ISNULL(tc.ItemId,-1)
                                    ORDER BY tc.CavityNumber)) AS DerivedCode
FROM Tools.ToolCavity tc
JOIN Tools.Tool t ON t.Id = tc.ToolId
LEFT JOIN Parts.Item i ON i.Id = tc.ItemId
WHERE tc.DeprecatedAt IS NULL
ORDER BY t.Code, i.PartNumber, tc.CavityNumber;

-- 4. D6 gate: is the legacy free-text column safe to drop?
SELECT COUNT(*) FROM Lots.Lot WHERE NULLIF(LTRIM(RTRIM(CavityNumber)), '') IS NOT NULL;
SELECT COUNT(*) FROM Lots.Lot WHERE ToolId IS NOT NULL AND ToolCavityId IS NULL;
```

**Pass conditions — all four must hold:**

1. Query 1 `Unmapped = 0` on every **family** die. A single-part die may legitimately leave `ItemId` NULL.
2. Query 2 returns **no rows**.
3. Query 3: for every row whose `Description` ends in a lowercase letter, that letter **equals** `DerivedCode`.
4. Query 4: both counts are **0**.

**Known failure to expect:** `DMO124` cavity 7 (`Exhaust 1 Aa`) was Scrapped before `0072` shipped. If it is still unmapped, map it to `12241-6MA -0000` through the Tool Cavities editor (punch-list §2 makes the Part dropdown editable on a Scrapped row) and re-run query 3. Do not proceed with it unmapped — spec §6.2.1 shows it mis-letters cavities 8 and 9.

If query 4 returns non-zero, **do not drop** in Task 10; rename to `CavityNote` instead per spec §6.3 and record that here.

- [ ] **Step 4: Record the result**

Create `notes/2026-09-10_cavity-rename-preflight.md` with: the date, the four query results pasted verbatim, the go/no-go, and any cavity you had to map by hand.

- [ ] **Step 5: Commit**

```bash
git add notes/2026-09-10_cavity-rename-preflight.md tools/cavity_rename_baseline.json
git commit -m "chore(cavity): pre-flight gate for the alpha-code rename

Prod ItemId coverage, group sizes, derived-letter cross-check and the
Lot.CavityNumber drop gate, run read-only against MPP_MES_Prod. Audit
re-baselined against the post-punch-list tree."
```

---

## Task 2: Migration 0075 — additive schema

**Files:**
- Create: `sql/migrations/versioned/0075_toolcavity_alpha_code.sql`
- Create: `sql/tests/0015_Tools_Cavity/040_CavityCode_migration.sql`

**Interfaces:**
- Consumes: Task 1's go/no-go
- Produces: `Tools.ToolCavity.CavityCode NVARCHAR(4) NOT NULL`; unique index `UQ_ToolCavity_ActiveToolItemCode (ToolId, ItemId, CavityCode) WHERE DeprecatedAt IS NULL`; `Tools.ToolCavity.CavityNumber` now **nullable** and no longer uniquely indexed. Every later task reads `CavityCode`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0015_Tools_Cavity/040_CavityCode_migration.sql`:

```sql
-- =============================================
-- File:         0015_Tools_Cavity/040_CavityCode_migration.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-10
-- Description:
--   Migration 0075 -- Tools.ToolCavity.CavityCode.
--   Asserts the column exists and is NOT NULL, that the unique index is
--   scoped (ToolId, ItemId, CavityCode), that CavityNumber is now nullable,
--   and that per-part duplicate codes are rejected while cross-part
--   duplicates are allowed.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0015_Tools_Cavity/040_CavityCode_migration.sql';
GO

-- =============================================
-- Test 1: CavityCode exists, NVARCHAR(4), NOT NULL
-- =============================================
DECLARE @IsNullable INT = (
    SELECT c.is_nullable FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(N'Tools.ToolCavity') AND c.name = N'CavityCode');
EXEC test.Assert_IsEqual
    @Actual = @IsNullable, @Expected = 0,
    @TestName = N'0075: CavityCode is NOT NULL';

DECLARE @MaxLen INT = (
    SELECT c.max_length / 2 FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(N'Tools.ToolCavity') AND c.name = N'CavityCode');
EXEC test.Assert_IsEqual
    @Actual = @MaxLen, @Expected = 4,
    @TestName = N'0075: CavityCode is NVARCHAR(4)';
GO

-- =============================================
-- Test 2: unique index is scoped to (ToolId, ItemId, CavityCode)
-- =============================================
DECLARE @NewIdx INT = (
    SELECT COUNT(*) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Tools.ToolCavity')
      AND name = N'UQ_ToolCavity_ActiveToolItemCode');
EXEC test.Assert_IsEqual
    @Actual = @NewIdx, @Expected = 1,
    @TestName = N'0075: UQ_ToolCavity_ActiveToolItemCode exists';

DECLARE @OldIdx INT = (
    SELECT COUNT(*) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Tools.ToolCavity')
      AND name = N'UQ_ToolCavity_ActiveToolCavity');
EXEC test.Assert_IsEqual
    @Actual = @OldIdx, @Expected = 0,
    @TestName = N'0075: old die-wide unique index is gone';

DECLARE @IdxCols INT = (
    SELECT COUNT(*) FROM sys.index_columns ic
    INNER JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    INNER JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.name = N'UQ_ToolCavity_ActiveToolItemCode'
      AND c.name IN (N'ToolId', N'ItemId', N'CavityCode'));
EXEC test.Assert_IsEqual
    @Actual = @IdxCols, @Expected = 3,
    @TestName = N'0075: unique index keys on ToolId + ItemId + CavityCode';
GO

-- =============================================
-- Test 3: CavityNumber is now nullable (0076 drops it later)
-- =============================================
DECLARE @NumNullable INT = (
    SELECT c.is_nullable FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(N'Tools.ToolCavity') AND c.name = N'CavityNumber');
EXEC test.Assert_IsEqual
    @Actual = @NumNullable, @Expected = 1,
    @TestName = N'0075: CavityNumber relaxed to nullable';
GO

-- =============================================
-- Test 4: two parts on one tool may BOTH have a cavity 'a';
--         the same part may not have two.
-- =============================================
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveTId BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @ActiveCId BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

CREATE TABLE #T (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T EXEC Tools.Tool_Create
    @ToolTypeId = @DieTypeId, @Code = N'CODE-TEST-DIE', @Name = N'Alpha Code Test Die',
    @StatusCodeId = @ActiveTId, @AppUserId = 1;
DECLARE @ToolId BIGINT = (SELECT NewId FROM #T);
DROP TABLE #T;

DECLARE @ItemA BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL);
DECLARE @ItemB BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id > @ItemA);

INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
VALUES (@ToolId, N'a', @ItemA, @ActiveCId, 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
VALUES (@ToolId, N'a', @ItemB, @ActiveCId, 1);

DECLARE @CrossPart INT = (
    SELECT COUNT(*) FROM Tools.ToolCavity
    WHERE ToolId = @ToolId AND CavityCode = N'a' AND DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual
    @Actual = @CrossPart, @Expected = 2,
    @TestName = N'0075: cavity a allowed on two different parts of one tool';

DECLARE @Dup INT = 0;
BEGIN TRY
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
    VALUES (@ToolId, N'a', @ItemA, @ActiveCId, 1);
END TRY
BEGIN CATCH
    SET @Dup = 1;
END CATCH
EXEC test.Assert_IsEqual
    @Actual = @Dup, @Expected = 1,
    @TestName = N'0075: duplicate cavity a on the SAME part is rejected';

-- Case-insensitive collation: 'A' collides with 'a'
DECLARE @Case INT = 0;
BEGIN TRY
    INSERT INTO Tools.ToolCavity (ToolId, CavityCode, ItemId, StatusCodeId, CreatedByUserId)
    VALUES (@ToolId, N'A', @ItemA, @ActiveCId, 1);
END TRY
BEGIN CATCH
    SET @Case = 1;
END CATCH
EXEC test.Assert_IsEqual
    @Actual = @Case, @Expected = 1,
    @TestName = N'0075: uppercase A collides with a (CI collation)';

DELETE FROM Tools.ToolCavity WHERE ToolId = @ToolId;
DELETE FROM Tools.Tool WHERE Id = @ToolId;
GO

EXEC test.PrintSummary;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "040_CavityCode_migration"
```

Expected: FAIL — `Invalid column name 'CavityCode'`, because the migration does not exist yet.

- [ ] **Step 3: Write the migration**

Create `sql/migrations/versioned/0075_toolcavity_alpha_code.sql`:

```sql
-- ============================================================
-- Migration:   0075_toolcavity_alpha_code.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-10
-- Description: Cavity identity moves from a die-wide INT ordinal to a
--              PER-PART lowercase alphabetic code.
--
--              MPP runs family dies -- one 12-cavity die casting four part
--              numbers, three cavities each -- and names a cavity by a
--              letter scoped to its part ("6MA EX 1 cavity 'a'", per 0072's
--              own header). The letter was already being hand-typed into the
--              free-text Description ('In 1 Da' / 'Db' / 'Dc' on prod)
--              because the schema had nowhere else for it.
--
--              ADDITIVE ONLY. CavityNumber is relaxed to nullable and its
--              unique index dropped, but the column survives until 0076 so
--              the test suite and every read proc stay green while they are
--              migrated. Both migrations ship in the same deployment.
--
--              Design: docs/superpowers/specs/2026-09-10-cavity-alpha-code-design.md
--              Idempotent-guarded; no explicit transaction (repo convention,
--              see 0067).
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0075_toolcavity_alpha_code')
BEGIN
    PRINT 'Migration 0075 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Add the column, nullable for the backfill
-- ============================================================
IF COL_LENGTH('Tools.ToolCavity', 'CavityCode') IS NULL
    ALTER TABLE Tools.ToolCavity ADD CavityCode NVARCHAR(4) NULL;
GO

-- ============================================================
-- 2. Guard BEFORE writing anything: a>z has no 27th letter.
--    A group this large means the ItemId map is wrong, not the letters.
-- ============================================================
IF EXISTS (SELECT 1 FROM Tools.ToolCavity
           GROUP BY ToolId, ISNULL(ItemId, -1) HAVING COUNT(*) > 26)
BEGIN
    RAISERROR(N'Migration 0075 aborted: a (Tool, Item) group has more than 26 cavities. Configure Tools.ToolCavity.ItemId before migrating.', 16, 1);
    RETURN;
END
GO

-- ============================================================
-- 3. Backfill: letters per part group, in existing ordinal order.
--    Deprecated rows included -- the unique index is filtered, but the
--    column is about to become NOT NULL.
-- ============================================================
UPDATE tc
SET CavityCode = CHAR(96 + x.rn)
FROM Tools.ToolCavity tc
INNER JOIN (
    SELECT Id,
           ROW_NUMBER() OVER (PARTITION BY ToolId, ISNULL(ItemId, -1)
                              ORDER BY CavityNumber, Id) AS rn
    FROM Tools.ToolCavity
) x ON x.Id = tc.Id
WHERE tc.CavityCode IS NULL;
GO

-- ============================================================
-- 3b. CROSS-CHECK, not a source.
--     Operators already typed the letter as the last character of
--     Description ('In 1 Da', 'Ex 1 Db', 'Exhaust 1 Aa'). Where a
--     Description ends in a lowercase letter it MUST equal the derived
--     code. Descriptions with no trailing letter (single-cavity dies --
--     '6MA oil Pan') are skipped, not failed.
--
--     Description is never PARSED INTO the column, only compared to it.
-- ============================================================
DECLARE @Mismatch NVARCHAR(MAX) = (
    SELECT STRING_AGG(
        CAST(t.Code + N' #' + CAST(tc.CavityNumber AS NVARCHAR(10))
             + N' "' + tc.Description + N'" derived=' + tc.CavityCode AS NVARCHAR(MAX)),
        N'; ')
    FROM Tools.ToolCavity tc
    INNER JOIN Tools.Tool t ON t.Id = tc.ToolId
    WHERE tc.Description IS NOT NULL
      AND RIGHT(tc.Description, 1) COLLATE Latin1_General_BIN2 LIKE N'[a-z]'
      AND RIGHT(tc.Description, 1) <> tc.CavityCode);

IF @Mismatch IS NOT NULL
BEGIN
    DECLARE @Msg NVARCHAR(2044) = LEFT(
        N'Migration 0075 aborted: derived cavity code disagrees with the letter in Description -- ' + @Mismatch, 2044);
    RAISERROR(@Msg, 16, 1);
    RETURN;
END
GO

-- ============================================================
-- 4. Lock it down
-- ============================================================
ALTER TABLE Tools.ToolCavity ALTER COLUMN CavityCode NVARCHAR(4) NOT NULL;
GO

-- ============================================================
-- 5. Re-scope uniqueness: per (Tool, Item), not per Tool.
--    ItemId stays NULLable -- SQL Server treats NULLs as equal for
--    uniqueness, so a non-family die's cavities form one group and still
--    get distinct letters. That is correct: a one-part die's cavities ARE
--    mutually exclusive.
-- ============================================================
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = N'UQ_ToolCavity_ActiveToolCavity'
             AND object_id = OBJECT_ID(N'Tools.ToolCavity'))
    DROP INDEX UQ_ToolCavity_ActiveToolCavity ON Tools.ToolCavity;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'UQ_ToolCavity_ActiveToolItemCode'
                 AND object_id = OBJECT_ID(N'Tools.ToolCavity'))
    CREATE UNIQUE INDEX UQ_ToolCavity_ActiveToolItemCode
        ON Tools.ToolCavity (ToolId, ItemId, CavityCode)
        WHERE DeprecatedAt IS NULL;
GO

-- ============================================================
-- 6. Relax the old column. 0076 drops it once nothing reads it.
-- ============================================================
ALTER TABLE Tools.ToolCavity ALTER COLUMN CavityNumber INT NULL;
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0075_toolcavity_alpha_code')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0075_toolcavity_alpha_code',
        N'Cavity identity: per-part lowercase alphabetic Tools.ToolCavity.CavityCode NVARCHAR(4) NOT NULL, backfilled per (Tool, Item) group in ordinal order and cross-checked against the letter in Description. Unique index re-scoped to (ToolId, ItemId, CavityCode). CavityNumber relaxed to nullable; dropped in 0076.'
    );
GO

PRINT 'Migration 0075 completed: Tools.ToolCavity.CavityCode.';
GO
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "040_CavityCode_migration"
```

Expected: PASS, 8 assertions.

- [ ] **Step 5: Run the whole suite — it must still be green**

```bash
powershell -File sql/tests/Run-Tests.ps1
```

Expected: assertion failures **0**. The runner may still exit 1 from the five pre-existing stale-fixture errors listed in Global Constraints. Nothing else may be red — `CavityNumber` still exists, so every unmigrated proc and test still works.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/versioned/0075_toolcavity_alpha_code.sql sql/tests/0015_Tools_Cavity/040_CavityCode_migration.sql
git commit -m "feat(sql): 0075 -- per-part alphabetic Tools.ToolCavity.CavityCode

Additive. Adds CavityCode NVARCHAR(4) NOT NULL, backfills a letter per
(Tool, Item) group in ordinal order, and re-scopes uniqueness to
(ToolId, ItemId, CavityCode) so a family die can carry four cavities
called 'a', one per part.

Step 3b cross-checks every derived letter against the one operators
already typed as the last character of Description and aborts listing
mismatches. Description is compared to, never parsed into, the column.

CavityNumber is relaxed to nullable rather than dropped so the suite and
every read proc stay green while they migrate; 0076 drops it."
```

---

## Task 3: The two write procs

**Files:**
- Modify: `sql/migrations/repeatable/R__Tools_ToolCavity_Create.sql`
- Modify: `sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql`
- Modify: `sql/tests/0015_Tools_Cavity/010_Cavity_crud.sql`
- Modify: `sql/tests/0015_Tools_Cavity/020_ToolCavity_SaveAll.sql`
- Modify: `sql/tests/0015_Tools_Cavity/030_ToolCavity_ItemId.sql`

**Interfaces:**
- Consumes: `Tools.ToolCavity.CavityCode` from Task 2
- Produces:
  - `Tools.ToolCavity_Create @ToolId BIGINT, @CavityCode NVARCHAR(4), @Description NVARCHAR(500) = NULL, @AppUserId BIGINT` → `SELECT Status, Message, NewId`
  - `Tools.ToolCavity_SaveAll @ToolId BIGINT, @RowsJson NVARCHAR(MAX), @AppUserId BIGINT` → `SELECT Status, Message, NewId`. `RowsJson` element is now `{Id, CavityCode, Description, StatusCode, ItemId}`.

- [ ] **Step 1: Write the failing tests**

Append to `sql/tests/0015_Tools_Cavity/020_ToolCavity_SaveAll.sql`, before `EXEC test.PrintSummary;`:

```sql
-- =============================================
-- Test: per-part code rules (0075)
-- =============================================
DECLARE @T3 BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CAV-SAVE-DIE');
DECLARE @P1 BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL);
DECLARE @P2 BIGINT = (SELECT MIN(Id) FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id > @P1);

-- Cross-part duplicate letter: ACCEPTED
DECLARE @J1 NVARCHAR(MAX) =
    N'[{"CavityCode":"a","StatusCode":"Active","ItemId":' + CAST(@P1 AS NVARCHAR(20)) + N'},'
    + N'{"CavityCode":"a","StatusCode":"Active","ItemId":' + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X1 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J1, @AppUserId=1;
DECLARE @S1 BIT = (SELECT Status FROM #X1);
DROP TABLE #X1;
EXEC test.Assert_IsEqual @Actual=@S1, @Expected=1,
    @TestName=N'SaveAll: cavity a on two different parts is accepted';

-- Same-part duplicate letter: REJECTED
DECLARE @J2 NVARCHAR(MAX) =
    N'[{"CavityCode":"b","StatusCode":"Active","ItemId":' + CAST(@P1 AS NVARCHAR(20)) + N'},'
    + N'{"CavityCode":"b","StatusCode":"Active","ItemId":' + CAST(@P1 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X2 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J2, @AppUserId=1;
DECLARE @S2 BIT = (SELECT Status FROM #X2);
DROP TABLE #X2;
EXEC test.Assert_IsEqual @Actual=@S2, @Expected=0,
    @TestName=N'SaveAll: duplicate cavity b on the same part is rejected';

-- Non-letter code: REJECTED
DECLARE @J3 NVARCHAR(MAX) = N'[{"CavityCode":"1","StatusCode":"Active"}]';
CREATE TABLE #X3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X3 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J3, @AppUserId=1;
DECLARE @S3 BIT = (SELECT Status FROM #X3);
DROP TABLE #X3;
EXEC test.Assert_IsEqual @Actual=@S3, @Expected=0,
    @TestName=N'SaveAll: numeric cavity code is rejected';

-- Empty code: REJECTED
DECLARE @J4 NVARCHAR(MAX) = N'[{"CavityCode":"","StatusCode":"Active"}]';
CREATE TABLE #X4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X4 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J4, @AppUserId=1;
DECLARE @S4 BIT = (SELECT Status FROM #X4);
DROP TABLE #X4;
EXEC test.Assert_IsEqual @Actual=@S4, @Expected=0,
    @TestName=N'SaveAll: empty cavity code is rejected';

-- Five-letter code: REJECTED
DECLARE @J5 NVARCHAR(MAX) = N'[{"CavityCode":"abcde","StatusCode":"Active"}]';
CREATE TABLE #X5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X5 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J5, @AppUserId=1;
DECLARE @S5 BIT = (SELECT Status FROM #X5);
DROP TABLE #X5;
EXEC test.Assert_IsEqual @Actual=@S5, @Expected=0,
    @TestName=N'SaveAll: over-length cavity code is rejected';

-- Uppercase normalizes to lowercase
DECLARE @J6 NVARCHAR(MAX) =
    N'[{"CavityCode":"Z","StatusCode":"Active","ItemId":' + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X6 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J6, @AppUserId=1;
DROP TABLE #X6;
DECLARE @Stored NVARCHAR(4) = (
    SELECT TOP 1 CavityCode COLLATE Latin1_General_BIN2 FROM Tools.ToolCavity
    WHERE ToolId=@T3 AND ItemId=@P2 AND CavityCode = N'z');
EXEC test.Assert_IsEqual @Actual=@Stored, @Expected=N'z',
    @TestName=N'SaveAll: uppercase code is normalized to lowercase';

-- CavityCode immutable on a saved row
DECLARE @ExistId BIGINT = (
    SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId=@T3 AND ItemId=@P1 AND CavityCode=N'a');
DECLARE @J7 NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@ExistId AS NVARCHAR(20)) + N',"CavityCode":"q","StatusCode":"Active","ItemId":'
    + CAST(@P1 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X7 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J7, @AppUserId=1;
DECLARE @S7 BIT = (SELECT Status FROM #X7);
DROP TABLE #X7;
EXEC test.Assert_IsEqual @Actual=@S7, @Expected=0,
    @TestName=N'SaveAll: CavityCode is immutable on an existing row';

-- ItemId edit that would collide: REJECTED
-- (P2 already has a cavity 'a'; moving P1's 'a' onto P2 duplicates it)
DECLARE @J8 NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@ExistId AS NVARCHAR(20)) + N',"CavityCode":"a","StatusCode":"Active","ItemId":'
    + CAST(@P2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #X8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #X8 EXEC Tools.ToolCavity_SaveAll @ToolId=@T3, @RowsJson=@J8, @AppUserId=1;
DECLARE @S8 BIT = (SELECT Status FROM #X8);
DROP TABLE #X8;
EXEC test.Assert_IsEqual @Actual=@S8, @Expected=0,
    @TestName=N'SaveAll: ItemId edit that collides with an existing code is rejected';
GO
```

The setup tool `CAV-SAVE-DIE` must exist in that file. If the file's existing setup uses a different code, use that code instead — do not create a second tool.

- [ ] **Step 2: Run to verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "0015_Tools_Cavity"
```

Expected: FAIL — the proc still takes `CavityNumber`, so every new assertion returns `Status = 0` for the wrong reason and the cross-part case fails outright.

- [ ] **Step 3: Rewrite `ToolCavity_Create`**

In `R__Tools_ToolCavity_Create.sql`, rename the parameter and replace the range check.

Signature:

```sql
CREATE OR ALTER PROCEDURE Tools.ToolCavity_Create
    @ToolId      BIGINT,
    @CavityCode  NVARCHAR(4),
    @Description NVARCHAR(500) = NULL,
    @AppUserId   BIGINT
AS
```

Normalize before validating (immediately after the `DECLARE` block, before `BEGIN TRY`):

```sql
SET @CavityCode = LOWER(LTRIM(RTRIM(@CavityCode)));
```

Replace the `IF @CavityNumber < 1` block with:

```sql
        IF @CavityCode IS NULL OR @CavityCode = N''
           OR LEN(@CavityCode) > 4
           OR @CavityCode LIKE N'%[^a-z]%'
        BEGIN
            SET @Message = N'Cavity code must be 1-4 letters (a-z).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
```

Also update the required-parameter check (`@CavityNumber IS NULL` → `@CavityCode IS NULL`), the `@Params` JSON (`@CavityNumber AS CavityNumber` → `@CavityCode AS CavityCode`), the `INSERT` column list, the header Description, and add a Change Log line.

- [ ] **Step 4: Rewrite `ToolCavity_SaveAll`**

In `R__Tools_ToolCavity_SaveAll.sql`:

Retype the staging table:

```sql
    DECLARE @Incoming TABLE (
        RowIndex     INT PRIMARY KEY,
        Id           BIGINT NULL,
        CavityCode   NVARCHAR(4) NULL,
        Description  NVARCHAR(500) NULL,
        StatusCode   NVARCHAR(20) NULL,
        StatusCodeId BIGINT NULL,
        ItemId       BIGINT NULL
    );
```

Change the `OPENJSON` projection — the value is a string now, not an INT:

```sql
        INSERT INTO @Incoming (RowIndex, Id, CavityCode, Description, StatusCode, ItemId)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT),
               LOWER(LTRIM(RTRIM(JSON_VALUE([value], '$.CavityCode')))),
               JSON_VALUE([value], '$.Description'),
               JSON_VALUE([value], '$.StatusCode'),
               TRY_CAST(JSON_VALUE([value], '$.ItemId') AS BIGINT)
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));
```

Replace the `CavityNumber IS NULL OR CavityNumber < 1` block:

```sql
        IF EXISTS (SELECT 1 FROM @Incoming
                   WHERE CavityCode IS NULL OR CavityCode = N''
                      OR LEN(CavityCode) > 4
                      OR CavityCode LIKE N'%[^a-z]%')
        BEGIN
            SET @Message = N'Cavity code must be 1-4 letters (a-z) on every row.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
```

Replace the intra-payload duplicate check — it must now group **per part**:

```sql
        IF EXISTS (SELECT 1 FROM @Incoming
                   GROUP BY ISNULL(ItemId, -1), CavityCode HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate cavity code for the same part in submitted rows.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
```

Replace the immutability check:

```sql
        IF EXISTS (
            SELECT 1 FROM @Incoming i INNER JOIN Tools.ToolCavity c ON c.Id = i.Id
            WHERE i.Id IS NOT NULL AND c.CavityCode <> i.CavityCode)
        BEGIN
            SET @Message = N'Cavity code is immutable on existing cavities.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
```

Replace the "new cavity number must not collide" check with a **projected-final-state** check. This one statement covers a new row colliding with an existing one *and* an `ItemId` edit colliding — the new rejection the spec calls for:

```sql
        -- Projected post-save state: every submitted row, plus every existing
        -- row this payload does not touch. A duplicate (ItemGrp, CavityCode)
        -- in that projection is a collision -- whether it came from a new row
        -- or from an ItemId edit that moved a cavity onto an occupied letter.
        DECLARE @Final TABLE (ItemGrp BIGINT NOT NULL, CavityCode NVARCHAR(4) NOT NULL);

        INSERT INTO @Final (ItemGrp, CavityCode)
        SELECT ISNULL(i.ItemId, -1), i.CavityCode FROM @Incoming i;

        INSERT INTO @Final (ItemGrp, CavityCode)
        SELECT ISNULL(c.ItemId, -1), c.CavityCode
        FROM Tools.ToolCavity c
        WHERE c.ToolId = @ToolId AND c.DeprecatedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM @Incoming i2 WHERE i2.Id = c.Id);

        IF EXISTS (SELECT 1 FROM @Final GROUP BY ItemGrp, CavityCode HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'A cavity with this code already exists for that part on the tool.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
```

Every `@Final` statement sits **before `BEGIN TRANSACTION`**, alongside the other rejections.

Retype the audit staging table and its ordering:

```sql
        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1) NOT NULL, SortKey INT NOT NULL,
            CavityCode NVARCHAR(4) NOT NULL,
            OldStatus NVARCHAR(20) NULL, NewStatus NVARCHAR(20) NULL,
            OldDesc NVARCHAR(500) NULL, NewDesc NVARCHAR(500) NULL,
            OldItem NVARCHAR(50) NULL, NewItem NVARCHAR(50) NULL
        );
```

The `STRING_AGG` narrative loses its cast — the code is already a string:

```sql
        SELECT @AddSpec = STRING_AGG(N'+#' + CavityCode + N' (' + ISNULL(NewStatus,N'Active') + N')', N', ')
```

Apply the same to `@UpdSpec`. Every `ORDER BY … CavityNumber` in this file becomes `ORDER BY … CavityCode`. Update the `UPDATE` and `INSERT` legs to write `CavityCode`. Do **not** write `CavityNumber` — it is nullable now and `0076` drops it.

Bump the header to v1.3 with a Change Log entry.

- [ ] **Step 5: Update the three existing test files**

In `010_Cavity_crud.sql`, `020_ToolCavity_SaveAll.sql` and `030_ToolCavity_ItemId.sql`, replace every `@CavityNumber = <n>` with `@CavityCode = N'<letter>'` (1→`a`, 2→`b`, 3→`c`, …) and every `"CavityNumber":<n>` JSON key with `"CavityCode":"<letter>"`. Assertions reading a `CavityNumber` column read `CavityCode` and compare against a letter.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "0015_Tools_Cavity"
```

Expected: PASS, assertion failures 0.

- [ ] **Step 7: Run the whole suite**

```bash
powershell -File sql/tests/Run-Tests.ps1
```

Expected: assertion failures 0 apart from the five known stale-fixture errors.

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_ToolCavity_Create.sql sql/migrations/repeatable/R__Tools_ToolCavity_SaveAll.sql sql/tests/0015_Tools_Cavity/010_Cavity_crud.sql sql/tests/0015_Tools_Cavity/020_ToolCavity_SaveAll.sql sql/tests/0015_Tools_Cavity/030_ToolCavity_ItemId.sql
git commit -m "feat(sql): cavity write procs take a per-part alphabetic code

ToolCavity_Create and ToolCavity_SaveAll move from @CavityNumber INT to
@CavityCode NVARCHAR(4), normalized lowercase and validated as 1-4
letters, replacing the '>= 1' range check.

Uniqueness is per (Tool, Item): SaveAll builds the projected post-save
state -- submitted rows plus untouched existing rows -- and rejects a
duplicate (part, code) in it. That single check covers a colliding new
row AND an ItemId edit that moves a cavity onto an occupied letter, which
is the new rejection per-part identity requires.

Code stays immutable on a saved row; ItemId stays editable."
```

---

## Task 4: Tools read procs and `Tool_Duplicate`

**Files:**
- Modify: `sql/migrations/repeatable/R__Tools_ToolCavity_ListByTool.sql`
- Modify: `sql/migrations/repeatable/R__Tools_ToolCavity_ListActiveByTool.sql`
- Modify: `sql/migrations/repeatable/R__Tools_Tool_Duplicate.sql`
- Modify: `sql/tests/0014_Tools_Tool/020_Tool_duplicate.sql`
- Modify: `sql/tests/0013_Tools_Types/010_Types_read.sql`

**Interfaces:**
- Consumes: `CavityCode` from Task 2
- Produces: both List procs return a `CavityCode NVARCHAR(4)` column in place of `CavityNumber`, ordered `PartNumber, CavityCode`. Column position is unchanged, so `INSERT-EXEC` consumers keep working.

- [ ] **Step 1: Write the failing test**

Append to `sql/tests/0014_Tools_Tool/020_Tool_duplicate.sql`, before `EXEC test.PrintSummary;`:

```sql
-- =============================================
-- Test: family-die cavities order by part, then code (0075)
-- =============================================
DECLARE @DupTool BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DUP-SRC-DIE');
CREATE TABLE #Ord (
    ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(200),
    CavityCode NVARCHAR(4), StatusCodeId BIGINT, StatusCode NVARCHAR(20),
    StatusName NVARCHAR(50), Description NVARCHAR(500),
    ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500));
INSERT INTO #Ord EXEC Tools.ToolCavity_ListActiveByTool @ToolId = @DupTool;

DECLARE @FirstCode NVARCHAR(4) = (SELECT TOP 1 CavityCode FROM #Ord);
EXEC test.Assert_IsEqual @Actual=@FirstCode, @Expected=N'a',
    @TestName=N'ListActiveByTool: first row of the first part is code a';
DROP TABLE #Ord;
GO
```

If `DUP-SRC-DIE` is not the source tool's code in that file, use the code the file already sets up.

- [ ] **Step 2: Run to verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "020_Tool_duplicate"
```

Expected: FAIL — `Invalid column name 'CavityCode'` in the temp-table shape.

- [ ] **Step 3: Update the two List procs**

In both `R__Tools_ToolCavity_ListByTool.sql` and `R__Tools_ToolCavity_ListActiveByTool.sql`, replace `tc.CavityNumber` in the SELECT with `tc.CavityCode` (same position — trailing-column-only is the 0072 convention and positional `INSERT-EXEC` consumers depend on it), and replace the final line:

```sql
    ORDER BY it.PartNumber, tc.CavityCode;
```

`it` is the existing `LEFT JOIN Parts.Item it ON it.Id = tc.ItemId`. A NULL `PartNumber` sorts first, which is right: a non-family die has one group.

Bump both headers with a Change Log line.

- [ ] **Step 4: Update `Tool_Duplicate`**

Replace `c.CavityNumber` with `c.CavityCode` in the cavity `INSERT … SELECT` column list and values, and both `ORDER BY c.CavityNumber` occurrences (lines ~289 and ~369, inside the `@OldValueResolved` / `@NewValueResolved` JSON) with `ORDER BY c.CavityCode`.

**Do not touch the `ItemId` copy** — that is punch-list §1's, already landed. Leave its deprecated-part guard and `@Message` reporting exactly as they are.

- [ ] **Step 5: Update `0013_Tools_Types/010_Types_read.sql`**

Replace its `CavityNumber` references with `CavityCode` and any numeric literals with letters.

- [ ] **Step 6: Run the tests**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "0013_Tools_Types"
powershell -File sql/tests/Run-Tests.ps1 -Filter "0014_Tools_Tool"
```

Expected: PASS both.

- [ ] **Step 7: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_ToolCavity_ListByTool.sql sql/migrations/repeatable/R__Tools_ToolCavity_ListActiveByTool.sql sql/migrations/repeatable/R__Tools_Tool_Duplicate.sql sql/tests/0014_Tools_Tool/020_Tool_duplicate.sql sql/tests/0013_Tools_Types/010_Types_read.sql
git commit -m "feat(sql): cavity reads return CavityCode, ordered by part then code

Without the part in the ORDER BY, a 12-cavity family die renders
a,a,a,a,b,b,b,b,c,c,c,c on the config grid and the cavity dropdown --
four unrelated parts interleaved. Ordering by PartNumber first groups
them the way the paper production sheets read."
```

---

## Task 5: Lots and Workorder procs

**Files:**
- Modify (11 procs): `R__Lots_DieCastLot_Open.sql`, `R__Lots_Lot_Create.sql`, `R__Lots_Lot_Get.sql`, `R__Lots_Lot_GetLatestForToolCavity.sql`, `R__Lots_Lot_GetOpenByTool.sql`, `R__Lots_Lot_GetShiftCavityTally.sql`, `R__Lots_Lot_SearchAdvanced.sql`, `R__Workorder_Assembly_CompleteTray.sql`, `R__Workorder_DieCast_GetReleasePreview.sql`, `R__Workorder_DieCast_GetShiftOutputBreakdown.sql`, `R__Workorder_MachiningOut_Mint.sql`
- Modify (17 test files): everything under `sql/tests/0020`–`0067` that the audit lists

**Interfaces:**
- Consumes: `CavityCode` from Task 2
- Produces: `Lots.Lot_Get` returns **`ToolCavityCode`** (renamed from `ToolCavityNumber`). `Lot_GetOpenByTool`, `Lot_GetShiftCavityTally`, `DieCast_GetShiftOutputBreakdown`, `Lot_GetLatestForToolCavity` and `Lot_SearchAdvanced` all return `CavityCode`. Tasks 7–9 bind to these names.

> **The alias is the trap.** `Lot_Get` selects `tc.CavityNumber AS ToolCavityNumber`. Renaming the column but not the alias leaves four plant-floor views rendering a **blank cell with no error**. Both change.

- [ ] **Step 1: Find every site**

```bash
python tools/verify_cavity_rename.py --mode inventory
```

Work the `sql/migrations/repeatable` and `sql/tests` sections. Two distinct tokens: `col` (`CavityNumber`) and `colalias` (`ToolCavityNumber`).

- [ ] **Step 2: Rename in the 11 remaining procs**

Mechanical: `tc.CavityNumber` → `tc.CavityCode`, and result-column aliases `AS CavityNumber` → `AS CavityCode`. Three need more than that:

`R__Lots_Lot_Get.sql` — the alias:

```sql
        tc.CavityCode      AS ToolCavityCode,
```

`R__Lots_Lot_GetShiftCavityTally.sql` — the label loses its implicit cast:

```sql
        CONCAT(N'Cavity ', tc.CavityCode)              AS CavityLabel,
```

`R__Workorder_DieCast_GetShiftOutputBreakdown.sql` — ordering gains the part:

```sql
    ORDER BY i.PartNumber, tc.CavityCode, ISNULL(lo.IsOpen, 0) DESC, lo.LotId;
```

Use the existing `Parts.Item` join alias in that proc; if there is none, add `LEFT JOIN Parts.Item i ON i.Id = tc.ItemId`.

Two more orderings gain the part key — `R__Lots_Lot_GetOpenByTool.sql` and `R__Lots_Lot_GetShiftCavityTally.sql`, which both end in a bare `ORDER BY tc.CavityNumber;`:

```sql
    ORDER BY it.PartNumber, tc.CavityCode;
```

Use each proc's existing `Parts.Item` join alias; if a proc has none, add `LEFT JOIN Parts.Item it ON it.Id = tc.ItemId`. That completes all seven ordering sites from spec §5 — the two Tools List procs and `Tool_Duplicate` and `ToolCavity_SaveAll` in Tasks 3 and 4, and `Lot_GetOpenByTool`, `Lot_GetShiftCavityTally` and `DieCast_GetShiftOutputBreakdown` here.

`R__Lots_Lot_Create.sql` — only the `@CavityNum` lookup changes here; the D2 path is Task 6's:

```sql
        DECLARE @CavityNum  NVARCHAR(50)  = (SELECT CavityCode FROM Tools.ToolCavity WHERE Id = @ToolCavityId);
```

`R__Lots_DieCastLot_Open.sql` — the resolved-FK audit JSON:

```sql
            JSON_QUERY((SELECT tc.Id, tc.CavityCode AS Code, tc.CavityCode AS Name FROM Tools.ToolCavity tc WHERE tc.Id = l.ToolCavityId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Cavity
```

- [ ] **Step 3: Rename in the 17 test files**

Every `CavityNumber` column reference becomes `CavityCode`; every temp-table declaration retypes `CavityNumber INT` → `CavityCode NVARCHAR(4)`; every numeric literal becomes its letter (1→`a`, 2→`b`, …). Every `ToolCavityNumber` becomes `ToolCavityCode`.

Files: `0020_PlantFloor_Foundation/040`, `/050`; `0021_PlantFloor_Lot_Lifecycle/076`; `0022_PlantFloor_DieCast/030`, `/040`, `/050`, `/070`, `/080`, `/090`, `/100`; `0023_PlantFloor_DieCast_Deltas/030`; `0045_DieCast_Lifecycle/020`, `/030`, `/040`, `/050`, `/060`, `/070`, `/080`; `0064_Crt_PartScoped/050`; `0067_Lot_SearchAdvanced/010`, `/020`, `/030`.

- [ ] **Step 4: Verify no SQL leftovers**

```bash
python tools/verify_cavity_rename.py --mode inventory
```

Expected: the `sql/migrations/repeatable` section shows **only** `R__Lots_Lot_Create.sql` and `R__Lots_Lot_GetTerminalRecentCreations.sql` (Task 6) and `R__Descriptions_ExtendedProperties.sql` (Task 11). The `sql/tests` section is empty except `0023_.../030` (Task 6).

- [ ] **Step 5: Run the whole suite**

```bash
powershell -File sql/tests/Run-Tests.ps1
```

Expected: assertion failures 0 apart from the five known stale-fixture errors.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_*.sql sql/migrations/repeatable/R__Workorder_*.sql sql/tests/0020_PlantFloor_Foundation sql/tests/0021_PlantFloor_Lot_Lifecycle sql/tests/0022_PlantFloor_DieCast sql/tests/0023_PlantFloor_DieCast_Deltas sql/tests/0045_DieCast_Lifecycle sql/tests/0064_Crt_PartScoped sql/tests/0067_Lot_SearchAdvanced
git commit -m "feat(sql): Lots and Workorder reads return CavityCode

Includes Lot_Get's result ALIAS, ToolCavityNumber -> ToolCavityCode.
Renaming the column without the alias would leave four plant-floor views
rendering a blank cell with no error at all.

Shift-output rows now order by part before code, matching how MPP groups
production: one row per cavity, grouped by part."
```

---

## Task 6: Retire the D2 manual-cavity fallback

**Files:**
- Modify: `sql/migrations/repeatable/R__Lots_Lot_Create.sql`
- Modify: `sql/migrations/repeatable/R__Lots_Lot_GetTerminalRecentCreations.sql`
- Modify: `sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql`

**Interfaces:**
- Consumes: nothing new
- Produces: `Lots.Lot_Create` **no longer accepts `@CavityNote`**. A die-cast-origin LOT without `@ToolCavityId` is rejected. Task 7 drops the named-query parameter and the Python argument to match.

> **Gate:** Task 1's pre-flight query 4 must have returned 0 and 0. If it did not, **skip this task** and rename `Lots.Lot.CavityNumber` to `CavityNote` in Task 10 instead (spec §6.3).

- [ ] **Step 1: Rewrite the two D2 tests**

In `sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql`, delete Test 5 (the D2 accept case, ~lines 125–145) and rewrite Test 6 as the sole rejection case:

```sql
-- =============================================
-- Test 6: die-cast origin without @ToolCavityId is rejected (D2 retired, 0076)
-- =============================================
CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #R6 EXEC Lots.Lot_Create
    @ItemId=@ItemId, @LotOriginTypeId=@ManufacturedId, @CurrentLocationId=@CellId,
    @PieceCount=5, @AppUserId=1, @ToolId=@ToolId, @ToolCavityId=NULL, @LotName=N'900000006';
DECLARE @S6 BIT = (SELECT Status FROM #R6);
DROP TABLE #R6;
EXEC test.Assert_IsEqual @Actual=@S6, @Expected=0,
    @TestName=N'Lot_Create: die-cast origin without a configured cavity is rejected';
GO
```

- [ ] **Step 2: Run to verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "030_Lot_Create_LotName_and_Cavity"
```

Expected: FAIL — `@CavityNote is not a parameter` is *not* yet the error; instead Test 6 fails because the proc still rejects with the old D2 message while Test 5's deleted rows leave the file's later `@LotName` sequence intact. Confirm the failure is Test 6's assertion, not a syntax error.

- [ ] **Step 3: Strip D2 from `Lot_Create`**

Delete the `@CavityNote NVARCHAR(50) = NULL,` parameter (line ~58).

Replace the whole `IF @ToolCavityId IS NULL … ELSE BEGIN` structure (lines ~308–358) so the NULL case is a flat rejection and the validated case is no longer nested in an `ELSE`:

```sql
            IF @ToolCavityId IS NULL
            BEGIN
                SET @Message = N'Die-cast-origin LOT requires a configured Cavity (FDS-05-034).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = NULL, @LogEventTypeCode = N'LotCreated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @MintedLotName AS MintedLotName;
                RETURN;
            END
```

Keep the two validated-path checks (`cavity belongs to the tool`, `cavity is Active`) exactly as they are, de-indented out of the deleted `ELSE`.

Delete `@CavityNumberToStore` (lines ~511–512), drop `CavityNumber` from the `INSERT` column list and `@CavityNumberToStore` from its `VALUES`, and simplify the audit prose:

```sql
        DECLARE @ToolSuffix NVARCHAR(200) =
            CASE WHEN @ToolId IS NOT NULL
                 THEN N'; Tool ' + ISNULL(@ToolCode, N'?') + N', Cavity ' + ISNULL(@CavityNum, N'?')
                 ELSE N'' END;
```

Remove `@CavityNote AS CavityNote` from the `@Params` JSON. Bump the header and add a Change Log line recording that D2 is retired.

- [ ] **Step 4: Simplify `Lot_GetTerminalRecentCreations`**

Replace the `CavityText` expression (lines ~39–48) — the free-text arm is gone:

```sql
        CASE
            WHEN tc.Id IS NOT NULL
                THEN CONCAT(
                        tc.CavityCode,
                        CASE WHEN NULLIF(LTRIM(RTRIM(tc.Description)), N'') IS NOT NULL
                             THEN N' - ' + tc.Description ELSE N'' END)
            ELSE N'-'
        END           AS CavityText,
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "0023_PlantFloor_DieCast_Deltas"
powershell -File sql/tests/Run-Tests.ps1
```

Expected: PASS; whole-suite assertion failures 0 apart from the five known.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Lots_Lot_Create.sql sql/migrations/repeatable/R__Lots_Lot_GetTerminalRecentCreations.sql sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql
git commit -m "feat(sql): retire the D2 manual-cavity fallback

@ToolCavityId is now unconditionally required for a die-cast-origin LOT.
The free-text @CavityNote escape hatch existed because cavities were not
always configured; they are now, with parts mapped, and a LOT whose cavity
is untyped free text cannot be rolled up per part -- which is what 0072
exists for.

Behaviour change, not a tidy. Dev evidence: 0 LOTs used the column and 0
die-cast LOTs lack a cavity FK. 0076 drops the column itself."
```

---

## Task 7: Named queries and Python

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/parts/ToolCavity_Create/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/parts/ToolCavity_Create/resource.json`
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/lots/Lot_Create/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py`

**Interfaces:**
- Consumes: the proc signatures from Tasks 3, 5, 6
- Produces:
  - `BlueRidge.Parts.Tool.createCavity(toolId, cavityCode, description=None)` → `{Status, Message, NewId}`
  - `BlueRidge.Parts.Tool.getCavityInstancesForTool(toolId)` → `[{'cavity': {'Id', 'Code', 'Description', 'StatusCode', 'ItemId', 'ItemPartNumber'}}]` — the row key `Number` becomes **`Code`**
  - `BlueRidge.Parts.Tool.saveAllCavities(toolId, rows)` — row dicts use `cavityCode`, JSON key `CavityCode`
  - `BlueRidge.Workorder.DieCast.cavityDisplayName(cavityCode, cavityDescription)`
  - `BlueRidge.Lots.Lot.create(data, appUserId=None, terminalLocationId=None, lotName=None)` — **`cavityNote` argument removed**
  - Row dicts handed to views carry `cavityCode`, and `Lot`'s `_EMPTY` shape carries `ToolCavityCode`

> **These are file-safe edits** — named queries and script-python are not Designer resources. Views are Tasks 8–9.

- [ ] **Step 1: Update `parts/ToolCavity_Create`**

`query.sql` — the parameter is a string now:

```sql
EXEC Tools.ToolCavity_Create
    @ToolId      = :toolId,
    @CavityCode  = :cavityCode,
    @Description = :description,
    @AppUserId   = :appUserId;
```

`resource.json` — rename the identifier and **change the type**:

```json
   {
    "type": "Parameter",
    "identifier": "cavityCode",
    "sqlType": 7
   },
```

`sqlType: 7` is String. Leaving it at `2` would coerce `'a'` to an integer and fail — the same class of bug as `int()`-ing a PIN.

- [ ] **Step 2: Update `lots/Lot_Create`**

`query.sql` — delete the line `@CavityNote = :cavityNote,`.

`resource.json` — delete the whole `cavityNote` parameter object (around line 105), including the trailing comma of the preceding entry if `cavityNote` was last.

- [ ] **Step 3: Update `Parts/Tool/code.py`**

Delete both `int()` coercions — a code is a string and `int('a')` raises `ValueError`.

`createCavity` (~line 782):

```python
def createCavity(toolId, cavityCode, description=None):
    """Insert a new ToolCavity. Returns {Status, Message, NewId}."""
    toolId = _u(toolId)
    cavityCode = _u(cavityCode)
    BlueRidge.Common.Util.log("toolId=%s cavityCode=%s" % (toolId, cavityCode))
    if toolId is None:
        return {"Status": 0, "Message": "toolId is required", "NewId": None}
    if not cavityCode:
        return {"Status": 0, "Message": "CavityCode is required", "NewId": None}
    return BlueRidge.Common.Db.execStatus(
        "parts/ToolCavity_Create",
        {
            "toolId": toolId,
            "cavityCode": ("%s" % cavityCode).strip().lower(),
            "description": description,
            "appUserId": BlueRidge.Common.Session.currentAppUserId(),
        })
```

Keep whatever `appUserId` expression the file already uses — do not introduce a new one.

`saveAllCavities` (~line 902), replacing the `int(num)` branch:

```python
        code = r.get("cavityCode")
        code = None if code is None else ("%s" % code).strip().lower()
```

and in the dict it builds:

```python
            "CavityCode": code,
```

`getCavityInstancesForTool` (~line 518) — the row key:

```python
                "Code":           r.get("CavityCode"),
```

Update the docstring at line ~495 to say `Code` rather than `Number`.

`activeCavityOptions` (~line 1001) — the dropdown label:

```python
        code = r.get("CavityCode")
        label = ("Cavity %s - %s" % (code, desc)) if desc else ("Cavity %s" % code)
```

- [ ] **Step 4: Update `Workorder/DieCast/code.py`**

Rename `cavityDisplayName`'s first parameter and every `CavityNumber` / `cavityNumber` occurrence:

```python
def cavityDisplayName(cavityCode, cavityDescription):
    """The operator-facing name of a die cavity.

       DECISION (2026-08-19, backlog 2.2): Tools.ToolCavity.Description IS the
       cavity's name; Tools.ToolCavity.CavityCode is only its per-part
       identifier. So the Description wins whenever it is populated, and the
       bare 'Cavity <code>' is the fallback for a cavity nobody has named."""
    desc = ("%s" % (cavityDescription or "")).strip()
    if desc:
        return desc
    return "Cavity %s" % (cavityCode if cavityCode is not None else "?")
```

In the `_EMPTY` dict (~line 92) and the row builders (~lines 132, 193), `"cavityNumber"` → `"cavityCode"` and `r.get("CavityNumber")` → `r.get("CavityCode")`. `cavityOrdinalLabel` keeps its key but its value becomes `"Cavity %s" % code`.

- [ ] **Step 5: Update `Lots/Lot/code.py`**

Drop the `cavityNote` argument from `create` (~line 34) and its entry in the params dict (~line 63):

```python
def create(data, appUserId=None, terminalLocationId=None, lotName=None):
    """Create a LOT. data carries itemId, lotOriginTypeId, currentLocationId,
       pieceCount, toolId, toolCavityId, vendorLotNumber, minSerialNumber,
       maxSerialNumber. lotName is the scanned pre-printed LTT."""
```

Remove `cavityNote` from the log line at ~line 42.

In `_EMPTY` (~line 514): `"ToolCavityNumber": ""` → `"ToolCavityCode": ""`.

In `getLatestForToolCavityOrEmpty` (~line 297): `"CavityNumber": None` → `"CavityCode": None`.

In `shiftCavityOptions` (~line 578):

```python
    return [{"label": r.get("CavityLabel") or ("Cavity %s" % r.get("CavityCode")),
             "value": r.get("ToolCavityId")} for r in rows]
```

- [ ] **Step 6: Scan the gateway**

```bash
powershell -File scan.ps1
```

Expected: exit 0, no errors. A named query or script module that fails to parse shows up here, not at runtime.

- [ ] **Step 7: Verify no leftovers in these layers**

```bash
python tools/verify_cavity_rename.py --mode inventory
```

Expected: the `named-query` and `script-python` sections are **absent** from the output.

- [ ] **Step 8: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/parts/ToolCavity_Create ignition/projects/Core/ignition/named-query/lots/Lot_Create ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py
git commit -m "feat(ignition): named queries and Python carry the cavity code

ToolCavity_Create's parameter is retyped sqlType 2 -> 7 (String). Leaving
it numeric would coerce 'a' to an integer and fail -- the same class of
bug as int()-ing a PIN, which is why both int() coercions in Parts/Tool
are deleted rather than adapted.

Lot_Create loses its cavityNote parameter with the D2 fallback."
```

---

## Task 8: Config Tool views (Designer)

**Files:**
- Modify **in Designer**: `MPP_Config/…/Components/Parts/Tools/_Tools/CavityRow/view.json`
- Modify **in Designer**: `MPP_Config/…/Components/Parts/Tools/Cavities/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Parts.Tool.getCavityInstancesForTool` (row key `Code`) and `saveAllCavities` (row key `cavityCode`) from Task 7
- Produces: an operator can type a letter into the cavity grid and save it

> **Designer only.** File-editing an existing `view.json` is unreliable — Designer's GSON writes `=` `'` `<` `>` as 6-char unicode escapes, and its in-memory model can overwrite your disk changes through the "Files vs Gateway" dialog.

- [ ] **Step 1: `CavityRow` — swap the input component**

Open `BlueRidge/Components/Parts/Tools/_Tools/CavityRow`.

1. Replace the `ia.input.numeric-entry-field` bound to the cavity with an **`ia.input.text-field`**.
2. Repoint both bindings from `view.params.row.cavityNumber` to `view.params.row.cavityCode`.
3. In `view.params`, rename `cavityNumber` to `cavityCode` and change its default from `null` to `""`. A nested bidirectional binding against a `null` renders a validation border and the literal text `"null"` until something populates it.
4. Confirm the `propConfig` entry for the renamed param keeps its `paramDirection`. A Designer save silently dropped one on `CavityLotRow` in the 2026-08-19 merge — check the key set, not just the visible props.

**Leave the `props.enabled` bindings alone.** Punch-list §2 already removed the `isScrappedSaved` term from all three; re-adding it would re-break the mapping of a Scrapped cavity.

- [ ] **Step 2: `Cavities` — rename the keys, delete the coercion**

Open `BlueRidge/Components/Parts/Tools/Cavities`.

1. In the `load` script, `"cavityNumber": cav.get("Number")` → `"cavityCode": cav.get("Code")`.
2. In the add-row script, `"cavityNumber": None` → `"cavityCode": ""`.
3. In the update script, **delete the `int()`**:

```python
	row["cavityCode"] = "" if newCode is None else ("%s" % newCode).strip().lower()
```

Rename the method's parameter to `newCode`, and rename the method itself from `updateCavityNumber` to `updateCavityCode`. Update `CavityRow`'s call site to match.

> Event-script bodies must start with a tab — Designer wraps them in `def runAction(self, event):` and a column-0 body is an `IndentationError` at runtime with no design-time warning.

- [ ] **Step 3: Save from Designer, then scan**

```bash
powershell -File scan.ps1
```

Expected: exit 0.

- [ ] **Step 4: Check for pickled data before committing**

```bash
git diff --stat ignition/projects/MPP_Config
```

Expected: a few tens of changed lines per view. **A diff in the hundreds means Designer pickled runtime rows into a component's default property value** — revert and re-do the edit without loading data into the grid first.

- [ ] **Step 5: Smoke-test in the browser**

Open the Config Tool Tools screen → a die → Cavities tab. Verify: existing cavities show letters; typing `d` into a new row and saving succeeds; typing `4` is rejected with *"Cavity code must be 1-4 letters (a-z) on every row."*

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/Tools
git commit -m "feat(config): the cavity grid takes a letter, not a number

CavityRow swaps numeric-entry-field for text-field and its param defaults
to \"\" rather than null -- a nested bidirectional binding against null
renders a validation border and the literal string 'null'.

Cavities drops the int() coercion that would have raised ValueError on
the first letter typed."
```

---

## Task 9: Plant-floor views (Designer)

**Files** — modify **in Designer**, all under `MPP/…/views/BlueRidge/`:

| View | Change |
|---|---|
| `Components/PlantFloor/DieCastEntry/BulkOpenRow` | param `cavityNumber` → `cavityCode` + its `propConfig.paramDirection` |
| `Components/PlantFloor/DieCastEntry/CavityLotRow` | same |
| `Components/PlantFloor/DieCastEntry/OpenBasketRow` | same |
| `Components/PlantFloor/DieCastEntry/RejectPanel` | expression `toStr({view.custom.targetLot.CavityNumber})` → `.CavityCode` |
| `Components/PlantFloor/LotDetail/CountPanel` | `ToolCavityNumber` → `ToolCavityCode` |
| `Components/PlantFloor/LotDetail/ScrapPanel` | `ToolCavityNumber` → `ToolCavityCode` |
| `Components/Popups/DieCastOverflow` | inline-Python row build, `cavityNumber` → `cavityCode` |
| `Components/Popups/DieCastOverflowRow` | param + `propConfig` + an expression binding |
| `Components/Popups/DieCastRelease` | custom prop `cavityNumber` → `cavityCode` |
| `Views/ShopFloor/DieCastBody` | inline Python: `r.get("CavityNumber")` → `r.get("CavityCode")`, key → `cavityCode` |
| `Views/ShopFloor/InspectionEntry` | `ToolCavityNumber` → `ToolCavityCode` |
| `Views/ShopFloor/LotDetail` | `ToolCavityNumber` → `ToolCavityCode` (3 sites) |
| `Views/ShopFloor/LotSearch` | table column `"field": "CavityNumber"` → `"CavityCode"` |

**Interfaces:**
- Consumes: the row-dict keys from Task 7 and the result-set column names from Task 5
- Produces: no downstream consumer

- [ ] **Step 1: Rename params and keys in the ten straightforward views**

Work the table above top to bottom, except `DieCastOverflowRow` (Step 2). For each: rename the `params` entry, confirm its `propConfig` entry survives **with its `paramDirection` intact**, and update every binding path that reads it.

- [ ] **Step 2: `DieCastOverflowRow` — the expression trap**

Its label binding is:

```
"Cavity " + toStr({view.params.cavityNumber}) + "  ·  " + {view.params.lotName} + …
```

Change only the property path. **The `·` must stay a literal character** — expression string literals reject `\u` escapes, so `·` renders as those six characters rather than a middle dot. If Designer mangles it, retype the character directly.

`toStr()` is now redundant but harmless; leaving it costs nothing and avoids a second edit to a working binding.

- [ ] **Step 3: Scan**

```bash
powershell -File scan.ps1
```

Expected: exit 0.

- [ ] **Step 4: Check for pickled data**

```bash
git diff --stat ignition/projects/MPP
```

Expected: modest per-view diffs. Hundreds of lines on a view you only renamed a param in means pickled data — revert that view and re-do it.

- [ ] **Step 5: Verify the view layer is clean**

```bash
python tools/verify_cavity_rename.py --mode inventory
```

Expected: the only remaining `perspective views` entry is `Views/Audit/AuditLog`, classified **`PICKLED DATA -- strip`**. That one is not a rename — see O2 in the spec. Leave it; it is tracked separately.

- [ ] **Step 6: Smoke-test the Die Cast screen**

Open the Die Cast LOT Entry screen against a family die (`DMO124`). Verify: Bulk Open lists one row per cavity showing letters, grouped by part; the shift-output rows show letters; the overflow popup names a cavity correctly.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge
git commit -m "feat(shop-floor): plant-floor views carry the cavity code

Ten param/key renames plus three that a search for the lowercase
'cavityNumber' would have missed: RejectPanel's expression binding,
LotSearch's table column definition, and the four views reading Lot_Get's
ToolCavityNumber alias."
```

---

## Task 10: Migration 0076 — drop the legacy columns

**Files:**
- Create: `sql/migrations/versioned/0076_drop_cavity_number.sql`
- Modify: `sql/tests/0015_Tools_Cavity/040_CavityCode_migration.sql`

**Interfaces:**
- Consumes: nothing reads `CavityNumber` after Tasks 3–9
- Produces: `Tools.ToolCavity.CavityNumber` and `Lots.Lot.CavityNumber` no longer exist

> **Gate:** if Task 1's pre-flight query 4 returned non-zero, **do not drop `Lots.Lot.CavityNumber`.** Rename it to `CavityNote` instead (`EXEC sp_rename 'Lots.Lot.CavityNumber', 'CavityNote', 'COLUMN';`) and note it in the migration description.

- [ ] **Step 1: Write the failing test**

Replace Test 3 in `040_CavityCode_migration.sql` (which asserted `CavityNumber` was nullable) with:

```sql
-- =============================================
-- Test 3: both legacy CavityNumber columns are gone (0076)
-- =============================================
DECLARE @TcNum INT = (
    SELECT COUNT(*) FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Tools.ToolCavity') AND name = N'CavityNumber');
EXEC test.Assert_IsEqual @Actual=@TcNum, @Expected=0,
    @TestName=N'0076: Tools.ToolCavity.CavityNumber dropped';

DECLARE @LotNum INT = (
    SELECT COUNT(*) FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'CavityNumber');
EXEC test.Assert_IsEqual @Actual=@LotNum, @Expected=0,
    @TestName=N'0076: Lots.Lot.CavityNumber dropped';
GO
```

- [ ] **Step 2: Run to verify it fails**

```bash
powershell -File sql/tests/Run-Tests.ps1 -Filter "040_CavityCode_migration"
```

Expected: FAIL — both counts are 1.

- [ ] **Step 3: Write the migration**

```sql
-- ============================================================
-- Migration:   0076_drop_cavity_number.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-10
-- Description: Drops the two legacy cavity columns, now that every proc,
--              named query, script module and view reads CavityCode.
--
--              Tools.ToolCavity.CavityNumber -- the die-wide INT ordinal,
--              superseded by the per-part CavityCode in 0075.
--
--              Lots.Lot.CavityNumber -- the D2 free-text manual-cavity note,
--              retired with the fallback itself: @ToolCavityId is now
--              unconditionally required for a die-cast-origin LOT.
--
--              PRE-FLIGHT (both must be 0, verified before running):
--                SELECT COUNT(*) FROM Lots.Lot
--                 WHERE NULLIF(LTRIM(RTRIM(CavityNumber)), '') IS NOT NULL;
--                SELECT COUNT(*) FROM Lots.Lot
--                 WHERE ToolId IS NOT NULL AND ToolCavityId IS NULL;
--
--              NOT REVERSIBLE. The ordinal cannot be recovered from the
--              letter once cavities are added or deprecated. Rollback is
--              restore-from-backup.
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0076_drop_cavity_number')
BEGIN
    PRINT 'Migration 0076 already applied -- skipping.';
    RETURN;
END
GO

-- Refuse to destroy data: abort if the D2 column is populated anywhere.
IF EXISTS (SELECT 1 FROM Lots.Lot WHERE NULLIF(LTRIM(RTRIM(CavityNumber)), N'') IS NOT NULL)
BEGIN
    RAISERROR(N'Migration 0076 aborted: Lots.Lot.CavityNumber holds data. Rename it to CavityNote instead of dropping it.', 16, 1);
    RETURN;
END
GO

IF COL_LENGTH('Tools.ToolCavity', 'CavityNumber') IS NOT NULL
    ALTER TABLE Tools.ToolCavity DROP COLUMN CavityNumber;
GO

IF COL_LENGTH('Lots.Lot', 'CavityNumber') IS NOT NULL
    ALTER TABLE Lots.Lot DROP COLUMN CavityNumber;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0076_drop_cavity_number')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0076_drop_cavity_number',
        N'Drops Tools.ToolCavity.CavityNumber (die-wide ordinal, superseded by CavityCode in 0075) and Lots.Lot.CavityNumber (D2 free-text cavity note, retired with the manual-cavity fallback). Guarded: aborts if the Lot column holds data.'
    );
GO

PRINT 'Migration 0076 completed: legacy CavityNumber columns dropped.';
GO
```

- [ ] **Step 4: Run the full suite**

```bash
powershell -File sql/tests/Run-Tests.ps1
```

Expected: PASS; assertion failures 0 apart from the five known stale-fixture errors. **Any new failure here is a proc that still reads `CavityNumber`** — find it, fix it, re-run.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/versioned/0076_drop_cavity_number.sql sql/tests/0015_Tools_Cavity/040_CavityCode_migration.sql
git commit -m "feat(sql): 0076 -- drop both legacy CavityNumber columns

Tools.ToolCavity.CavityNumber (die-wide ordinal) and Lots.Lot.CavityNumber
(D2 free-text note). Guarded: aborts rather than destroying data if the Lot
column is populated.

Not reversible -- the ordinal cannot be recovered from the letter once
cavities are added or deprecated. Rollback is restore-from-backup, which
is why the prod pre-flight in Task 1 is a gate."
```

---

## Task 11: Docs, extended properties and the ERD

**Files:**
- Modify: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`
- Modify: `MPP_MES_DATA_MODEL.md`
- Modify: `MPP_MES_SUMMARY.md`
- Modify: `MPP_MES_FDS.md` (FDS-05-034 wording)
- Regenerate: `MPP_MES_ERD.html`, and the `.docx` for each changed `.md`

**Interfaces:**
- Consumes: the final schema
- Produces: documentation matching it

- [ ] **Step 1: Update the extended properties**

In `R__Descriptions_ExtendedProperties.sql`, replace the `Tools.ToolCavity.CavityNumber` block (~line 5666) with one for `CavityCode`:

```sql
    IF COL_LENGTH(N'[Tools].[ToolCavity]', N'CavityCode') IS NOT NULL
```

with description text:

```
The cavity's identifier, scoped to the part it cuts: lowercase letters a-z, 1-4 characters. Unique per (ToolId, ItemId) among non-deprecated rows via UQ_ToolCavity_ActiveToolItemCode. A 12-cavity family die casting four part numbers carries four cavities called a, one per part -- which is how MPP names them ("6MA EX 1 cavity a"). Immutable once saved; correct a mistake by scrapping the cavity and creating a new one. Replaced the die-wide INT CavityNumber in migration 0075.
```

**ASCII only** — no em-dashes or middle dots; `sqlcmd` reads this file in the Windows codepage and would store mojibake.

Delete the two blocks describing `Lots.Lot.CavityNumber` (~lines 2074–2088) — the column no longer exists.

- [ ] **Step 2: Update the three markdown documents**

`MPP_MES_DATA_MODEL.md` (10 `CavityNumber` + 1 `ToolCavityNumber`): retype the `Tools.ToolCavity` row to `CavityCode NVARCHAR(4) NOT NULL`, update the unique-constraint note to `(ToolId, ItemId, CavityCode)`, remove the `Lots.Lot.CavityNumber` row, and rename the `Lot_Get` alias reference to `ToolCavityCode`. Add a Revision History entry.

`MPP_MES_SUMMARY.md` (1): update the single reference.

`MPP_MES_FDS.md`: FDS-05-034 currently requires `@ToolId` and `@ToolCavityId` with three validations. Add a fourth clause recording that the D2 free-text fallback is retired and `@ToolCavityId` is unconditional, and add a Revision History row.

- [ ] **Step 3: Regenerate the ERD**

The ERD is generated from the live `MPP_MES_Dev` schema, not hand-authored. From `../SchemaGen`:

```bash
python generate_erd.py --config mpp.json
```

Verify `MPP_MES_ERD.html` shows `CavityCode` on `Tools.ToolCavity` and no `CavityNumber` anywhere.

- [ ] **Step 4: Regenerate the Word versions**

```bash
pandoc MPP_MES_DATA_MODEL.md -o MPP_MES_DATA_MODEL.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_DATA_MODEL.docx
pandoc MPP_MES_SUMMARY.md -o MPP_MES_SUMMARY.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_SUMMARY.docx
pandoc MPP_MES_FDS.md -o MPP_MES_FDS.docx --reference-doc=reference.docx && node style_docx_tables.js MPP_MES_FDS.docx
```

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql MPP_MES_DATA_MODEL.md MPP_MES_DATA_MODEL.docx MPP_MES_SUMMARY.md MPP_MES_SUMMARY.docx MPP_MES_FDS.md MPP_MES_FDS.docx MPP_MES_ERD.html
git commit -m "docs(cavity): data model, FDS and ERD describe CavityCode

Extended properties rewritten for the per-part code and the (ToolId,
ItemId, CavityCode) uniqueness scope; the two Lots.Lot.CavityNumber
blocks deleted with the column. FDS-05-034 records that the D2 free-text
fallback is retired and @ToolCavityId is unconditional. ERD regenerated
from the live schema via SchemaGen."
```

---

## Task 12: Final verification

**Files:** none modified

**Interfaces:**
- Consumes: everything
- Produces: the completion signal

- [ ] **Step 1: The audit must reach zero**

```bash
python tools/verify_cavity_rename.py --mode verify
echo "exit=$?"
```

Expected: `PASS -- no cavity-rename leftovers outside the allowlist.` and `exit=0`.

**If `Views/Audit/AuditLog/view.json` is the only thing left**, the rename is complete but the audit cannot pass until its 19 pickled QualifiedValue rows are stripped (spec §7.5, O2). That is pre-existing and unrelated. Strip them — the property should default to empty and bind at runtime — or record explicitly that the audit stands at one file for that reason. **Do not "fix" it by renaming the column inside the pickled payload**; that preserves the defect and makes it look deliberate.

- [ ] **Step 2: Full suite from a clean database**

```bash
powershell -File sql/tests/Run-Tests.ps1
```

Expected: assertion failures 0 apart from the five known stale-fixture errors. A clean reset also proves `0075` and `0076` replay correctly from `0010`'s original `CavityNumber INT` — the forward-only path prod will take.

- [ ] **Step 3: Confirm the versioned migrations were not edited**

```bash
git diff --stat main -- sql/migrations/versioned/
```

Expected: only `0075_toolcavity_alpha_code.sql` and `0076_drop_cavity_number.sql` appear as **new** files. `0010` and `0020` must be untouched — they are history, and editing them would make a replayed schema disagree with every deployed database.

- [ ] **Step 4: Gateway scan and manifest check**

```bash
powershell -File scan.ps1
powershell -File tools/Repair-ProjectManifests.ps1 -Check
```

Expected: both clean. A `resource.json` naming a file not on disk kills the Designer with `project is null` while Perspective keeps serving happily — worth catching here rather than at the gateway.

- [ ] **Step 5: End-to-end smoke on a family die**

Against `MPP_MES_Dev`, with `DMO124` (or the Dev equivalent, `6MA-B`):

1. Config Tool → Tools → Cavities: letters show, grouped by part; adding cavity `d` to a part saves; `4` is rejected.
2. Die Cast → Bulk Open: one row per cavity, letters, grouped by part.
3. Open a basket on cavity `a` of one part; confirm a cavity `a` of a *different* part is independently openable.
4. Record shift output: cavity rows show letters and correct parts.
5. LOT Detail on the resulting LOT: the cavity field shows a letter, not blank. **A blank here means a missed `ToolCavityCode` alias binding.**
6. LOT Search: the Cavity column populates.

- [ ] **Step 6: Update PROJECT_STATUS.md**

Add an entry at the top recording: both migrations, the rename's blast radius (67 files), the D2 retirement, and that **prod deployment requires the Task 1 pre-flight to be re-run against prod immediately before `Update-Prod.ps1`**, plus rebuilt Ignition project exports imported in step with the DB.

- [ ] **Step 7: Commit**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): cavity alpha-code rename complete on Dev

Two migrations (0075 additive, 0076 drop), 67 files, D2 manual-cavity
fallback retired. verify_cavity_rename --mode verify passes.

Prod is NOT done: re-run the Task 1 pre-flight against MPP_MES_Prod
immediately before Update-Prod.ps1, and import rebuilt project exports in
step with the DB. 0076 is not reversible -- rollback is restore-from-backup."
```

---

## Deployment note (not a task)

Prod went live 2026-09-09 and holds real die-cast LOTs. When this ships:

1. **Back up** `MPP_MES_Prod` and `RESTORE VERIFYONLY` it.
2. **Re-run Task 1's pre-flight** against prod immediately before deploying — `ItemId` coverage can regress between now and then.
3. `Update-Prod.ps1` applies migrations then repeatables, which is the correct order. `0075` and `0076` go in the same run.
4. **Rebuild the Ignition project exports after the Designer work** and import them in step with the DB. A gateway serving the old views against the new schema shows blank cavity fields on every die-cast screen.
5. `0076` is **not reversible**. Rollback is restore-from-backup.
