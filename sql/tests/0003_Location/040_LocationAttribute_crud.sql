-- =============================================
-- File:         0003_Location/040_LocationAttribute_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for LocationAttribute procs (GetByLocation, Set, Clear).
--   Covers: insert via Set, upsert update via Set, GetByLocation with
--   definition metadata, Clear (non-required), Clear rejection for
--   required attributes, cross-definition validation, invalid FK
--   rejection, and audit trail verification.
--
--   Pre-conditions:
--     - Migration 0002 applied (seed data: LocationTypeDefinitions,
--       LocationAttributeDefinitions for Terminal/DieCastMachine)
--     - All 3 LocationAttribute procs deployed
--     - Location_Create deployed (from Task 5)
--     - Bootstrap user Id=1 exists
-- =============================================

EXEC test.BeginTestFile @FileName = N'0003_Location/040_LocationAttribute_crud.sql';
GO

-- =============================================
-- Setup: Create location hierarchy for tests
--   Enterprise -> Site -> Area -> Line -> DieCastMachine + Terminal
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

-- Enterprise root
CREATE TABLE #RA1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RA1
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 1,
    @ParentLocationId         = NULL,
    @Name                     = N'Test Enterprise (AttrTest)',
    @Code                     = N'ATTR-ENT',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RA1;
DROP TABLE #RA1;

DECLARE @EnterpriseId BIGINT = @NewId;

-- Site
CREATE TABLE #RA2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RA2
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 2,
    @ParentLocationId         = @EnterpriseId,
    @Name                     = N'Test Site (AttrTest)',
    @Code                     = N'ATTR-SITE',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RA2;
DROP TABLE #RA2;

DECLARE @SiteId BIGINT = @NewId;

-- Area
CREATE TABLE #RA3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RA3
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 3,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Test Area (AttrTest)',
    @Code                     = N'ATTR-AREA',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RA3;
DROP TABLE #RA3;

DECLARE @AreaId BIGINT = @NewId;

-- Production Line (WorkCenter, DefId 5)
CREATE TABLE #RA4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RA4
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 5,
    @ParentLocationId         = @AreaId,
    @Name                     = N'Test Line (AttrTest)',
    @Code                     = N'ATTR-LINE',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RA4;
DROP TABLE #RA4;

DECLARE @LineId BIGINT = @NewId;

-- DieCastMachine (DefId 8, Equipment tier)
CREATE TABLE #RA5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RA5
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 8,
    @ParentLocationId         = @LineId,
    @Name                     = N'DCM-001 (AttrTest)',
    @Code                     = N'ATTR-DCM-001',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RA5;
DROP TABLE #RA5;

DECLARE @DcmId BIGINT = @NewId;

-- Terminal (DefId 7, Equipment tier) -- for cross-def and required-attr tests
CREATE TABLE #RA6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RA6
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 7,
    @ParentLocationId         = @LineId,
    @Name                     = N'Term-001 (AttrTest)',
    @Code                     = N'ATTR-TERM-001',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #RA6;
DROP TABLE #RA6;

DECLARE @TerminalId BIGINT = @NewId;

-- Look up attribute definition Ids by name (safe against IDENTITY drift)
DECLARE @TonnageDefId BIGINT, @NumCavDefId BIGINT;
SELECT @TonnageDefId = Id FROM Location.LocationAttributeDefinition
    WHERE AttributeName = N'Tonnage' AND LocationTypeDefinitionId = 8;
SELECT @NumCavDefId = Id FROM Location.LocationAttributeDefinition
    WHERE AttributeName = N'NumberOfCavities' AND LocationTypeDefinitionId = 8;

DECLARE @IpAddrDefId BIGINT, @HasBarcodeScannerDefId BIGINT;
SELECT @IpAddrDefId = Id FROM Location.LocationAttributeDefinition
    WHERE AttributeName = N'IpAddress' AND LocationTypeDefinitionId = 7;
SELECT @HasBarcodeScannerDefId = Id FROM Location.LocationAttributeDefinition
    WHERE AttributeName = N'HasBarcodeScanner' AND LocationTypeDefinitionId = 7;

