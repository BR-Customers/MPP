-- =============================================
-- File:         0020_PlantFloor_Foundation/042_Lot_Create_consumptionpoint_maxquantity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-20
-- Description:  Lots.Lot_Create consumption-point quantity cap (RECEIVED origin
--               only), step 6b -- Parts.ItemLocation.MaxQuantity where
--               IsConsumptionPoint = 1. Distinct from the sibling 041 MaxParts
--               test: MaxParts is a blanket Item-level ceiling; this is a
--               per-(Item, consumption-point Location) cap that only applies
--               where one has actually been configured, and cascades the same
--               ancestor hierarchy as eligibility (nearest tier wins).
--               Fixture: a dedicated Item (P-CPMAXQTY) at cell MA1-COMPBR-AOUT
--               (Id 53, parent WorkCenter MA1-COMPBR Id 50, no die-cast tool so
--               Manufactured needs no Tool/Cavity).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/042_Lot_Create_consumptionpoint_maxquantity.sql';
GO

-- ---- cleanup (FK-safe) ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-CPMAXQTY');
IF @ItC IS NOT NULL
BEGIN
    DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @ItC;
    DELETE m  FROM Lots.LotMovement m  INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @ItC;
    DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @ItC;
    DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.ItemId = @ItC;
    DELETE FROM Lots.Lot WHERE ItemId = @ItC;
    DELETE FROM Parts.ItemLocation WHERE ItemId = @ItC;
END
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-CPMAXQTY')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (3, N'P-CPMAXQTY', N'Consumption-point MaxQuantity cap test item', 1, NULL, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-CPMAXQTY');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @WorkCenter BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Cell);
-- Direct row at the Cell: IsConsumptionPoint=1, MaxQuantity=50.
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MaxQuantity, CreatedAt)
VALUES (@Item, @Cell, 1, 50, @Now);
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Manufactured BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
IF OBJECT_ID(N'tempdb..#CP') IS NOT NULL DROP TABLE #CP;
CREATE TABLE #CP (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
INSERT INTO #CP VALUES (N'ITEM', @Item), (N'CELL', @Cell), (N'WC', @WorkCenter), (N'RECV', @Received), (N'MFG', @Manufactured);
EXEC test.Assert_IsNotNull @TestName = N'[CpMaxQty] fixture cell MA1-COMPBR-AOUT exists', @Value = @Cell;
EXEC test.Assert_IsNotNull @TestName = N'[CpMaxQty] fixture cell has a parent WorkCenter', @Value = @WorkCenter;
GO

-- =============================================
-- Test 1: receive 40 (cap 50) -> accepted
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #CP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #CP WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #CP WHERE Tag = N'RECV');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r1 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 40, @AppUserId = 1;
DECLARE @ok1 BIT = (SELECT Status FROM @r1);
EXEC test.Assert_IsTrue @TestName = N'[CpMaxQty] receive 40 of 50 accepted (Status 1)', @Condition = @ok1;
GO

-- =============================================
-- Test 2: receive 20 more (40 present + 20 = 60 > 50) -> REJECTED
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #CP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #CP WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #CP WHERE Tag = N'RECV');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r2 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = 1;
DECLARE @s2 BIT = (SELECT Status FROM @r2);
DECLARE @s2cond BIT = CASE WHEN @s2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CpMaxQty] receive over cap rejected (Status 0)', @Condition = @s2cond;
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @r2);
EXEC test.Assert_Contains @TestName = N'[CpMaxQty] reject message mentions consumption-point', @HaystackStr = @m2, @NeedleStr = N'consumption-point';
-- nothing minted: still exactly one LOT for the item at the cell
DECLARE @cnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Item AND CurrentLocationId = @Cell);
EXEC test.Assert_IsEqual @TestName = N'[CpMaxQty] over-cap receive minted nothing', @Expected = N'1', @Actual = @cnt;
GO

-- =============================================
-- Test 3: Manufactured origin over the cap is NOT gated (production births flow)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #CP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #CP WHERE Tag = N'CELL');
DECLARE @Mfg BIGINT = (SELECT Val FROM #CP WHERE Tag = N'MFG');
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r3 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Mfg, @CurrentLocationId = @Cell, @PieceCount = 100, @AppUserId = 1;
DECLARE @ok3 BIT = (SELECT Status FROM @r3);
EXEC test.Assert_IsTrue @TestName = N'[CpMaxQty] Manufactured LOT over cap NOT gated (Status 1)', @Condition = @ok3;
GO

-- =============================================
-- Test 4: not a consumption point (IsConsumptionPoint=0) -> unrestricted
-- Reassigns the fixture row to IsConsumptionPoint=0 and pushes well past the
-- prior MaxQuantity=50 to prove the cap no longer applies once the row isn't
-- flagged as a consumption point (mirrors 041's "no row = unrestricted" case,
-- but for "row exists, just not a consumption point").
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #CP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #CP WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #CP WHERE Tag = N'RECV');
UPDATE Parts.ItemLocation SET IsConsumptionPoint = 0 WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL;
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r4 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 200, @AppUserId = 1;
DECLARE @ok4 BIT = (SELECT Status FROM @r4);
EXEC test.Assert_IsTrue @TestName = N'[CpMaxQty] non-consumption-point row leaves receiving unrestricted (Status 1)', @Condition = @ok4;
-- restore for the remaining tests
UPDATE Parts.ItemLocation SET IsConsumptionPoint = 1 WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL;
-- clear what test 4 just minted so the running total resets for test 5
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @Item;
DELETE m  FROM Lots.LotMovement m  INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @Item;
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @Item;
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.ItemId = @Item;
DELETE FROM Lots.Lot WHERE ItemId = @Item;
GO

-- =============================================
-- Test 5: ancestor-tier cascade -- cap configured at the WorkCenter applies to
-- a receive at the Cell underneath it (no Cell-level row at all).
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #CP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #CP WHERE Tag = N'CELL');
DECLARE @WC   BIGINT = (SELECT Val FROM #CP WHERE Tag = N'WC');
DECLARE @Recv BIGINT = (SELECT Val FROM #CP WHERE Tag = N'RECV');
DECLARE @Now2 DATETIME2(3) = SYSUTCDATETIME();
-- move the fixture row up to the WorkCenter tier, cap tightened to 10
DELETE FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Cell;
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MaxQuantity, CreatedAt)
VALUES (@Item, @WC, 1, 10, @Now2);
DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r5 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 15, @AppUserId = 1;
DECLARE @s5 BIT = (SELECT Status FROM @r5);
DECLARE @s5cond BIT = CASE WHEN @s5 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CpMaxQty] WorkCenter-tier cap cascades to a Cell receive (Status 0)', @Condition = @s5cond;
GO

-- ---- cleanup ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-CPMAXQTY');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @ItC;
DELETE m  FROM Lots.LotMovement m  INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @ItC;
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @ItC;
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.ItemId = @ItC;
DELETE FROM Lots.Lot WHERE ItemId = @ItC;
DELETE FROM Parts.ItemLocation WHERE ItemId = @ItC;
IF OBJECT_ID(N'tempdb..#CP') IS NOT NULL DROP TABLE #CP;
GO
