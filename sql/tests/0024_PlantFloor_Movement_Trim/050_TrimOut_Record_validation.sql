-- =============================================
-- File:         0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql
-- Author:       Blue Ridge Automation
-- Rewritten:    2026-07-23 - Trim-Storage model (v2). Trim OUT no longer takes a
--               destination line; it deposits into the shop's Trim Storage, resolved
--               internally. The old "missing destination" / "non-eligible destination"
--               rejections are gone. Rejection tests now cover:
--                 - Trim Storage not configured for the shop (source under a non-trim area)
--                 - blocked (Hold) LOT rejects (B2)
--                 - counter regression (< prior cumulative) rejects (D1)
--                 - double checkout rejects (source-location guard) - after OUT the LOT
--                   sits in Trim Storage, so a 2nd OUT from the trim press rejects
--                 - combined shot + scrap above the LOT piece count rejects; boundary passes
--               Fixture item = 1 (5G0), origin Received, source = TRIM1-P01 (Trim Storage
--               = TRIM1-STORE resolved internally).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0024_PlantFloor_Movement_Trim/050_TrimOut_Record_validation.sql';
GO

-- ---- fixture cleanup ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
-- item 1 eligible under TRIM1 so Lot_Create can stage at the trim press
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = 1 AND LocationId = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1') AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
    VALUES (1, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'), 0, SYSUTCDATETIME());
GO

-- =============================================
-- Test 1: Trim Storage not configured for the shop -> reject
--   Source DC1-M05 sits under the Die Cast area, which has no Trim Storage child.
-- =============================================
DECLARE @NoStore BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = 1 AND LocationId = @NoStore AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (1, @NoStore, 0, SYSUTCDATETIME());
DECLARE @L1 BIGINT;
CREATE TABLE #C1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C1 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @NoStore, @PieceCount = 20, @AppUserId = 1;
SELECT @L1 = NewId FROM #C1; DROP TABLE #C1;
DECLARE @S1 BIT, @M1 NVARCHAR(500);
CREATE TABLE #T1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T1 EXEC Workorder.TrimOut_Record @ParentLotId = @L1, @OperationTemplateId = @OtId, @ShotCount = 20, @SourceLocationId = @NoStore, @AppUserId = 1;
SELECT @S1 = Status, @M1 = Message FROM #T1; DROP TABLE #T1;
DECLARE @S1c BIT = CASE WHEN @S1 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[TrimOutVal] Trim Storage not configured rejected (Status 0)', @Condition = @S1c;
EXEC test.Assert_Contains @TestName = N'[TrimOutVal] not-configured message', @HaystackStr = @M1, @NeedleStr = N'Trim Storage is not configured';
GO

-- =============================================
-- Test 2: blocked (Hold) LOT rejects (B2)
-- =============================================
DECLARE @Src BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L2 BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Src, @PieceCount = 20, @AppUserId = 1;
SELECT @L2 = NewId FROM #C2; DROP TABLE #C2;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold') WHERE Id = @L2;
DECLARE @S2 BIT;
CREATE TABLE #T2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T2 EXEC Workorder.TrimOut_Record @ParentLotId = @L2, @OperationTemplateId = @OtId, @ShotCount = 20, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @S2 = Status FROM #T2; DROP TABLE #T2;
DECLARE @S2Str NVARCHAR(10) = CAST(@S2 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] blocked (Hold) LOT rejected', @Expected = N'0', @Actual = @S2Str;
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good') WHERE Id = @L2;
GO

-- =============================================
-- Test 3: counter regression (< prior cumulative) rejects (D1)
-- =============================================
DECLARE @Src BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @DcOt BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'DieCastShot');
DECLARE @L3 BIGINT;
CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Src, @PieceCount = 20, @AppUserId = 1;
SELECT @L3 = NewId FROM #C3; DROP TABLE #C3;
CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #P EXEC Workorder.ProductionEvent_Record @LotId = @L3, @OperationTemplateId = @DcOt, @ShotCount = 10, @AppUserId = 1;
DROP TABLE #P;
DECLARE @S3 BIT;
CREATE TABLE #T3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T3 EXEC Workorder.TrimOut_Record @ParentLotId = @L3, @OperationTemplateId = @OtId, @ShotCount = 3, @SourceLocationId = @Src, @AppUserId = 1;  -- 3 < prior 10
SELECT @S3 = Status FROM #T3; DROP TABLE #T3;
DECLARE @S3Str NVARCHAR(10) = CAST(@S3 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] counter regression rejected (D1)', @Expected = N'0', @Actual = @S3Str;
GO

