-- =============================================
-- File:         0027_PlantFloor_Machining/030_MachiningIn_BOM_lookup_edge_cases.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  BOM-lookup edge cases for MachiningIn_PickAndConsume (FDS-05-033).
--                 - missing BOM rejects (no active single-line BOM names the source)
--                 - multiple matching BOMs reject (ambiguous rename)
--                 - deprecated BOM is NOT used (a deprecated single-line BOM alone
--                   => missing-BOM rejection)
--               Uses isolated fixture items per case (P5-NOBOM-SRC, P5-AMB-SRC,
--               P5-DEP-SRC) eligible at MA1-COMPBR-MIN via a Direct ItemLocation so
--               Lot_Create succeeds and the eligibility gate is passed -- isolating
--               the BOM-resolution branch.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/030_MachiningIn_BOM_lookup_edge_cases.sql';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');

-- ---- source items (Direct-eligible at the Cell so Lot_Create + eligibility gate pass) ----
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-NOBOM-SRC')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P5-NOBOM-SRC', N'Phase5 no-BOM source', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-AMB-SRC')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P5-AMB-SRC', N'Phase5 ambiguous source', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-DEP-SRC')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (2, N'P5-DEP-SRC', N'Phase5 deprecated-BOM source', 1, @Now, 1);
-- machined items for the ambiguous + deprecated cases
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-AMB-MACH1')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-AMB-MACH1', N'Phase5 ambiguous machined 1', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-AMB-MACH2')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-AMB-MACH2', N'Phase5 ambiguous machined 2', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-DEP-MACH')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-DEP-MACH', N'Phase5 deprecated machined', 1, @Now, 1);

DECLARE @NoBom BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-NOBOM-SRC');
DECLARE @AmbSrc BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-AMB-SRC');
DECLARE @DepSrc BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-DEP-SRC');
DECLARE @Amb1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-AMB-MACH1');
DECLARE @Amb2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-AMB-MACH2');
DECLARE @DepMach BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-DEP-MACH');

-- Direct eligibility for each SOURCE at the Cell (isolates BOM branch from eligibility)
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT v.ItemId, @Cell, 0, @Now
FROM (VALUES (@NoBom), (@AmbSrc), (@DepSrc)) v(ItemId)
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = v.ItemId AND il.LocationId = @Cell AND il.DeprecatedAt IS NULL);

-- Two published single-line BOMs naming P5-AMB-SRC (ambiguous)
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Amb1)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt) VALUES (@Amb1, 1, '2026-01-01', '2026-01-01', NULL, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @AmbSrc, 1.0, 1, 1);
END
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Amb2)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt) VALUES (@Amb2, 1, '2026-01-01', '2026-01-01', NULL, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @AmbSrc, 1.0, 1, 1);
END

-- A DEPRECATED single-line BOM naming P5-DEP-SRC (must NOT be used)
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @DepMach)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt) VALUES (@DepMach, 1, '2026-01-01', '2026-01-01', '2026-02-01', 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @DepSrc, 1.0, 1, 1);
END
GO

-- ---- LOT cleanup ----
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-BOM%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-BOM%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-BOM%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-BOM%';
GO

-- =============================================
-- Test 1: missing BOM rejects
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @NoBom BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-NOBOM-SRC');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L1 BIGINT;
CREATE TABLE #C1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C1 EXEC Lots.Lot_Create @ItemId = @NoBom, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-BOM-NOBOM';
SELECT @L1 = NewId FROM #C1; DROP TABLE #C1;

DECLARE @S1 BIT, @M1 NVARCHAR(500);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT);
INSERT INTO #R1 EXEC Workorder.MachiningIn_PickAndConsume @SourceLotId = @L1, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S1 = Status, @M1 = Message FROM #R1; DROP TABLE #R1;
DECLARE @S1cond BIT = CASE WHEN @S1 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInBom] missing BOM rejected', @Condition = @S1cond;
EXEC test.Assert_Contains @TestName = N'[MachInBom] missing-BOM message cites no BOM', @HaystackStr = @M1, @NeedleStr = N'No active BOM';
GO

-- =============================================
-- Test 2: multiple matching BOMs reject (ambiguous)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @AmbSrc BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-AMB-SRC');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L2 BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId = @AmbSrc, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-BOM-AMB';
SELECT @L2 = NewId FROM #C2; DROP TABLE #C2;

DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT);
INSERT INTO #R2 EXEC Workorder.MachiningIn_PickAndConsume @SourceLotId = @L2, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S2 = Status, @M2 = Message FROM #R2; DROP TABLE #R2;
DECLARE @S2cond BIT = CASE WHEN @S2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInBom] ambiguous BOM rejected', @Condition = @S2cond;
EXEC test.Assert_Contains @TestName = N'[MachInBom] ambiguous-BOM message cites ambiguity', @HaystackStr = @M2, @NeedleStr = N'Ambiguous';
GO

-- =============================================
-- Test 3: deprecated BOM not used (=> missing-BOM rejection)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN');
DECLARE @DepSrc BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-DEP-SRC');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');

DECLARE @L3 BIGINT;
CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = @DepSrc, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 20, @AppUserId = 1, @LotName = N'P5T-BOM-DEP';
SELECT @L3 = NewId FROM #C3; DROP TABLE #C3;

DECLARE @S3 BIT, @M3 NVARCHAR(500);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, NewMachinedLotName NVARCHAR(50), ConsumptionEventId BIGINT, ProductionEventId BIGINT);
INSERT INTO #R3 EXEC Workorder.MachiningIn_PickAndConsume @SourceLotId = @L3, @CellLocationId = @Cell, @AppUserId = 1;
SELECT @S3 = Status, @M3 = Message FROM #R3; DROP TABLE #R3;
DECLARE @S3cond BIT = CASE WHEN @S3 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachInBom] deprecated BOM not used (rejected)', @Condition = @S3cond;
EXEC test.Assert_Contains @TestName = N'[MachInBom] deprecated-BOM => no-active-BOM message', @HaystackStr = @M3, @NeedleStr = N'No active BOM';
GO

-- ---- cleanup ----
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-BOM%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-BOM%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-BOM%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-BOM%';
GO

EXEC test.EndTestFile;
GO
