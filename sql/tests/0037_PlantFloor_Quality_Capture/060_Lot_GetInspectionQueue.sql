-- =============================================
-- File:         0037_PlantFloor_Quality_Capture/060_Lot_GetInspectionQueue.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-24
-- Description:  Tests for Lots.Lot_GetInspectionQueueByLocation (third-party inspection
--   station queue). Returns OPEN Received/ReceivedOffsite LOTs at the station with their
--   LATEST inspection result. Covers: not-yet-inspected -> NULL result; inspected Pass ->
--   'Pass'; re-inspected (latest wins) -> 'Fail'; Manufactured LOT excluded; LOT at another
--   location excluded. Station cell = INSP-SORT-T1.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0037_PlantFloor_Quality_Capture/060_Lot_GetInspectionQueue.sql';
GO

-- ---- cleanup ----
DELETE qs FROM Quality.QualitySample qs INNER JOIN Lots.Lot l ON l.Id=qs.LotId WHERE l.LotName LIKE N'INSPQ-%';
DELETE FROM Quality.QualitySpecVersion WHERE QualitySpecId IN (SELECT Id FROM Quality.QualitySpec WHERE Name=N'INSPQ-TEST-SPEC');
DELETE FROM Quality.QualitySpec WHERE Name=N'INSPQ-TEST-SPEC';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id=c.AncestorLotId OR l.Id=c.DescendantLotId WHERE l.LotName LIKE N'INSPQ-%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id=m.LotId WHERE l.LotName LIKE N'INSPQ-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'INSPQ-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'P-INSP-TP') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-INSP-TP', N'Third-party pass-through part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P-INSP-TP');
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'INSP-SORT-T1');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'WHSE');
DECLARE @Recv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @Manu BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Manufactured');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');

-- minimal quality spec version for the inspected cases
INSERT INTO Quality.QualitySpec (Name, CreatedAt) VALUES (N'INSPQ-TEST-SPEC', @Now);
DECLARE @Spec BIGINT = SCOPE_IDENTITY();
INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, CreatedByUserId, CreatedAt) VALUES (@Spec, 1, @Now, 1, @Now);
DECLARE @SpecVer BIGINT = SCOPE_IDENTITY();

-- helper: insert a received LOT at a location with an arrival movement
DECLARE @L_new BIGINT, @L_pass BIGINT, @L_refail BIGINT, @L_manu BIGINT, @L_other BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, VendorLotNumber, CreatedByUserId, CreatedAt) VALUES (N'INSPQ-NEW', @Item, @Recv, @Good, 10, 10, @Station, N'VEND-001', 1, @Now); SET @L_new = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, VendorLotNumber, CreatedByUserId, CreatedAt) VALUES (N'INSPQ-PASS', @Item, @Recv, @Good, 10, 10, @Station, N'VEND-002', 1, @Now); SET @L_pass = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, VendorLotNumber, CreatedByUserId, CreatedAt) VALUES (N'INSPQ-REFAIL', @Item, @Recv, @Good, 10, 10, @Station, N'VEND-003', 1, @Now); SET @L_refail = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'INSPQ-MANU', @Item, @Manu, @Good, 10, 10, @Station, 1, @Now); SET @L_manu = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'INSPQ-OTHER', @Item, @Recv, @Good, 10, 10, @Other, 1, @Now); SET @L_other = SCOPE_IDENTITY();
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@L_new, NULL, @Station, 1, @Now), (@L_pass, NULL, @Station, 1, @Now), (@L_refail, NULL, @Station, 1, @Now);

-- inspections: PASS on the pass LOT; on the refail LOT, an earlier Pass then a later Fail (latest wins)
INSERT INTO Quality.QualitySample (LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId, InspectionResultCodeId, SampledByUserId, SampledAt) VALUES (@L_pass, @SpecVer, @Station, 9, 1, 1, @Now);
INSERT INTO Quality.QualitySample (LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId, InspectionResultCodeId, SampledByUserId, SampledAt) VALUES (@L_refail, @SpecVer, @Station, 9, 1, 1, DATEADD(MINUTE,-5,@Now));
INSERT INTO Quality.QualitySample (LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId, InspectionResultCodeId, SampledByUserId, SampledAt) VALUES (@L_refail, @SpecVer, @Station, 9, 2, 1, @Now);
GO

-- =============================================
-- Test
-- =============================================
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'INSP-SORT-T1');
DECLARE @Q TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, VendorLotNumber NVARCHAR(50), LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
    LatestInspectionResult NVARCHAR(20), LatestSampledAt DATETIME2(3), ArrivedAt DATETIME2(3));
INSERT INTO @Q EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId=@Station;

-- received LOTs present; manufactured + other-location excluded
DECLARE @newIn NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName=N'INSPQ-NEW');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue] not-yet-inspected received LOT present', @Expected=N'1', @Actual=@newIn;
DECLARE @newRes NVARCHAR(10) = (SELECT CASE WHEN LatestInspectionResult IS NULL THEN N'NULL' ELSE LatestInspectionResult END FROM @Q WHERE LotName=N'INSPQ-NEW');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue] not-inspected LOT has NULL result', @Expected=N'NULL', @Actual=@newRes;
DECLARE @vend NVARCHAR(20) = (SELECT VendorLotNumber FROM @Q WHERE LotName=N'INSPQ-NEW');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue] vendor lot surfaced', @Expected=N'VEND-001', @Actual=@vend;

DECLARE @passRes NVARCHAR(10) = (SELECT LatestInspectionResult FROM @Q WHERE LotName=N'INSPQ-PASS');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue] inspected LOT shows Pass', @Expected=N'Pass', @Actual=@passRes;

DECLARE @refailRes NVARCHAR(10) = (SELECT LatestInspectionResult FROM @Q WHERE LotName=N'INSPQ-REFAIL');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue] re-inspected LOT shows latest (Fail)', @Expected=N'Fail', @Actual=@refailRes;

DECLARE @manuIn NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName=N'INSPQ-MANU');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue] Manufactured LOT excluded (received-origin only)', @Expected=N'0', @Actual=@manuIn;
DECLARE @otherIn NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName=N'INSPQ-OTHER');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue] received LOT at another location excluded', @Expected=N'0', @Actual=@otherIn;
GO

-- ---- cleanup ----
DELETE qs FROM Quality.QualitySample qs INNER JOIN Lots.Lot l ON l.Id=qs.LotId WHERE l.LotName LIKE N'INSPQ-%';
DELETE FROM Quality.QualitySpecVersion WHERE QualitySpecId IN (SELECT Id FROM Quality.QualitySpec WHERE Name=N'INSPQ-TEST-SPEC');
DELETE FROM Quality.QualitySpec WHERE Name=N'INSPQ-TEST-SPEC';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id=m.LotId WHERE l.LotName LIKE N'INSPQ-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'INSPQ-%';
GO

EXEC test.EndTestFile;
GO