-- =============================================
-- Test 4: double checkout rejects (source-location guard). First OUT deposits into
--   Trim Storage; the LOT then sits in TRIM1-STORE (not under TRIM1-P01), so a 2nd OUT
--   from the same trim press rejects.
-- =============================================
DECLARE @Src BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L4 BIGINT;
CREATE TABLE #C4 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C4 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Src, @PieceCount = 20, @AppUserId = 1;
SELECT @L4 = NewId FROM #C4; DROP TABLE #C4;
DECLARE @S4a BIT, @S4b BIT, @M4b NVARCHAR(500);
CREATE TABLE #T4a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T4a EXEC Workorder.TrimOut_Record @ParentLotId = @L4, @OperationTemplateId = @OtId, @ShotCount = 20, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @S4a = Status FROM #T4a; DROP TABLE #T4a;
DECLARE @S4aStr NVARCHAR(10) = CAST(@S4a AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] first checkout succeeds (control)', @Expected = N'1', @Actual = @S4aStr;
CREATE TABLE #T4b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T4b EXEC Workorder.TrimOut_Record @ParentLotId = @L4, @OperationTemplateId = @OtId, @ShotCount = 20, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @S4b = Status, @M4b = Message FROM #T4b; DROP TABLE #T4b;
DECLARE @S4bStr NVARCHAR(10) = CAST(@S4b AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] double checkout rejected', @Expected = N'0', @Actual = @S4bStr;
EXEC test.Assert_Contains @TestName = N'[TrimOutVal] double checkout rejected for the location reason', @HaystackStr = @M4b, @NeedleStr = N'not at this Trim station';
GO

-- =============================================
-- Test 5: combined shot + scrap above the LOT piece count rejects; boundary passes
-- =============================================
DECLARE @Src BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
-- @ScrapCount param retired v1.3 (FAT #2); equivalent single scrap line, same total qty=2
DECLARE @D5 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Json5 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D5 AS NVARCHAR(20)) + N',"quantity":2}]';
DECLARE @L5 BIGINT;
CREATE TABLE #C5 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C5 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Src, @PieceCount = 20, @AppUserId = 1;
SELECT @L5 = NewId FROM #C5; DROP TABLE #C5;
DECLARE @S5 BIT, @M5 NVARCHAR(500);
CREATE TABLE #T5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5 EXEC Workorder.TrimOut_Record @ParentLotId = @L5, @OperationTemplateId = @OtId, @ShotCount = 19, @ScrapLinesJson = @Json5, @SourceLocationId = @Src, @AppUserId = 1;  -- 21 > 20
SELECT @S5 = Status, @M5 = Message FROM #T5; DROP TABLE #T5;
DECLARE @S5Str NVARCHAR(10) = CAST(@S5 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] combined shot + scrap above LOT piece count rejected', @Expected = N'0', @Actual = @S5Str;
EXEC test.Assert_Contains @TestName = N'[TrimOutVal] combined cap rejected for the piece-count reason', @HaystackStr = @M5, @NeedleStr = N'exceeds the LOT piece count';
-- boundary: 18 + 2 = 20 passes
DECLARE @S5b BIT;
CREATE TABLE #T5b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5b EXEC Workorder.TrimOut_Record @ParentLotId = @L5, @OperationTemplateId = @OtId, @ShotCount = 18, @ScrapLinesJson = @Json5, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @S5b = Status FROM #T5b; DROP TABLE #T5b;
DECLARE @S5bStr NVARCHAR(10) = CAST(@S5b AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] combined sum equal to piece count passes (boundary)', @Expected = N'1', @Actual = @S5bStr;
GO

