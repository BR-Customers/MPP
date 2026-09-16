-- =============================================
-- File:         0069_Aggregate_Reports/050_part_matrix.sql
-- Author:       Blue Ridge Automation
-- Description:  FDS-12-006 Part Matrix -- root + the two child queries.
--
--               The load-bearing assertion is RECONCILIATION: the per-defect
--               child must sum to the per-party child, which must sum to the
--               root's TotalRejects. Three queries render as one printed block,
--               so a reader compares them directly -- if they disagree the
--               report is worse than useless. Non-reject scrap must sit outside
--               that chain at every level.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0069_Aggregate_Reports/050_part_matrix.sql';
GO

IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
CREATE TABLE #SF (Tag NVARCHAR(30) PRIMARY KEY, Val BIGINT);
IF OBJECT_ID(N'tempdb..#P') IS NOT NULL DROP TABLE #P;
CREATE TABLE #P (ItemId BIGINT, ItemPartNumber NVARCHAR(100), ItemDescription NVARCHAR(500),
                 TotalRejects BIGINT, TotalNonRejectScrap BIGINT);
IF OBJECT_ID(N'tempdb..#B') IS NOT NULL DROP TABLE #B;
CREATE TABLE #B (ChargeToPartyCode NVARCHAR(50), ChargeToPartyName NVARCHAR(100),
                 GoodPieces BIGINT, RejectPieces BIGINT, RejectPercent DECIMAL(9,2));
IF OBJECT_ID(N'tempdb..#D') IS NOT NULL DROP TABLE #D;
CREATE TABLE #D (DefectCode NVARCHAR(20), DefectDescription NVARCHAR(500),
                 ChargeToPartyCode NVARCHAR(50), ChargeToPartyName NVARCHAR(100),
                 IsNonRejectScrap BIT, Quantity BIGINT);
GO

-- ---- Fixture: one part, rejects across TWO parties plus non-reject scrap ----
DECLARE @ItemId BIGINT, @CellA BIGINT, @LotId BIGINT;
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @UserId    BIGINT = (SELECT MIN(Id) FROM Location.AppUser);
-- Pick by (Code, area), never by Code alone. Migration 0087 made a code unique
-- per (area, charge-to) rather than plant-wide, so 135 now exists twice -- once
-- under Die Cast and once under Machining & Assembly -- and a bare
-- "WHERE Code = N'135'" scalar subquery raises Msg 512 instead of choosing.
DECLARE @OcDieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @DcSolder  BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'001' AND OperationCategoryId = @OcDieCast);
DECLARE @DcPoros   BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'135' AND OperationCategoryId = @OcDieCast);
DECLARE @DcHsp     BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'247');  -- Supplier, plant-wide (no area)
DECLARE @DcTest    BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008' AND OperationCategoryId = @OcDieCast);  -- non-reject scrap

SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellA, @PieceCount = 60, @AppUserId = @UserId,
    @VendorLotNumber = N'VND-MTX-001';
SELECT @LotId = NewId FROM @cr;
INSERT INTO #SF (Tag, Val) VALUES (N'Lot1', @LotId), (N'ItemId', @ItemId);

-- ItemId stamped on every row (spec 4.2): identity now resolves from
-- re.ItemId, not re.LotId -> Lots.Lot.ItemId, so the fixture must stamp it
-- the way the real write path does.
--  Die Cast:  4 + 6 = 10       Supplier: 2       Non-reject scrap: 9
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (@LotId, @ItemId, @DcSolder, 4, @UserId, SYSUTCDATETIME()),
       (@LotId, @ItemId, @DcPoros,  6, @UserId, SYSUTCDATETIME()),
       (@LotId, @ItemId, @DcHsp,    2, @UserId, SYSUTCDATETIME()),
       (@LotId, @ItemId, @DcTest,   9, @UserId, SYSUTCDATETIME());

-- ---- THE REGRESSION THIS TASK EXISTS FOR ----
-- A cavity with no basket (spec 3.5/4.1/4.2): LotId NULL, ItemId stamped
-- directly on the fact row, a DIFFERENT part (@ItemId2) so it cannot be
-- confused with the @ItemId rows above. An INNER JOIN through Lots.Lot
-- would silently drop this row from the Part Matrix.
DECLARE @ItemId2 BIGINT = (SELECT TOP 1 Id FROM Parts.Item
    WHERE Id <> @ItemId AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO #SF (Tag, Val) VALUES (N'ItemId2', @ItemId2);

DECLARE @LotFreeId BIGINT, @UnassignedId BIGINT;
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (NULL, @ItemId2, @DcSolder, 5, @UserId, SYSUTCDATETIME());
SET @LotFreeId = SCOPE_IDENTITY();

-- An unmapped cavity (ItemId also NULL, the shrinking-legacy-state case,
-- spec 4.1): must bucket as '(unassigned part)', not vanish.
INSERT INTO Workorder.RejectEvent (LotId, ItemId, DefectCodeId, Quantity, AppUserId, RecordedAt)
VALUES (NULL, NULL, @DcSolder, 8, @UserId, SYSUTCDATETIME());
SET @UnassignedId = SCOPE_IDENTITY();

INSERT INTO #SF (Tag, Val) VALUES (N'LotFreeReject', @LotFreeId), (N'UnassignedReject', @UnassignedId);
GO

DECLARE @n BIGINT, @ItemId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'ItemId');

