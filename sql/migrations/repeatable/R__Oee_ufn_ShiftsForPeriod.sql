-- =============================================
-- Repeatable:  R__Oee_ufn_ShiftsForPeriod.sql
-- Object:      Oee.ufn_ShiftsForPeriod
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: The runtime shifts in an OEE dashboard period (spec
--              docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 5.1, 6.6). @Zoom:
--                Shift  the anchor shift alone
--                Day    every shift in the anchor's production day
--                       (3rd -> 1st -> 2nd, Oee.ufn_ProductionDay)
--                Week   every shift whose production day falls in the anchor's
--                       Monday-Sunday week -- so a week opens with the 3rd
--                       shift starting Sunday 22:30
--              Anything else, or an unknown anchor -> no rows.
--              SortKey orders the set by ActualStart. The Monday is found by
--              day arithmetic from 1900-01-01 (a Monday), so @@DATEFIRST
--              cannot move a week edge.
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftsForPeriod (@Zoom NVARCHAR(5), @AnchorShiftId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH Anchor AS (
        SELECT pd.ProductionDay
        FROM Oee.ufn_ProductionDay(@AnchorShiftId) pd
    ),
    Bounds AS (
        SELECT
            CASE @Zoom
                WHEN N'Day'  THEN a.ProductionDay
                WHEN N'Week' THEN DATEADD(DAY, -(DATEDIFF(DAY, CAST('19000101' AS DATE), a.ProductionDay) % 7), a.ProductionDay)
            END AS FromDay,
            CASE @Zoom
                WHEN N'Day'  THEN a.ProductionDay
                WHEN N'Week' THEN DATEADD(DAY, 6 - (DATEDIFF(DAY, CAST('19000101' AS DATE), a.ProductionDay) % 7), a.ProductionDay)
            END AS ToDay
        FROM Anchor a
        WHERE @Zoom IN (N'Day', N'Week')
    ),
    Hit AS (
        SELECT s.Id AS ShiftId, pd.ProductionDay, s.ActualStart
        FROM Oee.Shift s
        CROSS APPLY Oee.ufn_ProductionDay(s.Id) pd
        WHERE @Zoom = N'Shift' AND s.Id = @AnchorShiftId
        UNION ALL
        SELECT s.Id, pd.ProductionDay, s.ActualStart
        FROM Bounds b
        INNER JOIN Oee.Shift s
                ON s.ActualStart >= DATEADD(DAY, -1, CAST(b.FromDay AS DATETIME2(3)))
               AND s.ActualStart <  DATEADD(DAY,  1, CAST(b.ToDay   AS DATETIME2(3)))
        CROSS APPLY Oee.ufn_ProductionDay(s.Id) pd
        WHERE pd.ProductionDay BETWEEN b.FromDay AND b.ToDay
    )
    SELECT h.ShiftId,
           h.ProductionDay,
           ROW_NUMBER() OVER (ORDER BY h.ActualStart, h.ShiftId) AS SortKey
    FROM Hit h
);
GO