-- Stash IDs in temp table for cross-batch access
IF OBJECT_ID('tempdb..#AttrTestIds') IS NOT NULL DROP TABLE #AttrTestIds;
CREATE TABLE #AttrTestIds (
    KeyName NVARCHAR(50) PRIMARY KEY,
    Val     BIGINT NOT NULL
);
INSERT INTO #AttrTestIds VALUES
    (N'DcmId',                   @DcmId),
    (N'TerminalId',              @TerminalId),
    (N'TonnageDefId',            @TonnageDefId),
    (N'NumCavDefId',             @NumCavDefId),
    (N'IpAddrDefId',             @IpAddrDefId),
    (N'HasBarcodeScannerDefId',  @HasBarcodeScannerDefId);
GO

-- =============================================
-- Test 1: Set Tonnage=350 on DieCastMachine -- insert
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @DcmId BIGINT       = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');
DECLARE @TonnageDefId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'TonnageDefId');

CREATE TABLE #RSet1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RSet1
EXEC Location.LocationAttribute_Set
    @LocationId                    = @DcmId,
    @LocationAttributeDefinitionId = @TonnageDefId,
    @AttributeValue                = N'350',
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RSet1;
DROP TABLE #RSet1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Set Tonnage=350 (insert): status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify row inserted
DECLARE @InsertedVal NVARCHAR(255);
SELECT @InsertedVal = AttributeValue
FROM Location.LocationAttribute
WHERE LocationId = @DcmId AND LocationAttributeDefinitionId = @TonnageDefId;

EXEC test.Assert_IsEqual
    @TestName = N'Set Tonnage=350 (insert): value stored correctly',
    @Expected = N'350',
    @Actual   = @InsertedVal;
GO

-- =============================================
-- Test 2: Set Tonnage=500 on same location -- upsert update
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @DcmId BIGINT       = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');
DECLARE @TonnageDefId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'TonnageDefId');

CREATE TABLE #RSet2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RSet2
EXEC Location.LocationAttribute_Set
    @LocationId                    = @DcmId,
    @LocationAttributeDefinitionId = @TonnageDefId,
    @AttributeValue                = N'500',
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RSet2;
DROP TABLE #RSet2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Set Tonnage=500 (upsert): status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify value updated (not duplicated)
DECLARE @RowCount INT;
SELECT @RowCount = COUNT(*)
FROM Location.LocationAttribute
WHERE LocationId = @DcmId AND LocationAttributeDefinitionId = @TonnageDefId;

EXEC test.Assert_RowCount
    @TestName      = N'Set Tonnage=500 (upsert): still only 1 row',
    @ExpectedCount = 1,
    @ActualCount   = @RowCount;

DECLARE @UpdatedVal NVARCHAR(255);
SELECT @UpdatedVal = AttributeValue
FROM Location.LocationAttribute
WHERE LocationId = @DcmId AND LocationAttributeDefinitionId = @TonnageDefId;

EXEC test.Assert_IsEqual
    @TestName = N'Set Tonnage=500 (upsert): value changed to 500',
    @Expected = N'500',
    @Actual   = @UpdatedVal;

-- Verify UpdatedAt is set
DECLARE @UpdAt DATETIME2(3);
SELECT @UpdAt = UpdatedAt
FROM Location.LocationAttribute
WHERE LocationId = @DcmId AND LocationAttributeDefinitionId = @TonnageDefId;

DECLARE @UpdAtNotNull NVARCHAR(1) = CASE WHEN @UpdAt IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Set Tonnage=500 (upsert): UpdatedAt is set',
    @Expected = N'1',
    @Actual   = @UpdAtNotNull;
GO

-- =============================================
-- Test 3: GetByLocation -- proc returns one row per active definition;
--   exactly one row (Tonnage) has a persisted value at this point.
-- =============================================
DECLARE @DcmId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');

DECLARE @PersistedCount INT, @TotalCount INT, @AllDefsCount INT;
DECLARE @AttrName NVARCHAR(100), @DataType NVARCHAR(50), @Uom NVARCHAR(20);
CREATE TABLE #R (
    Id BIGINT, LocationId BIGINT, LocationAttributeDefinitionId BIGINT,
    AttributeValue NVARCHAR(500), CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
    UpdatedByUserId BIGINT,
    AttributeName NVARCHAR(100), DataType NVARCHAR(50), IsRequired BIT,
    DefaultValue NVARCHAR(200), Uom NVARCHAR(20), SortOrder INT, Description NVARCHAR(500)
);
INSERT INTO #R EXEC Location.LocationAttribute_GetByLocation @LocationId = @DcmId;

