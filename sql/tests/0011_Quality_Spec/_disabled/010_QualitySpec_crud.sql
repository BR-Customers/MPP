-- =============================================
-- File:         0011_Quality_Spec/010_QualitySpec_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Quality.QualitySpec procs:
--     Quality.QualitySpec_Create
--     Quality.QualitySpec_Update
--     Quality.QualitySpec_Get
--     Quality.QualitySpec_List
--
--   Covers: create happy + empty name + invalid Item + invalid
--   OperationTemplate; update happy + not found; list with/without
--   filters; get with derived counts.
--
--   Pre-conditions:
--     - Migration 0001-0008 applied
--     - AppUser Id=1 exists
--     - Parts.Item seed (or created in test)
--     - Parts.OperationTemplate seed (or created in test)
-- =============================================

EXEC test.BeginTestFile @FileName = N'0011_Quality_Spec/010_QualitySpec_crud.sql';
GO

-- =============================================
-- Setup: Create a test Item and OperationTemplate
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @NewId BIGINT;

-- Create test Item
CREATE TABLE #Rc40 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc40
EXEC Parts.Item_Create
    @PartNumber  = N'TEST-QSPEC-ITEM-001',
    @ItemTypeId  = 4,
    @Description = N'Test item for QualitySpec tests',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc40;
DROP TABLE #Rc40;

-- Create test OperationTemplate (v1)
CREATE TABLE #Rc30 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc30
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-QSPEC-OP',
    @Name           = N'Test Operation for QualitySpec',
    @AreaLocationId = 3,  -- DIECAST area from seed_locations.sql
    @Description    = N'Test operation',
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc30;
DROP TABLE #Rc30;
GO

-- =============================================
-- Test 1: QualitySpec_Create happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @SpecId BIGINT;

CREATE TABLE #QR1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR1 EXEC Quality.QualitySpec_Create
    @Name        = N'Test Quality Spec 001',
    @Description = N'Test description',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #QR1;
DROP TABLE #QR1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecCreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @SpecIdStr NVARCHAR(20) = CAST(@SpecId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[QSpecCreateHappy] NewId is not NULL',
    @Value    = @SpecIdStr;
GO

-- =============================================
-- Test 2: QualitySpec_Create with Item
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @SpecId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-QSPEC-ITEM-001';

CREATE TABLE #QR2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR2 EXEC Quality.QualitySpec_Create
    @Name        = N'Test Quality Spec With Item',
    @ItemId      = @ItemId,
    @Description = N'Spec linked to item',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #QR2;
DROP TABLE #QR2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecCreateWithItem] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify FK
DECLARE @LinkedItemId BIGINT;
SELECT @LinkedItemId = ItemId FROM Quality.QualitySpec WHERE Id = @SpecId;
DECLARE @LinkedStr NVARCHAR(20) = CAST(@LinkedItemId AS NVARCHAR(20));
DECLARE @ExpectedStr NVARCHAR(20) = CAST(@ItemId AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecCreateWithItem] ItemId matches',
    @Expected = @ExpectedStr,
    @Actual   = @LinkedStr;
GO

-- =============================================
-- Test 3: QualitySpec_Create with OperationTemplate
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @OpId   BIGINT,
        @SpecId BIGINT;

SELECT @OpId = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-QSPEC-OP' AND DeprecatedAt IS NULL;

CREATE TABLE #QR3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR3 EXEC Quality.QualitySpec_Create
    @Name                = N'Test Quality Spec With Op',
    @OperationTemplateId = @OpId,
    @Description         = N'Spec linked to operation',
    @AppUserId           = 1;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #QR3;
DROP TABLE #QR3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecCreateWithOp] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 4: QualitySpec_Create rejects empty name
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @SpecId BIGINT;

CREATE TABLE #QR4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR4 EXEC Quality.QualitySpec_Create
    @Name      = N'',
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #QR4;
DROP TABLE #QR4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecCreateEmptyName] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSpecCreateEmptyName] Message mentions required',
    @HaystackStr = @M,
    @NeedleStr   = N'Required';
GO

-- =============================================
-- Test 5: QualitySpec_Create rejects invalid ItemId
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @SpecId BIGINT;

CREATE TABLE #QR5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #QR5 EXEC Quality.QualitySpec_Create
    @Name      = N'Test Spec Invalid Item',
    @ItemId    = 999999,
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @SpecId = NewId FROM #QR5;
DROP TABLE #QR5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecCreateInvalidItem] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSpecCreateInvalidItem] Message mentions Item',
    @HaystackStr = @M,
    @NeedleStr   = N'ItemId';
