-- =============================================
-- File:         0002_LocationType/040_LocationTypeDefinition_Deprecate.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-13
-- Description:
--   Tests for Location.LocationTypeDefinition_Deprecate.
--   Covers: happy path with child cascade, FK guard against active
--   Location.Location rows, idempotent re-deprecate (Status=1), not-found
--   rejection, required-param rejection, audit trail.
--
--   Pre-conditions:
--     - Migrations 0001..0014 applied
--     - Seed LocationType + LocationTypeDefinition + Location.Location
--     - DieCastMachine (Code='DieCastMachine') has active Location rows
--       in the MPP plant seed -- used for the FK-guard rejection test
--       (count derived dynamically in Test 3, not hardcoded)
--     - Bootstrap user Id=1
--     - Test framework deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0002_LocationType/040_LocationTypeDefinition_Deprecate.sql';
GO

-- =============================================
-- Setup: create a fresh LocationTypeDefinition with children via SaveAll
--        so we can deprecate it without disturbing seed data.
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @SetupJson NVARCHAR(MAX) = N'[
    {"Id":null,"AttributeName":"AttrA","DataType":"INT"},
    {"Id":null,"AttributeName":"AttrB","DataType":"NVARCHAR"}
]';
DECLARE @CreatedId BIGINT;

CREATE TABLE #Setup (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Setup
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TestDepDef',
    @Name            = N'Test Deprecate Definition',
    @AppUserId       = 1,
    @AttributesJson  = @SetupJson;
SELECT @CreatedId = NewId FROM #Setup;
DROP TABLE #Setup;
GO

-- =============================================
-- Test 1: Happy path -- deprecate fresh definition, children cascade
-- =============================================
DECLARE @CreatedId BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TestDepDef');
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R1
EXEC Location.LocationTypeDefinition_Deprecate
    @Id        = @CreatedId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R1;
DROP TABLE #R1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Happy path: Status=1',
    @Expected = N'1',
    @Actual   = @SStr;

EXEC test.Assert_Contains
    @TestName    = N'Happy path: Message mentions cascade count',
    @HaystackStr = @M,
    @NeedleStr   = N'cascaded';

-- Parent has DeprecatedAt set
DECLARE @ParentDepAt DATETIME2(3);
SELECT @ParentDepAt = DeprecatedAt FROM Location.LocationTypeDefinition WHERE Id = @CreatedId;
DECLARE @ParentDepIsSet BIT = CASE WHEN @ParentDepAt IS NOT NULL THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'Happy path: parent DeprecatedAt is set',
    @Condition = @ParentDepIsSet;

-- All 2 children also deprecated -> 0 active
DECLARE @ActiveChildCount INT;
SELECT @ActiveChildCount = COUNT(*) FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @CreatedId AND DeprecatedAt IS NULL;
EXEC test.Assert_RowCount
    @TestName      = N'Happy path: 0 active children after cascade',
    @ExpectedCount = 0,
    @ActualCount   = @ActiveChildCount;

-- Total children (active + deprecated) still 2
DECLARE @TotalChildCount INT;
SELECT @TotalChildCount = COUNT(*) FROM Location.LocationAttributeDefinition
WHERE LocationTypeDefinitionId = @CreatedId;
EXEC test.Assert_RowCount
    @TestName      = N'Happy path: 2 total children (rows not deleted, just deprecated)',
    @ExpectedCount = 2,
    @ActualCount   = @TotalChildCount;
GO

-- =============================================
-- Test 2: Idempotent re-deprecate -- Status=1, Already deprecated
-- =============================================
DECLARE @CreatedId BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TestDepDef');
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R2
EXEC Location.LocationTypeDefinition_Deprecate
    @Id        = @CreatedId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R2;
DROP TABLE #R2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Re-deprecate already-deprecated: Status=1 (idempotent)',
    @Expected = N'1',
    @Actual   = @SStr;
