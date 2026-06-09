-- ============================================================
-- Repeatable:  R__Oee_Shift_GetActive.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Returns the SCHEDULED shift (Oee.ShiftSchedule row) that covers
--              a given moment, matched by the day-of-week bitmask + the
--              time-of-day window. This is a CONFIG lookup ("which shift is
--              scheduled now") - distinct from Shift_GetOpen (the open runtime
--              instance).
--
--              DaysOfWeekBitmask (0009): Mon=1, Tue=2, Wed=4, Thu=8, Fri=16,
--              Sat=32, Sun=64. We derive the moment's bit from the ISO
--              day-of-week so the result is independent of @@DATEFIRST:
--                isoDow = (DATEPART(WEEKDAY, d) + @@DATEFIRST + 5) % 7 + 1
--                         -> Mon=1 .. Sun=7  ;  bit = POWER(2, isoDow - 1).
--              Time window: a shift covers [StartTime, EndTime). A shift that
--              spans midnight (EndTime < StartTime) is matched on the day its
--              StartTime falls on, for the late portion, OR the prior day for
--              the early-morning portion - handled below.
--
--              Read proc: ONE result set, AT MOST ONE row, empty = no scheduled
--              shift matches. SINGLE-ROW CONTRACT: if two ShiftSchedules overlap
--              the same moment (mis-configuration), TOP 1 + the deterministic
--              ORDER BY (EffectiveFrom DESC, Id DESC) picks the most recently-
--              effective one as "the active schedule", matching Shift_GetOpen's
--              single-row contract. No OUTPUT params, no audit.
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.Shift_GetActive
    @AtMoment DATETIME2(3) = NULL   -- defaults to now (UTC)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Moment DATETIME2(3) = ISNULL(@AtMoment, SYSUTCDATETIME());
    DECLARE @Date   DATE         = CAST(@Moment AS DATE);
    DECLARE @TimeOfDay TIME(0)   = CAST(@Moment AS TIME(0));

    -- ISO day-of-week (Mon=1 .. Sun=7), @@DATEFIRST-independent.
    DECLARE @IsoDow INT = (DATEPART(WEEKDAY, @Moment) + @@DATEFIRST + 5) % 7 + 1;
    DECLARE @TodayBit INT = POWER(2, @IsoDow - 1);
    -- Bit for "yesterday" (for a midnight-spanning shift's early-morning tail).
    DECLARE @PrevIsoDow INT = CASE WHEN @IsoDow = 1 THEN 7 ELSE @IsoDow - 1 END;
    DECLARE @PrevBit INT = POWER(2, @PrevIsoDow - 1);

    SELECT TOP 1
        ss.Id,
        ss.Name,
        ss.Description,
        ss.StartTime,
        ss.EndTime,
        ss.DaysOfWeekBitmask,
        ss.EffectiveFrom
    FROM Oee.ShiftSchedule ss
    WHERE ss.DeprecatedAt IS NULL
      AND ss.EffectiveFrom <= @Date
      AND (
            -- Same-day shift: window does not cross midnight.
            ( ss.EndTime > ss.StartTime
              AND (ss.DaysOfWeekBitmask & @TodayBit) <> 0
              AND @TimeOfDay >= ss.StartTime
              AND @TimeOfDay <  ss.EndTime )
            OR
            -- Midnight-spanning shift, late portion (today on/after StartTime).
            ( ss.EndTime < ss.StartTime
              AND (ss.DaysOfWeekBitmask & @TodayBit) <> 0
              AND @TimeOfDay >= ss.StartTime )
            OR
            -- Midnight-spanning shift, early-morning tail (started yesterday).
            ( ss.EndTime < ss.StartTime
              AND (ss.DaysOfWeekBitmask & @PrevBit) <> 0
              AND @TimeOfDay <  ss.EndTime )
          )
    ORDER BY ss.EffectiveFrom DESC, ss.Id DESC;
END;
GO
