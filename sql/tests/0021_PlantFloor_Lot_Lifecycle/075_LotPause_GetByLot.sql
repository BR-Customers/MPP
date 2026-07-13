SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/075_LotPause_GetByLot.sql';
GO
IF OBJECT_ID(N'tempdb..#GBLFix') IS NOT NULL DROP TABLE #GBLFix;
CREATE TABLE #GBLFix (Tag NVARCHAR(20) PRIMARY KEY, Val BIGINT);
GO
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellA BIGINT, @CellB BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellA = eil.LocationId FROM Parts.v_EffectiveItemLocation eil WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL) ORDER BY eil.LocationId;
SELECT TOP 1 @CellB = Id FROM Location.Location WHERE Id <> @CellA AND DeprecatedAt IS NULL ORDER BY Id;
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv, @CurrentLocationId=@CellA, @PieceCount=30, @AppUserId=1;
INSERT INTO #GBLFix (Tag, Val) SELECT N'Lot', NewId FROM @cr;
INSERT INTO #GBLFix (Tag, Val) VALUES (N'CellA', @CellA), (N'CellB', @CellB);
GO
-- Test 1: paused at two Cells -> two rows oldest-first
DECLARE @Lot BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'Lot');
DECLARE @CellA BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'CellA');
DECLARE @CellB BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'CellB');
DECLARE @p1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p1 EXEC Lots.LotPause_Place @LotId=@Lot, @LocationId=@CellA, @AppUserId=1;
UPDATE Lots.PauseEvent SET PausedAt=DATEADD(SECOND,-30,SYSUTCDATETIME()) WHERE LotId=@Lot AND LocationId=@CellA AND ResumedAt IS NULL;
DECLARE @p2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p2 EXEC Lots.LotPause_Place @LotId=@Lot, @LocationId=@CellB, @AppUserId=1;
CREATE TABLE #gbl (PauseEventId BIGINT, LotId BIGINT, LocationId BIGINT, LocationName NVARCHAR(200), PausedAt DATETIME2(3), PausedByUserId BIGINT, PausedReason NVARCHAR(500));
INSERT INTO #gbl EXEC Lots.LotPause_GetByLot @LotId=@Lot;
DECLARE @n INT=(SELECT COUNT(*) FROM #gbl);
EXEC test.Assert_RowCount @TestName=N'[GetByLot] 2 Cells -> 2 rows', @ExpectedCount=2, @ActualCount=@n;
DECLARE @firstLoc BIGINT=(SELECT TOP 1 LocationId FROM #gbl ORDER BY PausedAt ASC);
DECLARE @expStr NVARCHAR(20)=CAST(@CellA AS NVARCHAR(20));
DECLARE @actStr NVARCHAR(20)=CAST(@firstLoc AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[GetByLot] oldest-first (CellA leads)', @Expected=@expStr, @Actual=@actStr;
DROP TABLE #gbl;
GO
-- Test 2: resume one -> one remains
DECLARE @Lot BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'Lot');
DECLARE @CellA BIGINT=(SELECT Val FROM #GBLFix WHERE Tag=N'CellA');
DECLARE @paId BIGINT=(SELECT Id FROM Lots.PauseEvent WHERE LotId=@Lot AND LocationId=@CellA AND ResumedAt IS NULL);
DECLARE @rr TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @rr EXEC Lots.LotPause_Resume @PauseEventId=@paId, @AppUserId=1;
CREATE TABLE #gbl2 (PauseEventId BIGINT, LotId BIGINT, LocationId BIGINT, LocationName NVARCHAR(200), PausedAt DATETIME2(3), PausedByUserId BIGINT, PausedReason NVARCHAR(500));
INSERT INTO #gbl2 EXEC Lots.LotPause_GetByLot @LotId=@Lot;
DECLARE @n2 INT=(SELECT COUNT(*) FROM #gbl2);
DROP TABLE #gbl2;
EXEC test.Assert_RowCount @TestName=N'[GetByLot] one remains after resume', @ExpectedCount=1, @ActualCount=@n2;
GO
-- cleanup (FK-safe)
DECLARE @ids TABLE (Id BIGINT); INSERT INTO @ids SELECT Val FROM #GBLFix WHERE Tag=N'Lot';
DELETE ol FROM Audit.OperationLog ol INNER JOIN Lots.PauseEvent pe ON pe.Id=ol.EntityId INNER JOIN @ids x ON x.Id=pe.LotId
    WHERE ol.LogEntityTypeId=(SELECT Id FROM Audit.LogEntityType WHERE Code=N'PauseEvent');
DELETE FROM Lots.PauseEvent WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
IF OBJECT_ID(N'tempdb..#GBLFix') IS NOT NULL DROP TABLE #GBLFix;
GO
