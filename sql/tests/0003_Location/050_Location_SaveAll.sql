-- =============================================
-- File:         0003_Location/050_Location_SaveAll.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-18
-- Description:
--   Tests for Location.Location_SaveAll (bundled save: Location row +
--   LocationAttribute values atomic in one proc).
--
--   Covers:
--     1. Create-mode happy path -- new Cell under Area with 2 attribute values
--     2. Create rejects HierarchyLevel violation (FDS-02-002)
--     3. Create rejects missing required attribute value (Terminal's HasBarcodeScanner)
--     4. Create rejects attribute belonging to different LocationTypeDefinition
--     5. Create rejects duplicate Code among active rows
--     6. Update-mode happy path -- rename + add value + change value + clear value
--     7. Update rejects ParentLocationId mismatch (FDS-02-002a immutability)
--     8. Update rejects LocationTypeDefinitionId mismatch (FDS-02-002a immutability)
--
--   Pre-conditions:
--     - Migrations 0001..0014 applied
--     - Seed locations applied (DIECAST area + DC-401 etc.)
--     - DefId 8 = DieCastMachine (Cell, attrs all nullable)
--     - DefId 7 = Terminal (Cell, HasBarcodeScanner required)
--     - Bootstrap user Id=1
-- =============================================

EXEC test.BeginTestFile @FileName = N'0003_Location/050_Location_SaveAll.sql';
GO

-- =============================================
-- Test 1: Create-mode happy path -- DieCastMachine under DIECAST area
-- with 2 attribute values
-- =============================================
DECLARE @DiecastAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DIECAST');
-- Tonnage attribute def for DieCastMachine
DECLARE @TonnageAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 8 AND AttributeName = N'Tonnage'
);
DECLARE @CycleAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 8 AND AttributeName = N'RefCycleTimeSec'
);
DECLARE @Json NVARCHAR(MAX) = N'[' +
    N'{"LocationAttributeDefinitionId":' + CAST(@TonnageAttrId AS NVARCHAR(20)) + N',"Value":"800"},' +
    N'{"LocationAttributeDefinitionId":' + CAST(@CycleAttrId AS NVARCHAR(20)) + N',"Value":"42.5"}' +
    N']';

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1
EXEC Location.Location_SaveAll
    @Id                       = NULL,
    @ParentLocationId         = @DiecastAreaId,
    @LocationTypeDefinitionId = 8,
    @Name                     = N'Test Press SaveAll',
    @Code                     = N'TEST-DC-901',
    @Description              = N'SaveAll happy path test',
    @SortOrder                = NULL,
    @AppUserId                = 1,
    @AttributeValuesJson      = @Json;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create happy path: Status=1',
    @Expected = N'1',
    @Actual   = @SStr;
EXEC test.Assert_IsNotNull
    @TestName = N'Create happy path: NewId returned',
    @Value    = @NewId;

-- Verify Location row
DECLARE @LocName NVARCHAR(200);
SELECT @LocName = Name FROM Location.Location WHERE Id = @NewId;
EXEC test.Assert_IsEqual
    @TestName = N'Create happy path: Location.Name persisted',
    @Expected = N'Test Press SaveAll',
    @Actual   = @LocName;

-- Verify 2 LocationAttribute rows created
DECLARE @AttrCount INT;
SELECT @AttrCount = COUNT(*) FROM Location.LocationAttribute WHERE LocationId = @NewId;
EXEC test.Assert_RowCount
    @TestName      = N'Create happy path: 2 LocationAttribute rows',
    @ExpectedCount = 2,
    @ActualCount   = @AttrCount;

DECLARE @TonVal NVARCHAR(255);
SELECT @TonVal = AttributeValue
FROM Location.LocationAttribute
WHERE LocationId = @NewId AND LocationAttributeDefinitionId = @TonnageAttrId;
EXEC test.Assert_IsEqual
    @TestName = N'Create happy path: Tonnage value persisted',
    @Expected = N'800',
    @Actual   = @TonVal;
GO

-- =============================================
-- Test 2: Create rejects HierarchyLevel violation
-- Try to create an Enterprise (def 1) under DIECAST (Area, level 2)
-- =============================================
DECLARE @DiecastAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DIECAST');

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2
EXEC Location.Location_SaveAll
    @Id                       = NULL,
    @ParentLocationId         = @DiecastAreaId,
    @LocationTypeDefinitionId = 1,   -- Organization (Enterprise tier, level 0)
    @Name                     = N'Bad Enterprise',
    @Code                     = N'BADENT',
    @AppUserId                = 1,
    @AttributeValuesJson      = N'[]';
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'HierarchyLevel violation: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'HierarchyLevel violation: message mentions HierarchyLevel',
    @HaystackStr = @M,
    @NeedleStr   = N'HierarchyLevel';
