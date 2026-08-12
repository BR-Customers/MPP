-- =============================================
-- 0055_LotGenealogyReport/030_Lot_GetShippedContainers.sql
-- Descendant-aware shipped-container band. READ proc.
-- Fixture: SUB --consume--> FG; FG packed into a Container with an AIM ShippingLabel.
--   * GetShippedContainers(FG)  -> FG's own container (subject is an FG).
--   * GetShippedContainers(SUB) -> the SAME container, via descendant reach.
--   * GetShippedContainers(ISO) -> empty (no FG container in its descendants).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0055_LotGenealogyReport/030_Lot_GetShippedContainers.sql';
GO

IF OBJECT_ID(N'tempdb..#ScFix') IS NOT NULL DROP TABLE #ScFix;
CREATE TABLE #ScFix (Tag NVARCHAR(10) PRIMARY KEY, Id BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId=eil.ItemId, @CellId=eil.LocationId FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId=eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=300, @AppUserId=1;
INSERT INTO #ScFix SELECT N'SUB', NewId FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=300, @AppUserId=1;
INSERT INTO #ScFix SELECT N'FG', NewId FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId=@ItemId, @LotOriginTypeId=@OriginRcv,
    @CurrentLocationId=@CellId, @PieceCount=10, @AppUserId=1;
INSERT INTO #ScFix SELECT N'ISO', NewId FROM @cr;

DECLARE @Sub BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'SUB');
DECLARE @Fg  BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'FG');

-- SUB consumed into FG (descendant edge).
DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rc EXEC Lots.LotGenealogy_RecordConsumption
    @SourceLotId=@Sub, @ConsumedPieceCount=250, @ProducedLotId=@Fg, @AppUserId=1;

-- Pack FG into a Container with an AIM shipping label (direct inserts).
DECLARE @Cfg BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id);
DECLARE @FgItem BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id=@Fg);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@FgItem, @Cfg, @CellId, 2, SYSUTCDATETIME(), 1);
DECLARE @Cid BIGINT = SCOPE_IDENTITY();
INSERT INTO #ScFix SELECT N'CID', @Cid;
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@Cid, 1, 250, SYSUTCDATETIME(), 1, N'Auto', @Fg);
DECLARE @LblType BIGINT = (SELECT TOP 1 Id FROM Lots.LabelTypeCode ORDER BY Id);
-- NOTE: Lots.ShippingLabel has no CreatedByUserId column (verified against 0028/0054) --
-- fixture adapted to omit it; CreatedAt/IsVoid supplied explicitly though both have defaults.
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, IsVoid, CreatedAt)
VALUES (@Cid, N'AIMTEST00013218', @LblType, 0, SYSUTCDATETIME());
GO

-- Test 1: FG (subject is itself an FG) -> its own container + AIM id.
DECLARE @Fg BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'FG');
IF OBJECT_ID(N'tempdb..#sf') IS NOT NULL DROP TABLE #sf;
CREATE TABLE #sf (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50),
                  ContainerId BIGINT, AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(100),
                  CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO #sf EXEC Lots.Lot_GetShippedContainers @LotId=@Fg;
DECLARE @sfN INT = (SELECT COUNT(*) FROM #sf);
EXEC test.Assert_RowCount @TestName=N'[Shipped] FG has 1 container', @ExpectedCount=1, @ActualCount=@sfN;
DECLARE @sfAim NVARCHAR(50) = (SELECT AimShipperId FROM #sf);
EXEC test.Assert_IsEqual @TestName=N'[Shipped] FG container carries the AIM id',
    @Expected=N'AIMTEST00013218', @Actual=@sfAim;
DROP TABLE #sf;
GO

-- Test 2: SUB (upstream) -> the same FG container, tagged with the FG LOT.
DECLARE @Sub BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'SUB');
DECLARE @Fg BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'FG');
IF OBJECT_ID(N'tempdb..#ss') IS NOT NULL DROP TABLE #ss;
CREATE TABLE #ss (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50),
                  ContainerId BIGINT, AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(100),
                  CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO #ss EXEC Lots.Lot_GetShippedContainers @LotId=@Sub;
DECLARE @ssN INT = (SELECT COUNT(*) FROM #ss);
EXEC test.Assert_RowCount @TestName=N'[Shipped] SUB reaches 1 FG container (via descendant)', @ExpectedCount=1, @ActualCount=@ssN;
DECLARE @ssFg NVARCHAR(20) = CAST((SELECT FinishedGoodLotId FROM #ss) AS NVARCHAR(20));
DECLARE @FgStr NVARCHAR(20) = CAST(@Fg AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[Shipped] SUB container tagged with the FG LOT',
    @Expected=@FgStr, @Actual=@ssFg;
DROP TABLE #ss;
GO

-- Test 3: ISO (no FG container in its descendants) -> empty.
DECLARE @Iso BIGINT=(SELECT Id FROM #ScFix WHERE Tag=N'ISO');
IF OBJECT_ID(N'tempdb..#si') IS NOT NULL DROP TABLE #si;
CREATE TABLE #si (FinishedGoodLotId BIGINT, FinishedGoodLotName NVARCHAR(50), FinishedGoodPartNumber NVARCHAR(50),
                  ContainerId BIGINT, AimShipperId NVARCHAR(50), Quantity INT, ContainerStatusName NVARCHAR(100),
                  CurrentLocationName NVARCHAR(200), CompletedAt DATETIME2(3));
INSERT INTO #si EXEC Lots.Lot_GetShippedContainers @LotId=@Iso;
DECLARE @siN INT = (SELECT COUNT(*) FROM #si);
EXEC test.Assert_RowCount @TestName=N'[Shipped] in-process LOT returns empty band', @ExpectedCount=0, @ActualCount=@siN;
DROP TABLE #si;
GO

-- ---- cleanup (containers/labels before LOTs; edges before LOTs) ----
DECLARE @Cid BIGINT = (SELECT Id FROM #ScFix WHERE Tag=N'CID');
DELETE FROM Lots.ShippingLabel WHERE ContainerId=@Cid;
DELETE FROM Lots.ContainerTray WHERE ContainerId=@Cid;
DELETE FROM Lots.Container WHERE Id=@Cid;
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT Id FROM #ScFix WHERE Tag IN (N'SUB',N'FG',N'ISO');
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);
IF OBJECT_ID(N'tempdb..#ScFix') IS NOT NULL DROP TABLE #ScFix;
GO

EXEC test.EndTestFile;
GO
