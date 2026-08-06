-- =============================================
-- File:         0020_PlantFloor_Foundation/041_Lot_Create_maxparts.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-04
-- Description:  Lots.Lot_Create MaxParts per-location cap (RECEIVED origin only).
--               The loose-receive path (Received origin) must reject a receipt that
--               would push the item's non-Closed total at the location past
--               Parts.Item.MaxParts -- closing the gap that the move path
--               (Lot_MoveToValidated) already guards. Production births (non-Received
--               origins) are NOT gated: a Manufactured LOT over the cap still succeeds.
--               Fixture: a dedicated Item (MaxParts=50, MaxLotSize NULL) eligible at an
--               assembly-out cell (no die-cast tool -> Manufactured needs no Tool/Cavity).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/041_Lot_Create_maxparts.sql';
GO

-- ---- cleanup (FK-safe) ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-MAXPARTS');
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
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-MAXPARTS')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (3, N'P-MAXPARTS', N'MaxParts cap test item', 1, 50, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-MAXPARTS');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @Cell, 0, @Now);
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Manufactured BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
IF OBJECT_ID(N'tempdb..#MP') IS NOT NULL DROP TABLE #MP;
CREATE TABLE #MP (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
INSERT INTO #MP VALUES (N'ITEM', @Item), (N'CELL', @Cell), (N'RECV', @Received), (N'MFG', @Manufactured);
EXEC test.Assert_IsNotNull @TestName = N'[MaxParts] fixture cell MA1-COMPBR-AOUT exists', @Value = @Cell;
GO

-- =============================================
-- Test 1: receive 40 (cap 50) -> accepted
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #MP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #MP WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #MP WHERE Tag = N'RECV');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r1 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 40, @AppUserId = 1;
DECLARE @ok1 BIT = (SELECT Status FROM @r1);
EXEC test.Assert_IsTrue @TestName = N'[MaxParts] receive 40 of 50 accepted (Status 1)', @Condition = @ok1;
GO

-- =============================================
-- Test 2: receive 20 more (40 present + 20 = 60 > 50) -> REJECTED
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #MP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #MP WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #MP WHERE Tag = N'RECV');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r2 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = 1;
DECLARE @s2 BIT = (SELECT Status FROM @r2);
DECLARE @s2cond BIT = CASE WHEN @s2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MaxParts] receive over cap rejected (Status 0)', @Condition = @s2cond;
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @r2);
EXEC test.Assert_Contains @TestName = N'[MaxParts] reject message mentions max parts', @HaystackStr = @m2, @NeedleStr = N'max parts';
-- nothing minted: still exactly one LOT for the item at the cell
DECLARE @cnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Item AND CurrentLocationId = @Cell);
EXEC test.Assert_IsEqual @TestName = N'[MaxParts] over-cap receive minted nothing', @Expected = N'1', @Actual = @cnt;
GO

-- =============================================
-- Test 3: Manufactured origin over the cap is NOT gated (production births flow)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #MP WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #MP WHERE Tag = N'CELL');
DECLARE @Mfg BIGINT = (SELECT Val FROM #MP WHERE Tag = N'MFG');
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r3 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Mfg, @CurrentLocationId = @Cell, @PieceCount = 100, @AppUserId = 1;
DECLARE @ok3 BIT = (SELECT Status FROM @r3);
EXEC test.Assert_IsTrue @TestName = N'[MaxParts] Manufactured LOT over cap NOT gated (Status 1)', @Condition = @ok3;
GO

-- ---- cleanup ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-MAXPARTS');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @ItC;
DELETE m  FROM Lots.LotMovement m  INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @ItC;
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @ItC;
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.ItemId = @ItC;
DELETE FROM Lots.Lot WHERE ItemId = @ItC;
DELETE FROM Parts.ItemLocation WHERE ItemId = @ItC;
IF OBJECT_ID(N'tempdb..#MP') IS NOT NULL DROP TABLE #MP;
GO