GO

-- =============================================
-- Test 3: Create rejects missing required attribute
-- Terminal (DefId 7) requires HasBarcodeScanner. Omit it.
-- =============================================
DECLARE @DiecastAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DIECAST');
DECLARE @IpAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'IpAddress'
);
DECLARE @Json3 NVARCHAR(MAX) = N'[' +
    N'{"LocationAttributeDefinitionId":' + CAST(@IpAttrId AS NVARCHAR(20)) + N',"Value":"10.0.0.5"}' +
    N']';

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3
EXEC Location.Location_SaveAll
    @Id                       = NULL,
    @ParentLocationId         = @DiecastAreaId,
    @LocationTypeDefinitionId = 7,   -- Terminal
    @Name                     = N'Bad Terminal',
    @Code                     = N'BADTERM',
    @AppUserId                = 1,
    @AttributeValuesJson      = @Json3;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Missing required attr: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Missing required attr: message names HasBarcodeScanner',
    @HaystackStr = @M,
    @NeedleStr   = N'HasBarcodeScanner';
GO

-- =============================================
-- Test 4: Create rejects attribute belonging to wrong LocationTypeDefinition
-- Try to set Tonnage (DieCastMachine attr) on a Terminal
-- =============================================
DECLARE @DiecastAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DIECAST');
DECLARE @TonnageAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 8 AND AttributeName = N'Tonnage'
);
DECLARE @ScannerAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'HasBarcodeScanner'
);
DECLARE @Json4 NVARCHAR(MAX) = N'[' +
    N'{"LocationAttributeDefinitionId":' + CAST(@TonnageAttrId AS NVARCHAR(20)) + N',"Value":"800"},' +
    N'{"LocationAttributeDefinitionId":' + CAST(@ScannerAttrId AS NVARCHAR(20)) + N',"Value":"1"}' +
    N']';

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4
EXEC Location.Location_SaveAll
    @Id                       = NULL,
    @ParentLocationId         = @DiecastAreaId,
    @LocationTypeDefinitionId = 7,   -- Terminal
    @Name                     = N'Cross-Type Terminal',
    @Code                     = N'BADCROSS',
    @AppUserId                = 1,
    @AttributeValuesJson      = @Json4;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Cross-type attribute: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Cross-type attribute: message mentions does not belong',
    @HaystackStr = @M,
    @NeedleStr   = N'does not belong';
GO

-- =============================================
-- Test 5: Create rejects duplicate Code
-- Test 1 created TEST-DC-901; try to create another with same code
-- =============================================
DECLARE @DiecastAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DIECAST');

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5
EXEC Location.Location_SaveAll
    @Id                       = NULL,
    @ParentLocationId         = @DiecastAreaId,
    @LocationTypeDefinitionId = 8,
    @Name                     = N'Duplicate Code Attempt',
    @Code                     = N'TEST-DC-901',   -- already exists from Test 1
    @AppUserId                = 1,
    @AttributeValuesJson      = N'[]';
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R5;
DROP TABLE #R5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Duplicate Code: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Duplicate Code: message mentions already exists',
    @HaystackStr = @M,
    @NeedleStr   = N'already exists';
GO

-- =============================================
-- Test 6: Update-mode happy path
-- Rename, change one attribute value, add a new one, clear an existing one.
-- Target: the Location created in Test 1 (TEST-DC-901)
-- =============================================
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DC-901');
DECLARE @DiecastAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DIECAST');
DECLARE @TonnageAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 8 AND AttributeName = N'Tonnage'
);
DECLARE @CycleAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 8 AND AttributeName = N'RefCycleTimeSec'
);
DECLARE @OeeAttrId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 8 AND AttributeName = N'OeeTarget'
);
-- Incoming: change Tonnage 800 -> 1200, clear RefCycleTimeSec (empty Value),
-- add OeeTarget=0.85
DECLARE @Json6 NVARCHAR(MAX) = N'[' +
    N'{"LocationAttributeDefinitionId":' + CAST(@TonnageAttrId AS NVARCHAR(20)) + N',"Value":"1200"},' +
    N'{"LocationAttributeDefinitionId":' + CAST(@CycleAttrId AS NVARCHAR(20))   + N',"Value":""},' +
    N'{"LocationAttributeDefinitionId":' + CAST(@OeeAttrId AS NVARCHAR(20))     + N',"Value":"0.85"}' +
    N']';

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6
EXEC Location.Location_SaveAll
    @Id                       = @LocId,
    @ParentLocationId         = @DiecastAreaId,
    @LocationTypeDefinitionId = 8,
    @Name                     = N'Test Press SaveAll RENAMED',
    @Code                     = N'TEST-DC-901',
    @Description              = N'Updated description',
    @AppUserId                = 1,
    @AttributeValuesJson      = @Json6;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R6;
