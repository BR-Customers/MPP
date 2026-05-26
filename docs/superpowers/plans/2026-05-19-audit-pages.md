# Audit Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing `BlueRidge/Views/Audit/FailureLog` + `AuditLog` views to live data per the design at `docs/superpowers/specs/2026-05-19-audit-pages-design.md`.

**Architecture:** Three-layer Configuration Tool pattern (view → `BlueRidge.Audit.*` entity scripts → `Common.Db` → NQ → SQL). Read-only pages; no mutations. Default last-7-days, no-auto-apply, explicit Apply + Reset. Server-side TOP 1000 cap with `COUNT(*) OVER()` window count for "Showing N of M" banner. `ia.display.table` handles paging client-side over the capped result.

**Tech Stack:** SQL Server 2022 (T-SQL), Ignition 8.3.5 Perspective, Jython 2.7, Named Queries.

**Reference reading before starting:** `docs/superpowers/specs/2026-05-19-audit-pages-design.md` is authoritative; this plan implements it task-by-task. Also `ignition-context-pack/03_script_python.md`, `04_named_queries.md`, `06_component_quirks.md`, and the memory files `feedback_ignition_tree_qv_unwrap.md`, `feedback_ignition_designer_unicode_escapes.md`, `feedback_ignition_view_edit_boundary.md`.

---

## File Structure Map

**SQL:**
- `sql/migrations/repeatable/R__Audit_FailureLog_List.sql` — edit (add `@FailureReasonLike`, TOP 1000, `COUNT(*) OVER()`)
- `sql/migrations/repeatable/R__Audit_ConfigLog_List.sql` — edit (add `@DescriptionLike`, `@LogSeverityCode`, TOP 1000, `COUNT(*) OVER()`)
- `sql/migrations/repeatable/R__Audit_FailureLog_DistinctProcedures.sql` — new

**SQL tests:**
- `sql/tests/02_audit_readers/070_FailureLog_List.sql` — extend
- `sql/tests/02_audit_readers/050_ConfigLog_List.sql` — extend
- `sql/tests/02_audit_readers/100_FailureLog_DistinctProcedures.sql` — new

**Named queries** (`ignition/projects/MPP_Config/ignition/named-query/audit/<name>/`):
- 9 new folders, each with `query.sql` + `resource.json`:
  - `ConfigLog_List`, `ConfigLog_GetByEntity`
  - `FailureLog_List`, `FailureLog_GetByEntity`, `FailureLog_GetTopReasons`, `FailureLog_GetTopProcs`, `FailureLog_DistinctProcedures`
  - `LogEntityType_List`, `LogSeverity_List`

**Entity scripts** (`ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/<module>/`):
- `LogEntityType/code.py` — `list()`
- `LogSeverity/code.py` — `list()`
- `FailureLog/code.py` — `search(filter)`, `getByEntity(typeCode, entityId)`, `distinctProcedures()`
- `ConfigLog/code.py` — `search(filter)`, `getByEntity(typeCode, entityId)`

**Views** (`ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/`):
- New: `Components/Popups/FailureDetail/{view.json, resource.json}`
- New: `Components/Popups/ConfigChangeDetail/{view.json, resource.json}`
- New: `Components/Audit/TopRow/{view.json, resource.json}` — single reusable sub-view for both Top Reasons + Top Procs tile rows (param-driven)
- Edit: `Views/Audit/FailureLog/view.json` — wire bindings + handlers
- Edit: `Views/Audit/AuditLog/view.json` — wire bindings + handlers

**Total:** 11 SQL/NQ/script tasks + 5 view tasks + final smoke test = ~17 tasks.

---

## Task 1: Extend `Audit.FailureLog_List` — add LIKE filter + TOP 1000 + COUNT(*) OVER()

**Files:**
- Modify: `sql/migrations/repeatable/R__Audit_FailureLog_List.sql`
- Modify: `sql/tests/02_audit_readers/070_FailureLog_List.sql`

- [ ] **Step 1: Read current proc to confirm the existing param shape**

Run: `Read sql/migrations/repeatable/R__Audit_FailureLog_List.sql`

Note the current parameter list and SELECT column set. The edit preserves all existing params and columns; we're adding `@FailureReasonLike` + `TOP 1000` + a new `TotalCount` column.

- [ ] **Step 2: Add failing test for the LIKE filter**

Append to `sql/tests/02_audit_readers/070_FailureLog_List.sql` (before the existing `EXEC test.PrintSummary` / file-end):

```sql
-- =============================================
-- Test: @FailureReasonLike substring match
-- =============================================
-- Seed two FailureLog rows with distinct reasons via Audit_LogFailure
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'duplicate code abc',
    @ProcedureName       = N'test.LikeProc',
    @AttemptedParameters = N'{}';
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'invalid parent',
    @ProcedureName       = N'test.LikeProc',
    @AttemptedParameters = N'{}';
GO

DECLARE @Start DATETIME2(3) = DATEADD(MINUTE, -5, SYSUTCDATETIME());
DECLARE @End   DATETIME2(3) = SYSUTCDATETIME();
CREATE TABLE #FL_Like (
    Id BIGINT, AttemptedAt DATETIME2(3), AppUserId BIGINT, UserDisplayName NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50), LogEntityTypeName NVARCHAR(100),
    EntityId BIGINT, LogEventTypeId BIGINT, LogEventTypeCode NVARCHAR(50),
    FailureReason NVARCHAR(500), ProcedureName NVARCHAR(200), AttemptedParameters NVARCHAR(MAX),
    TotalCount INT
);
INSERT INTO #FL_Like EXEC Audit.FailureLog_List
    @StartDate         = @Start,
    @EndDate           = @End,
    @FailureReasonLike = N'duplicate';

DECLARE @LikeCount INT;
SELECT @LikeCount = COUNT(*) FROM #FL_Like;
DECLARE @LikeCountStr NVARCHAR(10) = CAST(@LikeCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'FailureLog_List @FailureReasonLike: only matching rows returned',
    @Expected = N'1',
    @Actual   = @LikeCountStr;

DECLARE @MatchedReason NVARCHAR(500);
SELECT TOP 1 @MatchedReason = FailureReason FROM #FL_Like;
EXEC test.Assert_Contains
    @TestName    = N'FailureLog_List @FailureReasonLike: matched reason contains substring',
    @HaystackStr = @MatchedReason,
    @NeedleStr   = N'duplicate';
DROP TABLE #FL_Like;
GO
```

- [ ] **Step 3: Run test suite to confirm new tests fail**

Run: `powershell -ExecutionPolicy Bypass -File sql\tests\Run-Tests.ps1 2>&1 | Select-String -Pattern "070_FailureLog_List"`

