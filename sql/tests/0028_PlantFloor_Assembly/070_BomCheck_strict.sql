-- =============================================
-- File:         0028_PlantFloor_Assembly/070_BomCheck_strict.sql
-- Description:  Workorder.ConsumptionEvent_RecordWithBomCheck strict path (UJ-09 /
--               FDS-06-011). On-BOM source consumes; off-BOM source rejects (no
--               override) with the FDS-06-011 message and writes no ConsumptionEvent.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/070_BomCheck_strict.sql';
GO

-- ---- cleanup (transient LOTs/consumptions; Items + BOM persistent) ----
DELETE ce FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot l ON l.Id = ce.SourceLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST'));
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
-- 3 items: producing, on-BOM component, off-BOM
DECLARE @parts TABLE (pn NVARCHAR(50));
INSERT INTO @parts VALUES (N'P6-PROD-TEST'), (N'P6-COMP-TEST'), (N'P6-OFFBOM-TEST');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
SELECT 3, p.pn, p.pn, 1, @Now, 1 FROM @parts p WHERE NOT EXISTS (SELECT 1 FROM Parts.Item i WHERE i.PartNumber = p.pn);

DECLARE @Prod BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-PROD-TEST');
DECLARE @Comp BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-COMP-TEST');
DECLARE @Off  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-OFFBOM-TEST');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

-- eligibility so Lot_Create succeeds for all three at the cell
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT v.Id, @Cell, 0, @Now FROM (VALUES (@Prod), (@Comp), (@Off)) v(Id)
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = v.Id AND il.LocationId = @Cell AND il.DeprecatedAt IS NULL);

-- published BOM: PROD <- COMP
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Prod AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Prod, 1, @Now, @Now, 1, @Now);
    DECLARE @Bom BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@Bom, @Comp, 1, 1, 1);
END

DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @CT TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CT EXEC Lots.Lot_Create @ItemId = @Prod, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @LotName = N'P6T-PROD'; DECLARE @ProdLot BIGINT = (SELECT NewId FROM @CT); DELETE FROM @CT;
INSERT INTO @CT EXEC Lots.Lot_Create @ItemId = @Comp, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 50, @AppUserId = 1, @LotName = N'P6T-COMP'; DECLARE @CompLot BIGINT = (SELECT NewId FROM @CT); DELETE FROM @CT;
INSERT INTO @CT EXEC Lots.Lot_Create @ItemId = @Off, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 50, @AppUserId = 1, @LotName = N'P6T-OFF'; DECLARE @OffLot BIGINT = (SELECT NewId FROM @CT);

-- on-BOM consumption succeeds
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R1 EXEC Workorder.ConsumptionEvent_RecordWithBomCheck @SourceLotId = @CompLot, @ProducingLotId = @ProdLot, @CellLocationId = @Cell, @ConsumedPieceCount = 1, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
DECLARE @Ce1 BIGINT = (SELECT NewId FROM @R1);
DECLARE @Ce1Str NVARCHAR(20) = CAST(@Ce1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[BomStrict] on-BOM consumption Status 1', @Expected = N'1', @Actual = @S1;
EXEC test.Assert_IsNotNull @TestName = N'[BomStrict] ConsumptionEvent NewId returned', @Value = @Ce1Str;
DECLARE @CeOk NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE Id = @Ce1 AND ConsumedItemId = @Comp AND ProducedItemId = @Prod AND ProducedLotId = @ProdLot);
EXEC test.Assert_IsEqual @TestName = N'[BomStrict] ConsumptionEvent persisted (comp -> prod)', @Expected = N'1', @Actual = @CeOk;

-- off-BOM consumption WITHOUT override rejects
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Workorder.ConsumptionEvent_RecordWithBomCheck @SourceLotId = @OffLot, @ProducingLotId = @ProdLot, @CellLocationId = @Cell, @ConsumedPieceCount = 1, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
DECLARE @M2 NVARCHAR(500) = (SELECT Message FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[BomStrict] off-BOM without override rejects (Status 0)', @Expected = N'0', @Actual = @S2;
DECLARE @M2ok NVARCHAR(10) = CASE WHEN @M2 LIKE N'%not a configured component%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[BomStrict] reject message is FDS-06-011 shape', @Expected = N'1', @Actual = @M2ok;
DECLARE @OffCe NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE SourceLotId = @OffLot);
EXEC test.Assert_IsEqual @TestName = N'[BomStrict] no ConsumptionEvent for off-BOM source', @Expected = N'0', @Actual = @OffCe;
GO

DELETE ce FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot l ON l.Id = ce.SourceLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST'));
GO

EXEC test.EndTestFile;
GO
