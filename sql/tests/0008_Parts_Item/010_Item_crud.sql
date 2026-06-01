-- =============================================
-- File:         0008_Parts_Item/010_Item_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Parts.Item CRUD procs:
--     Parts.Item_List
--     Parts.Item_Get
--     Parts.Item_GetByPartNumber
--     Parts.Item_Create
--     Parts.Item_Update
--     Parts.Item_Deprecate
--
--   Covers: list happy path, create happy + validation branches
--   (NULL required, duplicate PartNumber, invalid ItemTypeId,
--    invalid UomId, UnitWeight-without-WeightUomId),
--   Get by Id / PartNumber (happy + NULL + unknown),
--   Update (happy w/ audit stamps, missing Id, deprecated item),
--   List filters (ItemTypeId, SearchText), and Deprecate
--   (happy + double-deprecate).
--
--   Pre-conditions:
--     - Migration 0001 applied (AppUser, Audit schema, bootstrap user Id=1)
--     - Parts schema migration applied (Parts.Item, Parts.ContainerConfig,
--       Parts.ItemType seeds 1-5, Parts.Uom seeds 1-6)
--     - Audit lookup seeds present (LogEntityType incl. 'Item')
--     - All Parts.Item_* procs deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/010_Item_crud.sql';
GO

-- =============================================
-- Test 1: Item_List happy path (no filters, pre-test baseline call)
--   Assert Status=1. Row count is informational; only status matters here.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1);

CREATE TABLE #List0 (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3)
);

INSERT INTO #List0
EXEC Parts.Item_List;

-- Initial list executes without error (empty or populated both valid).
DROP TABLE #List0;
GO

-- =============================================
-- Test 2: Item_Create happy path
--   Valid required params. Assert Status=1 and NewId not NULL.
--   Verify row stored with correct columns and ConfigLog entry written.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc1
EXEC Parts.Item_Create
    @ItemTypeId       = 4,              -- FinishedGood
    @PartNumber       = N'TEST-001',
    @Description      = N'Test Item 001',
    @MacolaPartNumber = N'MAC-TEST-001',
    @DefaultSubLotQty = 100,
    @MaxLotSize       = 1000,
    @UomId            = 1,              -- EA
    @UnitWeight       = 1.2500,
    @WeightUomId      = 2,              -- LB
    @AppUserId        = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc1;
DROP TABLE #Rc1;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[CreateHappy] NewId is not NULL',
    @Value    = @NewIdStr;

-- Verify row exists
DECLARE @RowCount INT;
SELECT @RowCount = COUNT(*) FROM Parts.Item WHERE Id = @NewId;

EXEC test.Assert_RowCount
    @TestName      = N'[CreateHappy] Item row exists',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount;

-- Verify stored column values
DECLARE @StoredPartNumber  NVARCHAR(100),
        @StoredDescription NVARCHAR(500),
        @StoredMacola      NVARCHAR(100),
        @StoredCreatedBy   BIGINT,
        @StoredDepAt       DATETIME2(3);

SELECT
    @StoredPartNumber  = PartNumber,
    @StoredDescription = Description,
    @StoredMacola      = MacolaPartNumber,
    @StoredCreatedBy   = CreatedByUserId,
    @StoredDepAt       = DeprecatedAt
FROM Parts.Item
WHERE Id = @NewId;

EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] PartNumber stored',
    @Expected = N'TEST-001',
    @Actual   = @StoredPartNumber;

EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] Description stored',
    @Expected = N'Test Item 001',
    @Actual   = @StoredDescription;

EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] MacolaPartNumber stored',
    @Expected = N'MAC-TEST-001',
    @Actual   = @StoredMacola;

DECLARE @StoredCreatedByStr NVARCHAR(20) = CAST(@StoredCreatedBy AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] CreatedByUserId = 1',
    @Expected = N'1',
    @Actual   = @StoredCreatedByStr;

DECLARE @DepAtStr NVARCHAR(1) = CASE WHEN @StoredDepAt IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[CreateHappy] DeprecatedAt is NULL (active)',
    @Expected = N'1',
    @Actual   = @DepAtStr;

-- Verify ConfigLog entry
DECLARE @ConfigLogCount INT;
SELECT @ConfigLogCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Item'
  AND cl.EntityId = @NewId;

