-- =============================================
-- File:         0007_Parts_codes/010_Parts_codes_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Parts schema mutable reference code tables (Phase 3).
--   Covers full CRUD for 3 tables (List, Get, Create, Update, Deprecate):
--     - Parts.Uom                 (6 seeded rows)
--     - Parts.ItemType            (5 seeded rows)
--     - Parts.DataCollectionField (7 seeded rows)
--
--   Mutation procs use INSERT-EXEC into temp tables for result capture
--   (converted to SELECT-based result for Ignition JDBC compatibility).
-- =============================================

EXEC test.BeginTestFile @FileName = N'0007_Parts_codes/010_Parts_codes_crud.sql';
GO


-- =============================================
-- == Parts.Uom ===============================================
-- =============================================

-- Test: Uom_List returns 6 seeded rows
DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #R EXEC Parts.Uom_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'Uom_List: 6 active rows returned by proc',
    @ExpectedCount = 6,
    @ActualCount   = @Count;
GO

-- Test: Uom_Get(1) returns 1 row
DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #R EXEC Parts.Uom_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'Uom_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO

-- Test: Uom_Create happy path — status=1, NewId not NULL
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Parts.Uom_Create
    @Code        = N'TEST_UOM',
    @Name        = N'Test Uom',
    @Description = N'Unit created by test',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'Uom_Create[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'Uom_Create[HappyPath]: NewId is not NULL',
    @Value    = @NewIdStr;
GO

-- Test: Uom_Create with NULL Code — status=0
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Parts.Uom_Create
    @Code        = NULL,
    @Name        = N'No Code Uom',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'Uom_Create[NullCode]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- Test: Uom_Create duplicate Code — status=0 with 'already exists' in message
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

-- First insert (clean up at end)
CREATE TABLE #R3a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3a EXEC Parts.Uom_Create
    @Code        = N'DUP_UOM',
    @Name        = N'Dup Uom',
    @AppUserId   = 1;
DROP TABLE #R3a;

-- Second insert with same Code should be rejected
CREATE TABLE #R3b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3b EXEC Parts.Uom_Create
    @Code        = N'DUP_UOM',
    @Name        = N'Dup Uom 2',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R3b;
DROP TABLE #R3b;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'Uom_Create[DuplicateCode]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @HasAlreadyExists NVARCHAR(1) =
    CASE WHEN @M LIKE N'%already exists%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Uom_Create[DuplicateCode]: message contains "already exists"',
    @Expected = N'1',
    @Actual   = @HasAlreadyExists;
GO

-- Test: Uom_Update happy path — status=1 and Name changes
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Parts.Uom WHERE Code = N'TEST_UOM';

CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R4 EXEC Parts.Uom_Update
    @Id          = @TargetId,
    @Name        = N'Test Uom Renamed',
    @Description = N'Updated by test',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'Uom_Update[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredName NVARCHAR(100);
SELECT @StoredName = Name FROM Parts.Uom WHERE Id = @TargetId;

EXEC test.Assert_IsEqual
    @TestName = N'Uom_Update[HappyPath]: Name changed',
    @Expected = N'Test Uom Renamed',
    @Actual   = @StoredName;
GO

-- Test: Uom_Update with missing Id — status=0
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R5 EXEC Parts.Uom_Update
    @Id          = NULL,
    @Name        = N'Nope',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R5;
DROP TABLE #R5;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'Uom_Update[NullId]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- Test: Uom_Deprecate happy path — status=1 and DeprecatedAt set
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Parts.Uom WHERE Code = N'TEST_UOM';

CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R6 EXEC Parts.Uom_Deprecate
    @Id        = @TargetId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R6;
DROP TABLE #R6;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'Uom_Deprecate[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Parts.Uom WHERE Id = @TargetId;

DECLARE @DepAtSet NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Uom_Deprecate[HappyPath]: DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @DepAtSet;
GO


-- =============================================
-- == Parts.ItemType ==========================================
-- =============================================

-- Test: ItemType_List returns 5 active seeded rows
DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #R EXEC Parts.ItemType_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'ItemType_List: 5 active rows returned by proc',
    @ExpectedCount = 5,
    @ActualCount   = @Count;
GO

-- Test: ItemType_Get(1) returns 1 row
DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #R EXEC Parts.ItemType_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'ItemType_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO

-- Test: ItemType_Create happy path
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R7 EXEC Parts.ItemType_Create
    @Code        = N'TEST_ITEMTYPE',
    @Name        = N'Test Item Type',
    @Description = N'Item type created by test',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R7;
