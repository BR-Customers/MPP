# Tool (Die) Shot Count Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each die-cast die a materialized lifetime shot counter and an optional shot limit, surfaced with remaining/percent/near/over indicators for a die-detail view and a station badge.

**Architecture:** Add `ShotCount` (materialized, live-incremented) and `ShotLimit` (nullable) to `Tools.Tool`. The die-cast shift-output write proc increments `ShotCount` by the operator's gross shot count in the same transaction. A small inline TVF `Tools.ufn_ShotStatus` derives remaining/percent/near/over and is reused by the Tool reads and a new mounted-die read. No event ledger, no reconciliation job (spec §2).

**Tech Stack:** SQL Server 2022 (T-SQL stored procs + inline TVF, repeatable migrations), sqlcmd test harness (`sql/tests`, `Run-Tests.ps1`), Ignition Perspective named queries + Jython entity scripts.

**Spec:** `docs/superpowers/specs/2026-08-04-tool-shot-count-design.md`

## Global Constraints

- **Branch:** `claude/tool-shot-count` only. Stage **explicit paths** (`git add <path>`), never `git add -A`/`-u` — a pre-existing `M package.json` from another session must never be swept in. No `Co-Authored-By: Claude` trailer.
- **DB validation:** throwaway DB `MPP_MES_ToolShots` only. NEVER reset/migrate `MPP_MES_Dev`; NEVER use `MPP_MES_Test` (another session owns it).
- **Migration number:** `0050` (verified free: `0049_session_policy` is current highest). Re-confirm no collision immediately before writing the file.
- **SQL conventions** (`sql_best_practices_mes.md`): `UpperCamelCase`; `BIGINT IDENTITY` PKs; `NVARCHAR`; `DATETIME2(3)`; `DECIMAL` not `FLOAT`; store UTC via `SYSUTCDATETIME()`. Enum/status columns FK-backed.
- **FDS-11-011 (JDBC):** no `OUTPUT` params. Read procs: empty result set = not found. Mutation procs: `@Status`/`@Message`/`@NewId` are locals; every exit path ends with `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;`. One result set per proc.
- **Msg-3915 rule:** all rejecting validations run BEFORE `BEGIN TRANSACTION`; the CATCH block is the only legal `ROLLBACK` site.
- **Audit Description convention:** `<SUBJECT> · <CATEGORY?> · <ACTION>` with `Audit.ufn_MidDot()`; resolved-name FK sub-objects in OldValue/NewValue JSON; `Audit.ufn_TruncateActivity()` for the 500-char cap.
- **No business logic in Python:** all rules (die-only guard, near/over thresholds) live in SQL. Entity scripts are thin glue.
- **Ignition file-edit boundary:** new SQL / named queries / Python project scripts are safe file edits. Editing an EXISTING `view.json` is Designer work (Task 8, manual handoff — NOT executed here). Run `.\scan.ps1` after any Ignition resource change.
- **Do-not-touch (parallel sessions):** `Quality.DefectCode*` / DefectCode views / RejectPanel; `AppHeader`, `NavigationTree`, `CellContextSelector`, `MoveOverride`, `Location`/`Terminal`/`code.py`, `Common/Session/code.py`, session-props, MPP_Config Users view. This feature touches none of them.

## Test harness reference

- **Run (reset + all matching files):**
  ```bash
  cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"
  ```
  `Run-Tests.ps1` DROPs and rebuilds its target from all migrations + seeds + repeatables (so migration `0050` and every new `R__` proc apply on reset), then runs only test files whose path matches `-Filter`. First run creates `MPP_MES_ToolShots`. `MPP_MES_ToolShots` is not a `*_Dev` name, so no `-Force` is needed.
- **Assertions:** `EXEC test.BeginTestFile @FileName=N'...';` … `EXEC test.Assert_IsEqual @TestName=N'...', @Expected=N'...', @Actual=<nvarchar>;` … `EXEC test.EndTestFile;`. Compare NVARCHAR strings.
- **Capture a proc's result:** `INSERT INTO @tmp EXEC <proc> ...;` where `@tmp` matches the proc's SELECT shape column-for-column.
- **Teardown:** delete child/audit rows before parents; FK order matters.

---

### Task 1: Migration `0050` — `Tools.Tool` shot columns

**Files:**
- Create: `sql/migrations/versioned/0050_tool_shot_count.sql`

**Interfaces:**
- Produces: `Tools.Tool.ShotCount INT NOT NULL DEFAULT 0`, `Tools.Tool.ShotLimit INT NULL`.

- [ ] **Step 1: Confirm the migration number is free**

Run: `ls sql/migrations/versioned/ | tail -3`
Expected: highest is `0049_session_policy.sql`; no `0050_*` exists. If a `0050_*` appeared, use the next free number and update every reference in this plan.

- [ ] **Step 2: Write the migration**

Create `sql/migrations/versioned/0050_tool_shot_count.sql`:

```sql
-- ============================================================
-- Migration:   0050_tool_shot_count.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-04
-- Description: FAT #26/#27 - die (Tool) shot count. Adds a materialized
--              lifetime shot counter + optional lifetime shot limit to
--              Tools.Tool. ShotCount is incremented live by the die-cast
--              shift-output write proc (v1.2); ShotLimit is set via
--              Tools.Tool_Update. Derived remaining/percent/near/over live
--              in Tools.ufn_ShotStatus. No event ledger / reconcile job
--              (spec 2026-08-04-tool-shot-count-design.md, section 2).
-- ============================================================
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0050_tool_shot_count')
BEGIN
    PRINT 'Migration 0050 already applied - skipping.';
    COMMIT TRANSACTION;
    RETURN;
END

IF COL_LENGTH('Tools.Tool', 'ShotCount') IS NULL
    ALTER TABLE Tools.Tool ADD ShotCount INT NOT NULL DEFAULT 0 WITH VALUES;

IF COL_LENGTH('Tools.Tool', 'ShotLimit') IS NULL
    ALTER TABLE Tools.Tool ADD ShotLimit INT NULL;

INSERT INTO dbo.SchemaVersion (MigrationId, Description)
VALUES ('0050_tool_shot_count',
        'FAT #26/#27: Tools.Tool + ShotCount INT NOT NULL DEFAULT 0 (materialized lifetime) + ShotLimit INT NULL. Live-incremented by DieCastShiftOutput_Record; derived fields via Tools.ufn_ShotStatus.');

COMMIT TRANSACTION;
PRINT 'Migration 0050 completed: Tools.Tool.ShotCount + ShotLimit.';
```