EXEC test.Assert_RowCount
    @TestName      = N'[CreateHappy] ConfigLog entry written',
    @ExpectedCount = 1,
    @ActualCount   = @ConfigLogCount;
GO

-- =============================================
-- Test 3: Item_Create - NULL required param (PartNumber)
--   Status=0, NewId NULL.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc2
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = NULL,
    @Description = N'No Part Number',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc2;
DROP TABLE #Rc2;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateNullPart] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateNullPart] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 4: Item_Create - duplicate PartNumber
--   First call succeeds, second call returns status=0 with "already exists".
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT,
        @NewId2 BIGINT;

-- First create
CREATE TABLE #Rc3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc3
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'DUP-001',
    @Description = N'Duplicate Target',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc3;
DROP TABLE #Rc3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateDup] First: Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Second create with same PartNumber
CREATE TABLE #Rc4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc4
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'DUP-001',
    @Description = N'Duplicate Attempt',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId2 = NewId FROM #Rc4;
DROP TABLE #Rc4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateDup] Second: Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewId2Str NVARCHAR(20) = CAST(@NewId2 AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateDup] Second: NewId is NULL',
    @Value    = @NewId2Str;

-- Message should contain "already exists"
DECLARE @MsgContainsStr NVARCHAR(1) = CASE WHEN @M LIKE N'%already exists%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[CreateDup] Message contains "already exists"',
    @Expected = N'1',
    @Actual   = @MsgContainsStr;
GO

-- =============================================
-- Test 5: Item_Create - invalid ItemTypeId
--   Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc5
EXEC Parts.Item_Create
    @ItemTypeId  = 999999,
    @PartNumber  = N'TEST-BADITEMTYPE',
    @Description = N'Bad Item Type',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc5;
DROP TABLE #Rc5;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateBadItemType] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNull
    @TestName = N'[CreateBadItemType] NewId is NULL',
    @Value    = @NewIdStr;
GO

-- =============================================
-- Test 6: Item_Create - invalid UomId
--   Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc6
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'TEST-BADUOM',
    @Description = N'Bad Uom',
    @UomId       = 999999,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc6;
DROP TABLE #Rc6;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateBadUom] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 7: Item_Create - UnitWeight without WeightUomId
--   Status=0 with "WeightUomId required when UnitWeight is provided".
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rc7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc7
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'TEST-NOWGTUOM',
    @Description = N'Weight without UOM',
    @UomId       = 1,
    @UnitWeight  = 2.5,
    @WeightUomId = NULL,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc7;
DROP TABLE #Rc7;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[CreateWeightNoUom] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @MsgStr NVARCHAR(1) = CASE WHEN @M LIKE N'%WeightUomId%UnitWeight%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[CreateWeightNoUom] Message matches expected text',
    @Expected = N'1',
    @Actual   = @MsgStr;
GO

-- =============================================
-- Test 8: Item_Get by valid Id - returns the row
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-001';

CREATE TABLE #Get1 (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3)
);

INSERT INTO #Get1
EXEC Parts.Item_Get @Id = @ItemId;

DECLARE @GetRowCount INT = (SELECT COUNT(*) FROM #Get1);
EXEC test.Assert_RowCount
    @TestName      = N'[GetById] Returns 1 row',
    @ExpectedCount = 1,
    @ActualCount   = @GetRowCount;

DECLARE @GotPart NVARCHAR(100) = (SELECT TOP 1 PartNumber FROM #Get1);
EXEC test.Assert_IsEqual
    @TestName = N'[GetById] PartNumber matches',
    @Expected = N'TEST-001',
    @Actual   = @GotPart;

DROP TABLE #Get1;
GO

-- Test 9 (NULL Id rejection) removed: converted read procs no longer return
-- error status/message on NULL — they simply return an empty result set.

-- =============================================
-- Test 10: Item_GetByPartNumber happy path
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1);

CREATE TABLE #GetP1 (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3)
);

INSERT INTO #GetP1
EXEC Parts.Item_GetByPartNumber @PartNumber = N'TEST-001';

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #GetP1);
EXEC test.Assert_RowCount
    @TestName      = N'[GetByPart] Returns 1 row',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount;