DROP TABLE #R6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update happy path: Status=1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @UpdatedName NVARCHAR(200);
SELECT @UpdatedName = Name FROM Location.Location WHERE Id = @LocId;
EXEC test.Assert_IsEqual
    @TestName = N'Update happy path: Name renamed',
    @Expected = N'Test Press SaveAll RENAMED',
    @Actual   = @UpdatedName;

-- Tonnage updated to 1200
DECLARE @TonVal NVARCHAR(255);
SELECT @TonVal = AttributeValue FROM Location.LocationAttribute
WHERE LocationId = @LocId AND LocationAttributeDefinitionId = @TonnageAttrId;
EXEC test.Assert_IsEqual
    @TestName = N'Update happy path: Tonnage 800 -> 1200',
    @Expected = N'1200',
    @Actual   = @TonVal;

-- Cycle cleared (row deleted)
DECLARE @CycleRows INT;
SELECT @CycleRows = COUNT(*) FROM Location.LocationAttribute
WHERE LocationId = @LocId AND LocationAttributeDefinitionId = @CycleAttrId;
EXEC test.Assert_RowCount
    @TestName      = N'Update happy path: CycleTime cleared (row deleted)',
    @ExpectedCount = 0,
    @ActualCount   = @CycleRows;

-- OeeTarget inserted
DECLARE @OeeVal NVARCHAR(255);
SELECT @OeeVal = AttributeValue FROM Location.LocationAttribute
WHERE LocationId = @LocId AND LocationAttributeDefinitionId = @OeeAttrId;
EXEC test.Assert_IsEqual
    @TestName = N'Update happy path: OeeTarget inserted',
    @Expected = N'0.85',
    @Actual   = @OeeVal;

-- Net: should be 2 active rows (Tonnage, OeeTarget)
DECLARE @TotalAttrs INT;
SELECT @TotalAttrs = COUNT(*) FROM Location.LocationAttribute WHERE LocationId = @LocId;
EXEC test.Assert_RowCount
    @TestName      = N'Update happy path: 2 attribute rows after reconciliation',
    @ExpectedCount = 2,
    @ActualCount   = @TotalAttrs;
GO

-- =============================================
-- Test 7: Update rejects ParentLocationId mismatch (FDS-02-002a immutability)
-- =============================================
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DC-901');
DECLARE @MachShopId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MACHSHOP');

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R7
EXEC Location.Location_SaveAll
    @Id                       = @LocId,
    @ParentLocationId         = @MachShopId,   -- WRONG parent (was DIECAST)
    @LocationTypeDefinitionId = 8,
    @Name                     = N'Reparent Attempt',
    @Code                     = N'TEST-DC-901',
    @AppUserId                = 1,
    @AttributeValuesJson      = N'[]';
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R7;
DROP TABLE #R7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Reparent rejected: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Reparent rejected: message mentions immutable',
    @HaystackStr = @M,
    @NeedleStr   = N'immutable';
GO

-- =============================================
-- Test 8: Update rejects LocationTypeDefinitionId mismatch (FDS-02-002a immutability)
-- =============================================
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DC-901');
DECLARE @DiecastAreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DIECAST');

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R8
EXEC Location.Location_SaveAll
    @Id                       = @LocId,
    @ParentLocationId         = @DiecastAreaId,
    @LocationTypeDefinitionId = 9,   -- WRONG type (was 8 DieCastMachine, this is CNCMachine)
    @Name                     = N'Type Change Attempt',
    @Code                     = N'TEST-DC-901',
    @AppUserId                = 1,
    @AttributeValuesJson      = N'[]';
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R8;
DROP TABLE #R8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Type-change rejected: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Type-change rejected: message mentions immutable',
    @HaystackStr = @M,
    @NeedleStr   = N'immutable';
GO

-- =============================================
-- Cleanup: hard-delete the test rows so subsequent runs are idempotent
-- =============================================
DECLARE @LocId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-DC-901');
DELETE FROM Location.LocationAttribute WHERE LocationId = @LocId;
DELETE FROM Location.Location           WHERE Id = @LocId;
GO

EXEC test.EndTestFile;
GO