Expected: at least one FAIL line referencing the new tests (proc doesn't yet accept `@FailureReasonLike`).

- [ ] **Step 4: Update the proc to accept `@FailureReasonLike`, add `TOP 1000`, add `COUNT(*) OVER() AS TotalCount`**

Replace the entire body of `sql/migrations/repeatable/R__Audit_FailureLog_List.sql` with:

```sql
-- =============================================
-- Procedure:   Audit.FailureLog_List
-- Author:      Blue Ridge Automation
-- Description:
--   Paged, filterable list of rejected mutation attempts. Drives the
--   FailureLog Browser in the Configuration Tool (FDS-11-004).
--
--   Returns TOP 1000 rows ordered by AttemptedAt DESC so the
--   ia.display.table component handles client-side paging within a
--   bounded result. A COUNT(*) OVER() column on every row reports the
--   full unbounded count so the UI can render
--   "Showing 1000 of 24,317 -- narrow your filter".
--
-- Parameters:
--   @StartDate         DATETIME2(3) - inclusive lower bound
--   @EndDate           DATETIME2(3) - inclusive upper bound (treated as
--                                     "end of day" via < DATEADD(day, 1, @EndDate))
--   @LogEntityTypeCode NVARCHAR(50) NULL - exact match
--   @AppUserId         BIGINT       NULL - exact match
--   @ProcedureName     NVARCHAR(200) NULL - exact match
--   @FailureReasonLike NVARCHAR(500) NULL - substring match via LIKE '%X%'
--
-- Result set: top 1000 rows + TotalCount window aggregate.
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_List
    @StartDate           DATETIME2(3),
    @EndDate             DATETIME2(3),
    @LogEntityTypeCode   NVARCHAR(50)  = NULL,
    @AppUserId           BIGINT        = NULL,
    @ProcedureName       NVARCHAR(200) = NULL,
    @FailureReasonLike   NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1000
        fl.Id,
        fl.AttemptedAt,
        fl.AppUserId,
        au.DisplayName               AS UserDisplayName,
        let.Code                     AS LogEntityTypeCode,
        let.Name                     AS LogEntityTypeName,
        fl.EntityId,
        fl.LogEventTypeId,
        lev.Code                     AS LogEventTypeCode,
        fl.FailureReason,
        fl.ProcedureName,
        fl.AttemptedParameters,
        COUNT(*) OVER()              AS TotalCount
    FROM Audit.FailureLog fl
    INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
    LEFT JOIN  Audit.LogEventType  lev ON lev.Id = fl.LogEventTypeId
    LEFT JOIN  Location.AppUser    au  ON au.Id  = fl.AppUserId
    WHERE fl.AttemptedAt >= @StartDate
      AND fl.AttemptedAt <  DATEADD(day, 1, @EndDate)
      AND (@LogEntityTypeCode IS NULL OR let.Code = @LogEntityTypeCode)
      AND (@AppUserId         IS NULL OR fl.AppUserId = @AppUserId)
      AND (@ProcedureName     IS NULL OR fl.ProcedureName = @ProcedureName)
      AND (@FailureReasonLike IS NULL OR fl.FailureReason LIKE N'%' + @FailureReasonLike + N'%')
    ORDER BY fl.AttemptedAt DESC;
END;
GO
```

**Note on existing column shape:** the old proc may have a slightly different column projection than shown above. Run the test in Step 5 to find any mismatches between the existing test's expected columns and this new SELECT; if the existing tests rely on a column name that's been renamed here (e.g., `Username` vs `UserDisplayName`), update the existing tests to match the new canonical shape. The point is to produce one stable column set that the entity script will consume.

- [ ] **Step 5: Run reset + tests to verify pass**

Run: `powershell -ExecutionPolicy Bypass -File sql\tests\Run-Tests.ps1 2>&1 | Out-File -Encoding utf8 .tmp_test_run.log; Get-Content .tmp_test_run.log | Select-String -Pattern "FAIL|Test run" | Select-Object -Last 10`

Expected: `Test run PASSED.` with no FAIL lines.

If any FAIL lines reference column-name changes in the existing FailureLog_List tests (Steps 1's "Note on existing column shape"), edit those existing assertions to match the new column names. Re-run until clean.

- [ ] **Step 6: Cleanup + commit**

```bash
rm .tmp_test_run.log
git add sql/migrations/repeatable/R__Audit_FailureLog_List.sql sql/tests/02_audit_readers/070_FailureLog_List.sql
git commit -m "feat(audit): FailureLog_List adds @FailureReasonLike, TOP 1000, TotalCount window"
```

---

## Task 2: Extend `Audit.ConfigLog_List` — add LIKE filter + Severity filter + TOP 1000 + COUNT(*) OVER()

**Files:**
- Modify: `sql/migrations/repeatable/R__Audit_ConfigLog_List.sql`
- Modify: `sql/tests/02_audit_readers/050_ConfigLog_List.sql`

- [ ] **Step 1: Read current proc**

Run: `Read sql/migrations/repeatable/R__Audit_ConfigLog_List.sql`

- [ ] **Step 2: Add failing test for the new filters**

Append to `sql/tests/02_audit_readers/050_ConfigLog_List.sql` before file end:

```sql
-- =============================================
-- Test: @DescriptionLike substring match + @LogSeverityCode filter
-- =============================================
-- Seed two ConfigLog rows via the shared writer
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = 1,
    @LogEntityTypeCode = N'Location',
    @EntityId          = NULL,
    @LogEventTypeCode  = N'Created',
    @LogSeverityCode   = N'Info',
    @Description       = N'Location created for SaveAll harness',
    @OldValue          = NULL,
    @NewValue          = N'{}';
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = 1,
    @LogEntityTypeCode = N'Location',
    @EntityId          = NULL,
    @LogEventTypeCode  = N'Updated',
    @LogSeverityCode   = N'Warning',
    @Description       = N'Unrelated config event',
    @OldValue          = NULL,
    @NewValue          = N'{}';
GO

DECLARE @Start DATETIME2(3) = DATEADD(MINUTE, -5, SYSUTCDATETIME());
DECLARE @End   DATETIME2(3) = SYSUTCDATETIME();
CREATE TABLE #CL_Like (
    Id BIGINT, ChangedAt DATETIME2(3), AppUserId BIGINT, UserDisplayName NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50), LogEntityTypeName NVARCHAR(100),
    EntityId BIGINT, LogEventTypeId BIGINT, LogEventTypeCode NVARCHAR(50),
    LogSeverityId BIGINT, LogSeverityCode NVARCHAR(50),
    Description NVARCHAR(500), OldValue NVARCHAR(MAX), NewValue NVARCHAR(MAX),
    TotalCount INT
);
INSERT INTO #CL_Like EXEC Audit.ConfigLog_List
    @StartDate       = @Start,
    @EndDate         = @End,
    @DescriptionLike = N'SaveAll';

DECLARE @LikeCount INT;
SELECT @LikeCount = COUNT(*) FROM #CL_Like;
DECLARE @LikeCountStr NVARCHAR(10) = CAST(@LikeCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'ConfigLog_List @DescriptionLike: only matching row returned',
    @Expected = N'1',
    @Actual   = @LikeCountStr;
DROP TABLE #CL_Like;

-- Severity filter
CREATE TABLE #CL_Sev (
    Id BIGINT, ChangedAt DATETIME2(3), AppUserId BIGINT, UserDisplayName NVARCHAR(200),
    LogEntityTypeCode NVARCHAR(50), LogEntityTypeName NVARCHAR(100),
    EntityId BIGINT, LogEventTypeId BIGINT, LogEventTypeCode NVARCHAR(50),
    LogSeverityId BIGINT, LogSeverityCode NVARCHAR(50),
    Description NVARCHAR(500), OldValue NVARCHAR(MAX), NewValue NVARCHAR(MAX),
    TotalCount INT
);
INSERT INTO #CL_Sev EXEC Audit.ConfigLog_List
    @StartDate       = @Start,
    @EndDate         = @End,
    @LogSeverityCode = N'Warning';

DECLARE @SevCount INT;
SELECT @SevCount = COUNT(*) FROM #CL_Sev WHERE LogSeverityCode = N'Warning';
DECLARE @SevCountStr NVARCHAR(10) = CAST(@SevCount AS NVARCHAR(10));
EXEC test.Assert_IsTrue
    @TestName = N'ConfigLog_List @LogSeverityCode: returns at least one Warning row',
    @Condition = CAST(IIF(@SevCount >= 1, 1, 0) AS BIT);
DROP TABLE #CL_Sev;
GO
```

- [ ] **Step 3: Run tests to confirm failures**

Run: `powershell -ExecutionPolicy Bypass -File sql\tests\Run-Tests.ps1 2>&1 | Select-String -Pattern "050_ConfigLog_List|FAIL" | Select-Object -First 20`

Expected: FAIL lines for the new tests.

- [ ] **Step 4: Update the proc**

Replace `sql/migrations/repeatable/R__Audit_ConfigLog_List.sql` with:

```sql
-- =============================================
-- Procedure:   Audit.ConfigLog_List
-- Author:      Blue Ridge Automation
-- Description:
--   Paged, filterable list of successful configuration mutations.
--   Drives the AuditLog Browser in the Configuration Tool (FDS-11-002).
--
--   Returns TOP 1000 ordered by ChangedAt DESC with COUNT(*) OVER()
--   for "Showing N of M -- narrow your filter" banner support.
--
-- Parameters:
--   @StartDate         DATETIME2(3) - inclusive
--   @EndDate           DATETIME2(3) - inclusive (end-of-day)
--   @LogEntityTypeCode NVARCHAR(50) NULL
--   @AppUserId         BIGINT       NULL
--   @LogSeverityCode   NVARCHAR(50) NULL
--   @DescriptionLike   NVARCHAR(500) NULL - substring LIKE '%X%'
-- =============================================
CREATE OR ALTER PROCEDURE Audit.ConfigLog_List
    @StartDate           DATETIME2(3),
    @EndDate             DATETIME2(3),
    @LogEntityTypeCode   NVARCHAR(50)  = NULL,
    @AppUserId           BIGINT        = NULL,
    @LogSeverityCode     NVARCHAR(50)  = NULL,
    @DescriptionLike     NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1000
        cl.Id,
        cl.ChangedAt,
        cl.AppUserId,
        au.DisplayName            AS UserDisplayName,
        let.Code                  AS LogEntityTypeCode,
        let.Name                  AS LogEntityTypeName,
        cl.EntityId,
        cl.LogEventTypeId,
        lev.Code                  AS LogEventTypeCode,
        cl.LogSeverityId,
        ls.Code                   AS LogSeverityCode,
        cl.Description,
        cl.OldValue,
        cl.NewValue,
        COUNT(*) OVER()           AS TotalCount
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
    LEFT JOIN  Audit.LogEventType  lev ON lev.Id = cl.LogEventTypeId
    LEFT JOIN  Audit.LogSeverity   ls  ON ls.Id  = cl.LogSeverityId
    LEFT JOIN  Location.AppUser    au  ON au.Id  = cl.AppUserId
    WHERE cl.ChangedAt >= @StartDate
      AND cl.ChangedAt <  DATEADD(day, 1, @EndDate)
      AND (@LogEntityTypeCode IS NULL OR let.Code = @LogEntityTypeCode)
      AND (@AppUserId         IS NULL OR cl.AppUserId = @AppUserId)
      AND (@LogSeverityCode   IS NULL OR ls.Code = @LogSeverityCode)
      AND (@DescriptionLike   IS NULL OR cl.Description LIKE N'%' + @DescriptionLike + N'%')
    ORDER BY cl.ChangedAt DESC;
END;
GO
```

**Note:** confirm column names match what existing tests expect; rename in the tests if the canonical shape changed. (Same warning as Task 1.)

- [ ] **Step 5: Run tests**

Run: `powershell -ExecutionPolicy Bypass -File sql\tests\Run-Tests.ps1 2>&1 | Out-File -Encoding utf8 .tmp_test_run.log; Get-Content .tmp_test_run.log | Select-String -Pattern "FAIL|Test run" | Select-Object -Last 10`

Expected: `Test run PASSED.`

Fix any column-name mismatches in existing tests, re-run.

- [ ] **Step 6: Commit**

```bash
rm .tmp_test_run.log
git add sql/migrations/repeatable/R__Audit_ConfigLog_List.sql sql/tests/02_audit_readers/050_ConfigLog_List.sql
git commit -m "feat(audit): ConfigLog_List adds @DescriptionLike, @LogSeverityCode, TOP 1000, TotalCount"
```

---

## Task 3: New `Audit.FailureLog_DistinctProcedures` proc + tests

**Files:**
- Create: `sql/migrations/repeatable/R__Audit_FailureLog_DistinctProcedures.sql`
- Create: `sql/tests/02_audit_readers/100_FailureLog_DistinctProcedures.sql`

- [ ] **Step 1: Write the failing test**

Create `sql/tests/02_audit_readers/100_FailureLog_DistinctProcedures.sql`:

```sql
-- =============================================
-- File:         02_audit_readers/100_FailureLog_DistinctProcedures.sql
-- Description:  Tests for Audit.FailureLog_DistinctProcedures (proc
--               returns DISTINCT ProcedureName across all FailureLog
--               rows, sorted ascending, no NULLs).
-- =============================================

EXEC test.BeginTestFile @FileName = N'02_audit_readers/100_FailureLog_DistinctProcedures.sql';
GO

-- Seed 3 failure rows with 2 distinct procedure names + 1 NULL proc name
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test reason A',
    @ProcedureName       = N'test.ProcAlpha',
    @AttemptedParameters = N'{}';
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test reason A2',
    @ProcedureName       = N'test.ProcAlpha',
    @AttemptedParameters = N'{}';
EXEC Audit.Audit_LogFailure
    @AppUserId           = 1,
    @LogEntityTypeCode   = N'Location',
    @EntityId            = NULL,
    @LogEventTypeCode    = N'Created',
    @FailureReason       = N'Test reason B',
    @ProcedureName       = N'test.ProcBravo',
    @AttemptedParameters = N'{}';
GO

CREATE TABLE #DP (ProcedureName NVARCHAR(200));
INSERT INTO #DP EXEC Audit.FailureLog_DistinctProcedures;

DECLARE @AlphaCount INT;
SELECT @AlphaCount = COUNT(*) FROM #DP WHERE ProcedureName = N'test.ProcAlpha';
DECLARE @AlphaCountStr NVARCHAR(10) = CAST(@AlphaCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'DistinctProcedures: test.ProcAlpha appears once',
    @Expected = N'1',
    @Actual   = @AlphaCountStr;

DECLARE @BravoCount INT;
SELECT @BravoCount = COUNT(*) FROM #DP WHERE ProcedureName = N'test.ProcBravo';
DECLARE @BravoCountStr NVARCHAR(10) = CAST(@BravoCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'DistinctProcedures: test.ProcBravo appears once',
    @Expected = N'1',
    @Actual   = @BravoCountStr;

DECLARE @NullCount INT;
SELECT @NullCount = COUNT(*) FROM #DP WHERE ProcedureName IS NULL;
DECLARE @NullCountStr NVARCHAR(10) = CAST(@NullCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'DistinctProcedures: no NULL entries returned',
    @Expected = N'0',
    @Actual   = @NullCountStr;

DROP TABLE #DP;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run tests to confirm failure (proc doesn't exist yet)**

Run: `powershell -ExecutionPolicy Bypass -File sql\tests\Run-Tests.ps1 2>&1 | Select-String -Pattern "100_FailureLog_DistinctProcedures|FAIL" | Select-Object -First 10`

Expected: ERROR or FAIL lines indicating the proc doesn't exist yet.

- [ ] **Step 3: Create the proc**

Create `sql/migrations/repeatable/R__Audit_FailureLog_DistinctProcedures.sql`:

```sql
-- =============================================
-- Procedure:   Audit.FailureLog_DistinctProcedures
-- Author:      Blue Ridge Automation
-- Created:     2026-05-19
-- Description:
--   Returns the distinct list of ProcedureName values ever logged to
--   Audit.FailureLog (excluding NULLs), sorted ascending. Drives the
--   Procedure dropdown on the FailureLog Browser. No date param --
--   the dropdown shows every proc ever logged so operators can filter
--   without first having to narrow by date.
--
--   Cheap query -- procs are a closed set of code paths (~50-100
--   entries project-lifetime). Result set is small.
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_DistinctProcedures
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT ProcedureName
    FROM Audit.FailureLog
    WHERE ProcedureName IS NOT NULL
    ORDER BY ProcedureName;
END;
GO
```

- [ ] **Step 4: Run tests to verify pass**

Run: `powershell -ExecutionPolicy Bypass -File sql\tests\Run-Tests.ps1 2>&1 | Out-File -Encoding utf8 .tmp_test_run.log; Get-Content .tmp_test_run.log | Select-String -Pattern "FAIL|Test run" | Select-Object -Last 10`

Expected: `Test run PASSED.`

- [ ] **Step 5: Commit**

```bash
rm .tmp_test_run.log
git add sql/migrations/repeatable/R__Audit_FailureLog_DistinctProcedures.sql sql/tests/02_audit_readers/100_FailureLog_DistinctProcedures.sql
git commit -m "feat(audit): new Audit.FailureLog_DistinctProcedures proc + tests"
```

---

## Task 4: Named queries — 9 audit/ NQs

**Files:** All under `ignition/projects/MPP_Config/ignition/named-query/audit/<name>/{query.sql, resource.json}`.

Each NQ is a thin `EXEC` wrapper. All `version: 2` schema. Designer-canonical sqlType codes (3=Int8/BIGINT, 7=String/NVARCHAR, 8=DateTime, 2=Int4/INT).

- [ ] **Step 1: Reference an existing audit NQ's `resource.json` shape**

Look at any existing v2 NQ resource.json (e.g., `location/Location_SaveAll/resource.json`) for the canonical shape. Copy the structure for each new NQ; only `parameters` block changes.

- [ ] **Step 2: Create `audit/ConfigLog_List/`**

Create `ignition/projects/MPP_Config/ignition/named-query/audit/ConfigLog_List/query.sql`:

```sql
EXEC Audit.ConfigLog_List
    @StartDate         = :startDate,
    @EndDate           = :endDate,
    @LogEntityTypeCode = :logEntityTypeCode,
    @AppUserId         = :appUserId,
    @LogSeverityCode   = :logSeverityCode,
    @DescriptionLike   = :descriptionLike
```

Create `ignition/projects/MPP_Config/ignition/named-query/audit/ConfigLog_List/resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": ["query.sql"],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [{ "zone": "", "role": "" }],
    "lastModification": { "actor": "claude", "timestamp": "2026-05-19T10:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "startDate",         "sqlType": 8 },
      { "type": "Parameter", "identifier": "endDate",           "sqlType": 8 },
      { "type": "Parameter", "identifier": "logEntityTypeCode", "sqlType": 7 },
      { "type": "Parameter", "identifier": "appUserId",         "sqlType": 3 },
      { "type": "Parameter", "identifier": "logSeverityCode",   "sqlType": 7 },
      { "type": "Parameter", "identifier": "descriptionLike",   "sqlType": 7 }
    ]
  }
}
```

- [ ] **Step 3: Create `audit/ConfigLog_GetByEntity/`**

`query.sql`:

```sql
EXEC Audit.ConfigLog_GetByEntity
    @LogEntityTypeCode = :logEntityTypeCode,
    @EntityId          = :entityId
