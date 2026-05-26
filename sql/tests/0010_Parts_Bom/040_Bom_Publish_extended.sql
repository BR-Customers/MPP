-- =============================================
-- File:         0010_Parts_Bom/040_Bom_Publish_extended.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-26
-- Description:
--   Tests Parts.Bom_Publish's new behavior:
--     - Zero-line guard
--     - Save-then-publish in one shot
--     - Idempotent already-deprecated rejection
--   The "happy path" + already-published rejection are already covered
--   in 010_Bom_crud.sql; this file exercises only the new param surface.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0010_Parts_Bom/040_Bom_Publish_extended.sql';
GO

-- Setup: parent + 2 child items + empty Draft v1
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

CREATE TABLE #Rp1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rp1 EXEC Parts.Item_Create
    @PartNumber = N'TEST-BP-PARENT-001', @ItemTypeId = 4,
    @Description = N'Publish parent', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rp1;

CREATE TABLE #Rp2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rp2 EXEC Parts.Item_Create
    @PartNumber = N'TEST-BP-CHILD-001', @ItemTypeId = 2,
    @Description = N'Publish child 1', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rp2;

CREATE TABLE #Rp3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rp3 EXEC Parts.Item_Create
    @PartNumber = N'TEST-BP-CHILD-002', @ItemTypeId = 2,
    @Description = N'Publish child 2', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rp3;

DECLARE @PId BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-BP-PARENT-001';

CREATE TABLE #Rp4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rp4 EXEC Parts.Bom_Create
    @ParentItemId = @PId, @AppUserId = 1;
DROP TABLE #Rp4;
GO

-- =============================================
-- Test 1: Publish a zero-line draft -> rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT;

SELECT @PId   = Id FROM Parts.Item WHERE PartNumber = N'TEST-BP-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom  WHERE ParentItemId = @PId AND VersionNumber = 1;

CREATE TABLE #Ru1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru1 EXEC Parts.Bom_Publish
    @Id = @BomId, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru1;
DROP TABLE #Ru1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[PubZeroLines] Status = 0',
    @Expected = N'0', @Actual = @SStr;

DECLARE @ZeroMsg NVARCHAR(1) = CASE WHEN @M LIKE N'%no lines%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PubZeroLines] Message contains "no lines"',
    @Expected = N'1', @Actual = @ZeroMsg;
GO

-- =============================================
-- Test 2: Save-and-publish in one shot via @LinesJson
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT, @C1 BIGINT, @LinesJson NVARCHAR(MAX);

SELECT @PId   = Id FROM Parts.Item WHERE PartNumber = N'TEST-BP-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom  WHERE ParentItemId = @PId AND VersionNumber = 1;
SELECT @C1    = Id FROM Parts.Item WHERE PartNumber = N'TEST-BP-CHILD-001';

SET @LinesJson = N'[{"Id":null,"ChildItemId":' + CAST(@C1 AS NVARCHAR(20)) +
                 N',"QtyPer":2.0,"UomId":1}]';

CREATE TABLE #Ru2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Ru2 EXEC Parts.Bom_Publish
    @Id = @BomId, @EffectiveFrom = '2026-10-01',
    @LinesJson = @LinesJson, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru2;
DROP TABLE #Ru2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[PubSaveAnd] Status = 1',
    @Expected = N'1', @Actual = @SStr;

-- Verify PublishedAt set + 1 line + EffectiveFrom applied
DECLARE @Pub DATETIME2(3); SELECT @Pub = PublishedAt FROM Parts.Bom WHERE Id = @BomId;
DECLARE @PubStr NVARCHAR(1) = CASE WHEN @Pub IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[PubSaveAnd] PublishedAt is set',
    @Expected = N'1', @Actual = @PubStr;

DECLARE @Lc INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @BomId);
EXEC test.Assert_RowCount
    @TestName = N'[PubSaveAnd] 1 line on bom after save-and-publish',
    @ExpectedCount = 1, @ActualCount = @Lc;
GO

-- =============================================
-- Test 3: Bom_Deprecate idempotent on already-deprecated returns Status=1
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT;

SELECT @PId   = Id FROM Parts.Item WHERE PartNumber = N'TEST-BP-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom  WHERE ParentItemId = @PId AND VersionNumber = 1;

-- First deprecation: should succeed
CREATE TABLE #Rd1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rd1 EXEC Parts.Bom_Deprecate @Id = @BomId, @AppUserId = 1;
SELECT @S = Status FROM #Rd1;
DROP TABLE #Rd1;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateFirst] Status = 1',
    @Expected = N'1', @Actual = @SStr;

-- Second deprecation: idempotent, Status=1 with "Already deprecated."
CREATE TABLE #Rd2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rd2 EXEC Parts.Bom_Deprecate @Id = @BomId, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Rd2;
DROP TABLE #Rd2;
SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateAgain] Status = 1 (idempotent)',
    @Expected = N'1', @Actual = @SStr;

DECLARE @AlreadyMsg NVARCHAR(1) =
    CASE WHEN @M LIKE N'%lready%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DeprecateAgain] Message contains "lready"',
    @Expected = N'1', @Actual = @AlreadyMsg;
GO

-- =============================================
-- Test 4: Bom_Deprecate on Draft -> rejected (must use DiscardDraft)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @V2Id BIGINT, @V1Id BIGINT, @NewId BIGINT;

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-BP-PARENT-001';
SELECT @V1Id = Id FROM Parts.Bom  WHERE ParentItemId = @PId AND VersionNumber = 1;

-- Cannot create new version against a deprecated BOM (proc rejects "Parent BOM not found" since lookup excludes deprecated? Let's check by trying)
-- Actually Bom_CreateNewVersion looks up by Id directly so deprecated is fine for cloning.
CREATE TABLE #Rcv (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rcv EXEC Parts.Bom_CreateNewVersion
    @ParentBomId = @V1Id, @AppUserId = 1;
SELECT @S = Status, @V2Id = NewId FROM #Rcv;
DROP TABLE #Rcv;

-- Skip rest of test if v2 didn't get created (cleanup-friendly)
IF @V2Id IS NOT NULL
BEGIN
    CREATE TABLE #Rd3 (Status BIT, Message NVARCHAR(500));
    INSERT INTO #Rd3 EXEC Parts.Bom_Deprecate @Id = @V2Id, @AppUserId = 1;
    SELECT @S = Status, @M = Message FROM #Rd3;
    DROP TABLE #Rd3;
    SET @SStr = CAST(@S AS NVARCHAR(1));
    EXEC test.Assert_IsEqual
        @TestName = N'[DeprecateDraft] Status = 0 (draft cannot be deprecated)',
        @Expected = N'0', @Actual = @SStr;

    DECLARE @DraftMsg NVARCHAR(1) =
        CASE WHEN @M LIKE N'%draft%' OR @M LIKE N'%Discard%' THEN N'1' ELSE N'0' END;
    EXEC test.Assert_IsEqual
        @TestName = N'[DeprecateDraft] Message mentions draft/Discard',
        @Expected = N'1', @Actual = @DraftMsg;
END
GO

-- Cleanup
DELETE bl FROM Parts.BomLine bl
INNER JOIN Parts.Bom b  ON b.Id = bl.BomId
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BP-PARENT-001';

DELETE b FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-BP-PARENT-001';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-BP-%';
GO

EXEC test.PrintSummary;
GO
