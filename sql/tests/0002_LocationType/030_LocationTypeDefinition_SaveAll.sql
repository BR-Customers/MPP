-- =============================================
-- File:         0002_LocationType/030_LocationTypeDefinition_SaveAll.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-13
-- Description:
--   Tests for Location.LocationTypeDefinition_SaveAll.
--   Covers: create-mode happy path, create-mode rejections (duplicate Code,
--   attribute Ids supplied), update-mode happy path with mixed delta
--   (rename / deprecate-by-omit / insert-new), update-mode rejections
--   (immutable Code, immutable LocationTypeId, cross-definition attribute
--   Id), required-param rejection, within-batch duplicate AttributeName,
--   missing AttributeName / DataType, empty-attributes valid on both
--   create and update, SortOrder follows array index, audit trail.
--
--   Pre-conditions:
--     - Migrations 0001..0014 applied
--     - Seed LocationType (5 tiers) + LocationTypeDefinition (15 rows)
--     - Bootstrap user Id=1
--     - Test framework deployed (helpers/0001_test_framework.sql)
-- =============================================

EXEC test.BeginTestFile @FileName = N'0002_LocationType/030_LocationTypeDefinition_SaveAll.sql';
GO

-- =============================================
-- Test 1: Create-mode happy path — 2 attributes, SortOrder follows array
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @Json NVARCHAR(MAX) = N'[
    {"Id":null,"AttributeName":"Tonnage","DataType":"DECIMAL","IsRequired":1,"Uom":"tons","Description":"Press tonnage"},
    {"Id":null,"AttributeName":"CycleTime","DataType":"DECIMAL","IsRequired":0,"DefaultValue":"60.0","Uom":"sec","Description":"Ref cycle time"}
]';

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_Press',
    @Name            = N'Test Press Machine',
    @Icon            = N'mpp/die_cast',
    @Description     = N'Test definition for SaveAll create-mode',
    @AppUserId       = 1,
    @AttributesJson  = @Json;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create-mode happy path: Status=1',
    @Expected = N'1',
    @Actual   = @SStr;

EXEC test.Assert_IsNotNull
    @TestName = N'Create-mode happy path: NewId returned',
    @Value    = @NewId;

-- Verify definition exists
DECLARE @DefName NVARCHAR(200);
SELECT @DefName = Name FROM Location.LocationTypeDefinition WHERE Id = @NewId;
EXEC test.Assert_IsEqual
    @TestName = N'Create-mode happy path: definition Name persisted',
    @Expected = N'Test Press Machine',
    @Actual   = @DefName;

-- Verify 2 children with SortOrder 1, 2
DECLARE @ChildCount INT;
SELECT @ChildCount = COUNT(*)
FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @NewId AND DeprecatedAt IS NULL;
EXEC test.Assert_RowCount
    @TestName      = N'Create-mode happy path: 2 active children',
    @ExpectedCount = 2,
    @ActualCount   = @ChildCount;

DECLARE @FirstName NVARCHAR(100), @SecondName NVARCHAR(100);
SELECT @FirstName = AttributeName
FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @NewId AND DeprecatedAt IS NULL AND SortOrder = 1;
SELECT @SecondName = AttributeName
FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @NewId AND DeprecatedAt IS NULL AND SortOrder = 2;

EXEC test.Assert_IsEqual
    @TestName = N'Create-mode happy path: child at SortOrder 1 is Tonnage',
    @Expected = N'Tonnage',
    @Actual   = @FirstName;
EXEC test.Assert_IsEqual
    @TestName = N'Create-mode happy path: child at SortOrder 2 is CycleTime',
    @Expected = N'CycleTime',
    @Actual   = @SecondName;
GO

-- =============================================
-- Test 2: Create-mode rejects duplicate Code (DieCastMachine is seeded)
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'DieCastMachine',  -- collides with seed Id=8
    @Name            = N'Should fail',
    @AppUserId       = 1,
    @AttributesJson  = N'[]';
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create-mode duplicate Code: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Create-mode duplicate Code: Message mentions exists',
    @HaystackStr = @M,
    @NeedleStr   = N'already exists';
