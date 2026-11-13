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

-- =============================================
-- v1.1 (2026-11-13, SP review): behaviour the per-LOT-seek rewrite must preserve.
--   * latest inspection = greatest SampledAt, TIES broken by greatest Id (the v1.0
--     ROW_NUMBER ... ORDER BY SampledAt DESC, Id DESC rule)
--   * ReceivedOffsite origin is included; Closed is excluded; Open status is INCLUDED
--   * @IncludeDescendants: 0 = exact, 1 = location + descendants, NULL = nothing
--   * ArrivedAt = LATEST movement, ET; LatestSampledAt ET; order = arrival ASC (a LOT with
--     no movement has a NULL arrival and sorts first), ties by Id
-- =============================================

-- ---- cleanup ----
DELETE qs FROM Quality.QualitySample qs INNER JOIN Lots.Lot l ON l.Id=qs.LotId WHERE l.LotName LIKE N'INSPQ2-%';
DELETE FROM Quality.QualitySpecVersion WHERE QualitySpecId IN (SELECT Id FROM Quality.QualitySpec WHERE Name=N'INSPQ2-TEST-SPEC');
DELETE FROM Quality.QualitySpec WHERE Name=N'INSPQ2-TEST-SPEC';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id=m.LotId WHERE l.LotName LIKE N'INSPQ2-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'INSPQ2-%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'P-INSP-TP') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P-INSP-TP', N'Third-party pass-through part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P-INSP-TP');
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'INSP-SORT-T1');
DECLARE @Parent  BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id=@Station);
DECLARE @Recv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'Received');
DECLARE @Offs BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code=N'ReceivedOffsite');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Good');
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed');
DECLARE @OpenSt BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Open');

INSERT INTO Quality.QualitySpec (Name, CreatedAt) VALUES (N'INSPQ2-TEST-SPEC', @Now);
DECLARE @Spec BIGINT = SCOPE_IDENTITY();
INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, CreatedByUserId, CreatedAt) VALUES (@Spec, 1, @Now, 1, @Now);
DECLARE @SpecVer BIGINT = SCOPE_IDENTITY();

-- TIE: two samples at the SAME instant (Pass inserted first, Fail second = higher Id -> Fail wins);
--      movements 14:00 and 15:30 UTC (latest wins -> 10:30 ET)
-- OFFS: ReceivedOffsite origin, one movement 12:00 UTC
-- CLSD: Closed -> excluded;  OPN: Open status, no movement -> included, NULL arrival sorts first
-- PAR : at the station's PARENT -> only in the parent scope
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, VendorLotNumber, CreatedByUserId, CreatedAt) VALUES
 (N'INSPQ2-TIE',  @Item, @Recv, @Good,   10, 10, @Station, N'V2-TIE',  1, @Now),
 (N'INSPQ2-OFFS', @Item, @Offs, @Good,   10, 10, @Station, N'V2-OFFS', 1, @Now),
 (N'INSPQ2-CLSD', @Item, @Recv, @Closed, 10,  0, @Station, N'V2-CLSD', 1, @Now),
 (N'INSPQ2-OPN',  @Item, @Recv, @OpenSt, 10, 10, @Station, N'V2-OPN',  1, @Now),
 (N'INSPQ2-PAR',  @Item, @Recv, @Good,   10, 10, @Parent,  N'V2-PAR',  1, @Now);

INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
SELECT l.Id, NULL, @Station, 1, NULL, '2026-01-15 14:00:00.000' FROM Lots.Lot l WHERE l.LotName=N'INSPQ2-TIE'
UNION ALL SELECT l.Id, NULL, @Station, 1, NULL, '2026-01-15 15:30:00.000' FROM Lots.Lot l WHERE l.LotName=N'INSPQ2-TIE'
UNION ALL SELECT l.Id, NULL, @Station, 1, NULL, '2026-01-15 12:00:00.000' FROM Lots.Lot l WHERE l.LotName=N'INSPQ2-OFFS';

DECLARE @TieLot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName=N'INSPQ2-TIE');
INSERT INTO Quality.QualitySample (LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId, InspectionResultCodeId, SampledByUserId, SampledAt) VALUES (@TieLot, @SpecVer, @Station, 9, 1, 1, '2026-01-15 15:00:00.000');
INSERT INTO Quality.QualitySample (LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId, InspectionResultCodeId, SampledByUserId, SampledAt) VALUES (@TieLot, @SpecVer, @Station, 9, 2, 1, '2026-01-15 15:00:00.000');
GO

DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'INSP-SORT-T1');
DECLARE @Parent  BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id=@Station);
DECLARE @Q TABLE (RowNo INT IDENTITY(1,1), Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, VendorLotNumber NVARCHAR(50), LotStatusId BIGINT, LotStatusCode NVARCHAR(20),
    LatestInspectionResult NVARCHAR(20), LatestSampledAt DATETIME2(3), ArrivedAt DATETIME2(3));
