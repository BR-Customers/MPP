-- =============================================
-- File:         0069_Aggregate_Reports/030_reject_summary.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-006 Plant Summary + the Non-Reject Scrap sibling.
--
--               The single most consequential arithmetic in the report set, so
--               it is pinned with KNOWN numbers rather than shape-only checks:
--                 * a reject charged to a party counts against THAT party even
--                   when the party has no production (legacy part 121 shows
--                   Die Cast Reject 1 against Die Cast Production 0);
--                 * a non-reject-scrap code lands in its OWN block and is
--                   EXCLUDED from the reject count and the percentage;
--                 * zero production yields NULL, never a divide-by-zero.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0069_Aggregate_Reports/030_reject_summary.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);
IF OBJECT_ID(N'tempdb..#PS') IS NOT NULL DROP TABLE #PS;
CREATE TABLE #PS (ChargeToPartyCode NVARCHAR(50), ChargeToPartyName NVARCHAR(100),
                  GoodPieces BIGINT, RejectPieces BIGINT, TotalPieces BIGINT,
                  RejectPercent DECIMAL(9,2));
IF OBJECT_ID(N'tempdb..#NR') IS NOT NULL DROP TABLE #NR;
CREATE TABLE #NR (DefectCode NVARCHAR(20), DefectDescription NVARCHAR(500), Quantity BIGINT);
GO

-- ---- Fixture: a LOT with 3 die-cast rejects and 5 Test-Part (non-reject) ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @UserId    BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @DcSolder  BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'100');  -- Die Cast
DECLARE @DcTest    BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'107');  -- non-reject scrap
DECLARE @DcHsp     BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'247');  -- Supplier, no production

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 50, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-SUM-001';
SELECT @LotId = NewId FROM @cr;
INSERT INTO #SF (Tag, Val) VALUES (N'Lot1', @LotId);

INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (@LotId, @DcSolder, 3, @UserId, SYSUTCDATETIME()),   -- charged Die Cast
       (@LotId, @DcTest,   5, @UserId, SYSUTCDATETIME()),   -- non-reject scrap
       (@LotId, @DcHsp,    2, @UserId, SYSUTCDATETIME());   -- Supplier, zero production
GO

DECLARE @n BIGINT, @d DECIMAL(9,2);

INSERT INTO #PS EXEC Quality.Reject_GetPlantSummary;

-- Every party is always a row, even with nothing to report.
SELECT @n = COUNT(*) FROM #PS;
EXEC test.Assert_IsEqual @TestName = N'[PlantSummary] one row per charge-to party',
    @Expected = N'6', @Actual = @n;

-- The Die Cast defect counted against Die Cast.
SELECT @n = RejectPieces FROM #PS WHERE ChargeToPartyCode = N'DieCast';
EXEC test.Assert_IsEqual @TestName = N'[PlantSummary] Die Cast reject counts the Die-Cast-coded defect',
    @Expected = N'3', @Actual = @n;

-- The Test Part quantity is EXCLUDED from the reject count -- it is non-reject
-- scrap and belongs to its own block.
SELECT @n = RejectPieces FROM #PS WHERE ChargeToPartyCode = N'DieCast';
EXEC test.Assert_IsEqual @TestName = N'[PlantSummary] non-reject scrap is NOT added to the reject count',
    @Expected = N'3', @Actual = @n;

-- A party with rejects but NO production of its own: counted, percentage NULL
-- rather than a divide-by-zero. This is the legacy part-121 case.
SELECT @n = RejectPieces FROM #PS WHERE ChargeToPartyCode = N'SupplierNonSpecific';
EXEC test.Assert_IsEqual @TestName = N'[PlantSummary] a no-production party still accrues its charged rejects',
    @Expected = N'2', @Actual = @n;

SELECT @n = COUNT(*) FROM #PS
WHERE ChargeToPartyCode = N'SupplierNonSpecific' AND (GoodPieces IS NOT NULL OR RejectPercent IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[PlantSummary] a no-production party reports NULL production and NULL percent',
    @Expected = N'0', @Actual = @n;

-- Percentage arithmetic: reject / (good + reject).
SELECT @n = COUNT(*) FROM #PS
WHERE GoodPieces IS NOT NULL AND TotalPieces <> GoodPieces + RejectPieces;
EXEC test.Assert_IsEqual @TestName = N'[PlantSummary] TotalPieces equals good plus reject on every produced row',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM #PS
WHERE RejectPercent IS NOT NULL
  AND ABS(RejectPercent - CAST(100.0 * RejectPieces / NULLIF(TotalPieces,0) AS DECIMAL(9,2))) > 0.01;
EXEC test.Assert_IsEqual @TestName = N'[PlantSummary] RejectPercent is reject over total, to 2dp',
    @Expected = N'0', @Actual = @n;

-- ---- Non-reject scrap block ----
INSERT INTO #NR EXEC Quality.Reject_GetNonRejectScrap;

SELECT @n = COUNT(*) FROM #NR;
EXEC test.Assert_IsEqual @TestName = N'[NonRejectScrap] all five codes listed even at zero',
    @Expected = N'5', @Actual = @n;

SELECT @n = Quantity FROM #NR WHERE DefectCode = N'107';
EXEC test.Assert_IsEqual @TestName = N'[NonRejectScrap] the Test Part quantity lands here',
    @Expected = N'5', @Actual = @n;

SELECT @n = COUNT(*) FROM #NR WHERE DefectCode NOT IN (N'107', N'170', N'199', N'229', N'230');
EXEC test.Assert_IsEqual @TestName = N'[NonRejectScrap] no ordinary defect leaks into the block',
    @Expected = N'0', @Actual = @n;

-- A past window zeroes the block without dropping its rows.
DELETE FROM #NR;
INSERT INTO #NR EXEC Quality.Reject_GetNonRejectScrap @FromEt = '2000-01-01', @ToEt = '2000-01-02';
SELECT @n = SUM(Quantity) FROM #NR;
EXEC test.Assert_IsEqual @TestName = N'[NonRejectScrap] a past window reports zero, still five rows',
    @Expected = N'0', @Actual = @n;
GO

DECLARE @LotId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');
DELETE FROM Workorder.RejectEvent    WHERE LotId = @LotId;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @LotId OR DescendantLotId = @LotId;
DELETE FROM Lots.LotGenealogy        WHERE ParentLotId = @LotId OR ChildLotId = @LotId;
DELETE FROM Lots.LotEventLog         WHERE LotId = @LotId;
DELETE FROM Lots.LotMovement         WHERE LotId = @LotId;
DELETE FROM Lots.LotStatusHistory    WHERE LotId = @LotId;
DELETE FROM Lots.Lot                 WHERE Id    = @LotId;
IF OBJECT_ID(N'tempdb..#PS') IS NOT NULL DROP TABLE #PS;
IF OBJECT_ID(N'tempdb..#NR') IS NOT NULL DROP TABLE #NR;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