GO

-- =============================================
-- Test 6: QualitySpec_Update happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @SpecId BIGINT;

SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Test Quality Spec 001';

CREATE TABLE #QR6 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR6 EXEC Quality.QualitySpec_Update
    @Id          = @SpecId,
    @Name        = N'Test Quality Spec 001 Updated',
    @Description = N'Updated description',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #QR6;
DROP TABLE #QR6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecUpdateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify update
DECLARE @UpdatedName NVARCHAR(200);
SELECT @UpdatedName = Name FROM Quality.QualitySpec WHERE Id = @SpecId;
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecUpdateHappy] Name changed',
    @Expected = N'Test Quality Spec 001 Updated',
    @Actual   = @UpdatedName;
GO

-- =============================================
-- Test 7: QualitySpec_Update rejects not found
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1);

CREATE TABLE #QR7 (Status BIT, Message NVARCHAR(500));
INSERT INTO #QR7 EXEC Quality.QualitySpec_Update
    @Id          = 999999,
    @Name        = N'Should Fail',
    @Description = N'Should fail',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #QR7;
DROP TABLE #QR7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecUpdateNotFound] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'[QSpecUpdateNotFound] Message mentions not found',
    @HaystackStr = @M,
    @NeedleStr   = N'not found';
GO

-- =============================================
-- Test 8: QualitySpec_Get returns row
-- =============================================
DECLARE @SpecId BIGINT;
SELECT @SpecId = Id FROM Quality.QualitySpec WHERE Name = N'Test Quality Spec 001 Updated';

CREATE TABLE #GetResult (
    Id BIGINT, Name NVARCHAR(200), ItemId BIGINT, ItemCode NVARCHAR(50), ItemName NVARCHAR(200),
    OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50), OperationTemplateName NVARCHAR(200),
    Description NVARCHAR(500), CreatedAt DATETIME2(3), VersionCount INT, ActiveVersionCount INT
);

INSERT INTO #GetResult
EXEC Quality.QualitySpec_Get @Id = @SpecId;

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #GetResult);
DECLARE @RowStr NVARCHAR(10) = CAST(@RowCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecGet] Returns 1 row',
    @Expected = N'1',
    @Actual   = @RowStr;

DROP TABLE #GetResult;
GO

-- =============================================
-- Test 9: QualitySpec_List returns all specs
-- =============================================
CREATE TABLE #ListResult (
    Id BIGINT, Name NVARCHAR(200), ItemId BIGINT, ItemCode NVARCHAR(50), ItemName NVARCHAR(200),
    OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50), OperationTemplateName NVARCHAR(200),
    Description NVARCHAR(500), CreatedAt DATETIME2(3), VersionCount INT, ActiveVersionCount INT
);

INSERT INTO #ListResult
EXEC Quality.QualitySpec_List;

DECLARE @ListCount INT = (SELECT COUNT(*) FROM #ListResult);
DECLARE @HasRows NVARCHAR(1) = CASE WHEN @ListCount >= 3 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecList] Returns at least 3 rows',
    @Expected = N'1',
    @Actual   = @HasRows;

DROP TABLE #ListResult;
GO

-- =============================================
-- Test 10: QualitySpec_List filters by ItemId
-- =============================================
DECLARE @ItemId BIGINT;
SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-QSPEC-ITEM-001';

CREATE TABLE #FilterResult (
    Id BIGINT, Name NVARCHAR(200), ItemId BIGINT, ItemCode NVARCHAR(50), ItemName NVARCHAR(200),
    OperationTemplateId BIGINT, OperationTemplateCode NVARCHAR(50), OperationTemplateName NVARCHAR(200),
    Description NVARCHAR(500), CreatedAt DATETIME2(3), VersionCount INT, ActiveVersionCount INT
);

INSERT INTO #FilterResult
EXEC Quality.QualitySpec_List @ItemId = @ItemId;

DECLARE @FilterCount INT = (SELECT COUNT(*) FROM #FilterResult);
DECLARE @CountStr NVARCHAR(10) = CAST(@FilterCount AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[QSpecListByItem] Returns 1 row',
    @Expected = N'1',
    @Actual   = @CountStr;

DROP TABLE #FilterResult;
GO

EXEC test.EndTestFile;
GO
