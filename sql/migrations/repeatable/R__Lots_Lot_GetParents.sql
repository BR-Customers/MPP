-- ============================================================
-- Repeatable:  R__Lots_Lot_GetParents.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: One-hop-up genealogy read: the DIRECT parents of @LotId (Phase 2
--              Task 5 / G3; spec section 4.3). READ proc -- no @Status/@Message, no
--              status row, ONE result set, empty set = not found (FDS-11-011). No
--              OUTPUT params.
--
--              Source is the append-only edge table Lots.LotGenealogy (NOT the
--              closure): rows WHERE ChildLotId = @LotId. Each edge carries its
--              RelationshipType (Split / Merge / Consumption) and the edge
--              PieceCount, so a parent reached by two different relationships shows
--              as two rows -- the read does NOT collapse distinct edges. (A single
--              parent never appears twice for the same relationship because the
--              writers emit one edge per parent->child relationship.)
--
--              Result columns:
--                ParentLotId BIGINT, ParentLotName NVARCHAR(50), ItemId BIGINT,
--                ItemCode NVARCHAR(50), RelationshipTypeCode NVARCHAR(20),
--                RelationshipTypeName NVARCHAR(100), PieceCount INT,
--                EventUserId BIGINT, EventUserName NVARCHAR(200),
--                EventAt DATETIME2(3)
--              ItemCode is Parts.Item.PartNumber. EventUserName is the acting
--              operator resolved from Location.AppUser.DisplayName. Ordered by
--              EventAt then ParentLotName for a stable, chronological listing.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_GetParents
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        g.ParentLotId,
        pl.LotName    AS ParentLotName,
        pl.ItemId,
        i.PartNumber  AS ItemCode,
        rt.Code       AS RelationshipTypeCode,
        rt.Name       AS RelationshipTypeName,
        g.PieceCount,
        g.EventUserId,
        au.DisplayName AS EventUserName,
        g.EventAt
    FROM Lots.LotGenealogy g
    INNER JOIN Lots.Lot                       pl ON pl.Id = g.ParentLotId
    INNER JOIN Parts.Item                     i  ON i.Id  = pl.ItemId
    INNER JOIN Lots.GenealogyRelationshipType rt ON rt.Id = g.RelationshipTypeId
    INNER JOIN Location.AppUser               au ON au.Id = g.EventUserId
    WHERE g.ChildLotId = @LotId
    ORDER BY g.EventAt, pl.LotName;
END;
GO
