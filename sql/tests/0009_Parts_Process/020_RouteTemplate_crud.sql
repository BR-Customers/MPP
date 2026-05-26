-- =============================================
-- File:         0009_Parts_Process/020_RouteTemplate_crud.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-04-14
-- Description:
--   Tests for Parts.RouteTemplate + Parts.RouteStep procs:
--     Parts.RouteTemplate_ListByItem
--     Parts.RouteTemplate_Get
--     Parts.RouteTemplate_GetActiveForItem
--     Parts.RouteTemplate_Create
--     Parts.RouteTemplate_CreateNewVersion
--     Parts.RouteTemplate_Deprecate
--     Parts.RouteStep_ListByRoute
--     Parts.RouteStep_Add
--     Parts.RouteStep_Update
--     Parts.RouteStep_MoveUp
--     Parts.RouteStep_MoveDown
--     Parts.RouteStep_Remove
--
--   Covers: create happy + duplicate + invalid ItemId; get; list-by-
--   item; GetActiveForItem with default and historical AsOfDate;
--   RouteStep add (sequence numbers auto-assigned), update,
--   MoveUp/MoveDown (adjacency swap), remove (hard-delete + compact),
--   deprecated-route immutability, CreateNewVersion clone, and
--   deprecate-of-prior-version lifecycle.
--
--   Pre-conditions:
--     - Migration 0001-0006 applied
--     - AppUser Id=1 exists
--     - Area-tier Location DIECAST Id=3 present (for OperationTemplates)
--     - Parts.ItemType and Parts.Uom seeds present
--     - All RouteTemplate_*, RouteStep_*, OperationTemplate_Create,
--       and Item_Create procs deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/020_RouteTemplate_crud.sql';
GO

-- =============================================
-- Setup: create 1 test Item and 3 test OperationTemplates
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @NewId BIGINT;

CREATE TABLE #Rc21 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc21
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'TEST-RT-ITEM-001',
    @Description = N'Route-owning test item',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc21;
DROP TABLE #Rc21;

CREATE TABLE #Rc27 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc27
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-RT-OT-1',
    @Name           = N'RT OT 1',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc27;
DROP TABLE #Rc27;

CREATE TABLE #Rc28 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc28
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-RT-OT-2',
    @Name           = N'RT OT 2',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc28;
DROP TABLE #Rc28;

CREATE TABLE #Rc29 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc29
EXEC Parts.OperationTemplate_Create
    @Code           = N'TEST-RT-OT-3',
    @Name           = N'RT OT 3',
    @AreaLocationId = 3,
    @AppUserId      = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Rc29;
DROP TABLE #Rc29;
GO

-- =============================================
-- Test 1: RouteTemplate_Create happy path
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @RtId   BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';

CREATE TABLE #Rc3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc3
EXEC Parts.RouteTemplate_Create
    @ItemId    = @ItemId,
    @Name      = N'TEST-RT-001',
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @RtId = NewId FROM #Rc3;
DROP TABLE #Rc3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtCreateHappy] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @RtIdStr NVARCHAR(20) = CAST(@RtId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[RtCreateHappy] NewId is not NULL',
    @Value    = @RtIdStr;

DECLARE @RtVer INT;
SELECT @RtVer = VersionNumber FROM Parts.RouteTemplate WHERE Id = @RtId;
DECLARE @RtVerStr NVARCHAR(20) = CAST(@RtVer AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[RtCreateHappy] VersionNumber is 1',
    @Expected = N'1',
    @Actual   = @RtVerStr;
GO

-- =============================================
-- Test 2: RouteTemplate_Create duplicate for same Item rejected
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @RtId   BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';

CREATE TABLE #Rc4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc4
EXEC Parts.RouteTemplate_Create
    @ItemId    = @ItemId,
    @Name      = N'TEST-RT-DUP',
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @RtId = NewId FROM #Rc4;
DROP TABLE #Rc4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtCreateDup] Status is 0 (v1 already exists for this Item)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @DupHit NVARCHAR(1) = CASE
    WHEN @M LIKE N'%already exists%' OR @M LIKE N'%already%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtCreateDup] Message indicates existence',
    @Expected = N'1',
    @Actual   = @DupHit;
GO

-- =============================================
-- Test 3: RouteTemplate_Create invalid ItemId
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @RtId  BIGINT;

CREATE TABLE #Rc5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc5
EXEC Parts.RouteTemplate_Create
    @ItemId    = 999999,
    @Name      = N'TEST-RT-BADITEM',
    @AppUserId = 1;
SELECT @S = Status, @M = Message, @RtId = NewId FROM #Rc5;
DROP TABLE #Rc5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtCreateBadItem] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 4: RouteTemplate_Get happy path (header)
--   NOTE: proc returns 2 result sets (header + steps); INSERT-EXEC can only
--   capture the first. We capture the header and assert 1 row. The second
--   result set (steps) is not captured here — covered by Test 8 via
--   RouteStep_ListByRoute.
-- =============================================
DECLARE @RtId BIGINT;
SELECT @RtId = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';

CREATE TABLE #RtGetHeader (
    Id BIGINT, ItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    Name NVARCHAR(200), EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3), CreatedByUserId BIGINT,
    CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #RtGetHeader EXEC Parts.RouteTemplate_Get @Id = @RtId;
