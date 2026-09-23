-- ============================================================
-- Repeatable:  R__Workorder_DieCastShiftReconciliation_ListMoveTargets.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Where an entry filed against the wrong shift may move: the
--              CLOSED shifts within two of this one (Oee.ufn_ShiftNeighbours),
--              each with what it already holds for this press and die, so
--              moving onto a shift that already has an entry is visible before
--              it happens (spec sec 7.3). Nothing is pre-selected on screen.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastShiftReconciliation_ListMoveTargets
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id AS ShiftId,
           CONVERT(NVARCHAR(5), s.ActualStart, 110) + N' ' + ss.Name AS ShiftLabel,
           s.ActualStart AS StartEt, s.ActualEnd AS EndEt, n.Offset,
           ISNULL(g.Good, 0) AS GoodRecorded
    FROM Oee.ufn_ShiftNeighbours(@ShiftId, 2) n
    INNER JOIN Oee.Shift s ON s.Id = n.ShiftId
    INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
    OUTER APPLY (SELECT SUM(c.PieceDelta) AS Good
                 FROM Workorder.DieCastContribution c
                 INNER JOIN Lots.Lot l ON l.Id = c.LotId
                 WHERE c.ShiftId = s.Id AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId) g
    ORDER BY s.ActualStart;
END;
GO