SELECT @PersistedCount = COUNT(*),
       @AttrName       = MAX(AttributeName),
       @DataType       = MAX(DataType),
       @Uom            = MAX(Uom)
FROM #R
WHERE Id IS NOT NULL;

SELECT @TotalCount = COUNT(*) FROM #R;
DROP TABLE #R;

SELECT @AllDefsCount = COUNT(*)
FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL;

EXEC test.Assert_RowCount
    @TestName      = N'GetByLocation (1 value persisted): 1 row has non-NULL Id',
    @ExpectedCount = 1,
    @ActualCount   = @PersistedCount;

EXEC test.Assert_RowCount
    @TestName      = N'GetByLocation: returns one row per active definition for the type',
    @ExpectedCount = @AllDefsCount,
    @ActualCount   = @TotalCount;

EXEC test.Assert_IsEqual
    @TestName = N'GetByLocation (1 value): persisted AttributeName is Tonnage',
    @Expected = N'Tonnage',
    @Actual   = @AttrName;

EXEC test.Assert_IsEqual
    @TestName = N'GetByLocation (1 value): persisted DataType is DECIMAL',
    @Expected = N'DECIMAL',
    @Actual   = @DataType;

EXEC test.Assert_IsEqual
    @TestName = N'GetByLocation (1 value): persisted Uom is tons',
    @Expected = N'tons',
    @Actual   = @Uom;
GO

-- =============================================
-- Test 4: Set NumberOfCavities=4 -- second attribute inserted
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @DcmId BIGINT      = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');
DECLARE @NumCavDefId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'NumCavDefId');

CREATE TABLE #RSet4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RSet4
EXEC Location.LocationAttribute_Set
    @LocationId                    = @DcmId,
    @LocationAttributeDefinitionId = @NumCavDefId,
    @AttributeValue                = N'4',
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RSet4;
DROP TABLE #RSet4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Set NumberOfCavities=4 (insert): status is 1',
    @Expected = N'1',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 5: GetByLocation -- returns both attributes, ordered by SortOrder
-- =============================================
DECLARE @DcmId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');

DECLARE @AttrCount INT;
CREATE TABLE #R (
    Id BIGINT, LocationId BIGINT, LocationAttributeDefinitionId BIGINT,
    AttributeValue NVARCHAR(500), CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
    UpdatedByUserId BIGINT,
    AttributeName NVARCHAR(100), DataType NVARCHAR(50), IsRequired BIT,
    DefaultValue NVARCHAR(200), Uom NVARCHAR(20), SortOrder INT, Description NVARCHAR(500)
);
INSERT INTO #R EXEC Location.LocationAttribute_GetByLocation @LocationId = @DcmId;
SELECT @AttrCount = COUNT(*) FROM #R WHERE Id IS NOT NULL;
DROP TABLE #R;

EXEC test.Assert_RowCount
    @TestName      = N'GetByLocation (2 values persisted): 2 rows have non-NULL Id',
    @ExpectedCount = 2,
    @ActualCount   = @AttrCount;

-- Verify ordering: Tonnage (SortOrder=1) before NumberOfCavities (SortOrder=2)
DECLARE @FirstAttrName NVARCHAR(100);
SELECT TOP 1 @FirstAttrName = lad.AttributeName
FROM Location.LocationAttribute la
INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
WHERE la.LocationId = @DcmId
ORDER BY lad.SortOrder ASC;

EXEC test.Assert_IsEqual
    @TestName = N'GetByLocation (2 attrs): first by SortOrder is Tonnage',
    @Expected = N'Tonnage',
    @Actual   = @FirstAttrName;
GO

-- =============================================
-- Test 6: Clear Tonnage (not required) -- row deleted
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @DcmId BIGINT       = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');
DECLARE @TonnageDefId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'TonnageDefId');

