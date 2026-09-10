-- ============================================================
-- Repeatable:  R__Workorder_ufn_CavityShotWatermark.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-09
-- Version:     1.0
-- Description: Die-cast shot-reading chain (spec 2026-09-09). Returns the
--              press-counter reading through which a CAVITY has already been
--              credited in a shift -- its "credited-through watermark".
--
--              A basket's credit is (reading now - this watermark). A cavity
--              that has not been settled yet this shift returns 0, so it is
--              credited the whole reading -- which is exactly the pre-change
--              behaviour. Uniform fan-out is not replaced; it becomes the case
--              where nothing rolled over.
--
--              SCOPED BY PRESS (@CellLocationId), and that is load-bearing:
--                * die moved to another press mid-shift -> different
--                  CellLocationId -> watermark 0, so the two presses' counter
--                  spaces never mix;
--                * different die changed onto the same press -> different
--                  Tools.ToolCavity rows entirely -> watermark 0.
--              Both cases reset with no special-casing, matching the floor
--              reality that a changeover always closes the lots, opens new
--              ones, and resets the counter.
--
--              The watermark belongs to the CAVITY, not the basket. If it were
--              per-basket, a gap between releasing one and opening the next
--              would lose shots; on the cavity the successor inherits it
--              whenever it is opened, even hours later.
--
--              Scalar (SQL Server 2022 inlines these). Cardinality is a
--              handful of rows per cavity per shift.
-- ============================================================
CREATE OR ALTER FUNCTION Workorder.ufn_CavityShotWatermark
(
    @ToolCavityId   BIGINT,
    @ShiftId        BIGINT,
    @CellLocationId BIGINT
)
RETURNS INT
AS
BEGIN
    IF @ToolCavityId IS NULL OR @ShiftId IS NULL RETURN 0;

    DECLARE @Watermark INT;

    SELECT @Watermark = MAX(c.ShotCounterReading)
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE l.ToolCavityId = @ToolCavityId
      AND c.ShiftId      = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1);

    RETURN ISNULL(@Watermark, 0);
END
GO