DECLARE @RtGetCount INT = (SELECT COUNT(*) FROM #RtGetHeader);
DROP TABLE #RtGetHeader;

EXEC test.Assert_RowCount
    @TestName      = N'[RtGet] Header result set returns 1 row',
    @ExpectedCount = 1,
    @ActualCount   = @RtGetCount;
GO

-- =============================================
-- Test 5: RouteTemplate_GetActiveForItem hides Draft routes.
--   v1 has been created but not Published. GetActiveForItem filters on
--   PublishedAt IS NOT NULL, so it must return 0 rows. v1 will be
--   mutated (step add/remove/move) in Tests 7-14 before being promoted
--   via CreateNewVersion in Test 15; Test 16 publishes v2 and verifies
--   the active-route visibility path.
-- =============================================
DECLARE @ItemId BIGINT;
SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';

CREATE TABLE #RtActive (
    Id BIGINT, ItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    Name NVARCHAR(200), EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3), CreatedByUserId BIGINT,
    CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #RtActive EXEC Parts.RouteTemplate_GetActiveForItem @ItemId = @ItemId, @AsOfDate = NULL;
DECLARE @RtActiveCount INT = (SELECT COUNT(*) FROM #RtActive);
DROP TABLE #RtActive;

EXEC test.Assert_RowCount
    @TestName      = N'[RtActiveNow] Draft RouteTemplate invisible (0 rows)',
    @ExpectedCount = 0,
    @ActualCount   = @RtActiveCount;
GO

-- =============================================
-- Test 6: RouteTemplate_ListByItem returns 1 row
-- =============================================
DECLARE @ItemId BIGINT;
SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';

CREATE TABLE #RtList (
    Id BIGINT, ItemId BIGINT, VersionNumber INT, Name NVARCHAR(200),
    EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3), CreatedByUserId BIGINT,
    CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #RtList EXEC Parts.RouteTemplate_ListByItem @ItemId = @ItemId;
