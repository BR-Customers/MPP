-- =============================================
-- File:         0109_Lot_ListByVendorLot/010_matches.sql
-- Author:       Blue Ridge Automation
-- Description:  Lots.Lot_ListByVendorLot -- the read behind the "supplier lot
--               already entered" warning. Covers: no match, two matches newest
--               first with TotalMatches, trimming, and that NULL / blank /
--               NONE never match.
--
--               Builds its own LOT fixture and tears it down (fixture mirrors
--               0107_LotNote/010_add_and_list.sql).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0109_Lot_ListByVendorLot/010_matches.sql';
GO

IF OBJECT_ID(N'tempdb..#VF') IS NOT NULL DROP TABLE #VF;
CREATE TABLE #VF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);

IF OBJECT_ID(N'tempdb..#VL') IS NOT NULL DROP TABLE #VL;
CREATE TABLE #VL (
    LotId BIGINT, LotName NVARCHAR(50), VendorLotNumber NVARCHAR(100), ItemId BIGINT,
    PartNumber NVARCHAR(100), ItemDescription NVARCHAR(500), EnteredLocationName NVARCHAR(200),
    CurrentLocationName NVARCHAR(200), EnteredAt DATETIME2(3), PieceCount INT,
    LotStatusCode NVARCHAR(50), TotalMatches INT, Seq INT IDENTITY(1,1)
);
GO

-- ---- Fixture: two boxes sharing one supplier lot, one "no lot on box" ----
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT;

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 30, @AppUserId = 1,
    @VendorLotNumber = N'VND-DUP-0109';
INSERT INTO #VF (Tag, Val) SELECT N'Lot1', NewId FROM @cr;
DELETE FROM @cr;

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 40, @AppUserId = 1,
    @VendorLotNumber = N'VND-DUP-0109';
INSERT INTO #VF (Tag, Val) SELECT N'Lot2', NewId FROM @cr;
DELETE FROM @cr;

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 50, @AppUserId = 1,
    @RequireVendorLot = 1, @VendorLotAbsent = 1;
INSERT INTO #VF (Tag, Val) SELECT N'Lot3', NewId FROM @cr;

INSERT INTO #VF (Tag, Val) VALUES (N'CellA', @CellA);
GO

-- ---- Assertions ----
DECLARE @n INT;
DECLARE @Lot2  BIGINT = (SELECT Val FROM #VF WHERE Tag = N'Lot2');
DECLARE @CellA BIGINT = (SELECT Val FROM #VF WHERE Tag = N'CellA');
DECLARE @CellName NVARCHAR(200) = (SELECT Name FROM Location.Location WHERE Id = @CellA);
DECLARE @Padded NVARCHAR(100) = N'  VND-DUP-0109  ';
DECLARE @Blank  NVARCHAR(100) = N'   ';

SELECT @n = COUNT(*) FROM #VF WHERE Tag IN (N'Lot1', N'Lot2', N'Lot3') AND Val IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[VendorLot] fixture: three LOTs created',
    @Expected = N'3', @Actual = @n;

-- 1. A number never entered -> empty set.
INSERT INTO #VL (LotId, LotName, VendorLotNumber, ItemId, PartNumber, ItemDescription, EnteredLocationName,
                 CurrentLocationName, EnteredAt, PieceCount, LotStatusCode, TotalMatches)
EXEC Lots.Lot_ListByVendorLot @VendorLotNumber = N'VND-NEVER-0109';
SELECT @n = COUNT(*) FROM #VL;
EXEC test.Assert_IsEqual @TestName = N'[VendorLot] an unused number returns an empty set',
    @Expected = N'0', @Actual = @n;

-- 2. Two boxes share the number; padding is trimmed.
INSERT INTO #VL (LotId, LotName, VendorLotNumber, ItemId, PartNumber, ItemDescription, EnteredLocationName,
                 CurrentLocationName, EnteredAt, PieceCount, LotStatusCode, TotalMatches)
EXEC Lots.Lot_ListByVendorLot @VendorLotNumber = @Padded;
SELECT @n = COUNT(*) FROM #VL;
EXEC test.Assert_IsEqual @TestName = N'[VendorLot] both LOTs with the number are returned (input trimmed)',
    @Expected = N'2', @Actual = @n;

SELECT @n = COUNT(*) FROM #VL WHERE TotalMatches = 2;
EXEC test.Assert_IsEqual @TestName = N'[VendorLot] TotalMatches carries the full count on every row',
    @Expected = N'2', @Actual = @n;

SELECT @n = CASE WHEN (SELECT TOP 1 LotId FROM #VL ORDER BY Seq) = @Lot2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsEqual @TestName = N'[VendorLot] newest LOT first',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM #VL
WHERE EnteredLocationName = @CellName AND ItemDescription IS NOT NULL AND EnteredAt IS NOT NULL;
EXEC test.Assert_IsEqual @TestName = N'[VendorLot] rows name the entry location and the part',
    @Expected = N'2', @Actual = @n;
DELETE FROM #VL;

-- 3. NULL, blank and the NONE marker never match -- not even the NONE LOT.
INSERT INTO #VL (LotId, LotName, VendorLotNumber, ItemId, PartNumber, ItemDescription, EnteredLocationName,
                 CurrentLocationName, EnteredAt, PieceCount, LotStatusCode, TotalMatches)
EXEC Lots.Lot_ListByVendorLot @VendorLotNumber = NULL;
INSERT INTO #VL (LotId, LotName, VendorLotNumber, ItemId, PartNumber, ItemDescription, EnteredLocationName,
                 CurrentLocationName, EnteredAt, PieceCount, LotStatusCode, TotalMatches)
EXEC Lots.Lot_ListByVendorLot @VendorLotNumber = @Blank;
INSERT INTO #VL (LotId, LotName, VendorLotNumber, ItemId, PartNumber, ItemDescription, EnteredLocationName,
                 CurrentLocationName, EnteredAt, PieceCount, LotStatusCode, TotalMatches)
EXEC Lots.Lot_ListByVendorLot @VendorLotNumber = N'NONE';
SELECT @n = COUNT(*) FROM #VL;
EXEC test.Assert_IsEqual @TestName = N'[VendorLot] NULL, blank and NONE match nothing',
    @Expected = N'0', @Actual = @n;
GO

-- ---- Teardown (closure BEFORE the LOTs) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Val FROM #VF WHERE Tag IN (N'Lot1', N'Lot2', N'Lot3');

DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy
WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot              WHERE Id    IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#VL') IS NOT NULL DROP TABLE #VL;
IF OBJECT_ID(N'tempdb..#VF') IS NOT NULL DROP TABLE #VF;
GO
