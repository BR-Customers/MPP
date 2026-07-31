# Shift Boundary Reconcile-to-Now Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace detection-time shift stamping with a single idempotent `Oee.Shift_Reconcile` proc that snaps shift boundaries to the schedule and backfills missed shifts, so `Oee.Shift` rows always line up with the schedule regardless of gateway uptime.

**Architecture:** All boundary logic moves out of the Python ticker into one SQL proc (per the "no business logic in Python" rule). Each 60s tick calls `Oee.Shift_Reconcile @NowLocal`, which resolves the scheduled instance covering now, snaps/closes the open shift, backfills any missed instances (bounded to 7 days), and opens the active instance — as a no-op once already consistent. The Python `tickShiftBoundary` collapses to a guarded one-line delegator.

**Tech Stack:** SQL Server 2022 T-SQL (repeatable migration + tSQL test harness under `sql/tests/`), Ignition Named Query, Jython project script (`BlueRidge.Oee.Shift`).

## Global Constraints

- **Design spec:** `docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md` (authority for all decisions D1–D5).
- **Local time throughout** — the shift subsystem operates in local (Eastern) wall-clock; `Shift_Reconcile` computes boundaries in local time, consistent with `Shift_GetActive` and every existing row. Do NOT introduce UTC conversion (logged as an OI instead). Tests drive explicit `@NowLocal` literals — never wall-clock/`SYSDATETIME()` inside a test assertion path.
- **JDBC status-row contract (FDS-11-011):** no `OUTPUT` params. Every exit path ends with `SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed, @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;`.
- **INSERT-EXEC / inlining:** `Shift_Reconcile` returns a status row and is captured via `INSERT-EXEC` in tests, so it MUST inline its close/insert/open + audit writes — it must NOT `EXEC Oee.Shift_Start` / `Oee.Shift_End`. All rejecting validations run BEFORE `BEGIN TRANSACTION`; `ROLLBACK` only in the `CATCH`. `SET XACT_ABORT ON`. `RAISERROR` (not `THROW`) in `CATCH`.
- **Naming:** proc `Oee.Shift_Reconcile`; file `sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql`. NQ `oee/Shift_Reconcile`. Audit uses `Audit.Audit_LogOperation` with `N'Shift'` entity + `N'ShiftStarted'` / `N'ShiftEnded'` event codes (mirroring `Shift_Start` / `Shift_End`).
- **UpperCamelCase, `NVARCHAR`, `DATETIME2(3)`, `DECIMAL`.** ASCII-only string literals (use `Audit.ufn_MidDot()` for the middle dot; never a literal `·`).
- **Git:** branch `jacques/working`. Stage explicit paths only (never `git add -A`/`-u`). Omit the `Co-Authored-By: Claude` trailer.
- **Deploy:** SQL changes apply to `MPP_MES_Test` via `sql/tests/Run-Tests.ps1`; Ignition script/NQ changes require `.\scan.ps1` from repo root. Never run `Run-Tests.ps1` against `MPP_MES_Dev` (it resets its target).

**TDD note for this plan:** the proc is one artifact whose behaviors interlock (resolution → snap/close → backfill → open). Task 1 establishes the red (stub proc + failing happy-path test); Task 2 implements the *complete* proc and turns the core green; Tasks 3–4 add the remaining spec-behavior acceptance tests. Each of Tasks 3–4 begins by running its new tests and, if any are red, fixing the proc — debug guidance is included per task.

**Weekday reference (all 2026):** Mon `06-08`, Tue `06-09`, Wed `06-10`, Thu `06-11`, Fri `06-12`, Sat `06-13`, Sun `06-14`. (Confirmed against the existing `030_Shift_lifecycle.sql` note that `2026-06-10` is a Wednesday / `2026-06-14` a Sunday.)

**Test fixture schedules (inserted `TEST_R_` prefixed, deprecated-clean each run):**
| Name | StartTime | EndTime | Days | Bitmask |
|---|---|---|---|---|
| `TEST_R_First`  | 07:00 | 15:00 | Mon–Fri | 31 |
| `TEST_R_Second` | 15:00 | 23:00 | Mon–Fri | 31 |
| `TEST_R_Third`  | 23:00 | 07:00 | Tue–Sat | 62 |

To keep the fixture isolated from any real/other schedules, tests pass an explicit `@NowLocal` on days in the `06-08…06-14` week and assert on `TEST_R_`-scheduled rows only. **Deprecate/delete all non-`TEST_R_` schedules' interference by scoping every assertion query to `ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')`.** Because `Shift_GetActive`-style resolution scans ALL active schedules, the fixture setup also deprecates any other schedule whose window could overlap the test week — see Task 1 Step 1.

---

### Task 1: Test scaffolding + stub proc + first failing test

Establishes the deterministic fixture, a do-nothing stub proc so the test file executes, and the first (red) happy-path test.

**Files:**
- Create: `sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql` (stub)
- Create: `sql/tests/0046_Shift_Reconcile/010_reconcile_core.sql`

**Interfaces:**
- Produces: `Oee.Shift_Reconcile @NowLocal DATETIME2(3) = NULL, @MaxBackfillDays INT = 7, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL` → result set `(Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT)`.

- [ ] **Step 1: Write the stub proc**

Create `sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Oee_Shift_Reconcile.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-07-31
-- Version:     0.1 (STUB - full body lands in Task 2)
-- Description: Reconciles Oee.Shift runtime instances to the schedule up to
--              @NowLocal: snaps boundaries, closes stale open shifts at their
--              scheduled end, backfills missed instances (bounded @MaxBackfillDays),
--              and opens the active instance. Idempotent. Local-time (see spec
--              2026-07-31-shift-boundary-reconcile-design.md).
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.Shift_Reconcile
    @NowLocal           DATETIME2(3)  = NULL,
    @MaxBackfillDays    INT           = 7,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Stub';
    DECLARE @ShiftsClosed INT = 0, @ShiftsBackfilled INT = 0, @ShiftOpened BIGINT = NULL;
    SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed,
           @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;
END;
GO
```

- [ ] **Step 2: Write the test file with fixture + first failing test**

Create `sql/tests/0046_Shift_Reconcile/010_reconcile_core.sql`:

```sql
-- =============================================
-- File: 0046_Shift_Reconcile/010_reconcile_core.sql
-- Core reconcile behaviors: open-from-empty, idempotent, snap ragged start.
-- Fixture: TEST_R_First/Second/Third (see plan). Local-time; explicit @NowLocal.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0046_Shift_Reconcile/010_reconcile_core.sql';
GO