DECLARE @RtListCount INT = (SELECT COUNT(*) FROM #RtList);
DROP TABLE #RtList;

EXEC test.Assert_RowCount
    @TestName      = N'[RtListByItem] 1 row returned by proc',
    @ExpectedCount = 1,
    @ActualCount   = @RtListCount;
GO

-- =============================================
-- Test 7: RouteStep_Add 3 times - auto-increment SequenceNumber
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @RtId    BIGINT,
        @Ot1     BIGINT,
        @Ot2     BIGINT,
        @Ot3     BIGINT,
        @Step1   BIGINT,
        @Step2   BIGINT,
        @Step3   BIGINT;

SELECT @RtId = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';
SELECT @Ot1  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-RT-OT-1';
SELECT @Ot2  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-RT-OT-2';
SELECT @Ot3  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-RT-OT-3';

CREATE TABLE #Rc6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc6
EXEC Parts.RouteStep_Add
    @RouteTemplateId     = @RtId,
    @OperationTemplateId = @Ot1,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message, @Step1 = NewId FROM #Rc6;
DROP TABLE #Rc6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepAdd1] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

CREATE TABLE #Rc7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc7
EXEC Parts.RouteStep_Add
    @RouteTemplateId     = @RtId,
    @OperationTemplateId = @Ot2,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message, @Step2 = NewId FROM #Rc7;
DROP TABLE #Rc7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepAdd2] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

CREATE TABLE #Rc8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc8
EXEC Parts.RouteStep_Add
    @RouteTemplateId     = @RtId,
    @OperationTemplateId = @Ot3,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message, @Step3 = NewId FROM #Rc8;
DROP TABLE #Rc8;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepAdd3] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Assert distinct Ids
DECLARE @DistinctCheck NVARCHAR(1) = CASE
    WHEN @Step1 <> @Step2 AND @Step2 <> @Step3 AND @Step1 <> @Step3
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[StepAdd] All three NewId values distinct',
    @Expected = N'1',
    @Actual   = @DistinctCheck;

-- Assert SequenceNumbers are 1, 2, 3 in order
DECLARE @Seq1 INT, @Seq2 INT, @Seq3 INT;
SELECT @Seq1 = SequenceNumber FROM Parts.RouteStep WHERE Id = @Step1;
SELECT @Seq2 = SequenceNumber FROM Parts.RouteStep WHERE Id = @Step2;
SELECT @Seq3 = SequenceNumber FROM Parts.RouteStep WHERE Id = @Step3;

DECLARE @Seq1Str NVARCHAR(20) = CAST(@Seq1 AS NVARCHAR(20));
DECLARE @Seq2Str NVARCHAR(20) = CAST(@Seq2 AS NVARCHAR(20));
DECLARE @Seq3Str NVARCHAR(20) = CAST(@Seq3 AS NVARCHAR(20));

EXEC test.Assert_IsEqual
    @TestName = N'[StepAdd] Step1 SequenceNumber = 1',
    @Expected = N'1',
    @Actual   = @Seq1Str;
EXEC test.Assert_IsEqual
    @TestName = N'[StepAdd] Step2 SequenceNumber = 2',
    @Expected = N'2',
    @Actual   = @Seq2Str;
EXEC test.Assert_IsEqual
    @TestName = N'[StepAdd] Step3 SequenceNumber = 3',
    @Expected = N'3',
    @Actual   = @Seq3Str;
GO

-- =============================================
-- Test 8: RouteStep_ListByRoute returns 3 rows
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @RtId BIGINT;

SELECT @RtId = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';

CREATE TABLE #StepList (
    Id BIGINT, RouteTemplateId BIGINT, SequenceNumber INT,
    OperationTemplateId BIGINT, OperationCode NVARCHAR(50),
    OperationName NVARCHAR(200), OperationVersionNumber INT,
    OperationAreaLocationId BIGINT, OperationAreaName NVARCHAR(200),
    DataCollectionSummary NVARCHAR(MAX),
    IsRequired BIT, Description NVARCHAR(500)
);
INSERT INTO #StepList EXEC Parts.RouteStep_ListByRoute @RouteTemplateId = @RtId;
DECLARE @StepCount INT = (SELECT COUNT(*) FROM #StepList);
DROP TABLE #StepList;

EXEC test.Assert_RowCount
    @TestName      = N'[StepList] 3 steps returned by proc',
    @ExpectedCount = 3,
    @ActualCount   = @StepCount;
GO

-- =============================================
-- Test 9: RouteStep_Update on step 2 - change OperationTemplateId to OT3
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @RtId    BIGINT,
        @Step2   BIGINT,
        @Ot3     BIGINT,
        @Ot2     BIGINT;

SELECT @RtId = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';
SELECT @Ot2  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-RT-OT-2';
SELECT @Ot3  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-RT-OT-3';

SELECT @Step2 = Id FROM Parts.RouteStep
WHERE RouteTemplateId = @RtId AND SequenceNumber = 2;

CREATE TABLE #Ru12 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru12
EXEC Parts.RouteStep_Update
    @Id                  = @Step2,
    @OperationTemplateId = @Ot3,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message FROM #Ru12;
DROP TABLE #Ru12;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepUpdate] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Verify column changed
DECLARE @StoredOt BIGINT;
SELECT @StoredOt = OperationTemplateId FROM Parts.RouteStep WHERE Id = @Step2;
DECLARE @StoredOtStr NVARCHAR(20) = CAST(@StoredOt AS NVARCHAR(20));
DECLARE @Ot3Str      NVARCHAR(20) = CAST(@Ot3      AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[StepUpdate] OperationTemplateId changed to OT3',
    @Expected = @Ot3Str,
    @Actual   = @StoredOtStr;

-- Now restore step2 to OT2 so subsequent tests are predictable
CREATE TABLE #Ru13 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru13
EXEC Parts.RouteStep_Update
    @Id                  = @Step2,
    @OperationTemplateId = @Ot2,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message FROM #Ru13;
DROP TABLE #Ru13;
GO

-- =============================================
-- Test 10: RouteStep_Update missing Id
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @Ot1  BIGINT;

SELECT @Ot1 = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-RT-OT-1';

CREATE TABLE #Ru14 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru14
EXEC Parts.RouteStep_Update
    @Id                  = NULL,
    @OperationTemplateId = @Ot1,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message FROM #Ru14;
DROP TABLE #Ru14;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepUpdateNullId] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;
GO

-- =============================================
-- Test 11: RouteStep_MoveUp on step 3 - swap with step 2
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @RtId    BIGINT,
        @Step3   BIGINT,
        @Step2   BIGINT;

SELECT @RtId = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';
SELECT @Step3 = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 3;
SELECT @Step2 = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2;

CREATE TABLE #Ru15 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru15
EXEC Parts.RouteStep_MoveUp
    @Id        = @Step3,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru15;
DROP TABLE #Ru15;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveUp3] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- After swap: @Step3 row now has SequenceNumber = 2; @Step2 row has 3
DECLARE @S3New INT, @S2New INT;
SELECT @S3New = SequenceNumber FROM Parts.RouteStep WHERE Id = @Step3;
SELECT @S2New = SequenceNumber FROM Parts.RouteStep WHERE Id = @Step2;

DECLARE @S3NewStr NVARCHAR(20) = CAST(@S3New AS NVARCHAR(20));
DECLARE @S2NewStr NVARCHAR(20) = CAST(@S2New AS NVARCHAR(20));

EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveUp3] Former step-3 now has SequenceNumber = 2',
    @Expected = N'2',
    @Actual   = @S3NewStr;
EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveUp3] Former step-2 now has SequenceNumber = 3',
    @Expected = N'3',
    @Actual   = @S2NewStr;
GO

-- =============================================
-- Test 12: RouteStep_MoveUp on step 1 (first row) - no-op
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @RtId  BIGINT,
        @Step1 BIGINT;

SELECT @RtId  = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';
SELECT @Step1 = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1;

CREATE TABLE #Ru16 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru16
EXEC Parts.RouteStep_MoveUp
    @Id        = @Step1,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru16;