DROP TABLE #GetP1;
GO

-- Test 11 (NULL PartNumber rejection) removed: converted read procs no longer
-- return error status on NULL — they simply return an empty result set.

-- =============================================
-- Test 12: Item_GetByPartNumber - unknown PartNumber
--   Status=1 with 0 rows.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1);

CREATE TABLE #GetP2 (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3)
);

INSERT INTO #GetP2
EXEC Parts.Item_GetByPartNumber @PartNumber = N'TEST-DOESNOTEXIST';

DECLARE @RowCount INT = (SELECT COUNT(*) FROM #GetP2);
EXEC test.Assert_RowCount
    @TestName      = N'[GetByPartUnknown] Returns 0 rows',
    @ExpectedCount = 0,
    @ActualCount   = @RowCount;

DROP TABLE #GetP2;
GO

-- =============================================
-- Test 13: Item_Update happy path
--   Description changes, status=1.
--   UpdatedAt not NULL, UpdatedByUserId = @AppUserId (1).
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

-- Create a fresh item to update
CREATE TABLE #Rc8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc8
EXEC Parts.Item_Create
    @ItemTypeId  = 2,
    @PartNumber  = N'TEST-002',
    @Description = N'Test Item 002 Original',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @ItemId = NewId FROM #Rc8;
DROP TABLE #Rc8;

-- Note: @ItemTypeId and @PartNumber are IMMUTABLE after create and are
-- not parameters on Item_Update. Only mutable fields are passed.
CREATE TABLE #Ru13 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru13
EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Test Item 002 Updated',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #Ru13;
DROP TABLE #Ru13;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify description changed and audit stamps set
DECLARE @StoredDescription  NVARCHAR(500),
        @StoredUpdatedAt    DATETIME2(3),
        @StoredUpdatedBy    BIGINT;

SELECT
    @StoredDescription = Description,
    @StoredUpdatedAt   = UpdatedAt,
    @StoredUpdatedBy   = UpdatedByUserId
FROM Parts.Item
WHERE Id = @ItemId;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] Description changed',
    @Expected = N'Test Item 002 Updated',
    @Actual   = @StoredDescription;

DECLARE @UpdatedAtNotNull NVARCHAR(1) = CASE WHEN @StoredUpdatedAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] UpdatedAt is not NULL',
    @Expected = N'1',
    @Actual   = @UpdatedAtNotNull;

DECLARE @StoredUpdatedByStr NVARCHAR(20) = CAST(@StoredUpdatedBy AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateHappy] UpdatedByUserId = 1',
    @Expected = N'1',
    @Actual   = @StoredUpdatedByStr;
GO

-- =============================================
-- Test 14: Item_Update - missing Id
--   Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1);

CREATE TABLE #Ru14 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru14
EXEC Parts.Item_Update
    @Id          = NULL,
    @Description = N'No-op',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #Ru14;
DROP TABLE #Ru14;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateNullId] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 15: Item_Update - deprecated Item rejected
--   Create item, deprecate, attempt update. Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

CREATE TABLE #Rc9 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc9
EXEC Parts.Item_Create
    @ItemTypeId  = 2,
    @PartNumber  = N'TEST-003',
    @Description = N'Test Item 003 Dep',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @ItemId = NewId FROM #Rc9;
DROP TABLE #Rc9;

CREATE TABLE #Ru15 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru15
EXEC Parts.Item_Deprecate
    @Id        = @ItemId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru15;
DROP TABLE #Ru15;

CREATE TABLE #Ru16 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru16
EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Should not apply',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #Ru16;
DROP TABLE #Ru16;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateDeprecated] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- Verify description was not changed
DECLARE @StoredDesc NVARCHAR(500);
SELECT @StoredDesc = Description FROM Parts.Item WHERE Id = @ItemId;

EXEC test.Assert_IsEqual
    @TestName = N'[UpdateDeprecated] Description unchanged',
    @Expected = N'Test Item 003 Dep',
    @Actual   = @StoredDesc;
GO

-- =============================================
-- Test 16: Item_List filter by @ItemTypeId
--   Create two items of ItemTypeId=5 (PassThrough), filter by type,
--   assert only PassThrough rows are returned.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @Id1 BIGINT,
        @Id2 BIGINT;