-- ---- fixture: clean + (re)create the three TEST_R_ schedules ----
DELETE FROM Oee.Shift
WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';

-- Isolate the test week from any other active schedule that could resolve as
-- "active" for a 06-08..06-14 @NowLocal. Temp-deprecate overlappers; the test
-- restores none (Run-Tests targets the throwaway MPP_MES_Test DB).
UPDATE Oee.ShiftSchedule SET DeprecatedAt = SYSUTCDATETIME()
WHERE DeprecatedAt IS NULL AND Name NOT LIKE N'TEST_R_%';

INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_R_First',  N'First 07-15 Mon-Fri',  '07:00:00', '15:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Second', N'Second 15-23 Mon-Fri', '15:00:00', '23:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Third',  N'Third 23-07 Tue-Sat',  '23:00:00', '07:00:00', 62, '2020-01-01', 1);
GO

-- =============================================
-- Test 1: open-from-empty. Wed 06-10 10:00 -> First active, opens at 07:00.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r1 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;

DECLARE @FirstId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @openStart NVARCHAR(30) = (
    SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift
    WHERE ShiftScheduleId = @FirstId AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.open] First opened at scheduled 07:00',
     @Expected = N'2026-06-10 07:00:00.000', @Actual = @openStart;

DECLARE @openCnt NVARCHAR(10) = CAST(
    (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL
        AND ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.open] exactly one open shift',
     @Expected = N'1', @Actual = @openCnt;
GO

-- ---- cleanup ----
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 3: Run the test to verify it FAILS**

Run:
```bash
cd sql/tests && ./Run-Tests.ps1 -Filter "0046"
```
Expected: FAIL — `[Reconcile.open] First opened at scheduled 07:00` (stub opens nothing, so `@openStart` is NULL ≠ expected) and `exactly one open shift` = `0`.

- [ ] **Step 4: Commit**

```bash
git add sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql sql/tests/0046_Shift_Reconcile/010_reconcile_core.sql
git commit -m "test(shift): failing scaffold for Shift_Reconcile core behavior"
```

---

### Task 2: Implement the complete `Oee.Shift_Reconcile` proc

Replace the stub with the full implementation. Turns the Task 1 test green and adds idempotent + snap tests.

**Files:**
- Modify: `sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql` (full body)
- Modify: `sql/tests/0046_Shift_Reconcile/010_reconcile_core.sql` (add Tests 2–3)

**Interfaces:**
- Consumes: `Oee.ShiftSchedule` (Id, Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, DeprecatedAt), `Oee.Shift` (Id, ShiftScheduleId, ActualStart, ActualEnd), `Audit.Audit_LogOperation`, `Audit.ufn_MidDot()`, `Audit.ufn_TruncateActivity()`.
- Produces: the reconcile behavior contract used by Tasks 3–5.

- [ ] **Step 1: Replace the proc body with the full implementation**

Overwrite `sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Oee_Shift_Reconcile.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-07-31
-- Version:     1.0
-- Description: Reconciles Oee.Shift runtime instances to the schedule up to
--              @NowLocal. Idempotent. LOCAL TIME (matches Shift_GetActive).
--              Behaviors (see spec 2026-07-31-shift-boundary-reconcile-design):
--                (A) snap the open shift's ragged start to its scheduled boundary
--                (B) close a stale open shift at ITS scheduled end (ShiftEnded)
--                (C) backfill missed instances in the gap, bounded @MaxBackfillDays
--                (D) open the active instance (ShiftStarted); NULL active = gap = no open
--              Inlines all mutations + audit (captured via INSERT-EXEC; must not
--              EXEC sibling status-row procs). Rejections before BEGIN TRAN;
--              ROLLBACK only in CATCH. No OUTPUT params (FDS-11-011).
-- Change Log:
--   2026-07-31 - 1.0 - Initial version (replaces per-tick start/end orchestration).
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.Shift_Reconcile
    @NowLocal           DATETIME2(3)  = NULL,
    @MaxBackfillDays    INT           = 7,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ShiftsClosed INT = 0, @ShiftsBackfilled INT = 0, @ShiftOpened BIGINT = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.Shift_Reconcile';
    DECLARE @Params NVARCHAR(MAX) = (
        SELECT @NowLocal AS NowLocal, @MaxBackfillDays AS MaxBackfillDays, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- Parameter validation (before any transaction) ----
        IF @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (AppUserId).';
            SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed,
                   @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;
            RETURN;
        END

        DECLARE @Now DATETIME2(3) = ISNULL(@NowLocal, SYSDATETIME());   -- LOCAL, deliberately
        IF @MaxBackfillDays IS NULL OR @MaxBackfillDays < 0 SET @MaxBackfillDays = 7;
        DECLARE @BackfillFloor DATETIME2(3) = DATEADD(DAY, -@MaxBackfillDays, @Now);

        -- ============================================================
        -- Resolve the ACTIVE scheduled instance covering @Now.
        -- Mirrors Oee.Shift_GetActive's day-bit + window logic, yielding the
        -- concrete StartLocal/EndLocal. NULL row => uncovered gap.
        -- ============================================================
        DECLARE @NowDate DATE = CAST(@Now AS DATE);
        DECLARE @NowTime TIME(0) = CAST(@Now AS TIME(0));
        DECLARE @IsoDow INT = (DATEPART(WEEKDAY, @Now) + @@DATEFIRST + 5) % 7 + 1;
        DECLARE @TodayBit INT = POWER(2, @IsoDow - 1);
        DECLARE @PrevBit  INT = POWER(2, (CASE WHEN @IsoDow = 1 THEN 7 ELSE @IsoDow - 1 END) - 1);

        DECLARE @ActiveSchedId BIGINT = NULL, @ActiveStart DATETIME2(3) = NULL, @ActiveEnd DATETIME2(3) = NULL;

        ;WITH cand AS (
            SELECT TOP 1
                ss.Id,
                CASE WHEN ss.EndTime > ss.StartTime
                          THEN CAST(@NowDate AS DATETIME2(3)) + ss.StartTime
                     WHEN ss.EndTime < ss.StartTime AND @NowTime >= ss.StartTime
                          THEN CAST(@NowDate AS DATETIME2(3)) + ss.StartTime
                     ELSE CAST(DATEADD(DAY,-1,@NowDate) AS DATETIME2(3)) + ss.StartTime
                END AS StartLocal,
                CASE WHEN ss.EndTime > ss.StartTime
                          THEN CAST(@NowDate AS DATETIME2(3)) + ss.EndTime
                     WHEN ss.EndTime < ss.StartTime AND @NowTime >= ss.StartTime
                          THEN CAST(DATEADD(DAY,1,@NowDate) AS DATETIME2(3)) + ss.EndTime
                     ELSE CAST(@NowDate AS DATETIME2(3)) + ss.EndTime
                END AS EndLocal
            FROM Oee.ShiftSchedule ss
            WHERE ss.DeprecatedAt IS NULL
              AND ss.EffectiveFrom <= @NowDate
              AND (
                    ( ss.EndTime > ss.StartTime AND (ss.DaysOfWeekBitmask & @TodayBit) <> 0
                      AND @NowTime >= ss.StartTime AND @NowTime < ss.EndTime )
                    OR ( ss.EndTime < ss.StartTime AND (ss.DaysOfWeekBitmask & @TodayBit) <> 0
                      AND @NowTime >= ss.StartTime )
                    OR ( ss.EndTime < ss.StartTime AND (ss.DaysOfWeekBitmask & @PrevBit) <> 0
                      AND @NowTime < ss.EndTime )
                  )
            ORDER BY ss.EffectiveFrom DESC, ss.Id DESC
        )
        SELECT @ActiveSchedId = Id, @ActiveStart = StartLocal, @ActiveEnd = EndLocal FROM cand;

        -- ---- Current open shift (B3 guarantees <= 1) ----
        DECLARE @OpenId BIGINT = NULL, @OpenSchedId BIGINT = NULL, @OpenStart DATETIME2(3) = NULL;
        SELECT TOP 1 @OpenId = Id, @OpenSchedId = ShiftScheduleId, @OpenStart = ActualStart
        FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC;

        -- ---- FAST PATH: already consistent -> no-op ----
        IF @ActiveSchedId IS NOT NULL AND @OpenId IS NOT NULL
           AND @OpenSchedId = @ActiveSchedId AND @OpenStart = @ActiveStart
        BEGIN
            SET @Status = 1; SET @Message = N'No change; timeline matches schedule.';
            SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed,
                   @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;
            RETURN;
        END

        -- ---- Derive the open shift's scheduled EndLocal (for stale close) ----
        DECLARE @OpenSchedEnd DATETIME2(3) = NULL;
        IF @OpenId IS NOT NULL
            SELECT @OpenSchedEnd = CASE WHEN ss.EndTime > ss.StartTime
                        THEN CAST(CAST(@OpenStart AS DATE) AS DATETIME2(3)) + ss.EndTime
                        ELSE CAST(DATEADD(DAY,1,CAST(@OpenStart AS DATE)) AS DATETIME2(3)) + ss.EndTime END
            FROM Oee.ShiftSchedule ss WHERE ss.Id = @OpenSchedId;

        -- ============================================================
        -- Mutation (atomic)
        -- ============================================================
        BEGIN TRANSACTION;

        -- (A) Open shift IS the active instance but ragged -> snap start.
        IF @OpenId IS NOT NULL AND @ActiveSchedId IS NOT NULL
           AND @OpenSchedId = @ActiveSchedId AND @OpenStart <> @ActiveStart
        BEGIN
            UPDATE Oee.Shift SET ActualStart = @ActiveStart WHERE Id = @OpenId;
        END

        -- (B) Open shift is STALE (no active, or different schedule) -> close at scheduled end.
        --     Mirror of Oee.Shift_End (ActualEnd + ShiftEnded audit).
        IF @OpenId IS NOT NULL AND (@ActiveSchedId IS NULL OR @OpenSchedId <> @ActiveSchedId)
        BEGIN
            DECLARE @CloseAt DATETIME2(3) = ISNULL(@OpenSchedEnd, @Now);
            IF @CloseAt < @OpenStart SET @CloseAt = @Now;   -- never end before start
            UPDATE Oee.Shift SET ActualEnd = @CloseAt WHERE Id = @OpenId;
            SET @ShiftsClosed = 1;

            DECLARE @EndName NVARCHAR(100) = (SELECT Name FROM Oee.ShiftSchedule WHERE Id = @OpenSchedId);
            DECLARE @EndActivity NVARCHAR(500) = Audit.ufn_TruncateActivity(
                @EndName + N' ' + Audit.ufn_MidDot() + N' Shift ' + Audit.ufn_MidDot()
                + N' Ended ' + CONVERT(NVARCHAR(23), @CloseAt, 121));
            EXEC Audit.Audit_LogOperation
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                @LogEntityTypeCode = N'Shift', @EntityId = @OpenId, @LogEventTypeCode = N'ShiftEnded',
                @LogSeverityCode = N'Info', @Description = @EndActivity, @OldValue = NULL, @NewValue = NULL;
        END

        -- (C) Backfill missed instances in the gap (lastEnd, activeStart), bounded.
        IF @ActiveSchedId IS NOT NULL
        BEGIN
            DECLARE @GapStart DATETIME2(3) = (SELECT MAX(ActualEnd) FROM Oee.Shift WHERE ActualEnd IS NOT NULL);
            IF @GapStart IS NOT NULL AND @GapStart >= @BackfillFloor AND @GapStart < @ActiveStart
            BEGIN
                DECLARE @FromDate DATE = CAST(@GapStart AS DATE);
                DECLARE @ToDate   DATE = CAST(@ActiveStart AS DATE);

                DECLARE @Backfilled TABLE (Id BIGINT, SchedId BIGINT, StartLocal DATETIME2(3), EndLocal DATETIME2(3));

                ;WITH d AS (
                    SELECT @FromDate AS D
                    UNION ALL SELECT DATEADD(DAY,1,D) FROM d WHERE D < @ToDate
                ),
                inst AS (
                    SELECT ss.Id AS SchedId,
                           CAST(d.D AS DATETIME2(3)) + ss.StartTime AS StartLocal,
                           CASE WHEN ss.EndTime > ss.StartTime
                                THEN CAST(d.D AS DATETIME2(3)) + ss.EndTime
                                ELSE CAST(DATEADD(DAY,1,d.D) AS DATETIME2(3)) + ss.EndTime END AS EndLocal
                    FROM d CROSS JOIN Oee.ShiftSchedule ss
                    WHERE ss.DeprecatedAt IS NULL AND ss.EffectiveFrom <= d.D
                      AND (ss.DaysOfWeekBitmask
                           & POWER(2, ((DATEPART(WEEKDAY, d.D) + @@DATEFIRST + 5) % 7 + 1) - 1)) <> 0
                )
                INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
                OUTPUT inserted.Id, inserted.ShiftScheduleId, inserted.ActualStart, inserted.ActualEnd
                    INTO @Backfilled (Id, SchedId, StartLocal, EndLocal)
                SELECT i.SchedId, i.StartLocal, i.EndLocal, N'Backfilled by Shift_Reconcile'
                FROM inst i
                WHERE i.StartLocal >= @GapStart AND i.StartLocal < @ActiveStart AND i.StartLocal >= @BackfillFloor
                  AND NOT EXISTS (
                      SELECT 1 FROM Oee.Shift s
                      WHERE s.ActualStart < i.EndLocal AND (s.ActualEnd IS NULL OR s.ActualEnd > i.StartLocal))
                OPTION (MAXRECURSION 366);

                SET @ShiftsBackfilled = (SELECT COUNT(*) FROM @Backfilled);

                -- Audit each backfilled (born-closed) shell: ShiftStarted then ShiftEnded.
                DECLARE @bfId BIGINT, @bfSched BIGINT, @bfStart DATETIME2(3), @bfEnd DATETIME2(3), @bfName NVARCHAR(100);
                DECLARE bf CURSOR LOCAL FAST_FORWARD FOR
                    SELECT b.Id, b.SchedId, b.StartLocal, b.EndLocal, ss.Name
                    FROM @Backfilled b JOIN Oee.ShiftSchedule ss ON ss.Id = b.SchedId;
                OPEN bf; FETCH NEXT FROM bf INTO @bfId, @bfSched, @bfStart, @bfEnd, @bfName;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DECLARE @bfStartAct NVARCHAR(500) = Audit.ufn_TruncateActivity(
                        @bfName + N' ' + Audit.ufn_MidDot() + N' Shift ' + Audit.ufn_MidDot()
                        + N' Started ' + CONVERT(NVARCHAR(23), @bfStart, 121) + N' (backfilled)');
                    EXEC Audit.Audit_LogOperation
                        @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                        @LogEntityTypeCode = N'Shift', @EntityId = @bfId, @LogEventTypeCode = N'ShiftStarted',
                        @LogSeverityCode = N'Info', @Description = @bfStartAct, @OldValue = NULL, @NewValue = NULL;
                    DECLARE @bfEndAct NVARCHAR(500) = Audit.ufn_TruncateActivity(
                        @bfName + N' ' + Audit.ufn_MidDot() + N' Shift ' + Audit.ufn_MidDot()
                        + N' Ended ' + CONVERT(NVARCHAR(23), @bfEnd, 121) + N' (backfilled)');
                    EXEC Audit.Audit_LogOperation
                        @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                        @LogEntityTypeCode = N'Shift', @EntityId = @bfId, @LogEventTypeCode = N'ShiftEnded',
                        @LogSeverityCode = N'Info', @Description = @bfEndAct, @OldValue = NULL, @NewValue = NULL;
                    FETCH NEXT FROM bf INTO @bfId, @bfSched, @bfStart, @bfEnd, @bfName;
                END
                CLOSE bf; DEALLOCATE bf;
            END
        END

        -- (D) Open the active instance if not already open.
        IF @ActiveSchedId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL)
        BEGIN
            INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
            VALUES (@ActiveSchedId, @ActiveStart, NULL, NULL);
            SET @ShiftOpened = CAST(SCOPE_IDENTITY() AS BIGINT);

            DECLARE @OpName NVARCHAR(100) = (SELECT Name FROM Oee.ShiftSchedule WHERE Id = @ActiveSchedId);
            DECLARE @OpAct NVARCHAR(500) = Audit.ufn_TruncateActivity(
                @OpName + N' ' + Audit.ufn_MidDot() + N' Shift ' + Audit.ufn_MidDot()
                + N' Started ' + CONVERT(NVARCHAR(23), @ActiveStart, 121));
            EXEC Audit.Audit_LogOperation
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                @LogEntityTypeCode = N'Shift', @EntityId = @ShiftOpened, @LogEventTypeCode = N'ShiftStarted',
                @LogSeverityCode = N'Info', @Description = @OpAct, @OldValue = NULL, @NewValue = NULL;
        END

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Reconciled.';
        SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed,
               @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Shift', @EntityId = NULL,
                @LogEventTypeCode = N'ShiftStarted', @FailureReason = @Message,
                @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH

        SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed,
               @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
```

- [ ] **Step 2: Run Task 1's test to verify it now PASSES**

Run: `cd sql/tests && ./Run-Tests.ps1 -Filter "0046"`
Expected: PASS — First opened at `2026-06-10 07:00:00.000`, one open shift.

- [ ] **Step 3: Add idempotent + snap tests**

Append into `010_reconcile_core.sql` **before** the `-- ---- cleanup ----` block:

```sql
-- =============================================
-- Test 2: idempotent. Re-run at the same @Now -> no-op, no duplicate.
-- =============================================
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r2 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;
DECLARE @noop NVARCHAR(10) = (SELECT CASE WHEN ShiftsClosed = 0 AND ShiftsBackfilled = 0
    AND ShiftOpened IS NULL THEN N'1' ELSE N'0' END FROM @r2);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.idem] second run is a no-op', @Expected = N'1', @Actual = @noop;
DECLARE @rowCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift
    WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.idem] still exactly one row', @Expected = N'1', @Actual = @rowCnt;
GO

-- =============================================
-- Test 3: snap a ragged open start (07:03 -> 07:00), no new rows.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DECLARE @Fid BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@Fid, '2026-06-10T07:03:11', NULL);
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r3 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;
DECLARE @snapped NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift
    WHERE ShiftScheduleId = @Fid AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.snap] ragged start snapped to 07:00',
     @Expected = N'2026-06-10 07:00:00.000', @Actual = @snapped;
DECLARE @snapCnt NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift
    WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%')) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Reconcile.snap] no new rows created', @Expected = N'1', @Actual = @snapCnt;
GO
```

- [ ] **Step 4: Run tests to verify all three PASS**

Run: `cd sql/tests && ./Run-Tests.ps1 -Filter "0046"`
Expected: PASS on all `[Reconcile.open]`, `[Reconcile.idem]`, `[Reconcile.snap]` assertions. If snap fails with the start unchanged, verify branch (A)'s `@OpenStart <> @ActiveStart` comparison and that resolution returned `@ActiveStart = 2026-06-10 07:00`.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Oee_Shift_Reconcile.sql sql/tests/0046_Shift_Reconcile/010_reconcile_core.sql
git commit -m "feat(shift): Oee.Shift_Reconcile snap/idempotent/open core"
```

---

### Task 3: Backfill & boundary-crossing acceptance tests

Prove close-at-scheduled-end, single-boundary crossing, and full-timeline backfill including the overnight Third Shift (the reported bug).

**Files:**
- Create: `sql/tests/0046_Shift_Reconcile/020_reconcile_backfill.sql`

**Interfaces:**
- Consumes: `Oee.Shift_Reconcile` (Task 2), the `TEST_R_` fixture (re-declared in this file).

- [ ] **Step 1: Write the backfill test file**

Create `sql/tests/0046_Shift_Reconcile/020_reconcile_backfill.sql`:

```sql
-- =============================================
-- File: 0046_Shift_Reconcile/020_reconcile_backfill.sql
-- Close-at-scheduled-end, single boundary, and missed-boundary backfill
-- (incl. overnight Third). Local-time; explicit @NowLocal.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0046_Shift_Reconcile/020_reconcile_backfill.sql';
GO

DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
UPDATE Oee.ShiftSchedule SET DeprecatedAt = SYSUTCDATETIME()
WHERE DeprecatedAt IS NULL AND Name NOT LIKE N'TEST_R_%';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_R_First',  N'First 07-15 Mon-Fri',  '07:00:00', '15:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Second', N'Second 15-23 Mon-Fri', '15:00:00', '23:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Third',  N'Third 23-07 Tue-Sat',  '23:00:00', '07:00:00', 62, '2020-01-01', 1);
GO
DECLARE @F BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @S BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Second');
DECLARE @T BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Third');

-- =============================================
-- Test 1: single clean boundary. Open First (07:00); now = Wed 15:05 -> Second.
--   First closes at 15:00; Second opens at 15:00; 0 backfilled.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F,@S,@T);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@F, '2026-06-10T07:00:00', NULL);
DECLARE @b1 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @b1 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T15:05:00', @AppUserId = 1;

