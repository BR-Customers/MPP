-- =============================================
-- File:         0010_Parts_Bom/030_Bom_SaveDraft.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-26
-- Description:
--   Tests for Parts.Bom_SaveDraft -- bundled line reconciliation.
--   Covers add/edit/remove/reorder lines on a Draft Bom, the
--   published-rejection guard, deprecated-rejection guard,
--   self-reference rejection, missing-field rejection,
--   invalid UomId rejection.
--
--   Pre-conditions:
--     - Migrations 0001-0015 applied
--     - AppUser Id=1 exists
--     - Parts.ItemType and Parts.Uom seeds present
-- =============================================

EXEC test.BeginTestFile @FileName = N'0010_Parts_Bom/030_Bom_SaveDraft.sql';
GO

-- =============================================
-- Setup: parent + 4 child Items + Draft Bom v1
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

CREATE TABLE #Rs1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rs1 EXEC Parts.Item_Create
    @PartNumber = N'TEST-SD-PARENT-001', @ItemTypeId = 4,
    @Description = N'SaveDraft parent', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rs1;

CREATE TABLE #Rs2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rs2 EXEC Parts.Item_Create
    @PartNumber = N'TEST-SD-CHILD-001', @ItemTypeId = 2,
    @Description = N'SD child 1', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rs2;

CREATE TABLE #Rs3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rs3 EXEC Parts.Item_Create
    @PartNumber = N'TEST-SD-CHILD-002', @ItemTypeId = 2,
    @Description = N'SD child 2', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rs3;

CREATE TABLE #Rs4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rs4 EXEC Parts.Item_Create
    @PartNumber = N'TEST-SD-CHILD-003', @ItemTypeId = 2,
    @Description = N'SD child 3', @UomId = 1, @AppUserId = 1;
DROP TABLE #Rs4;

DECLARE @PId BIGINT;
SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';

CREATE TABLE #Rs5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rs5 EXEC Parts.Bom_Create
    @ParentItemId = @PId, @AppUserId = 1;
DROP TABLE #Rs5;
GO

-- =============================================
-- Test 1: SaveDraft adds 2 brand-new lines on empty draft
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT, @C1 BIGINT, @C2 BIGINT, @NewId BIGINT,
        @LinesJson NVARCHAR(MAX);

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;
SELECT @C1 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-CHILD-001';
SELECT @C2 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-CHILD-002';

SET @LinesJson = N'[' +
    N'{"Id":null,"ChildItemId":' + CAST(@C1 AS NVARCHAR(20)) + N',"QtyPer":1.0,"UomId":1},' +
    N'{"Id":null,"ChildItemId":' + CAST(@C2 AS NVARCHAR(20)) + N',"QtyPer":2.0,"UomId":1}' +
N']';

CREATE TABLE #Ru1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ru1 EXEC Parts.Bom_SaveDraft
    @Id = @BomId, @EffectiveFrom = '2026-08-01',
    @LinesJson = @LinesJson, @AppUserId = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Ru1;
DROP TABLE #Ru1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftAdd] Status = 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @LineCount INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @BomId);
EXEC test.Assert_RowCount
    @TestName = N'[SaveDraftAdd] 2 lines inserted',
    @ExpectedCount = 2, @ActualCount = @LineCount;

-- SortOrder should be 1, 2 (from RowIndex)
DECLARE @SOrders NVARCHAR(50) =
    (SELECT STRING_AGG(CAST(SortOrder AS NVARCHAR(5)), N',') WITHIN GROUP (ORDER BY SortOrder)
     FROM Parts.BomLine WHERE BomId = @BomId);
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftAdd] SortOrder 1,2',
    @Expected = N'1,2', @Actual = @SOrders;
GO

-- =============================================
-- Test 2: SaveDraft re-saves with edits + reorder + removal
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT, @C1 BIGINT, @C2 BIGINT, @C3 BIGINT,
        @L1 BIGINT, @L2 BIGINT, @NewId BIGINT, @LinesJson NVARCHAR(MAX);

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;
SELECT @C1 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-CHILD-001';
SELECT @C2 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-CHILD-002';
SELECT @C3 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-CHILD-003';

SELECT @L1 = Id FROM Parts.BomLine WHERE BomId = @BomId AND ChildItemId = @C1;
SELECT @L2 = Id FROM Parts.BomLine WHERE BomId = @BomId AND ChildItemId = @C2;