CREATE TABLE #Rc10 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc10
EXEC Parts.Item_Create
    @ItemTypeId  = 5,
    @PartNumber  = N'TEST-PT-001',
    @Description = N'PassThrough 1',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @Id1 = NewId FROM #Rc10;
DROP TABLE #Rc10;

CREATE TABLE #Rc11 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc11
EXEC Parts.Item_Create
    @ItemTypeId  = 5,
    @PartNumber  = N'TEST-PT-002',
    @Description = N'PassThrough 2',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @Id2 = NewId FROM #Rc11;
DROP TABLE #Rc11;

CREATE TABLE #ListByType (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3)
);

INSERT INTO #ListByType
EXEC Parts.Item_List @ItemTypeId = 5;

-- All returned rows must be ItemTypeId=5
DECLARE @NonMatchCount INT = (SELECT COUNT(*) FROM #ListByType WHERE ItemTypeId <> 5);
DECLARE @NonMatchStr NVARCHAR(20) = CAST(@NonMatchCount AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[ListByType] All rows have ItemTypeId=5',
    @Expected = N'0',
    @Actual   = @NonMatchStr;

-- Both test items must appear
DECLARE @BothCount INT = (
    SELECT COUNT(*) FROM #ListByType
    WHERE PartNumber IN (N'TEST-PT-001', N'TEST-PT-002')
);
EXEC test.Assert_RowCount
    @TestName      = N'[ListByType] Both PassThrough items present',
    @ExpectedCount = 2,
    @ActualCount   = @BothCount;

DROP TABLE #ListByType;
GO

-- =============================================
-- Test 17: Item_List filter by @SearchText
--   Filter by SearchText='TEST-PT' - should return the two PassThrough rows.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1);

CREATE TABLE #ListSearch (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3)
);

INSERT INTO #ListSearch
EXEC Parts.Item_List @SearchText = N'TEST-PT';

DECLARE @MatchCount INT = (
    SELECT COUNT(*) FROM #ListSearch
    WHERE PartNumber IN (N'TEST-PT-001', N'TEST-PT-002')
);
EXEC test.Assert_RowCount
    @TestName      = N'[ListSearch] Found both PT rows by SearchText',
    @ExpectedCount = 2,
    @ActualCount   = @MatchCount;

DROP TABLE #ListSearch;
GO

-- =============================================
-- Test 18: Item_Deprecate happy path (no dependents)
--   Status=1, DeprecatedAt not NULL.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

CREATE TABLE #Rc12 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc12
EXEC Parts.Item_Create
    @ItemTypeId  = 1,
    @PartNumber  = N'TEST-DEP-001',
    @Description = N'To deprecate',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @ItemId = NewId FROM #Rc12;
DROP TABLE #Rc12;

CREATE TABLE #Ru17 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru17
EXEC Parts.Item_Deprecate
    @Id        = @ItemId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru17;
DROP TABLE #Ru17;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredDepAt DATETIME2(3);
SELECT @StoredDepAt = DeprecatedAt FROM Parts.Item WHERE Id = @ItemId;

DECLARE @DepAtNotNullStr NVARCHAR(1) = CASE WHEN @StoredDepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateHappy] DeprecatedAt is not NULL',
    @Expected = N'1',
    @Actual   = @DepAtNotNullStr;
GO

-- =============================================
-- Test 19: Item_Deprecate - second call rejected
--   Deprecate again; Status=0.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-DEP-001';

CREATE TABLE #Ru18 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru18
EXEC Parts.Item_Deprecate
    @Id        = @ItemId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru18;
DROP TABLE #Ru18;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateTwice] Second call: Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 20: Audit trail - ConfigLog has >= 3 entries for Item entity
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Item';

DECLARE @AuditCond BIT = CASE WHEN @AuditCount >= 3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'[Audit] ConfigLog has >= 3 Item entries',
    @Condition = @AuditCond;
GO