DECLARE @firstEnd NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualEnd, 121) FROM Oee.Shift WHERE ShiftScheduleId=@F);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.single] First closed at 15:00',
     @Expected = N'2026-06-10 15:00:00.000', @Actual = @firstEnd;
DECLARE @secStart NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift WHERE ShiftScheduleId=@S AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.single] Second opened at 15:00',
     @Expected = N'2026-06-10 15:00:00.000', @Actual = @secStart;
DECLARE @bf1 NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @b1);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.single] nothing backfilled', @Expected = N'0', @Actual = @bf1;
GO

-- =============================================
-- Test 2: overnight backfill (the reported bug). Open Second (Wed 15:00);
--   now = Thu 08:00 -> First. Missed: Second-end 23:00, Third 23:00->07:00.
--   Expect: Second closed 06-10 23:00; Third row 06-10 23:00 -> 06-11 07:00;
--           First open 06-11 07:00; backfilled = 1.
-- =============================================
DECLARE @F2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @S2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Second');
DECLARE @T2 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Third');
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F2,@S2,@T2);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@S2, '2026-06-10T15:00:00', NULL);
DECLARE @b2 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @b2 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-11T08:00:00', @AppUserId = 1;

DECLARE @secEnd NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualEnd, 121) FROM Oee.Shift WHERE ShiftScheduleId=@S2);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] Second closed at 06-10 23:00',
     @Expected = N'2026-06-10 23:00:00.000', @Actual = @secEnd;