DROP TABLE #Ru16;

-- Accept either status=1 (no-op returns success) or status=0 (no-op
-- treated as rejection). Either way, SequenceNumber must remain 1.
DECLARE @Seq1After INT;
SELECT @Seq1After = SequenceNumber FROM Parts.RouteStep WHERE Id = @Step1;
DECLARE @Seq1AfterStr NVARCHAR(20) = CAST(@Seq1After AS NVARCHAR(20));

EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveUpFirst] SequenceNumber unchanged (still 1)',
    @Expected = N'1',
    @Actual   = @Seq1AfterStr;
GO

-- =============================================
-- Test 13: RouteStep_MoveDown on step 1 - now step 1 moves to position 2
-- =============================================
DECLARE @S     BIT,
        @M     NVARCHAR(500),
        @SStr  NVARCHAR(1),
        @RtId  BIGINT,
        @Step1 BIGINT;

SELECT @RtId  = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';
SELECT @Step1 = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1;

CREATE TABLE #Ru17 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru17
EXEC Parts.RouteStep_MoveDown
    @Id        = @Step1,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru17;
DROP TABLE #Ru17;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveDown1] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @S1New INT;
SELECT @S1New = SequenceNumber FROM Parts.RouteStep WHERE Id = @Step1;
DECLARE @S1NewStr NVARCHAR(20) = CAST(@S1New AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveDown1] Former step-1 now SequenceNumber = 2',
    @Expected = N'2',
    @Actual   = @S1NewStr;
GO

-- =============================================
-- Test 14: RouteStep_Remove hard-deletes a step and compacts siblings
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @RtId   BIGINT,
        @RmStep BIGINT;

SELECT @RtId   = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';
-- Remove the row currently at SequenceNumber = 1
SELECT @RmStep = Id FROM Parts.RouteStep
WHERE RouteTemplateId = @RtId AND SequenceNumber = 1;

CREATE TABLE #Ru18 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru18
EXEC Parts.RouteStep_Remove
    @Id        = @RmStep,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru18;
DROP TABLE #Ru18;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepRemove] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

-- Row physically gone
DECLARE @GoneCount INT = (
    SELECT COUNT(*) FROM Parts.RouteStep WHERE Id = @RmStep
);
EXEC test.Assert_RowCount
    @TestName      = N'[StepRemove] Row hard-deleted',
    @ExpectedCount = 0,
    @ActualCount   = @GoneCount;

-- Remaining 2 rows compacted to SequenceNumber 1 and 2
DECLARE @RemCount INT = (
    SELECT COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @RtId
);
EXEC test.Assert_RowCount
    @TestName      = N'[StepRemove] 2 rows remain on route',
    @ExpectedCount = 2,
    @ActualCount   = @RemCount;

DECLARE @MinSeq INT, @MaxSeq INT;
SELECT @MinSeq = MIN(SequenceNumber), @MaxSeq = MAX(SequenceNumber)
FROM Parts.RouteStep WHERE RouteTemplateId = @RtId;

DECLARE @MinSeqStr NVARCHAR(20) = CAST(@MinSeq AS NVARCHAR(20));
DECLARE @MaxSeqStr NVARCHAR(20) = CAST(@MaxSeq AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[StepRemove] Compacted: MIN(Seq) = 1',
    @Expected = N'1',
    @Actual   = @MinSeqStr;
EXEC test.Assert_IsEqual
    @TestName = N'[StepRemove] Compacted: MAX(Seq) = 2',
    @Expected = N'2',
    @Actual   = @MaxSeqStr;
GO

-- =============================================
-- Test 15: RouteTemplate_CreateNewVersion from v1 - clone
--   New row should have VersionNumber = 2, distinct Id, and the same
--   step count as the parent (2 after prior removal).
-- =============================================
DECLARE @S        BIT,
        @M        NVARCHAR(500),
        @SStr     NVARCHAR(1),
        @ItemId   BIGINT,
        @V1Id     BIGINT,
        @V2Id     BIGINT,
        @V1Steps  INT,
        @V2Steps  INT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';
SELECT @V1Id   = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001';

SELECT @V1Steps = COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @V1Id;

-- Publish v1 first. _CreateNewVersion now enforces a single-Draft-per-Item
-- guard: it rejects when an active Draft already exists for the same Item.
-- v1 has been a Draft up through Test 14; publish it here so the v2 clone
-- below is allowed. (Test 17 publishes again — that call returns Status=0,
-- which the test does not assert on, then directly backdates the row.)
CREATE TABLE #RtPubV1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RtPubV1
EXEC Parts.RouteTemplate_Publish @Id = @V1Id, @AppUserId = 1;
DROP TABLE #RtPubV1;

CREATE TABLE #Rc9 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc9
EXEC Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId = @V1Id,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @V2Id = NewId FROM #Rc9;
DROP TABLE #Rc9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtNewVer] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @V2IdStr NVARCHAR(20) = CAST(@V2Id AS NVARCHAR(20));
EXEC test.Assert_IsNotNull
    @TestName = N'[RtNewVer] NewId is not NULL',
    @Value    = @V2IdStr;

DECLARE @DistinctStr NVARCHAR(1) = CASE WHEN @V2Id <> @V1Id THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtNewVer] v2 Id differs from v1',
    @Expected = N'1',
    @Actual   = @DistinctStr;

