-- =============================================
-- File:         0037_PlantFloor_Quality_Capture/020_QualitySample_Record_validation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-10
-- Description:  Rejection tests for Quality.QualitySample_Record (Arc 2 Phase 9).
--               All rejections run BEFORE the transaction (FDS-11-011 /
--               Msg-3915) and no sample rows may be created by them:
--                 - missing required parameter
--                 - non-JSON ResultsJson
--                 - unknown LOT
--                 - Draft (unpublished) spec version
--                 - Deprecated spec version
--                 - attribute id not in the spec version
--                 - missing required attribute / empty required value
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0037_PlantFloor_Quality_Capture/020_QualitySample_Record_validation.sql';
GO

-- ---- fixture cleanup (re-runnable) ----
DELETE qa FROM Quality.QualityAttachment qa INNER JOIN Quality.QualitySample qs ON qs.Id = qa.QualitySampleId INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
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

-- ---- fixture build: item + spec (v1 published, v2 draft, v3 deprecated) + LOT ----
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

-- v1 published
INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
VALUES (@Spec, 1, @Now, @Now, 1, @Now);
DECLARE @V1 BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Quality.QualitySpecAttribute (QualitySpecVersionId, AttributeName, DataType, Uom, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder) VALUES
    (@V1, N'Diameter', N'Numeric', N'mm', 15.0, 10.0, 20.0, 1, 1),
    (@V1, N'Weight',   N'Numeric', N'kg', NULL, 5.0,  NULL, 1, 2);

-- v2 DRAFT (PublishedAt NULL) with its own attribute (also the "foreign attribute" donor)
INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
VALUES (@Spec, 2, @Now, NULL, 1, @Now);
DECLARE @V2 BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Quality.QualitySpecAttribute (QualitySpecVersionId, AttributeName, DataType, Uom, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder) VALUES
    (@V2, N'DraftOnly', N'Text', NULL, NULL, NULL, NULL, 0, 1);

-- v3 published then DEPRECATED
INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
VALUES (@Spec, 3, @Now, @Now, @Now, 1, @Now);

DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 20, @AppUserId = 1, @LotName = N'P9T-VAL-L1';
GO

-- =============================================
-- Test 1: missing required parameter rejects
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = NULL, @ResultsJson = N'[]', @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] missing QualitySpecVersionId rejected', @Expected = N'0', @Actual = @S;
GO

-- =============================================
-- Test 2: non-JSON ResultsJson rejects
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = N'this is not json', @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] non-JSON ResultsJson rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[QSVal] non-JSON rejection names JSON', @HaystackStr = @M, @NeedleStr = N'JSON';
GO

-- =============================================
-- Test 3: unknown LOT rejects
-- =============================================
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = 999999999, @QualitySpecVersionId = @V1, @ResultsJson = N'[]', @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] unknown LOT rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[QSVal] unknown LOT rejection reason', @HaystackStr = @M, @NeedleStr = N'LOT not found';
GO

-- =============================================
-- Test 4: Draft (unpublished) spec version rejects
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @V2 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 2);
DECLARE @A BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V2 AND AttributeName = N'DraftOnly');
DECLARE @J NVARCHAR(MAX) = N'[{"qualitySpecAttributeId":' + CAST(@A AS NVARCHAR(20)) + N',"measuredValue":"x"}]';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V2, @ResultsJson = @J, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] Draft spec version rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[QSVal] Draft rejection names published state', @HaystackStr = @M, @NeedleStr = N'published';
GO

-- =============================================
-- Test 5: Deprecated spec version rejects
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @V3 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 3);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V3, @ResultsJson = N'[]', @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] Deprecated spec version rejected', @Expected = N'0', @Actual = @S;
GO

-- =============================================
-- Test 6: attribute id from ANOTHER version rejects
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @V2 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 2);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');
DECLARE @Foreign BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V2 AND AttributeName = N'DraftOnly');

DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@Foreign AS NVARCHAR(20)) + N',"measuredValue":"x"}]';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] foreign attribute id rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[QSVal] foreign-attribute rejection reason', @HaystackStr = @M, @NeedleStr = N'does not belong';
GO

-- =============================================
-- Test 7: missing required attribute rejects (names the attribute)
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');

-- only Diameter submitted; required Weight is missing
DECLARE @J NVARCHAR(MAX) = N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15"}]';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] missing required attribute rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[QSVal] rejection names the missing attribute', @HaystackStr = @M, @NeedleStr = N'Weight';
GO

-- =============================================
-- Test 8: required attribute with EMPTY value rejects
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');

DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":""}]';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSVal] empty required value rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[QSVal] empty-value rejection names the attribute', @HaystackStr = @M, @NeedleStr = N'Weight';
GO

-- =============================================
-- Test 9: no sample rows were created by any rejection
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-VAL-L1');
DECLARE @C INT = (SELECT COUNT(*) FROM Quality.QualitySample WHERE LotId = @Lot);
EXEC test.Assert_RowCount @TestName = N'[QSVal] rejections created NO sample rows (pre-txn)', @ExpectedCount = 0, @ActualCount = @C;
GO

-- ---- cleanup ----
DELETE qa FROM Quality.QualityAttachment qa INNER JOIN Quality.QualitySample qs ON qs.Id = qa.QualitySampleId INNER JOIN Lots.Lot l ON l.Id = qs.LotId INNER JOIN Parts.Item i ON i.Id = l.ItemId WHERE i.PartNumber = N'P9-QC-TEST';
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