-- Reorder: L2 first, then L1 with updated qty, then a new C3 line.
SET @LinesJson = N'[' +
    N'{"Id":' + CAST(@L2 AS NVARCHAR(20)) + N',"ChildItemId":' + CAST(@C2 AS NVARCHAR(20)) + N',"QtyPer":2.0,"UomId":1},' +
    N'{"Id":' + CAST(@L1 AS NVARCHAR(20)) + N',"ChildItemId":' + CAST(@C1 AS NVARCHAR(20)) + N',"QtyPer":42.5,"UomId":1},' +
    N'{"Id":null,"ChildItemId":' + CAST(@C3 AS NVARCHAR(20)) + N',"QtyPer":3.0,"UomId":1}' +
N']';

CREATE TABLE #Ru2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ru2 EXEC Parts.Bom_SaveDraft
    @Id = @BomId, @EffectiveFrom = '2026-08-15',
    @LinesJson = @LinesJson, @AppUserId = 1;
SELECT @S = Status, @M = Message, @NewId = NewId FROM #Ru2;
DROP TABLE #Ru2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftEdit] Status = 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @TotalLines INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @BomId);
EXEC test.Assert_RowCount
    @TestName = N'[SaveDraftEdit] 3 lines after add',
    @ExpectedCount = 3, @ActualCount = @TotalLines;

DECLARE @L2Sort INT;
SELECT @L2Sort = SortOrder FROM Parts.BomLine WHERE Id = @L2;
DECLARE @L2SortStr NVARCHAR(5) = CAST(@L2Sort AS NVARCHAR(5));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftEdit] L2 reordered to SortOrder=1',
    @Expected = N'1', @Actual = @L2SortStr;

DECLARE @L1Qty DECIMAL(10,4);
SELECT @L1Qty = QtyPer FROM Parts.BomLine WHERE Id = @L1;
DECLARE @L1QtyStr NVARCHAR(20) = CAST(@L1Qty AS NVARCHAR(20));
DECLARE @ExpQtyStr NVARCHAR(20) = CAST(CAST(42.5 AS DECIMAL(10,4)) AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftEdit] L1 QtyPer updated to 42.5',
    @Expected = @ExpQtyStr, @Actual = @L1QtyStr;

DECLARE @EffFromStr NVARCHAR(30);
SELECT @EffFromStr = CONVERT(NVARCHAR(30), EffectiveFrom, 121) FROM Parts.Bom WHERE Id = @BomId;
DECLARE @ExpEffStr NVARCHAR(30) = CONVERT(NVARCHAR(30), CAST('2026-08-15' AS DATETIME2(3)), 121);
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftEdit] EffectiveFrom updated',
    @Expected = @ExpEffStr, @Actual = @EffFromStr;
GO

-- =============================================
-- Test 3: SaveDraft with line removed (physical delete)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT, @C2 BIGINT, @L2 BIGINT,
        @NewId BIGINT, @LinesJson NVARCHAR(MAX);

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;
SELECT @C2 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-CHILD-002';
SELECT @L2 = Id FROM Parts.BomLine WHERE BomId = @BomId AND ChildItemId = @C2;

-- Only one line remains in payload: L2.
SET @LinesJson = N'[{"Id":' + CAST(@L2 AS NVARCHAR(20)) +
                 N',"ChildItemId":' + CAST(@C2 AS NVARCHAR(20)) +
                 N',"QtyPer":2.0,"UomId":1}]';

CREATE TABLE #Ru3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ru3 EXEC Parts.Bom_SaveDraft
    @Id = @BomId, @EffectiveFrom = '2026-08-15',
    @LinesJson = @LinesJson, @AppUserId = 1;
SELECT @S = Status FROM #Ru3;
DROP TABLE #Ru3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftRemove] Status = 1',
    @Expected = N'1', @Actual = @SStr;

DECLARE @After INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @BomId);
EXEC test.Assert_RowCount
    @TestName = N'[SaveDraftRemove] 1 line remains after physical delete',
    @ExpectedCount = 1, @ActualCount = @After;
GO

-- =============================================
-- Test 4: SaveDraft on Published Bom rejected
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @BomId BIGINT, @NewId BIGINT, @PubMsg NVARCHAR(1);

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';
SELECT @BomId = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;

