-- =============================================
-- File:         0037_PlantFloor_Quality_Capture/010_QualitySample_Record_semantics.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-10
-- Description:  Quality.QualitySample_Record pass/fail semantics (Arc 2 Phase 9,
--               FDS-08-011/012):
--                 - happy path Pass (header + per-attribute results + audit)
--                 - numeric out-of-range -> attribute IsPass 0 + overall Fail
--                   + LOT STATUS UNCHANGED (no auto-hold, FDS-08-012)
--                 - open-ended bounds (lower-only) + at-boundary passes
--                 - non-convertible numeric -> IsPass 0
--                 - optional empty attribute -> IsPass NULL (informational)
--                 - inspection of a HELD lot is allowed
--               Fixture: item P9-QC-TEST, spec P9-QC-SPEC v1 (published) with
--               Diameter (Numeric 10..20, req), Weight (Numeric >=5, req),
--               Note (Text, optional).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0037_PlantFloor_Quality_Capture/010_QualitySample_Record_semantics.sql';
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

-- ---- fixture build: item + eligibility + spec v1 (published) + LOT ----
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
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 20, @AppUserId = 1, @LotName = N'P9T-REC-L1';
DECLARE @LotOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @CL);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] fixture LOT created (control)', @Expected = N'1', @Actual = @LotOk;
GO

-- =============================================
-- Test 1: happy path Pass
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-REC-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');
DECLARE @A3 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Note');
DECLARE @LocM05 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @Trigger BIGINT = (SELECT Id FROM Quality.SampleTriggerCode WHERE Code = N'Manual');

DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15.5"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A3 AS NVARCHAR(20)) + N',"measuredValue":"looks good"}]';

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @LocationId = @LocM05,
    @SampleTriggerCodeId = @Trigger, @ResultsJson = @J, @AppUserId = 1;

DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
DECLARE @Sid BIGINT = (SELECT NewId FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] happy path Status 1', @Expected = N'1', @Actual = @S;
EXEC test.Assert_IsNotNull @TestName = N'[QSRec] happy path returns NewId', @Value = @Sid;
EXEC test.Assert_Contains @TestName = N'[QSRec] happy path message states Pass', @HaystackStr = @M, @NeedleStr = N'Pass';

DECLARE @ResCode NVARCHAR(20) = (SELECT ir.Code FROM Quality.QualitySample qs INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs.InspectionResultCodeId WHERE qs.Id = @Sid);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] overall InspectionResultCode = Pass', @Expected = N'Pass', @Actual = @ResCode;

DECLARE @RC INT = (SELECT COUNT(*) FROM Quality.QualityResult WHERE QualitySampleId = @Sid);
EXEC test.Assert_RowCount @TestName = N'[QSRec] 3 QualityResult rows written', @ExpectedCount = 3, @ActualCount = @RC;

DECLARE @DiaPass NVARCHAR(10) = (SELECT CAST(IsPass AS NVARCHAR(10)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A1);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] Diameter 15.5 in [10,20] -> IsPass 1', @Expected = N'1', @Actual = @DiaPass;
DECLARE @DiaNum NVARCHAR(40) = (SELECT CAST(NumericValue AS NVARCHAR(40)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A1);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] Diameter NumericValue shadow stored', @Expected = N'15.5000', @Actual = @DiaNum;
DECLARE @NotePass NVARCHAR(10) = (SELECT CAST(IsPass AS NVARCHAR(10)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A3);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] non-numeric present -> IsPass 1', @Expected = N'1', @Actual = @NotePass;

-- audit: entity QualitySample routes to Audit.OperationLog (not LotEventLog)
DECLARE @Aud INT = (SELECT COUNT(*) FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'InspectionRecorded' AND ol.EntityId = @Sid);
EXEC test.Assert_RowCount @TestName = N'[QSRec] InspectionRecorded audit row in OperationLog', @ExpectedCount = 1, @ActualCount = @Aud;
DECLARE @AudDesc NVARCHAR(1000) = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol INNER JOIN Audit.LogEventType et ON et.Id = ol.LogEventTypeId WHERE et.Code = N'InspectionRecorded' AND ol.EntityId = @Sid);
EXEC test.Assert_Contains @TestName = N'[QSRec] audit Description carries LotName + Inspection', @HaystackStr = @AudDesc, @NeedleStr = N'P9T-REC-L1';
EXEC test.Assert_Contains @TestName = N'[QSRec] audit Description carries the attribute tally', @HaystackStr = @AudDesc, @NeedleStr = N'(3/3 attributes)';
GO

-- =============================================
-- Test 2: numeric out-of-range -> Fail, LOT status UNCHANGED (no auto-hold)
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-REC-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');

DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"25"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"}]';

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;

DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
DECLARE @Sid BIGINT = (SELECT NewId FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] out-of-range record still Status 1 (recorded)', @Expected = N'1', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[QSRec] out-of-range message states Fail', @HaystackStr = @M, @NeedleStr = N'Fail';

DECLARE @ResCode NVARCHAR(20) = (SELECT ir.Code FROM Quality.QualitySample qs INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs.InspectionResultCodeId WHERE qs.Id = @Sid);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] overall result = Fail', @Expected = N'Fail', @Actual = @ResCode;
DECLARE @DiaPass NVARCHAR(10) = (SELECT CAST(IsPass AS NVARCHAR(10)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A1);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] Diameter 25 above upper 20 -> IsPass 0', @Expected = N'0', @Actual = @DiaPass;

-- FDS-08-012: NO AUTO-HOLD -- the LOT stays Good
DECLARE @LotStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] FAIL does NOT auto-hold: LOT status unchanged (Good)', @Expected = N'Good', @Actual = @LotStatus;
DECLARE @Crt NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @Lot);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] FAIL does not touch CrtActive', @Expected = N'0', @Actual = @Crt;
GO

-- =============================================
-- Test 3: open-ended bounds + at-boundary values pass
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-REC-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');

-- Weight has LowerLimit 5 and NO UpperLimit: a huge value passes. Diameter at
-- the exact lower bound 10 passes (inclusive).
DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"10"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"99999"}]';

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;
DECLARE @Sid BIGINT = (SELECT NewId FROM @R);

DECLARE @WPass NVARCHAR(10) = (SELECT CAST(IsPass AS NVARCHAR(10)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A2);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] open upper bound: 99999 >= 5 -> IsPass 1', @Expected = N'1', @Actual = @WPass;
DECLARE @DPass NVARCHAR(10) = (SELECT CAST(IsPass AS NVARCHAR(10)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A1);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] at-boundary value 10 = lower limit -> IsPass 1', @Expected = N'1', @Actual = @DPass;
DECLARE @ResCode NVARCHAR(20) = (SELECT ir.Code FROM Quality.QualitySample qs INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs.InspectionResultCodeId WHERE qs.Id = @Sid);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] open-bounds sample overall Pass', @Expected = N'Pass', @Actual = @ResCode;
GO

-- =============================================
-- Test 4: non-convertible numeric value -> IsPass 0, overall Fail
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-REC-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');

DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"abc"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"}]';

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;
DECLARE @Sid BIGINT = (SELECT NewId FROM @R);

DECLARE @DPass NVARCHAR(10) = (SELECT CAST(IsPass AS NVARCHAR(10)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A1);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] non-convertible ''abc'' on limited numeric -> IsPass 0', @Expected = N'0', @Actual = @DPass;
DECLARE @DNum NVARCHAR(40) = (SELECT CAST(NumericValue AS NVARCHAR(40)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A1);
EXEC test.Assert_IsNull @TestName = N'[QSRec] non-convertible value has NULL NumericValue', @Value = @DNum;
DECLARE @ResCode NVARCHAR(20) = (SELECT ir.Code FROM Quality.QualitySample qs INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs.InspectionResultCodeId WHERE qs.Id = @Sid);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] non-convertible required attr -> overall Fail', @Expected = N'Fail', @Actual = @ResCode;
GO

-- =============================================
-- Test 5: optional attribute submitted empty -> IsPass NULL (informational)
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-REC-L1');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');
DECLARE @A3 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Note');

DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A3 AS NVARCHAR(20)) + N',"measuredValue":""}]';

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;
DECLARE @Sid BIGINT = (SELECT NewId FROM @R);

DECLARE @NotePass NVARCHAR(10) = (SELECT CAST(IsPass AS NVARCHAR(10)) FROM Quality.QualityResult WHERE QualitySampleId = @Sid AND QualitySpecAttributeId = @A3);
EXEC test.Assert_IsNull @TestName = N'[QSRec] optional empty attribute -> IsPass NULL', @Value = @NotePass;
DECLARE @ResCode NVARCHAR(20) = (SELECT ir.Code FROM Quality.QualitySample qs INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs.InspectionResultCodeId WHERE qs.Id = @Sid);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] informational NULL does not fail the rollup', @Expected = N'Pass', @Actual = @ResCode;
GO

-- =============================================
-- Test 6: inspection of a HELD lot is allowed (any status)
-- =============================================
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-REC-L1');
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @Lot;

DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @A2 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Weight');

DECLARE @J NVARCHAR(MAX) =
      N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15"},'
    + N'{"qualitySpecAttributeId":'  + CAST(@A2 AS NVARCHAR(20)) + N',"measuredValue":"12"}]';

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record
    @LotId = @Lot, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[QSRec] inspection of a HELD lot is allowed', @Expected = N'1', @Actual = @S;

DECLARE @GoodId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
UPDATE Lots.Lot SET LotStatusId = @GoodId WHERE Id = @Lot;
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
