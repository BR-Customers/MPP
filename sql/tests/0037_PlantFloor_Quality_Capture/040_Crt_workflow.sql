-- =============================================
-- File:         0037_PlantFloor_Quality_Capture/040_Crt_workflow.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-10
-- Description:  CRT workflow (Arc 2 Phase 9, FDS-10-011/012):
--                 - Lots.Lot_SetCrt happy + audit (LotEventLog CrtActivated)
--                 - double-set rejected (idempotence guard)
--                 - SetCrt on a Closed LOT rejected
--                 - Lots.Lot_ClearCrt happy + audit (CrtCleared) + clear-on-clear rejected
--                 - Quality.Crt_FlagMissedInspection writes ONLY the audit row
--                 - Quality.Crt_GetRequiredInspections scoping: at-location +
--                   descendant walk, excludes non-CRT / Closed / out-of-scope
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0037_PlantFloor_Quality_Capture/040_Crt_workflow.sql';
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

-- ---- fixture build: item eligible at DC1-M05 / DC1-M06 / MA1-COMPBR-AOUT + 4 LOTs + spec ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'P9-QC-TEST', N'Phase 9 quality-capture test part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P9-QC-TEST');

DECLARE @LocM05 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @LocM06 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M06');
DECLARE @LocAsm BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @LocM05 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @LocM05, 0, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @LocM06 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @LocM06, 0, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @LocAsm AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Item, @LocAsm, 0, @Now);

INSERT INTO Quality.QualitySpec (Name, ItemId, Description, CreatedAt)
VALUES (N'P9-QC-SPEC', @Item, N'Phase 9 test spec', @Now);
DECLARE @Spec BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt)
VALUES (@Spec, 1, @Now, @Now, 1, @Now);
DECLARE @V1 BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);
INSERT INTO Quality.QualitySpecAttribute (QualitySpecVersionId, AttributeName, DataType, Uom, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder) VALUES
    (@V1, N'Diameter', N'Numeric', N'mm', 15.0, 10.0, 20.0, 1, 1);

DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @CL TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 10, @AppUserId = 1, @LotName = N'P9T-CRT-LA';
DELETE FROM @CL;
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM06, @PieceCount = 10, @AppUserId = 1, @LotName = N'P9T-CRT-LB';
DELETE FROM @CL;
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocM05, @PieceCount = 10, @AppUserId = 1, @LotName = N'P9T-CRT-LC';
DELETE FROM @CL;
INSERT INTO @CL EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocAsm, @PieceCount = 10, @AppUserId = 1, @LotName = N'P9T-CRT-LD';
GO

-- =============================================
-- Test 1: SetCrt happy path + LotEventLog audit
-- =============================================
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LA');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Lots.Lot_SetCrt @LotId = @LA, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[CRT] SetCrt Status 1', @Expected = N'1', @Actual = @S;
DECLARE @Flag NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @LA);
EXEC test.Assert_IsEqual @TestName = N'[CRT] Lot.CrtActive flipped to 1', @Expected = N'1', @Actual = @Flag;
DECLARE @Aud INT = (SELECT COUNT(*) FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'CrtActivated' AND el.LotId = @LA);
EXEC test.Assert_RowCount @TestName = N'[CRT] CrtActivated audit row in LotEventLog (B7 route)', @ExpectedCount = 1, @ActualCount = @Aud;
DECLARE @Desc NVARCHAR(1000) = (SELECT TOP 1 el.Description FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'CrtActivated' AND el.LotId = @LA);
EXEC test.Assert_Contains @TestName = N'[CRT] audit Description = <LotName> . CRT . Activated', @HaystackStr = @Desc, @NeedleStr = N'CRT';
GO

-- =============================================
-- Test 2: double-set rejected (idempotence guard)
-- =============================================
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LA');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Lots.Lot_SetCrt @LotId = @LA, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[CRT] double SetCrt rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[CRT] double-set rejection says already active', @HaystackStr = @M, @NeedleStr = N'already';
DECLARE @Aud INT = (SELECT COUNT(*) FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'CrtActivated' AND el.LotId = @LA);
EXEC test.Assert_RowCount @TestName = N'[CRT] rejected double-set wrote NO second audit row', @ExpectedCount = 1, @ActualCount = @Aud;
GO

