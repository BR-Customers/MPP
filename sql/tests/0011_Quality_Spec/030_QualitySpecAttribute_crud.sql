-- =============================================
-- File:         0011_Quality_Spec/030_QualitySpecAttribute_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Quality.QualitySpecAttribute procs:
--     Quality.QualitySpecAttribute_Add
--     Quality.QualitySpecAttribute_Update
--     Quality.QualitySpecAttribute_Remove
--     Quality.QualitySpecAttribute_MoveUp
--     Quality.QualitySpecAttribute_MoveDown
--     Quality.QualitySpecAttribute_ListByVersion
--
--   Covers: add happy + duplicate name + published reject;
--   update happy + published reject; remove + SortOrder compact;
--   move up/down; list ordering.
--
--   Pre-conditions:
--     - Migration 0001-0008 applied
--     - AppUser Id=1 exists
-- =============================================

EXEC test.BeginTestFile @FileName = N'0011_Quality_Spec/030_QualitySpecAttribute_crud.sql';
GO

-- =============================================
-- Setup: Create spec with draft version
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SpecId BIGINT,
        @VerId  BIGINT;

CREATE TABLE #QR1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR1 EXEC Quality.QualitySpec_Create
    @Name        = N'Test Spec For Attributes',
    @Description = N'Parent spec for attribute tests',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #QR1;
DROP TABLE #QR1;

CREATE TABLE #QR2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR2 EXEC Quality.QualitySpecVersion_Create
    @QualitySpecId = @SpecId,
    @AppUserId     = 1;
SELECT @S = Status, @M = Message, @VerId = NewId FROM #QR2;
DROP TABLE #QR2;
GO

-- =============================================
-- Test 1: QualitySpecAttribute_Add happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @VerId  BIGINT,
        @AttrId BIGINT;

SELECT @VerId = qsv.Id
FROM Quality.QualitySpecVersion qsv
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsv.VersionNumber = 1;

CREATE TABLE #QR3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR3 EXEC Quality.QualitySpecAttribute_Add
    @QualitySpecVersionId = @VerId,
    @AttributeName        = N'Dimension A',
    @DataType             = N'Numeric',
    @Uom                  = N'mm',
    @TargetValue          = 10.5,
    @LowerLimit           = 10.0,
    @UpperLimit           = 11.0,
    @IsRequired           = 1,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @AttrId = NewId FROM #QR3;
DROP TABLE #QR3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrAddHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @AttrIdStr NVARCHAR(20) = CAST(@AttrId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[AttrAddHappy] NewId is not NULL',
    @Value    = @AttrIdStr;

-- Verify SortOrder = 1
DECLARE @Sort INT;
SELECT @Sort = SortOrder FROM Quality.QualitySpecAttribute WHERE Id = @AttrId;
DECLARE @SortStr NVARCHAR(10) = CAST(@Sort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrAddHappy] SortOrder = 1',
    @Expected = N'1',
    @Actual   = @SortStr;
GO

-- =============================================
-- Test 2: Add second attribute (SortOrder = 2)
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @VerId  BIGINT,
        @AttrId BIGINT;

SELECT @VerId = qsv.Id
FROM Quality.QualitySpecVersion qsv
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsv.VersionNumber = 1;

CREATE TABLE #QR4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR4 EXEC Quality.QualitySpecAttribute_Add
    @QualitySpecVersionId = @VerId,
    @AttributeName        = N'Dimension B',
    @DataType             = N'Numeric',
    @Uom                  = N'mm',
    @IsRequired           = 1,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @AttrId = NewId FROM #QR4;
DROP TABLE #QR4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrAddSecond] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @Sort INT;
SELECT @Sort = SortOrder FROM Quality.QualitySpecAttribute WHERE Id = @AttrId;
DECLARE @SortStr NVARCHAR(10) = CAST(@Sort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrAddSecond] SortOrder = 2',
    @Expected = N'2',
    @Actual   = @SortStr;
GO

-- =============================================
-- Test 3: Add third attribute
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @VerId  BIGINT,
        @AttrId BIGINT;

SELECT @VerId = qsv.Id
FROM Quality.QualitySpecVersion qsv
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsv.VersionNumber = 1;

CREATE TABLE #QR5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR5 EXEC Quality.QualitySpecAttribute_Add
    @QualitySpecVersionId = @VerId,
    @AttributeName        = N'Surface Finish',
    @DataType             = N'Text',
    @IsRequired           = 0,
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @AttrId = NewId FROM #QR5;
DROP TABLE #QR5;
GO

-- =============================================
-- Test 4: Add rejects duplicate name
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @VerId  BIGINT,
        @AttrId BIGINT;

SELECT @VerId = qsv.Id
FROM Quality.QualitySpecVersion qsv
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsv.VersionNumber = 1;

