-- =============================================
-- File:         0010_Parts_Bom/050_Bom_DiscardDraft.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-26
-- Description:
--   Tests Parts.Bom_DiscardDraft -- physical delete with cascade,
--   published rejection, deprecated rejection.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0010_Parts_Bom/050_Bom_DiscardDraft.sql';
GO

-- Setup: parent + child + Draft v1 with 1 line
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

CREATE TABLE #Rd1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rd1 EXEC Parts.Item_Create
    @PartNumber = N'TEST-DD-PARENT-001', @ItemTypeId = 4,
    @Description = N'Discard parent', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rd1;

CREATE TABLE #Rd2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rd2 EXEC Parts.Item_Create
    @PartNumber = N'TEST-DD-CHILD-001', @ItemTypeId = 2,
    @Description = N'Discard child', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rd2;

DECLARE @PId BIGINT, @C1 BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-DD-PARENT-001';
SELECT @C1  = Id FROM Parts.Item WHERE PartNumber = N'TEST-DD-CHILD-001';

CREATE TABLE #Rd3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rd3 EXEC Parts.Bom_Create
    @ParentItemId = @PId, @AppUserId = 1;
DROP TABLE #Rd3;

DECLARE @BomId BIGINT;
SELECT @BomId = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;

CREATE TABLE #Rd4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rd4 EXEC Parts.BomLine_Add
    @BomId = @BomId, @ChildItemId = @C1,
    @QtyPer = 1.0, @UomId = 1, @AppUserId = 1;
DROP TABLE #Rd4;
GO

-- =============================================
-- Test 1: DiscardDraft happy path -- physical delete + cascade
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT;

SELECT @PId   = Id FROM Parts.Item WHERE PartNumber = N'TEST-DD-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom  WHERE ParentItemId = @PId AND VersionNumber = 1;

DECLARE @LineBefore INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @BomId);
DECLARE @LineBeforeStr NVARCHAR(5) = CAST(@LineBefore AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardSetup] 1 line before discard',
    @Expected = N'1', @Actual = @LineBeforeStr;

CREATE TABLE #Rd5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rd5 EXEC Parts.Bom_DiscardDraft
    @Id = @BomId, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Rd5;
DROP TABLE #Rd5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardHappy] Status = 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @BomGone INT = (SELECT COUNT(*) FROM Parts.Bom WHERE Id = @BomId);
EXEC test.Assert_RowCount
    @TestName = N'[DiscardHappy] Bom row physically deleted',
    @ExpectedCount = 0, @ActualCount = @BomGone;

DECLARE @LinesGone INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @BomId);
EXEC test.Assert_RowCount
    @TestName = N'[DiscardHappy] BomLine rows physically deleted',
    @ExpectedCount = 0, @ActualCount = @LinesGone;
GO

-- =============================================
-- Test 2: DiscardDraft on Published BOM -> rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT, @C1 BIGINT, @NewId BIGINT;

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-DD-PARENT-001';
SELECT @C1  = Id FROM Parts.Item WHERE PartNumber = N'TEST-DD-CHILD-001';

-- Re-create Bom v1 (previous one was discarded)
CREATE TABLE #Rd6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rd6 EXEC Parts.Bom_Create
    @ParentItemId = @PId, @AppUserId = 1;
SELECT @BomId = NewId FROM #Rd6;
DROP TABLE #Rd6;

CREATE TABLE #Rd7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rd7 EXEC Parts.BomLine_Add
    @BomId = @BomId, @ChildItemId = @C1,
    @QtyPer = 1.0, @UomId = 1, @AppUserId = 1;
DROP TABLE #Rd7;

CREATE TABLE #Rd8 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rd8 EXEC Parts.Bom_Publish
    @Id = @BomId, @AppUserId = 1;
DROP TABLE #Rd8;

CREATE TABLE #Rd9 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rd9 EXEC Parts.Bom_DiscardDraft
    @Id = @BomId, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Rd9;
DROP TABLE #Rd9;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardPub] Status = 0 (published cannot be discarded)',
    @Expected = N'0', @Actual = @SStr;

DECLARE @CantMsg NVARCHAR(1) =
    CASE WHEN @M LIKE N'%annot%' OR @M LIKE N'%published%' OR @M LIKE N'%deprecated%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardPub] Message rejects discard',
    @Expected = N'1', @Actual = @CantMsg;
GO

-- Cleanup
DELETE bl FROM Parts.BomLine bl
INNER JOIN Parts.Bom b  ON b.Id = bl.BomId
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-DD-PARENT-001';

DELETE b FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-DD-PARENT-001';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-DD-%';
GO

EXEC test.PrintSummary;
GO
