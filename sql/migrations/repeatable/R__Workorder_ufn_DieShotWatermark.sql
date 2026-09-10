-- ============================================================
-- Repeatable:  R__Workorder_ufn_DieShotWatermark.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-09
-- Version:     1.0
-- Description: Die-cast shot-reading chain (spec 2026-09-09). Returns the
--              press-counter reading through which a DIE has already been
--              counted in a shift, on a given press.
--
--              Consumer: Tools.Tool.ShotCount. Die life advances by
--              (reading now - this watermark) at EVERY event that records a
--              reading -- both Workorder.DieCastShiftOutput_Record and
--              Lots.DieCastLot_Release.
--
--              Why release must also advance it, contrary to the earlier
--              design note that release should never touch ShotCount: a
--              changeover always closes the lots, so the OUTGOING die may
--              never see a shift-output entry at all. Its shots since the last
--              entry would then be lost from its life -- a die silently
--              running past ShotLimit. Incrementing by the DELTA (never the
--              raw reading) cannot double-count, because the watermark
--              advances with each recorded reading:
--                  release at 1450 -> +1450 ;  shift end at 2000 -> +550
--                  total 2000 = the shift's actual shots.
--
--              Scoped by press for the same reason as the cavity watermark --
--              see R__Workorder_ufn_CavityShotWatermark.sql.
--
--              This is DIE-WIDE, so it is deliberately NOT the max of the
--              per-cavity watermarks: crediting one cavity at a release
--              advances the die watermark while every other cavity's stays
--              where it was. Both are right, from one column.
-- ============================================================
CREATE OR ALTER FUNCTION Workorder.ufn_DieShotWatermark
(
    @ToolId         BIGINT,
    @ShiftId        BIGINT,
    @CellLocationId BIGINT
)
RETURNS INT
AS
BEGIN
    IF @ToolId IS NULL OR @ShiftId IS NULL RETURN 0;

    DECLARE @Watermark INT;

    SELECT @Watermark = MAX(c.ShotCounterReading)
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE l.ToolId  = @ToolId
      AND c.ShiftId = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1);

    RETURN ISNULL(@Watermark, 0);
END
GO