- [ ] **Step 3: Apply via a reset and verify the columns exist**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "__none__"`
(`__none__` matches no test file, so this just resets the DB through migration `0050`.)
Then verify:
```bash
sqlcmd -S localhost -d MPP_MES_ToolShots -C -Q "SELECT COL_LENGTH('Tools.Tool','ShotCount') AS SC, COL_LENGTH('Tools.Tool','ShotLimit') AS SL;"
```
Expected: both non-NULL (columns present). If the reset errors, read the sqlcmd output and fix the migration before continuing.

- [ ] **Step 4: Commit**

```bash
git add sql/migrations/versioned/0050_tool_shot_count.sql
git commit -m "feat(tools): migration 0050 - Tool.ShotCount + ShotLimit columns"
```

---

### Task 2: `Tools.ufn_ShotStatus` inline TVF + tests

**Files:**
- Create: `sql/migrations/repeatable/R__Tools_ufn_ShotStatus.sql`
- Create: `sql/tests/0050_ToolShotCount/010_ufn_ShotStatus.sql`

**Interfaces:**
- Produces: `Tools.ufn_ShotStatus(@ShotCount INT, @ShotLimit INT)` — inline TVF returning exactly one row: `ShotsRemaining INT` (NULL when no limit), `PercentOfLimit DECIMAL(9,2)` (NULL when no/zero limit), `IsNearLimit BIT`, `IsOverLimit BIT`. `IsNearLimit` and `IsOverLimit` are mutually exclusive (near = ≥90% and < limit; over = ≥ limit).

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0050_ToolShotCount/010_ufn_ShotStatus.sql`:

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/010_ufn_ShotStatus.sql';
GO
-- No fixture: the TVF is a pure function of its two arguments.

