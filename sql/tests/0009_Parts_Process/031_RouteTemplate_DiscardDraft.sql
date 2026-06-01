-- =============================================
-- File:         0009_Parts_Process/031_RouteTemplate_DiscardDraft.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-20
-- Description:
--   Tests for Parts.RouteTemplate_DiscardDraft (Phase 5).
--   Covers: hard-delete of a Draft (zero steps), hard-delete of a Draft
--   with steps, rejection when Published, rejection when Deprecated,
--   rejection when Id does not exist, and that one ConfigLog row is
--   written per successful discard.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/031_RouteTemplate_DiscardDraft.sql';
GO

-- =============================================
-- Setup: 1 Item, 2 OperationTemplates, 4 RouteTemplates in distinct states.
--   v1: Draft with 0 steps                 → discard target (Test 1)
--   v2: Draft with 2 steps                 → discard target (Test 2)
--   v3: Published with steps               → reject target (Test 3)
--   v4: Deprecated (cloned from v3 then deprecated) → reject target (Test 4)
--
-- Each RouteTemplate has its own Item so the single-Draft-per-Item guard
-- in _CreateNewVersion does not interfere with the multi-version setup.
-- =============================================
DECLARE @ItId1 BIGINT, @ItId2 BIGINT, @ItId3 BIGINT, @ItId4 BIGINT;
DECLARE @Ot1   BIGINT, @Ot2   BIGINT;
DECLARE @S BIT, @M NVARCHAR(500), @NewId BIGINT;

-- Items
CREATE TABLE #Itm (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-DD-ITEM-001',
    @Description = N'DiscardDraft test item 1', @UomId = 1, @AppUserId = 1;
SELECT @ItId1 = NewId FROM #Itm; DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-DD-ITEM-002',
    @Description = N'DiscardDraft test item 2', @UomId = 1, @AppUserId = 1;
SELECT @ItId2 = NewId FROM #Itm; DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-DD-ITEM-003',
    @Description = N'DiscardDraft test item 3', @UomId = 1, @AppUserId = 1;
SELECT @ItId3 = NewId FROM #Itm; DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-DD-ITEM-004',
    @Description = N'DiscardDraft test item 4', @UomId = 1, @AppUserId = 1;
SELECT @ItId4 = NewId FROM #Itm;
DROP TABLE #Itm;

-- OperationTemplates
CREATE TABLE #Ot (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ot EXEC Parts.OperationTemplate_Create
    @Code = N'TEST-DD-OT-1', @Name = N'DD OT 1',
    @AreaLocationId = 3, @AppUserId = 1;
SELECT @Ot1 = NewId FROM #Ot; DELETE FROM #Ot;
INSERT INTO #Ot EXEC Parts.OperationTemplate_Create
    @Code = N'TEST-DD-OT-2', @Name = N'DD OT 2',
    @AreaLocationId = 3, @AppUserId = 1;
SELECT @Ot2 = NewId FROM #Ot;
DROP TABLE #Ot;

-- v1: Draft, zero steps
DECLARE @V1 BIGINT;
CREATE TABLE #Rt (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId1, @Name = N'TEST-DD-RT-001', @AppUserId = 1;
SELECT @V1 = NewId FROM #Rt; DELETE FROM #Rt;

-- v2: Draft, 2 steps
DECLARE @V2 BIGINT;
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId2, @Name = N'TEST-DD-RT-002', @AppUserId = 1;
SELECT @V2 = NewId FROM #Rt; DELETE FROM #Rt;

CREATE TABLE #St (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #St EXEC Parts.RouteStep_Add @RouteTemplateId = @V2, @OperationTemplateId = @Ot1, @AppUserId = 1;
DELETE FROM #St;
INSERT INTO #St EXEC Parts.RouteStep_Add @RouteTemplateId = @V2, @OperationTemplateId = @Ot2, @AppUserId = 1;
DROP TABLE #St;

-- v3: Published, 1 step
DECLARE @V3 BIGINT;
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId3, @Name = N'TEST-DD-RT-003', @AppUserId = 1;
SELECT @V3 = NewId FROM #Rt; DELETE FROM #Rt;

