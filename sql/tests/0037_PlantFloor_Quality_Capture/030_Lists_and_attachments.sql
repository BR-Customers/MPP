-- =============================================
-- File:         0037_PlantFloor_Quality_Capture/030_Lists_and_attachments.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-10
-- Description:  Read-proc shapes + attachment lifecycle (Arc 2 Phase 9):
--                 - Quality.QualitySample_ListByLot (newest-first, ET SampledAt,
--                   result code, spec name/version, inspector, result counts)
--                 - Quality.QualityResult_ListBySample (attribute-joined rows,
--                   SortOrder ordering)
--                 - Quality.QualityAttachment_Add / _ListBySample
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0037_PlantFloor_Quality_Capture/030_Lists_and_attachments.sql';
GO

-- ---- fixture cleanup (re-runnable) ----
DELETE qa FROM Quality.QualityAttachment qa INNER JOIN Quality.QualitySample qs ON qs.Id = qa.QualitySampleId INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE FROM Quality.QualityAttachment WHERE FilePath LIKE N'\\p9test\%';
DELETE qr FROM Quality.QualityResult qr INNER JOIN Quality.QualitySample qs ON qs.Id = qr.QualitySampleId INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE qs FROM Quality.QualitySample qs INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST');
DELETE a FROM Quality.QualitySpecAttribute a INNER JOIN Quality.QualitySpecVersion v ON v.Id = a.QualitySpecVersionId INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC';
DELETE v FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC';
DELETE FROM Quality.QualitySpec WHERE Name = N'P9-QC-SPEC';
GO

-- ---- fixture build + two samples (Pass then Fail) ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'P9-QC-TEST', N'Phase 9 quality-capture test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST');

DECLARE @LocM05 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @LocM05 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @LocM05, 0, @Now);

INSERT INTO Quality.QualitySpec (Name, ItemId, Description, CreatedAt)
VALUES (N'P9-QC-SPEC', @Item, N'Phase 9 test spec', @Now);
DECLARE @Spec BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
VALUES (@Spec, 1, @Now, @Now, 1, @Now);
DECLARE @V1 BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Quality.QualitySpecAttribute (QualitySpecVersionId, AttributeName, DataType, Uom, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder) VALUES
    (@V1, N'Diameter', N'Numeric', N'mm', 15.0, 10.0, 20.0, 1, 1),
    (@V1, N'Weight',   N'Numeric', N'kg', NULL, 5.0,  NULL, 1, 2),
    (@V1, N'Note',     N'Text',    NULL,  NULL, NULL, NULL, 0, 3);

DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 20, @AppUserId = 1, @LotName = N'P9T-LST-L1';
DECLARE @Lot BIGINT = (SELECT NewId FROM @CL);

DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');
DECLARE @A3 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Note');

-- sample 1: Pass (3 results)
DECLARE @J1 NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A3 AS NVARCHAR(20)) + N',"measuredValue":"first"}]';
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R1 EXEC Quality.QualitySample_Record @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J1, @AppUserId = 1;

-- sample 2: Fail (Diameter out of range; 2 results)
DECLARE @J2 NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"25"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"}]';
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Quality.QualitySample_Record @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J2, @AppUserId = 1;
GO

-- =============================================
-- Test 1: ListByLot shape + counts + newest-first
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-LST-L1');
CREATE TABLE #L (
    Ord INT IDENTITY(1,1),
    Id BIGINT, LotId BIGINT, QualitySpecVersionId BIGINT, SpecName NVARCHAR(200), VersionNumber INT,
    InspectionResultCodeId BIGINT, InspectionResultCode NVARCHAR(20), InspectionResultName NVARCHAR(100),
    SampleTriggerCodeId BIGINT, SampleTriggerCode NVARCHAR(30), LocationId BIGINT, LocationName NVARCHAR(200),
    SampledByUserId BIGINT, InspectorName NVARCHAR(200), SampledAt DATETIME2(3),
    TotalResults INT, PassedResults INT
);
INSERT INTO #L EXEC Quality.QualitySample_ListByLot @LotId = @Lot;

