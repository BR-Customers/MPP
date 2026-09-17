# Tool Shot-Count Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the die manager type a die's actual lifetime shot count on the Config Tool Tools screen (with a mandatory note, audited), and let both shot fields accept thousands separators while still storing `INT`.

**Architecture:** A new status-row proc `Tools.Tool_CorrectShotCount` applies `ShotCount = ShotCount + (typed - loaded)` under a row lock, refuses a stale edit, and writes one `Audit.ConfigLog` row carrying the note. `BlueRidge.Parts.Tool` gains pure parse/format helpers (unit-tested with pytest, no gateway), formats the loaded meta, and calls the new proc after `Tool_Update` when the count changed. The existing `Parts/Tools` view swaps the read-only "Total Shots" label for a text field and gains a note row, edited by a JSON script that preserves Designer's escaping.

**Tech Stack:** SQL Server 2022 (T-SQL, `sql/tests` framework), Ignition 8.3 Perspective + Jython 2.7 project scripts, named queries, pytest.

**Spec:** `docs/superpowers/specs/2026-09-17-tool-shot-count-correction-design.md`

## Global Constraints

- Note is required **only** when the shot count changes; other header edits are unchanged.
- The correction touches **only** `Tools.Tool.ShotCount` -- never `Workorder.DieCastContribution`, watermarks, or counter anchors.
- Record lives in `Audit.ConfigLog` only; no new table, no versioned migration.
- Shot values stored as `INT`; input accepts `,` and spaces; non-numeric input is rejected with a message, never coerced to NULL.
- Stored procs: no OUTPUT params; every exit path `SELECT @Status AS Status, @Message AS Message;`; all rejections before `BEGIN TRANSACTION`; `ROLLBACK` only in CATCH; `RAISERROR` not `THROW`.
- Audit Description shape `<SUBJECT> · <CATEGORY> · <ACTION>` via `Audit.ufn_MidDot()` + `Audit.ufn_TruncateActivity()`; non-ASCII characters only via `NCHAR()` (sqlcmd codepage).
- Named-query status-row procs are `type: Query`.
- Jython 2.7: no f-strings, no `unicode`-only builtins in the pure helpers (they must also run under CPython 3 for pytest).
- Commits: stage explicit paths only (`git add <path>`), never `-A`/`-u`; no `Co-Authored-By: Claude` trailer; branch `jacques/working`.
- The working tree has unrelated uncommitted changes (NQ `resource.json` files, `MPP_MES_SEEDING_REGISTRY.md`) -- do not stage them.

## File map

| File | Action | Responsibility |
|---|---|---|
| `sql/migrations/repeatable/R__Tools_Tool_CorrectShotCount.sql` | Create | The correction proc |
| `sql/tests/0050_ToolShotCount/060_Tool_CorrectShotCount.sql` | Create | Proc tests |
| `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` | Modify (~5836-5852) | `Tools.Tool.ShotCount` description |
| `MPP_MES_DATA_MODEL.md` | Modify | `ShotCount` row + revision history |
| `ignition/projects/Core/ignition/named-query/parts/Tool_CorrectShotCount/{query.sql,resource.json}` | Create | NQ |
| `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py` | Modify | Pure helpers, `getOne`, `update` |
| `ignition/tests/test_tool_shot_inputs.py` | Create | pytest for the pure helpers |
| `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/Tools/view.json` | Modify (scripted) | Current Shots field + note row + clean defaults |
| `tools/edit_tools_view_shot_count.py` | Create | One-off, re-runnable view edit script |

---

### Task 1: SQL proc `Tools.Tool_CorrectShotCount` + tests + schema docs

**Files:**
- Create: `sql/migrations/repeatable/R__Tools_Tool_CorrectShotCount.sql`
- Create: `sql/tests/0050_ToolShotCount/060_Tool_CorrectShotCount.sql`
- Modify: `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql` (the `[Tools].[Tool]` / `ShotCount` block, ~line 5836)
- Modify: `MPP_MES_DATA_MODEL.md` (the `| ShotCount | INT | NOT NULL, DEFAULT 0 |` row in §7 Tools, ~line 1596; revision table at top)

**Interfaces:**
- Produces: `EXEC Tools.Tool_CorrectShotCount @Id BIGINT, @ShotCount INT, @ExpectedShotCount INT, @Note NVARCHAR(500), @AppUserId BIGINT` -> one row `(Status BIT, Message NVARCHAR(500))`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0050_ToolShotCount/060_Tool_CorrectShotCount.sql`:

```sql
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0050_ToolShotCount/060_Tool_CorrectShotCount.sql';
GO
DELETE FROM Tools.Tool WHERE Code IN (N'TEST-SHOT-FIX', N'TEST-SHOT-FIXCUT', N'TEST-SHOT-FIXDEP');
GO
DECLARE @DieType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @CutType BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Cutter');
DECLARE @Active  BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @ToolEntity BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Tool');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId)
VALUES (@DieType, N'TEST-SHOT-FIX', N'Shot fix test die', @Active, 1000, SYSUTCDATETIME(), 1);
DECLARE @Die BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@CutType, N'TEST-SHOT-FIXCUT', N'Shot fix test cutter', @Active, SYSUTCDATETIME(), 1);
DECLARE @Cut BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId, DeprecatedAt)
VALUES (@DieType, N'TEST-SHOT-FIXDEP', N'Shot fix deprecated die', @Active, 50, SYSUTCDATETIME(), 1, SYSUTCDATETIME());
DECLARE @Dep BIGINT = SCOPE_IDENTITY();

DECLARE @ContribBefore INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @v NVARCHAR(4000);

-- [Up] 1000 -> 850000 with a note
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=850000,
    @ExpectedShotCount=1000, @Note=N'Cutover: count from die card', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Up] Status 1', @Expected=N'1', @Actual=@v;
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Up] ShotCount = 850000', @Expected=N'850000', @Actual=@v;