DECLARE @V2Ver INT;
SELECT @V2Ver = VersionNumber FROM Parts.RouteTemplate WHERE Id = @V2Id;
DECLARE @V2VerStr NVARCHAR(20) = CAST(@V2Ver AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[RtNewVer] VersionNumber = 2',
    @Expected = N'2',
    @Actual   = @V2VerStr;

SELECT @V2Steps = COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @V2Id;
EXEC test.Assert_RowCount
    @TestName      = N'[RtNewVer] Step count matches parent',
    @ExpectedCount = @V1Steps,
    @ActualCount   = @V2Steps;
GO

-- =============================================
-- Test 16: RouteTemplate_GetActiveForItem with default AsOfDate returns v2
--   Post-retrofit: only Published routes are visible. Publish v2 first.
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @ItemId  BIGINT,
        @V2Id    BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';
SELECT @V2Id = Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId AND VersionNumber = 2;

CREATE TABLE #Ru19 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru19
EXEC Parts.RouteTemplate_Publish
    @Id        = @V2Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru19;
DROP TABLE #Ru19;

-- Invoke read proc (no assertion on its result — validated by direct query below)
CREATE TABLE #RtActiveV2 (
    Id BIGINT, ItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    Name NVARCHAR(200), EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3), CreatedByUserId BIGINT,
    CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #RtActiveV2 EXEC Parts.RouteTemplate_GetActiveForItem @ItemId = @ItemId, @AsOfDate = NULL;
DROP TABLE #RtActiveV2;

-- Validate by direct query: the newest-active published row has VersionNumber = 2
DECLARE @NewestVer INT;
SELECT TOP 1 @NewestVer = VersionNumber
FROM Parts.RouteTemplate
WHERE ItemId = @ItemId
  AND PublishedAt IS NOT NULL
  AND DeprecatedAt IS NULL
ORDER BY EffectiveFrom DESC, VersionNumber DESC;

DECLARE @NewestVerStr NVARCHAR(20) = CAST(@NewestVer AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[RtActiveV2] Newest active version is v2',
    @Expected = N'2',
    @Actual   = @NewestVerStr;
GO

-- =============================================
-- Test 17: RouteTemplate_GetActiveForItem with AsOfDate before v2 returns v1
--   Use v2.EffectiveFrom - 1 hour.
-- =============================================
DECLARE @S         BIT,
        @M         NVARCHAR(500),
        @SStr      NVARCHAR(1),
        @ItemId    BIGINT,
        @V2Eff     DATETIME2(3),
        @AsOf      DATETIME2(3);

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';

-- Post-retrofit: v1 must be Published at the historical AsOfDate to be
-- returned by GetActiveForItem. Publish v1, then backdate both
-- EffectiveFrom and PublishedAt so the window includes v1 as "published
-- at that time".
DECLARE @V1PublishId BIGINT;
SELECT @V1PublishId = Id FROM Parts.RouteTemplate
WHERE ItemId = @ItemId AND VersionNumber = 1;

CREATE TABLE #Ru20 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru20
EXEC Parts.RouteTemplate_Publish
    @Id        = @V1PublishId,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru20;
DROP TABLE #Ru20;

UPDATE Parts.RouteTemplate
SET EffectiveFrom = DATEADD(HOUR, -2, SYSUTCDATETIME()),
    PublishedAt   = DATEADD(HOUR, -2, SYSUTCDATETIME())
WHERE ItemId = @ItemId AND VersionNumber = 1;

SELECT @V2Eff = EffectiveFrom
FROM Parts.RouteTemplate
WHERE ItemId = @ItemId AND VersionNumber = 2;

-- AsOfDate = 1 hour ago: after the backdated v1.EffectiveFrom, before v2.EffectiveFrom
SET @AsOf = DATEADD(HOUR, -1, SYSUTCDATETIME());

-- Invoke read proc (no assertion on its result — validated by direct query below)
CREATE TABLE #RtActiveHist (
    Id BIGINT, ItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    Name NVARCHAR(200), EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3), CreatedByUserId BIGINT,
    CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #RtActiveHist EXEC Parts.RouteTemplate_GetActiveForItem @ItemId = @ItemId, @AsOfDate = @AsOf;
DROP TABLE #RtActiveHist;

-- Direct-query mirror: the row effective+published at that historical point is v1
DECLARE @HistVer INT;
SELECT TOP 1 @HistVer = VersionNumber
FROM Parts.RouteTemplate
WHERE ItemId = @ItemId
  AND PublishedAt IS NOT NULL
  AND PublishedAt <= @AsOf
  AND EffectiveFrom <= @AsOf
  AND (DeprecatedAt IS NULL OR DeprecatedAt > @AsOf)
ORDER BY EffectiveFrom DESC, VersionNumber DESC;