-- =============================================
-- Test 6: same-shop re-entry via AREA-level source (FAT #22, 2026-08-04).
--   The real Trim terminal records with @SourceLocationId = the trim AREA (its
--   zoneLocationId), NOT a press. Trim Storage (TRIM1-STORE) is a CHILD of that
--   area, so the source-ancestor guard (3b) still passes after the first OUT --
--   the LOT sits in the store, whose ancestor set includes TRIM1 = the source.
--   The explicit already-in-Trim-Storage guard must reject the 2nd OUT.
-- =============================================
DECLARE @Area BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L6 BIGINT;
CREATE TABLE #C6 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C6 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Press, @PieceCount = 20, @AppUserId = 1;
SELECT @L6 = NewId FROM #C6; DROP TABLE #C6;
DECLARE @S6a BIT, @S6b BIT, @M6b NVARCHAR(500);
-- First OUT via AREA-level source succeeds (LOT is at a press under TRIM1).
CREATE TABLE #T6a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T6a EXEC Workorder.TrimOut_Record @ParentLotId = @L6, @OperationTemplateId = @OtId, @ShotCount = 20, @SourceLocationId = @Area, @AppUserId = 1;
SELECT @S6a = Status FROM #T6a; DROP TABLE #T6a;
DECLARE @S6aStr NVARCHAR(10) = CAST(@S6a AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] first OUT via area source succeeds (control)', @Expected = N'1', @Actual = @S6aStr;
-- Second OUT via the same AREA-level source must reject (LOT now in Trim Storage).
CREATE TABLE #T6b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T6b EXEC Workorder.TrimOut_Record @ParentLotId = @L6, @OperationTemplateId = @OtId, @ShotCount = 20, @SourceLocationId = @Area, @AppUserId = 1;
SELECT @S6b = Status, @M6b = Message FROM #T6b; DROP TABLE #T6b;
DECLARE @S6bStr NVARCHAR(10) = CAST(@S6b AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] area-source re-entry rejected (FAT #22)', @Expected = N'0', @Actual = @S6bStr;
EXEC test.Assert_Contains @TestName = N'[TrimOutVal] re-entry rejected for already-trimmed reason', @HaystackStr = @M6b, @NeedleStr = N'already completed Trim OUT';
GO

-- =============================================
-- Test 7: multi-line scrap -> N RejectEvent rows + PieceCount decremented by Sigma-qty (once)
-- =============================================
DECLARE @Area7 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press7 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv7 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot7 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
-- two DISTINCT active defect codes; resolved dynamically (proc validates active-ness, not category)
DECLARE @D1 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @D2 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL AND Id <> @D1 ORDER BY Id);
DECLARE @L7 BIGINT;
CREATE TABLE #C7 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C7 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv7, @CurrentLocationId = @Press7, @PieceCount = 20, @AppUserId = 1;
SELECT @L7 = NewId FROM #C7; DROP TABLE #C7;
DECLARE @RejBefore7 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L7);
DECLARE @Json7 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D1 AS NVARCHAR(20)) + N',"quantity":3},{"defectCodeId":' + CAST(@D2 AS NVARCHAR(20)) + N',"quantity":2}]';
DECLARE @S7 BIT;
CREATE TABLE #T7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T7 EXEC Workorder.TrimOut_Record @ParentLotId = @L7, @OperationTemplateId = @Ot7, @ShotCount = 15, @ScrapLinesJson = @Json7, @SourceLocationId = @Area7, @AppUserId = 1;
SELECT @S7 = Status FROM #T7; DROP TABLE #T7;
DECLARE @S7Str NVARCHAR(10) = CAST(@S7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] multi-line scrap succeeds', @Expected = N'1', @Actual = @S7Str;
DECLARE @RejNew7 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L7) - @RejBefore7;
DECLARE @RejNew7Str NVARCHAR(10) = CAST(@RejNew7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] two RejectEvent rows written', @Expected = N'2', @Actual = @RejNew7Str;
DECLARE @PC7 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @L7);
DECLARE @PC7Str NVARCHAR(10) = CAST(@PC7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] PieceCount decremented by Sigma-qty once (20-5=15)', @Expected = N'15', @Actual = @PC7Str;
DECLARE @PENull7 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L7 AND ProductionEventId IS NOT NULL);
DECLARE @PENull7Str NVARCHAR(10) = CAST(@PENull7 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] reject rows have NULL ProductionEventId (by design)', @Expected = N'0', @Actual = @PENull7Str;
GO

-- =============================================
-- Test 8: invalid/deprecated defectCodeId in a line -> Status 0, nothing written
-- =============================================
DECLARE @Area8 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press8 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv8 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot8 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L8 BIGINT;
CREATE TABLE #C8 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C8 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv8, @CurrentLocationId = @Press8, @PieceCount = 20, @AppUserId = 1;
SELECT @L8 = NewId FROM #C8; DROP TABLE #C8;
DECLARE @BadJson8 NVARCHAR(MAX) = N'[{"defectCodeId":99999999,"quantity":2}]';
DECLARE @S8 BIT, @M8 NVARCHAR(500);
CREATE TABLE #T8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T8 EXEC Workorder.TrimOut_Record @ParentLotId = @L8, @OperationTemplateId = @Ot8, @ShotCount = 18, @ScrapLinesJson = @BadJson8, @SourceLocationId = @Area8, @AppUserId = 1;
SELECT @S8 = Status, @M8 = Message FROM #T8; DROP TABLE #T8;
DECLARE @S8Str NVARCHAR(10) = CAST(@S8 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] invalid defect code rejected (Status 0)', @Expected = N'0', @Actual = @S8Str;
EXEC test.Assert_Contains @TestName = N'[TrimOutScrap] invalid-defect message', @HaystackStr = @M8, @NeedleStr = N'invalid or deprecated';
DECLARE @PC8 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @L8);
DECLARE @PC8Str NVARCHAR(10) = CAST(@PC8 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] no decrement on rejected scrap', @Expected = N'20', @Actual = @PC8Str;
GO

