-- =============================================
-- Procedure:   Oee.Dashboard_GetPeriod
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   The OEE dashboard's period header (spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 5.1,
--   6.6, 6.8): which shift anchors the period, its label, and the `< >` steps.
--     @AnchorShiftId NULL -> the last ENDED shift (the screens open on the
--                            last completed shift, never the one in progress).
--     @Step -1 / +1       -> the previous / next shift, production day or week
--                            that has shifts. A Day or Week step anchors on the
--                            LATEST shift of the target day / week. Never past
--                            the last shift: a step with nowhere to go leaves
--                            the anchor unchanged.
--   Production day / week as Oee.ufn_ProductionDay / ufn_ShiftsForPeriod
--   (3rd -> 1st -> 2nd; Monday-Sunday weeks).
--
-- Result set (one row; none for an unknown anchor):
--   AnchorShiftId, Zoom,
--   PeriodLabel       '<schedule> - Tue 10/27' | 'Production day Tue 10/27'
--                     | 'Week of Mon 10/26'
--   IsInProgress      the period includes the shift in progress
--   HasNext           a later shift exists beyond the period
--   IsRecentlyClosed  the anchor shift ended under an hour ago ("entries may
--                     still be arriving", 6.8)
--
-- Read proc: ONE result set, no OUTPUT params (FDS-11-011).
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetPeriod
    @Zoom          NVARCHAR(5),
    @AnchorShiftId BIGINT = NULL,
    @Step          INT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Anchor BIGINT = @AnchorShiftId;
    IF @Anchor IS NULL
        SET @Anchor = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NOT NULL ORDER BY ActualStart DESC, Id DESC);

    IF @Zoom NOT IN (N'Shift', N'Day', N'Week')
       OR NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @Anchor)
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS AnchorShiftId, CAST(NULL AS NVARCHAR(5)) AS Zoom,
               CAST(NULL AS NVARCHAR(100)) AS PeriodLabel, CAST(NULL AS BIT) AS IsInProgress,
               CAST(NULL AS BIT) AS HasNext, CAST(NULL AS BIT) AS IsRecentlyClosed
        WHERE 1 = 0;
        RETURN;
    END

    -- every shift with its production day (Oee.Shift is small: ~1,100 a year)
    DECLARE @S TABLE (ShiftId BIGINT PRIMARY KEY, ActualStart DATETIME2(3), ProductionDay DATE);
    INSERT INTO @S
    SELECT s.Id, s.ActualStart, pd.ProductionDay
    FROM Oee.Shift s CROSS APPLY Oee.ufn_ProductionDay(s.Id) pd;

    DECLARE @AStart DATETIME2(3), @ADay DATE;
    SELECT @AStart = ActualStart, @ADay = ProductionDay FROM @S WHERE ShiftId = @Anchor;
    -- Monday of the anchor's week (1900-01-01 was a Monday; DATEFIRST-independent)
    DECLARE @AWeek DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @ADay) % 7), @ADay);

    -- ---- step ----
    DECLARE @Target BIGINT = NULL, @TDay DATE = NULL;
    IF @Step > 0 AND @Zoom = N'Shift'
        SET @Target = (SELECT TOP 1 ShiftId FROM @S WHERE ActualStart > @AStart ORDER BY ActualStart, ShiftId);
    ELSE IF @Step < 0 AND @Zoom = N'Shift'
        SET @Target = (SELECT TOP 1 ShiftId FROM @S WHERE ActualStart < @AStart ORDER BY ActualStart DESC, ShiftId DESC);
    ELSE IF @Step <> 0
    BEGIN
        IF @Zoom = N'Day'
            SET @TDay = CASE WHEN @Step > 0 THEN (SELECT MIN(ProductionDay) FROM @S WHERE ProductionDay > @ADay)
                             ELSE (SELECT MAX(ProductionDay) FROM @S WHERE ProductionDay < @ADay) END;
        ELSE
            SET @TDay = CASE WHEN @Step > 0 THEN (SELECT MIN(ProductionDay) FROM @S WHERE ProductionDay >= DATEADD(DAY, 7, @AWeek))
                             ELSE (SELECT MAX(ProductionDay) FROM @S WHERE ProductionDay < @AWeek) END;
        IF @TDay IS NOT NULL AND @Zoom = N'Week'
            SET @TDay = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @TDay) % 7), @TDay);
        IF @TDay IS NOT NULL
            SET @Target = (SELECT TOP 1 ShiftId FROM @S
                           WHERE (@Zoom = N'Day'  AND ProductionDay = @TDay)
                              OR (@Zoom = N'Week' AND ProductionDay >= @TDay AND ProductionDay < DATEADD(DAY, 7, @TDay))
                           ORDER BY ActualStart DESC, ShiftId DESC);
    END
    IF @Target IS NOT NULL
    BEGIN
        SET @Anchor = @Target;
        SELECT @AStart = ActualStart, @ADay = ProductionDay FROM @S WHERE ShiftId = @Anchor;
        SET @AWeek = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @ADay) % 7), @ADay);
    END

    -- ---- the period ----
    DECLARE @PeriodEnd DATETIME2(3) = (SELECT MAX(s.ActualStart) FROM Oee.ufn_ShiftsForPeriod(@Zoom, @Anchor) p
                                       INNER JOIN Oee.Shift s ON s.Id = p.ShiftId);
    DECLARE @NowLocal DATETIME2(3) = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));

    SELECT @Anchor AS AnchorShiftId,
           @Zoom   AS Zoom,
           CAST(CASE @Zoom
               WHEN N'Shift' THEN ss.Name + N' - ' + LEFT(DATENAME(WEEKDAY, @ADay), 3) + N' '
                                  + CAST(MONTH(@ADay) AS NVARCHAR(2)) + N'/' + CAST(DAY(@ADay) AS NVARCHAR(2))
               WHEN N'Day'   THEN N'Production day ' + LEFT(DATENAME(WEEKDAY, @ADay), 3) + N' '
                                  + CAST(MONTH(@ADay) AS NVARCHAR(2)) + N'/' + CAST(DAY(@ADay) AS NVARCHAR(2))
               ELSE N'Week of Mon ' + CAST(MONTH(@AWeek) AS NVARCHAR(2)) + N'/' + CAST(DAY(@AWeek) AS NVARCHAR(2))
           END AS NVARCHAR(100)) AS PeriodLabel,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM Oee.ufn_ShiftsForPeriod(@Zoom, @Anchor) p
                                  INNER JOIN Oee.Shift x ON x.Id = p.ShiftId WHERE x.ActualEnd IS NULL)
                     THEN 1 ELSE 0 END AS BIT) AS IsInProgress,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM Oee.Shift x WHERE x.ActualStart > @PeriodEnd)
                     THEN 1 ELSE 0 END AS BIT) AS HasNext,
           CAST(CASE WHEN sh.ActualEnd IS NOT NULL AND sh.ActualEnd > DATEADD(MINUTE, -60, @NowLocal) AND sh.ActualEnd <= @NowLocal
                     THEN 1 ELSE 0 END AS BIT) AS IsRecentlyClosed
    FROM Oee.Shift sh
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = sh.ShiftScheduleId
    WHERE sh.Id = @Anchor;
END
GO