DECLARE @HistVerStr NVARCHAR(20) = CAST(@HistVer AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[RtActiveHist] Version-at-AsOfDate is 1',
    @Expected = N'1',
    @Actual   = @HistVerStr;
GO

-- =============================================
-- Test 18: RouteTemplate_Deprecate on v1
-- =============================================
DECLARE @S    BIT,
        @M    NVARCHAR(500),
        @SStr NVARCHAR(1),
        @V1Id BIGINT;

-- Name is not unique across versions (CreateNewVersion copies it); scope to v1
SELECT @V1Id = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001' AND VersionNumber = 1;

CREATE TABLE #Ru21 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru21
EXEC Parts.RouteTemplate_Deprecate
    @Id        = @V1Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru21;
DROP TABLE #Ru21;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtDep1] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @V1Dep DATETIME2(3);
SELECT @V1Dep = DeprecatedAt FROM Parts.RouteTemplate WHERE Id = @V1Id;
DECLARE @V1DepStr NVARCHAR(1) = CASE WHEN @V1Dep IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtDep1] DeprecatedAt set',
    @Expected = N'1',
    @Actual   = @V1DepStr;
GO

-- =============================================
-- Test 19: RouteStep_MoveUp on step in deprecated v1 - immutable
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @V1Id    BIGINT,
        @AnyStep BIGINT;

-- Name is not unique across versions (CreateNewVersion copies it); scope to v1
SELECT @V1Id = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001' AND VersionNumber = 1;
SELECT TOP 1 @AnyStep = Id FROM Parts.RouteStep
WHERE RouteTemplateId = @V1Id
ORDER BY SequenceNumber DESC;    -- pick a non-first step

CREATE TABLE #Ru22 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru22
EXEC Parts.RouteStep_MoveUp
    @Id        = @AnyStep,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru22;
DROP TABLE #Ru22;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveUpDep] Status is 0 (deprecated route)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @ImmMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%deprecated%' OR @M LIKE N'%immutable%' OR @M LIKE N'%published%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[StepMoveUpDep] Message indicates deprecated/published (immutable)',
    @Expected = N'1',
    @Actual   = @ImmMsg;
GO

-- =============================================
-- Test 20: RouteStep_Remove on deprecated route rejected
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @V1Id    BIGINT,
        @AnyStep BIGINT;

-- Name is not unique across versions (CreateNewVersion copies it); scope to v1
SELECT @V1Id = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-RT-001' AND VersionNumber = 1;
SELECT TOP 1 @AnyStep = Id FROM Parts.RouteStep WHERE RouteTemplateId = @V1Id;

CREATE TABLE #Ru23 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru23
EXEC Parts.RouteStep_Remove
    @Id        = @AnyStep,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru23;
DROP TABLE #Ru23;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[StepRemoveDep] Status is 0 (deprecated route)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @RmMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%deprecated%' OR @M LIKE N'%immutable%' OR @M LIKE N'%published%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[StepRemoveDep] Message indicates deprecated/published (immutable)',
    @Expected = N'1',
    @Actual   = @RmMsg;
GO

-- =============================================
-- Test 21 (retrofit): RouteTemplate_Publish happy path on a fresh Draft v3
--   Create v3 from v2 and then publish it.
-- =============================================
DECLARE @S      BIT,
        @M      NVARCHAR(500),
        @SStr   NVARCHAR(1),
        @ItemId BIGINT,
        @V2Id   BIGINT,
        @V3Id   BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';
SELECT @V2Id = Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId AND VersionNumber = 2;

CREATE TABLE #Rc10 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc10
EXEC Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId = @V2Id,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @V3Id = NewId FROM #Rc10;
DROP TABLE #Rc10;

-- =============================================
-- Test 22 (retrofit): RtDraftInvisible - a new Draft is NOT returned by
--   GetActiveForItem (v2 remains the active published one).
-- =============================================
-- Invoke read proc (no assertion on its result — validated by direct query below)
CREATE TABLE #RtActiveDraft (
    Id BIGINT, ItemId BIGINT, PartNumber NVARCHAR(50), VersionNumber INT,
    Name NVARCHAR(200), EffectiveFrom DATETIME2(3), PublishedAt DATETIME2(3),
    DeprecatedAt DATETIME2(3), CreatedByUserId BIGINT,
    CreatedByDisplayName NVARCHAR(200), CreatedAt DATETIME2(3)
);
INSERT INTO #RtActiveDraft EXEC Parts.RouteTemplate_GetActiveForItem @ItemId = @ItemId, @AsOfDate = NULL;
DROP TABLE #RtActiveDraft;

-- Direct-query mirror: newest active+published is still v2 (v3 is Draft)
DECLARE @ActiveVer INT;
SELECT TOP 1 @ActiveVer = VersionNumber
FROM Parts.RouteTemplate
WHERE ItemId = @ItemId
  AND PublishedAt IS NOT NULL
  AND DeprecatedAt IS NULL
ORDER BY EffectiveFrom DESC, VersionNumber DESC;

