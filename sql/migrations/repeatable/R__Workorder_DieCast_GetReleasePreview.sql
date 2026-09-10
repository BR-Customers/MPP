-- ============================================================
-- Repeatable:  R__Workorder_DieCast_GetReleasePreview.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-10
-- Version:     1.0
-- Description: Die-cast shot-reading chain (spec 2026-09-09), release side.
--              Pure READ: everything the Release dialog has to put in front of
--              the operator BEFORE they commit, computed here so no arithmetic
--              lives in a binding, an expression or a Jython handler.
--
--              WHY THIS EXISTS. Lots.DieCastLot_Release v2.0 already derives
--              the closing piece delta from a press-counter reading, but the
--              screen neither asked for the reading nor showed what it would
--              do with it -- so an operator closing a basket mid-shift had to
--              go and record shift output FIRST or silently lose that cavity's
--              shots since the last entry, and nothing on the screen said so.
--              The whole point of the reading model is that the operator never
--              subtracts anything; a dialog that shows the subtraction being
--              done is what makes that visible instead of merely true.
--
--              @CounterReading is OPTIONAL and is what the operator has typed
--              so far -- NULL (or a reading behind the watermark) yields
--              NewShots 0 and ReadingState telling the screen why, so the
--              preview is meaningful on first paint and while they are still
--              typing.
--
--              ReadingState: 'None'    -- nothing typed yet
--                            'Behind'  -- reading is below this DIE's watermark
--                                         (the same rejection Release itself
--                                         raises -- surfaced before the press,
--                                         not after)
--                            'Ok'      -- usable
--
--              Columns: LotId, LotName, ToolCavityId, CavityNumber,
--              CavityDescription, ItemId, PartNumber, PieceCount,
--              MaxPieceCount, CreditedThrough (this CAVITY's watermark),
--              DieCreditedThrough (the DIE's -- what the Behind test uses),
--              NewShots, ProjectedPieceCount, BelowStandardAfter (BIT),
--              ReadingState.
--
--              FDS-11-011: no OUTPUT params, one result set, empty set = the
--              LOT is not an open basket (no invented 404). No mutation, no
--              transaction, no audit.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCast_GetReleasePreview
    @LotId          BIGINT,
    @ShiftId        BIGINT       = NULL,
    @CellLocationId BIGINT       = NULL,
    @CounterReading INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ToolId BIGINT, @ToolCavityId BIGINT;
    SELECT @ToolId = l.ToolId, @ToolCavityId = l.ToolCavityId
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.Id = @LotId AND sc.Code = N'Open';

    IF @ToolId IS NULL RETURN;   -- not an open basket: empty set

    -- The press. Both watermarks are scoped by it, so it is resolved exactly
    -- the way Lots.DieCastLot_Release resolves it or the preview would quote
    -- numbers the write would not use.
    IF @CellLocationId IS NULL
        SELECT TOP 1 @CellLocationId = a.CellLocationId
        FROM Tools.ToolAssignment a
        WHERE a.ToolId = @ToolId AND a.ReleasedAt IS NULL
        ORDER BY a.AssignedAt DESC, a.Id DESC;

    DECLARE @CavityWatermark INT =
        Workorder.ufn_CavityShotWatermark(@ToolCavityId, @ShiftId, @CellLocationId);
    DECLARE @DieWatermark INT =
        Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @CellLocationId);

    DECLARE @ReadingState NVARCHAR(20) = N'Ok';
    IF @CounterReading IS NULL                 SET @ReadingState = N'None';
    ELSE IF @CounterReading < @DieWatermark    SET @ReadingState = N'Behind';

    DECLARE @NewShots INT = 0;
    IF @ReadingState = N'Ok'
    BEGIN
        SET @NewShots = @CounterReading - @CavityWatermark;
        IF @NewShots < 0 SET @NewShots = 0;
    END

    SELECT
        l.Id                                   AS LotId,
        l.LotName                              AS LotName,
        tc.Id                                  AS ToolCavityId,
        tc.CavityNumber                        AS CavityNumber,
        tc.Description                         AS CavityDescription,
        l.ItemId                               AS ItemId,
        it.PartNumber                          AS PartNumber,
        l.PieceCount                           AS PieceCount,
        l.MaxPieceCount                        AS MaxPieceCount,
        @CavityWatermark                       AS CreditedThrough,
        @DieWatermark                          AS DieCreditedThrough,
        @NewShots                              AS NewShots,
        l.PieceCount + @NewShots               AS ProjectedPieceCount,
        CAST(CASE WHEN l.MaxPieceCount IS NOT NULL
                       AND (l.PieceCount + @NewShots) * 100 < l.MaxPieceCount * 95
                  THEN 1 ELSE 0 END AS BIT)    AS BelowStandardAfter,
        @ReadingState                          AS ReadingState
    FROM Lots.Lot l
    INNER JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
    LEFT  JOIN Parts.Item       it ON it.Id = l.ItemId
    WHERE l.Id = @LotId;
END;
GO
