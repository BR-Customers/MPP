-- ============================================================
-- Repeatable:  R__Lots_Lot_GetGenealogyTree.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Closure-backed genealogy walk for a LOT (Phase 2 Task 5 / G3; spec
--              section 4.3). READ proc -- no @Status/@Message, no status row, ONE
--              result set, empty set = not found (FDS-11-011 read-proc convention).
--              No OUTPUT params.
--
--              The B4 closure table (Lots.LotGenealogyClosure) makes this O(1) per
--              row -- no recursion -- so Honda year-15 audits stay fast regardless
--              of partition count. The self-row (Depth=0) is excluded via Depth > 0.
--
--                * Ancestors   = closure rows WHERE DescendantLotId = @LotId
--                                AND Depth > 0; the projected LotId is the ANCESTOR.
--                * Descendants = closure rows WHERE AncestorLotId   = @LotId
--                                AND Depth > 0; the projected LotId is the DESCENDANT.
--                * Both (default) = UNION ALL of the two.
--
--              Result columns (one consistent shape across all three branches):
--                LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT,
--                ItemCode NVARCHAR(50), Depth INT, Direction NVARCHAR(20)
--              where LotId is the OTHER LOT in the relationship (the ancestor for an
--              'Ancestor' row, the descendant for a 'Descendant' row) and ItemCode
--              is Parts.Item.PartNumber (the human-facing item identifier).
--
--              *** DEPTH IS INFORMATIONAL, NOT AUTHORITATIVE SHORTEST-PATH ***
--              The closure's stored Depth reflects the ORDER edges were recorded
--              (see R__Lots_LotGenealogy_RecordConsumption header), not the minimum
--              path across all routes. This proc PROJECTS the stored Depth as a
--              descriptive column -- it neither recomputes nor claims a minimal
--              depth. Callers MUST NOT treat Depth as the canonical shortest path.
--              ORDER BY Depth, LotName gives a stable, readable ordering only.
--
--              @Direction is honored case-insensitively (Ancestor/Ancestors,
--              Descendant/Descendants, Both). Any unrecognized value falls back to
--              'Both' (documented default), so a typo never silently returns empty.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_GetGenealogyTree
    @LotId     BIGINT,
    @Direction NVARCHAR(20) = N'Both'
AS
BEGIN
    SET NOCOUNT ON;

    -- Normalize @Direction: case-insensitive, singular/plural accepted, default Both.
    DECLARE @Dir NVARCHAR(20) =
        CASE LOWER(LTRIM(RTRIM(ISNULL(@Direction, N'Both'))))
            WHEN N'ancestor'    THEN N'Ancestors'
            WHEN N'ancestors'   THEN N'Ancestors'
            WHEN N'descendant'  THEN N'Descendants'
            WHEN N'descendants' THEN N'Descendants'
            WHEN N'both'        THEN N'Both'
            ELSE N'Both'   -- unrecognized -> Both (documented fallback)
        END;

    SELECT u.LotId, u.LotName, u.ItemId, u.ItemCode, u.Depth, u.Direction
    FROM (
        -- Ancestors: every LOT that is an ancestor of @LotId.
        SELECT
            c.AncestorLotId AS LotId,
            l.LotName,
            l.ItemId,
            i.PartNumber    AS ItemCode,
            c.Depth,
            CAST(N'Ancestor' AS NVARCHAR(20)) AS Direction
        FROM Lots.LotGenealogyClosure c
        INNER JOIN Lots.Lot   l ON l.Id = c.AncestorLotId
        INNER JOIN Parts.Item i ON i.Id = l.ItemId
        WHERE c.DescendantLotId = @LotId
          AND c.Depth > 0
          AND @Dir IN (N'Ancestors', N'Both')

        UNION ALL

        -- Descendants: every LOT that is a descendant of @LotId.
        SELECT
            c.DescendantLotId AS LotId,
            l.LotName,
            l.ItemId,
            i.PartNumber      AS ItemCode,
            c.Depth,
            CAST(N'Descendant' AS NVARCHAR(20)) AS Direction
        FROM Lots.LotGenealogyClosure c
        INNER JOIN Lots.Lot   l ON l.Id = c.DescendantLotId
        INNER JOIN Parts.Item i ON i.Id = l.ItemId
        WHERE c.AncestorLotId = @LotId
          AND c.Depth > 0
          AND @Dir IN (N'Descendants', N'Both')
    ) u
    ORDER BY u.Direction, u.Depth, u.LotName;
END;
GO
