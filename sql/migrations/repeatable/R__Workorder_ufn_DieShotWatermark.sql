-- ============================================================
-- Repeatable:  R__Workorder_ufn_DieShotWatermark.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-10
-- Version:     2.0
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
--
--              -------------------------------------------------------------
--              v2.0 (2026-09-10, migration 0074) -- COUNTER ANCHOR FLOOR.
--
--              A MAX cannot be lowered by appending, so a press counter that
--              was reset mid-shift, or a wrong reading entered earlier, left
--              this watermark permanently above every honest reading and
--              blocked the die for the rest of the shift (spec E3 / E4).
--
--              Workorder.DieCastCounterAnchor records an operator declaration
--              -- "as of now this counter reads N" -- and the watermark
--              becomes:
--
--                  MAX( anchor.DeclaredReading,
--                       MAX(reading) over contributions recorded AFTER it,
--                       0 )
--
--              With no anchor the result is byte-for-byte v1.0's. Only the
--              LATEST anchor counts; superseding one means recording another.
--
--              Contributions at exactly the anchor's EventAt are excluded
--              (strict >). That is deliberate: an anchor recorded in the same
--              millisecond as a contribution is correcting it, so the anchor
--              must win.
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

    -- The latest declaration for this (die, shift, press), if any.
    DECLARE @AnchorReading INT, @AnchorAt DATETIME2(3);
    SELECT TOP 1 @AnchorReading = a.DeclaredReading, @AnchorAt = a.EventAt
    FROM Workorder.DieCastCounterAnchor a
    WHERE a.ToolId  = @ToolId
      AND a.ShiftId = @ShiftId
      AND ISNULL(a.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
    ORDER BY a.EventAt DESC, a.Id DESC;

    DECLARE @Watermark INT;

    SELECT @Watermark = MAX(c.ShotCounterReading)
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE l.ToolId  = @ToolId
      AND c.ShiftId = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
      AND (@AnchorAt IS NULL OR c.EventAt > @AnchorAt);

    SET @Watermark = ISNULL(@Watermark, 0);
    IF @AnchorReading IS NOT NULL AND @AnchorReading > @Watermark
        SET @Watermark = @AnchorReading;

    RETURN @Watermark;
END
GO