CREATE TABLE #QR6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR6 EXEC Quality.QualitySpecAttribute_Add
    @QualitySpecVersionId = @VerId,
    @AttributeName        = N'Dimension A',
    @DataType             = N'Numeric',
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @AttrId = NewId FROM #QR6;
DROP TABLE #QR6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrAddDupe] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[AttrAddDupe] Message mentions exists',
    @HaystackStr = @M,
    @NeedleStr   = N'exists';
GO

-- =============================================
-- Test 5: QualitySpecAttribute_Update happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AttrId BIGINT;

SELECT @AttrId = qsa.Id
FROM Quality.QualitySpecAttribute qsa
JOIN Quality.QualitySpecVersion qsv ON qsa.QualitySpecVersionId = qsv.Id
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsa.AttributeName = N'Dimension A';

CREATE TABLE #QR7 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR7 EXEC Quality.QualitySpecAttribute_Update
    @Id            = @AttrId,
    @AttributeName = N'Dimension A',
    @DataType      = N'Numeric',
    @Uom           = N'in',
    @TargetValue   = 0.41,
    @LowerLimit    = 0.39,
    @UpperLimit    = 0.43,
    @IsRequired    = 1,
    @AppUserId     = 1;
SELECT @S = Status, @M = Message FROM #QR7;
DROP TABLE #QR7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrUpdateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify Uom changed
DECLARE @NewUom NVARCHAR(20);
SELECT @NewUom = Uom FROM Quality.QualitySpecAttribute WHERE Id = @AttrId;
EXEC test.Assert_IsEqual
    @TestName = N'[AttrUpdateHappy] Uom changed to in',
    @Expected = N'in',
    @Actual   = @NewUom;
GO

-- =============================================
-- Test 6: QualitySpecAttribute_MoveUp happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AttrId BIGINT;

-- Get Dimension B (SortOrder=2)
SELECT @AttrId = qsa.Id
FROM Quality.QualitySpecAttribute qsa
JOIN Quality.QualitySpecVersion qsv ON qsa.QualitySpecVersionId = qsv.Id
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsa.AttributeName = N'Dimension B';

CREATE TABLE #QR8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR8 EXEC Quality.QualitySpecAttribute_MoveUp
    @Id        = @AttrId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR8;
DROP TABLE #QR8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrMoveUp] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify Dimension B now has SortOrder = 1
DECLARE @NewSort INT;
SELECT @NewSort = SortOrder FROM Quality.QualitySpecAttribute WHERE Id = @AttrId;
DECLARE @NewSortStr NVARCHAR(10) = CAST(@NewSort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrMoveUp] Dimension B SortOrder = 1',
    @Expected = N'1',
    @Actual   = @NewSortStr;

-- Verify Dimension A now has SortOrder = 2
DECLARE @OtherId BIGINT, @OtherSort INT;
SELECT @OtherId = qsa.Id
FROM Quality.QualitySpecAttribute qsa
JOIN Quality.QualitySpecVersion qsv ON qsa.QualitySpecVersionId = qsv.Id
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsa.AttributeName = N'Dimension A';
SELECT @OtherSort = SortOrder FROM Quality.QualitySpecAttribute WHERE Id = @OtherId;
DECLARE @OtherSortStr NVARCHAR(10) = CAST(@OtherSort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrMoveUp] Dimension A SortOrder = 2',
    @Expected = N'2',
    @Actual   = @OtherSortStr;
GO

-- =============================================
-- Test 7: MoveUp rejects at top
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AttrId BIGINT;

-- Dimension B is now at top (SortOrder=1)
SELECT @AttrId = qsa.Id
FROM Quality.QualitySpecAttribute qsa
JOIN Quality.QualitySpecVersion qsv ON qsa.QualitySpecVersionId = qsv.Id
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsa.AttributeName = N'Dimension B';

CREATE TABLE #QR9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR9 EXEC Quality.QualitySpecAttribute_MoveUp
    @Id        = @AttrId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR9;
DROP TABLE #QR9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrMoveUpTop] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[AttrMoveUpTop] Message mentions top',
    @HaystackStr = @M,
    @NeedleStr   = N'top';
GO

-- =============================================
-- Test 8: QualitySpecAttribute_MoveDown happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AttrId BIGINT;

-- Dimension B is at SortOrder=1, move down to 2
SELECT @AttrId = qsa.Id
FROM Quality.QualitySpecAttribute qsa
JOIN Quality.QualitySpecVersion qsv ON qsa.QualitySpecVersionId = qsv.Id
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsa.AttributeName = N'Dimension B';

CREATE TABLE #QR10 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR10 EXEC Quality.QualitySpecAttribute_MoveDown
    @Id        = @AttrId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR10;
DROP TABLE #QR10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrMoveDown] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify Dimension B now has SortOrder = 2
DECLARE @NewSort INT;
SELECT @NewSort = SortOrder FROM Quality.QualitySpecAttribute WHERE Id = @AttrId;
DECLARE @NewSortStr NVARCHAR(10) = CAST(@NewSort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrMoveDown] Dimension B SortOrder = 2',
    @Expected = N'2',
    @Actual   = @NewSortStr;