EXEC test.Assert_IsEqual
    @TestName = N'Re-deprecate already-deprecated: Message = Already deprecated.',
    @Expected = N'Already deprecated.',
    @Actual   = @M;
GO

-- =============================================
-- Test 3: FK guard -- DieCastMachine has 3 active Location rows, reject
-- =============================================
DECLARE @DieCastDefId BIGINT;
SELECT @DieCastDefId = Id FROM Location.LocationTypeDefinition WHERE Code = N'DieCastMachine';
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

-- Derive the active-Location count for DieCastMachine from the seed so the
-- message assertion survives seed regeneration (the MPP plant seed has many
-- die-cast machines, not a fixed 3).
DECLARE @DcActiveCount INT;
SELECT @DcActiveCount = COUNT(*) FROM Location.Location
WHERE LocationTypeDefinitionId = @DieCastDefId AND DeprecatedAt IS NULL;
DECLARE @CountNeedle NVARCHAR(60) = CAST(@DcActiveCount AS NVARCHAR(20)) + N' active Location';

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R3
EXEC Location.LocationTypeDefinition_Deprecate
    @Id        = @DieCastDefId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R3;
DROP TABLE #R3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'FK guard against active Locations: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_Contains
    @TestName    = N'FK guard: Message mentions cannot deprecate',
    @HaystackStr = @M,
    @NeedleStr   = N'Cannot deprecate';
EXEC test.Assert_Contains
    @TestName    = N'FK guard: Message reports the seeded active-Location count',
    @HaystackStr = @M,
    @NeedleStr   = @CountNeedle;

-- Verify DieCastMachine is still active (rejection did not mutate)
DECLARE @StillActive BIT;
SELECT @StillActive = CASE WHEN DeprecatedAt IS NULL THEN 1 ELSE 0 END
FROM Location.LocationTypeDefinition WHERE Id = @DieCastDefId;
EXEC test.Assert_IsTrue
    @TestName  = N'FK guard: DieCastMachine still active after rejection',
    @Condition = @StillActive;
GO

-- =============================================
-- Test 4: Not found -- Id 99999 doesn't exist
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R4
EXEC Location.LocationTypeDefinition_Deprecate
    @Id        = 99999,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R4;
DROP TABLE #R4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'Not found: Status=0',
    @Expected = N'0',
    @Actual   = @SStr;
EXEC test.Assert_IsEqual
    @TestName = N'Not found: Message',
    @Expected = N'LocationTypeDefinition not found.',
    @Actual   = @M;
GO

-- =============================================
-- Test 5: Required param missing (@Id NULL)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @SStr NVARCHAR(1);

CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #R5
EXEC Location.LocationTypeDefinition_Deprecate
    @Id        = NULL,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #R5;
DROP TABLE #R5;

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
-- Test 5b: Audit-readability convention (Slice 7)
--   Create a fresh definition with 2 children, deprecate it, and assert
--   the resulting ConfigLog.Description matches the convention shape and
--   that OldValue carries the resolved tier FK sub-object.
-- =============================================
DECLARE @CellId BIGINT = (SELECT Id FROM Location.LocationType WHERE Code = N'Cell');
DECLARE @LtdTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'LocationTypeDef');
DECLARE @ConvJson NVARCHAR(MAX) = N'[
    {"Id":null,"AttributeName":"AttrX","DataType":"INT"},
    {"Id":null,"AttributeName":"AttrY","DataType":"NVARCHAR"}
]';
DECLARE @ConvId BIGINT;

CREATE TABLE #R5bSetup (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5bSetup
EXEC Location.LocationTypeDefinition_SaveAll
    @Id              = NULL,
    @LocationTypeId  = @CellId,
    @Code            = N'TST-LTD-S7-DEP',
    @Name            = N'S7 Dep Convention Def',
    @AppUserId       = 1,
    @AttributesJson  = @ConvJson;