```

`resource.json` — same shape as Step 2 with parameters:
```json
"parameters": [
  { "type": "Parameter", "identifier": "logEntityTypeCode", "sqlType": 7 },
  { "type": "Parameter", "identifier": "entityId",          "sqlType": 3 }
]
```

- [ ] **Step 4: Create `audit/FailureLog_List/`**

`query.sql`:

```sql
EXEC Audit.FailureLog_List
    @StartDate         = :startDate,
    @EndDate           = :endDate,
    @LogEntityTypeCode = :logEntityTypeCode,
    @AppUserId         = :appUserId,
    @ProcedureName     = :procedureName,
    @FailureReasonLike = :failureReasonLike
```

`resource.json` — same shape, parameters:
```json
"parameters": [
  { "type": "Parameter", "identifier": "startDate",         "sqlType": 8 },
  { "type": "Parameter", "identifier": "endDate",           "sqlType": 8 },
  { "type": "Parameter", "identifier": "logEntityTypeCode", "sqlType": 7 },
  { "type": "Parameter", "identifier": "appUserId",         "sqlType": 3 },
  { "type": "Parameter", "identifier": "procedureName",     "sqlType": 7 },
  { "type": "Parameter", "identifier": "failureReasonLike", "sqlType": 7 }
]
```

- [ ] **Step 5: Create `audit/FailureLog_GetByEntity/`**

`query.sql`:

```sql
EXEC Audit.FailureLog_GetByEntity
    @LogEntityTypeCode = :logEntityTypeCode,
    @EntityId          = :entityId
```

parameters same as Step 3.

- [ ] **Step 6: Create `audit/FailureLog_GetTopReasons/`**

`query.sql`:

```sql
EXEC Audit.FailureLog_GetTopReasons
    @StartDate         = :startDate,
    @EndDate           = :endDate,
    @LogEntityTypeCode = :logEntityTypeCode
```

parameters:
```json
[
  { "type": "Parameter", "identifier": "startDate",         "sqlType": 8 },
  { "type": "Parameter", "identifier": "endDate",           "sqlType": 8 },
  { "type": "Parameter", "identifier": "logEntityTypeCode", "sqlType": 7 }
]
```

- [ ] **Step 7: Create `audit/FailureLog_GetTopProcs/`**

`query.sql`:

```sql
EXEC Audit.FailureLog_GetTopProcs
    @StartDate = :startDate,
    @EndDate   = :endDate
```

parameters:
```json
[
  { "type": "Parameter", "identifier": "startDate", "sqlType": 8 },
  { "type": "Parameter", "identifier": "endDate",   "sqlType": 8 }
]
```

- [ ] **Step 8: Create `audit/FailureLog_DistinctProcedures/`**

`query.sql`:

```sql
EXEC Audit.FailureLog_DistinctProcedures
```

parameters: empty array `[]`.

- [ ] **Step 9: Create `audit/LogEntityType_List/`**

`query.sql`:

```sql
EXEC Audit.LogEntityType_List
```

parameters: empty array `[]`.

- [ ] **Step 10: Create `audit/LogSeverity_List/`**

`query.sql`:

```sql
EXEC Audit.LogSeverity_List
```

parameters: empty array `[]`.

- [ ] **Step 11: Trigger gateway scan**

Run: `powershell -ExecutionPolicy Bypass -File scan.ps1`

Expected: `scanActive: true` then `scanActive: false` within ~500ms.

- [ ] **Step 12: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/named-query/audit/
git commit -m "feat(audit): 9 NQ wrappers for FailureLog + ConfigLog + LogEntityType + LogSeverity"
```

---

## Task 5: Entity script — `BlueRidge.Audit.LogEntityType`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogEntityType/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogEntityType/resource.json`

- [ ] **Step 1: Create resource.json**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogEntityType/resource.json`

```json
{
  "scope": "A",
  "version": 1,
  "files": ["code.py"],
  "attributes": {
    "hintScope": 2,
    "lastModification": { "actor": "claude", "timestamp": "2026-05-19T10:00:00Z" }
  }
}
```

- [ ] **Step 2: Create code.py**

Path: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogEntityType/code.py`

```python
# =============================================================================
# Project Library:  BlueRidge.Audit.LogEntityType
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read-side helper for Audit.LogEntityType. Drives the EntityType
#   dropdown on the AuditLog + FailureLog Browser pages.
#
# Public surface:
#   list() -> list[dict]
# =============================================================================


def list():
    """
    Returns all LogEntityType rows, ordered by Name. Used to populate
    the EntityType dropdown.

    Returns:
        list[dict]: rows with keys Id, Code, Name. Empty list on failure.
    """
    BlueRidge.Common.Util.log("loading log-entity types")
    try:
        return BlueRidge.Common.Db.execList("audit/LogEntityType_List")
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load entity types", str(e), "error")
        return []
```

- [ ] **Step 3: Trigger scan**

