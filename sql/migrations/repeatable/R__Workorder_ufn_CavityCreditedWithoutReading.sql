-- ============================================================
-- Repeatable:  R__Workorder_ufn_CavityCreditedWithoutReading.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-08
-- Version:     1.0
-- Description: Pieces credited to a CAVITY in a shift WITHOUT a press counter
--              reading, since the last reading on record for that cavity --
--              "already released this shift" on the Reconcile Shift tab.
--
--              WHY IT EXISTS. Operators release a basket mid-shift by typing
--              the pieces, with no counter reading. Such a credit does not
--              move the cavity watermark (Workorder.ufn_CavityShotWatermark
--              reads readings only), so until now the shift-end entry offered
--              the successor basket the whole reading again -- the same
--              castings credited twice (prod, Machine 11, 2026-10-07: 515
--              released per cavity, then 1,038 offered where 523 was cast).
--
--              WHY IT IS A SEPARATE FIGURE AND NOT PART OF THE WATERMARK. It
--              was folded into the watermark once (ufn_CavityShotWatermark
--              v4.0, prod 2026-10-07 16:32, rolled back the next morning).
--              That hid these pieces inside the SHOT count, and a typed
--              release count is a BASKET total, not a this-shift count: a
--              basket carried over a shift change brings the earlier shift's
--              castings with it. Machine 304, 10-07 Third Shift: 325 castings
--              on the cavity, 359 pieces released -- so the "shots left" went
--              to zero and the screen showed nothing at all. Shots are a fact
--              about the counter and stay untouched. This is a second fact,
--              shown beside it, and the two are allowed to disagree: when the
--              released pieces exceed the shift's castings the difference is
--              a NEGATIVE unaccounted that takes a disposition, never a
--              silent zero.
--
--              THE RULE. SUM(PieceDelta) over this cavity's credit rows in
--              this shift on this press that
--                * carry NO reading,
--                * were written after the cavity's last reading-bearing row
--                  (by row Id -- insertion order, which nothing restamps; a
--                  reading-less credit BEFORE a reading is already inside
--                  that reading's span, because the entry that carried the
--                  reading settled the cavity up to it),
--                * sit after the die's latest counter anchor, exactly like the
--                  watermark (a declared reading restarts the cavity), and
--                * are 'Derived' (Oee.ShiftAttributionSource, 0099). A row a
--                  shift reconciliation wrote or moved is a team lead's
--                  correction, stamped at shift end and possibly negative; it
--                  is not a casting event in this cavity's counter space.
--
--              Same scope keys as ufn_CavityShotWatermark, on purpose: the two
--              answer for the same rows or the screen's arithmetic would not
--              close.
-- ============================================================
CREATE OR ALTER FUNCTION Workorder.ufn_CavityCreditedWithoutReading
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
    DECLARE @AnchorAt DATETIME2(3);
    SELECT TOP 1 @AnchorAt = a.EventAt
    FROM Workorder.DieCastCounterAnchor a
    INNER JOIN Tools.ToolCavity tc ON tc.ToolId = a.ToolId
    WHERE tc.Id     = @ToolCavityId
      AND a.ShiftId = @ShiftId
      AND ISNULL(a.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
    ORDER BY a.EventAt DESC, a.Id DESC;

    DECLARE @LastReadingRowId BIGINT;
    SELECT @LastReadingRowId = MAX(c.Id)
    FROM Workorder.DieCastContribution c
    WHERE c.ToolCavityId = @ToolCavityId
      AND c.ShiftId      = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
      AND (@AnchorAt IS NULL OR c.EventAt > @AnchorAt)
      AND c.ShotCounterReading IS NOT NULL;

    DECLARE @Pieces INT;
    SELECT @Pieces = SUM(c.PieceDelta)
    FROM Workorder.DieCastContribution c
    INNER JOIN Oee.ShiftAttributionSource src ON src.Id = c.ShiftAttributionSourceId
    WHERE c.ToolCavityId = @ToolCavityId
      AND c.ShiftId      = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
      AND (@AnchorAt IS NULL OR c.EventAt > @AnchorAt)
      AND c.ShotCounterReading IS NULL
      AND src.Code = N'Derived'
      AND (@LastReadingRowId IS NULL OR c.Id > @LastReadingRowId);

    RETURN CASE WHEN ISNULL(@Pieces, 0) > 0 THEN @Pieces ELSE 0 END;
END
GO