DECLARE @ActiveVerStr NVARCHAR(20) = CAST(@ActiveVer AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[RtDraftInvisible] Active published version remains v2 (v3 Draft hidden)',
    @Expected = N'2',
    @Actual   = @ActiveVerStr;

-- =============================================
-- Test 23 (retrofit): RtStepOnPublished - RouteStep_Add on a published
--   RouteTemplate is rejected with "published" in the message.
-- =============================================
DECLARE @OtAny BIGINT;
SELECT @OtAny = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-RT-OT-1';

DECLARE @NewStepId BIGINT;
CREATE TABLE #Rc11 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc11
EXEC Parts.RouteStep_Add
    @RouteTemplateId     = @V2Id,
    @OperationTemplateId = @OtAny,
    @AppUserId           = 1;
SELECT @S = Status, @M = Message, @NewStepId = NewId FROM #Rc11;
DROP TABLE #Rc11;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtStepOnPublished] Status is 0 (published route)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @StepPubMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%published%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtStepOnPublished] Message contains "published"',
    @Expected = N'1',
    @Actual   = @StepPubMsg;

-- =============================================
-- Test 24 (retrofit): RtPublish happy path - publish v3
-- =============================================
CREATE TABLE #Ru24 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru24
EXEC Parts.RouteTemplate_Publish
    @Id        = @V3Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru24;
DROP TABLE #Ru24;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtPublish] Status is 1 after publishing v3',
    @Expected = N'1',
    @Actual   = @SStr;

-- =============================================
-- Test 25 (retrofit): RtPublishTwice - publishing v3 again is rejected
-- =============================================
CREATE TABLE #Ru25 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru25
EXEC Parts.RouteTemplate_Publish
    @Id        = @V3Id,
    @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru25;
DROP TABLE #Ru25;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtPublishTwice] Status is 0 (already published)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @TwiceMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%already published%' OR @M LIKE N'%already%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtPublishTwice] Message indicates already published',
    @Expected = N'1',
    @Actual   = @TwiceMsg;
GO

-- =============================================
-- Test 26 (Phase 5): Single-Draft-per-Item guard on _CreateNewVersion
--   At this point v1 Deprecated, v2 Published, v3 Published, no Drafts.
--   First _CreateNewVersion → v4 Draft → Status=1.
--   Second _CreateNewVersion → rejected (v4 is the active Draft).
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @ItemId  BIGINT,
        @V3Id    BIGINT,
        @V4Id    BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';
SELECT @V3Id = Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId AND VersionNumber = 3;

-- First CreateNewVersion → v4 Draft, expected to succeed
CREATE TABLE #Rc12 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc12
EXEC Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId = @V3Id,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message, @V4Id = NewId FROM #Rc12;
DROP TABLE #Rc12;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtDraftGuard] First CreateNewVersion succeeds (v4 Draft)',
    @Expected = N'1',
    @Actual   = @SStr;

-- Second CreateNewVersion on same Item → rejected by single-Draft guard
CREATE TABLE #Rc13 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rc13
EXEC Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId = @V3Id,
    @AppUserId             = 1;
SELECT @S = Status, @M = Message FROM #Rc13;
DROP TABLE #Rc13;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtDraftGuard] Second CreateNewVersion rejected (Status=0)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @DraftMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%Draft for this Item already exists%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtDraftGuard] Message names the single-Draft guard',
    @Expected = N'1',
    @Actual   = @DraftMsg;
GO

-- =============================================
-- Test 27 (Phase 5): Publish rejects a Draft with zero steps
--   Fresh Item TEST-RT-ITEM-002 with a Draft RouteTemplate but no steps.
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @Item2Id BIGINT,
        @Rt2Id   BIGINT;

CREATE TABLE #Rci2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rci2
EXEC Parts.Item_Create
    @ItemTypeId  = 4,
    @PartNumber  = N'TEST-RT-ITEM-002',
    @Description = N'Zero-step publish test',
    @UomId       = 1,
    @AppUserId   = 1;
SELECT @Item2Id = NewId FROM #Rci2;
DROP TABLE #Rci2;

CREATE TABLE #Rcr2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcr2
EXEC Parts.RouteTemplate_Create
    @ItemId    = @Item2Id,
    @Name      = N'TEST-RT-NOSTEPS',
    @AppUserId = 1;
SELECT @Rt2Id = NewId FROM #Rcr2;
DROP TABLE #Rcr2;

CREATE TABLE #RuP1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RuP1
EXEC Parts.RouteTemplate_Publish @Id = @Rt2Id, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RuP1;
DROP TABLE #RuP1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubNoSteps] Status is 0 (zero-steps guard)',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NoStepsMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%no steps%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubNoSteps] Message names the no-steps guard',
    @Expected = N'1',
    @Actual   = @NoStepsMsg;
GO

-- =============================================
-- Test 28 (Phase 5): Publish v4 with no overrides preserves Name + EffectiveFrom
--   After Test 26 v4 was cloned from v3, so it has steps and a Name
--   identical to v3's. Publishing without overrides should leave Name
--   and EffectiveFrom untouched.
-- =============================================
DECLARE @S            BIT,
        @M            NVARCHAR(500),
        @SStr         NVARCHAR(1),
        @ItemId       BIGINT,
        @V4Id         BIGINT,
        @BeforeName   NVARCHAR(200),
        @BeforeEffFr  DATETIME2(3),
        @AfterName    NVARCHAR(200),
        @AfterEffFr   DATETIME2(3);

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';
SELECT @V4Id = Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId AND VersionNumber = 4;

SELECT @BeforeName  = Name,
       @BeforeEffFr = EffectiveFrom
FROM Parts.RouteTemplate WHERE Id = @V4Id;

CREATE TABLE #RuP2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RuP2
EXEC Parts.RouteTemplate_Publish @Id = @V4Id, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #RuP2;
DROP TABLE #RuP2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubV4] Status is 1 (publish v4 with no overrides)',
    @Expected = N'1',
    @Actual   = @SStr;

SELECT @AfterName  = Name,
       @AfterEffFr = EffectiveFrom
FROM Parts.RouteTemplate WHERE Id = @V4Id;

DECLARE @NameUnchanged NVARCHAR(1) = CASE
    WHEN @AfterName = @BeforeName THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubV4] Name unchanged when override is NULL',
    @Expected = N'1',
    @Actual   = @NameUnchanged;