-- =============================================
-- Test 21: Item_Create with MaxParts roundtrips through GetByPartNumber
--   OI-12 (migration 0013): MaxParts moved from ContainerConfig to Item.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rmp1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rmp1
EXEC Parts.Item_Create
    @ItemTypeId = 4,
    @PartNumber = N'TEST-MP-001',
    @Description = N'MaxParts roundtrip',
    @UomId = 1,
    @MaxParts = 100,
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rmp1;
DROP TABLE #Rmp1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateMaxParts] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

CREATE TABLE #Gmp1 (
    Id                BIGINT,
    ItemTypeId        BIGINT,
    ItemTypeName      NVARCHAR(200),
    PartNumber        NVARCHAR(50),
    Description       NVARCHAR(500),
    MacolaPartNumber  NVARCHAR(50),
    DefaultSubLotQty  INT,
    MaxLotSize        INT,
    UomId             BIGINT,
    UomCode           NVARCHAR(20),
    UnitWeight        DECIMAL(10,4),
    WeightUomId       BIGINT,
    WeightUomCode     NVARCHAR(20),
    CountryOfOrigin   NVARCHAR(2),
    MaxParts          INT,
    CreatedAt         DATETIME2(3),
    UpdatedAt         DATETIME2(3),
    CreatedByUserId   BIGINT,
    UpdatedByUserId   BIGINT,
    DeprecatedAt      DATETIME2(3)
);

INSERT INTO #Gmp1
EXEC Parts.Item_GetByPartNumber @PartNumber = N'TEST-MP-001';

DECLARE @StoredMax INT = (SELECT TOP 1 MaxParts FROM #Gmp1);
DECLARE @StoredMaxStr NVARCHAR(10) = CAST(@StoredMax AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateMaxParts] GetByPartNumber surfaces MaxParts = 100',
    @Expected = N'100',
    @Actual   = @StoredMaxStr;
DROP TABLE #Gmp1;
GO

-- =============================================
-- Test 22: Item_Create rejects MaxParts = 0
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #Rmp2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rmp2
EXEC Parts.Item_Create
    @ItemTypeId = 4,
    @PartNumber = N'TEST-MP-002',
    @Description = N'MaxParts zero',
    @UomId = 1,
    @MaxParts = 0,
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rmp2;
DROP TABLE #Rmp2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[CreateMaxPartsZero] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @MsgMatchStr NVARCHAR(1) = CASE WHEN @M LIKE N'%MaxParts%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[CreateMaxPartsZero] Message mentions MaxParts',
    @Expected = N'1',
    @Actual   = @MsgMatchStr;
GO

-- =============================================
-- Test 23: Item_Update sets MaxParts; rejects MaxParts = 0
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-MP-001';

-- Happy path: change MaxParts to 250
CREATE TABLE #Ump1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ump1
EXEC Parts.Item_Update
    @Id = @ItemId,
    @UomId = 1,
    @MaxParts = 250,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ump1;
DROP TABLE #Ump1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateMaxParts] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredMax INT;
SELECT @StoredMax = MaxParts FROM Parts.Item WHERE Id = @ItemId;
DECLARE @StoredMaxStr NVARCHAR(10) = CAST(@StoredMax AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateMaxParts] MaxParts now 250',
    @Expected = N'250',
    @Actual   = @StoredMaxStr;

-- Rejection: MaxParts = 0
CREATE TABLE #Ump2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ump2
EXEC Parts.Item_Update
    @Id = @ItemId,
    @UomId = 1,
    @MaxParts = 0,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ump2;
DROP TABLE #Ump2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateMaxPartsZero] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- Verify MaxParts unchanged
SELECT @StoredMax = MaxParts FROM Parts.Item WHERE Id = @ItemId;
SET @StoredMaxStr = CAST(@StoredMax AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[UpdateMaxPartsZero] MaxParts unchanged at 250',
    @Expected = N'250',
    @Actual   = @StoredMaxStr;
GO

-- =============================================
-- Test 24: Audit-readability narrative — Item_Create Description + resolved FK
--   Slice 5 convention. Description shape:
--     <PartNumber> — <Description> (<ItemTypeName>) · Created
--   NewValue JSON carries a resolved "ItemType" sub-object.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @NewId BIGINT;

CREATE TABLE #RcAud1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RcAud1
EXEC Parts.Item_Create
    @ItemTypeId  = 4,                 -- FinishedGood
    @PartNumber  = N'TEST-ITEM-S5-001',
    @Description = N'Front Cover',
    @UomId       = 1,                 -- EA
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RcAud1;
DROP TABLE #RcAud1;

-- (a) Description follows the convention shape
DECLARE @CreateDesc NVARCHAR(500), @CreateNew NVARCHAR(MAX);
SELECT TOP 1 @CreateDesc = cl.Description, @CreateNew = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Item' AND cl.EntityId = @NewId
ORDER BY cl.Id DESC;

DECLARE @CreateDescMatch NVARCHAR(1) =
    CASE WHEN @CreateDesc LIKE N'TEST-ITEM-S5-001%Front Cover%Created' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditItemCreate] Description matches "<Part> — <Desc> (<Type>) · Created"',
    @Expected = N'1',
    @Actual   = @CreateDescMatch;

-- (b) NewValue JSON contains a resolved ItemType sub-object (Name resolved)
DECLARE @CreateFkMatch NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@CreateNew, '$.ItemType.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditItemCreate] NewValue has resolved ItemType.Name',
    @Expected = N'1',
    @Actual   = @CreateFkMatch;
GO

-- =============================================
-- Test 25: Audit-readability narrative — Item_Update Description (field-diff)
--   Description shape:
--     <PartNumber> · Identity · Updated Description "old" → "new"; ...
--   OldValue JSON carries a resolved "Uom" sub-object.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-ITEM-S5-001';

CREATE TABLE #RuAud1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RuAud1
EXEC Parts.Item_Update
    @Id          = @ItemId,
    @Description = N'Front Cover Assembly',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #RuAud1;
DROP TABLE #RuAud1;

DECLARE @UpdDesc NVARCHAR(500), @UpdOld NVARCHAR(MAX);
SELECT TOP 1 @UpdDesc = cl.Description, @UpdOld = cl.OldValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Item' AND cl.EntityId = @ItemId AND cl.Description LIKE N'%Identity%'
ORDER BY cl.Id DESC;

DECLARE @UpdDescMatch NVARCHAR(1) =
    CASE WHEN @UpdDesc LIKE N'TEST-ITEM-S5-001%Identity%Updated Description%Front Cover%Front Cover Assembly%'
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditItemUpdate] Description shows changed field old→new',
    @Expected = N'1',
    @Actual   = @UpdDescMatch;

