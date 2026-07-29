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
DECLARE @L5 BIGINT;
CREATE TABLE #C5 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C5 EXEC Lots.Lot_Create @ItemId = 1, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Src, @PieceCount = 20, @AppUserId = 1;
SELECT @L5 = NewId FROM #C5; DROP TABLE #C5;
DECLARE @S5 BIT, @M5 NVARCHAR(500);
CREATE TABLE #T5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5 EXEC Workorder.TrimOut_Record @ParentLotId = @L5, @OperationTemplateId = @OtId, @ShotCount = 19, @ScrapCount = 2, @SourceLocationId = @Src, @AppUserId = 1;  -- 21 > 20
SELECT @S5 = Status, @M5 = Message FROM #T5; DROP TABLE #T5;
DECLARE @S5Str NVARCHAR(10) = CAST(@S5 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] combined shot + scrap above LOT piece count rejected', @Expected = N'0', @Actual = @S5Str;
EXEC test.Assert_Contains @TestName = N'[TrimOutVal] combined cap rejected for the piece-count reason', @HaystackStr = @M5, @NeedleStr = N'exceeds the LOT piece count';
-- boundary: 18 + 2 = 20 passes
DECLARE @S5b BIT;
CREATE TABLE #T5b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #T5b EXEC Workorder.TrimOut_Record @ParentLotId = @L5, @OperationTemplateId = @OtId, @ShotCount = 18, @ScrapCount = 2, @SourceLocationId = @Src, @AppUserId = 1;
SELECT @S5b = Status FROM #T5b; DROP TABLE #T5b;
DECLARE @S5bStr NVARCHAR(10) = CAST(@S5b AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[TrimOutVal] combined sum equal to piece count passes (boundary)', @Expected = N'1', @Actual = @S5bStr;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%';
GO

EXEC test.EndTestFile;
GO