GO

-- =============================================
-- Test 3: Create-mode rejects when attribute Ids supplied
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @Json NVARCHAR(MAX) = N'[
    {"Id":999,"AttributeName":"X","DataType":"INT","IsRequired":1}
]';
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_WithId',
    @Name            = N'Should fail',
    @AppUserId       = 1,
    @AttributesJson  = @Json;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Create-mode with attribute Id: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Create-mode with attribute Id: Message mentions Ids',
    @HaystackStr = @M,
    @NeedleStr   = N'Cannot specify attribute Ids';
GO

-- =============================================
-- Test 4: Update-mode happy path — mixed delta on TestDef_Press
--   Pre-state: 2 children {Tonnage(1), CycleTime(2)}
--   Submitted: [
--     Tonnage(Id=X1, kept, IsRequired=0),   -- update existing
--     NewAttr(no Id),                        -- insert new
--   ]
--   Expected: CycleTime deprecated, Tonnage updated with IsRequired=0,
--   NewAttr inserted at SortOrder 2, CycleTime's old SortOrder doesn't
--   matter (deprecated rows aren't visible).
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @DefId BIGINT, @TonnageId BIGINT, @CycleTimeId BIGINT;
SELECT @DefId = Id FROM Location.LocationTypeDefinition WHERE Code = N'TestDef_Press';
SELECT @TonnageId   = Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = @DefId AND AttributeName = N'Tonnage'   AND DeprecatedAt IS NULL;
SELECT @CycleTimeId = Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = @DefId AND AttributeName = N'CycleTime' AND DeprecatedAt IS NULL;

DECLARE @TonnageIdStr NVARCHAR(20) = CAST(@TonnageId AS NVARCHAR(20));
DECLARE @Json NVARCHAR(MAX) = N'[
    {"Id":' + @TonnageIdStr + N',"AttributeName":"Tonnage","DataType":"DECIMAL","IsRequired":0,"Uom":"tons"},
    {"Id":null,"AttributeName":"OperatorCount","DataType":"INT","IsRequired":0}
]';

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = @DefId,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_Press',
    @Name            = N'Test Press Machine (Updated)',
    @Icon            = N'mpp/die_cast',
    @Description     = N'Updated description',
    @AppUserId       = 1,
    @AttributesJson  = @Json;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update-mode mixed delta: Status=1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Definition Name updated
DECLARE @NewName NVARCHAR(200);
SELECT @NewName = Name FROM Location.LocationTypeDefinition WHERE Id = @DefId;
EXEC test.Assert_IsEqual
    @TestName = N'Update-mode mixed delta: definition Name updated',
    @Expected = N'Test Press Machine (Updated)',
    @Actual   = @NewName;

-- CycleTime deprecated
DECLARE @CycleDepAt DATETIME2(3);
SELECT @CycleDepAt = DeprecatedAt FROM Location.LocationAttributeDefinition WHERE Id = @CycleTimeId;
DECLARE @CycleDepIsSet BIT = CASE WHEN @CycleDepAt IS NOT NULL THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'Update-mode mixed delta: CycleTime (omitted) is deprecated',
    @Condition = @CycleDepIsSet;

