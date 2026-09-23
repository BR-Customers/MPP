-- ============================================================
-- Repeatable:  R__Workorder_ufn_DieCastShiftStamp.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: The stale guard for the shift reconciliation screen (spec
--              2026-09-21 sec 8). The screen reads this when it loads and
--              hands it back at save; a different value means somebody wrote
--              to -- or moved something out of -- this shift x press x die in
--              between, and the save is refused rather than applied to a
--              picture that has moved.
--
--              COUNTS as well as MAX ids: a row moved OUT lowers the count
--              without lowering any maximum.
--
--              Rows with a NULL CellLocationId are invisible to this (as they
--              are to the screen): the press is how the whole surface is
--              scoped, and a row without one is not attributable to a press.
-- ============================================================
CREATE OR ALTER FUNCTION Workorder.ufn_DieCastShiftStamp
(
    @ShiftId        BIGINT,
    @CellLocationId BIGINT,
    @ToolId         BIGINT
)
RETURNS NVARCHAR(100)
AS
BEGIN
    DECLARE @CCount INT, @CMax BIGINT, @RCount INT, @RMax BIGINT, @AMax BIGINT;

    SELECT @CCount = COUNT(*), @CMax = ISNULL(MAX(c.Id), 0)
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE c.ShiftId = @ShiftId AND c.CellLocationId = @CellLocationId AND l.ToolId = @ToolId;

    SELECT @RCount = COUNT(*), @RMax = ISNULL(MAX(r.Id), 0)
    FROM Workorder.RejectEvent r
    WHERE r.ShiftId = @ShiftId AND r.CellLocationId = @CellLocationId AND r.ToolId = @ToolId;

    SELECT @AMax = ISNULL(MAX(a.Id), 0)
    FROM Workorder.DieCastCounterAnchor a
    WHERE a.ShiftId = @ShiftId AND a.ToolId = @ToolId
      AND ISNULL(a.CellLocationId, -1) = ISNULL(@CellLocationId, -1);

    RETURN CONCAT(@CCount, N'.', @CMax, N'.', @RCount, N'.', @RMax, N'.', @AMax);
END;
GO
