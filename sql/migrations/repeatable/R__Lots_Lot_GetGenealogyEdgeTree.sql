-- ============================================================
-- Repeatable:  R__Lots_Lot_GetGenealogyEdgeTree.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Recursive edge-walk genealogy for the LOT Genealogy & Traceability
--              report. Unlike the closure-backed Lots.Lot_GetGenealogyTree (which
--              flattens the DAG and loses per-edge quantity above depth 1), this
--              walks the Lots.LotGenealogy EDGE table so each row carries the actual
--              per-edge consumed PieceCount and the true tree depth.
--
--              READ proc (FDS-11-011): no @Status/@Message, no status row, ONE result
--              set, empty set = not found, no OUTPUT params.
--
--              @Direction is Ancestors / Descendants / Both (default), case-insensitive,
--              singular/plural accepted, unrecognized -> Both.
--
--              A path-string cycle guard + OPTION(MAXRECURSION 100) bound the walk;
--              genealogy is a DAG by construction, the guard is defensive. The guard
--              makes emission per DISTINCT PATH from the subject, not per node and not
--              per edge: a node reachable by N distinct paths (a diamond / merge
--              topology) appears N times, once per path, each carrying the real
--              per-edge PieceCount for that path's final hop. Consumers MUST treat the
--              rows as a tree listing (one line per path) and MUST NOT SUM PieceCount
--              across rows -- summing double-counts shared-upstream edges whenever two
--              paths reconverge on a common ancestor.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetGenealogyEdgeTree
    @LotId     BIGINT,
    @Direction NVARCHAR(20) = N'Both'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Dir NVARCHAR(20) =
        CASE LOWER(LTRIM(RTRIM(ISNULL(@Direction, N'Both'))))
            WHEN N'ancestor'    THEN N'Ancestors'
            WHEN N'ancestors'   THEN N'Ancestors'
            WHEN N'descendant'  THEN N'Descendants'
            WHEN N'descendants' THEN N'Descendants'
            WHEN N'both'        THEN N'Both'
            ELSE N'Both'
        END;

    ;WITH Up AS (
        -- Ancestors: seed on the subject's direct parents, recurse up.
        SELECT g.ParentLotId AS RelatedLotId, g.RelationshipTypeId, g.PieceCount,
               1 AS Depth,
               CAST(N'/' + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX)) AS Path
        FROM Lots.LotGenealogy g
        WHERE g.ChildLotId = @LotId
        UNION ALL
        SELECT g.ParentLotId, g.RelationshipTypeId, g.PieceCount, u.Depth + 1,
               CAST(u.Path + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX))
        FROM Lots.LotGenealogy g
        INNER JOIN Up u ON g.ChildLotId = u.RelatedLotId
        WHERE u.Path NOT LIKE N'%/' + CAST(g.ParentLotId AS NVARCHAR(20)) + N'/%'
    ),
    Dn AS (
        -- Descendants: seed on the subject's direct children, recurse down.
        SELECT g.ChildLotId AS RelatedLotId, g.RelationshipTypeId, g.PieceCount,
               1 AS Depth,
               CAST(N'/' + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX)) AS Path
        FROM Lots.LotGenealogy g
        WHERE g.ParentLotId = @LotId
        UNION ALL
        SELECT g.ChildLotId, g.RelationshipTypeId, g.PieceCount, d.Depth + 1,
               CAST(d.Path + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/' AS NVARCHAR(MAX))
        FROM Lots.LotGenealogy g
        INNER JOIN Dn d ON g.ParentLotId = d.RelatedLotId
        WHERE d.Path NOT LIKE N'%/' + CAST(g.ChildLotId AS NVARCHAR(20)) + N'/%'
    )
    SELECT u.RelatedLotId,
           l.LotName        AS RelatedLotName,
           l.ItemId,
           i.PartNumber,
           rt.Name          AS RelationshipName,
           u.PieceCount,
           ISNULL(uom.Code, N'PCS') AS UomCode,
           u.Depth,
           u.Direction
    FROM (
        SELECT RelatedLotId, RelationshipTypeId, PieceCount, Depth,
               CAST(N'Ancestor' AS NVARCHAR(20)) AS Direction
        FROM Up   WHERE @Dir IN (N'Ancestors', N'Both')
        UNION ALL
        SELECT RelatedLotId, RelationshipTypeId, PieceCount, Depth,
               CAST(N'Descendant' AS NVARCHAR(20)) AS Direction
        FROM Dn   WHERE @Dir IN (N'Descendants', N'Both')
    ) u
    INNER JOIN Lots.Lot   l  ON l.Id  = u.RelatedLotId
    INNER JOIN Parts.Item i  ON i.Id  = l.ItemId
    INNER JOIN Lots.GenealogyRelationshipType rt ON rt.Id = u.RelationshipTypeId
    LEFT  JOIN Parts.Uom  uom ON uom.Id = i.UomId
    ORDER BY u.Direction, u.Depth, l.LotName
    OPTION (MAXRECURSION 100);
END;
GO