-- [Audit] one ConfigLog row with old/new/delta/note
SET @v = (SELECT TOP 1 Description FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName=N'[Audit] description names the category', @HaystackStr=@v, @NeedleStr=N'Shot Count';
EXEC test.Assert_Contains @TestName=N'[Audit] description shows old count', @HaystackStr=@v, @NeedleStr=N'1,000';
EXEC test.Assert_Contains @TestName=N'[Audit] description shows new count', @HaystackStr=@v, @NeedleStr=N'850,000';
EXEC test.Assert_Contains @TestName=N'[Audit] description carries the note', @HaystackStr=@v, @NeedleStr=N'die card';
SET @v = (SELECT TOP 1 JSON_VALUE(NewValue, '$.Delta') FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_IsEqual @TestName=N'[Audit] NewValue.Delta = 849000', @Expected=N'849000', @Actual=@v;
SET @v = (SELECT TOP 1 JSON_VALUE(NewValue, '$.Note') FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_IsEqual @TestName=N'[Audit] NewValue.Note is the full note', @Expected=N'Cutover: count from die card', @Actual=@v;
SET @v = (SELECT TOP 1 JSON_VALUE(OldValue, '$.ShotCount') FROM Audit.ConfigLog
          WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die ORDER BY Id DESC);
EXEC test.Assert_IsEqual @TestName=N'[Audit] OldValue.ShotCount = 1000', @Expected=N'1000', @Actual=@v;

-- [Down] 850000 -> 849990 (negative delta allowed)
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=849990,
    @ExpectedShotCount=850000, @Note=N'Typo fix', @AppUserId=1;
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Down] ShotCount = 849990', @Expected=N'849990', @Actual=@v;

-- [Zero] to 0 is legal
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=0,
    @ExpectedShotCount=849990, @Note=N'Die rebuilt', @AppUserId=1;
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[Zero] ShotCount = 0', @Expected=N'0', @Actual=@v;

DECLARE @AuditCount INT = (SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die);

-- [Reject] blank note
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=10,
    @ExpectedShotCount=0, @Note=N'   ', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] blank note', @Expected=N'0|A note is required when changing the shot count.', @Actual=@v;

-- [Reject] NULL note
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=10,
    @ExpectedShotCount=0, @Note=NULL, @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] NULL note -> Status 0', @Expected=N'0', @Actual=@v;

-- [Reject] negative
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=-1,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] negative', @Expected=N'0|Shot count cannot be negative.', @Actual=@v;

-- [Reject] unchanged
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=0,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] unchanged', @Expected=N'0|Shot count is unchanged.', @Actual=@v;

-- [Reject] stale: screen loaded 500 but the die is at 0
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=900,
    @ExpectedShotCount=500, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] stale expected count',
    @Expected=N'0|Shot count changed since this die was opened (now 0). Reload and re-enter.', @Actual=@v;

-- [Reject] non-Die
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Cut, @ShotCount=10,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] non-Die', @Expected=N'0|Shot count is only tracked for Die-type Tools.', @Actual=@v;

-- [Reject] deprecated
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Dep, @ShotCount=60,
    @ExpectedShotCount=50, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] deprecated', @Expected=N'0|Tool not found or deprecated.', @Actual=@v;

-- [Reject] missing required
DELETE FROM @R;
INSERT INTO @R EXEC Tools.Tool_CorrectShotCount @Id=@Die, @ShotCount=NULL,
    @ExpectedShotCount=0, @Note=N'x', @AppUserId=1;
SET @v = (SELECT CAST(Status AS NVARCHAR(5)) + N'|' + Message FROM @R);
EXEC test.Assert_IsEqual @TestName=N'[Reject] missing ShotCount', @Expected=N'0|Required parameter missing.', @Actual=@v;