Run: `powershell -ExecutionPolicy Bypass -File scan.ps1`

- [ ] **Step 4: Smoke-test in Script Console**

In Designer's Script Console:
```python
result = BlueRidge.Audit.LogEntityType.list()
print "count:", len(result)
print "first:", result[0] if result else None
```

Expected: count > 0 (LogEntityType is seeded — Location, LocationTypeDefinition, AppUser, etc.). First row is a dict with Id, Code, Name.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogEntityType/
git commit -m "feat(audit): BlueRidge.Audit.LogEntityType.list() for EntityType dropdown"
```

---

## Task 6: Entity script — `BlueRidge.Audit.LogSeverity`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogSeverity/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogSeverity/resource.json`

- [ ] **Step 1: Create resource.json (mirror of Task 5)**

Same structure as Task 5 Step 1 with path `.../LogSeverity/resource.json`.

- [ ] **Step 2: Create code.py**

Path: `.../LogSeverity/code.py`

```python
# =============================================================================
# Project Library:  BlueRidge.Audit.LogSeverity
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read-side helper for Audit.LogSeverity. Drives the Severity dropdown
#   on the AuditLog Browser page (FailureLog doesn't have severity).
#
# Public surface:
#   list() -> list[dict]
# =============================================================================


def list():
    """Returns all LogSeverity rows (Info / Warning / Error). Empty list on failure."""
    BlueRidge.Common.Util.log("loading log severities")
    try:
        return BlueRidge.Common.Db.execList("audit/LogSeverity_List")
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load severities", str(e), "error")
        return []
```

- [ ] **Step 3: Scan + smoke-test**

```python
result = BlueRidge.Audit.LogSeverity.list()
print result
```

Expected: 3 rows (Info, Warning, Error).

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/LogSeverity/
git commit -m "feat(audit): BlueRidge.Audit.LogSeverity.list() for Severity dropdown"
```

---

## Task 7: Entity script — `BlueRidge.Audit.FailureLog`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/FailureLog/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/FailureLog/resource.json`

- [ ] **Step 1: Create resource.json**

Same shape as Task 5, path `.../FailureLog/resource.json`.

- [ ] **Step 2: Create code.py**

Path: `.../FailureLog/code.py`

```python
# =============================================================================
# Project Library:  BlueRidge.Audit.FailureLog
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read surface for the FailureLog Browser page (FDS-11-004). Three
#   public functions:
#
#   search(filter)                  -> {rows, totalCount, topReasons, topProcs}
#   getByEntity(typeCode, entityId) -> list[dict]
#   distinctProcedures()            -> list[dict]
#
#   search() bundles 3 NQ calls (List + GetTopReasons + GetTopProcs) so
#   the view's Apply handler stays a one-liner. The List proc returns
#   TOP 1000 with COUNT(*) OVER() as TotalCount in every row -- search()
#   strips that column out of the body rows and surfaces it once at the
#   top level.
#
#   The filter dict is deep-unwrapped at entry via Common.Util
#   .extractQualifiedValues to defend against any future caller (tile
#   click, bidirectional binding) handing in QualifiedValue-wrapped
#   fields. See feedback_ignition_tree_qv_unwrap.md.
#
# Layer:
#   View -> BlueRidge.Audit.FailureLog (this module)
#        -> BlueRidge.Common.Db.execList
# =============================================================================


def _u(value):
    """Deep-unwrap shorthand. See feedback_ignition_tree_qv_unwrap.md."""
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filter):
    """
    Bundled search for the FailureLog Browser. Issues 3 NQ calls and
    returns a single result dict the view writes atomically into
    view.custom.{rows, totalCount, topReasons, topProcs}.

    Args:
        filter (dict): startDate, endDate, entityTypeCode, procedureName,
                       appUserId, searchText. None / empty values mean
                       "no filter on this field."

    Returns:
        dict: {
            "rows":        list[dict] -- up to 1000 FailureLog rows,
                                        TotalCount column stripped out
            "totalCount":  int        -- full unbounded count for banner
            "topReasons":  list[dict] -- top 5 by FailureReason
            "topProcs":    list[dict] -- top 5 by ProcedureName
        }
        On any exception, returns the same shape with empty lists and
        a toast surfaces the error.
    """
    f = _u(filter) or {}
    BlueRidge.Common.Util.log("search filter=%s" % f)

    try:
        listParams = {
            "startDate":         f.get("startDate"),
            "endDate":           f.get("endDate"),
            "logEntityTypeCode": f.get("entityTypeCode"),
            "appUserId":         f.get("appUserId"),
            "procedureName":     f.get("procedureName"),
            "failureReasonLike": (f.get("searchText") or None),
        }
        rows = BlueRidge.Common.Db.execList("audit/FailureLog_List", listParams)

        # COUNT(*) OVER() rides on every row -- pull it off the first
        # row, then strip the column out of the body to keep the table
        # schema clean.
        totalCount = rows[0]["TotalCount"] if rows else 0
        for r in rows:
            if "TotalCount" in r:
                del r["TotalCount"]

        tileParams = {
            "startDate":         f.get("startDate"),
            "endDate":           f.get("endDate"),
            "logEntityTypeCode": f.get("entityTypeCode"),
        }
        topReasons = BlueRidge.Common.Db.execList(
            "audit/FailureLog_GetTopReasons", tileParams
        )
        topProcs = BlueRidge.Common.Db.execList(
            "audit/FailureLog_GetTopProcs",
            {"startDate": f.get("startDate"), "endDate": f.get("endDate")},
        )

        return {
            "rows":       rows,
            "totalCount": totalCount,
            "topReasons": topReasons,
            "topProcs":   topProcs,
        }
    except Exception as e:
        BlueRidge.Common.Util.log("search failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Search failed", str(e), "error")
        return {"rows": [], "totalCount": 0, "topReasons": [], "topProcs": []}


def getByEntity(typeCode, entityId):
    """
    Returns every FailureLog row for a specific entity. Drives the
    "View Rejection History" drill-down from entity Config Tool screens
    (future polish pass).
    """
    typeCode = _u(typeCode)
    entityId = _u(entityId)
    BlueRidge.Common.Util.log("typeCode=%s entityId=%s" % (typeCode, entityId))
    if not typeCode or entityId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "audit/FailureLog_GetByEntity",
            {"logEntityTypeCode": typeCode, "entityId": entityId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getByEntity failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Lookup failed", str(e), "error")
        return []


def distinctProcedures():
    """
    Returns the distinct list of ProcedureName values for the Procedure
    dropdown. All-time distinct (no date param) -- the result set is
    small (a closed set of code paths) and cheap.

    Returns:
        list[dict]: each row {"ProcedureName": str}
    """
    BlueRidge.Common.Util.log("loading distinct procedures")
    try:
        return BlueRidge.Common.Db.execList("audit/FailureLog_DistinctProcedures")
    except Exception as e:
        BlueRidge.Common.Util.log("distinctProcedures failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load procedures", str(e), "error")
        return []
```

- [ ] **Step 3: Scan + smoke-test**

```python
import system
now = system.date.now()
weekAgo = system.date.addDays(now, -7)
filter = {
    "startDate":      weekAgo,
    "endDate":        now,
    "entityTypeCode": None,
    "procedureName":  None,
    "appUserId":      None,
    "searchText":     "",
}
result = BlueRidge.Audit.FailureLog.search(filter)
print "rows:",       len(result["rows"])
print "totalCount:", result["totalCount"]
print "topReasons:", len(result["topReasons"])
print "topProcs:",   len(result["topProcs"])
```

Expected: a result dict with the 4 keys. Counts may be 0 if no failures in the last 7 days; structure should be valid.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/FailureLog/
git commit -m "feat(audit): BlueRidge.Audit.FailureLog (search + getByEntity + distinctProcedures)"
```

---

## Task 8: Entity script — `BlueRidge.Audit.ConfigLog`

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/ConfigLog/code.py`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/ConfigLog/resource.json`

- [ ] **Step 1: Create resource.json (mirror)**

- [ ] **Step 2: Create code.py**

Path: `.../ConfigLog/code.py`

```python
# =============================================================================
# Project Library:  BlueRidge.Audit.ConfigLog
#
# Author:           Blue Ridge Automation
# Created:          2026-05-19
# Version:          1.0
#
# Description:
#   Read surface for the AuditLog Browser page (FDS-11-002). Parallel
#   to BlueRidge.Audit.FailureLog but ConfigLog has no equivalent of the
#   Top Reasons / Top Procs aggregations -- it only logs successes, so
#   "top rejection reasons" wouldn't make sense. search() therefore
#   returns just {rows, totalCount}.
#
# Public surface:
#   search(filter)                  -> {rows, totalCount}
#   getByEntity(typeCode, entityId) -> list[dict]
# =============================================================================


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filter):
    """
    Args:
        filter (dict): startDate, endDate, entityTypeCode, logSeverityCode,
                       appUserId, searchText.

    Returns:
        dict: {"rows": list[dict], "totalCount": int}. Empty rows + 0
              count on exception (toast fires).
    """
    f = _u(filter) or {}
    BlueRidge.Common.Util.log("search filter=%s" % f)
    try:
        params = {
            "startDate":         f.get("startDate"),
            "endDate":           f.get("endDate"),
            "logEntityTypeCode": f.get("entityTypeCode"),
            "appUserId":         f.get("appUserId"),
            "logSeverityCode":   f.get("logSeverityCode"),
            "descriptionLike":   (f.get("searchText") or None),
        }
        rows = BlueRidge.Common.Db.execList("audit/ConfigLog_List", params)
        totalCount = rows[0]["TotalCount"] if rows else 0
        for r in rows:
            if "TotalCount" in r:
                del r["TotalCount"]
        return {"rows": rows, "totalCount": totalCount}
    except Exception as e:
        BlueRidge.Common.Util.log("search failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Search failed", str(e), "error")
        return {"rows": [], "totalCount": 0}


def getByEntity(typeCode, entityId):
    """Every ConfigLog row for a specific entity (drill-down support)."""
    typeCode = _u(typeCode)
    entityId = _u(entityId)
    BlueRidge.Common.Util.log("typeCode=%s entityId=%s" % (typeCode, entityId))
    if not typeCode or entityId is None:
        return []
    try:
        return BlueRidge.Common.Db.execList(
            "audit/ConfigLog_GetByEntity",
            {"logEntityTypeCode": typeCode, "entityId": entityId},
        )
    except Exception as e:
        BlueRidge.Common.Util.log("getByEntity failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Lookup failed", str(e), "error")
        return []
