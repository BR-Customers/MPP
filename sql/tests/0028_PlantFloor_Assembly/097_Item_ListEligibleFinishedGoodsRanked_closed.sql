-- =============================================
-- File:         0028_PlantFloor_Assembly/097_Item_ListEligibleFinishedGoodsRanked_closed.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-13
-- Description:  Parts.Item_ListEligibleFinishedGoodsRanked v1.2 (stored-procedure review). The
--               four stock subqueries now also carry the literal LotStatusId <> 4 (Closed) so they
--               can seek the 0118 filtered indexes. Pins that CLOSED stock never satisfies a line,
--               in both arms, so the extra predicate cannot change a ranking:
--                 * BOM arm: a Closed LOT with plenty of stock does not satisfy the BOM line;
--                   enough open stock does;
--                 * repack arm (no published BOM): a Closed received LOT does not satisfy the part;
--                   an open received LOT does.
--               Fixture cell: MA1-COMPBR-AOUT. 096_ covers eligibility and recommendation.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/097_Item_ListEligibleFinishedGoodsRanked_closed.sql';
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-097%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P7-RFG-FG';
DELETE b FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P7-RFG-FG';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber IN (N'P7-RFG-FG', N'P7-RFG-RP', N'P7-RFG-CH');
GO

-- ---- fixture ----
--   P7-RFG-FG  FinishedGood with a published BOM: one line, child P7-RFG-CH (Component), QtyPer 2
--   P7-RFG-RP  FinishedGood with NO BOM (pass-through repack)
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @FgType  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @CmpType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-RFG-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@FgType, N'P7-RFG-FG', N'097 finished good (BOM)', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-RFG-RP')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@FgType, N'P7-RFG-RP', N'097 repack part', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P7-RFG-CH')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@CmpType, N'P7-RFG-CH', N'097 component', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-RFG-FG');
DECLARE @Rp BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-RFG-RP');
DECLARE @Ch BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-RFG-CH');
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Fg, @Cell, 0, @Now), (@Rp, @Cell, 0, @Now);
INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Fg, 1, @Now, @Now, 1, @Now);
INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Ch, 2, 1, 1);

-- Only CLOSED stock so far: 100 of the component, 50 received repack parts (status 4 = Closed)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'STG-097-CH-CLOSED', @Ch, 2, 4, 100, 100, @Cell, 1, @Now),
    (N'STG-097-RP-CLOSED', @Rp, 2, 4,  50,  50, @Cell, 1, @Now);
GO

DECLARE @R TABLE (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LinesSatisfied INT, IsRecommended INT);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @S NVARCHAR(40);

INSERT INTO @R EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Cell;
SET @S = ISNULL((SELECT CAST(LinesSatisfied AS NVARCHAR(10)) FROM @R WHERE PartNumber = N'P7-RFG-FG'), N'<missing>');
EXEC test.Assert_IsEqual @TestName = N'[RankedFG v1.2] BOM arm: a Closed LOT with 100 on hand does not satisfy the line (QtyPer 2)', @Expected = N'0', @Actual = @S;
SET @S = ISNULL((SELECT CAST(LinesSatisfied AS NVARCHAR(10)) FROM @R WHERE PartNumber = N'P7-RFG-RP'), N'<missing>');
EXEC test.Assert_IsEqual @TestName = N'[RankedFG v1.2] repack arm: a Closed received LOT does not satisfy the part', @Expected = N'0', @Actual = @S;
GO

-- now OPEN stock: 2 of the component (Good), 1 received repack part (Good)
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @Rp BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-RFG-RP');
DECLARE @Ch BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P7-RFG-CH');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES
    (N'STG-097-CH-GOOD', @Ch, 2, 1, 2, 2, @Cell, 1, @Now),
    (N'STG-097-RP-GOOD', @Rp, 2, 1, 1, 1, @Cell, 1, @Now);
DECLARE @R TABLE (Id BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), LinesSatisfied INT, IsRecommended INT);
DECLARE @S NVARCHAR(40);
INSERT INTO @R EXEC Parts.Item_ListEligibleFinishedGoodsRanked @LocationId = @Cell;
SET @S = ISNULL((SELECT CAST(LinesSatisfied AS NVARCHAR(10)) FROM @R WHERE PartNumber = N'P7-RFG-FG'), N'<missing>');
EXEC test.Assert_IsEqual @TestName = N'[RankedFG v1.2] BOM arm: enough open stock (2) satisfies the line', @Expected = N'1', @Actual = @S;
SET @S = ISNULL((SELECT CAST(LinesSatisfied AS NVARCHAR(10)) FROM @R WHERE PartNumber = N'P7-RFG-RP'), N'<missing>');
EXEC test.Assert_IsEqual @TestName = N'[RankedFG v1.2] repack arm: an open received LOT satisfies the part', @Expected = N'1', @Actual = @S;
GO

-- ---- cleanup ----
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-097%';
DELETE bl FROM Parts.BomLine bl INNER JOIN Parts.Bom b ON b.Id = bl.BomId INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P7-RFG-FG';
DELETE b FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'P7-RFG-FG';
DELETE il FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId WHERE i.PartNumber IN (N'P7-RFG-FG', N'P7-RFG-RP', N'P7-RFG-CH');
GO

EXEC test.EndTestFile;
GO
