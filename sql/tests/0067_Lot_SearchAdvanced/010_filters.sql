-- =============================================
-- File:         0067_Lot_SearchAdvanced/010_filters.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-004 filter coverage for Lots.Lot_SearchAdvanced.
--
--               Run-Tests.ps1 resets to a schema-only database -- there are NO
--               seeded LOTs. Every assertion therefore builds and scopes to its
--               OWN fixture (two Received LOTs with a distinctive vendor-lot
--               prefix) rather than asserting against global state, which also
--               makes the file order-independent. Fixture + teardown mirror
--               0021_PlantFloor_Lot_Lifecycle/077_Lot_Search.sql.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/010_filters.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);

IF OBJECT_ID(N'tempdb..#LS') IS NOT NULL DROP TABLE #LS;
CREATE TABLE #LS (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, LotOriginTypeId BIGINT,
    LotStatusId BIGINT, PieceCount INT, VendorLotNumber NVARCHAR(100),
    CurrentLocationId BIGINT, CreatedAt DATETIME2(3), ItemPartNumber NVARCHAR(100),
    LotStatusCode NVARCHAR(50), LotOriginTypeCode NVARCHAR(50),
    CurrentLocationName NVARCHAR(200), LastOperationName NVARCHAR(100),
    ToolCode NVARCHAR(50), CavityNumber INT, OriginMachineName NVARCHAR(200),
    TotalCount INT
);
GO

-- ---- Fixture: two Received LOTs at the same eligible cell ----
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @ItemId BIGINT, @CellA BIGINT;

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 30, @AppUserId = 1,
    @VendorLotNumber = N'VND-ADV-001';
INSERT INTO #SF (Tag, Val) SELECT N'Lot1', NewId FROM @cr;
DELETE FROM @cr;

INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 40, @AppUserId = 1,
    @VendorLotNumber = N'VND-ADV-002';
INSERT INTO #SF (Tag, Val) SELECT N'Lot2', NewId FROM @cr;

INSERT INTO #SF (Tag, Val) VALUES (N'ItemId', @ItemId), (N'CellA', @CellA),
                                  (N'OriginRcv', @OriginRcv), (N'OriginMfg', @OriginMfg);
GO

-- ---- Assertions ----
DECLARE @n INT;
DECLARE @ItemId    BIGINT = (SELECT Val FROM #SF WHERE Tag = N'ItemId');
DECLARE @CellA     BIGINT = (SELECT Val FROM #SF WHERE Tag = N'CellA');
DECLARE @OriginMfg BIGINT = (SELECT Val FROM #SF WHERE Tag = N'OriginMfg');

-- 1. The fixture is visible to an unfiltered-but-scoped search.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-ADV';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] free-text vendor prefix matches both fixture LOTs',
    @Expected = N'2', @Actual = @n;
DELETE FROM #LS;

-- 2. @ItemId admits no foreign item.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-ADV', @ItemId = @ItemId;
SELECT @n = COUNT(*) FROM #LS WHERE ItemId <> @ItemId;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @ItemId returns no foreign items',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 3. Location filter (always descendant-inclusive) finds LOTs at that exact cell.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-ADV', @LocationId = @CellA;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] location filter includes LOTs at that exact location',
    @Expected = N'2', @Actual = @n;
DELETE FROM #LS;

-- 4. @LimitRows caps the page while TotalCount still reports the full match.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-ADV', @LimitRows = 1;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @LimitRows = 1 returns exactly one row',
    @Expected = N'1', @Actual = @n;
SELECT @n = MAX(TotalCount) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] TotalCount reports the full match, not the page',
    @Expected = N'2', @Actual = @n;
DELETE FROM #LS;

-- 5. Unmatched free text returns nothing.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'ZZZ-NO-SUCH-LOT-ZZZ';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] unmatched query returns empty set',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 6. Origin filter excludes a non-matching origin (fixture LOTs are Received).
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-ADV', @LotOriginTypeId = @OriginMfg;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @LotOriginTypeId excludes non-matching origin',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 7. A date window that predates the fixture excludes it.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-ADV',
    @CreatedFromEt = '2000-01-01', @CreatedToEt = '2000-01-02';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] a past date window excludes the fixture',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- 8. Combined filters do not error and stay within each constraint.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'VND-ADV', @ItemId = @ItemId,
    @LocationId = @CellA, @LimitRows = 50;
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] combined filters still return the fixture',
    @Expected = N'2', @Actual = @n;
GO

-- ---- Teardown (closure BEFORE the LOTs -- Lot_Create writes a self-row) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Val FROM #SF WHERE Tag IN (N'Lot1', N'Lot2');

DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy
WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement      WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot              WHERE Id    IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#LS') IS NOT NULL DROP TABLE #LS;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