GO

-- =============================================
-- Test 9: ListByVersion returns ordered attributes
-- =============================================
DECLARE @VerId BIGINT;
SELECT @VerId = qsv.Id
FROM Quality.QualitySpecVersion qsv
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsv.VersionNumber = 1;

CREATE TABLE #ListResult (
    Id BIGINT, QualitySpecVersionId BIGINT, AttributeName NVARCHAR(100),
    DataType NVARCHAR(50), Uom NVARCHAR(20),
    UomId BIGINT, UomCode NVARCHAR(50), UomName NVARCHAR(200),
    TargetValue DECIMAL(18,6),
    LowerLimit DECIMAL(18,6), UpperLimit DECIMAL(18,6), IsRequired BIT, SortOrder INT
);

INSERT INTO #ListResult
EXEC Quality.QualitySpecAttribute_ListByVersion @QualitySpecVersionId = @VerId;

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #ListResult);
DECLARE @RowStr NVARCHAR(10) = CAST(@RowCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrList] Returns 3 rows',
    @Expected = N'3',
    @Actual   = @RowStr;

-- Check order (first should be Dimension A now at SortOrder=1)
DECLARE @FirstName NVARCHAR(100) = (SELECT TOP 1 AttributeName FROM #ListResult ORDER BY SortOrder);
EXEC test.Assert_IsEqual
    @TestName = N'[AttrList] First is Dimension A',
    @Expected = N'Dimension A',
    @Actual   = @FirstName;

DROP TABLE #ListResult;
GO

-- =============================================
-- Test 10: Remove attr with SortOrder compaction
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @AttrId BIGINT;

-- Remove Dimension A (SortOrder=1)
SELECT @AttrId = qsa.Id
FROM Quality.QualitySpecAttribute qsa
JOIN Quality.QualitySpecVersion qsv ON qsa.QualitySpecVersionId = qsv.Id
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsa.AttributeName = N'Dimension A';

CREATE TABLE #QR11 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR11 EXEC Quality.QualitySpecAttribute_Remove
    @Id        = @AttrId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR11;
DROP TABLE #QR11;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrRemove] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify remaining attributes have compacted SortOrder
DECLARE @VerId BIGINT;
SELECT @VerId = qsv.Id
FROM Quality.QualitySpecVersion qsv
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsv.VersionNumber = 1;

DECLARE @MinSort INT, @MaxSort INT, @Count INT;
SELECT @MinSort = MIN(SortOrder), @MaxSort = MAX(SortOrder), @Count = COUNT(*)
FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @VerId;

DECLARE @MinStr NVARCHAR(10) = CAST(@MinSort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrRemove] Min SortOrder = 1',
    @Expected = N'1',
    @Actual   = @MinStr;

DECLARE @MaxStr NVARCHAR(10) = CAST(@MaxSort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrRemove] Max SortOrder = 2',
    @Expected = N'2',
    @Actual   = @MaxStr;
GO

-- =============================================
-- Test 11: Publish then reject add/update/remove
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @VerId  BIGINT,
        @AttrId BIGINT;

SELECT @VerId = qsv.Id
FROM Quality.QualitySpecVersion qsv
JOIN Quality.QualitySpec qs ON qsv.QualitySpecId = qs.Id
WHERE qs.Name = N'Test Spec For Attributes' AND qsv.VersionNumber = 1;

-- Publish the version
CREATE TABLE #QR12 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR12 EXEC Quality.QualitySpecVersion_Publish
    @Id        = @VerId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR12;
DROP TABLE #QR12;

-- Try to add
CREATE TABLE #QR13 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR13 EXEC Quality.QualitySpecAttribute_Add
    @QualitySpecVersionId = @VerId,
    @AttributeName        = N'Should Fail',
    @DataType             = N'Text',
    @AppUserId            = 1;
SELECT @S = Status, @M = Message, @AttrId = NewId FROM #QR13;
DROP TABLE #QR13;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrAddPublished] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[AttrAddPublished] Message mentions published',
    @HaystackStr = @M,
    @NeedleStr   = N'published';

-- Try to update existing
SELECT @AttrId = qsa.Id
FROM Quality.QualitySpecAttribute qsa
WHERE qsa.QualitySpecVersionId = @VerId;

CREATE TABLE #QR14 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR14 EXEC Quality.QualitySpecAttribute_Update
    @Id            = @AttrId,
    @AttributeName = N'Changed',
    @DataType      = N'Text',
    @AppUserId     = 1;
SELECT @S = Status, @M = Message FROM #QR14;
DROP TABLE #QR14;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrUpdatePublished] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- Try to remove
CREATE TABLE #QR15 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR15 EXEC Quality.QualitySpecAttribute_Remove
    @Id        = @AttrId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #QR15;
DROP TABLE #QR15;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[AttrRemovePublished] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

EXEC test.EndTestFile;
GO