-- Tonnage IsRequired flipped
DECLARE @TonnageIsRequired BIT;
SELECT @TonnageIsRequired = IsRequired FROM Location.LocationAttributeDefinition WHERE Id = @TonnageId;
DECLARE @TonnageIsReqStr NVARCHAR(1) = CAST(@TonnageIsRequired AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update-mode mixed delta: Tonnage IsRequired flipped to 0',
    @Expected = N'0',
    @Actual   = @TonnageIsReqStr;

-- New OperatorCount row exists and is at SortOrder 2
DECLARE @OperatorCountSort INT;
SELECT @OperatorCountSort = SortOrder FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @DefId AND AttributeName = N'OperatorCount' AND DeprecatedAt IS NULL;
DECLARE @OperatorCountSortStr NVARCHAR(10) = CAST(@OperatorCountSort AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'Update-mode mixed delta: new OperatorCount at SortOrder 2',
    @Expected = N'2',
    @Actual   = @OperatorCountSortStr;

-- Active children count is 2 (Tonnage + OperatorCount)
DECLARE @ActiveCount INT;
SELECT @ActiveCount = COUNT(*) FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @DefId AND DeprecatedAt IS NULL;
EXEC test.Assert_RowCount
    @TestName      = N'Update-mode mixed delta: 2 active children after save',
    @ExpectedCount = 2,
    @ActualCount   = @ActiveCount;
GO

-- =============================================
-- Test 5: Update-mode rejects Code change (immutability)
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @DefId BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TestDef_Press');
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = @DefId,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_Press_RENAMED',
    @Name            = N'Test Press Machine',
    @AppUserId       = 1,
    @AttributesJson  = N'[]';
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R5;
DROP TABLE #R5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update-mode Code change: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Update-mode Code change: Message mentions immutable',
    @HaystackStr = @M,
    @NeedleStr   = N'immutable';
GO

-- =============================================
-- Test 6: Update-mode rejects LocationTypeId change (immutability)
-- =============================================
DECLARE @AreaId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Area');
DECLARE @DefId BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TestDef_Press');
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = @DefId,
    @LocationTypeId  = @AreaId,   -- definition is on Cell, submitting Area
    @Code            = N'TestDef_Press',
    @Name            = N'Test Press Machine',
    @AppUserId       = 1,
    @AttributesJson  = N'[]';
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R6;
DROP TABLE #R6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update-mode LocationTypeId change: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Update-mode LocationTypeId change: Message mentions immutable',
    @HaystackStr = @M,
    @NeedleStr   = N'immutable';
GO

-- =============================================
-- Test 7: Update-mode rejects cross-definition attribute Id
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @DefId BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TestDef_Press');
-- An attribute Id belonging to the DieCastMachine definition (seed Id 8) — not ours.
DECLARE @ForeignId BIGINT;
SELECT TOP 1 @ForeignId = Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 8 AND DeprecatedAt IS NULL;

DECLARE @ForeignIdStr NVARCHAR(20) = CAST(@ForeignId AS NVARCHAR(20));
DECLARE @Json NVARCHAR(MAX) = N'[
    {"Id":' + @ForeignIdStr + N',"AttributeName":"X","DataType":"INT"}
]';

DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R7
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = @DefId,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_Press',
    @Name            = N'Test Press Machine',
    @AppUserId       = 1,
    @AttributesJson  = @Json;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R7;
DROP TABLE #R7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Update-mode cross-definition attribute Id: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Update-mode cross-definition attribute Id: Message mentions unknown/deprecated',
    @HaystackStr = @M,
    @NeedleStr   = N'unknown or deprecated';
GO

-- =============================================
-- Test 8: Required parameter missing (@LocationTypeId NULL)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R8
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = NULL,
    @Code            = N'X',
    @Name            = N'X',
    @AppUserId       = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R8;
DROP TABLE #R8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Required param missing: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_IsEqual
    @TestName = N'Required param missing: Message',
    @Expected = N'Required parameter missing.',
    @Actual   = @M;
GO

-- =============================================
-- Test 9: Duplicate AttributeName within batch rejected
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @Json NVARCHAR(MAX) = N'[
    {"Id":null,"AttributeName":"Foo","DataType":"INT"},
    {"Id":null,"AttributeName":"Foo","DataType":"NVARCHAR"}
]';
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R9 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R9
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_DupName',
    @Name            = N'X',
    @AppUserId       = 1,
    @AttributesJson  = @Json;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R9;
DROP TABLE #R9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Duplicate AttributeName: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Duplicate AttributeName: Message mentions Foo',
    @HaystackStr = @M,
    @NeedleStr   = N'Foo';
GO