-- First publish v1 (it has a line by now)
CREATE TABLE #Rp (Status BIT, Message NVARCHAR(500));
INSERT INTO #Rp EXEC Parts.Bom_Publish
    @Id = @BomId, @AppUserId = 1;
DROP TABLE #Rp;

-- Now attempt SaveDraft on published v1
CREATE TABLE #Ru4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ru4 EXEC Parts.Bom_SaveDraft
    @Id = @BomId, @EffectiveFrom = '2026-09-01',
    @LinesJson = N'[]', @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru4;
DROP TABLE #Ru4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftPub] Status = 0 (published immutable)',
    @Expected = N'0', @Actual = @SStr;

SET @PubMsg = CASE WHEN @M LIKE N'%published%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftPub] Message contains "published"',
    @Expected = N'1', @Actual = @PubMsg;
GO

-- =============================================
-- Test 5: SaveDraft -- self-reference rejection (ChildItemId = ParentItemId)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @V2Id BIGINT, @NewId BIGINT, @LinesJson NVARCHAR(MAX);

SELECT @PId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';

-- Create v2 draft via CreateNewVersion
CREATE TABLE #Rc (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @V1Id BIGINT;
SELECT @V1Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 1;
INSERT INTO #Rc EXEC Parts.Bom_CreateNewVersion
    @ParentBomId = @V1Id, @AppUserId = 1;
SELECT @V2Id = NewId FROM #Rc;
DROP TABLE #Rc;

-- Self-reference: child = parent
SET @LinesJson = N'[{"Id":null,"ChildItemId":' + CAST(@PId AS NVARCHAR(20)) +
                 N',"QtyPer":1.0,"UomId":1}]';

CREATE TABLE #Ru5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ru5 EXEC Parts.Bom_SaveDraft
    @Id = @V2Id, @EffectiveFrom = '2026-09-01',
    @LinesJson = @LinesJson, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru5;
DROP TABLE #Ru5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftSelfRef] Status = 0',
    @Expected = N'0', @Actual = @SStr;

DECLARE @SelfMsg NVARCHAR(1) =
    CASE WHEN @M LIKE N'%self%' OR @M LIKE N'%parent%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftSelfRef] Message indicates self-reference',
    @Expected = N'1', @Actual = @SelfMsg;
GO

-- =============================================
-- Test 6: SaveDraft -- missing required field (ChildItemId null)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @V2Id BIGINT, @LinesJson NVARCHAR(MAX);

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';
SELECT @V2Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 2;

SET @LinesJson = N'[{"Id":null,"ChildItemId":null,"QtyPer":1.0,"UomId":1}]';

CREATE TABLE #Ru6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ru6 EXEC Parts.Bom_SaveDraft
    @Id = @V2Id, @EffectiveFrom = '2026-09-01',
    @LinesJson = @LinesJson, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru6;
DROP TABLE #Ru6;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftMissingChild] Status = 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Test 7: SaveDraft -- invalid UomId
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1),
        @PId BIGINT, @V2Id BIGINT, @C1 BIGINT, @LinesJson NVARCHAR(MAX);

SELECT @PId  = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-PARENT-001';
SELECT @V2Id = Id FROM Parts.Bom WHERE ParentItemId = @PId AND VersionNumber = 2;
SELECT @C1   = Id FROM Parts.Item WHERE PartNumber = N'TEST-SD-CHILD-001';

SET @LinesJson = N'[{"Id":null,"ChildItemId":' + CAST(@C1 AS NVARCHAR(20)) +
                 N',"QtyPer":1.0,"UomId":999999}]';

CREATE TABLE #Ru7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ru7 EXEC Parts.Bom_SaveDraft
    @Id = @V2Id, @EffectiveFrom = '2026-09-01',
    @LinesJson = @LinesJson, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Ru7;
DROP TABLE #Ru7;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SaveDraftBadUom] Status = 0',
    @Expected = N'0', @Actual = @SStr;
GO

-- =============================================
-- Cleanup
-- =============================================
DELETE bl FROM Parts.BomLine bl
INNER JOIN Parts.Bom b  ON b.Id = bl.BomId
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-SD-PARENT-001';

DELETE b FROM Parts.Bom b
INNER JOIN Parts.Item p ON p.Id = b.ParentItemId
WHERE p.PartNumber = N'TEST-SD-PARENT-001';

DELETE FROM Parts.Item WHERE PartNumber LIKE N'TEST-SD-%';
GO

EXEC test.PrintSummary;
GO