CREATE TABLE #StP (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #StP EXEC Parts.RouteStep_Add @RouteTemplateId = @V3, @OperationTemplateId = @Ot1, @AppUserId = 1;
DROP TABLE #StP;

CREATE TABLE #Pub (Status BIT, Message NVARCHAR(500));
INSERT INTO #Pub EXEC Parts.RouteTemplate_Publish @Id = @V3, @AppUserId = 1;
DROP TABLE #Pub;

-- v4: Deprecated. Create + Publish + Deprecate (Deprecate accepts only
-- non-deprecated rows; a Draft cannot be deprecated directly through the
-- Deprecate proc per its NOT NULL guard? Test the helper). To keep this
-- simple: publish-then-deprecate.
DECLARE @V4 BIGINT;
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId4, @Name = N'TEST-DD-RT-004', @AppUserId = 1;
SELECT @V4 = NewId FROM #Rt;
DROP TABLE #Rt;

CREATE TABLE #StD (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #StD EXEC Parts.RouteStep_Add @RouteTemplateId = @V4, @OperationTemplateId = @Ot1, @AppUserId = 1;
DROP TABLE #StD;

CREATE TABLE #PubD (Status BIT, Message NVARCHAR(500));
INSERT INTO #PubD EXEC Parts.RouteTemplate_Publish @Id = @V4, @AppUserId = 1;
DROP TABLE #PubD;

CREATE TABLE #DepD (Status BIT, Message NVARCHAR(500));
INSERT INTO #DepD EXEC Parts.RouteTemplate_Deprecate @Id = @V4, @AppUserId = 1;
DROP TABLE #DepD;
GO

-- =============================================
-- Test 1: DiscardDraft hard-deletes a Draft with zero steps
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @V1 BIGINT;
SELECT @V1 = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-DD-RT-001';

CREATE TABLE #Dd1 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Dd1 EXEC Parts.RouteTemplate_DiscardDraft @Id = @V1, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Dd1;
DROP TABLE #Dd1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardZeroSteps] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @GoneCount INT = (SELECT COUNT(*) FROM Parts.RouteTemplate WHERE Id = @V1);
EXEC test.Assert_RowCount
    @TestName      = N'[DiscardZeroSteps] Header row hard-deleted',
    @ExpectedCount = 0,
    @ActualCount   = @GoneCount;
GO

-- =============================================
-- Test 2: DiscardDraft hard-deletes a Draft with steps (cascade)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @V2 BIGINT;
SELECT @V2 = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-DD-RT-002';

DECLARE @BeforeSteps INT = (SELECT COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @V2);
DECLARE @BeforeStepsStr NVARCHAR(20) = CAST(@BeforeSteps AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardWithSteps] Setup: v2 has 2 steps pre-discard',
    @Expected = N'2',
    @Actual   = @BeforeStepsStr;

CREATE TABLE #Dd2 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Dd2 EXEC Parts.RouteTemplate_DiscardDraft @Id = @V2, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Dd2;
DROP TABLE #Dd2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardWithSteps] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @HdrGone INT = (SELECT COUNT(*) FROM Parts.RouteTemplate WHERE Id = @V2);
EXEC test.Assert_RowCount
    @TestName      = N'[DiscardWithSteps] Header row hard-deleted',
    @ExpectedCount = 0,
    @ActualCount   = @HdrGone;

DECLARE @StepsGone INT = (SELECT COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @V2);
EXEC test.Assert_RowCount
    @TestName      = N'[DiscardWithSteps] Step rows hard-deleted',
    @ExpectedCount = 0,
    @ActualCount   = @StepsGone;

-- One ConfigLog row written under EventCode='Deleted' for this entity
DECLARE @LogCount INT = (
    SELECT COUNT(*) FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEventType et ON et.Id = cl.LogEventTypeId
    INNER JOIN Audit.LogEntityType nt ON nt.Id = cl.LogEntityTypeId
    WHERE cl.EntityId = @V2 AND et.Code = N'Deleted' AND nt.Code = N'Route'
);
EXEC test.Assert_RowCount
    @TestName      = N'[DiscardWithSteps] ConfigLog row written with EventCode=Deleted',
    @ExpectedCount = 1,
    @ActualCount   = @LogCount;