-- =============================================
-- Test 3: SetCrt on a Closed LOT rejected
-- =============================================
DECLARE @LC BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LC');
DECLARE @ClosedId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
UPDATE Lots.Lot SET LotStatusId = @ClosedId WHERE Id = @LC;

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Lots.Lot_SetCrt @LotId = @LC, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[CRT] SetCrt on Closed LOT rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[CRT] Closed rejection reason', @HaystackStr = @M, @NeedleStr = N'Closed';
GO

-- =============================================
-- Test 4: unknown LOT rejected (Set + Clear)
-- =============================================
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R1 EXEC Lots.Lot_SetCrt @LotId = 999999999, @AppUserId = 1;
DECLARE @S1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName = N'[CRT] SetCrt unknown LOT rejected', @Expected = N'0', @Actual = @S1;
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Lots.Lot_ClearCrt @LotId = 999999999, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[CRT] ClearCrt unknown LOT rejected', @Expected = N'0', @Actual = @S2;
GO

-- =============================================
-- Test 5: FlagMissedInspection on CRT-active LOT writes ONLY the audit row
-- =============================================
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LA');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Quality.Crt_FlagMissedInspection @LotId = @LA, @Remarks = N'operator skipped station check', @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[CRT] FlagMissedInspection Status 1', @Expected = N'1', @Actual = @S;
DECLARE @Aud INT = (SELECT COUNT(*) FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'MissedCrtInspect' AND el.LotId = @LA);
EXEC test.Assert_RowCount @TestName = N'[CRT] MissedCrtInspect audit row in LotEventLog', @ExpectedCount = 1, @ActualCount = @Aud;
DECLARE @Desc NVARCHAR(1000) = (SELECT TOP 1 el.Description FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'MissedCrtInspect' AND el.LotId = @LA);
EXEC test.Assert_Contains @TestName = N'[CRT] missed-inspect Description carries the remarks', @HaystackStr = @Desc, @NeedleStr = N'operator skipped';
-- no table mutation: sample count for the LOT is still zero
DECLARE @SampleCount INT = (SELECT COUNT(*) FROM Quality.QualitySample WHERE LotId = @LA);
EXEC test.Assert_RowCount @TestName = N'[CRT] FlagMissed mutates no quality tables', @ExpectedCount = 0, @ActualCount = @SampleCount;
GO