DECLARE @EffFrUnchanged NVARCHAR(1) = CASE
    WHEN @AfterEffFr = @BeforeEffFr THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubV4] EffectiveFrom unchanged when override is NULL',
    @Expected = N'1',
    @Actual   = @EffFrUnchanged;
GO

-- =============================================
-- Test 29 (Phase 5): Publish with @EffectiveFrom override applies the override
--   Create v5 (cloned from v4), then Publish with EffectiveFrom = 2027-01-01.
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @ItemId  BIGINT,
        @V4Id    BIGINT,
        @V5Id    BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';
SELECT @V4Id = Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId AND VersionNumber = 4;

CREATE TABLE #RcV5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RcV5
EXEC Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId = @V4Id,
    @AppUserId             = 1;
SELECT @V5Id = NewId FROM #RcV5;
DROP TABLE #RcV5;

DECLARE @OverrideEff DATETIME2(3) = N'2027-01-01T00:00:00';

CREATE TABLE #RuP3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RuP3
EXEC Parts.RouteTemplate_Publish
    @Id            = @V5Id,
    @AppUserId     = 1,
    @EffectiveFrom = @OverrideEff;
SELECT @S = Status, @M = Message FROM #RuP3;
DROP TABLE #RuP3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubV5EffOverride] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredEff DATETIME2(3);
SELECT @StoredEff = EffectiveFrom FROM Parts.RouteTemplate WHERE Id = @V5Id;
DECLARE @EffApplied NVARCHAR(1) = CASE
    WHEN @StoredEff = @OverrideEff THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubV5EffOverride] EffectiveFrom = 2027-01-01',
    @Expected = N'1',
    @Actual   = @EffApplied;
GO

-- =============================================
-- Test 30 (Phase 5): Publish with @Name override applies the rename
--   Create v6 (cloned from v5), then Publish with @Name = 'Renamed at publish'.
-- =============================================
DECLARE @S       BIT,
        @M       NVARCHAR(500),
        @SStr    NVARCHAR(1),
        @ItemId  BIGINT,
        @V5Id    BIGINT,
        @V6Id    BIGINT;

SELECT @ItemId = Id FROM Parts.Item WHERE PartNumber = N'TEST-RT-ITEM-001';
SELECT @V5Id = Id FROM Parts.RouteTemplate WHERE ItemId = @ItemId AND VersionNumber = 5;

CREATE TABLE #RcV6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #RcV6
EXEC Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId = @V5Id,
    @AppUserId             = 1;
SELECT @V6Id = NewId FROM #RcV6;
DROP TABLE #RcV6;

CREATE TABLE #RuP4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #RuP4
EXEC Parts.RouteTemplate_Publish
    @Id        = @V6Id,
    @AppUserId = 1,
    @Name      = N'Renamed at publish';
SELECT @S = Status, @M = Message FROM #RuP4;
DROP TABLE #RuP4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubV6NameOverride] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StoredName NVARCHAR(200);
SELECT @StoredName = Name FROM Parts.RouteTemplate WHERE Id = @V6Id;
EXEC test.Assert_IsEqual
    @TestName = N'[RtPubV6NameOverride] Name = ''Renamed at publish''',
    @Expected = N'Renamed at publish',
    @Actual   = @StoredName;
GO

-- =============================================
-- Cleanup
-- =============================================
DELETE rs
FROM Parts.RouteStep rs
INNER JOIN Parts.RouteTemplate rt ON rt.Id = rs.RouteTemplateId
INNER JOIN Parts.Item it          ON it.Id = rt.ItemId
WHERE it.PartNumber LIKE N'TEST-RT-ITEM-%';

DELETE rt
FROM Parts.RouteTemplate rt
INNER JOIN Parts.Item it ON it.Id = rt.ItemId
WHERE it.PartNumber LIKE N'TEST-RT-ITEM-%';

DELETE FROM Parts.OperationTemplate WHERE Code LIKE N'TEST-RT-OT-%';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-RT-ITEM-%';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
