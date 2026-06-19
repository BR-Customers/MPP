-- =============================================
-- File:         0028_PlantFloor_Assembly/080_BomCheck_supervisor_override.sql
-- Description:  Workorder.ConsumptionEvent_RecordWithBomCheck override path (UJ-09).
--               Off-BOM + @OverrideAuthorized=1 + supervisor @OverrideAppUserId writes
--               the consumption + a MaterialSubstituteOverride audit (LotEventLog,
--               B7) capturing BOTH user ids; override without a supervisor rejects.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/080_BomCheck_supervisor_override.sql';
GO

DELETE ce FROM Workorder.ConsumptionEvent ce INNER JOIN Lots.Lot l ON l.Id = ce.SourceLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST');
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'P6-PROD-TEST', N'P6-COMP-TEST', N'P6-OFFBOM-TEST'));
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @parts TABLE (pn NVARCHAR(50));
INSERT INTO @parts VALUES (N'P6-PROD-TEST'), (N'P6-COMP-TEST'), (N'P6-OFFBOM-TEST');
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
SELECT 3, p.pn, p.pn, 1, @Now, 1 FROM @parts p WHERE NOT EXISTS (SELECT 1 FROM Parts.Item i WHERE i.PartNumber = p.pn);

DECLARE @Prod BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-PROD-TEST');
DECLARE @Comp BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-COMP-TEST');
DECLARE @Off  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-OFFBOM-TEST');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');

INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT v.Id, @Cell, 0, @Now FROM (VALUES (@Prod), (@Comp), (@Off)) v(Id)
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = v.Id AND il.LocationId = @Cell AND il.DeprecatedAt IS NULL);

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Prod AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Prod, 1, @Now, @Now, 1, @Now);
    DECLARE @Bom BIGINT = SCOPE_IDENTITY();
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (@Bom, @Comp, 1, 1, 1);
END

DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @CT TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CT EXEC Lots.Lot_Create @ItemId = @Prod, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @LotName = N'P6T-PROD'; DECLARE @ProdLot BIGINT = (SELECT NewId FROM @CT); DELETE FROM @CT;
INSERT INTO @CT EXEC Lots.Lot_Create @ItemId = @Off, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Cell, @PieceCount = 50, @AppUserId = 1, @LotName = N'P6T-OFF'; DECLARE @OffLot BIGINT = (SELECT NewId FROM @CT);

-- off-BOM WITH supervisor override (operator 1, supervisor 2) -> succeeds
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R1 EXEC Workorder.ConsumptionEvent_RecordWithBomCheck @SourceLotId = @OffLot, @ProducingLotId = @ProdLot, @CellLocationId = @Cell, @ConsumedPieceCount = 1, @OverrideAppUserId = 2, @OverrideAuthorized = 1, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[BomOverride] authorized override succeeds (Status 1)', @Expected = N'1', @Actual = @S1;
DECLARE @CeOk NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ConsumptionEvent WHERE SourceLotId = @OffLot AND ProducedLotId = @ProdLot);
EXEC test.Assert_IsEqual @TestName = N'[BomOverride] ConsumptionEvent written on override', @Expected = N'1', @Actual = @CeOk;

-- MaterialSubstituteOverride audit in LotEventLog (B7) captures both user ids
DECLARE @AudCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.LotEventLog le INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId WHERE et.Code = N'MaterialSubstituteOverride' AND le.EntityId = @ProdLot);
EXEC test.Assert_IsEqual @TestName = N'[BomOverride] MaterialSubstituteOverride audit in LotEventLog', @Expected = N'1', @Actual = @AudCnt;
DECLARE @NV NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Lots.LotEventLog le INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId WHERE et.Code = N'MaterialSubstituteOverride' AND le.EntityId = @ProdLot ORDER BY le.Id DESC);
DECLARE @BothIds NVARCHAR(10) = CASE WHEN @NV LIKE N'%"OperatorUserId":1%' AND @NV LIKE N'%"SupervisorUserId":2%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[BomOverride] audit captures operator + supervisor ids', @Expected = N'1', @Actual = @BothIds;

-- override flagged but NO supervisor -> rejects
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Workorder.ConsumptionEvent_RecordWithBomCheck @SourceLotId = @OffLot, @ProducingLotId = @ProdLot, @CellLocationId = @Cell, @ConsumedPieceCount = 1, @OverrideAuthorized = 1, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[BomOverride] override without supervisor rejects (Status 0)', @Expected = N'0', @Actual = @S2;
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