DROP TABLE #R7;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Create[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'ItemType_Create[HappyPath]: NewId is not NULL',
    @Value    = @NewIdStr;
GO

-- Test: ItemType_Create NULL Code — status=0
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R8 EXEC Parts.ItemType_Create
    @Code        = NULL,
    @Name        = N'No Code ItemType',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R8;
DROP TABLE #R8;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Create[NullCode]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- Test: ItemType_Create duplicate Code — status=0 with 'already exists'
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R9a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R9a EXEC Parts.ItemType_Create
    @Code        = N'DUP_ITEMTYPE',
    @Name        = N'Dup ItemType',
    @AppUserId   = 1;
DROP TABLE #R9a;

CREATE TABLE #R9b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R9b EXEC Parts.ItemType_Create
    @Code        = N'DUP_ITEMTYPE',
    @Name        = N'Dup ItemType 2',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R9b;
DROP TABLE #R9b;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Create[DuplicateCode]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @HasAlreadyExists NVARCHAR(1) =
    CASE WHEN @M LIKE N'%already exists%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Create[DuplicateCode]: message contains "already exists"',
    @Expected = N'1',
    @Actual   = @HasAlreadyExists;
GO

-- Test: ItemType_Update happy path
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Parts.ItemType WHERE Code = N'TEST_ITEMTYPE';

CREATE TABLE #R10 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R10 EXEC Parts.ItemType_Update
    @Id          = @TargetId,
    @Name        = N'Test ItemType Renamed',
    @Description = N'Updated by test',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R10;
DROP TABLE #R10;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Update[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredName NVARCHAR(100);
SELECT @StoredName = Name FROM Parts.ItemType WHERE Id = @TargetId;

EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Update[HappyPath]: Name changed',
    @Expected = N'Test ItemType Renamed',
    @Actual   = @StoredName;
GO

-- Test: ItemType_Update missing Id — status=0
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R11 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R11 EXEC Parts.ItemType_Update
    @Id          = NULL,
    @Name        = N'Nope',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R11;
DROP TABLE #R11;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Update[NullId]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- Test: ItemType_Deprecate happy path
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Parts.ItemType WHERE Code = N'TEST_ITEMTYPE';

CREATE TABLE #R12 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R12 EXEC Parts.ItemType_Deprecate
    @Id        = @TargetId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R12;
DROP TABLE #R12;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Deprecate[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Parts.ItemType WHERE Id = @TargetId;

DECLARE @DepAtSet NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'ItemType_Deprecate[HappyPath]: DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @DepAtSet;
GO


-- =============================================
-- == Parts.DataCollectionField ===============================
-- =============================================

-- Test: DataCollectionField_List returns 7 active seeded rows
DECLARE @Count INT;
-- v3.0 (migration 0023) widened the SELECT: + DataTypeId/DataTypeCode/DataTypeName.
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), DataTypeId BIGINT, DataTypeCode NVARCHAR(50), DataTypeName NVARCHAR(100), CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #R EXEC Parts.DataCollectionField_List;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'DataCollectionField_List: 7 active rows returned by proc',
    @ExpectedCount = 7,
    @ActualCount   = @Count;
GO

-- Test: DataCollectionField_Get(1) returns 1 row
DECLARE @Count INT;
CREATE TABLE #R (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), Description NVARCHAR(500), CreatedAt DATETIME2(3), DeprecatedAt DATETIME2(3));
INSERT INTO #R EXEC Parts.DataCollectionField_Get @Id = 1;
SELECT @Count = COUNT(*) FROM #R;
DROP TABLE #R;
EXEC test.Assert_RowCount
    @TestName      = N'DataCollectionField_Get(1): 1 row returned',
    @ExpectedCount = 1,
    @ActualCount   = @Count;
GO

-- Test: DataCollectionField_Create happy path
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R13 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R13 EXEC Parts.DataCollectionField_Create
    @Code        = N'TEST_DCF',
    @Name        = N'Test DCF',
    @Description = N'DCF created by test',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R13;
DROP TABLE #R13;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Create[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @NewIdStr NVARCHAR(20) = CAST(@NewId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'DataCollectionField_Create[HappyPath]: NewId is not NULL',
    @Value    = @NewIdStr;
GO

-- Test: DataCollectionField_Create NULL Code — status=0
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R14 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R14 EXEC Parts.DataCollectionField_Create
    @Code        = NULL,
    @Name        = N'No Code DCF',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R14;
