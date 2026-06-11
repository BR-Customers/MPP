-- ============================================================
-- Repeatable:  R__Lots_Lot_GetChildren.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: One-hop-down genealogy read: the DIRECT children of @LotId (Phase 2
--              Task 5 / G3; spec section 4.3). READ proc -- no @Status/@Message, no
--              status row, ONE result set, empty set = not found (FDS-11-011). No
--              OUTPUT params. Mirrors Lots.Lot_GetParents but from the parent side.
--
--              Source is the append-only edge table Lots.LotGenealogy: rows WHERE
--              ParentLotId = @LotId. Each edge carries its RelationshipType
--              (Split / Merge / Consumption) and the edge PieceCount. Direct
--              children only -- grandchildren are NOT included (use
--              Lots.Lot_GetGenealogyTree @Direction='Descendants' for the full walk).
--
--              Result columns:
--                ChildLotId BIGINT, ChildLotName NVARCHAR(50), ItemId BIGINT,
--                ItemCode NVARCHAR(50), RelationshipTypeCode NVARCHAR(20),
--                RelationshipTypeName NVARCHAR(100), PieceCount INT,
--                EventAt DATETIME2(3)
--              ItemCode is Parts.Item.PartNumber. Ordered by EventAt then
--              ChildLotName for a stable, chronological listing.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_GetChildren
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        g.ChildLotId,
        cl.LotName    AS ChildLotName,
        cl.ItemId,
        i.PartNumber  AS ItemCode,
        rt.Code       AS RelationshipTypeCode,
        rt.Name       AS RelationshipTypeName,
        g.PieceCount,
        g.EventAt
    FROM Lots.LotGenealogy g
    INNER JOIN Lots.Lot                       cl ON cl.Id = g.ChildLotId
    INNER JOIN Parts.Item                     i  ON i.Id  = cl.ItemId
    INNER JOIN Lots.GenealogyRelationshipType rt ON rt.Id = g.RelationshipTypeId
    WHERE g.ParentLotId = @LotId
    ORDER BY g.EventAt, cl.LotName;
END;
GO