-- Audit-readability: Description follows SUBJECT . Route v1 (Draft) . Discarded; K steps discarded
DECLARE @DdDesc NVARCHAR(2000), @DdOld NVARCHAR(MAX);
SELECT TOP 1 @DdDesc = cl.Description, @DdOld = cl.OldValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType nt ON nt.Id = cl.LogEntityTypeId
INNER JOIN Audit.LogEventType et  ON et.Id = cl.LogEventTypeId
WHERE cl.EntityId = @V2 AND nt.Code = N'Route' AND et.Code = N'Deleted'
ORDER BY cl.Id DESC;

DECLARE @DdDescOk NVARCHAR(1) = CASE
    WHEN @DdDesc LIKE N'TEST-DD-ITEM-002%Route v1 (Draft)%Discarded; 2 steps discarded%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardWithSteps] Description matches convention shape',
    @Expected = N'1',
    @Actual   = @DdDescOk;

DECLARE @DdFkOk NVARCHAR(1) = CASE
    WHEN @DdOld LIKE N'%"OperationTemplate"%' AND @DdOld LIKE N'%"Item"%"PartNumber":"TEST-DD-ITEM-002"%'
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardWithSteps] OldValue carries resolved Item + OperationTemplate FKs',
    @Expected = N'1',
    @Actual   = @DdFkOk;
GO

-- =============================================
-- Test 3: DiscardDraft rejects a Published RouteTemplate
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @V3 BIGINT;
SELECT @V3 = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-DD-RT-003';

CREATE TABLE #Dd3 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Dd3 EXEC Parts.RouteTemplate_DiscardDraft @Id = @V3, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Dd3;
DROP TABLE #Dd3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardPublished] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @PubMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%Published%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardPublished] Message names Published',
    @Expected = N'1',
    @Actual   = @PubMsg;

DECLARE @StillThere INT = (SELECT COUNT(*) FROM Parts.RouteTemplate WHERE Id = @V3);
EXEC test.Assert_RowCount
    @TestName      = N'[DiscardPublished] Published row preserved',
    @ExpectedCount = 1,
    @ActualCount   = @StillThere;
GO

-- =============================================
-- Test 4: DiscardDraft rejects a Deprecated RouteTemplate
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @V4 BIGINT;
SELECT @V4 = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-DD-RT-004';

CREATE TABLE #Dd4 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Dd4 EXEC Parts.RouteTemplate_DiscardDraft @Id = @V4, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Dd4;
DROP TABLE #Dd4;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardDeprecated] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- v4 is BOTH Published (then Deprecated), so the Published guard fires first.
-- The semantic point: a non-Draft row is rejected. Accept either rejection message.
DECLARE @DepMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%deprecated%' OR @M LIKE N'%Published%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardDeprecated] Message rejects non-Draft (deprecated/Published)',
    @Expected = N'1',
    @Actual   = @DepMsg;
GO

-- =============================================
-- Test 5: DiscardDraft rejects a non-existent Id
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);

CREATE TABLE #Dd5 (Status BIT, Message NVARCHAR(500));
INSERT INTO #Dd5 EXEC Parts.RouteTemplate_DiscardDraft @Id = 9999999, @AppUserId = 1;
SELECT @S = Status, @M = Message FROM #Dd5;
DROP TABLE #Dd5;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardMissing] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @NotFoundMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%not found%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[DiscardMissing] Message names not-found',
    @Expected = N'1',
    @Actual   = @NotFoundMsg;
GO

-- =============================================
-- Cleanup
-- =============================================
DELETE rs
FROM Parts.RouteStep rs
INNER JOIN Parts.RouteTemplate rt ON rt.Id = rs.RouteTemplateId
INNER JOIN Parts.Item it          ON it.Id = rt.ItemId
WHERE it.PartNumber LIKE N'TEST-DD-ITEM-%';

DELETE rt
FROM Parts.RouteTemplate rt
INNER JOIN Parts.Item it ON it.Id = rt.ItemId
WHERE it.PartNumber LIKE N'TEST-DD-ITEM-%';

DELETE FROM Parts.OperationTemplate WHERE Code LIKE N'TEST-DD-OT-%';
DELETE FROM Parts.Item              WHERE PartNumber LIKE N'TEST-DD-ITEM-%';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