DROP TABLE #R14;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Create[NullCode]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- Test: DataCollectionField_Create duplicate Code — status=0 with 'already exists'
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @NewId BIGINT;

CREATE TABLE #R15a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R15a EXEC Parts.DataCollectionField_Create
    @Code        = N'DUP_DCF',
    @Name        = N'Dup DCF',
    @AppUserId   = 1;
DROP TABLE #R15a;

CREATE TABLE #R15b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R15b EXEC Parts.DataCollectionField_Create
    @Code        = N'DUP_DCF',
    @Name        = N'Dup DCF 2',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R15b;
DROP TABLE #R15b;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Create[DuplicateCode]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @HasAlreadyExists NVARCHAR(1) =
    CASE WHEN @M LIKE N'%already exists%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Create[DuplicateCode]: message contains "already exists"',
    @Expected = N'1',
    @Actual   = @HasAlreadyExists;
GO

-- Test: DataCollectionField_Update happy path
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Parts.DataCollectionField WHERE Code = N'TEST_DCF';

CREATE TABLE #R16 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R16 EXEC Parts.DataCollectionField_Update
    @Id          = @TargetId,
    @Name        = N'Test DCF Renamed',
    @Description = N'Updated by test',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R16;
DROP TABLE #R16;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Update[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredName NVARCHAR(100);
SELECT @StoredName = Name FROM Parts.DataCollectionField WHERE Id = @TargetId;

EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Update[HappyPath]: Name changed',
    @Expected = N'Test DCF Renamed',
    @Actual   = @StoredName;
GO

-- Test: DataCollectionField_Update missing Id — status=0
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R17 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R17 EXEC Parts.DataCollectionField_Update
    @Id          = NULL,
    @Name        = N'Nope',
    @AppUserId   = 1;
SELECT @S = Status, @M = Message FROM #R17;
DROP TABLE #R17;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Update[NullId]: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- Test: DataCollectionField_Deprecate happy path
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TargetId BIGINT;

SELECT @TargetId = Id FROM Parts.DataCollectionField WHERE Code = N'TEST_DCF';

CREATE TABLE #R18 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R18 EXEC Parts.DataCollectionField_Deprecate
    @Id        = @TargetId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R18;
DROP TABLE #R18;

SET @SStr = CAST(@S AS NVARCHAR(1));

EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Deprecate[HappyPath]: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @DepAt DATETIME2(3);
SELECT @DepAt = DeprecatedAt FROM Parts.DataCollectionField WHERE Id = @TargetId;

DECLARE @DepAtSet NVARCHAR(1) = CASE WHEN @DepAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'DataCollectionField_Deprecate[HappyPath]: DeprecatedAt is set',
    @Expected = N'1',
    @Actual   = @DepAtSet;
GO


-- =============================================
-- == Audit trail checks ======================================
-- =============================================

-- Uom audit trail: at least Create + Update + Deprecate for TEST_UOM = 3
DECLARE @UomAuditCount INT;
SELECT @UomAuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Uom';

DECLARE @HasUomAudit NVARCHAR(1) = CASE WHEN @UomAuditCount >= 3 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Audit trail: at least 3 ConfigLog entries for Uom',
    @Expected = N'1',
    @Actual   = @HasUomAudit;

-- ItemType audit trail: at least 3 entries
DECLARE @ItemTypeAuditCount INT;
SELECT @ItemTypeAuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'ItemType';

DECLARE @HasItemTypeAudit NVARCHAR(1) = CASE WHEN @ItemTypeAuditCount >= 3 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Audit trail: at least 3 ConfigLog entries for ItemType',
    @Expected = N'1',
    @Actual   = @HasItemTypeAudit;

-- DataCollectionField audit trail: at least 3 entries
DECLARE @DcfAuditCount INT;
SELECT @DcfAuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'DataCollectionField';

DECLARE @HasDcfAudit NVARCHAR(1) = CASE WHEN @DcfAuditCount >= 3 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Audit trail: at least 3 ConfigLog entries for DataCollectionField',
    @Expected = N'1',
    @Actual   = @HasDcfAudit;
GO


-- =============================================
-- Cleanup: remove test-inserted rows so the suite is re-runnable
-- =============================================

DELETE FROM Parts.Uom
    WHERE Code IN (N'TEST_UOM', N'DUP_UOM');

DELETE FROM Parts.ItemType
    WHERE Code IN (N'TEST_ITEMTYPE', N'DUP_ITEMTYPE');

DELETE FROM Parts.DataCollectionField
    WHERE Code IN (N'TEST_DCF', N'DUP_DCF');
GO


-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
