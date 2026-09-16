-- =============================================
-- File:         0069_Aggregate_Reports/020_reject_detail.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-006 Rejects -- Transaction Detail.
--
--               Pins the charge-to source: the report reads
--               DefectCode.ChargeToPartyId, NOT RejectEvent.ChargeToArea. The
--               fixture sets ChargeToArea to a deliberately WRONG value and
--               asserts the report ignores it -- if someone later "helpfully"
--               joins the free-text column, this fails.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0069_Aggregate_Reports/020_reject_detail.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);
IF OBJECT_ID(N'tempdb..#RD') IS NOT NULL DROP TABLE #RD;
CREATE TABLE #RD (
    RejectEventId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(100),
    RecordedAt DATETIME2(3), OperatorName NVARCHAR(200), ShiftName NVARCHAR(100),
    DefectCode NVARCHAR(20), DefectDescription NVARCHAR(500), ChargeToPartyName NVARCHAR(100),
    Quantity INT, IsNonRejectScrap BIT, RecordedAtLocationName NVARCHAR(200), TotalCount INT
);
GO

-- ---- Fixture: one ordinary reject + one non-reject-scrap reject ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @UserId    BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
DECLARE @DcNormal  BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'001');  -- Soldering, Die Cast
DECLARE @DcTest    BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');  -- Test Part, non-reject scrap

-- MaxLotSize IS NULL: Lot_Create REJECTS a PieceCount above the item's cap,
-- and a rejected create leaves @LotId NULL -> a NOT NULL violation two
-- statements later. Same guard 010_filters and 077_Lot_Search use.
SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 100, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-RJ-001';
SELECT @LotId = NewId FROM @cr;
INSERT INTO #SF (Tag, Val) VALUES (N'Lot1', @LotId), (N'ItemId', @ItemId);

-- ChargeToArea deliberately set to a WRONG value: the report must ignore it.
-- ItemId stamped on every row (spec 4.2): identity resolves from re.ItemId,
-- not re.LotId -> Lots.Lot.ItemId.
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, ChargeToArea, AppUserId, RecordedAt)
VALUES (@LotId, @ItemId, @DcNormal, 7, N'WRONG-SHOULD-BE-IGNORED', @UserId, SYSUTCDATETIME());
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, ChargeToArea, AppUserId, RecordedAt)
VALUES (@LotId, @ItemId, @DcTest, 3, N'WRONG-SHOULD-BE-IGNORED', @UserId, SYSUTCDATETIME());

-- ---- THE REGRESSION THIS TASK EXISTS FOR ----
-- A cavity with no basket (spec 3.5/4.1/4.2): LotId NULL, ItemId stamped
-- directly. An INNER JOIN through Lots.Lot would silently drop this row
-- from the Transaction Detail.
DECLARE @LotFreeId BIGINT;
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (NULL, @ItemId, @DcNormal, 6, @UserId, SYSUTCDATETIME());
SET @LotFreeId = SCOPE_IDENTITY();
INSERT INTO #SF (Tag, Val) VALUES (N'LotFreeReject', @LotFreeId);
GO

DECLARE @n INT, @s NVARCHAR(100), @ItemId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'ItemId');

INSERT INTO #RD EXEC Quality.Reject_SearchDetail @PartNumberLike = NULL;
SELECT @n = COUNT(*) FROM #RD WHERE LotName IN (SELECT LotName FROM Lots.Lot WHERE VendorLotNumber = N'VND-RJ-001');
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] both fixture rejects returned',
    @Expected = N'2', @Actual = @n;

-- THE REGRESSION THIS TASK EXISTS FOR. With an INNER JOIN to Lots.Lot, a
-- lot-free reject is DROPPED from the Transaction Detail with no error.
DECLARE @LotFreeId2 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'LotFreeReject');
SELECT @n = COUNT(*) FROM #RD WHERE RejectEventId = @LotFreeId2;
EXEC test.Assert_IsEqual @TestName = N'[Reports] lot-free scrap appears in Transaction Detail',
    @Expected = N'1', @Actual = @n;

-- ... and its LotId/LotName stay NULL (not dropped, not guessed) while the
-- part still resolves via the stamped re.ItemId.
SELECT @n = COUNT(*) FROM #RD rd
INNER JOIN Parts.Item i ON i.PartNumber = rd.ItemPartNumber
WHERE rd.RejectEventId = @LotFreeId2 AND rd.LotId IS NULL AND rd.LotName IS NULL AND i.Id = @ItemId;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] lot-free scrap keeps LotId NULL and resolves the right part',
    @Expected = N'1', @Actual = @n;

-- Charge-to comes from the DEFECT CODE, not the free-text column.
SELECT @s = MAX(ChargeToPartyName) FROM #RD WHERE DefectCode = N'001';
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] charge-to resolves from DefectCode, not ChargeToArea',
    @Expected = N'Die Cast', @Actual = @s;

SELECT @n = COUNT(*) FROM #RD WHERE ChargeToPartyName LIKE N'%WRONG%';
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] the free-text ChargeToArea is never surfaced',
    @Expected = N'0', @Actual = @n;

-- The non-reject-scrap flag rides along so the report can bucket it.
SELECT @n = CAST(MAX(CAST(IsNonRejectScrap AS INT)) AS INT) FROM #RD WHERE DefectCode = N'008';
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] Test Part carries IsNonRejectScrap = 1',
    @Expected = N'1', @Actual = @n;

SELECT @n = CAST(MAX(CAST(IsNonRejectScrap AS INT)) AS INT) FROM #RD WHERE DefectCode = N'001';
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] an ordinary defect carries IsNonRejectScrap = 0',
    @Expected = N'0', @Actual = @n;

-- Defect filter narrows.
-- EXEC parameters must be literals or @variables -- never an inline
-- subquery/CAST/CASE (repo convention; SQL Server rejects it outright).
DECLARE @DcTestId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DELETE FROM #RD;
INSERT INTO #RD EXEC Quality.Reject_SearchDetail @DefectCodeId = @DcTestId;
SELECT @n = COUNT(*) FROM #RD WHERE DefectCode <> N'008';
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] @DefectCodeId admits no other defect',
    @Expected = N'0', @Actual = @n;

-- A past date window excludes today's fixture.
DELETE FROM #RD;
INSERT INTO #RD EXEC Quality.Reject_SearchDetail @FromEt = '2000-01-01', @ToEt = '2000-01-02';
SELECT @n = COUNT(*) FROM #RD;
EXEC test.Assert_IsEqual @TestName = N'[RejectDetail] a past date window returns nothing',
    @Expected = N'0', @Actual = @n;
GO

DECLARE @LotId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');
-- The lot-free row carries no LotId to key the delete below on -- remove it
-- by its own captured Id.
DELETE FROM Workorder.RejectEvent WHERE Id = (SELECT Val FROM #SF WHERE Tag = N'LotFreeReject');
DELETE FROM Workorder.RejectEvent    WHERE LotId = @LotId;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @LotId OR DescendantLotId = @LotId;
DELETE FROM Lots.LotGenealogy        WHERE ParentLotId = @LotId OR ChildLotId = @LotId;
DELETE FROM Lots.LotEventLog         WHERE LotId = @LotId;
DELETE FROM Lots.LotMovement         WHERE LotId = @LotId;
DELETE FROM Lots.LotStatusHistory    WHERE LotId = @LotId;
DELETE FROM Lots.Lot                 WHERE Id    = @LotId;
IF OBJECT_ID(N'tempdb..#RD') IS NOT NULL DROP TABLE #RD;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
