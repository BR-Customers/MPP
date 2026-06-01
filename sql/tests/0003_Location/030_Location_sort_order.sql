-- =============================================
-- File:         0003_Location/030_Location_sort_order.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-13
-- Description:
--   Tests for Location MoveUp/MoveDown procs.
--   Covers: initial SortOrder, swap operations, no-op at boundaries,
--   null/invalid Id handling, and audit trail verification.
--
--   Pre-conditions:
--     - Migration 0002 applied (LocationType + LocationTypeDefinition rows)
--     - Location CRUD procs deployed (Location_Create used for test data)
--     - Location_MoveUp and Location_MoveDown procs deployed
--     - Bootstrap user Id=1 exists
--     - No Location rows are pre-seeded — tests create their own
-- =============================================

EXEC test.BeginTestFile @FileName = N'0003_Location/030_Location_sort_order.sql';
GO

-- =============================================
-- Setup: Create parent + 3 children (A, B, C) with SortOrder 1, 2, 3
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @ParentId BIGINT, @IdA BIGINT, @IdB BIGINT, @IdC BIGINT;

-- Create Enterprise root as parent
CREATE TABLE #RS1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RS1
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 1,
    @ParentLocationId         = NULL,
    @Name                     = N'Sort Test Enterprise',
    @Code                     = N'SORT-ENT',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @ParentId = NewId FROM #RS1;
DROP TABLE #RS1;

-- Create Site as parent for our 3 test children
DECLARE @SiteId BIGINT;
CREATE TABLE #RS2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RS2
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 2,
    @ParentLocationId         = @ParentId,
    @Name                     = N'Sort Test Site',
    @Code                     = N'SORT-SITE',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @SiteId = NewId FROM #RS2;
DROP TABLE #RS2;

-- Child A (SortOrder=1)
CREATE TABLE #RS3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RS3
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 3,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Child A',
    @Code                     = N'SORT-A',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @IdA = NewId FROM #RS3;
DROP TABLE #RS3;

-- Child B (SortOrder=2)
CREATE TABLE #RS4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RS4
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 3,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Child B',
    @Code                     = N'SORT-B',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @IdB = NewId FROM #RS4;
DROP TABLE #RS4;

-- Child C (SortOrder=3)
CREATE TABLE #RS5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RS5
EXEC Location.Location_Create
    @LocationTypeDefinitionId = 3,
    @ParentLocationId         = @SiteId,
    @Name                     = N'Child C',
    @Code                     = N'SORT-C',
    @AppUserId                = 1;
SELECT @S = Status, @M = Message, @IdC = NewId FROM #RS5;
DROP TABLE #RS5;
GO

-- =============================================
-- Test 1: Verify initial SortOrder — A=1, B=2, C=3
-- =============================================
DECLARE @SortA INT, @SortB INT, @SortC INT;
SELECT @SortA = SortOrder FROM Location.Location WHERE Code = N'SORT-A';
SELECT @SortB = SortOrder FROM Location.Location WHERE Code = N'SORT-B';
SELECT @SortC = SortOrder FROM Location.Location WHERE Code = N'SORT-C';

DECLARE @SortAStr NVARCHAR(10) = CAST(@SortA AS NVARCHAR(10));
DECLARE @SortBStr NVARCHAR(10) = CAST(@SortB AS NVARCHAR(10));
DECLARE @SortCStr NVARCHAR(10) = CAST(@SortC AS NVARCHAR(10));

EXEC test.Assert_IsEqual
    @TestName = N'Initial SortOrder: A=1',
    @Expected = N'1',
    @Actual   = @SortAStr;

EXEC test.Assert_IsEqual
    @TestName = N'Initial SortOrder: B=2',
    @Expected = N'2',
    @Actual   = @SortBStr;

EXEC test.Assert_IsEqual
    @TestName = N'Initial SortOrder: C=3',
    @Expected = N'3',
    @Actual   = @SortCStr;
GO

-- =============================================
-- Test 2: MoveDown A — A swaps with B → A=2, B=1, C=3
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @IdA BIGINT;
SELECT @IdA = Id FROM Location.Location WHERE Code = N'SORT-A';

CREATE TABLE #RM1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RM1
EXEC Location.Location_MoveDown
    @Id        = @IdA,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RM1;
DROP TABLE #RM1;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'MoveDown A: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'MoveDown A: message is success',
    @Expected = N'Moved down successfully.',
    @Actual   = @M;