DECLARE @thirdRange NVARCHAR(60) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) + N' | ' + CONVERT(NVARCHAR(30), ActualEnd, 121)
    FROM Oee.Shift WHERE ShiftScheduleId=@T2);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] Third backfilled 23:00->07:00',
     @Expected = N'2026-06-10 23:00:00.000 | 2026-06-11 07:00:00.000', @Actual = @thirdRange;

DECLARE @firstOpen NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift WHERE ShiftScheduleId=@F2 AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] First open at 06-11 07:00',
     @Expected = N'2026-06-11 07:00:00.000', @Actual = @firstOpen;

DECLARE @bf2 NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @b2);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.overnight] exactly one shift backfilled', @Expected = N'1', @Actual = @bf2;
GO

-- =============================================
-- Test 3: full-day backfill. Open First (Wed 07:00); now = Thu 08:00 -> First.
--   Missed: First-end 15:00, Second 15-23, Third 23-07. Expect backfilled = 2
--   (Second + Third), First closed 06-10 15:00, new First open 06-11 07:00.
-- =============================================
DECLARE @F3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @S3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Second');
DECLARE @T3 BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Third');
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F3,@S3,@T3);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@F3, '2026-06-10T07:00:00', NULL);
DECLARE @b3 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @b3 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-11T08:00:00', @AppUserId = 1;