SELECT @ConvId = NewId FROM #R5bSetup;
DROP TABLE #R5bSetup;

CREATE TABLE #R5b (Status BIT, Message NVARCHAR(500));
INSERT INTO #R5b
EXEC Location.LocationTypeDefinition_Deprecate
    @Id        = @ConvId,
    @AppUserId = 1;
DROP TABLE #R5b;

-- Description: SUBJECT . Deprecated (cascade: 2 attributes deprecated)
DECLARE @DepDesc NVARCHAR(500) = (SELECT TOP 1 Description FROM Audit.ConfigLog
                                  WHERE EntityId = @ConvId AND LogEntityTypeId = @LtdTypeId
                                    AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'Deprecated')
                                  ORDER BY Id DESC);
DECLARE @DepPattern NVARCHAR(300) =
    N'Location Type Definition "S7 Dep Convention Def" ' + Audit.ufn_MidDot()
    + N' Deprecated (cascade: 2 attributes deprecated)';
DECLARE @DepMatch NVARCHAR(1) = CASE WHEN @DepDesc LIKE @DepPattern THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[S7DepDesc] Deprecate Description matches SUBJECT . Deprecated (cascade: N attributes deprecated)',
    @Expected = N'1',
    @Actual   = @DepMatch;

-- OldValue carries resolved tier FK {Id, Name:Cell}; NewValue is NULL
DECLARE @DepOld NVARCHAR(MAX) = (SELECT TOP 1 OldValue FROM Audit.ConfigLog
                                 WHERE EntityId = @ConvId AND LogEntityTypeId = @LtdTypeId
                                   AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'Deprecated')
                                 ORDER BY Id DESC);
DECLARE @DepFk NVARCHAR(1) =
    CASE WHEN @DepOld LIKE N'%"LocationType":%' AND @DepOld LIKE N'%"Name":"Cell"%'
         THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[S7DepFk] OldValue carries resolved LocationType {Id, Name:Cell}',
    @Expected = N'1',
    @Actual   = @DepFk;

-- Cleanup the convention fixture
DELETE FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = @ConvId;
DELETE FROM Location.LocationTypeDefinition WHERE Id = @ConvId;
GO

-- =============================================
-- Test 6: Audit trail -- success Deprecate logged to ConfigLog,
--                       rejections logged to FailureLog
-- =============================================
DECLARE @ConfigCount INT;
SELECT @ConfigCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
INNER JOIN Audit.LogEventType  evt ON evt.Id = cl.LogEventTypeId
WHERE let.Code = N'LocationTypeDef'
  AND evt.Code = N'Deprecated';

-- At least 1 successful Deprecate audit row from Test 1
DECLARE @HasConfig BIT = CASE WHEN @ConfigCount >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'Audit ConfigLog: at least 1 Deprecate audit row',
    @Condition = @HasConfig;

DECLARE @FailureCount INT;
SELECT @FailureCount = COUNT(*)
FROM Audit.FailureLog fl
INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
INNER JOIN Audit.LogEventType  evt ON evt.Id = fl.LogEventTypeId
WHERE let.Code = N'LocationTypeDef'
  AND evt.Code = N'Deprecated';

-- At least 3 failure-log rows from tests 3 (FK guard), 4 (not found), 5 (param missing)
DECLARE @HasFailures BIT = CASE WHEN @FailureCount >= 3 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue
    @TestName  = N'Audit FailureLog: at least 3 rejection rows',
    @Condition = @HasFailures;
GO

-- =============================================
-- Cleanup: remove the deprecated test definition + its (deprecated) children
-- =============================================
DECLARE @CreatedId BIGINT = (SELECT Id FROM Location.LocationTypeDefinition WHERE Code = N'TestDepDef');
IF @CreatedId IS NOT NULL
BEGIN
    DELETE FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = @CreatedId;
    DELETE FROM Location.LocationTypeDefinition
    WHERE Id = @CreatedId;
END
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
