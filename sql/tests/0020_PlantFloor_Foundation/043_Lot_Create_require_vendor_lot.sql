-- =============================================
-- File:         0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-05
-- Description:  Lots.Lot_Create v1.8 -- @RequireVendorLot / @VendorLotAbsent.
--               Both default 0, so a caller that passes neither behaves as
--               before. With @RequireVendorLot = 1 a missing or blank supplier
--               lot is rejected before any transaction opens. @VendorLotAbsent
--               = 1 stores the marker NONE, replacing anything supplied.
--               Fixture: a dedicated Item (P-REQVLOT) made eligible at cell
--               MA1-COMPBR-AOUT by a non-consumption-point ItemLocation row,
--               so neither quantity cap applies.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/043_Lot_Create_require_vendor_lot.sql';
GO

-- ---- cleanup (FK-safe: closure rows before LOTs) ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-REQVLOT');
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
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-REQVLOT')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (3, N'P-REQVLOT', N'Required supplier lot test item', 1, NULL, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-REQVLOT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
VALUES (@Item, @Cell, 0, @Now);
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
IF OBJECT_ID(N'tempdb..#VL') IS NOT NULL DROP TABLE #VL;
CREATE TABLE #VL (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
INSERT INTO #VL VALUES (N'ITEM', @Item), (N'CELL', @Cell), (N'RECV', @Received);
EXEC test.Assert_IsNotNull @TestName = N'[ReqVendorLot] fixture cell MA1-COMPBR-AOUT exists', @Value = @Cell;
GO

-- =============================================
-- Test 1: flag off, no supplier lot -> created, stored NULL (unchanged behaviour)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r1 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1;
DECLARE @ok1 BIT = (SELECT Status FROM @r1);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag off, no supplier lot: created', @Condition = @ok1;
DECLARE @v1 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r1 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] flag off, no supplier lot: stored NULL', @Expected = N'<null>', @Actual = @v1;
GO

-- =============================================
-- Test 2: flag on, no supplier lot -> REJECTED, nothing minted
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r2 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @RequireVendorLot = 1;
DECLARE @s2 BIT = (SELECT Status FROM @r2);
DECLARE @s2cond BIT = CASE WHEN @s2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on, no supplier lot: rejected (Status 0)', @Condition = @s2cond;
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @r2);
EXEC test.Assert_Contains @TestName = N'[ReqVendorLot] rejection names the supplier lot', @HaystackStr = @m2, @NeedleStr = N'Supplier lot number is required';
DECLARE @cnt2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Item);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] rejection minted nothing', @Expected = N'1', @Actual = @cnt2;
GO

-- =============================================
-- Test 3: flag on, whitespace-only supplier lot -> REJECTED
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r3 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'   ', @AppUserId = 1, @RequireVendorLot = 1;
DECLARE @s3 BIT = (SELECT Status FROM @r3);
DECLARE @s3cond BIT = CASE WHEN @s3 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on, whitespace only: rejected (Status 0)', @Condition = @s3cond;
DECLARE @cnt3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ItemId = @Item);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] whitespace rejection minted nothing', @Expected = N'1', @Actual = @cnt3;
GO

-- =============================================
-- Test 4: flag on, padded value -> created, stored trimmed
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r4 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'  AB-123 ', @AppUserId = 1, @RequireVendorLot = 1;
DECLARE @ok4 BIT = (SELECT Status FROM @r4);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on with a value: created', @Condition = @ok4;
DECLARE @v4 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r4 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] value stored trimmed', @Expected = N'AB-123', @Actual = @v4;
GO

-- =============================================
-- Test 5: flag on, absent, no value -> created, stored NONE
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r5 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @RequireVendorLot = 1, @VendorLotAbsent = 1;
DECLARE @ok5 BIT = (SELECT Status FROM @r5);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] flag on, absent: created', @Condition = @ok5;
DECLARE @v5 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r5 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] absent stored as NONE', @Expected = N'NONE', @Actual = @v5;
GO

-- =============================================
-- Test 6: flag on, absent AND a value -> absent wins, stored NONE
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r6 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'ZZ-9', @AppUserId = 1, @RequireVendorLot = 1, @VendorLotAbsent = 1;
DECLARE @ok6 BIT = (SELECT Status FROM @r6);
EXEC test.Assert_IsTrue @TestName = N'[ReqVendorLot] absent with a value: created', @Condition = @ok6;
DECLARE @v6 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r6 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] absent replaces a supplied value', @Expected = N'NONE', @Actual = @v6;
GO

-- =============================================
-- Test 7: flag off, absent -> stored NONE (absent does not depend on the flag)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r7 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r7 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @VendorLotAbsent = 1;
DECLARE @v7 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r7 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] flag off, absent: stored NONE', @Expected = N'NONE', @Actual = @v7;
GO

-- =============================================
-- Test 8: flag off, whitespace-only value -> created, stored NULL (not spaces)
-- =============================================
DECLARE @Item BIGINT = (SELECT Val FROM #VL WHERE Tag = N'ITEM');
DECLARE @Cell BIGINT = (SELECT Val FROM #VL WHERE Tag = N'CELL');
DECLARE @Recv BIGINT = (SELECT Val FROM #VL WHERE Tag = N'RECV');
DECLARE @r8 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @r8 EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @Recv, @CurrentLocationId = @Cell, @PieceCount = 10, @VendorLotNumber = N'  ', @AppUserId = 1;
DECLARE @v8 NVARCHAR(100) = (SELECT ISNULL(l.VendorLotNumber, N'<null>') FROM Lots.Lot l INNER JOIN @r8 r ON r.NewId = l.Id);
EXEC test.Assert_IsEqual @TestName = N'[ReqVendorLot] flag off, whitespace only: stored NULL', @Expected = N'<null>', @Actual = @v8;
GO

-- ---- cleanup ----
DECLARE @ItC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-REQVLOT');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @ItC;
DELETE m  FROM Lots.LotMovement m  INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @ItC;
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @ItC;
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id = cl.AncestorLotId OR l.Id = cl.DescendantLotId WHERE l.ItemId = @ItC;
DELETE FROM Lots.Lot WHERE ItemId = @ItC;
DELETE FROM Parts.ItemLocation WHERE ItemId = @ItC;
IF OBJECT_ID(N'tempdb..#VL') IS NOT NULL DROP TABLE #VL;
GO
