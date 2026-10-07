-- ============================================================
-- Repeatable:  R__Workorder_ufn_CavityShotWatermark.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-07
-- Version:     4.0
-- Change:      v4.0 (2026-10-07) -- A RELEASE WITH A COUNT AND NO READING NOW
--              ADVANCES THE CAVITY. Reverses decision D6 / sec 9 of the shift
--              reconciliation spec (2026-09-21), which left such a release
--              invisible here and recorded the consequence as known behaviour:
--              "the breakdown proposes the whole shift again". It did exactly
--              that on prod on 2026-10-07 (Machine 11, 6MA IN 1&5 EX 1&5 - F):
--              three baskets released mid-shift with 515 typed and no reading,
--              then the shift-end entry at reading 1,092 proposed 1,038 for
--              each successor basket instead of 523, and was accepted. The
--              spec's safety net -- "the variance shows the gap" -- cannot
--              fire: the shot count the variance is measured against comes off
--              this same function, so 1,038 shots against 1,038 good reads as
--              zero variance. Operators cannot be made to type a reading at
--              every release (owner, 2026-10-07), so the gap is closed here.
--
--              THE RULE. A credit row with no reading still says the cavity
--              made that many castings. One shot is one casting per cavity, so
--              the cavity is credited through
--
--                  (last reading on record) + (pieces credited WITHOUT a
--                                              reading since that reading)
--
--              "Since" is by row Id, not EventAt: Id is insertion order and
--              nothing restamps it. A reading-less credit written BEFORE the
--              latest reading is already inside that reading's span -- the
--              entry that carried the reading settled the cavity up to it --
--              so it is not added again. With no reading at all this shift,
--              every reading-less credit counts from 0 (or from the anchor).
--
--              ONLY 'Derived' ROWS COUNT (Oee.ShiftAttributionSource, 0099).
--              A row a shift reconciliation wrote or moved is a team lead's
--              correction against the whole picture, is stamped at shift end
--              rather than when the work happened, and may be negative; it is
--              not a casting event in this cavity's counter space.
--
--              WHAT IT IS NOT. It is not exact when the pieces typed at a
--              reading-less release include castings from an EARLIER shift (a
--              basket carried over a shift change that the earlier shift never
--              settled). Those pieces then count against this shift's shots and
--              the successor basket is proposed LOW by that amount, where
--              before v4.0 it was proposed high by the whole release. The
--              figure stays editable and the reconciliation form is the repair.
--
--              Every consumer picks this up with no change of its own, which is
--              the point of doing it here: DieCast_GetShiftOutputBreakdown
--              (ProposedGood, CreditedThrough, NewShots), DieCast_GetReleasePreview
--              and DieCastLot_Release's reading-derived delta all ask this
--              function the same question -- what has this cavity already been
--              credited through. Workorder.ufn_DieShotWatermark is UNTOUCHED:
--              die life still advances only on a real reading, by
--              (reading - die watermark), so nothing is counted twice.
--              Guarded by sql/tests/0022_PlantFloor_DieCast/120_ReadinglessRelease.sql.
--              v3.0 (2026-09-14, die-cast quantity + scrap model, sec 3.6/5.3b)
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
--              credited in a shift -- its "credited-through watermark". Since
--              v4.0 that is the last reading on record PLUS any pieces credited
--              without a reading after it (see the v4.0 note above).
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

    -- v4.0: pieces credited WITHOUT a reading since the last reading on record
    -- (see header). Same scope as the reading above -- cavity, shift, press,
    -- after the anchor -- so the two can never disagree about which rows count.
    DECLARE @LastReadingRowId BIGINT;
    SELECT @LastReadingRowId = MAX(c.Id)
    FROM Workorder.DieCastContribution c
    WHERE c.ToolCavityId = @ToolCavityId
      AND c.ShiftId      = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
      AND (@AnchorAt IS NULL OR c.EventAt > @AnchorAt)
      AND c.ShotCounterReading IS NOT NULL;

    DECLARE @Readingless INT;
    SELECT @Readingless = SUM(c.PieceDelta)
    FROM Workorder.DieCastContribution c
    INNER JOIN Oee.ShiftAttributionSource src ON src.Id = c.ShiftAttributionSourceId
    WHERE c.ToolCavityId = @ToolCavityId
      AND c.ShiftId      = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
      AND (@AnchorAt IS NULL OR c.EventAt > @AnchorAt)
      AND c.ShotCounterReading IS NULL
      AND src.Code = N'Derived'
      AND (@LastReadingRowId IS NULL OR c.Id > @LastReadingRowId);

    IF ISNULL(@Readingless, 0) > 0
        SET @Watermark = @Watermark + @Readingless;

    RETURN @Watermark;
END
GO