-- [NoSideEffects] rejections wrote nothing; no contribution rows ever
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id=@Die);
EXEC test.Assert_IsEqual @TestName=N'[NoSideEffects] ShotCount still 0', @Expected=N'0', @Actual=@v;
SET @v = CAST((SELECT COUNT(*) FROM Audit.ConfigLog WHERE LogEntityTypeId=@ToolEntity AND EntityId=@Die) AS NVARCHAR(10));
DECLARE @AuditExpected NVARCHAR(10) = CAST(@AuditCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[NoSideEffects] no ConfigLog rows from rejections', @Expected=@AuditExpected, @Actual=@v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution) AS NVARCHAR(10));
DECLARE @ContribExpected NVARCHAR(10) = CAST(@ContribBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName=N'[NoSideEffects] no DieCastContribution rows written', @Expected=@ContribExpected, @Actual=@v;

DELETE FROM Tools.Tool WHERE Id IN (@Die, @Cut, @Dep);
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run (PowerShell, repo root): `.\sql\tests\Run-Tests.ps1 -Filter "0050_ToolShotCount"`
Expected: `060_Tool_CorrectShotCount.sql` fails with "Could not find stored procedure 'Tools.Tool_CorrectShotCount'"; 010-050 still pass. (The runner rebuilds the throwaway `MPP_MES_Test` DB; it never touches `MPP_MES_Dev`.)

- [ ] **Step 3: Write the proc**

Create `sql/migrations/repeatable/R__Tools_Tool_CorrectShotCount.sql`:

```sql
-- =============================================
-- Procedure:   Tools.Tool_CorrectShotCount
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
--
-- Description:
--   Sets a die's lifetime shot count to the value the die manager typed
--   on the Config Tool Tools screen (cutover entry or correction). Spec
--   docs/superpowers/specs/2026-09-17-tool-shot-count-correction-design.md.
--
--   Mirrors the shift-reconcile increment in
--   Workorder.DieCastShiftOutput_Record (ShotCount = ShotCount + delta,
--   row-locked) with two differences: the delta may be negative, and it
--   touches ONLY Tools.Tool.ShotCount. It writes no
--   Workorder.DieCastContribution row and moves no watermark -- those rows
--   are the per-shift press-counter chain and drive basket crediting; a
--   lifetime die count is not a press reading.
--
--   Stale guard: @ExpectedShotCount is the count the screen loaded. If a
--   shift output has landed since, the proc refuses rather than overwrite
--   shots recorded while the user was typing. Checked before the
--   transaction and again by the UPDATE's WHERE (a race inside the window
--   commits nothing and returns the same refusal).
--
--   A non-blank @Note is mandatory. The record of the correction is one
--   Audit.ConfigLog row: the note appears in Description (truncated at
--   500) and in full in NewValue.Note.
--
-- Parameters (input):
--   @Id BIGINT                 - Tool PK. Required.
--   @ShotCount INT             - The actual lifetime count. Required, >= 0.
--   @ExpectedShotCount INT     - Count the screen loaded. Required.
--   @Note NVARCHAR(500)        - Why. Required, non-blank.
--   @AppUserId BIGINT          - Required.
--
-- Result set:
--   Single row: Status, Message.
--
-- Dependencies:
--   Tables: Tools.Tool, Tools.ToolType
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
-- =============================================
CREATE OR ALTER PROCEDURE Tools.Tool_CorrectShotCount
    @Id                BIGINT,
    @ShotCount         INT,
    @ExpectedShotCount INT,
    @Note              NVARCHAR(500) = NULL,
    @AppUserId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName  NVARCHAR(200) = N'Tools.Tool_CorrectShotCount';
    DECLARE @CleanNote NVARCHAR(500) = NULLIF(LTRIM(RTRIM(@Note)), N'');
    DECLARE @Params    NVARCHAR(MAX) =
        (SELECT @Id                AS Id,
                @ShotCount         AS ShotCount,
                @ExpectedShotCount AS ExpectedShotCount,
                @Note              AS Note
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Validation (all before BEGIN TRANSACTION)
        -- ====================
        IF @Id IS NULL OR @ShotCount IS NULL OR @ExpectedShotCount IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            GOTO Fail;
        END

        IF @CleanNote IS NULL
        BEGIN
            SET @Message = N'A note is required when changing the shot count.';
            GOTO Fail;
        END

        IF @ShotCount < 0
        BEGIN
            SET @Message = N'Shot count cannot be negative.';
            GOTO Fail;
        END

        DECLARE @ToolTypeCode NVARCHAR(50), @Code NVARCHAR(50),
                @Name NVARCHAR(100), @Current INT;

        SELECT @ToolTypeCode = tt.Code,
               @Code         = t.Code,
               @Name         = t.Name,
               @Current      = t.ShotCount
        FROM Tools.Tool t
        INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @Id AND t.DeprecatedAt IS NULL;

        IF @ToolTypeCode IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            GOTO Fail;
        END

        IF @ToolTypeCode <> N'Die'
        BEGIN
            SET @Message = N'Shot count is only tracked for Die-type Tools.';
            GOTO Fail;
        END

        IF @ShotCount = @ExpectedShotCount
        BEGIN
            SET @Message = N'Shot count is unchanged.';
            GOTO Fail;
        END

        IF @Current <> @ExpectedShotCount
        BEGIN
            SET @Message = N'Shot count changed since this die was opened (now '
                         + CAST(@Current AS NVARCHAR(20)) + N'). Reload and re-enter.';
            GOTO Fail;
        END

        -- ====================
        -- Audit narrative
        -- ====================
        DECLARE @Delta  INT          = @ShotCount - @ExpectedShotCount;
        DECLARE @MidDot NVARCHAR(10) = Audit.ufn_MidDot();
        DECLARE @Dash   NVARCHAR(10) = NCHAR(8212);   -- em dash, ASCII-safe source
        DECLARE @Arrow  NVARCHAR(10) = NCHAR(8594);   -- right arrow, field-diff notation

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Code + N' ' + @Dash + N' ' + @Name
            + N' ' + @MidDot + N' Shot Count '
            + @MidDot + N' ' + FORMAT(@ExpectedShotCount, 'N0', 'en-US')
            + N' ' + @Arrow + N' ' + FORMAT(@ShotCount, 'N0', 'en-US')
            + N' ' + @MidDot + N' ' + @CleanNote);

        DECLARE @OldValue NVARCHAR(MAX) =
            (SELECT @ExpectedShotCount AS ShotCount
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) =
            (SELECT @ShotCount AS ShotCount, @Delta AS Delta, @CleanNote AS Note
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ====================
        -- Mutation
        -- ====================
        BEGIN TRANSACTION;

        -- Same shape as the shift-reconcile increment; the extra predicate
        -- makes a shift output that lands after the pre-check a no-op.
        UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
        SET ShotCount       = ShotCount + @Delta,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id AND ShotCount = @ExpectedShotCount;

        IF @@ROWCOUNT = 0
        BEGIN
            COMMIT TRANSACTION;   -- nothing was written; close cleanly (no ROLLBACK outside CATCH)
            SET @Message = N'Shot count changed since this die was opened. Reload and re-enter.';
            GOTO Fail;
        END

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Tool',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shot count updated.';
        SELECT @Status AS Status, @Message AS Message;
        RETURN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
        RETURN;
    END CATCH

Fail:
    -- Audit.FailureLog.AppUserId is NOT NULL/FK: the required-parameter
    -- branch can arrive here with @AppUserId NULL -- skip the log then.
    IF @AppUserId IS NOT NULL
        EXEC Audit.Audit_LogFailure
            @AppUserId = @AppUserId, @LogEntityTypeCode = N'Tool',
            @EntityId = @Id, @LogEventTypeCode = N'Updated',
            @FailureReason = @Message, @ProcedureName = @ProcName,
            @AttemptedParameters = @Params;
    SELECT @Status AS Status, @Message AS Message;
END;
GO
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0050_ToolShotCount"`
Expected: all files 010-060 pass, 0 failures. If the runner exits 1 with 0 failures, a test file's sqlcmd errored -- read its output (usually a teardown FK or a wrong `Assert_Contains` parameter name).

- [ ] **Step 5: Update the schema description**

In `sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql`, in the `[Tools].[Tool]` / `ShotCount` block, replace the `@value` string in **both** the `sp_updateextendedproperty` and `sp_addextendedproperty` calls with (ASCII only):

```
N'Added v2.2 (migration 0050). Materialized lifetime shot counter. Live-incremented by Workorder.DieCastShiftOutput_Record by the counter-reading delta - no event ledger, no reconcile job. The one setter is Tools.Tool_CorrectShotCount (Config Tool Tools screen): a cutover entry or correction with a mandatory note, audited to Audit.ConfigLog, stale-guarded, and never touching DieCastContribution or the shot watermarks. Per-physical-asset state, not configuration: Tool_Duplicate resets it to 0 (a cross-database import necessarily lands 0).'
```

Byte-scan the file for non-ASCII introduced by this edit: `git diff -U0 sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql | grep -nP '^\+.*[^\x00-\x7F]'` -> Expected: no output.

- [ ] **Step 6: Update the Data Model**

In `MPP_MES_DATA_MODEL.md` §7, the `Tools.Tool` `ShotCount` row: replace the sentence "`Tool_Duplicate` resets it to 0, and no proc exposes a setter (a cross-database import necessarily lands 0)." with:

```
`Tool_Duplicate` resets it to 0 (a cross-database import necessarily lands 0). **The one setter is `Tools.Tool_CorrectShotCount`** (2026-09-17, Config Tool Tools screen): the die manager's cutover entry or correction -- `ShotCount + (typed − loaded)` under a row lock, refused if the count moved since the screen loaded, mandatory note, one `Audit.ConfigLog` row (`NewValue` = `{ShotCount, Delta, Note}`). It never writes `DieCastContribution` or moves a shot watermark.
```

Add a revision-history row at the top of the table (above `| 2.5 | 2026-09-14 |`):

```
| 2.6 | 2026-09-17 | Blue Ridge Automation | **`Tools.Tool.ShotCount` gains a setter.** `Tools.Tool_CorrectShotCount` lets the die manager enter a die's actual lifetime count at cutover or fix a wrong one, with a mandatory note audited to `Audit.ConfigLog`. Stale-guarded against a shift output landing mid-edit; touches no `DieCastContribution` row or watermark. Spec `docs/superpowers/specs/2026-09-17-tool-shot-count-correction-design.md`. |
```

- [ ] **Step 7: Apply to Dev and re-run the full shot-count + die-cast suites**

Run the repeatables against Dev (non-destructive, `CREATE OR ALTER`):
```
sqlcmd -S localhost -d MPP_MES_Dev -b -I -C -i sql/migrations/repeatable/R__Tools_Tool_CorrectShotCount.sql
sqlcmd -S localhost -d MPP_MES_Dev -b -I -C -i sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql
```
Expected: no errors.
Then: `.\sql\tests\Run-Tests.ps1 -Filter "0022_PlantFloor_DieCast"` -> Expected: 0 failures (nothing in the die-cast path changed; this guards that).

- [ ] **Step 8: Commit**

```bash
git add sql/migrations/repeatable/R__Tools_Tool_CorrectShotCount.sql sql/tests/0050_ToolShotCount/060_Tool_CorrectShotCount.sql sql/migrations/repeatable/R__Descriptions_ExtendedProperties.sql MPP_MES_DATA_MODEL.md
git commit -m "feat(tools): Tool_CorrectShotCount -- audited, stale-guarded die shot-count correction"
```

---

### Task 2: Named query + Python helpers and save path

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/parts/Tool_CorrectShotCount/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/parts/Tool_CorrectShotCount/resource.json`
- Create: `ignition/tests/test_tool_shot_inputs.py`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py` (header docstring; `getOne` ~175-198; `update` ~255-307)

**Interfaces:**
- Consumes: `Tools.Tool_CorrectShotCount` (Task 1).
- Produces:
  - NQ `parts/Tool_CorrectShotCount` params `id`, `shotCount`, `expectedShotCount`, `note`, `appUserId`.
  - `_parseShots(value, label) -> (int|None, str|None)` -- blank -> `(None, None)`; bad -> `(None, "<message>")`.
  - `_formatShots(value) -> str` -- `None`/`""` -> `""`, `850000` -> `"850,000"`.
  - `_metaForEditor(row) -> dict` -- the Tool_Get row plus `deprecated`, `Description` (`""` for NULL), `ShotLimit` (formatted str), `ShotCount` (formatted str), `ShotCountLoaded` (int), `ShotCountNote` (`""`).
  - `_shotEdits(data) -> dict` with keys `error`, `shotLimit`, `shotCount`, `shotCountChanged`, `note`.
  - `getOne(toolId)` returns `_metaForEditor(row)`; `update(data)` reads `ShotLimit`, `ShotCount`, `ShotCountLoaded`, `ShotCountNote` from `data`. The view (Task 3) binds `editDraft.meta.ShotCount` and `editDraft.meta.ShotCountNote`.

- [ ] **Step 1: Write the failing pytest**

Create `ignition/tests/test_tool_shot_inputs.py`:

```python
"""Shot-count / shot-limit input handling on the Config Tool Tools screen.

The two shot fields are ia.input.text-field, so Perspective writes STRINGS
back into view.custom.editDraft.meta. The die manager types thousands
separators ("1,000,000"). Before this change Tool.update() parsed with
int(float(v)), which fails on a comma and fell back to None -- silently
clearing the shot limit. These tests pin the pure helpers:

  * a comma'd value parses to an int; garbage is REJECTED, never None'd
  * the loaded meta seeds both fields as formatted strings, so a
    text-field writeback of the same text does not dirty the draft
  * a shot-count change without a note is refused before any write

Run: python -m pytest ignition/tests/test_tool_shot_inputs.py
"""

import ast
import io
import json
import os

import pytest

MODULE = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python",
    "BlueRidge", "Parts", "Tool", "code.py",
)

WANTED = ("_parseShots", "_formatShots", "_metaForEditor", "_shotEdits")


def load_helpers(path=MODULE):
    """Exec only the self-contained helpers, so the test needs no Ignition."""
    src = io.open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    keep = [n for n in tree.body
            if isinstance(n, ast.FunctionDef) and n.name in WANTED]
    ns = {}
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    return ns


@pytest.fixture(scope="module")
def h():
    ns = load_helpers()
    missing = [n for n in WANTED if n not in ns]
    if missing:
        pytest.fail("helper(s) missing from the module: %s" % ", ".join(missing))
    return ns


TOOL_ROW = {
    "Id": 7, "Code": "DM0124", "Name": "6MA die", "Description": None,
    "ToolTypeCode": "Die", "ShotCount": 812400, "ShotLimit": 1000000,
    "DeprecatedAt": None,
}


@pytest.mark.parametrize("text,expected", [
    ("1,000,000", 1000000),
    (" 850 000 ", 850000),
    ("0", 0),
    (1200, 1200),
])
def test_parse_accepts_separators(h, text, expected):
    assert h["_parseShots"](text, "Shot Limit") == (expected, None)


@pytest.mark.parametrize("blank", [None, "", "   "])
def test_parse_blank_is_none_without_error(h, blank):
    assert h["_parseShots"](blank, "Shot Limit") == (None, None)


@pytest.mark.parametrize("bad", ["12a", "1.5", "-5", "1,00x"])
def test_parse_rejects_garbage(h, bad):
    value, error = h["_parseShots"](bad, "Shot Limit")
    assert value is None
    assert error == "Shot Limit must be a whole number of shots (got '%s')." % bad.strip()


def test_format(h):
    assert h["_formatShots"](850000) == "850,000"
    assert h["_formatShots"](0) == "0"
    assert h["_formatShots"](None) == ""
    assert h["_formatShots"]("") == ""


def test_meta_seeds_formatted_strings(h):
    meta = h["_metaForEditor"](dict(TOOL_ROW))
    assert meta["ShotCount"] == "812,400"
    assert meta["ShotLimit"] == "1,000,000"
    assert meta["ShotCountLoaded"] == 812400
    assert meta["ShotCountNote"] == ""
    assert meta["Description"] == ""
    assert meta["deprecated"] is False


def test_meta_blank_limit(h):
    row = dict(TOOL_ROW, ShotLimit=None)
    assert h["_metaForEditor"](row)["ShotLimit"] == ""


def test_text_field_writeback_does_not_dirty(h):
    """The dirty compare is jsonEncode(editDraft) != jsonEncode(selected);
    a text field writing back the same string must be a no-op."""
    baseline = h["_metaForEditor"](dict(TOOL_ROW))
    draft = dict(baseline)
    draft["ShotCount"] = str(draft["ShotCount"])
    draft["ShotLimit"] = str(draft["ShotLimit"])
    assert json.dumps(draft, sort_keys=True) == json.dumps(baseline, sort_keys=True)


def _data(**over):
    base = {"ShotLimit": "1,000,000", "ShotCount": "812,400",
            "ShotCountLoaded": 812400, "ShotCountNote": ""}
    base.update(over)
    return base


def test_edits_unchanged_count(h):
    e = h["_shotEdits"](_data())
    assert e == {"error": None, "shotLimit": 1000000, "shotCount": 812400,
                 "shotCountChanged": False, "note": None}


def test_edits_changed_count_needs_note(h):
    e = h["_shotEdits"](_data(ShotCount="850,000", ShotCountNote="  "))
    assert e["error"] == "Enter a note explaining the shot count change."


def test_edits_changed_count_with_note(h):
    e = h["_shotEdits"](_data(ShotCount="850,000", ShotCountNote=" from die card "))
    assert e == {"error": None, "shotLimit": 1000000, "shotCount": 850000,
                 "shotCountChanged": True, "note": "from die card"}


def test_edits_blank_count_is_an_error(h):
    e = h["_shotEdits"](_data(ShotCount=""))
    assert e["error"] == "Current Shots cannot be blank."


def test_edits_bad_limit_is_an_error_not_a_clear(h):
    e = h["_shotEdits"](_data(ShotLimit="1,0O0"))
    assert e["error"] == "Shot Limit must be a whole number of shots (got '1,0O0')."


def test_edits_blank_limit_clears(h):
    e = h["_shotEdits"](_data(ShotLimit=""))
    assert e["error"] is None
    assert e["shotLimit"] is None
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python -m pytest ignition/tests/test_tool_shot_inputs.py -q`
Expected: every test errors with `helper(s) missing from the module: _parseShots, _formatShots, _metaForEditor, _shotEdits`.

- [ ] **Step 3: Add the pure helpers**

In `ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py`, insert directly **above** `def getOne(toolId):` (these must not reference any module globals or imports -- the pytest execs them alone):

```python
# -----------------------------------------------------------------------------
# Shot-field helpers (pure -- exec'd by ignition/tests/test_tool_shot_inputs.py)
#
# Both shot fields are text-fields so the die manager can type "1,000,000".
# Values are seeded as formatted strings (a text-field writes strings back,
# so an int baseline would latch the dirty flag) and parsed on save. Bad
# input is an error -- never a silent NULL.
# -----------------------------------------------------------------------------

def _parseShots(value, label):
    """(int, None) for a whole number (commas/spaces allowed), (None, None)
    for blank, (None, message) for anything else."""
    if value is None:
        return (None, None)
    if isinstance(value, bool):
        return (None, "%s must be a whole number of shots (got '%s')." % (label, value))
    try:
        integerTypes = (int, long)  # Jython 2.7
    except NameError:
        integerTypes = (int,)       # CPython 3 (pytest)
    if isinstance(value, integerTypes):
        return (int(value), None)
    text = ("%s" % value).strip()
    if text == "":
        return (None, None)
    digits = text.replace(",", "").replace(" ", "")
    if not digits.isdigit():
        return (None, "%s must be a whole number of shots (got '%s')." % (label, text))
    return (int(digits), None)


def _formatShots(value):
    """850000 -> '850,000'; None / '' -> ''."""
    if value is None or value == "":
        return ""
    return "{:,}".format(int(value))


def _metaForEditor(row):
    """Tool_Get row -> the meta dict the Tools header binds to."""
    meta = dict(row)
    meta["deprecated"] = meta.get("DeprecatedAt") is not None
    # Nullable text renders as literal "null" in a bidi text-field; seed "".
    if meta.get("Description") is None:
        meta["Description"] = ""
    meta["ShotLimit"] = _formatShots(meta.get("ShotLimit"))
    loaded = meta.get("ShotCount")
    meta["ShotCountLoaded"] = int(loaded) if loaded is not None else 0
    meta["ShotCount"] = _formatShots(meta["ShotCountLoaded"])
    meta["ShotCountNote"] = ""
    return meta


def _shotEdits(data):
    """Validate the header's shot fields. Returns
    {error, shotLimit, shotCount, shotCountChanged, note}."""
    out = {"error": None, "shotLimit": None, "shotCount": None,
           "shotCountChanged": False, "note": None}
    shotLimit, err = _parseShots(data.get("ShotLimit"), "Shot Limit")
    if err:
        out["error"] = err
        return out
    shotCount, err = _parseShots(data.get("ShotCount"), "Current Shots")
    if err:
        out["error"] = err
        return out
    if shotCount is None:
        out["error"] = "Current Shots cannot be blank."
        return out
    loaded = data.get("ShotCountLoaded")
    loaded = int(loaded) if loaded is not None else 0
    note = ("%s" % (data.get("ShotCountNote") or "")).strip()
    out["shotLimit"] = shotLimit
    out["shotCount"] = shotCount
    out["shotCountChanged"] = shotCount != loaded
    if out["shotCountChanged"]:
        if not note:
            out["error"] = "Enter a note explaining the shot count change."
            return out
        out["note"] = note
    return out
```

- [ ] **Step 4: Run pytest to verify it passes**

Run: `python -m pytest ignition/tests/test_tool_shot_inputs.py -q`
Expected: all pass. Also run `python -m pytest ignition/tests -q` -> the existing `test_location_sort_order.py` still passes.

- [ ] **Step 5: Wire `getOne` and `update`**

Replace the body of `getOne` after the `row is None` check (the `row["deprecated"] = ...` line through `return row`) with:

```python
    return _metaForEditor(row)
```

(`_metaForEditor` now owns the Description / ShotLimit coercions the removed comments described.)

Replace `update(data)` entirely with:

```python
def update(data):
    """Update an existing Tool. data: the header meta -- {Id, Name,
    Description, DieRankCode, StatusCode, ShotLimit, ShotCount,
    ShotCountLoaded, ShotCountNote}. Code is immutable per the proc.

    Legs, each its own proc/transaction, short-circuiting on failure:
      1. Tools.Tool_Update            Name / Description / DieRank / ShotLimit
      2. Tools.Tool_CorrectShotCount  only when ShotCount != ShotCountLoaded
      3. Tools.Tool_UpdateStatus      when a StatusCode is passed
    Shot fields are validated first (_shotEdits) so a bad number or a
    missing note writes nothing. After any failure the screen reloads the
    tool, which shows the true state.
    """
    data = _u(data) or {}
    BlueRidge.Common.Util.log("data=%s" % data)

    toolId = data.get("Id")
    if toolId is None:
        return {"Status": 0, "Message": "Id is required for update"}

    shots = _shotEdits(data)
    if shots["error"]:
        return {"Status": 0, "Message": shots["error"]}

    dieRankId = _lookupDieRankIdByCode(data.get("DieRankCode"))
    appUserId = BlueRidge.Common.Util._currentAppUserId()
    description = (data.get("Description") or "").strip() or None

    updateResult = BlueRidge.Common.Db.execMutation(
        "parts/Tool_Update",
        {
            "id":          toolId,
            "name":        data.get("Name"),
            "description": description,
            "dieRankId":   dieRankId,
            "shotLimit":   shots["shotLimit"],
            "appUserId":   appUserId,
        },
    )
    if not updateResult.get("Status"):
        return updateResult

    if shots["shotCountChanged"]:
        shotResult = BlueRidge.Common.Db.execMutation(
            "parts/Tool_CorrectShotCount",
            {
                "id":                toolId,
                "shotCount":         shots["shotCount"],
                "expectedShotCount": int(data.get("ShotCountLoaded") or 0),
                "note":              shots["note"],
                "appUserId":         appUserId,
            },
        )
        if not shotResult.get("Status"):
            return shotResult

    statusCode = data.get("StatusCode")
    if statusCode:
        statusResult = BlueRidge.Common.Db.execMutation(
            "parts/Tool_UpdateStatus",
            {
                "id":         toolId,
                "statusCode": statusCode,
                "appUserId":  appUserId,
            },
        )
        if not statusResult.get("Status"):
            return statusResult

    return updateResult
```

In the module header docstring, under `update(data)`, add:

```
#       Also runs Tools.Tool_CorrectShotCount when the header's Current
#       Shots differs from the loaded count (note required).
```

- [ ] **Step 6: Create the named query**

`ignition/projects/Core/ignition/named-query/parts/Tool_CorrectShotCount/query.sql`:

```sql
EXEC Tools.Tool_CorrectShotCount
    @Id                = :id,
    @ShotCount         = :shotCount,
    @ExpectedShotCount = :expectedShotCount,
    @Note              = :note,
    @AppUserId         = :appUserId
```

`ignition/projects/Core/ignition/named-query/parts/Tool_CorrectShotCount/resource.json`:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
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
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-17T12:00:00Z"
    },
    "parameters": [
      { "type": "Parameter", "identifier": "id",                "sqlType": 3 },
      { "type": "Parameter", "identifier": "shotCount",         "sqlType": 3 },
      { "type": "Parameter", "identifier": "expectedShotCount", "sqlType": 3 },
      { "type": "Parameter", "identifier": "note",              "sqlType": 7 },
      { "type": "Parameter", "identifier": "appUserId",         "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 7: Scan and smoke-test the NQ on the gateway**

Run (PowerShell, repo root): `.\scan.ps1` -> Expected: scan accepted, no errors.
In the Designer Script Console (MPP_Config project), with a real Dev die id and its current count from `SELECT Id, ShotCount FROM Tools.Tool WHERE ToolTypeId = (SELECT Id FROM Tools.ToolType WHERE Code='Die') AND DeprecatedAt IS NULL`:

```python
print BlueRidge.Parts.Tool.update(dict(BlueRidge.Parts.Tool.getOne(<id>), ShotCount="bogus"))
```
Expected: `{'Status': 0, 'Message': "Current Shots must be a whole number of shots (got 'bogus')."}` and nothing written. (Do not run a real correction against Dev here -- Task 4 does it through the screen.)

- [ ] **Step 8: Commit**

```bash
git add ignition/tests/test_tool_shot_inputs.py ignition/projects/Core/ignition/script-python/BlueRidge/Parts/Tool/code.py ignition/projects/Core/ignition/named-query/parts/Tool_CorrectShotCount/query.sql ignition/projects/Core/ignition/named-query/parts/Tool_CorrectShotCount/resource.json
git commit -m "feat(tools): shot fields accept commas; header save runs the shot-count correction"
```

---

### Task 3: Tools view -- Current Shots field and note row

**Files:**
- Create: `tools/edit_tools_view_shot_count.py`
- Modify (via the script): `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/Tools/view.json`

**Interfaces:**
- Consumes: `editDraft.meta.ShotCount` (formatted str), `ShotCountLoaded` (int), `ShotCountNote` (str) from `getOne` (Task 2). The existing Save button already passes the whole `editDraft.meta` to `Tool.update`, and already reloads via `getOne` on success -- no script changes.

**Why a script:** this is an existing view. Designer serialises `=`, `'`, `<`, `>`, `&` as `=`-style escapes, which defeats text edits. The script round-trips the JSON and re-applies those escapes; a dry run of the round-trip against the current file differs only on two expressions inside the row this task replaces. **Close the Tools view in Designer before running it** (or close Designer), then scan.

- [ ] **Step 1: Write the edit script**

Create `tools/edit_tools_view_shot_count.py`:

```python
"""One-off edit of the Config Tool Tools view (2026-09-17 shot-count correction).

  * FieldShotCount: "Total Shots" read-only label -> "Current Shots" text field
    bound bidirectionally to view.custom.editDraft.meta.ShotCount.
  * New FieldRowShotCountNote under FieldRowShotLimit, shown only while the
    typed count differs from the loaded one.
  * custom.selected / custom.editDraft defaults: drop the pickled live row,
    seed the full empty meta shape (incl. ShotCountLoaded / ShotCountNote).

Re-runnable: it rebuilds the targeted nodes from scratch each time.
Close the view in Designer first, then run scan.ps1.

Usage: python tools/edit_tools_view_shot_count.py [--check]
"""

import io
import json
import sys

VIEW = ("ignition/projects/MPP_Config/com.inductiveautomation.perspective/"
        "views/BlueRidge/Views/Parts/Tools/view.json")

BS = chr(92)
ESC = {"=": BS + "u003d", "<": BS + "u003c", ">": BS + "u003e",
       "'": BS + "u0027", "&": BS + "u0026"}


def dump(obj):
    """json.dumps(indent=2) with GSON's html-safe escapes inside strings."""
    s = json.dumps(obj, indent=2, ensure_ascii=False)
    out, i, n, instr = [], 0, len(s), False
    while i < n:
        c = s[i]
        if instr:
            if c == BS:
                out.append(s[i:i + 2])
                i += 2
                continue
            if c == '"':
                instr = False
            elif c in ESC:
                c = ESC[c]
        elif c == '"':
            instr = True
        out.append(c)
        i += 1
    return "".join(out)


def find(node, name):
    if isinstance(node, dict):
        if node.get("meta", {}).get("name") == name:
            return node
        for v in node.values():
            hit = find(v, name)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find(v, name)
            if hit is not None:
                return hit
    return None


def find_parent(node, name):
    if isinstance(node, dict):
        for c in node.get("children", []) or []:
            if c.get("meta", {}).get("name") == name:
                return node
        for v in node.values():
            hit = find_parent(v, name)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find_parent(v, name)
            if hit is not None:
                return hit
    return None


EMPTY_META = {
    "Id": None, "ToolTypeId": None, "ToolTypeCode": "", "ToolTypeName": "",
    "HasCavities": False, "Code": "", "Name": "", "Description": "",
    "DieRankId": None, "DieRankCode": None, "DieRankName": None,
    "StatusCodeId": None, "StatusCode": "", "StatusName": "",
    "CreatedAt": None, "UpdatedAt": None, "CreatedByUserId": None,
    "UpdatedByUserId": None, "DeprecatedAt": None,
    "ShotCount": "", "ShotLimit": "", "ShotsRemaining": None,
    "PercentOfLimit": None, "IsNearLimit": False, "IsOverLimit": False,
    "ShotCountLoaded": 0, "ShotCountNote": "", "deprecated": False,
}

ENABLED_EXPR = "!{view.custom.selected.meta.deprecated}"
CHANGED_EXPR = ("{view.custom.editDraft.meta.ShotCount} != "
                "{view.custom.selected.meta.ShotCount}")


def text_input(name, path):
    return {
        "meta": {"name": name},
        "propConfig": {
            "props.enabled": {"binding": {"config": {"expression": ENABLED_EXPR},
                                          "type": "expr"}},
            "props.text": {"binding": {"config": {"bidirectional": True, "path": path},
                                       "type": "property"}},
        },
        "props": {"deferUpdates": False,
                  "style": {"classes": "search-input", "width": "100%"}},
        "type": "ia.input.text-field",
    }


def label(name, text):
    return {"meta": {"name": name},
            "props": {"style": {"classes": "field-label"}, "text": text},
            "type": "ia.display.label"}


def apply(view):
    root = view["root"]

    # 1. Current Shots field
    field = find(root, "FieldShotCount")
    assert field is not None, "FieldShotCount not found"
    field["children"] = [
        label("LabelShotCount", "Current Shots"),
        text_input("InputShotCount", "view.custom.editDraft.meta.ShotCount"),
    ]

    # 2. Shot Limit input commits on keystroke too (Save reads the draft)
    limit = find(root, "InputShotLimit")
    assert limit is not None, "InputShotLimit not found"
    limit.setdefault("props", {})["deferUpdates"] = False

    # 3. Note row directly under FieldRowShotLimit
    header = find_parent(root, "FieldRowShotLimit")
    assert header is not None, "FieldRowShotLimit parent not found"
    kids = [c for c in header["children"]
            if c.get("meta", {}).get("name") != "FieldRowShotCountNote"]
    at = [c.get("meta", {}).get("name") for c in kids].index("FieldRowShotLimit") + 1
    note_row = {
        "children": [{
            "children": [
                label("LabelShotCountNote", "Shot Count Change Note (required)"),
                text_input("InputShotCountNote", "view.custom.editDraft.meta.ShotCountNote"),
            ],
            "meta": {"name": "FieldShotCountNote"},
            "position": {"basis": "0", "grow": 1},
            "props": {"direction": "column",
                      "style": {"classes": "field", "gap": "2px"}},
            "type": "ia.container.flex",
        }],
        "meta": {"name": "FieldRowShotCountNote"},
        "propConfig": {
            # position.display, like FieldRowShotLimit: the row takes no
            # space until the typed count differs from the loaded one.
            "position.display": {"binding": {"config": {"expression": CHANGED_EXPR},
                                             "type": "expr"}},
        },
        "props": {"style": {"classes": "field-row", "gap": "12px"}},
        "type": "ia.container.flex",
    }
    kids.insert(at, note_row)
    header["children"] = kids

    # 4. Clean, fully-shaped custom defaults (no pickled live row)
    view.setdefault("custom", {})
    view["custom"]["selected"] = {"meta": dict(EMPTY_META)}
    view["custom"]["editDraft"] = {"meta": dict(EMPTY_META)}
    return view


def main():
    raw = io.open(VIEW, encoding="utf-8", newline="").read()
    out = dump(apply(json.loads(raw)))
    if raw.endswith("\n") and not out.endswith("\n"):
        out += "\n"
    if "--check" in sys.argv:
        print("would change" if out != raw else "no change")
        return
    io.open(VIEW, "w", encoding="utf-8", newline="").write(out)
    print("wrote %s" % VIEW)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it and inspect the diff**

Run: `python tools/edit_tools_view_shot_count.py`
Expected: `wrote ignition/.../Parts/Tools/view.json`.
Run: `git diff --stat -- ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/Tools/view.json` -> one file, changes confined to the custom block and the shot rows.
Run: `git diff -- <same path> | grep -c '^[-+]'` and eyeball the hunks: only `custom.selected` / `custom.editDraft`, `FieldShotCount`, `InputShotLimit`, and the new `FieldRowShotCountNote`.
Run again: `python tools/edit_tools_view_shot_count.py --check` -> Expected: `no change` (idempotent).

- [ ] **Step 3: Scan and load**

Run: `.\scan.ps1` -> Expected: no errors. Check the gateway `wrapper.log` for a GSON / deserialize error on `Parts/Tools` (a valid-JSON view can still fail schema); expected none.

- [ ] **Step 4: Commit**

```bash
git add tools/edit_tools_view_shot_count.py ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/Tools/view.json
git commit -m "feat(config): Tools header -- editable Current Shots with a change note"
```

---

### Task 4: End-to-end verification on Dev + status docs

**Files:**
- Modify: `PROJECT_STATUS.md` (append-only entry)
- Modify: `docs/superpowers/specs/2026-09-17-tool-shot-count-correction-design.md` (status line + §4/§5 as-built notes)

- [ ] **Step 1: Verify on the screen**

Open the Config Tool Tools screen in the in-app browser (`/tools` on the MPP_Config project) and pick a Dev die. Check, in order:

1. Current Shots and Shot Limit show commas (e.g. `812,400`, `1,000,000`); no "Unsaved changes" indicator on load.
2. Change Shot Limit to `1,200,000`, Save -> toast "Tool saved"; SQL `SELECT ShotLimit FROM Tools.Tool WHERE Id=<id>` = `1200000`.
3. Type `1,2x` in Shot Limit, Save -> error toast "Shot Limit must be a whole number of shots (got '1,2x')."; `ShotLimit` unchanged.
4. Change Current Shots -> the note row appears. Save with the note blank -> error toast "Enter a note explaining the shot count change."; `ShotCount` unchanged.
5. Type a note, Save -> success; note row disappears after reload; SQL `ShotCount` = typed value; newest `Audit.ConfigLog` row for the tool reads `<Code> — <Name> · Shot Count · <old> → <new> · <note>`, and it shows in the Audit Browser.
6. Put Current Shots back to its original value with a note "verification revert", Save.

The in-app browser may not commit text-field input (known limit); if typed values don't reach the draft, do steps 2-6 in a real browser session and verify the results by SQL.

- [ ] **Step 2: Record status**

Append to `PROJECT_STATUS.md` (append-only, under the current recent-changes list):

```
- 2026-09-17 -- **Tools screen: die shot-count correction.** Config Tool Tools header gains an editable **Current Shots** field (die manager's cutover entry / correction) with a mandatory change note, via new `Tools.Tool_CorrectShotCount` (stale-guarded, audited to `Audit.ConfigLog`, never touches `DieCastContribution` or watermarks). Shot Limit and Current Shots accept thousands separators; a non-numeric Shot Limit is now rejected instead of silently cleared. Spec/plan `2026-09-17-tool-shot-count-correction*`. Not yet deployed to prod.
```

In the spec, change `**Status:** Approved (design), not yet built` to `**Status:** Built 2026-09-17 (Dev); not yet deployed`, and add under §4: "As built: the parse/format helpers live in `BlueRidge.Parts.Tool` as private pure functions (`_parseShots`, `_formatShots`, `_metaForEditor`, `_shotEdits`) so `ignition/tests/test_tool_shot_inputs.py` can exec them without a gateway; `Common.Util` is unchanged." and under §5: "As built: the note row uses `position.display` (like `FieldRowShotLimit`) rather than `meta.visible`."

- [ ] **Step 3: Commit**

```bash
git add PROJECT_STATUS.md docs/superpowers/specs/2026-09-17-tool-shot-count-correction-design.md
git commit -m "docs: tool shot-count correction built on Dev"
```

---

## Not in this plan

Prod deployment. When it is scheduled it follows `prod-release-context-pack/`: `Deploy-ProdRelease.ps1` preview / rehearsal / execute for the one repeatable (+ the extended-properties repeatable), a scoped export built with `tools/Build-ChangeExport.ps1` (Core: `named-query/parts/Tool_CorrectShotCount`, `script-python/BlueRidge/Parts/Tool`; MPP_Config: `views/BlueRidge/Views/Parts/Tools`; Core imports first), and a runbook artifact mirrored to `notes/<date>_prod-release-runbook-tool-shot-count.md`.