```

- [ ] **Step 3: Scan + smoke-test**

```python
import system
filter = {
    "startDate":       system.date.addDays(system.date.now(), -7),
    "endDate":         system.date.now(),
    "entityTypeCode":  None,
    "logSeverityCode": None,
    "appUserId":       None,
    "searchText":      "",
}
result = BlueRidge.Audit.ConfigLog.search(filter)
print "rows:", len(result["rows"])
print "totalCount:", result["totalCount"]
```

Expected: rows reflect any ConfigLog activity from the last 7 days (will include all the Location SaveAll activity from this session, so >0).

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/ConfigLog/
git commit -m "feat(audit): BlueRidge.Audit.ConfigLog (search + getByEntity)"
```

---

## Task 9: New view — `BlueRidge/Components/Popups/FailureDetail`

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/FailureDetail/{view.json, resource.json}`

- [ ] **Step 1: Create resource.json**

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModificationSignature": "",
    "lastModification": { "actor": "claude", "timestamp": "2026-05-19T10:00:00Z" }
  }
}
```

- [ ] **Step 2: Create view.json**

Per-row detail popup. Params receive the row data from the FailureTable click handler. Pretty-print AttemptedParameters JSON.

```json
{
  "custom": {},
  "params": {
    "id":                  null,
    "attemptedAt":         null,
    "userDisplayName":     "",
    "logEntityTypeName":   "",
    "entityId":            null,
    "logEventTypeCode":    "",
    "procedureName":       "",
    "failureReason":       "",
    "attemptedParameters": "",
    "popupId":             "mpp-failure-detail"
  },
  "propConfig": {
    "params.id":                  { "paramDirection": "input" },
    "params.attemptedAt":         { "paramDirection": "input" },
    "params.userDisplayName":     { "paramDirection": "input" },
    "params.logEntityTypeName":   { "paramDirection": "input" },
    "params.entityId":            { "paramDirection": "input" },
    "params.logEventTypeCode":    { "paramDirection": "input" },
    "params.procedureName":       { "paramDirection": "input" },
    "params.failureReason":       { "paramDirection": "input" },
    "params.attemptedParameters": { "paramDirection": "input" },
    "params.popupId":             { "paramDirection": "input" }
  },
  "props": {
    "defaultSize": { "width": 720, "height": 560 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "direction": "column",
      "style": {
        "background":    "var(--mpp-surface-canvas)",
        "borderRadius":  "var(--mpp-radius-md, 8px)",
        "height":        "100%",
        "overflow":      "hidden",
        "width":         "100%"
      }
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": { "name": "Header" },
        "position": { "basis": "48px", "shrink": 0 },
        "props": {
          "alignItems": "center",
          "style": {
            "background":   "var(--mpp-surface-raised)",
            "borderBottom": "1px solid var(--mpp-border-subtle)",
            "padding":      "0 16px"
          }
        },
        "children": [
          {
            "type": "ia.display.label",
            "meta": { "name": "Title" },
            "position": { "grow": 1 },
            "props": {
              "style": { "classes": "modal-title", "color": "var(--mpp-text-primary)", "fontSize": "14px", "fontWeight": "600" },
              "text": "Rejection Detail"
            }
          },
          {
            "type": "ia.display.icon",
            "meta": { "name": "CloseIcon" },
            "position": { "basis": "24px", "shrink": 0 },
            "props": { "path": "material/close", "color": "var(--mpp-text-secondary)",
                       "style": { "cursor": "pointer", "height": "20px", "width": "20px" } },
            "events": {
              "dom": {
                "onClick": {
                  "type": "script", "scope": "G",
                  "config": { "script": "\tsystem.perspective.closePopup(id=self.view.params.popupId)" }
                }
              }
            }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "Body" },
        "position": { "basis": "0", "grow": 1 },
        "props": {
          "direction": "column",
          "style": { "gap": "10px", "padding": "16px", "overflow": "auto" }
        },
        "children": [
          {
            "type": "ia.display.label",
            "meta": { "name": "MetaLine" },
            "position": { "shrink": 0 },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "\"Attempted at:  \" + dateFormat({view.params.attemptedAt}, \"yyyy-MM-dd HH:mm:ss\") + \"   |   User:  \" + coalesce({view.params.userDisplayName}, \"(unknown)\") + \"   |   Event:  \" + coalesce({view.params.logEventTypeCode}, \"\")"
                  }
                }
              }
            },
            "props": { "style": { "fontSize": "12px", "color": "var(--mpp-text-secondary)" } }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "EntityLine" },
            "position": { "shrink": 0 },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "\"Procedure:  \" + coalesce({view.params.procedureName}, \"\") + \"   |   Entity:  \" + coalesce({view.params.logEntityTypeName}, \"\") + \"  \\u00B7  \" + coalesce({view.params.entityId}, \"(new)\")"
                  }
                }
              }
            },
            "props": { "style": { "fontSize": "12px", "color": "var(--mpp-text-secondary)" } }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "ReasonHeader" },
            "position": { "shrink": 0 },
            "props": { "text": "Failure Reason",
                       "style": { "fontSize": "11px", "fontWeight": "600", "color": "var(--mpp-text-secondary)", "letterSpacing": "0.05em", "textTransform": "uppercase", "marginTop": "8px" } }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "ReasonText" },
            "position": { "shrink": 0 },
            "propConfig": {
              "props.text": { "binding": { "type": "property", "config": { "path": "view.params.failureReason" } } }
            },
            "props": { "style": { "fontSize": "13px", "color": "var(--mpp-text-primary)", "lineHeight": "1.4" } }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "ParamsHeader" },
            "position": { "shrink": 0 },
            "props": { "text": "Attempted Parameters",
                       "style": { "fontSize": "11px", "fontWeight": "600", "color": "var(--mpp-text-secondary)", "letterSpacing": "0.05em", "textTransform": "uppercase", "marginTop": "8px" } }
          },
          {
            "type": "ia.display.label",
            "meta": { "name": "ParamsBlock" },
            "position": { "basis": "0", "grow": 1, "shrink": 0 },
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "runScript(\"BlueRidge.Common.Util.prettyJson\", 0, {view.params.attemptedParameters})"
                  }
                }
              }
            },
            "props": {
              "style": {
                "background":  "var(--mpp-surface-card)",
                "border":      "1px solid var(--mpp-border-subtle)",
                "borderRadius": "6px",
                "color":       "var(--mpp-text-primary)",
                "fontFamily":  "ui-monospace, Menlo, Consolas, monospace",
                "fontSize":    "11px",
                "lineHeight":  "1.4",
                "overflow":    "auto",
                "padding":     "12px",
                "whiteSpace":  "pre"
              }
            }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "Footer" },
        "position": { "basis": "60px", "shrink": 0 },
        "props": {
          "alignItems": "center",
          "style": {
            "background":   "var(--mpp-surface-raised)",
            "borderTop":    "1px solid var(--mpp-border-subtle)",
            "padding":      "12px 16px"
          }
        },
        "children": [
          { "type": "ia.container.flex", "meta": { "name": "Spacer" }, "position": { "grow": 1 } },
          {
            "type": "ia.input.button",
            "meta": { "name": "CloseButton" },
            "position": { "shrink": 0 },
            "props": { "text": "Close", "style": { "classes": "btn btn-sm" } },
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script", "scope": "G",
                  "config": { "script": "\tsystem.perspective.closePopup(id=self.view.params.popupId)" }
                }
              }
            }
          }
        ]
      }
    ]
  }
}
```

**Note** — the expression uses `runScript("BlueRidge.Common.Util.prettyJson", 0, {view.params.attemptedParameters})` to pretty-print the JSON. We need to add that helper to `Common.Util` — do that in the next step.

- [ ] **Step 3: Add `prettyJson` helper to `Common.Util`**

Read current `Common/Util/code.py` and append:

```python
def prettyJson(jsonString):
    """
    Pretty-print a JSON string with 2-space indentation. Used by audit
    detail popups to render the AttemptedParameters / Old / New JSON
    snapshots in a readable form. On parse failure (malformed JSON, or
    NULL) returns the input unchanged -- the popup shows the raw text
    rather than crashing.

    Args:
        jsonString (str): JSON string to format, or None.

    Returns:
        str: pretty-printed JSON, or the input string if it can't be
             parsed, or empty string if input was None.
    """
    if jsonString is None:
        return ""
    try:
        parsed = system.util.jsonDecode(jsonString)
        return system.util.jsonEncode(parsed, 2)
    except Exception:
        return jsonString
```

Add a one-line entry to the module's header description list.

- [ ] **Step 4: Trigger scan**

Run: `powershell -ExecutionPolicy Bypass -File scan.ps1`

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/FailureDetail/ ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Common/Util/code.py
git commit -m "feat(audit): FailureDetail popup + Common.Util.prettyJson helper"
```

---

## Task 10: New view — `BlueRidge/Components/Popups/ConfigChangeDetail`

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfigChangeDetail/{view.json, resource.json}`

- [ ] **Step 1: Create resource.json (mirror of Task 9)**

Same shape as Task 9 Step 1.

- [ ] **Step 2: Create view.json — same structure as FailureDetail but with OldValue + NewValue blocks**