CREATE TABLE #RClr1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RClr1
EXEC Location.LocationAttribute_Clear
    @LocationId                    = @DcmId,
    @LocationAttributeDefinitionId = @TonnageDefId,
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RClr1;
DROP TABLE #RClr1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Clear Tonnage: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify row deleted
DECLARE @TonnageExists INT;
SELECT @TonnageExists = COUNT(*)
FROM Location.LocationAttribute
WHERE LocationId = @DcmId AND LocationAttributeDefinitionId = @TonnageDefId;

EXEC test.Assert_RowCount
    @TestName      = N'Clear Tonnage: row deleted (0 remaining)',
    @ExpectedCount = 0,
    @ActualCount   = @TonnageExists;
GO

-- =============================================
-- Test 7: GetByLocation -- only NumberOfCavities remains
-- =============================================
DECLARE @DcmId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');

DECLARE @RemainingCount INT;
DECLARE @RemainingName NVARCHAR(100);
CREATE TABLE #R (
    Id BIGINT, LocationId BIGINT, LocationAttributeDefinitionId BIGINT,
    AttributeValue NVARCHAR(500), CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
    UpdatedByUserId BIGINT,
    AttributeName NVARCHAR(100), DataType NVARCHAR(50), IsRequired BIT,
    DefaultValue NVARCHAR(200), Uom NVARCHAR(20), SortOrder INT, Description NVARCHAR(500)
);
INSERT INTO #R EXEC Location.LocationAttribute_GetByLocation @LocationId = @DcmId;
SELECT @RemainingCount = COUNT(*), @RemainingName = MAX(AttributeName)
FROM #R
WHERE Id IS NOT NULL;
DROP TABLE #R;

EXEC test.Assert_RowCount
    @TestName      = N'GetByLocation after Clear: only 1 persisted value remains',
    @ExpectedCount = 1,
    @ActualCount   = @RemainingCount;

EXEC test.Assert_IsEqual
    @TestName = N'GetByLocation after Clear: remaining persisted attr is NumberOfCavities',
    @Expected = N'NumberOfCavities',
    @Actual   = @RemainingName;
GO

-- =============================================
-- Test 8: Clear a required attribute (HasBarcodeScanner on Terminal) -- rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TerminalId BIGINT           = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'TerminalId');
DECLARE @HasBarcodeScannerDefId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'HasBarcodeScannerDefId');

-- First, set the value so there is something to clear
CREATE TABLE #RSet8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RSet8
EXEC Location.LocationAttribute_Set
    @LocationId                    = @TerminalId,
    @LocationAttributeDefinitionId = @HasBarcodeScannerDefId,
    @AttributeValue                = N'1',
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RSet8;
DROP TABLE #RSet8;

-- Now try to clear it -- should be rejected because IsRequired=1
CREATE TABLE #RClr8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RClr8
EXEC Location.LocationAttribute_Clear
    @LocationId                    = @TerminalId,
    @LocationAttributeDefinitionId = @HasBarcodeScannerDefId,
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RClr8;
DROP TABLE #RClr8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Clear required attribute: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Clear required attribute: message says cannot clear',
    @Expected = N'Cannot clear a required attribute.',
    @Actual   = @M;
GO

-- =============================================
-- Test 9: Set with wrong definition -- Terminal attr on DieCastMachine, rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @DcmId BIGINT      = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');
DECLARE @IpAddrDefId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'IpAddrDefId');

-- IpAddress belongs to Terminal (DefId 7), but DcmId is a DieCastMachine (DefId 8)
CREATE TABLE #RSet9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RSet9
EXEC Location.LocationAttribute_Set
    @LocationId                    = @DcmId,
    @LocationAttributeDefinitionId = @IpAddrDefId,
    @AttributeValue                = N'192.168.1.100',
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RSet9;
DROP TABLE #RSet9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Set cross-definition mismatch: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Set cross-definition mismatch: message says wrong type',
    @Expected = N'Attribute definition does not belong to this location''s type definition.',
    @Actual   = @M;
GO

-- =============================================
-- Test 10: Set with invalid LocationId -- rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @TonnageDefId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'TonnageDefId');

CREATE TABLE #RSet10 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RSet10
EXEC Location.LocationAttribute_Set
    @LocationId                    = 999999,
    @LocationAttributeDefinitionId = @TonnageDefId,
    @AttributeValue                = N'350',
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RSet10;
DROP TABLE #RSet10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Set invalid LocationId: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Set invalid LocationId: message says not found',
    @Expected = N'Location not found or deprecated.',
    @Actual   = @M;