DECLARE @bf3 NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @b3);
EXEC test.Assert_IsEqual @TestName = N'[Backfill.fullday] two shifts backfilled', @Expected = N'2', @Actual = @bf3;
DECLARE @totRows NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift WHERE ShiftScheduleId IN (@F3,@S3,@T3)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Backfill.fullday] 4 rows total (First,Second,Third,First)', @Expected = N'4', @Actual = @totRows;
DECLARE @openCnt3 NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL AND ShiftScheduleId IN (@F3,@S3,@T3)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Backfill.fullday] exactly one open (B3)', @Expected = N'1', @Actual = @openCnt3;
GO

DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the backfill tests**

Run: `cd sql/tests && ./Run-Tests.ps1 -Filter "0046"`
Expected: PASS on all `[Backfill.*]` assertions.

Debug guidance if red:
- `Third backfilled 23:00->07:00` wrong/missing → check the backfill CTE day-bit expression (`POWER(2, ((DATEPART(WEEKDAY, d.D)+@@DATEFIRST+5)%7+1)-1)`) and that Third's bitmask 62 includes Wed (start day `06-10`). Also confirm `@GapStart` = the just-closed Second's `ActualEnd` (`06-10 23:00`), and `@ActiveStart` = `06-11 07:00`.
- `two shifts backfilled` returns 1 → the `NOT EXISTS` overlap filter is excluding one; verify the closed First's end (`06-10 15:00`) does not overlap the Second instance (`15:00→23:00`) — the filter is half-open (`s.ActualStart < i.EndLocal AND s.ActualEnd > i.StartLocal`), so an end exactly at a start must NOT count as overlap.