DECLARE @C INT = (SELECT COUNT(*) FROM #L);
EXEC test.Assert_RowCount @TestName = N'[QList] ListByLot returns both samples', @ExpectedCount = 2, @ActualCount = @C;

DECLARE @FirstCode NVARCHAR(20) = (SELECT InspectionResultCode FROM #L WHERE Ord = 1);
EXEC test.Assert_IsEqual @TestName = N'[QList] newest sample (Fail) first', @Expected = N'Fail', @Actual = @FirstCode;

DECLARE @SpecName NVARCHAR(200) = (SELECT TOP 1 SpecName FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[QList] SpecName joined', @Expected = N'P9-QC-SPEC', @Actual = @SpecName;
DECLARE @Ver NVARCHAR(10) = (SELECT TOP 1 CAST(VersionNumber AS NVARCHAR(10)) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[QList] VersionNumber joined', @Expected = N'1', @Actual = @Ver;
DECLARE @Insp NVARCHAR(200) = (SELECT TOP 1 InspectorName FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[QList] InspectorName = AppUser.DisplayName', @Expected = N'System Bootstrap', @Actual = @Insp;

DECLARE @PassTotals NVARCHAR(20) = (SELECT CAST(TotalResults AS NVARCHAR(10)) + N'/' + CAST(PassedResults AS NVARCHAR(10)) FROM #L WHERE InspectionResultCode = N'Pass');
EXEC test.Assert_IsEqual @TestName = N'[QList] Pass sample counts 3 total / 3 passed', @Expected = N'3/3', @Actual = @PassTotals;
DECLARE @FailTotals NVARCHAR(20) = (SELECT CAST(TotalResults AS NVARCHAR(10)) + N'/' + CAST(PassedResults AS NVARCHAR(10)) FROM #L WHERE InspectionResultCode = N'Fail');
EXEC test.Assert_IsEqual @TestName = N'[QList] Fail sample counts 2 total / 1 passed', @Expected = N'2/1', @Actual = @FailTotals;

DECLARE @SampledAt NVARCHAR(40) = (SELECT TOP 1 CONVERT(NVARCHAR(40), SampledAt, 126) FROM #L);
EXEC test.Assert_IsNotNull @TestName = N'[QList] SampledAt present (ET-converted)', @Value = @SampledAt;
DROP TABLE #L;
GO

-- =============================================
-- Test 2: ListBySample shape + SortOrder ordering
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-LST-L1');
DECLARE @PassSample BIGINT = (
    SELECT TOP 1 qs.Id FROM Quality.QualitySample qs
    INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs.InspectionResultCodeId
    WHERE qs.LotId = @Lot AND ir.Code = N'Pass' ORDER BY qs.Id);

CREATE TABLE #D (
    Ord INT IDENTITY(1,1),
    Id BIGINT, QualitySampleId BIGINT, QualitySpecAttributeId BIGINT,
    AttributeName NVARCHAR(100), DataType NVARCHAR(50), Uom NVARCHAR(20),
    TargetValue DECIMAL(18,6), LowerLimit DECIMAL(18,6), UpperLimit DECIMAL(18,6),
    IsRequired BIT, SortOrder INT, MeasuredValue NVARCHAR(200), NumericValue DECIMAL(18,4), IsPass BIT
);
INSERT INTO #D EXEC Quality.QualityResult_ListBySample @QualitySampleId = @PassSample;

DECLARE @C INT = (SELECT COUNT(*) FROM #D);
EXEC test.Assert_RowCount @TestName = N'[QList] ListBySample returns 3 attribute rows', @ExpectedCount = 3, @ActualCount = @C;
DECLARE @First NVARCHAR(100) = (SELECT AttributeName FROM #D WHERE Ord = 1);
EXEC test.Assert_IsEqual @TestName = N'[QList] rows ordered by SortOrder (Diameter first)', @Expected = N'Diameter', @Actual = @First;
DECLARE @Last NVARCHAR(100) = (SELECT AttributeName FROM #D WHERE Ord = 3);
EXEC test.Assert_IsEqual @TestName = N'[QList] rows ordered by SortOrder (Note last)', @Expected = N'Note', @Actual = @Last;
DECLARE @Uom NVARCHAR(20) = (SELECT Uom FROM #D WHERE AttributeName = N'Diameter');
EXEC test.Assert_IsEqual @TestName = N'[QList] attribute Uom joined', @Expected = N'mm', @Actual = @Uom;
DECLARE @Upper NVARCHAR(40) = (SELECT CAST(UpperLimit AS NVARCHAR(40)) FROM #D WHERE AttributeName = N'Diameter');
EXEC test.Assert_IsEqual @TestName = N'[QList] attribute UpperLimit joined', @Expected = N'20.000000', @Actual = @Upper;
DECLARE @Meas NVARCHAR(200) = (SELECT MeasuredValue FROM #D WHERE AttributeName = N'Note');
EXEC test.Assert_IsEqual @TestName = N'[QList] MeasuredValue round-trips', @Expected = N'first', @Actual = @Meas;
DROP TABLE #D;
GO

-- =============================================
-- Test 3: attachment add + list happy path
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-LST-L1');
DECLARE @Sample BIGINT = (SELECT TOP 1 Id FROM Quality.QualitySample WHERE LotId = @Lot ORDER BY Id);

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualityAttachment_Add
    @QualitySampleId = @Sample, @FileName = N'cmm-report.pdf', @FileType = N'PDF',
    @FilePath = N'\\p9test\quality\cmm-report.pdf', @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @Aid BIGINT = (SELECT NewId FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QAtt] attachment add Status 1', @Expected = N'1', @Actual = @S;
EXEC test.Assert_IsNotNull @TestName = N'[QAtt] attachment add returns NewId', @Value = @Aid;

CREATE TABLE #A (
    Id BIGINT, QualitySampleId BIGINT, FileName NVARCHAR(260), FileType NVARCHAR(20),
    FilePath NVARCHAR(500), UploadedAt DATETIME2(3), UploadedByUserId BIGINT, UploadedByName NVARCHAR(200)
);
INSERT INTO #A EXEC Quality.QualityAttachment_ListBySample @QualitySampleId = @Sample;
DECLARE @C INT = (SELECT COUNT(*) FROM #A);
EXEC test.Assert_RowCount @TestName = N'[QAtt] ListBySample returns the attachment', @ExpectedCount = 1, @ActualCount = @C;
DECLARE @Fn NVARCHAR(260) = (SELECT FileName FROM #A);
EXEC test.Assert_IsEqual @TestName = N'[QAtt] FileName round-trips', @Expected = N'cmm-report.pdf', @Actual = @Fn;
DECLARE @By NVARCHAR(200) = (SELECT UploadedByName FROM #A);
EXEC test.Assert_IsEqual @TestName = N'[QAtt] UploadedByName joined', @Expected = N'System Bootstrap', @Actual = @By;
DROP TABLE #A;
GO

-- =============================================
-- Test 4: attachment validation
-- =============================================
-- unknown sample id rejects
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R1 EXEC Quality.QualityAttachment_Add
    @QualitySampleId = 999999999, @FileName = N'x.pdf', @FileType = N'PDF',
    @FilePath = N'\\p9test\x.pdf', @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[QAtt] unknown sample id rejected', @Expected = N'0', @Actual = @S1;

-- missing file name rejects
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Quality.QualityAttachment_Add
    @QualitySampleId = NULL, @FileName = N'', @FileType = N'PDF',
    @FilePath = N'\\p9test\y.pdf', @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[QAtt] empty FileName rejected', @Expected = N'0', @Actual = @S2;

-- NULL sample id is allowed (staged attachment)
DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R3 EXEC Quality.QualityAttachment_Add
    @QualitySampleId = NULL, @FileName = N'staged.csv', @FileType = N'CSV',
    @FilePath = N'\\p9test\staged.csv', @AppUserId = 1;
DECLARE @S3 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R3);
EXEC test.Assert_IsEqual @TestName = N'[QAtt] NULL sample id (staged) allowed', @Expected = N'1', @Actual = @S3;
GO

-- ---- cleanup ----
DELETE qa FROM Quality.QualityAttachment qa INNER JOIN Quality.QualitySample qs ON qs.Id = qa.QualitySampleId INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE FROM Quality.QualityAttachment WHERE FilePath LIKE N'\\p9test\%';
DELETE qr FROM Quality.QualityResult qr INNER JOIN Quality.QualitySample qs ON qs.Id = qr.QualitySampleId INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE qs FROM Quality.QualitySample qs INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
DELETE FROM Lots.Lot WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST');
DELETE a FROM Quality.QualitySpecAttribute a INNER JOIN Quality.QualitySpecVersion v ON v.Id = a.QualitySpecVersionId INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC';
DELETE v FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC';
DELETE FROM Quality.QualitySpec WHERE Name = N'P9-QC-SPEC';
GO

EXEC test.EndTestFile;
GO
