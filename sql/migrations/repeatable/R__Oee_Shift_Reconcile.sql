-- ============================================================
-- Repeatable:  R__Oee_Shift_Reconcile.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-07-31
-- Version:     1.1
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
--              (A)/(B) discriminate "open shift IS the active instance" by the
--              open shift's SCHEDULED INSTANCE START (@OpenSchedStart), not by
--              ShiftScheduleId alone -- two different calendar days can share
--              the same schedule id (cross-day outage). See fix 1.1.
-- Change Log:
--   2026-07-31 - 1.0 - Initial version (replaces per-tick start/end orchestration).
--   2026-07-31 - 1.1 - Fix: discriminate same-instance by scheduled start, not
--                       schedule id, so a cross-day stale open (same schedule,
--                       different day) is closed + backfilled instead of
--                       silently relabeled (branch A) / skipped (branch B).
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

        -- Boundary math uses DATEADD(SECOND,...) -- schedule times are TIME(0) (whole-second).
        ;WITH cand AS (
            SELECT TOP 1
                ss.Id,
                CASE WHEN ss.EndTime > ss.StartTime
                          THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.StartTime), CAST(@NowDate AS DATETIME2(3)))
                     WHEN ss.EndTime < ss.StartTime AND @NowTime >= ss.StartTime
                          THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.StartTime), CAST(@NowDate AS DATETIME2(3)))
                     ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.StartTime), CAST(DATEADD(DAY,-1,@NowDate) AS DATETIME2(3)))
                END AS StartLocal,
                CASE WHEN ss.EndTime > ss.StartTime
                          THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(@NowDate AS DATETIME2(3)))
                     WHEN ss.EndTime < ss.StartTime AND @NowTime >= ss.StartTime
                          THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(DATEADD(DAY,1,@NowDate) AS DATETIME2(3)))
                     ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(@NowDate AS DATETIME2(3)))
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

        -- ---- Derive the open shift's scheduled StartLocal/EndLocal (for the
        --      same-instance test and stale close). StartLocal discriminates
        --      "open shift IS the active instance" by scheduled INSTANCE START,
        --      not by schedule id alone -- two different calendar days can
        --      share the same ShiftScheduleId (see cross-day regression). ----
        DECLARE @OpenSchedStart DATETIME2(3) = NULL;
        DECLARE @OpenSchedEnd DATETIME2(3) = NULL;
        IF @OpenId IS NOT NULL
            SELECT @OpenSchedStart = DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.StartTime), CAST(CAST(@OpenStart AS DATE) AS DATETIME2(3))),
                   @OpenSchedEnd = CASE WHEN ss.EndTime > ss.StartTime
                        THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(CAST(@OpenStart AS DATE) AS DATETIME2(3)))
                        ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(DATEADD(DAY,1,CAST(@OpenStart AS DATE)) AS DATETIME2(3))) END
            FROM Oee.ShiftSchedule ss WHERE ss.Id = @OpenSchedId;

        -- ============================================================
        -- Mutation (atomic)
        -- ============================================================
        BEGIN TRANSACTION;

        -- (A) Open shift IS the active instance (same scheduled INSTANCE START,
        --     not just same schedule id) but ragged -> snap start.
        IF @OpenId IS NOT NULL AND @ActiveSchedId IS NOT NULL
           AND @OpenSchedId = @ActiveSchedId AND @OpenSchedStart = @ActiveStart AND @OpenStart <> @ActiveStart
        BEGIN
            UPDATE Oee.Shift SET ActualStart = @ActiveStart WHERE Id = @OpenId;
        END

        -- (B) Open shift is STALE (no active; different schedule; OR same
        --     schedule but a different day/instance -- e.g. an outage spanning
        --     a full cycle leaves Monday's First open while Tuesday's First is
        --     now active) -> close at ITS scheduled end.
        --     Mirror of Oee.Shift_End (ActualEnd + ShiftEnded audit).
        IF @OpenId IS NOT NULL AND (@ActiveSchedId IS NULL OR @OpenSchedId <> @ActiveSchedId OR @OpenSchedStart <> @ActiveStart)
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
                           DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.StartTime), CAST(d.D AS DATETIME2(3))) AS StartLocal,
                           CASE WHEN ss.EndTime > ss.StartTime
                                THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(d.D AS DATETIME2(3)))
                                ELSE DATEADD(SECOND, DATEDIFF(SECOND, 0, ss.EndTime), CAST(DATEADD(DAY,1,d.D) AS DATETIME2(3))) END AS EndLocal
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