```json
{
  "custom": {},
  "params": {
    "id":                null,
    "changedAt":         null,
    "userDisplayName":   "",
    "logEntityTypeName": "",
    "entityId":          null,
    "logEventTypeCode":  "",
    "logSeverityCode":   "",
    "description":       "",
    "oldValue":          "",
    "newValue":          "",
    "popupId":           "mpp-config-change-detail"
  },
  "propConfig": {
    "params.id":                { "paramDirection": "input" },
    "params.changedAt":         { "paramDirection": "input" },
    "params.userDisplayName":   { "paramDirection": "input" },
    "params.logEntityTypeName": { "paramDirection": "input" },
    "params.entityId":          { "paramDirection": "input" },
    "params.logEventTypeCode":  { "paramDirection": "input" },
    "params.logSeverityCode":   { "paramDirection": "input" },
    "params.description":       { "paramDirection": "input" },
    "params.oldValue":          { "paramDirection": "input" },
    "params.newValue":          { "paramDirection": "input" },
    "params.popupId":           { "paramDirection": "input" }
  },
  "props": {
    "defaultSize": { "width": 880, "height": 620 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "direction": "column",
      "style": { "background": "var(--mpp-surface-canvas)", "borderRadius": "var(--mpp-radius-md, 8px)", "height": "100%", "overflow": "hidden", "width": "100%" }
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": { "name": "Header" },
        "position": { "basis": "48px", "shrink": 0 },
        "props": {
          "alignItems": "center",
          "style": { "background": "var(--mpp-surface-raised)", "borderBottom": "1px solid var(--mpp-border-subtle)", "padding": "0 16px" }
        },
        "children": [
          {
            "type": "ia.display.label", "meta": { "name": "Title" }, "position": { "grow": 1 },
            "props": { "style": { "classes": "modal-title", "color": "var(--mpp-text-primary)", "fontSize": "14px", "fontWeight": "600" }, "text": "Configuration Change Detail" }
          },
          {
            "type": "ia.display.icon", "meta": { "name": "CloseIcon" }, "position": { "basis": "24px", "shrink": 0 },
            "props": { "path": "material/close", "color": "var(--mpp-text-secondary)", "style": { "cursor": "pointer", "height": "20px", "width": "20px" } },
            "events": { "dom": { "onClick": {
              "type": "script", "scope": "G",
              "config": { "script": "\tsystem.perspective.closePopup(id=self.view.params.popupId)" }
            }}}
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "Body" },
        "position": { "basis": "0", "grow": 1 },
        "props": { "direction": "column", "style": { "gap": "10px", "padding": "16px", "overflow": "auto" } },
        "children": [
          {
            "type": "ia.display.label", "meta": { "name": "MetaLine" }, "position": { "shrink": 0 },
            "propConfig": { "props.text": { "binding": { "type": "expr", "config": {
              "expression": "\"Changed at:  \" + dateFormat({view.params.changedAt}, \"yyyy-MM-dd HH:mm:ss\") + \"   |   User:  \" + coalesce({view.params.userDisplayName}, \"(unknown)\") + \"   |   Severity:  \" + coalesce({view.params.logSeverityCode}, \"\") + \"   |   Event:  \" + coalesce({view.params.logEventTypeCode}, \"\")"
            }}}},
            "props": { "style": { "fontSize": "12px", "color": "var(--mpp-text-secondary)" } }
          },
          {
            "type": "ia.display.label", "meta": { "name": "EntityLine" }, "position": { "shrink": 0 },
            "propConfig": { "props.text": { "binding": { "type": "expr", "config": {
              "expression": "\"Entity:  \" + coalesce({view.params.logEntityTypeName}, \"\") + \"  \\u00B7  \" + coalesce({view.params.entityId}, \"(new)\")"
            }}}},
            "props": { "style": { "fontSize": "12px", "color": "var(--mpp-text-secondary)" } }
          },
          {
            "type": "ia.display.label", "meta": { "name": "DescHeader" }, "position": { "shrink": 0 },
            "props": { "text": "Description", "style": { "fontSize": "11px", "fontWeight": "600", "color": "var(--mpp-text-secondary)", "letterSpacing": "0.05em", "textTransform": "uppercase", "marginTop": "8px" } }
          },
          {
            "type": "ia.display.label", "meta": { "name": "DescText" }, "position": { "shrink": 0 },
            "propConfig": { "props.text": { "binding": { "type": "property", "config": { "path": "view.params.description" } } } },
            "props": { "style": { "fontSize": "13px", "color": "var(--mpp-text-primary)", "lineHeight": "1.4" } }
          },
          {
            "type": "ia.container.flex", "meta": { "name": "DiffRow" }, "position": { "basis": "0", "grow": 1, "shrink": 0 },
            "props": { "direction": "row", "style": { "gap": "10px" } },
            "children": [
              {
                "type": "ia.container.flex", "meta": { "name": "OldBlock" }, "position": { "basis": "0", "grow": 1 },
                "props": { "direction": "column", "style": { "gap": "4px" } },
                "children": [
                  { "type": "ia.display.label", "meta": { "name": "OldHeader" }, "position": { "shrink": 0 },
                    "props": { "text": "Old Value", "style": { "fontSize": "11px", "fontWeight": "600", "color": "var(--mpp-text-secondary)", "letterSpacing": "0.05em", "textTransform": "uppercase" } } },
                  { "type": "ia.display.label", "meta": { "name": "OldBody" }, "position": { "basis": "0", "grow": 1 },
                    "propConfig": { "props.text": { "binding": { "type": "expr", "config": { "expression": "runScript(\"BlueRidge.Common.Util.prettyJson\", 0, {view.params.oldValue})" } } } },
                    "props": { "style": { "background": "var(--mpp-surface-card)", "border": "1px solid var(--mpp-border-subtle)", "borderRadius": "6px", "color": "var(--mpp-text-primary)", "fontFamily": "ui-monospace, Menlo, Consolas, monospace", "fontSize": "11px", "lineHeight": "1.4", "overflow": "auto", "padding": "12px", "whiteSpace": "pre" } } }
                ]
              },
              {
                "type": "ia.container.flex", "meta": { "name": "NewBlock" }, "position": { "basis": "0", "grow": 1 },
                "props": { "direction": "column", "style": { "gap": "4px" } },
                "children": [
                  { "type": "ia.display.label", "meta": { "name": "NewHeader" }, "position": { "shrink": 0 },
                    "props": { "text": "New Value", "style": { "fontSize": "11px", "fontWeight": "600", "color": "var(--mpp-text-secondary)", "letterSpacing": "0.05em", "textTransform": "uppercase" } } },
                  { "type": "ia.display.label", "meta": { "name": "NewBody" }, "position": { "basis": "0", "grow": 1 },
                    "propConfig": { "props.text": { "binding": { "type": "expr", "config": { "expression": "runScript(\"BlueRidge.Common.Util.prettyJson\", 0, {view.params.newValue})" } } } },
                    "props": { "style": { "background": "var(--mpp-surface-card)", "border": "1px solid var(--mpp-border-subtle)", "borderRadius": "6px", "color": "var(--mpp-text-primary)", "fontFamily": "ui-monospace, Menlo, Consolas, monospace", "fontSize": "11px", "lineHeight": "1.4", "overflow": "auto", "padding": "12px", "whiteSpace": "pre" } } }
                ]
              }
            ]
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": { "name": "Footer" },
        "position": { "basis": "60px", "shrink": 0 },
        "props": { "alignItems": "center", "style": { "background": "var(--mpp-surface-raised)", "borderTop": "1px solid var(--mpp-border-subtle)", "padding": "12px 16px" } },
        "children": [
          { "type": "ia.container.flex", "meta": { "name": "Spacer" }, "position": { "grow": 1 } },
          {
            "type": "ia.input.button", "meta": { "name": "CloseButton" }, "position": { "shrink": 0 },
            "props": { "text": "Close", "style": { "classes": "btn btn-sm" } },
            "events": { "component": { "onActionPerformed": {
              "type": "script", "scope": "G",
              "config": { "script": "\tsystem.perspective.closePopup(id=self.view.params.popupId)" }
            }}}
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Scan**

Run: `powershell -ExecutionPolicy Bypass -File scan.ps1`

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfigChangeDetail/
git commit -m "feat(audit): ConfigChangeDetail popup with Old/New JSON diff"
```

---

## Task 11: New reusable sub-view — `BlueRidge/Components/Audit/TopRow`

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Audit/TopRow/{view.json, resource.json}`

Single sub-view shared between Top Reasons and Top Procs tile rows. Params: label (text shown), count (number), filterField (which `view.custom.filter.X` to write to), filterValue (what to write). Click → page-scoped `applyFilterFromTile` message with the field+value.

- [ ] **Step 1: Create resource.json (standard shape)**

- [ ] **Step 2: Create view.json**

```json
{
  "custom": {},
  "params": {
    "label":       "",
    "count":       0,
    "filterField": "",
    "filterValue": ""
  },
  "propConfig": {
    "params.label":       { "paramDirection": "input" },
    "params.count":       { "paramDirection": "input" },
    "params.filterField": { "paramDirection": "input" },
    "params.filterValue": { "paramDirection": "input" }
  },
  "props": {
    "defaultSize": { "width": 320, "height": 32 }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": { "name": "root" },
    "props": {
      "alignItems": "center",
      "style": {
        "borderBottom": "1px solid var(--mpp-border-subtle)",
        "cursor":       "pointer",
        "gap":          "10px",
        "padding":      "6px 12px"
      }
    },
    "events": {
      "dom": {
        "onClick": {
          "type": "script", "scope": "G",
          "config": {
            "script": "\tsystem.perspective.sendMessage(\"applyFilterFromTile\", payload={\"field\": self.view.params.filterField, \"value\": self.view.params.filterValue}, scope=\"page\")"
          }
        }
      }
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": { "name": "Label" },
        "position": { "basis": "0", "grow": 1 },
        "propConfig": {
          "props.text": { "binding": { "type": "property", "config": { "path": "view.params.label" } } }
        },
        "props": {
          "style": {
            "color":        "var(--mpp-text-primary)",
            "fontSize":     "12px",
            "overflow":     "hidden",
            "textOverflow": "ellipsis",
            "whiteSpace":   "nowrap"
          }
        }
      },
      {
        "type": "ia.display.label",
        "meta": { "name": "Count" },
        "position": { "basis": "auto", "shrink": 0 },
        "propConfig": {
          "props.text": { "binding": { "type": "property", "config": { "path": "view.params.count" } } }
        },
        "props": {
          "style": {
            "color":     "var(--mpp-text-secondary)",
            "fontSize":  "11px",
            "fontWeight": "600"
          }
        }
      }
    ]
  }
}
```

- [ ] **Step 3: Scan**

Run: `powershell -ExecutionPolicy Bypass -File scan.ps1`

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Audit/TopRow/
git commit -m "feat(audit): TopRow reusable sub-view for Top Reasons + Top Procs tiles"
```

---

