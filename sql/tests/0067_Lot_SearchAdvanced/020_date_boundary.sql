-- =============================================
-- File:         0067_Lot_SearchAdvanced/020_date_boundary.sql
-- Author:       Blue Ridge Automation
-- Description:  The Eastern-day filter must agree with the Eastern-converted
--               CreatedAt column. A LOT created 01:00 UTC on day D belongs to
--               Eastern day D-1 (20:00 EST), so it must be found by
--               @CreatedToEt = D-1 and NOT by @CreatedFromEt = D.
--
--               January is deliberate -- EST, no DST ambiguity.
--
--               The LOT is INSERTed directly rather than via Lots.Lot_Create so
--               CreatedAt can be pinned; Lot_Create defaults it to
--               SYSUTCDATETIME(). Item / location are sourced from
--               Parts.v_EffectiveItemLocation because the reset database has no
--               LOTs to copy them from.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0067_Lot_SearchAdvanced/020_date_boundary.sql';
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

-- ---- Fixture: one LOT stamped 2026-01-15 01:00 UTC == 2026-01-14 20:00 EST ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @StatusGood BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @UserId BIGINT = (SELECT MIN(Id) FROM Location.AppUser);

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
ORDER BY eil.LocationId;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount,
                      CurrentLocationId, CreatedByUserId, CreatedAt, VendorLotNumber)
VALUES (N'TEST-TZ-BOUNDARY-01', @ItemId, @OriginRcv, @StatusGood, 1, @CellA, @UserId,
        CAST(N'2026-01-15T01:00:00' AS DATETIME2(3)), N'VND-TZ-001');
SET @LotId = SCOPE_IDENTITY();
INSERT INTO #SF (Tag, Val) VALUES (N'Lot1', @LotId);
GO

DECLARE @n INT;

-- Found on the Eastern day it actually belongs to.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'TEST-TZ-BOUNDARY-01',
    @CreatedFromEt = '2026-01-14', @CreatedToEt = '2026-01-14';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] 01:00 UTC LOT found on the prior Eastern day',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

-- Absent from the UTC calendar day.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'TEST-TZ-BOUNDARY-01',
    @CreatedFromEt = '2026-01-15', @CreatedToEt = '2026-01-15';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] 01:00 UTC LOT absent from the UTC day',
    @Expected = N'0', @Actual = @n;
DELETE FROM #LS;

-- @CreatedToEt is inclusive of its whole day.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'TEST-TZ-BOUNDARY-01',
    @CreatedFromEt = '2026-01-13', @CreatedToEt = '2026-01-14';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @CreatedToEt is inclusive of its whole day',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

-- @CreatedFromEt is inclusive of its whole day.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'TEST-TZ-BOUNDARY-01',
    @CreatedFromEt = '2026-01-14', @CreatedToEt = '2026-01-20';
SELECT @n = COUNT(*) FROM #LS;
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] @CreatedFromEt is inclusive of its whole day',
    @Expected = N'1', @Actual = @n;
DELETE FROM #LS;

-- The displayed CreatedAt is Eastern, so it must read 2026-01-14 20:00.
INSERT INTO #LS EXEC Lots.Lot_SearchAdvanced @Query = N'TEST-TZ-BOUNDARY-01';
DECLARE @Shown NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), MAX(CreatedAt), 120) FROM #LS);
EXEC test.Assert_IsEqual @TestName = N'[SearchAdv] CreatedAt is rendered in Eastern time',
    @Expected = N'2026-01-14 20:00:00', @Actual = @Shown;
GO

-- ---- Teardown (closure BEFORE the LOT) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Val FROM #SF WHERE Tag = N'Lot1';

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
