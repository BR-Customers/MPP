-- ============================================================
-- Repeatable:  R__Workorder_ufn_CavityShotWatermark.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-14
-- Version:     3.0
-- Change:      v3.0 (2026-09-14, die-cast quantity + scrap model, sec 3.6/5.3b)
--              -- reads the stamped Workorder.DieCastContribution.ToolCavityId
--              directly instead of traversing INNER JOIN Lots.Lot. Behaviour-
--              identical: every contribution row still carries a LOT (LotId
--              stays NOT NULL, precisely so a basketless cavity cannot write a
--              watermark-advancing row -- spec 3.6), so the old join and the
--              new column resolve the same cavity for every existing row. This
--              is a pure simplification, pinned neutral by 110_CavityScrap.sql
--              Test 1.
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
--
--              -------------------------------------------------------------
--              v2.0 (2026-09-10, migration 0074) -- COUNTER ANCHOR FLOOR.
--
--              An anchor is recorded against the DIE, and it floors EVERY
--              cavity on that die from that moment:
--
--                  MAX( anchor.DeclaredReading,
--                       MAX(reading) for this cavity AFTER the anchor,
--                       0 )
--
--              That the floor reaches every cavity is the whole reason the
--              anchor is a separate table rather than a contribution row:
--              Workorder.DieCastContribution.LotId is NOT NULL (0045), so a
--              cavity that is Closed, Scrapped, or simply has no open basket
--              could never carry the correction. Flooring here reaches it.
--
--              A counter reset is DeclaredReading = 0, which restores exactly
--              the start-of-shift state for every cavity. No special case.
--
--              The cavity's OWN tool is resolved from Tools.ToolCavity, so the
--              caller does not have to pass it and cannot pass a mismatched
--              one.
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

    -- The latest declaration for this cavity's DIE on this press, if any.
    DECLARE @AnchorReading INT, @AnchorAt DATETIME2(3);
    SELECT TOP 1 @AnchorReading = a.DeclaredReading, @AnchorAt = a.EventAt
    FROM Workorder.DieCastCounterAnchor a
    INNER JOIN Tools.ToolCavity tc ON tc.ToolId = a.ToolId
    WHERE tc.Id     = @ToolCavityId
      AND a.ShiftId = @ShiftId
      AND ISNULL(a.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
    ORDER BY a.EventAt DESC, a.Id DESC;

    DECLARE @Watermark INT;

    -- v3.0: read the stamped cavity instead of traversing the LOT. Behaviour-
    -- identical -- every contribution row still has a LOT (spec 3.6) -- so
    -- this is a simplification, asserted neutral by test 1.
    SELECT @Watermark = MAX(c.ShotCounterReading)
    FROM Workorder.DieCastContribution c
    WHERE c.ToolCavityId = @ToolCavityId
      AND c.ShiftId      = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
      AND (@AnchorAt IS NULL OR c.EventAt > @AnchorAt);

    SET @Watermark = ISNULL(@Watermark, 0);
    IF @AnchorReading IS NOT NULL AND @AnchorReading > @Watermark
        SET @Watermark = @AnchorReading;

    RETURN @Watermark;
END
GO