## Task 12: Wire `BlueRidge/Views/Audit/FailureLog/view.json`

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/FailureLog/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/FailureLog/resource.json`

This is the heavy lift. Existing view has the layout; we add the state model + bindings + handlers. Existing view is large (~17KB) and was converted from a mockup; touch it via Python-driven byte-level edits per `feedback_ignition_view_edit_boundary.md`.

**Before starting: Designer must NOT have this view open.**

- [ ] **Step 1: Read current view to understand component naming + structure**

Run: `Read ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/FailureLog/view.json`

Note the meta.name values for: StartDateInput, EndDateInput, EntityTypeDropdown, ProcedureDropdown, SearchInput, RejectionReasonsRows, FailingProceduresRows, FailureTable, and the existing custom block.

- [ ] **Step 2: Add `view.custom` defaults**

Replace the existing `"custom": {...}` block (likely empty or a small stub) with:

```json
"custom": {
  "filter": {
    "startDate":      null,
    "endDate":        null,
    "entityTypeCode": null,
    "procedureName":  null,
    "appUserId":      null,
    "searchText":     ""
  },
  "rows":       [],
  "totalCount": 0,
  "topReasons": [],
  "topProcs":   []
}
```

- [ ] **Step 3: Add view-level `propConfig` for filter bindings**

(Add to top-level propConfig — note this is at the same level as `custom`, NOT inside the root component, per the lesson from PlantHierarchy.)

```json
"propConfig": {
  "custom.filter.startDate":      { "persistent": true },
  "custom.filter.endDate":        { "persistent": true },
  "custom.filter.entityTypeCode": { "persistent": true },
  "custom.filter.procedureName":  { "persistent": true },
  "custom.filter.appUserId":      { "persistent": true },
  "custom.filter.searchText":     { "persistent": true }
}
```

- [ ] **Step 4: Add view onStartup script (seeds dates + initial Apply)**

Locate the `root` component object. Add (or modify) its `scripts` block to include an `onStartup` extension function:

```json
"scripts": {
  "customMethods": [
    {
      "name": "applySearch",
      "params": ["self"],
      "script": "\tresult = BlueRidge.Audit.FailureLog.search(self.view.custom.filter)\n\tself.view.custom.rows       = result[\"rows\"]\n\tself.view.custom.totalCount = result[\"totalCount\"]\n\tself.view.custom.topReasons = result[\"topReasons\"]\n\tself.view.custom.topProcs   = result[\"topProcs\"]"
    },
    {
      "name": "resetFilter",
      "params": ["self"],
      "script": "\timport system\n\tnow = system.date.now()\n\tself.view.custom.filter = {\n\t\t\"startDate\":      system.date.addDays(now, -7),\n\t\t\"endDate\":        now,\n\t\t\"entityTypeCode\": None,\n\t\t\"procedureName\":  None,\n\t\t\"appUserId\":      None,\n\t\t\"searchText\":     \"\"\n\t}\n\tself.applySearch()"
    }
  ],
  "extensionFunctions": {
    "onStartup": "\tself.resetFilter()"
  },
  "messageHandlers": [
    {
      "messageType":  "applyFilterFromTile",
      "pageScope":    true,
      "sessionScope": false,
      "viewScope":    false,
      "script": "\tfield = payload.get(\"field\") if payload else None\n\tvalue = payload.get(\"value\") if payload else None\n\tif not field:\n\t\treturn\n\tf = dict(self.view.custom.filter or {})\n\tif field == \"failureReasonText\":\n\t\tf[\"searchText\"] = value or \"\"\n\telif field == \"procedureName\":\n\t\tf[\"procedureName\"] = value\n\tself.view.custom.filter = f\n\tself.applySearch()"
    }
  ]
}
```

(If `scripts` is already present, MERGE these into the existing block — preserve any existing messageHandlers.)

**Reasoning:** customMethods give us `self.applySearch()` and `self.resetFilter()` callable from any inline event script. onStartup fires once on view load — calling resetFilter populates dates with today/today-7d and immediately runs Apply. applyFilterFromTile handles the tile-row clicks.

- [ ] **Step 5: Wire StartDateInput.props.value bidirectionally to filter.startDate**

Locate the StartDateInput component (per the meta.name found in Step 1). Modify its `propConfig.props.value` binding (or add if absent) to:

```json
"propConfig": {
  "props.value": {
    "binding": {
      "type": "property",
      "config": { "bidirectional": true, "path": "view.custom.filter.startDate" }
    }
  }
}
```

Repeat for EndDateInput (path = `view.custom.filter.endDate`).

**Date format note:** if the existing inputs use Moment.js tokens that match `YYYY-MM-DD` per `06_component_quirks.md`, keep them. If they use `yyyy-MM-dd` (Java pattern), fix to `YYYY-MM-DD`.

- [ ] **Step 6: Wire EntityTypeDropdown — options + value**

Same component approach. The dropdown's `propConfig` should be:

```json
"propConfig": {
  "props.options": {
    "binding": {
      "type": "expr",
      "config": { "expression": "runScript(\"BlueRidge.Audit.LogEntityType.list\", 0)" },
      "transforms": [
        {
          "type": "script",
          "code": "\treturn [{\"label\": \"(All)\", \"value\": None}] + [{\"label\": t.get(\"Name\"), \"value\": t.get(\"Code\")} for t in (value or [])]"
        }
      ]
    }
  },
  "props.value": {
    "binding": {
      "type": "property",
      "config": { "bidirectional": true, "path": "view.custom.filter.entityTypeCode" }
    }
  }
}
```

- [ ] **Step 7: Wire ProcedureDropdown — options + value**

```json
"propConfig": {
  "props.options": {
    "binding": {
      "type": "expr",
      "config": { "expression": "runScript(\"BlueRidge.Audit.FailureLog.distinctProcedures\", 0)" },
      "transforms": [
        {
          "type": "script",
          "code": "\treturn [{\"label\": \"(All)\", \"value\": None}] + [{\"label\": t.get(\"ProcedureName\"), \"value\": t.get(\"ProcedureName\")} for t in (value or [])]"
        }
      ]
    }
  },
  "props.value": {
    "binding": {
      "type": "property",
      "config": { "bidirectional": true, "path": "view.custom.filter.procedureName" }
    }
  }
}
```

- [ ] **Step 8: Wire SearchInput — text bidirectional to filter.searchText**

```json
"propConfig": {
  "props.text": {
    "binding": {
      "type": "property",
      "config": { "bidirectional": true, "path": "view.custom.filter.searchText" }
    }
  }
}
```

- [ ] **Step 9: Add Apply + Reset buttons to sidebar footer if not already present**

Locate the FilterPanel container (or equivalent). Append a footer child:

```json
{
  "type": "ia.container.flex",
  "meta": { "name": "FilterFooter" },
  "position": { "basis": "auto", "shrink": 0 },
  "props": {
    "alignItems": "center",
    "style": { "gap": "8px", "padding": "12px 0 0 0" }
  },
  "children": [
    {
      "type": "ia.input.button",
      "meta": { "name": "ResetButton" },
      "position": { "basis": "0", "grow": 1 },
      "props": { "text": "Reset", "style": { "classes": "btn btn-sm" } },
      "events": {
        "component": {
          "onActionPerformed": {
            "type": "script", "scope": "G",
            "config": { "script": "\tself.view.resetFilter()" }
          }
        }
      }
    },
    {
      "type": "ia.input.button",
      "meta": { "name": "ApplyButton" },
      "position": { "basis": "0", "grow": 1 },
      "props": { "text": "Apply", "style": { "classes": "btn btn-primary btn-sm" } },
      "events": {
        "component": {
          "onActionPerformed": {
            "type": "script", "scope": "G",
            "config": { "script": "\tself.view.applySearch()" }
          }
        }
      }
    }
  ]
}
```

If a similar footer already exists from the mockup, modify the buttons to use these handlers instead.

- [ ] **Step 10: Wire RejectionReasonsRows + FailingProceduresRows flex-repeaters**

For RejectionReasonsRows:
```json
"propConfig": {
  "props.instances": {
    "binding": {
      "type": "property",
      "config": { "path": "view.custom.topReasons" },
      "transforms": [
        {
          "type": "script",
          "code": "\treturn [\n\t\t{\n\t\t\t\"label\":       r.get(\"FailureReason\") or \"(none)\",\n\t\t\t\"count\":       r.get(\"Count\") or 0,\n\t\t\t\"filterField\": \"failureReasonText\",\n\t\t\t\"filterValue\": r.get(\"FailureReason\") or \"\"\n\t\t}\n\t\tfor r in (value or [])\n\t]"
        }
      ]
    }
  }
},
"props": {
  "path": "BlueRidge/Components/Audit/TopRow",
  "direction": "column",
  "elementPosition": { "basis": "32px", "shrink": 0 },
  "useDefaultViewWidth": false,
  "useDefaultViewHeight": false
}
```

For FailingProceduresRows — identical except:
- `path: "view.custom.topProcs"`
- transform: `"label": r.get("ProcedureName"), "filterField": "procedureName", "filterValue": r.get("ProcedureName")`

**Note:** the `_GetTopReasons` and `_GetTopProcs` procs return columns `FailureReason` + `Count` and `ProcedureName` + `Count` respectively (verify against the existing proc bodies; if column names differ, adjust the transform).

- [ ] **Step 11: Wire FailureTable**

The FailureTable is `ia.display.table`. Its props.data binding:

```json
"propConfig": {
  "props.data": {
    "binding": {
      "type": "property",
      "config": { "path": "view.custom.rows" }
    }
  }
}
```

If `props.data` requires a Dataset rather than list[dict]: wrap the binding in a script transform that calls `system.dataset.toDataSet(headers, [list of lists])`. Verify during smoke test; the table component may accept either shape.

Add row-click event on the table:
```json
"events": {
  "component": {
    "onRowClick": {
      "type": "script", "scope": "G",
      "config": {
        "script": "\trow = event.row if hasattr(event, \"row\") else None\n\tdata = row.data if row and hasattr(row, \"data\") else None\n\tif data is None:\n\t\treturn\n\tsystem.perspective.openPopup(\n\t\tid=\"mpp-failure-detail\",\n\t\tview=\"BlueRidge/Components/Popups/FailureDetail\",\n\t\tmodal=True,\n\t\tdraggable=False,\n\t\tshowCloseIcon=False,\n\t\tparams={\n\t\t\t\"id\":                  data.get(\"Id\"),\n\t\t\t\"attemptedAt\":         data.get(\"AttemptedAt\"),\n\t\t\t\"userDisplayName\":     data.get(\"UserDisplayName\"),\n\t\t\t\"logEntityTypeName\":   data.get(\"LogEntityTypeName\"),\n\t\t\t\"entityId\":            data.get(\"EntityId\"),\n\t\t\t\"logEventTypeCode\":    data.get(\"LogEventTypeCode\"),\n\t\t\t\"procedureName\":       data.get(\"ProcedureName\"),\n\t\t\t\"failureReason\":       data.get(\"FailureReason\"),\n\t\t\t\"attemptedParameters\": data.get(\"AttemptedParameters\")\n\t\t}\n\t)"
      }
    }
  }
}
```

The exact `event.row` / `event.data` access path depends on the Perspective table component version — verify via `06_component_quirks.md` or empirically during smoke test. If access fails, an alternative is `self.props.selection` lookup.

- [ ] **Step 12: Add "Showing X of Y" banner**

Insert a label above the FailureTable in the ContentArea:

```json
{
  "type": "ia.display.label",
  "meta": { "name": "ResultBanner" },
  "position": { "basis": "auto", "shrink": 0 },
  "propConfig": {
    "props.text": {
      "binding": {
        "type": "expr",
        "config": {
          "expression": "if({view.custom.totalCount} < 1000, \"Showing \" + {view.custom.totalCount} + \" rows\", \"Showing first 1000 of \" + {view.custom.totalCount} + \" \\u2014 narrow your filter\")"
        }
      }
    }
  },
  "props": {
    "style": {
      "color":      "var(--mpp-text-secondary)",
      "fontSize":   "11px",
      "padding":    "4px 12px"
    }
  }
}
```

- [ ] **Step 13: Clear resource.json signature + bump timestamp**

Edit `.../FailureLog/resource.json`:
```json
"lastModificationSignature": "",
"lastModification": { "actor": "claude", "timestamp": "2026-05-19T15:00:00Z" }
```

- [ ] **Step 14: Validate JSON + scan**

```bash
python -c "import json; json.loads(open('ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/FailureLog/view.json').read())"
```

Then: `powershell -ExecutionPolicy Bypass -File scan.ps1`

- [ ] **Step 15: Designer smoke test**

In Designer:
1. Project → Update Project
2. Open FailureLog view (`/failure-log` page)
3. Verify: page loads with last-7d data populated; Top Reasons + Top Procs show recent failures (will be empty initially if no failures in last 7d — generate some by trying to deprecate a Cell with active LotMovement references, or by intentionally creating with duplicate Code).
4. Change StartDate → click Apply → table refreshes
5. Reset → defaults restored, table refreshes
6. Top Reasons row click → searchText populated, table re-filters
7. Top Procs row click → procedureName dropdown updates, table re-filters
8. Table row click → FailureDetail popup opens with pretty-printed AttemptedParameters JSON

Document any issues found and address before committing.

- [ ] **Step 16: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/FailureLog/
git commit -m "feat(audit): wire FailureLog view -- filter sidebar + dashboard tiles + detail popup"
```