- [ ] **Step 3: Commit**

```bash
git add sql/tests/0046_Shift_Reconcile/020_reconcile_backfill.sql
git commit -m "test(shift): reconcile close/single-boundary/overnight backfill"
```

---

### Task 4: Guardrail, gap & invariant acceptance tests

Prove the 7-day cap, uncovered-gap handling (no open shift), first-ever run, and the B3 single-open invariant.

**Files:**
- Create: `sql/tests/0046_Shift_Reconcile/030_reconcile_guards.sql`

- [ ] **Step 1: Write the guards test file**

Create `sql/tests/0046_Shift_Reconcile/030_reconcile_guards.sql`:

```sql
-- =============================================
-- File: 0046_Shift_Reconcile/030_reconcile_guards.sql
-- 7-day backfill cap, uncovered-gap (no open), first-ever run, B3 invariant.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0046_Shift_Reconcile/030_reconcile_guards.sql';
GO

DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
UPDATE Oee.ShiftSchedule SET DeprecatedAt = SYSUTCDATETIME()
WHERE DeprecatedAt IS NULL AND Name NOT LIKE N'TEST_R_%';
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_R_First',  N'First 07-15 Mon-Fri',  '07:00:00', '15:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Second', N'Second 15-23 Mon-Fri', '15:00:00', '23:00:00', 31, '2020-01-01', 1),
       (N'TEST_R_Third',  N'Third 23-07 Tue-Sat',  '23:00:00', '07:00:00', 62, '2020-01-01', 1);
GO
DECLARE @F BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_First');
DECLARE @S BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Second');
DECLARE @T BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST_R_Third');

-- =============================================
-- Test 1: 7-day cap. A closed shift ended 06-01 23:00 (9 days before now);
--   no open shift. now = Wed 06-10 10:00 -> First. Gap exceeds 7d -> NO backfill,
--   just open First 06-10 07:00.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F,@S,@T);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@S, '2026-06-01T15:00:00', '2026-06-01T23:00:00');
DECLARE @g1 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @g1 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @MaxBackfillDays = 7, @AppUserId = 1;

DECLARE @capBf NVARCHAR(10) = (SELECT CAST(ShiftsBackfilled AS NVARCHAR(10)) FROM @g1);
EXEC test.Assert_IsEqual @TestName = N'[Guard.cap] no backfill beyond 7 days', @Expected = N'0', @Actual = @capBf;
DECLARE @capOpen NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualStart, 121) FROM Oee.Shift WHERE ShiftScheduleId=@F AND ActualEnd IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Guard.cap] current First still opened at 07:00',
     @Expected = N'2026-06-10 07:00:00.000', @Actual = @capOpen;
GO

-- =============================================
-- Test 2: uncovered gap. Stale open Third from Sat 06-13 23:00; now = Sun 06-14
--   09:00 (no schedule covers it). Expect: Third closed at its sched end
--   06-14 07:00; NO open shift remains.
-- =============================================
DECLARE @F2 BIGINT=(SELECT Id FROM Oee.ShiftSchedule WHERE Name=N'TEST_R_First');
DECLARE @S2 BIGINT=(SELECT Id FROM Oee.ShiftSchedule WHERE Name=N'TEST_R_Second');
DECLARE @T2 BIGINT=(SELECT Id FROM Oee.ShiftSchedule WHERE Name=N'TEST_R_Third');
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (@F2,@S2,@T2);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd) VALUES (@T2, '2026-06-13T23:00:00', NULL);
DECLARE @g2 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @g2 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-14T09:00:00', @AppUserId = 1;

DECLARE @gapEnd NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), ActualEnd, 121) FROM Oee.Shift WHERE ShiftScheduleId=@T2);
EXEC test.Assert_IsEqual @TestName = N'[Guard.gap] stale Third closed at sched end 06-14 07:00',
     @Expected = N'2026-06-14 07:00:00.000', @Actual = @gapEnd;
DECLARE @gapOpen NVARCHAR(10) = CAST((SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL AND ShiftScheduleId IN (@F2,@S2,@T2)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Guard.gap] no open shift in uncovered gap', @Expected = N'0', @Actual = @gapOpen;
GO

-- =============================================
-- Test 3: first-ever run. Empty table; now = Wed 06-10 10:00 -> opens First,
--   0 backfilled, 0 closed.
-- =============================================
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DECLARE @g3 TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @g3 EXEC Oee.Shift_Reconcile @NowLocal = '2026-06-10T10:00:00', @AppUserId = 1;
DECLARE @firstEver NVARCHAR(20) = (SELECT CASE WHEN ShiftsClosed=0 AND ShiftsBackfilled=0 AND ShiftOpened IS NOT NULL THEN N'1' ELSE N'0' END FROM @g3);
EXEC test.Assert_IsEqual @TestName = N'[Guard.first] first-ever opens current, no backfill/close', @Expected = N'1', @Actual = @firstEver;
GO

DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'TEST_R_%';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the guards tests**

Run: `cd sql/tests && ./Run-Tests.ps1 -Filter "0046"`
Expected: PASS on all `[Guard.*]`.

Debug guidance if red:
- `[Guard.cap]` backfills anyway → `@BackfillFloor = DATEADD(DAY,-7,@Now)` = `06-03`; the anchor `@GapStart = 06-01 23:00` is `< @BackfillFloor`, so the `IF @GapStart >= @BackfillFloor` guard must skip block (C). Verify the comparison direction.
- `[Guard.gap]` leaves an open shift → branch (B) close condition must fire when `@ActiveSchedId IS NULL` (the `(@ActiveSchedId IS NULL OR @OpenSchedId <> @ActiveSchedId)` predicate); and branch (D) opens only `IF @ActiveSchedId IS NOT NULL`.

- [ ] **Step 3: Commit**

```bash
git add sql/tests/0046_Shift_Reconcile/030_reconcile_guards.sql
git commit -m "test(shift): reconcile 7d-cap, uncovered-gap, first-ever, B3"
```

---

### Task 5: Wire the ticker + Named Query

Point the gateway timer at the new proc via a thin guarded delegator and a `Query`-typed NQ.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/Shift/code.py`
- Create: `ignition/projects/Core/ignition/named-query/oee/Shift_Reconcile/query.sql`
- Create: `ignition/projects/Core/ignition/named-query/oee/Shift_Reconcile/resource.json`