-- =============================================
-- Test 6: FlagMissedInspection on a non-CRT LOT rejected
-- =============================================
DECLARE @LB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LB');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Quality.Crt_FlagMissedInspection @LotId = @LB, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
DECLARE @M NVARCHAR(500) = (SELECT Message FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[CRT] FlagMissed on non-CRT LOT rejected', @Expected = N'0', @Actual = @S;
EXEC test.Assert_Contains @TestName = N'[CRT] non-CRT rejection reason', @HaystackStr = @M, @NeedleStr = N'not CRT-active';
GO

-- =============================================
-- Test 7: Crt_GetRequiredInspections scoping
--   LA: CRT, Good, at DC1-M05      -> in scope at DC1-M05 and DC1 (descendant)
--   LB: non-CRT, Good, at DC1-M06  -> excluded
--   LC: CRT flag forced, Closed    -> excluded
--   LD: CRT, Good, at MA1-...-AOUT -> excluded from DC1, visible at its own cell
-- =============================================
DECLARE @LC BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LC');
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @LC;  -- closed LOT with a stale CRT flag
DECLARE @LD BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LD');
DECLARE @RD TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RD EXEC Lots.Lot_SetCrt @LotId = @LD, @AppUserId = 1;

DECLARE @LocM05 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
CREATE TABLE #Q1 (LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), PieceCount INT, SampleCount INT, LastSampledAt DATETIME2(3), LastResultCode NVARCHAR(20));
INSERT INTO #Q1 EXEC Quality.Crt_GetRequiredInspections @LocationId = @LocM05;
DECLARE @C1 INT = (SELECT COUNT(*) FROM #Q1 WHERE LotName LIKE N'P9T-CRT-%');
EXEC test.Assert_RowCount @TestName = N'[CRT200] at DC1-M05: only LA in scope', @ExpectedCount = 1, @ActualCount = @C1;
DECLARE @N1 NVARCHAR(50) = (SELECT LotName FROM #Q1 WHERE LotName LIKE N'P9T-CRT-%');
EXEC test.Assert_IsEqual @TestName = N'[CRT200] at DC1-M05: the row is LA', @Expected = N'P9T-CRT-LA', @Actual = @N1;
DECLARE @SC1 NVARCHAR(10) = (SELECT CAST(SampleCount AS NVARCHAR(10)) FROM #Q1 WHERE LotName = N'P9T-CRT-LA');
EXEC test.Assert_IsEqual @TestName = N'[CRT200] LA SampleCount 0 before inspection', @Expected = N'0', @Actual = @SC1;
DECLARE @LR1 NVARCHAR(20) = (SELECT LastResultCode FROM #Q1 WHERE LotName = N'P9T-CRT-LA');
EXEC test.Assert_IsNull @TestName = N'[CRT200] LA LastResultCode NULL before inspection', @Value = @LR1;
DROP TABLE #Q1;

-- area-level query walks descendants: DC1 (area) still finds LA at DC1-M05
DECLARE @LocDC1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1');
CREATE TABLE #Q2 (LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), PieceCount INT, SampleCount INT, LastSampledAt DATETIME2(3), LastResultCode NVARCHAR(20));
INSERT INTO #Q2 EXEC Quality.Crt_GetRequiredInspections @LocationId = @LocDC1;
DECLARE @C2 INT = (SELECT COUNT(*) FROM #Q2 WHERE LotName LIKE N'P9T-CRT-%');
EXEC test.Assert_RowCount @TestName = N'[CRT200] at DC1 area: LA via descendant walk; LB/LC/LD excluded', @ExpectedCount = 1, @ActualCount = @C2;
DECLARE @N2 NVARCHAR(50) = (SELECT LotName FROM #Q2 WHERE LotName LIKE N'P9T-CRT-%');
EXEC test.Assert_IsEqual @TestName = N'[CRT200] area-scoped row is LA (Closed LC excluded)', @Expected = N'P9T-CRT-LA', @Actual = @N2;
DROP TABLE #Q2;

-- LD is visible at its own cell
DECLARE @LocAsm BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
CREATE TABLE #Q3 (LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), PieceCount INT, SampleCount INT, LastSampledAt DATETIME2(3), LastResultCode NVARCHAR(20));
INSERT INTO #Q3 EXEC Quality.Crt_GetRequiredInspections @LocationId = @LocAsm;
DECLARE @C3 INT = (SELECT COUNT(*) FROM #Q3 WHERE LotName LIKE N'P9T-CRT-%');
EXEC test.Assert_RowCount @TestName = N'[CRT200] LD visible at its own cell', @ExpectedCount = 1, @ActualCount = @C3;
DROP TABLE #Q3;
GO

-- =============================================
-- Test 8: sample tallies flow into the 200% read
-- =============================================
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LA');
DECLARE @V1 BIGINT = (SELECT v.Id FROM Quality.QualitySpecVersion v INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId WHERE s.Name = N'P9-QC-SPEC' AND v.VersionNumber = 1);
DECLARE @A1 BIGINT = (SELECT Id FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @V1 AND AttributeName = N'Diameter');
DECLARE @J NVARCHAR(MAX) = N'[{"qualitySpecAttributeId":' + CAST(@A1 AS NVARCHAR(20)) + N',"measuredValue":"15"}]';
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Quality.QualitySample_Record @LotId = @LA, @QualitySpecVersionId = @V1, @ResultsJson = @J, @AppUserId = 1;

DECLARE @LocM05 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
CREATE TABLE #Q (LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), PieceCount INT, SampleCount INT, LastSampledAt DATETIME2(3), LastResultCode NVARCHAR(20));
INSERT INTO #Q EXEC Quality.Crt_GetRequiredInspections @LocationId = @LocM05;
DECLARE @SC NVARCHAR(10) = (SELECT CAST(SampleCount AS NVARCHAR(10)) FROM #Q WHERE LotName = N'P9T-CRT-LA');
EXEC test.Assert_IsEqual @TestName = N'[CRT200] SampleCount 1 after inspection', @Expected = N'1', @Actual = @SC;
DECLARE @LR NVARCHAR(20) = (SELECT LastResultCode FROM #Q WHERE LotName = N'P9T-CRT-LA');
EXEC test.Assert_IsEqual @TestName = N'[CRT200] LastResultCode = Pass', @Expected = N'Pass', @Actual = @LR;
DECLARE @LS NVARCHAR(40) = (SELECT CONVERT(NVARCHAR(40), LastSampledAt, 126) FROM #Q WHERE LotName = N'P9T-CRT-LA');
EXEC test.Assert_IsNotNull @TestName = N'[CRT200] LastSampledAt populated (ET)', @Value = @LS;
DECLARE @PN NVARCHAR(50) = (SELECT ItemPartNumber FROM #Q WHERE LotName = N'P9T-CRT-LA');
EXEC test.Assert_IsEqual @TestName = N'[CRT200] ItemPartNumber joined', @Expected = N'P9-QC-TEST', @Actual = @PN;
DROP TABLE #Q;
GO

-- =============================================
-- Test 9: ClearCrt happy + audit + clear-on-clear rejected
-- =============================================
DECLARE @LA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'P9T-CRT-LA');
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Lots.Lot_ClearCrt @LotId = @LA, @AppUserId = 1;
DECLARE @S NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[CRT] ClearCrt Status 1', @Expected = N'1', @Actual = @S;
DECLARE @Flag NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @LA);
EXEC test.Assert_IsEqual @TestName = N'[CRT] Lot.CrtActive flipped back to 0', @Expected = N'0', @Actual = @Flag;
DECLARE @Aud INT = (SELECT COUNT(*) FROM Lots.LotEventLog el INNER JOIN Audit.LogEventType et ON et.Id = el.LogEventTypeId WHERE et.Code = N'CrtCleared' AND el.LotId = @LA);
EXEC test.Assert_RowCount @TestName = N'[CRT] CrtCleared audit row in LotEventLog', @ExpectedCount = 1, @ActualCount = @Aud;

DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R2 EXEC Lots.Lot_ClearCrt @LotId = @LA, @AppUserId = 1;
DECLARE @S2 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R2);
DECLARE @M2 NVARCHAR(500) = (SELECT Message FROM @R2);
EXEC test.Assert_IsEqual @TestName = N'[CRT] clear-on-clear rejected', @Expected = N'0', @Actual = @S2;
EXEC test.Assert_Contains @TestName = N'[CRT] clear-on-clear rejection says not active', @HaystackStr = @M2, @NeedleStr = N'not active';

-- cleared LOT drops out of the 200% read
DECLARE @LocM05 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
CREATE TABLE #Q (LotId BIGINT, LotName NVARCHAR(50), ItemPartNumber NVARCHAR(50), PieceCount INT, SampleCount INT, LastSampledAt DATETIME2(3), LastResultCode NVARCHAR(20));
INSERT INTO #Q EXEC Quality.Crt_GetRequiredInspections @LocationId = @LocM05;
DECLARE @C INT = (SELECT COUNT(*) FROM #Q WHERE LotName LIKE N'P9T-CRT-%');
EXEC test.Assert_RowCount @TestName = N'[CRT200] cleared LOT no longer required', @ExpectedCount = 0, @ActualCount = @C;
DROP TABLE #Q;
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