DECLARE @UpdFkMatch NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@UpdOld, '$.Uom.Code') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditItemUpdate] OldValue has resolved Uom.Code',
    @Expected = N'1',
    @Actual   = @UpdFkMatch;
GO

-- =============================================
-- Test 26: Audit-readability narrative — Item_Deprecate Description + resolved FK
--   Description shape:
--     <PartNumber> — <Description> · Deprecated
--   OldValue JSON carries a resolved "ItemType" sub-object.
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @ItemId BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-ITEM-S5-001';

CREATE TABLE #RdAud1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RdAud1
EXEC Parts.Item_Deprecate
    @Id        = @ItemId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RdAud1;
DROP TABLE #RdAud1;

DECLARE @DepDesc NVARCHAR(500), @DepOld NVARCHAR(MAX);
SELECT TOP 1 @DepDesc = cl.Description, @DepOld = cl.OldValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Item' AND cl.EntityId = @ItemId AND cl.Description LIKE N'%Deprecated'
ORDER BY cl.Id DESC;

DECLARE @DepDescMatch NVARCHAR(1) =
    CASE WHEN @DepDesc LIKE N'TEST-ITEM-S5-001%Front Cover Assembly%Deprecated' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditItemDeprecate] Description matches "<Part> — <Desc> · Deprecated"',
    @Expected = N'1',
    @Actual   = @DepDescMatch;

DECLARE @DepFkMatch NVARCHAR(1) =
    CASE WHEN JSON_VALUE(@DepOld, '$.ItemType.Name') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[AuditItemDeprecate] OldValue has resolved ItemType.Name',
    @Expected = N'1',
    @Actual   = @DepFkMatch;
GO

-- =============================================
-- Cleanup: delete all test rows (test prefixes TEST- and DUP-)
-- =============================================
DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'DUP-%';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