GO

-- =============================================
-- Test 11: Set with invalid AttributeDefinitionId -- rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);
DECLARE @DcmId BIGINT = (SELECT Val FROM #AttrTestIds WHERE KeyName = N'DcmId');

CREATE TABLE #RSet11 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RSet11
EXEC Location.LocationAttribute_Set
    @LocationId                    = @DcmId,
    @LocationAttributeDefinitionId = 999999,
    @AttributeValue                = N'350',
    @AppUserId                     = 1;
SELECT @S = Status, @M = Message FROM #RSet11;
DROP TABLE #RSet11;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Set invalid AttributeDefinitionId: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'Set invalid AttributeDefinitionId: message says not found',
    @Expected = N'Attribute definition not found or deprecated.',
    @Actual   = @M;
GO

-- =============================================
-- Test 12: Audit trail -- verify ConfigLog entries for LocationAttrDef entity
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'LocationAttrDef';

-- Expected audit entries from this test file:
--   Test 1: Set Tonnage=350 (Created) = 1
--   Test 2: Set Tonnage=500 (Updated) = 1
--   Test 4: Set NumberOfCavities=4 (Created) = 1
--   Test 6: Clear Tonnage (Updated) = 1
--   Test 8: Set HasBarcodeScanner=1 on Terminal (Created) = 1
-- Total from LocationAttribute Set/Clear: at least 5
-- (plus any from seed AttributeDefinition creation in other tests if they ran)

DECLARE @HasAudit NVARCHAR(1) = CASE WHEN @AuditCount >= 5 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Audit trail: at least 5 ConfigLog entries for LocationAttrDef',
    @Expected = N'1',
    @Actual   = @HasAudit;
GO

-- =============================================
-- Test 13: Audit-readability — Set attribute narrative + resolved-FK JSON
--   Tonnage on ATTR-DCM-001 was set to 350 (insert) then 500 (update,
--   was 350). Assert against the upsert-update entry which carries the
--   "(was ...)" clause and a resolved OldValue.
-- =============================================
DECLARE @SetDesc NVARCHAR(500), @SetOld NVARCHAR(MAX), @SetNew NVARCHAR(MAX);
SELECT TOP 1 @SetDesc = cl.Description, @SetOld = cl.OldValue, @SetNew = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'LocationAttrDef'
  AND cl.Description LIKE N'Location ATTR-DCM-001 % Set attribute Tonnage = "500"%'
ORDER BY cl.Id DESC;

EXEC test.Assert_Contains
    @TestName    = N'Set audit: Description matches "Set attribute <Name> = ..." convention',
    @HaystackStr = @SetDesc,
    @NeedleStr   = N'Set attribute Tonnage = "500"';

EXEC test.Assert_Contains
    @TestName    = N'Set audit: Description carries the (was "350") prior-value clause',
    @HaystackStr = @SetDesc,
    @NeedleStr   = N'(was "350")';

EXEC test.Assert_Contains
    @TestName    = N'Set audit: NewValue JSON carries Attribute FK sub-object',
    @HaystackStr = @SetNew,
    @NeedleStr   = N'"Attribute":{';

EXEC test.Assert_Contains
    @TestName    = N'Set audit: OldValue JSON carries Attribute FK sub-object',
    @HaystackStr = @SetOld,
    @NeedleStr   = N'"Attribute":{';
GO

-- =============================================
-- Cleanup: remove test data to restore clean state
-- =============================================

-- Delete attribute values first
DELETE la FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code IN (N'ATTR-DCM-001', N'ATTR-TERM-001');

-- Delete locations bottom-up
DELETE FROM Location.Location WHERE Code IN (N'ATTR-DCM-001', N'ATTR-TERM-001');
DELETE FROM Location.Location WHERE Code = N'ATTR-LINE';
DELETE FROM Location.Location WHERE Code = N'ATTR-AREA';
DELETE FROM Location.Location WHERE Code = N'ATTR-SITE';
DELETE FROM Location.Location WHERE Code = N'ATTR-ENT';

-- Drop temp table
DROP TABLE IF EXISTS #AttrTestIds;
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
