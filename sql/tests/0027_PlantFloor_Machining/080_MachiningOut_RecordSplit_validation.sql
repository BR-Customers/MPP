-- =============================================
-- File:         0027_PlantFloor_Machining/080_MachiningOut_RecordSplit_validation.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-19
-- Description:  Rejection tests for Workorder.MachiningOut_RecordSplit:
--                 - SUM(children) != parent piece count rejects
--                 - missing/invalid destination rejects
--                 - blocked (Hold) parent rejects (B2)
--               After each rejection the parent stays open + intact (no children,
--               no closing ProductionEvent).
--               Fixture: P5-MACH-TEST; parent at MA1-FPRPY-MOUT; valid dest
--               MA1-FPRPY-AFIN.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/080_MachiningOut_RecordSplit_validation.sql';
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P5-MACH-TEST', N'Phase5 test machined part', 1, @Now, 1);
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @MachItem AND LocationId = @Parent AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@MachItem, @Parent, 0, @Now);
GO

-- ---- LOT cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE ac FROM Lots.LotAttributeChange ac INNER JOIN Lots.Lot l ON l.Id = ac.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-SPL%';
GO

-- =============================================
-- Test 1a: over-extraction (SUM > parent) rejects; parent stays open + intact
-- =============================================
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @Dest BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');

DECLARE @L1 BIGINT;
CREATE TABLE #C1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C1 EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Parent, @PieceCount = 48, @AppUserId = 1, @LotName = N'P5T-SPL-SUM';
SELECT @L1 = NewId FROM #C1; DROP TABLE #C1;

DECLARE @D NVARCHAR(20) = CAST(@Dest AS NVARCHAR(20));
-- 30 + 24 = 54 > 48 (over-extraction)
DECLARE @Json1 NVARCHAR(MAX) = N'[{"pieceCount":30,"destinationLocationId":' + @D + N'},{"pieceCount":24,"destinationLocationId":' + @D + N'}]';
DECLARE @S1 BIT, @M1 NVARCHAR(500);
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R1 EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @L1, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json1, @AppUserId = 1;
SELECT TOP 1 @S1 = Status, @M1 = Message FROM #R1;
DROP TABLE #R1;
DECLARE @S1cond BIT = CASE WHEN @S1 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachSplitVal] over-extraction rejected', @Condition = @S1cond;
EXEC test.Assert_Contains @TestName = N'[MachSplitVal] over-extraction message', @HaystackStr = @M1, @NeedleStr = N'exceeds the parent';

-- parent untouched: still Good, no children, no closing PE
DECLARE @P1Status NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @L1);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] parent still Good after over-extraction reject', @Expected = N'Good', @Actual = @P1Status;
DECLARE @P1Children NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ParentLotId = @L1);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] no children after over-extraction reject', @Expected = N'0', @Actual = @P1Children;
DECLARE @P1Pe NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent WHERE LotId = @L1);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] no ProductionEvent after over-extraction reject', @Expected = N'0', @Actual = @P1Pe;
GO

-- =============================================
-- Test 1b: partial extraction (SUM < parent) is ACCEPTED; parent stays open w/ remainder
-- =============================================
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @Dest BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');

DECLARE @L1b BIGINT;
CREATE TABLE #C1b (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C1b EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Parent, @PieceCount = 48, @AppUserId = 1, @LotName = N'P5T-SPL-PART';
SELECT @L1b = NewId FROM #C1b; DROP TABLE #C1b;

DECLARE @Db NVARCHAR(20) = CAST(@Dest AS NVARCHAR(20));
-- 24 + 20 = 44 < 48 (partial extraction -> parent stays open with 4 remaining)
DECLARE @Json1b NVARCHAR(MAX) = N'[{"pieceCount":24,"destinationLocationId":' + @Db + N'},{"pieceCount":20,"destinationLocationId":' + @Db + N'}]';
DECLARE @S1b BIT;
CREATE TABLE #R1b (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R1b EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @L1b, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json1b, @AppUserId = 1;
SELECT TOP 1 @S1b = Status FROM #R1b;
DROP TABLE #R1b;
DECLARE @S1bStr NVARCHAR(10) = CAST(@S1b AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] partial extraction accepted (Status 1)', @Expected = N'1', @Actual = @S1bStr;