-- =============================================
-- Test 9: shots + Sigma-scrap > PieceCount -> reject; boundary (= PieceCount) passes
-- =============================================
DECLARE @Area9 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press9 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv9 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot9 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @D9 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @L9 BIGINT;
CREATE TABLE #C9 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C9 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv9, @CurrentLocationId = @Press9, @PieceCount = 20, @AppUserId = 1;
SELECT @L9 = NewId FROM #C9; DROP TABLE #C9;
-- shots 19 + scrap 2 = 21 > 20 -> reject
DECLARE @OverJson9 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D9 AS NVARCHAR(20)) + N',"quantity":2}]';
DECLARE @S9a BIT;
CREATE TABLE #T9a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T9a EXEC Workorder.TrimOut_Record @ParentLotId = @L9, @OperationTemplateId = @Ot9, @ShotCount = 19, @ScrapLinesJson = @OverJson9, @SourceLocationId = @Area9, @AppUserId = 1;
SELECT @S9a = Status FROM #T9a; DROP TABLE #T9a;
DECLARE @S9aStr NVARCHAR(10) = CAST(@S9a AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] shots+scrap over piece count rejected', @Expected = N'0', @Actual = @S9aStr;
-- boundary: shots 18 + scrap 2 = 20 = PieceCount -> passes
DECLARE @S9b BIT;
CREATE TABLE #T9b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T9b EXEC Workorder.TrimOut_Record @ParentLotId = @L9, @OperationTemplateId = @Ot9, @ShotCount = 18, @ScrapLinesJson = @OverJson9, @SourceLocationId = @Area9, @AppUserId = 1;
SELECT @S9b = Status FROM #T9b; DROP TABLE #T9b;
DECLARE @S9bStr NVARCHAR(10) = CAST(@S9b AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] shots+scrap = piece count boundary passes', @Expected = N'1', @Actual = @S9bStr;
GO

-- =============================================
-- Test 10: empty/absent @ScrapLinesJson -> success, 0 rejects, no decrement (scrap-free Trim OUT)
-- =============================================
DECLARE @Area10 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press10 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv10 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot10 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @L10 BIGINT;
CREATE TABLE #C10 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C10 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv10, @CurrentLocationId = @Press10, @PieceCount = 20, @AppUserId = 1;
SELECT @L10 = NewId FROM #C10; DROP TABLE #C10;
DECLARE @RejBefore10 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L10);
DECLARE @S10 BIT;
CREATE TABLE #T10 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T10 EXEC Workorder.TrimOut_Record @ParentLotId = @L10, @OperationTemplateId = @Ot10, @ShotCount = 20, @ScrapLinesJson = NULL, @SourceLocationId = @Area10, @AppUserId = 1;
SELECT @S10 = Status FROM #T10; DROP TABLE #T10;
DECLARE @S10Str NVARCHAR(10) = CAST(@S10 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] scrap-free Trim OUT succeeds', @Expected = N'1', @Actual = @S10Str;
DECLARE @RejNew10 INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @L10) - @RejBefore10;
DECLARE @RejNew10Str NVARCHAR(10) = CAST(@RejNew10 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] scrap-free writes zero rejects', @Expected = N'0', @Actual = @RejNew10Str;
DECLARE @PC10 INT = (SELECT PieceCount FROM Lots.Lot WHERE Id = @L10);
DECLARE @PC10Str NVARCHAR(10) = CAST(@PC10 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] scrap-free leaves PieceCount unchanged', @Expected = N'20', @Actual = @PC10Str;
GO

-- =============================================
-- Test 11: non-positive quantity in a line -> reject
-- =============================================
DECLARE @Area11 BIGINT  = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Press11 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-P01');
DECLARE @Rcv11 BIGINT   = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Ot11 BIGINT    = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @D11 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @L11 BIGINT;
CREATE TABLE #C11 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C11 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @Rcv11, @CurrentLocationId = @Press11, @PieceCount = 20, @AppUserId = 1;
SELECT @L11 = NewId FROM #C11; DROP TABLE #C11;
DECLARE @ZeroJson11 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@D11 AS NVARCHAR(20)) + N',"quantity":0}]';
DECLARE @S11 BIT, @M11 NVARCHAR(500);
CREATE TABLE #T11 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T11 EXEC Workorder.TrimOut_Record @ParentLotId = @L11, @OperationTemplateId = @Ot11, @ShotCount = 20, @ScrapLinesJson = @ZeroJson11, @SourceLocationId = @Area11, @AppUserId = 1;
SELECT @S11 = Status, @M11 = Message FROM #T11; DROP TABLE #T11;
DECLARE @S11Str NVARCHAR(10) = CAST(@S11 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutScrap] non-positive scrap quantity rejected', @Expected = N'0', @Actual = @S11Str;
EXEC test.Assert_Contains @TestName = N'[TrimOutScrap] positive-quantity message', @HaystackStr = @M11, @NeedleStr = N'quantity must be positive';
GO

-- ---- cleanup ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