-- =============================================
-- Test 10: Missing AttributeName in batch rejected
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @Json NVARCHAR(MAX) = N'[
    {"Id":null,"AttributeName":"OK","DataType":"INT"},
    {"Id":null,"AttributeName":null,"DataType":"INT"}
]';
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R10 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R10
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_MissingName',
    @Name            = N'X',
    @AppUserId       = 1,
    @AttributesJson  = @Json;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #R10;
DROP TABLE #R10;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Missing AttributeName at index 2: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'Missing AttributeName at index 2: Message mentions index 2',
    @HaystackStr = @M,
    @NeedleStr   = N'index 2';
GO

-- =============================================
-- Test 11: Empty attributes valid on update — deprecates all active children
--   Setup: create a fresh definition with 2 children.
--   Action: SaveAll update with @AttributesJson = '[]'.
--   Expect: both children deprecated, 0 active.
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @Setup NVARCHAR(MAX) = N'[
    {"Id":null,"AttributeName":"A","DataType":"INT"},
    {"Id":null,"AttributeName":"B","DataType":"INT"}
]';
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;
DECLARE @SStr NVARCHAR(1);

-- Setup: create
CREATE TABLE #R11a (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R11a
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_EmptyAttrs',
    @Name            = N'Empty Attrs Test',
    @AppUserId       = 1,
    @AttributesJson  = @Setup;
SELECT @NewId = NewId FROM #R11a;
DROP TABLE #R11a;

-- Action: update with empty array
DECLARE @EmptyJson NVARCHAR(MAX) = N'[]';
CREATE TABLE #R11b (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R11b
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = @NewId,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDef_EmptyAttrs',
    @Name            = N'Empty Attrs Test',
    @AppUserId       = 1,
    @AttributesJson  = @EmptyJson;
SELECT @S = Status, @M = Message FROM #R11b;
DROP TABLE #R11b;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Empty attributes on update: Status=1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @ActiveAfter INT;
SELECT @ActiveAfter = COUNT(*) FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @NewId AND DeprecatedAt IS NULL;
EXEC test.Assert_RowCount
    @TestName      = N'Empty attributes on update: 0 active children remain',
    @ExpectedCount = 0,
    @ActualCount   = @ActiveAfter;
GO

-- =============================================
-- Test 12: Audit trail — verify ConfigLog has LocationTypeDef entries
-- =============================================
DECLARE @AuditCount INT;
SELECT @AuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'LocationTypeDef';

-- Tests so far have made at least 4 successful saves (T1 create, T4 update,
-- T11a create, T11b update) -> at least 4 audit rows.
DECLARE @HasAudit BIT = CASE WHEN @AuditCount >= 4 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'Audit trail: at least 4 ConfigLog rows for LocationTypeDef',
    @Condition = @HasAudit;
GO

-- =============================================
-- Test 13: Audit-readability convention (Slice 7)
--   Create a definition with 3 attributes, then update it with a mixed
--   delta (rename one, drop one, add one). Asserts the resulting
--   ConfigLog.Description matches the SUBJECT . ACTION convention shape
--   and that the resolved JSON carries the tier FK sub-object.
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @LtdTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'LocationTypeDef');
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

-- Create with 3 attributes
DECLARE @CreateJson NVARCHAR(MAX) = N'[
    {"Id":null,"AttributeName":"Building","DataType":"NVARCHAR","IsRequired":1},
    {"Id":null,"AttributeName":"Floor","DataType":"INT","IsRequired":0},
    {"Id":null,"AttributeName":"SquareFt","DataType":"DECIMAL","IsRequired":0}
]';
CREATE TABLE #R13c (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R13c
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TST-LTD-S7',
    @Name            = N'S7 Convention Def',
    @AppUserId       = 1,
    @AttributesJson  = @CreateJson;
SELECT @NewId = NewId FROM #R13c;
DROP TABLE #R13c;

-- Assert create-mode Description: SUBJECT (tier) . Created; +Attribute ...
DECLARE @CreateDesc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                                     WHERE EntityId = @NewId AND LogEntityTypeId = @LtdTypeId
                                     ORDER BY Id DESC);