DECLARE @N NVARCHAR(10), @S NVARCHAR(200);

-- station, exact
INSERT INTO @Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, VendorLotNumber, LotStatusId, LotStatusCode, LatestInspectionResult, LatestSampledAt, ArrivedAt)
EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId=@Station, @IncludeDescendants=0;

SET @S = ISNULL((SELECT LatestInspectionResult FROM @Q WHERE LotName=N'INSPQ2-TIE'), N'<null>');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] samples tied on SampledAt: the greatest Id wins (Fail)', @Expected=N'Fail', @Actual=@S;
SET @S = ISNULL((SELECT CONVERT(NVARCHAR(30), LatestSampledAt, 121) FROM @Q WHERE LotName=N'INSPQ2-TIE'), N'<null>');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] LatestSampledAt converted UTC to Eastern', @Expected=N'2026-01-15 10:00:00.000', @Actual=@S;
SET @S = ISNULL((SELECT CONVERT(NVARCHAR(30), ArrivedAt, 121) FROM @Q WHERE LotName=N'INSPQ2-TIE'), N'<null>');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] ArrivedAt is the LATEST movement, converted UTC to Eastern', @Expected=N'2026-01-15 10:30:00.000', @Actual=@S;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName=N'INSPQ2-OFFS');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] ReceivedOffsite-origin LOT is included', @Expected=N'1', @Actual=@N;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName=N'INSPQ2-CLSD');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] Closed LOT is excluded', @Expected=N'0', @Actual=@N;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName=N'INSPQ2-OPN');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] Open-status LOT is INCLUDED (only Closed is excluded)', @Expected=N'1', @Actual=@N;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName=N'INSPQ2-PAR');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] exact scope excludes a LOT at the parent location', @Expected=N'0', @Actual=@N;
SET @S = ISNULL((SELECT STRING_AGG(LotName, N',') WITHIN GROUP (ORDER BY RowNo) FROM @Q WHERE LotName LIKE N'INSPQ2-%'), N'<none>');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] arrival order: no-movement (NULL) first, then earliest arrival', @Expected=N'INSPQ2-OPN,INSPQ2-OFFS,INSPQ2-TIE', @Actual=@S;

-- parent + descendants: the station's LOTs and the parent's own
DELETE FROM @Q;
INSERT INTO @Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, VendorLotNumber, LotStatusId, LotStatusCode, LatestInspectionResult, LatestSampledAt, ArrivedAt)
EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId=@Parent, @IncludeDescendants=1;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName LIKE N'INSPQ2-%');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] parent + descendants returns TIE, OFFS, OPN and PAR (not Closed)', @Expected=N'4', @Actual=@N;

-- parent, exact: only the parent's own LOT
DELETE FROM @Q;
INSERT INTO @Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, VendorLotNumber, LotStatusId, LotStatusCode, LatestInspectionResult, LatestSampledAt, ArrivedAt)
EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId=@Parent, @IncludeDescendants=0;
SET @S = ISNULL((SELECT STRING_AGG(LotName, N',') WITHIN GROUP (ORDER BY RowNo) FROM @Q WHERE LotName LIKE N'INSPQ2-%'), N'<none>');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] parent exact returns only the parent''s own LOT', @Expected=N'INSPQ2-PAR', @Actual=@S;

-- NULL @IncludeDescendants matches neither arm
DELETE FROM @Q;
INSERT INTO @Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, VendorLotNumber, LotStatusId, LotStatusCode, LatestInspectionResult, LatestSampledAt, ArrivedAt)
EXEC Lots.Lot_GetInspectionQueueByLocation @LocationId=@Station, @IncludeDescendants=NULL;
SET @N = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE LotName LIKE N'INSPQ2-%');
EXEC test.Assert_IsEqual @TestName=N'[InspQueue v1.1] NULL @IncludeDescendants returns nothing', @Expected=N'0', @Actual=@N;
GO

-- ---- cleanup ----
DELETE qs FROM Quality.QualitySample qs INNER JOIN Lots.Lot l ON l.Id=qs.LotId WHERE l.LotName LIKE N'INSPQ2-%';
DELETE FROM Quality.QualitySpecVersion WHERE QualitySpecId IN (SELECT Id FROM Quality.QualitySpec WHERE Name=N'INSPQ2-TEST-SPEC');
DELETE FROM Quality.QualitySpec WHERE Name=N'INSPQ2-TEST-SPEC';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id=m.LotId WHERE l.LotName LIKE N'INSPQ2-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'INSPQ2-%';
GO

EXEC test.EndTestFile;
GO