INSERT INTO #P EXEC Quality.Reject_GetPartMatrix;

-- Root: rejects and non-reject scrap are kept apart.
SELECT @n = TotalRejects FROM #P WHERE ItemId = @ItemId;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] root TotalRejects excludes non-reject scrap',
    @Expected = N'12', @Actual = @n;

SELECT @n = TotalNonRejectScrap FROM #P WHERE ItemId = @ItemId;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] root reports non-reject scrap separately',
    @Expected = N'9', @Actual = @n;

-- THE REGRESSION THIS TASK EXISTS FOR. With an INNER JOIN to Lots.Lot, a
-- lot-free reject is DROPPED from the report with no error -- a smaller
-- number that looks plausible. Assert it is present and attributed to the
-- right part (@ItemId2, not @ItemId -- proves it resolved via re.ItemId,
-- not by falling through to some other row's LOT).
DECLARE @ItemId2 BIGINT = (SELECT Val FROM #SF WHERE Tag = N'ItemId2');
SELECT @n = TotalRejects FROM #P WHERE ItemId = @ItemId2;
EXEC test.Assert_IsEqual @TestName = N'[Reports] lot-free scrap appears in the Part Matrix',
    @Expected = N'5', @Actual = @n;

-- Unmapped-cavity scrap (ItemId NULL, spec 4.1): buckets as
-- '(unassigned part)' rather than being dropped by the GROUP BY.
SELECT @n = TotalRejects FROM #P WHERE ItemPartNumber = N'(unassigned part)';
EXEC test.Assert_IsEqual @TestName = N'[Reports] unmapped-cavity scrap buckets as unassigned, not dropped',
    @Expected = N'8', @Actual = @n;

-- Party child.
INSERT INTO #B EXEC Quality.Reject_GetPartMatrixByParty @ItemId = @ItemId;

SELECT @n = COUNT(*) FROM #B;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] party child returns every party',
    @Expected = N'6', @Actual = @n;

SELECT @n = RejectPieces FROM #B WHERE ChargeToPartyCode = N'DieCast';
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] Die Cast party row sums its two defects',
    @Expected = N'10', @Actual = @n;

SELECT @n = RejectPieces FROM #B WHERE ChargeToPartyCode = N'SupplierNonSpecific';
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] the supplier-charged defect lands on the supplier row',
    @Expected = N'2', @Actual = @n;

-- RECONCILIATION: party child sums to the root total.
SELECT @n = SUM(RejectPieces) FROM #B;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] party child SUMS to the root TotalRejects',
    @Expected = N'12', @Actual = @n;

-- Defect child.
INSERT INTO #D EXEC Quality.Reject_GetPartMatrixDefects @ItemId = @ItemId;

SELECT @n = SUM(Quantity) FROM #D WHERE IsNonRejectScrap = 0;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] defect child SUMS to the root TotalRejects',
    @Expected = N'12', @Actual = @n;

SELECT @n = SUM(Quantity) FROM #D WHERE IsNonRejectScrap = 1;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] defect child carries non-reject scrap, flagged',
    @Expected = N'9', @Actual = @n;

-- Per-party reconciliation between the two children.
SELECT @n = SUM(Quantity) FROM #D WHERE IsNonRejectScrap = 0 AND ChargeToPartyCode = N'DieCast';
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] defect child reconciles with the party child per party',
    @Expected = N'10', @Actual = @n;

-- Every defect row resolves a party -- an unclassified code would print blank.
SELECT @n = COUNT(*) FROM #D WHERE ChargeToPartyCode IS NULL;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] every defect row resolves a charge-to party',
    @Expected = N'0', @Actual = @n;

-- A past window empties the root entirely.
DELETE FROM #P;
INSERT INTO #P EXEC Quality.Reject_GetPartMatrix @FromEt = '2000-01-01', @ToEt = '2000-01-02';
SELECT @n = COUNT(*) FROM #P WHERE ItemId = @ItemId;
EXEC test.Assert_IsEqual @TestName = N'[PartMatrix] a past window returns no parts',
    @Expected = N'0', @Actual = @n;
GO

DECLARE @LotId BIGINT = (SELECT Val FROM #SF WHERE Tag = N'Lot1');
-- Lot-free rows carry no LotId to key the delete above on -- remove them by
-- their own captured Ids.
DELETE FROM Workorder.RejectEvent
WHERE Id IN (SELECT Val FROM #SF WHERE Tag IN (N'LotFreeReject', N'UnassignedReject'));
DELETE FROM Workorder.RejectEvent    WHERE LotId = @LotId;
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @LotId OR DescendantLotId = @LotId;
DELETE FROM Lots.LotGenealogy        WHERE ParentLotId = @LotId OR ChildLotId = @LotId;
DELETE FROM Lots.LotEventLog         WHERE LotId = @LotId;
DELETE FROM Lots.LotMovement         WHERE LotId = @LotId;
DELETE FROM Lots.LotStatusHistory    WHERE LotId = @LotId;
DELETE FROM Lots.Lot                 WHERE Id    = @LotId;
IF OBJECT_ID(N'tempdb..#P') IS NOT NULL DROP TABLE #P;
IF OBJECT_ID(N'tempdb..#B') IS NOT NULL DROP TABLE #B;
IF OBJECT_ID(N'tempdb..#D') IS NOT NULL DROP TABLE #D;
IF OBJECT_ID(N'tempdb..#SF') IS NOT NULL DROP TABLE #SF;
GO