**Interfaces:**
- Consumes: `Oee.Shift_Reconcile` proc; `BlueRidge.Common.Db.execMutation`, `BlueRidge.Common.Util._currentAppUserId` / `.log`.
- Produces: `BlueRidge.Oee.Shift.reconcile(nowLocal=None, appUserId=None, terminalLocationId=None)` and a rewritten guarded `tickShiftBoundary(nowLocal=None)` (still the timer entrypoint — `handleTimerEvent.py` is unchanged).

- [ ] **Step 1: Create the NQ query.sql**

Create `ignition/projects/Core/ignition/named-query/oee/Shift_Reconcile/query.sql`:

```sql
EXEC Oee.Shift_Reconcile
    @NowLocal           = :nowLocal,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId
```

- [ ] **Step 2: Create the NQ resource.json**

Create `ignition/projects/Core/ignition/named-query/oee/Shift_Reconcile/resource.json` (mirrors `Shift_Start`'s — `type: "Query"` because the proc returns a status row; `sqlType` 8 = timestamp, 3 = BIGINT):

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
      "timestamp": "2026-07-31T12:00:00Z"
    },
    "parameters": [
      {
        "type": "Parameter",
        "identifier": "nowLocal",
        "sqlType": 8
      },
      {
        "type": "Parameter",
        "identifier": "appUserId",
        "sqlType": 3
      },
      {
        "type": "Parameter",
        "identifier": "terminalLocationId",
        "sqlType": 3
      }
    ]
  }
}
```

- [ ] **Step 3: Add `reconcile` and rewrite `tickShiftBoundary` in `Shift/code.py`**

At the top of `code.py`, add the Java import alongside the existing imports:

```python
import java.lang
```

Add a new `reconcile` function (place it just above the existing `tickShiftBoundary`):

```python
def reconcile(nowLocal=None, appUserId=None, terminalLocationId=None):
    """Reconcile Oee.Shift instances to the schedule up to nowLocal (LOCAL time).
       Thin wrapper -- all logic in Oee.Shift_Reconcile. Returns
       {Status, Message, ShiftsClosed, ShiftsBackfilled, ShiftOpened}."""
    if appUserId is None:
        appUserId = BlueRidge.Common.Util._currentAppUserId()
    return BlueRidge.Common.Db.execMutation("oee/Shift_Reconcile", {
        "nowLocal":           nowLocal,
        "appUserId":          appUserId,
        "terminalLocationId": terminalLocationId,
    })
```

Replace the **entire** existing `tickShiftBoundary` function body with the guarded delegator:

```python
def tickShiftBoundary(nowLocal=None):
    """Gateway-timer entrypoint (ShiftBoundaryTicker, 60s). Delegates to
       Oee.Shift_Reconcile via reconcile(). Guarded: a gateway timer must never
       throw uncaught (must catch Java Throwables too, not just Python).
       Returns the reconcile status dict, or an error dict on failure."""
    BlueRidge.Common.Util.log("tick nowLocal=%s" % nowLocal, level="debug")
    try:
        return reconcile(nowLocal)
    except (Exception, java.lang.Exception) as e:
        BlueRidge.Common.Util.log("tickShiftBoundary error: %s" % e, level="error")
        return {"Status": 0, "Message": "reconcile error: %s" % e}
```

- [ ] **Step 4: Scan the Ignition resources into the gateway**

Run (from repo root):
```bash
./scan.ps1
```
Expected: JSON with `"scanActive": true` and no error. This registers the new NQ and the updated script.

- [ ] **Step 5: Smoke-verify the wrapper resolves (no exception)**

In the Ignition Designer script console (or a Gateway scripting test), run:
```python
print BlueRidge.Oee.Shift.reconcile()
```
Expected: a dict like `{'Status': 1, 'Message': 'Reconciled.'|'No change...', ...}` — NOT an exception / `Named query not found`. If `Named query not found`, re-run `./scan.ps1` and confirm both NQ files exist on disk.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Oee/Shift/code.py ignition/projects/Core/ignition/named-query/oee/Shift_Reconcile/query.sql ignition/projects/Core/ignition/named-query/oee/Shift_Reconcile/resource.json
git commit -m "feat(shift): route ShiftBoundaryTicker through Oee.Shift_Reconcile"
```

---

### Task 6: Dev seed + picker verification

Provide a repeatable dev seed that reuses the proc to build a clean trailing timeline, then verify the die-cast picker shows a proper last-3 including the overnight Third.

**Files:**
- Create: `sql/scratch/seed_shifts.sql`

**Interfaces:**
- Consumes: `Oee.Shift_Reconcile`, the real (non-`TEST_R_`) `Oee.ShiftSchedule` rows already in `MPP_MES_Dev` (First/Second/Third).

- [ ] **Step 1: Write the dev seed**

Create `sql/scratch/seed_shifts.sql`:

```sql
-- =============================================
-- sql/scratch/seed_shifts.sql
-- DEV-ONLY. Builds a clean trailing shift timeline in MPP_MES_Dev by inserting
-- a single anchor shift ~2 days back at a real boundary, then letting
-- Oee.Shift_Reconcile backfill the full timeline up to now and open the current
-- shift. Reuses the proc, so it also exercises it end-to-end. Local time.
--
-- Run:  sqlcmd -S localhost -d MPP_MES_Dev -E -C -I -i sql/scratch/seed_shifts.sql
-- Safe to re-run: clears prior Oee.Shift rows first (dependent test rows must be
-- clear -- run against a shift-clean dev DB, or delete DowntimeEvent/diecast
-- shift-output rows first).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- FK-safe clear (adjust if your dev DB has dependent rows you want to keep).
DELETE FROM Oee.Shift;

DECLARE @First BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'First Shift' AND DeprecatedAt IS NULL);
IF @First IS NULL
BEGIN
    RAISERROR('No active "First Shift" schedule found in this DB. Seed the real schedules first.', 16, 1);
    RETURN;
END

-- Anchor: a First Shift that ENDED at 15:00 two days ago (a real boundary).
DECLARE @AnchorEnd DATETIME2(3) =
    CAST(DATEADD(DAY, -2, CAST(SYSDATETIME() AS DATE)) AS DATETIME2(3)) + '15:00:00';
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@First, DATEADD(HOUR, -8, @AnchorEnd), @AnchorEnd, N'seed anchor');

-- Reconcile builds every scheduled instance from the anchor up to now + opens current.
DECLARE @U BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500), ShiftsClosed INT, ShiftsBackfilled INT, ShiftOpened BIGINT);
INSERT INTO @r EXEC Oee.Shift_Reconcile @NowLocal = NULL, @MaxBackfillDays = 7, @AppUserId = @U;

SELECT Message, ShiftsBackfilled, ShiftOpened FROM @r;
SELECT s.Id, ss.Name, CONVERT(varchar, s.ActualStart, 120) AS ActualStart,
       CONVERT(varchar, s.ActualEnd, 120) AS ActualEnd
FROM Oee.Shift s JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
ORDER BY s.ActualStart DESC;
GO
```