-- Verify new positions: A=2, B=1, C=3
DECLARE @SortA INT, @SortB INT, @SortC INT;
SELECT @SortA = SortOrder FROM Location.Location WHERE Code = N'SORT-A';
SELECT @SortB = SortOrder FROM Location.Location WHERE Code = N'SORT-B';
SELECT @SortC = SortOrder FROM Location.Location WHERE Code = N'SORT-C';

DECLARE @SortAStr NVARCHAR(10) = CAST(@SortA AS NVARCHAR(10));
DECLARE @SortBStr NVARCHAR(10) = CAST(@SortB AS NVARCHAR(10));
DECLARE @SortCStr NVARCHAR(10) = CAST(@SortC AS NVARCHAR(10));

EXEC test.Assert_IsEqual
    @TestName = N'After MoveDown A: A=2',
    @Expected = N'2',
    @Actual   = @SortAStr;

EXEC test.Assert_IsEqual
    @TestName = N'After MoveDown A: B=1',
    @Expected = N'1',
    @Actual   = @SortBStr;

EXEC test.Assert_IsEqual
    @TestName = N'After MoveDown A: C=3',
    @Expected = N'3',
    @Actual   = @SortCStr;
GO

-- =============================================
-- Test 3: MoveUp C — C swaps with A (now at 2) → B=1, C=2, A=3
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @IdC BIGINT;
SELECT @IdC = Id FROM Location.Location WHERE Code = N'SORT-C';

CREATE TABLE #RM2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RM2
EXEC Location.Location_MoveUp
    @Id        = @IdC,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RM2;
DROP TABLE #RM2;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'MoveUp C: status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'MoveUp C: message is success',
    @Expected = N'Moved up successfully.',
    @Actual   = @M;

-- Verify new positions: B=1, C=2, A=3
DECLARE @SortA INT, @SortB INT, @SortC INT;
SELECT @SortA = SortOrder FROM Location.Location WHERE Code = N'SORT-A';
SELECT @SortB = SortOrder FROM Location.Location WHERE Code = N'SORT-B';
SELECT @SortC = SortOrder FROM Location.Location WHERE Code = N'SORT-C';

DECLARE @SortAStr NVARCHAR(10) = CAST(@SortA AS NVARCHAR(10));
DECLARE @SortBStr NVARCHAR(10) = CAST(@SortB AS NVARCHAR(10));
DECLARE @SortCStr NVARCHAR(10) = CAST(@SortC AS NVARCHAR(10));

EXEC test.Assert_IsEqual
    @TestName = N'After MoveUp C: B=1',
    @Expected = N'1',
    @Actual   = @SortBStr;

EXEC test.Assert_IsEqual
    @TestName = N'After MoveUp C: C=2',
    @Expected = N'2',
    @Actual   = @SortCStr;

EXEC test.Assert_IsEqual
    @TestName = N'After MoveUp C: A=3',
    @Expected = N'3',
    @Actual   = @SortAStr;
GO

-- =============================================
-- Test 4: MoveUp B (already first) — no-op, Status=1
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @IdB BIGINT;
SELECT @IdB = Id FROM Location.Location WHERE Code = N'SORT-B';

-- Verify B is currently at SortOrder=1
DECLARE @SortBBefore INT;
SELECT @SortBBefore = SortOrder FROM Location.Location WHERE Code = N'SORT-B';

CREATE TABLE #RM3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RM3
EXEC Location.Location_MoveUp
    @Id        = @IdB,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RM3;
DROP TABLE #RM3;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'MoveUp B (already first): status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'MoveUp B (already first): message is no-op',
    @Expected = N'Already at the top position.',
    @Actual   = @M;

-- Verify SortOrder unchanged
DECLARE @SortBAfter INT;
SELECT @SortBAfter = SortOrder FROM Location.Location WHERE Code = N'SORT-B';
DECLARE @SortBAfterStr NVARCHAR(10) = CAST(@SortBAfter AS NVARCHAR(10));
DECLARE @SortBBeforeStr NVARCHAR(10) = CAST(@SortBBefore AS NVARCHAR(10));

EXEC test.Assert_IsEqual
    @TestName = N'MoveUp B (already first): SortOrder unchanged',
    @Expected = @SortBBeforeStr,
    @Actual   = @SortBAfterStr;
GO

-- =============================================
-- Test 5: MoveDown A (already last) — no-op, Status=1
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);
DECLARE @IdA BIGINT;
SELECT @IdA = Id FROM Location.Location WHERE Code = N'SORT-A';