---

## Task 13: Wire `BlueRidge/Views/Audit/AuditLog/view.json`

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/AuditLog/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/AuditLog/resource.json`

Same pattern as Task 12 with these differences:

| Element | FailureLog | AuditLog |
|---|---|---|
| Table | `view.custom.rows` rows from `BlueRidge.Audit.FailureLog.search` | rows from `BlueRidge.Audit.ConfigLog.search` |
| Procedure dropdown | yes | **NO — replaced by Severity dropdown** |
| Severity dropdown | NO | yes, options from `BlueRidge.Audit.LogSeverity.list()` |
| Search field | substring match on FailureReason | substring match on Description |
| Dashboard tiles | yes (Top Reasons + Top Procs) | **NO — drop entirely** |
| Row click popup | FailureDetail | ConfigChangeDetail |
| Banner | same | same |

- [ ] **Step 1: Read current AuditLog view to confirm components**

Note its existing filter inputs — confirm whether it already has a Severity dropdown placeholder or whether the converted mockup has a Procedure dropdown that needs swapping.

- [ ] **Step 2: Apply state model**

Same `view.custom` shape as FailureLog but with `logSeverityCode` instead of `procedureName`. Drop `topReasons` and `topProcs`.

- [ ] **Step 3: customMethods + onStartup + messageHandlers**

Same as Task 12 with:
- `applySearch` calls `BlueRidge.Audit.ConfigLog.search` instead of `FailureLog.search`
- omit topReasons/topProcs from the returned-state writes
- omit the `applyFilterFromTile` message handler (no tiles)

- [ ] **Step 4: Wire all filter fields**

Same Steps 5–8 from Task 12 with field substitutions per the table above.

For Severity dropdown — same pattern as EntityType:
```json
"props.options": {
  "binding": {
    "type": "expr",
    "config": { "expression": "runScript(\"BlueRidge.Audit.LogSeverity.list\", 0)" },
    "transforms": [
      {
        "type": "script",
        "code": "\treturn [{\"label\": \"(All)\", \"value\": None}] + [{\"label\": s.get(\"Name\"), \"value\": s.get(\"Code\")} for s in (value or [])]"
      }
    ]
  }
},
"props.value": {
  "binding": {
    "type": "property",
    "config": { "bidirectional": true, "path": "view.custom.filter.logSeverityCode" }
  }
}
```

If the existing AuditLog view has a Procedure dropdown component in the position where Severity should be, rename/repurpose it: change `meta.name` from `ProcedureDropdown` to `SeverityDropdown`, update its label text, replace the options/value bindings.

- [ ] **Step 5: Wire Apply + Reset buttons (same as FailureLog)**

- [ ] **Step 6: Remove or hide DashboardTiles**

Locate the DashboardTiles container (if present). Either:
- Delete it entirely from the children array, OR
- Set its `position.display` to `false` (keeps the structure for future reuse)

Recommendation: delete it cleanly — the dashboard tiles section is specific to FailureLog.

- [ ] **Step 7: Wire AuditTable + row-click handler**

Same as Step 11 of Task 12 but call:
- `openPopup("BlueRidge/Components/Popups/ConfigChangeDetail", ...)`
- pass params: `id, changedAt, userDisplayName, logEntityTypeName, entityId, logEventTypeCode, logSeverityCode, description, oldValue, newValue`

- [ ] **Step 8: Add the same "Showing X of Y" banner**

- [ ] **Step 9: Clear resource.json signature + bump timestamp**

- [ ] **Step 10: Validate JSON + scan**

Same as Task 12 Steps 14.

- [ ] **Step 11: Designer smoke test**

In Designer:
1. Project → Update Project
2. Open AuditLog view (`/audit-log` page)
3. Verify: page loads with last-7d ConfigLog data; rows include the day's Location SaveAll / IconPicker / etc. activity
4. Change StartDate / EntityType / Severity / Search → click Apply → table refreshes
5. Reset → defaults restored
6. Click a row → ConfigChangeDetail popup opens with Old + New JSON pretty-printed

- [ ] **Step 12: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/AuditLog/
git commit -m "feat(audit): wire AuditLog view -- filter sidebar + ConfigChangeDetail popup"
```

---

## Task 14: Final smoke test + memory updates

- [ ] **Step 1: Full reset + test run**

```bash
powershell -ExecutionPolicy Bypass -File sql\tests\Run-Tests.ps1 2>&1 | Out-File -Encoding utf8 .tmp_test_run.log
Get-Content .tmp_test_run.log | Select-String -Pattern "Total:|Passed:|Failed:|Test run" | Select-Object -Last 8
```

Expected: `Test run PASSED.` with full count (previous suite total + the new tests in Tasks 1, 2, 3).

- [ ] **Step 2: Designer end-to-end smoke test**

Run through the full FailureLog + AuditLog workflows one more time end-to-end. Document any issues that need follow-up; if any are blocking, address now; otherwise capture as `PROJECT_STATUS.md` non-blocking polish items.

- [ ] **Step 3: PROJECT_STATUS.md update**

Add a "Recent Change Narrative" entry dated 2026-05-19 capturing:
- Audit pages landed: FailureLog + AuditLog wiring
- SQL: 2 proc edits + 1 new proc + extended tests
- Ignition: 9 NQs + 4 entity scripts + 3 new component views + 2 view wires + Common.Util.prettyJson helper
- Reference: design spec + implementation plan paths

- [ ] **Step 4: Consider adding memory entries**

Candidates worth capturing if patterns emerged:
- "ia.display.table data prop accepts X" (Dataset vs list[dict]) — only if there was an actual decision
- "Audit Browser pattern" (filter + Apply + Reset + cap+banner) — could be a project memory if other browsers follow

Write entries to `~/.claude/projects/.../memory/` files only if there's genuinely a reusable pattern. Otherwise skip.

- [ ] **Step 5: Final commit**

```bash
rm .tmp_test_run.log
git add PROJECT_STATUS.md
git commit -m "docs: audit pages landed (FailureLog + AuditLog) -- session narrative + status"
```

---

## Self-Review Notes

**Spec coverage:** every spec section has at least one task:
- §3 Architecture → Tasks 5–8 (entity scripts)
- §4 UI Layout → Tasks 12–13 (view wires)
- §5 State Model → Tasks 12–13 (onStartup + applySearch + resetFilter)
- §6 Detail Popups → Tasks 9–10
- §7 SQL Changes → Tasks 1–3
- §8 NQs → Task 4
- §9 Entity Scripts → Tasks 5–8
- §10 View Wiring → Tasks 12–13
- §11 Performance (TOP 1000, COUNT OVER) → Tasks 1, 2
- §12 Risks → addressed via implementation (server cap, popup error handling)
- §13 Testing → Tasks 1, 2, 3 (SQL tests); Tasks 12, 13 Step 15 (smoke)
- §14 Files Touched → all enumerated above

**Type consistency check:** filter dict shape consistent across `BlueRidge.Audit.FailureLog.search` (Task 7), `ConfigLog.search` (Task 8), and the view's `view.custom.filter` defaults (Tasks 12, 13). Search keys: `startDate`, `endDate`, `entityTypeCode`, `procedureName`/`logSeverityCode`, `appUserId`, `searchText`.

**Placeholder scan:** no TBD/TODO. Each step shows actual code where code is needed. The "verify column names match" note in Tasks 1–2 Step 4 is intentional (existing tests' expectations may not match the new canonical shape) — the engineer adjusts on first test run failure rather than predicting column drift.

**Scope check:** ~22 files, all related to the audit-pages spec. Single coherent plan. Estimate 2.5–3 hours as the spec said.