- [ ] **Step 2: Run the seed against the dev DB**

Run:
```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -I -i sql/scratch/seed_shifts.sql
```
Expected: the final `SELECT` lists a contiguous trailing timeline (…First, Third, Second, First…) with exact `07:00 / 15:00 / 23:00` boundaries and one open (current) shift with `ActualEnd = NULL`. Confirm a `Third Shift` row with `23:00 → 07:00` appears.

- [ ] **Step 3: Verify the picker in the running app**

Open the Die Cast entry page (`DieCastBody`) in Perspective and open the **Reporting Shift** dropdown. Expected: three options, e.g. `First Shift - MM/dd (current)`, then the prior two — one of which is now the overnight `Third Shift`. (`getRecentOptions` already returns the last 3; the data is now clean.)

- [ ] **Step 4: Commit**

```bash
git add sql/scratch/seed_shifts.sql
git commit -m "chore(shift): dev seed_shifts.sql reuses Shift_Reconcile for clean timeline"
```

---

### Task 7: OI log, status docs, and full-suite green

Record the store-UTC divergence as an Open Item, update project status, mark the spec implemented, and confirm the whole test suite passes.

**Files:**
- Modify: `MPP_MES_Open_Issues_Register.md`
- Modify: `PROJECT_STATUS.md`
- Modify: `docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md` (status line)

- [ ] **Step 1: Add the OI entry**

In `MPP_MES_Open_Issues_Register.md`, add a new OI in Part A (use the next free `OI-NN` number — check the file's current max). Entry text:

> **OI-NN — Shift subsystem stores/compares LOCAL time (store-UTC convention divergence).** `Oee.Shift_GetActive` compares `CAST(@Moment AS TIME(0))` against local schedule `StartTime`/`EndTime`; the ticker feeds `system.date.now()` (local); `Oee.Shift.ActualStart`/`ActualEnd` therefore store local wall-clock, and `Oee.Shift_Reconcile` (2026-07-31) intentionally follows suit for consistency. This diverges from the store-UTC convention (CLAUDE.md § SQL design) and is related to OI-36 (UTC-display read sweep). A future change would convert schedule `TIME` → UTC per-date (DST-aware), migrate existing `Oee.Shift` rows, and audit every shift read/display. Not scoped now — flagged for a deliberate decision. Ref spec `docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md` §7.

- [ ] **Step 2: Update PROJECT_STATUS.md**

Add a line under the recent-change narrative noting: shift-boundary ticker replaced by `Oee.Shift_Reconcile` (snap-to-boundary + bounded 7-day backfill); new OI-NN logged for the local-time divergence; dev seed `sql/scratch/seed_shifts.sql`.

- [ ] **Step 3: Flip the spec status line**

In `docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md`, change the `**Status:**` line to:
`**Status:** Implemented 2026-07-31 (proc + tests + ticker wiring + dev seed). OI-NN logged for the local-time divergence.`

- [ ] **Step 4: Run the FULL test suite**

Run:
```bash
cd sql/tests && ./Run-Tests.ps1
```
Expected: full suite passes, including the three `0046_Shift_Reconcile` files. Confirm no regression in `0020_PlantFloor_Foundation/030_Shift_lifecycle.sql` (the untouched `Shift_Start`/`End`/`GetActive` procs).

- [ ] **Step 5: Commit**

```bash
git add MPP_MES_Open_Issues_Register.md PROJECT_STATUS.md docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md
git commit -m "docs(shift): log OI-NN local-time divergence; mark reconcile spec implemented"
```

---

## Self-Review

**Spec coverage:**
- D1 snap-to-boundary → Task 2 branches (A)/(D); Tasks 3–4 assert exact boundaries. ✓
- D2 backfill full timeline → Task 2 block (C); Task 3 Tests 2–3. ✓
- D3 7-day cap → Task 2 `@BackfillFloor`; Task 4 Test 1. ✓
- D4 keep local + OI → Global Constraints; Task 7 OI. ✓
- D5 never rewrite closed shift → Task 2 backfill `NOT EXISTS` overlap + only open-shift snap/close; asserted implicitly by Task 3 Test 1 (closed First not re-touched). ✓
- Idempotency → Task 2 fast path; Task 2 Test 2. ✓
- Uncovered gap leaves no open → Task 4 Test 2. ✓
- First-ever run → Task 4 Test 3. ✓
- B3 invariant → Task 3 Test 3, Task 4 Test 2. ✓
- Inlining/JDBC/no-OUTPUT → Task 2 proc structure + Global Constraints. ✓
- Ticker rewired, never-throws → Task 5. ✓
- Dev seed reuses proc → Task 6. ✓
- NQ typed `Query` → Task 5 Step 2. ✓

**Placeholder scan:** `OI-NN` in Task 7 is an intentional "next free number" lookup with the full entry text supplied; no code placeholders. Timestamps in resource.json are literals. ✓

**Type consistency:** proc signature `(@NowLocal DATETIME2(3), @MaxBackfillDays INT, @AppUserId BIGINT, @TerminalLocationId BIGINT)` and result columns `(Status, Message, ShiftsClosed, ShiftsBackfilled, ShiftOpened)` are identical in the stub (Task 1), full proc (Task 2), NQ (Task 5), wrapper (Task 5), and every test temp-table. `reconcile(nowLocal, appUserId, terminalLocationId)` param names match the NQ `:nowLocal/:appUserId/:terminalLocationId`. ✓
