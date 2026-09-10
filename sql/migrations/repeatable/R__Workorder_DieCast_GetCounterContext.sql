-- ============================================================
-- Repeatable:  R__Workorder_DieCast_GetCounterContext.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-10
-- Version:     1.0
-- Description: Die-cast COUNTER ANCHOR, read side (spec 2026-09-10;
--              migration 0074). The shift's rolling counter total for a die on
--              a press, and where that number came from.
--
--              WHY THIS EXISTS. The die watermark was already computed
--              everywhere it mattered, but the only place it was ever SHOWN
--              was inside the Release dialog's red "that reading is behind
--              ..." advisory -- so the operator could not see the number until
--              they had already collided with it. This proc is what lets both
--              die-cast entry points state it as plain context, before
--              anything is typed.
--
--              SourceKind tells the screen how to talk about the number:
--                'None'   -- nothing recorded yet this shift; total is 0 and
--                            every cavity is credited from 0
--                'Entry'  -- the high-water reading from a recorded shift
--                            output or basket release
--                'Anchor' -- an operator declaration
--                            (Workorder.DieCastCounterAnchor) is the floor;
--                            ReasonName / Note say why, and any entries
--                            recorded since it are already folded in
--
--              Timestamps come back in EASTERN, converted here at the read
--              boundary per repo convention. RecordedBy is Initials, which is
--              what operators recognise (the PIN is only how they sign in).
--
--              FDS-11-011: no OUTPUT params, exactly one result set. ALWAYS
--              returns exactly one row -- an unknown tool or shift comes back
--              as a zero total with SourceKind 'None' rather than an empty
--              set, because both consumers bind nested paths into it and a
--              missing row would render them Quality-Bad.
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCast_GetCounterContext
    @ToolId         BIGINT,
    @ShiftId        BIGINT,
    @CellLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- The press. Resolved the same way every other member of this family
    -- resolves it, or the context would quote a different counter space than
    -- the one the write will use.
    IF @CellLocationId IS NULL AND @ToolId IS NOT NULL
        SELECT TOP 1 @CellLocationId = a.CellLocationId
        FROM Tools.ToolAssignment a
        WHERE a.ToolId = @ToolId AND a.ReleasedAt IS NULL
        ORDER BY a.AssignedAt DESC, a.Id DESC;

    DECLARE @DieCreditedThrough INT = 0;
    IF @ToolId IS NOT NULL AND @ShiftId IS NOT NULL
        SET @DieCreditedThrough = Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @CellLocationId);

    -- The latest anchor, if any.
    DECLARE @AnchorId BIGINT, @AnchorAt DATETIME2(3), @AnchorReading INT,
            @AnchorUserId BIGINT, @ReasonName NVARCHAR(100), @Note NVARCHAR(500);
    SELECT TOP 1
        @AnchorId      = a.Id,
        @AnchorAt      = a.EventAt,
        @AnchorReading = a.DeclaredReading,
        @AnchorUserId  = a.AppUserId,
        @ReasonName    = r.Name,
        @Note          = a.Note
    FROM Workorder.DieCastCounterAnchor a
    INNER JOIN Workorder.DieCastCounterAnchorReason r ON r.Id = a.ReasonId
    WHERE a.ToolId  = @ToolId
      AND a.ShiftId = @ShiftId
      AND ISNULL(a.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
    ORDER BY a.EventAt DESC, a.Id DESC;

    -- The latest CONTRIBUTION recorded after that anchor (or at all, if none).
    -- Strict > matches the watermark functions: an entry at the anchor's exact
    -- millisecond is the one being corrected, so it does not speak for the
    -- number on screen either.
    DECLARE @EntryAt DATETIME2(3), @EntryReading INT, @EntryUserId BIGINT;
    SELECT TOP 1
        @EntryAt      = c.EventAt,
        @EntryReading = c.ShotCounterReading,
        @EntryUserId  = c.AppUserId
    FROM Workorder.DieCastContribution c
    INNER JOIN Lots.Lot l ON l.Id = c.LotId
    WHERE l.ToolId  = @ToolId
      AND c.ShiftId = @ShiftId
      AND ISNULL(c.CellLocationId, -1) = ISNULL(@CellLocationId, -1)
      AND (@AnchorAt IS NULL OR c.EventAt > @AnchorAt)
    ORDER BY c.ShotCounterReading DESC, c.EventAt DESC, c.Id DESC;

    -- Whichever of the two actually IS the watermark gets to name itself. An
    -- entry recorded after an anchor and above it supersedes the anchor as the
    -- explanation, which is exactly what the operator needs to see next time.
    DECLARE @SourceKind NVARCHAR(10) = N'None';
    DECLARE @RecordedAt DATETIME2(3) = NULL, @RecordedByUserId BIGINT = NULL;

    IF @EntryReading IS NOT NULL AND @EntryReading >= ISNULL(@AnchorReading, -1)
    BEGIN
        SET @SourceKind = N'Entry';
        SET @RecordedAt = @EntryAt;
        SET @RecordedByUserId = @EntryUserId;
        SET @ReasonName = NULL; SET @Note = NULL;
    END
    ELSE IF @AnchorId IS NOT NULL
    BEGIN
        SET @SourceKind = N'Anchor';
        SET @RecordedAt = @AnchorAt;
        SET @RecordedByUserId = @AnchorUserId;
    END

    SELECT
        @ToolId                         AS ToolId,
        @ShiftId                        AS ShiftId,
        @CellLocationId                 AS CellLocationId,
        @DieCreditedThrough             AS DieCreditedThrough,
        @SourceKind                     AS SourceKind,
        CAST(@RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                                        AS RecordedAt,
        u.Initials                      AS RecordedBy,
        @ReasonName                     AS ReasonName,
        @Note                           AS Note,
        CAST(CASE WHEN @AnchorId IS NULL THEN 0 ELSE 1 END AS BIT)
                                        AS HasAnchor
    FROM (SELECT 1 AS One) x
    LEFT JOIN Location.AppUser u ON u.Id = @RecordedByUserId;
END;
GO