-- parent stays open (Good) with the 4-pc remainder + two children minted
DECLARE @P1bStatus NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @L1b);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] parent stays Good after partial extraction', @Expected = N'Good', @Actual = @P1bStatus;
DECLARE @P1bPc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @L1b);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] parent remainder is 4 after partial extraction', @Expected = N'4', @Actual = @P1bPc;
DECLARE @P1bChildren NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ParentLotId = @L1b);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] two children after partial extraction', @Expected = N'2', @Actual = @P1bChildren;
GO

-- =============================================
-- Test 2: invalid destination rejects
-- =============================================
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @Dest BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');

DECLARE @L2 BIGINT;
CREATE TABLE #C2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C2 EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Parent, @PieceCount = 40, @AppUserId = 1, @LotName = N'P5T-SPL-DEST';
SELECT @L2 = NewId FROM #C2; DROP TABLE #C2;

DECLARE @D NVARCHAR(20) = CAST(@Dest AS NVARCHAR(20));
-- one valid (20) + one bogus destination id 999999999 (20) = 40
DECLARE @Json2 NVARCHAR(MAX) = N'[{"pieceCount":20,"destinationLocationId":' + @D + N'},{"pieceCount":20,"destinationLocationId":999999999}]';
DECLARE @S2 BIT, @M2 NVARCHAR(500);
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R2 EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @L2, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json2, @AppUserId = 1;
SELECT TOP 1 @S2 = Status, @M2 = Message FROM #R2;
DROP TABLE #R2;
DECLARE @S2cond BIT = CASE WHEN @S2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachSplitVal] invalid destination rejected', @Condition = @S2cond;

DECLARE @P2Status NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @L2);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] parent still Good after dest reject', @Expected = N'Good', @Actual = @P2Status;
DECLARE @P2Children NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Lot WHERE ParentLotId = @L2);
EXEC test.Assert_IsEqual @TestName = N'[MachSplitVal] no children after dest reject', @Expected = N'0', @Actual = @P2Children;
GO

-- =============================================
-- Test 3: blocked (Hold) parent rejects (B2)
-- =============================================
DECLARE @Parent BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT');
DECLARE @Dest BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN');
DECLARE @MachItem BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P5-MACH-TEST');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OtId BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');
DECLARE @HoldId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');

DECLARE @L3 BIGINT;
CREATE TABLE #C3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #C3 EXEC Lots.Lot_Create @ItemId = @MachItem, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @Parent, @PieceCount = 40, @AppUserId = 1, @LotName = N'P5T-SPL-HOLD';
SELECT @L3 = NewId FROM #C3; DROP TABLE #C3;
UPDATE Lots.Lot SET LotStatusId = @HoldId WHERE Id = @L3;

DECLARE @D NVARCHAR(20) = CAST(@Dest AS NVARCHAR(20));
DECLARE @Json3 NVARCHAR(MAX) = N'[{"pieceCount":40,"destinationLocationId":' + @D + N'}]';
DECLARE @S3 BIT, @M3 NVARCHAR(500);
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), ProductionEventId BIGINT, ChildLotId BIGINT, ChildLotName NVARCHAR(50), DestinationLocationId BIGINT, PieceCount INT);
INSERT INTO #R3 EXEC Workorder.MachiningOut_RecordSplit @ParentLotId = @L3, @OperationTemplateId = @OtId, @SplitChildrenJson = @Json3, @AppUserId = 1;
SELECT TOP 1 @S3 = Status, @M3 = Message FROM #R3;
DROP TABLE #R3;
DECLARE @S3cond BIT = CASE WHEN @S3 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[MachSplitVal] blocked (Hold) parent rejected', @Condition = @S3cond;
EXEC test.Assert_Contains @TestName = N'[MachSplitVal] blocked message cites Hold', @HaystackStr = @M3, @NeedleStr = N'Hold';
GO

-- ---- cleanup ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE ac FROM Lots.LotAttributeChange ac INNER JOIN Lots.Lot l ON l.Id = ac.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE eg FROM Lots.LotEventLog eg INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'P5T-SPL%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'P5T-SPL%';
GO

EXEC test.EndTestFile;
GO