DECLARE @CreatePattern NVARCHAR(300) =
    N'Location Type Definition "S7 Convention Def" (Cell tier) ' + Audit.ufn_MidDot()
    + N' Created; +Attribute Building%';
DECLARE @CreateMatch NVARCHAR(1) = CASE WHEN @CreateDesc LIKE @CreatePattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[S7CreateDesc] Create Description matches SUBJECT (tier) . Created; +Attribute',
    @Expected = N'1',
    @Actual   = @CreateMatch;

-- Assert create-mode NewValue carries resolved tier FK {Id, Name}
DECLARE @CreateNew NVARCHAR(MAX) = (SELECT TOP 1 NewValue FROM Audit.ConfigLog
                                    WHERE EntityId = @NewId AND LogEntityTypeId = @LtdTypeId
                                    ORDER BY Id DESC);
DECLARE @CreateFk NVARCHAR(1) =
    CASE WHEN @CreateNew LIKE N'%"LocationType":%' AND @CreateNew LIKE N'%"Name":"Cell"%'
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[S7CreateFk] NewValue carries resolved LocationType {Id, Name:Cell}',
    @Expected = N'1',
    @Actual   = @CreateFk;

-- Update: rename SquareFt -> SquareFootage, drop Floor, add Wing.
DECLARE @BuildingId BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = @NewId AND AttributeName = N'Building' AND DeprecatedAt IS NULL);
DECLARE @SquareFtId BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = @NewId AND AttributeName = N'SquareFt' AND DeprecatedAt IS NULL);
DECLARE @UpdJson NVARCHAR(MAX) = N'[
    {"Id":' + CAST(@BuildingId AS NVARCHAR(20)) + N',"AttributeName":"Building","DataType":"NVARCHAR","IsRequired":1},
    {"Id":' + CAST(@SquareFtId AS NVARCHAR(20)) + N',"AttributeName":"SquareFootage","DataType":"DECIMAL","IsRequired":0},
    {"Id":null,"AttributeName":"Wing","DataType":"NVARCHAR","IsRequired":0}
]';
CREATE TABLE #R13u (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R13u
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = @NewId,
    @LocationTypeId  = @CellId,
    @Code            = N'TST-LTD-S7',
    @Name            = N'S7 Convention Def',
    @AppUserId       = 1,
    @AttributesJson  = @UpdJson;
DROP TABLE #R13u;

-- Assert update-mode Description: contains the ~Attribute rename old -> new
DECLARE @UpdDesc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                                  WHERE EntityId = @NewId AND LogEntityTypeId = @LtdTypeId
                                  ORDER BY Id DESC);
DECLARE @UpdMatch NVARCHAR(1) =
    CASE WHEN @UpdDesc LIKE N'Location Type Definition "S7 Convention Def" ' + Audit.ufn_MidDot() + N'%'
              AND @UpdDesc LIKE N'%~Attribute SquareFt ' + NCHAR(8594) + N' SquareFootage%'
              AND @UpdDesc LIKE N'%-Attribute Floor%'
              AND @UpdDesc LIKE N'%+Attribute Wing%'
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[S7UpdateDesc] Update Description has +Attribute / -Attribute / ~Attribute old->new',
    @Expected = N'1',
    @Actual   = @UpdMatch;
GO

-- =============================================
-- Cleanup: remove test definitions and their children to restore seed state
-- =============================================
DECLARE @CleanupIds TABLE (Id BIGINT);
INSERT INTO @CleanupIds (Id)
SELECT Id FROM Location.LocationTypeDefinition
WHERE Code IN (N'TestDef_Press', N'TestDef_EmptyAttrs', N'TST-LTD-S7');

DELETE FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId IN (SELECT Id FROM @CleanupIds);

DELETE FROM Location.LocationTypeDefinition
WHERE Id IN (SELECT Id FROM @CleanupIds);
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
