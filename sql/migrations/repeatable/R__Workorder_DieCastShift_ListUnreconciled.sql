-- ============================================================
-- Repeatable:  R__Workorder_DieCastShift_ListUnreconciled.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The supervisor dashboard's "shifts not reconciled" tile (spec
--              2026-09-21 sec 6.4): a CLOSED shift x press x die with
--              production on record but no shift-end number -- no counter
--              reading on any contribution, no counter anchor, and no
--              reconciliation header.
--
--              This is a positive finding, not an absence: those LOTs were
--              released with a count and the shift was never settled, which is
--              exactly what Machine 202 did every shift of the week the design
--              was written against. A shift with nothing recorded at all is
--              NOT here -- the MES cannot tell it from a press that did not run.
--
--              One row per shift x press x die; the tile counts them.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShift_ListUnreconciled
    @Days     INT          = 7,
    @AtMoment DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NowUtc DATETIME2(3) = ISNULL(@AtMoment, SYSUTCDATETIME());
    DECLARE @NowEt  DATETIME2(3) = CAST(@NowUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
    DECLARE @FromEt DATETIME2(3) = DATEADD(DAY, -@Days, @NowEt);

    ;WITH g AS (
        SELECT c.ShiftId, c.CellLocationId, l.ToolId,
               COUNT(*) AS Rows, SUM(c.PieceDelta) AS Good, COUNT(c.ShotCounterReading) AS Readings
        FROM Workorder.DieCastContribution c
        INNER JOIN Lots.Lot l ON l.Id = c.LotId
        INNER JOIN Oee.Shift s ON s.Id = c.ShiftId
        WHERE s.ActualEnd IS NOT NULL AND s.ActualStart >= @FromEt AND s.ActualStart <= @NowEt
          AND c.CellLocationId IS NOT NULL AND l.ToolId IS NOT NULL
        GROUP BY c.ShiftId, c.CellLocationId, l.ToolId
    )
    SELECT g.ShiftId,
           CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS ShiftLabel,
           s.ActualStart AS StartEt,
           g.CellLocationId, loc.Code AS PressCode, loc.Name AS PressName,
           g.ToolId, t.Code AS AssetNumber, t.Name AS DieName,
           g.Rows AS ContributionRows, g.Good AS GoodRecorded
    FROM g
    INNER JOIN Oee.Shift s ON s.Id = g.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    INNER JOIN Location.Location loc ON loc.Id = g.CellLocationId
    INNER JOIN Tools.Tool t ON t.Id = g.ToolId
    WHERE g.Readings = 0
      AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastCounterAnchor a
                      WHERE a.ShiftId = g.ShiftId AND a.ToolId = g.ToolId AND a.CellLocationId = g.CellLocationId)
      AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastShiftReconciliation h
                      WHERE h.ShiftId = g.ShiftId AND h.ToolId = g.ToolId AND h.CellLocationId = g.CellLocationId)
    ORDER BY s.ActualStart DESC, loc.Code;
END;
GO