-- Verify A is currently at SortOrder=3 (last)
DECLARE @SortABefore INT;
SELECT @SortABefore = SortOrder FROM Location.Location WHERE Code = N'SORT-A';

CREATE TABLE #RM4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RM4
EXEC Location.Location_MoveDown
    @Id        = @IdA,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RM4;
DROP TABLE #RM4;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'MoveDown A (already last): status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'MoveDown A (already last): message is no-op',
    @Expected = N'Already at the bottom position.',
    @Actual   = @M;

-- Verify SortOrder unchanged
DECLARE @SortAAfter INT;
SELECT @SortAAfter = SortOrder FROM Location.Location WHERE Code = N'SORT-A';
DECLARE @SortAAfterStr NVARCHAR(10) = CAST(@SortAAfter AS NVARCHAR(10));
DECLARE @SortABeforeStr NVARCHAR(10) = CAST(@SortABefore AS NVARCHAR(10));

EXEC test.Assert_IsEqual
    @TestName = N'MoveDown A (already last): SortOrder unchanged',
    @Expected = @SortABeforeStr,
    @Actual   = @SortAAfterStr;
GO

-- =============================================
-- Test 6: MoveUp with NULL Id — Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);

CREATE TABLE #RM5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RM5
EXEC Location.Location_MoveUp
    @Id        = NULL,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RM5;
DROP TABLE #RM5;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'MoveUp NULL Id: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'MoveUp NULL Id: message says required parameter',
    @Expected = N'Required parameter missing.',
    @Actual   = @M;
GO

-- =============================================
-- Test 7: MoveUp with non-existent Id — Status=0
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500);

CREATE TABLE #RM6 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RM6
EXEC Location.Location_MoveUp
    @Id        = 999999,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RM6;
DROP TABLE #RM6;

DECLARE @SStr NVARCHAR(1) = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'MoveUp non-existent Id: status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

EXEC test.Assert_IsEqual
    @TestName = N'MoveUp non-existent Id: message says not found',
    @Expected = N'Location not found or deprecated.',
    @Actual   = @M;
GO

-- =============================================
-- Test 8: Audit trail — verify ConfigLog entries for move operations
--   Description now follows the audit-readability convention:
--     Location <Code> · Reordered from #<old> to #<new> [within <ParentCode>]
-- =============================================
DECLARE @MoveAuditCount INT;
SELECT @MoveAuditCount = COUNT(*)
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Location'
  AND cl.Description LIKE N'Location % Reordered from #% to #%';

-- We performed 2 successful moves: MoveDown A (Test 2) and MoveUp C (Test 3)
DECLARE @HasMoveAudit NVARCHAR(1) = CASE WHEN @MoveAuditCount >= 2 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'Audit trail: at least 2 ConfigLog entries for move operations',
    @Expected = N'1',
    @Actual   = @HasMoveAudit;
GO

-- =============================================
-- Test 9: Audit-readability — most-recent move Description matches the
--   Reordered convention shape, and resolved JSON carries FK sub-objects.
-- =============================================
DECLARE @LastMoveDesc NVARCHAR(500), @LastMoveOld NVARCHAR(MAX), @LastMoveNew NVARCHAR(MAX);
SELECT TOP 1
       @LastMoveDesc = cl.Description,
       @LastMoveOld  = cl.OldValue,
       @LastMoveNew  = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
WHERE let.Code = N'Location'
  AND cl.Description LIKE N'Location % Reordered from #% to #%'
ORDER BY cl.Id DESC;

EXEC test.Assert_Contains
    @TestName    = N'Move audit: Description matches Reordered convention',
    @HaystackStr = @LastMoveDesc,
    @NeedleStr   = N'Reordered from #';

EXEC test.Assert_Contains
    @TestName    = N'Move audit: NewValue JSON carries LocationTypeDefinition FK sub-object',
    @HaystackStr = @LastMoveNew,
    @NeedleStr   = N'"LocationTypeDefinition":{';

EXEC test.Assert_Contains
    @TestName    = N'Move audit: NewValue JSON carries Parent FK sub-object',
    @HaystackStr = @LastMoveNew,
    @NeedleStr   = N'"Parent":{';
GO

-- =============================================
-- Cleanup: remove test data to restore clean state
-- =============================================
DELETE FROM Location.Location WHERE Code IN (N'SORT-A', N'SORT-B', N'SORT-C');
DELETE FROM Location.Location WHERE Code = N'SORT-SITE';
DELETE FROM Location.Location WHERE Code = N'SORT-ENT';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