-- No limit -> all derived values NULL / 0.
DECLARE @r1 NVARCHAR(20) = (SELECT ISNULL(CAST(ShotsRemaining AS NVARCHAR(20)), N'NULL') FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> ShotsRemaining NULL', @Expected=N'NULL', @Actual=@r1;
DECLARE @p1 NVARCHAR(20) = (SELECT ISNULL(CAST(PercentOfLimit AS NVARCHAR(20)), N'NULL') FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> PercentOfLimit NULL', @Expected=N'NULL', @Actual=@p1;
DECLARE @n1 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> IsNearLimit 0', @Expected=N'0', @Actual=@n1;
DECLARE @o1 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(500, NULL));
EXEC test.Assert_IsEqual @TestName=N'[TVF] no limit -> IsOverLimit 0', @Expected=N'0', @Actual=@o1;

-- Below near (80%).
DECLARE @r2 NVARCHAR(20) = (SELECT CAST(ShotsRemaining AS NVARCHAR(20)) FROM Tools.ufn_ShotStatus(800, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 800/1000 -> remaining 200', @Expected=N'200', @Actual=@r2;
DECLARE @p2 NVARCHAR(20) = (SELECT CAST(PercentOfLimit AS NVARCHAR(20)) FROM Tools.ufn_ShotStatus(800, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 800/1000 -> percent 80.00', @Expected=N'80.00', @Actual=@p2;
DECLARE @n2 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(800, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 800/1000 -> IsNearLimit 0', @Expected=N'0', @Actual=@n2;

-- At the near boundary (exactly 90%).
DECLARE @n3 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(900, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 900/1000 -> IsNearLimit 1 (>=90%)', @Expected=N'1', @Actual=@n3;
DECLARE @o3 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(900, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 900/1000 -> IsOverLimit 0', @Expected=N'0', @Actual=@o3;

-- Near but not over (95%).
DECLARE @n4 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(950, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 950/1000 -> IsNearLimit 1', @Expected=N'1', @Actual=@n4;

-- Exactly at limit -> over, not near.
DECLARE @n5 NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(1000, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1000/1000 -> IsNearLimit 0', @Expected=N'0', @Actual=@n5;
DECLARE @o5 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(1000, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1000/1000 -> IsOverLimit 1', @Expected=N'1', @Actual=@o5;

-- Over the limit -> remaining negative, over set.
DECLARE @r6 NVARCHAR(20) = (SELECT CAST(ShotsRemaining AS NVARCHAR(20)) FROM Tools.ufn_ShotStatus(1200, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1200/1000 -> remaining -200', @Expected=N'-200', @Actual=@r6;
DECLARE @o6 NVARCHAR(5) = (SELECT CAST(IsOverLimit AS NVARCHAR(5)) FROM Tools.ufn_ShotStatus(1200, 1000));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 1200/1000 -> IsOverLimit 1', @Expected=N'1', @Actual=@o6;

-- Zero limit -> percent NULL (guard against divide-by-zero).
DECLARE @p7 NVARCHAR(20) = (SELECT ISNULL(CAST(PercentOfLimit AS NVARCHAR(20)), N'NULL') FROM Tools.ufn_ShotStatus(0, 0));
EXEC test.Assert_IsEqual @TestName=N'[TVF] 0/0 -> PercentOfLimit NULL (no divide-by-zero)', @Expected=N'NULL', @Actual=@p7;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: FAIL — the reset errors or the test file errors with `Invalid object name 'Tools.ufn_ShotStatus'` (the function does not exist yet).

- [ ] **Step 3: Write the function**

Create `sql/migrations/repeatable/R__Tools_ufn_ShotStatus.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Tools_ufn_ShotStatus.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-04
-- Version:     1.0
-- Description: Inline TVF deriving a die's shot-limit indicators from its
--              materialized ShotCount + nullable ShotLimit. Single source of
--              the near/over rule (threshold 90%); reused by Tools.Tool_Get,
--              Tools.Tool_List, and Tools.Tool_GetShotStatusForCell via
--              CROSS APPLY. Always returns exactly one row.
--                ShotsRemaining : ShotLimit - ShotCount (NULL when no limit; negative when over)
--                PercentOfLimit : ShotCount * 100 / ShotLimit (NULL when no/zero limit)
--                IsNearLimit    : 1 when limit set and 90% <= ShotCount < limit
--                IsOverLimit    : 1 when limit set and ShotCount >= limit
--              IsNearLimit and IsOverLimit are mutually exclusive.
-- ============================================================
CREATE OR ALTER FUNCTION Tools.ufn_ShotStatus (@ShotCount INT, @ShotLimit INT)
RETURNS TABLE
AS RETURN
    SELECT
        CASE WHEN @ShotLimit IS NULL THEN NULL
             ELSE @ShotLimit - @ShotCount END AS ShotsRemaining,
        CASE WHEN @ShotLimit IS NULL OR @ShotLimit = 0 THEN NULL
             ELSE CAST(@ShotCount AS DECIMAL(9,2)) * 100.0 / @ShotLimit END AS PercentOfLimit,
        CAST(CASE WHEN @ShotLimit IS NOT NULL AND @ShotLimit > 0
                   AND @ShotCount >= 0.9 * @ShotLimit AND @ShotCount < @ShotLimit
                  THEN 1 ELSE 0 END AS BIT) AS IsNearLimit,
        CAST(CASE WHEN @ShotLimit IS NOT NULL AND @ShotCount >= @ShotLimit
                  THEN 1 ELSE 0 END AS BIT) AS IsOverLimit;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: PASS — all `[TVF]` assertions green, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_ufn_ShotStatus.sql sql/tests/0050_ToolShotCount/010_ufn_ShotStatus.sql
git commit -m "feat(tools): Tools.ufn_ShotStatus TVF for shot-limit indicators + tests"
```

---

### Task 3: Surface shot fields on `Tool_Get` + `Tool_List`

**Files:**
- Modify: `sql/migrations/repeatable/R__Tools_Tool_Get.sql`
- Modify: `sql/migrations/repeatable/R__Tools_Tool_List.sql`
- Create: `sql/tests/0050_ToolShotCount/020_Tool_reads_shot_fields.sql`

**Interfaces:**
- Consumes: `Tools.ufn_ShotStatus` (Task 2).
- Produces: `Tools.Tool_Get` / `Tools.Tool_List` result sets gain 6 trailing columns: `ShotCount INT`, `ShotLimit INT`, `ShotsRemaining INT`, `PercentOfLimit DECIMAL(9,2)`, `IsNearLimit BIT`, `IsOverLimit BIT`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0050_ToolShotCount/020_Tool_reads_shot_fields.sql`:

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/020_Tool_reads_shot_fields.sql';
GO
-- cleanup (idempotent)
DELETE FROM Tools.Tool WHERE Code = N'TEST-SHOT-RD';
GO
-- fixture: a Die-type tool with a near-limit shot count
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @Active BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, ShotLimit, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-RD', N'Shot read test die', @Active, 950, 1000, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

-- Tool_Get: full-width capture (must match the proc's SELECT column-for-column)
DECLARE @G TABLE (
    Id BIGINT, ToolTypeId BIGINT, ToolTypeCode NVARCHAR(50), ToolTypeName NVARCHAR(100),
    HasCavities BIT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
    DieRankId BIGINT, DieRankCode NVARCHAR(20), DieRankName NVARCHAR(100),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), CreatedByUserId BIGINT,
    UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(9,2),
    IsNearLimit BIT, IsOverLimit BIT);
INSERT INTO @G EXEC Tools.Tool_Get @Id = @Tool;

DECLARE @sc NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] ShotCount 950', @Expected=N'950', @Actual=@sc;
DECLARE @sl NVARCHAR(20) = (SELECT CAST(ShotLimit AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] ShotLimit 1000', @Expected=N'1000', @Actual=@sl;
DECLARE @rem NVARCHAR(20) = (SELECT CAST(ShotsRemaining AS NVARCHAR(20)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] ShotsRemaining 50', @Expected=N'50', @Actual=@rem;
DECLARE @near NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM @G);
EXEC test.Assert_IsEqual @TestName=N'[Tool_Get] IsNearLimit 1', @Expected=N'1', @Actual=@near;

-- Tool_List: capture only the columns we assert is not possible (INSERT-EXEC needs full shape),
-- so capture full width and filter to our fixture row.
DECLARE @L TABLE (
    Id BIGINT, ToolTypeId BIGINT, ToolTypeCode NVARCHAR(50), ToolTypeName NVARCHAR(100),
    HasCavities BIT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500),
    DieRankId BIGINT, DieRankCode NVARCHAR(20), DieRankName NVARCHAR(100),
    StatusCodeId BIGINT, StatusCode NVARCHAR(30), StatusName NVARCHAR(100),
    CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3), CreatedByUserId BIGINT,
    UpdatedByUserId BIGINT, DeprecatedAt DATETIME2(3),
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(9,2),
    IsNearLimit BIT, IsOverLimit BIT);
INSERT INTO @L EXEC Tools.Tool_List @ToolTypeId = NULL, @StatusCode = NULL, @IncludeDeprecated = 1;
DECLARE @lNear NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM @L WHERE Code = N'TEST-SHOT-RD');
EXEC test.Assert_IsEqual @TestName=N'[Tool_List] fixture row IsNearLimit 1', @Expected=N'1', @Actual=@lNear;

DELETE FROM Tools.Tool WHERE Id = @Tool;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: FAIL — `INSERT INTO @G EXEC Tools.Tool_Get` errors with a column count/type mismatch (the proc does not yet return the 6 shot columns).

- [ ] **Step 3: Add the shot columns to `Tool_Get`**

In `sql/migrations/repeatable/R__Tools_Tool_Get.sql`, change the SELECT tail. Replace:

```sql
        t.UpdatedByUserId,
        t.DeprecatedAt
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType       tt ON tt.Id = t.ToolTypeId
    INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
    LEFT  JOIN Tools.DieRank        dr ON dr.Id = t.DieRankId
    WHERE t.Id = @Id;
```

with:

```sql
        t.UpdatedByUserId,
        t.DeprecatedAt,
        t.ShotCount,
        t.ShotLimit,
        ss.ShotsRemaining,
        ss.PercentOfLimit,
        ss.IsNearLimit,
        ss.IsOverLimit
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType       tt ON tt.Id = t.ToolTypeId
    INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
    LEFT  JOIN Tools.DieRank        dr ON dr.Id = t.DieRankId
    CROSS APPLY Tools.ufn_ShotStatus(t.ShotCount, t.ShotLimit) ss
    WHERE t.Id = @Id;
```

- [ ] **Step 4: Add the shot columns to `Tool_List`**

In `sql/migrations/repeatable/R__Tools_Tool_List.sql`, apply the identical change to its SELECT tail. Replace:

```sql
        t.UpdatedByUserId,
        t.DeprecatedAt
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType       tt ON tt.Id = t.ToolTypeId
    INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
    LEFT  JOIN Tools.DieRank        dr ON dr.Id = t.DieRankId
    WHERE (@IncludeDeprecated = 1 OR t.DeprecatedAt IS NULL)
```

with:

```sql
        t.UpdatedByUserId,
        t.DeprecatedAt,
        t.ShotCount,
        t.ShotLimit,
        ss.ShotsRemaining,
        ss.PercentOfLimit,
        ss.IsNearLimit,
        ss.IsOverLimit
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType       tt ON tt.Id = t.ToolTypeId
    INNER JOIN Tools.ToolStatusCode sc ON sc.Id = t.StatusCodeId
    LEFT  JOIN Tools.DieRank        dr ON dr.Id = t.DieRankId
    CROSS APPLY Tools.ufn_ShotStatus(t.ShotCount, t.ShotLimit) ss
    WHERE (@IncludeDeprecated = 1 OR t.DeprecatedAt IS NULL)
```

(The `ORDER BY tt.SortOrder, t.Code;` line below stays unchanged.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: PASS — all `[Tool_Get]` and `[Tool_List]` assertions green.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_Tool_Get.sql sql/migrations/repeatable/R__Tools_Tool_List.sql sql/tests/0050_ToolShotCount/020_Tool_reads_shot_fields.sql
git commit -m "feat(tools): surface ShotCount/ShotLimit + derived indicators on Tool_Get/Tool_List"
```

---

### Task 4: `Tools.Tool_Update` accepts `@ShotLimit`

**Files:**
- Modify: `sql/migrations/repeatable/R__Tools_Tool_Update.sql`
- Create: `sql/tests/0050_ToolShotCount/030_Tool_Update_shotlimit.sql`

**Interfaces:**
- Produces: `Tools.Tool_Update` gains `@ShotLimit INT = NULL`. Rejects (`Status = 0`, message `ShotLimit is only valid for Die-type Tools.`) when `@ShotLimit IS NOT NULL` and the tool's type is not `Die`. Persists `ShotLimit` (including clearing to NULL). Result set unchanged: `Status, Message`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0050_ToolShotCount/030_Tool_Update_shotlimit.sql`:

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/030_Tool_Update_shotlimit.sql';
GO
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-SHOT-UPD', N'TEST-SHOT-CUT');
GO
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @CutType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Cutter');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-UPD', N'Shot update test die', @Active, SYSUTCDATETIME(), 1);
DECLARE @Die BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@CutType, N'TEST-SHOT-CUT', N'Shot update test cutter', @Active, SYSUTCDATETIME(), 1);
DECLARE @Cut BIGINT = SCOPE_IDENTITY();

-- set a limit on the die
DECLARE @U TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U EXEC Tools.Tool_Update @Id=@Die, @Name=N'Shot update test die', @Description=NULL,
    @DieRankId=NULL, @ShotLimit=5000, @AppUserId=1;
DECLARE @us NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @U);
EXEC test.Assert_IsEqual @TestName=N'[Update] set ShotLimit on die -> Status 1', @Expected=N'1', @Actual=@us;
DECLARE @slAfter NVARCHAR(20) = (SELECT CAST(ShotLimit AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Update] die ShotLimit persisted 5000', @Expected=N'5000', @Actual=@slAfter;

-- clear the limit
DELETE FROM @U;
INSERT INTO @U EXEC Tools.Tool_Update @Id=@Die, @Name=N'Shot update test die', @Description=NULL,
    @DieRankId=NULL, @ShotLimit=NULL, @AppUserId=1;
DECLARE @slCleared NVARCHAR(20) = (SELECT ISNULL(CAST(ShotLimit AS NVARCHAR(20)), N'NULL') FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Update] die ShotLimit cleared to NULL', @Expected=N'NULL', @Actual=@slCleared;

-- non-die rejection
DELETE FROM @U;
INSERT INTO @U EXEC Tools.Tool_Update @Id=@Cut, @Name=N'Shot update test cutter', @Description=NULL,
    @DieRankId=NULL, @ShotLimit=100, @AppUserId=1;
DECLARE @cs NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @U);
EXEC test.Assert_IsEqual @TestName=N'[Update] ShotLimit on non-die -> Status 0', @Expected=N'0', @Actual=@cs;
DECLARE @cslAfter NVARCHAR(20) = (SELECT ISNULL(CAST(ShotLimit AS NVARCHAR(20)), N'NULL') FROM Tools.Tool WHERE Id=@Cut);
EXEC test.Assert_IsEqual @TestName=N'[Update] non-die ShotLimit not written', @Expected=N'NULL', @Actual=@cslAfter;

DELETE FROM Tools.Tool WHERE Id IN (@Die, @Cut);
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: FAIL — `Tool_Update` errors with `@ShotLimit is not a parameter for procedure Tools.Tool_Update`.

- [ ] **Step 3: Add `@ShotLimit` to `Tool_Update`**

In `sql/migrations/repeatable/R__Tools_Tool_Update.sql`:

(a) Add the parameter after `@DieRankId`:
```sql
    @DieRankId   BIGINT        = NULL,
    @ShotLimit   INT           = NULL,
    @AppUserId   BIGINT
```

(b) Add `ShotLimit` to the `@Params` JSON (used as audit NewValue). Replace:
```sql
        (SELECT @Id          AS Id,
                @Name        AS Name,
                @Description AS Description,
                @DieRankId   AS DieRankId
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```
with:
```sql
        (SELECT @Id          AS Id,
                @Name        AS Name,
                @Description AS Description,
                @DieRankId   AS DieRankId,
                @ShotLimit   AS ShotLimit
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```

(c) Capture the old ShotLimit. Replace:
```sql
        DECLARE @ToolTypeCode NVARCHAR(50), @OldName NVARCHAR(100),
                @OldDescription NVARCHAR(500), @OldDieRankId BIGINT;

        SELECT @ToolTypeCode   = tt.Code,
               @OldName        = t.Name,
               @OldDescription = t.Description,
               @OldDieRankId   = t.DieRankId
        FROM Tools.Tool t
        INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @Id AND t.DeprecatedAt IS NULL;
```
with:
```sql
        DECLARE @ToolTypeCode NVARCHAR(50), @OldName NVARCHAR(100),
                @OldDescription NVARCHAR(500), @OldDieRankId BIGINT, @OldShotLimit INT;

        SELECT @ToolTypeCode   = tt.Code,
               @OldName        = t.Name,
               @OldDescription = t.Description,
               @OldDieRankId   = t.DieRankId,
               @OldShotLimit   = t.ShotLimit
        FROM Tools.Tool t
        INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @Id AND t.DeprecatedAt IS NULL;
```

(d) Add the die-only guard. Immediately BEFORE the `IF @DieRankId IS NOT NULL` block, insert:
```sql
        IF @ShotLimit IS NOT NULL AND @ToolTypeCode <> N'Die'
        BEGIN
            SET @Message = N'ShotLimit is only valid for Die-type Tools.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
```

(e) Add ShotLimit to the audit `@OldValue` JSON. Replace:
```sql
        DECLARE @OldValue NVARCHAR(MAX) =
            (SELECT @OldName AS Name, @OldDescription AS Description,
                    @OldDieRankId AS DieRankId
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```
with:
```sql
        DECLARE @OldValue NVARCHAR(MAX) =
            (SELECT @OldName AS Name, @OldDescription AS Description,
                    @OldDieRankId AS DieRankId, @OldShotLimit AS ShotLimit
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
```

(f) Persist ShotLimit. Replace:
```sql
        UPDATE Tools.Tool
        SET Name            = @Name,
            Description     = @Description,
            DieRankId       = @DieRankId,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;
```
with:
```sql
        UPDATE Tools.Tool
        SET Name            = @Name,
            Description     = @Description,
            DieRankId       = @DieRankId,
            ShotLimit       = @ShotLimit,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: PASS — all `[Update]` assertions green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_Tool_Update.sql sql/tests/0050_ToolShotCount/030_Tool_Update_shotlimit.sql
git commit -m "feat(tools): Tool_Update accepts ShotLimit (die-only, audited)"
```

---

### Task 5: `Workorder.DieCastShiftOutput_Record` increments `ShotCount`

**Files:**
- Modify: `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql`
- Create: `sql/tests/0050_ToolShotCount/040_ShiftOutput_increments_shotcount.sql`

**Interfaces:**
- Consumes: `Tools.Tool.ShotCount` (Task 1).
- Produces: `Workorder.DieCastShiftOutput_Record` gains `@GrossShots INT = NULL` (last parameter). When `@GrossShots > 0`, increments `Tools.Tool.ShotCount` by that amount for `@ToolId` inside the existing transaction. `@GrossShots < 0` is rejected pre-transaction (`Status = 0`, no increment). NULL/0 = no-op. Result set unchanged: `Status, Message, NewId`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0050_ToolShotCount/040_ShiftOutput_increments_shotcount.sql`:

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/040_ShiftOutput_increments_shotcount.sql';
GO
DELETE FROM Tools.Tool WHERE Code = N'TEST-SHOT-INC';
GO
-- fixture: a Die tool (the increment target) + a resolved/minted open shift.
-- Empty @LinesJson means the proc records no per-cavity output and only the
-- gross-shot increment runs, so no Cell/Item/Cavity/basket is needed.
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-INC', N'Shot increment test die', @Active, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0050/040 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- first submission: gross 500 -> ShotCount 500
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=500;
DECLARE @s1 NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Inc] gross 500 -> Status 1', @Expected=N'1', @Actual=@s1;
DECLARE @c1 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] ShotCount = 500 after first submit', @Expected=N'500', @Actual=@c1;

-- second submission: gross 300 -> accumulates to 800
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=300;
DECLARE @c2 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] ShotCount accumulates to 800', @Expected=N'800', @Actual=@c2;

-- NULL gross: no-op (mirrors registerShotLoss's no-gross path)
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=NULL;
DECLARE @c3 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] NULL gross leaves ShotCount at 800', @Expected=N'800', @Actual=@c3;

-- zero gross: no-op
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=0;
DECLARE @c4 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] zero gross leaves ShotCount at 800', @Expected=N'800', @Actual=@c4;

-- negative gross: rejected pre-transaction, no increment
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[]', @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=-1;
DECLARE @s5 NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Inc] negative gross -> Status 0', @Expected=N'0', @Actual=@s5;
DECLARE @c5 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] negative gross leaves ShotCount at 800', @Expected=N'800', @Actual=@c5;

-- gross supplied but a bad lot line -> validation rejects before the txn -> no increment
DELETE FROM @W;
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool,
    @LinesJson=N'[{"lotId":999999999,"pieceDelta":1,"scrapLines":null}]',
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @GrossShots=100;
DECLARE @s6 NVARCHAR(5) = (SELECT CAST(Status AS NVARCHAR(5)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Inc] gross + bad lot -> Status 0', @Expected=N'0', @Actual=@s6;
DECLARE @c6 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Tool);
EXEC test.Assert_IsEqual @TestName=N'[Inc] failed submit does not bump ShotCount (still 800)', @Expected=N'800', @Actual=@c6;

-- teardown
DELETE FROM Tools.Tool WHERE Id = @Tool;
IF @ShiftCreatedByTest = 1
    DELETE FROM Oee.Shift WHERE Id = @Shift;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: FAIL — `@GrossShots is not a parameter for procedure Workorder.DieCastShiftOutput_Record`.

- [ ] **Step 3: Add `@GrossShots` + the increment**

In `sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql`:

(a) Add the parameter. Replace:
```sql
    @ShotLossJson NVARCHAR(MAX) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
```
with:
```sql
    @ShotLossJson NVARCHAR(MAX) = NULL, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL,
    @GrossShots INT = NULL
```

(b) Add the pre-transaction guard. Immediately AFTER this line:
```sql
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id=@AppUserId) BEGIN SET @Message=N'AppUser not found.'; GOTO Fail; END
```
insert:
```sql
        IF @GrossShots IS NOT NULL AND @GrossShots < 0 BEGIN SET @Message=N'GrossShots cannot be negative.'; GOTO Fail; END
```

(c) Add the increment inside the transaction. Immediately BEFORE this line:
```sql
        COMMIT TRANSACTION;
        SET @Status=1; SET @Message=N'Shift output recorded.';
```
insert:
```sql
        -- FAT #26/#27: materialized die shot counter. The operator's gross shot
        -- count for this die/shift is the authoritative cycle count; bump it in
        -- the same txn (B5 materialized-quantity pattern, row-locked). NULL/0 =
        -- no-op, so the standalone shot-loss path never double-counts.
        IF @GrossShots > 0
            UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
            SET ShotCount = ShotCount + @GrossShots,
                UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
            WHERE Id = @ToolId;

```

(d) Update the header: bump `Version: 1.1` to `1.2` and add a changelog line, e.g.:
```sql
-- Change:      v1.2 -- FAT #26/#27: new @GrossShots INT param; when > 0,
--              increments Tools.Tool.ShotCount for @ToolId in the same txn
--              (materialized die shot counter). Negative gross rejected
--              pre-transaction. NULL/0 = no-op (shot-loss path never bumps).
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: PASS — all `[Inc]` assertions green.

- [ ] **Step 5: Regression-check the existing die-cast lifecycle test**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "DieCast_Lifecycle"`
Expected: PASS — `0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql` still green (the new param is optional; existing callers pass no gross).

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Workorder_DieCastShiftOutput_Record.sql sql/tests/0050_ToolShotCount/040_ShiftOutput_increments_shotcount.sql
git commit -m "feat(diecast): DieCastShiftOutput_Record v1.2 increments Tool.ShotCount by gross shots"
```

---

### Task 6: `Tools.Tool_GetShotStatusForCell` — mounted-die badge read

**Files:**
- Create: `sql/migrations/repeatable/R__Tools_Tool_GetShotStatusForCell.sql`
- Create: `sql/tests/0050_ToolShotCount/050_Tool_GetShotStatusForCell.sql`

**Interfaces:**
- Consumes: `Tools.ufn_ShotStatus` (Task 2); `Tools.ToolAssignment` active row (`ReleasedAt IS NULL`).
- Produces: `Tools.Tool_GetShotStatusForCell(@CellLocationId BIGINT)` → 0 or 1 row: `ToolId, ToolCode, ToolName, ShotCount, ShotLimit, ShotsRemaining, PercentOfLimit, IsNearLimit, IsOverLimit`. Empty set when no die is mounted on the cell.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0050_ToolShotCount/050_Tool_GetShotStatusForCell.sql`:

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/050_Tool_GetShotStatusForCell.sql';
GO
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-SHOT-CELL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-SHOT-CELL';
GO
-- fixture: a near-limit Die tool mounted on any Cell-tier location
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @Cell BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.Code = N'Cell' AND l.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = l.Id AND ta.ReleasedAt IS NULL)
    ORDER BY l.Id);
IF @Cell IS NULL RAISERROR(N'0050/050 fixture: no free Cell-tier location -- BLOCKED.', 16, 1);

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, ShotLimit, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-CELL', N'Shot cell test die', @Active, 950, 1000, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@Tool, @Cell, SYSUTCDATETIME(), 1);

DECLARE @S TABLE (ToolId BIGINT, ToolCode NVARCHAR(50), ToolName NVARCHAR(100),
    ShotCount INT, ShotLimit INT, ShotsRemaining INT, PercentOfLimit DECIMAL(9,2),
    IsNearLimit BIT, IsOverLimit BIT);
INSERT INTO @S EXEC Tools.Tool_GetShotStatusForCell @CellLocationId=@Cell;

DECLARE @cnt NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] mounted die returns one row', @Expected=N'1', @Actual=@cnt;
DECLARE @csc NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] ShotCount 950', @Expected=N'950', @Actual=@csc;
DECLARE @cnear NVARCHAR(5) = (SELECT CAST(IsNearLimit AS NVARCHAR(5)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] IsNearLimit 1', @Expected=N'1', @Actual=@cnear;

-- release the mount -> read returns empty
UPDATE Tools.ToolAssignment SET ReleasedAt = SYSUTCDATETIME(), ReleasedByUserId = 1
WHERE ToolId = @Tool AND ReleasedAt IS NULL;
DELETE FROM @S;
INSERT INTO @S EXEC Tools.Tool_GetShotStatusForCell @CellLocationId=@Cell;
DECLARE @cnt2 NVARCHAR(5) = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @S);
EXEC test.Assert_IsEqual @TestName=N'[Cell] no mount -> empty result set', @Expected=N'0', @Actual=@cnt2;

DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: FAIL — `Could not find stored procedure 'Tools.Tool_GetShotStatusForCell'`.

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Tools_Tool_GetShotStatusForCell.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Tools_Tool_GetShotStatusForCell.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-04
-- Version:     1.0
-- Description: FAT #26/#27. Returns the shot status of the die CURRENTLY
--              mounted on a cell (active Tools.ToolAssignment, ReleasedAt
--              IS NULL) for the die-cast station badge. Derived indicators
--              come from Tools.ufn_ShotStatus. FDS-11-011: no OUTPUT params,
--              one result set, empty set = nothing mounted (not an error).
-- ============================================================
CREATE OR ALTER PROCEDURE Tools.Tool_GetShotStatusForCell
    @CellLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Id   AS ToolId,
        t.Code AS ToolCode,
        t.Name AS ToolName,
        t.ShotCount,
        t.ShotLimit,
        ss.ShotsRemaining,
        ss.PercentOfLimit,
        ss.IsNearLimit,
        ss.IsOverLimit
    FROM Tools.ToolAssignment ta
    INNER JOIN Tools.Tool t ON t.Id = ta.ToolId
    CROSS APPLY Tools.ufn_ShotStatus(t.ShotCount, t.ShotLimit) ss
    WHERE ta.CellLocationId = @CellLocationId
      AND ta.ReleasedAt IS NULL;
END;
GO
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd sql/tests && powershell -File Run-Tests.ps1 -DatabaseName MPP_MES_ToolShots -Filter "ToolShot"`
Expected: PASS — all `[Cell]` assertions green.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_Tool_GetShotStatusForCell.sql sql/tests/0050_ToolShotCount/050_Tool_GetShotStatusForCell.sql
git commit -m "feat(tools): Tool_GetShotStatusForCell for the die-cast station badge"
```

---

### Task 7: Ignition named queries + entity glue

**Files:**
- Modify: `ignition/projects/Core/ignition/named-query/parts/Tool_Update/query.sql`
- Modify: `ignition/projects/Core/ignition/named-query/workorder/DieCastShiftOutput_Record/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/parts/Tool_GetShotStatusForCell/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/parts/Tool_GetShotStatusForCell/resource.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py`

**Interfaces:**
- Consumes: procs from Tasks 4–6.
- Produces: `BlueRidge.Parts.Tool.update(data)` passes `shotLimit`; `BlueRidge.Parts.Tool.getShotStatusForCell(cellLocationId)` reader; `BlueRidge.Workorder.DieCast.recordShiftOutput(data)` passes `grossShots` from `data['grossShots']`.

> **No sqlcmd test.** NQ/Jython layers aren't unit-tested by the harness; verify with `.\scan.ps1` (clean) and the parameter-shape checks below. This task is one commit.

- [ ] **Step 1: Add `@ShotLimit` to the `Tool_Update` NQ**

Replace the entire body of `ignition/projects/Core/ignition/named-query/parts/Tool_Update/query.sql` with:
```sql
EXEC Tools.Tool_Update
    @DieRankId   = :dieRankId,
    @Description = :description,
    @Name        = :name,
    @Id          = :id,
    @ShotLimit   = :shotLimit,
    @AppUserId   = :appUserId
```
Then open `ignition/projects/Core/ignition/named-query/parts/Tool_Update/resource.json` (or the NQ's `.meta`/param definition file alongside `query.sql`) and add a parameter `shotLimit` of type `Int8`/`Int4` (match the existing `dieRankId` integer parameter's declaration shape). If the NQ stores its parameter list in a sibling JSON, mirror the `dieRankId` entry exactly, renamed to `shotLimit`.

- [ ] **Step 2: Add `@GrossShots` to the `DieCastShiftOutput_Record` NQ**

Replace the body of `ignition/projects/Core/ignition/named-query/workorder/DieCastShiftOutput_Record/query.sql` with:
```sql
EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId            = :shiftId,
    @ToolId             = :toolId,
    @LinesJson          = :linesJson,
    @ShotLossJson       = :shotLossJson,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @GrossShots         = :grossShots
```
Add a `grossShots` integer parameter to that NQ's parameter definition (mirror the existing `toolId` int parameter's declaration, renamed and nullable).

- [ ] **Step 3: Create the `Tool_GetShotStatusForCell` NQ**

Create `ignition/projects/Core/ignition/named-query/parts/Tool_GetShotStatusForCell/query.sql`:
```sql
EXEC Tools.Tool_GetShotStatusForCell @CellLocationId = :cellLocationId
```
Create `ignition/projects/Core/ignition/named-query/parts/Tool_GetShotStatusForCell/resource.json` by copying the structure of `ignition/projects/Core/ignition/named-query/parts/ToolAssignment_GetCellContext/resource.json` (same single `cellLocationId` BIGINT input parameter, `type: "Query"`). Read that sibling file first and mirror its shape exactly, changing only the query text reference if the resource embeds it.

- [ ] **Step 4: Pass `shotLimit` through `Parts.Tool.update` + coerce on read**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py`, in `update(data)`, add `shotLimit` to the `Tool_Update` params. Replace:
```python
    updateResult = BlueRidge.Common.Db.execMutation(
        "parts/Tool_Update",
        {
            "id":          toolId,
            "name":        data.get("Name"),
            "description": description,
            "dieRankId":   dieRankId,
            "appUserId":   appUserId,
        },
    )
```
with:
```python
    shotLimit = data.get("ShotLimit")
    if shotLimit == "" or shotLimit == u"":
        shotLimit = None

    updateResult = BlueRidge.Common.Db.execMutation(
        "parts/Tool_Update",
        {
            "id":          toolId,
            "name":        data.get("Name"),
            "description": description,
            "dieRankId":   dieRankId,
            "shotLimit":   shotLimit,
            "appUserId":   appUserId,
        },
    )
```

- [ ] **Step 5: Add the `getShotStatusForCell` reader**

In the same file, add after `getMountedToolForCellOrEmpty` (near line 880):
```python
def getShotStatusForCell(cellLocationId):
    """Shot status (count / limit / remaining / percent / near / over) of the die
    currently mounted on a Cell, for the die-cast station badge. Returns a dict,
    or None when nothing is mounted. Wraps Tools.Tool_GetShotStatusForCell."""
    cellLocationId = _u(cellLocationId)
    BlueRidge.Common.Util.log("getShotStatusForCell cellLocationId=%s" % cellLocationId)
    if cellLocationId is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne(
            "parts/Tool_GetShotStatusForCell", {"cellLocationId": cellLocationId})
    except Exception as e:
        BlueRidge.Common.Util.log("getShotStatusForCell failed: %s" % str(e))
        return None


def getShotStatusForCellOrEmpty(cellLocationId, _refreshToken=None):
    """Binding-safe variant: a fully-shaped dict (never None) so the badge's
    nested-path bindings never Component-Error (pre-declare-bound-props rule).
    _refreshToken lets a runScript binding force a re-read (runScript caches on args)."""
    row = getShotStatusForCell(cellLocationId)
    if row is None:
        return {"ToolId": None, "ToolCode": "", "ToolName": "",
                "ShotCount": 0, "ShotLimit": None, "ShotsRemaining": None,
                "PercentOfLimit": None, "IsNearLimit": False, "IsOverLimit": False}
    return row
```

- [ ] **Step 6: Pass `grossShots` through `Workorder.DieCast.recordShiftOutput`**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py`, in `recordShiftOutput`, add `grossShots` to the params. Replace:
```python
    params = {
        "shiftId":            d.get("shiftId"),
        "toolId":             d.get("toolId"),
        "linesJson":          BlueRidge.Common.Util.convertWrapperObjectToJson(lines),
        "shotLossJson":       BlueRidge.Common.Util.convertWrapperObjectToJson(shotLoss) if shotLoss else None,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    }
```
with:
```python
    params = {
        "shiftId":            d.get("shiftId"),
        "toolId":             d.get("toolId"),
        "linesJson":          BlueRidge.Common.Util.convertWrapperObjectToJson(lines),
        "shotLossJson":       BlueRidge.Common.Util.convertWrapperObjectToJson(shotLoss) if shotLoss else None,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
        "grossShots":         d.get("grossShots"),
    }
```
(`registerShotLoss` builds `data` without a `grossShots` key, so `d.get("grossShots")` is `None` there — the shot-loss path never increments, as intended.)

- [ ] **Step 7: Scan the gateway and verify clean**

Run: `powershell -File scan.ps1` (from repo root)
Expected: "Project Up to Date" / no deserialize errors. If a new NQ's `resource.json` is malformed, scan reports it — fix and re-scan.

- [ ] **Step 8: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/parts/Tool_Update/query.sql ignition/projects/Core/ignition/named-query/workorder/DieCastShiftOutput_Record/query.sql "ignition/projects/Core/ignition/named-query/parts/Tool_GetShotStatusForCell" ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCast/code.py
git commit -m "feat(ignition): NQ + entity glue for Tool shot count (ShotLimit, grossShots, badge read)"
```

> If Step 1/2's parameter-definition JSON format is unclear, read `ignition-context-pack/04_named_queries.md` before editing — an NQ with a query param not declared in its metadata fails at runtime, and the declaration shape is version-specific.

---

### Task 8: Designer punch-list (MANUAL handoff — not executed here)

**These edit EXISTING `view.json` files → Designer work per the file-edit boundary. Do NOT file-edit them. Hand this list to Jacques (or do it in Designer, then `.\scan.ps1`).** None of these views are on the do-not-touch list.

- [ ] **DieCastBody submit payload** — the shift-output Submit builds the `data` dict passed to `BlueRidge.Workorder.DieCast.recordShiftOutput`. Add the operator's gross shot count under key `grossShots` (it is already in view scope — it drove `getShiftOutputBreakdown`). **Required** for the counter to move in production; nothing else in Task 7 helps without it.
- [ ] **Die-cast station badge** — bind a badge on the die-cast station (DieCastBody / its ContextBar) to `BlueRidge.Parts.Tool.getShotStatusForCellOrEmpty({cell id}, {refreshToken})`. Show `ShotCount` / `ShotLimit` / `PercentOfLimit`; color via `IsNearLimit` (warn) and `IsOverLimit` (danger). Hide the limit portion when `ShotLimit` is null.
- [ ] **Config-Tool tool detail/editor** — display `ShotCount` (read-only) + `ShotsRemaining` / `PercentOfLimit`, and add a **`ShotLimit`** numeric input bound into the tool `editDraft` (the editor must load the current `ShotLimit` into `editDraft` and pass it back on save — `Tool_Update` writes exactly what it receives, so an omitted value clears the limit). Use `ia.input.numeric-entry-field` (`props.value`), or the project's text-field + proc-coercion pattern.

---

## Self-Review

**1. Spec coverage:**
- §3 schema (ShotCount, ShotLimit) → Task 1. ✓
- §4.1 increment → Task 5. ✓
- §4.2 Tool_Update @ShotLimit + die-only guard → Task 4. ✓
- §4.3 Tool_Get/List computed fields → Tasks 2 (TVF) + 3 (wiring). ✓
- §4.4 Tool_GetShotStatusForCell → Task 6. ✓
- §5 NQ + entity glue → Task 7. ✓
- §6 Designer display → Task 8 (flagged manual). ✓
- §7 tests → each SQL task is TDD; scenarios map to §7 items 1–7. ✓
- §8 out-of-scope (ledger/reconcile/maintenance) → correctly absent. ✓
- §9 guardrails → Global Constraints. ✓

**2. Placeholder scan:** No "TBD"/"handle errors"/"similar to". The one soft reference (Task 7 param-definition JSON shape) points at a concrete sibling file to mirror and the context-pack section to read. ✓

**3. Type consistency:** `Tools.ufn_ShotStatus(@ShotCount INT, @ShotLimit INT)` returns `ShotsRemaining INT, PercentOfLimit DECIMAL(9,2), IsNearLimit BIT, IsOverLimit BIT` — used identically in Tasks 3 & 6. `@GrossShots INT` param name matches across Task 5 proc, test, and Task 7 NQ (`grossShots`). `shotLimit`/`ShotLimit` casing consistent (SQL `@ShotLimit`, NQ `:shotLimit`, Python `shotLimit` param / `ShotLimit` data key). Test temp tables match each proc's SELECT column-for-column. ✓
