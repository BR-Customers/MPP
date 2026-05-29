-- =============================================
-- File:         0009_Parts_Process/030_RouteTemplate_SaveAll.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-20
-- Description:
--   Tests for Parts.RouteTemplate_SaveAll (Phase 5 bundled Draft save).
--   Covers: empty→3 steps, in-place update with reorder, mixed delete/
--   insert/update reconciliation, rejections on Published / Deprecated /
--   missing OperationTemplateId / stale step Id / NULL required-params,
--   and audit row written on success.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/030_RouteTemplate_SaveAll.sql';
GO

-- =============================================
-- Setup: 4 Items each with their own Drafts, 3 OperationTemplates,
-- and a "deprecated OperationTemplate" for the OT-validation test.
-- =============================================
DECLARE @Ot1 BIGINT, @Ot2 BIGINT, @Ot3 BIGINT, @OtDep BIGINT;
DECLARE @S BIT, @M NVARCHAR(500);

-- Items (one per Draft we'll exercise)
CREATE TABLE #Itm (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-SA-ITEM-001',
    @Description = N'Route bundle item1', @UomId = 1, @AppUserId = 1;
DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-SA-ITEM-002',
    @Description = N'Route bundle item2', @UomId = 1, @AppUserId = 1;
DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-SA-ITEM-003',
    @Description = N'Route bundle item3', @UomId = 1, @AppUserId = 1;
DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-SA-ITEM-004',
    @Description = N'Route bundle item4', @UomId = 1, @AppUserId = 1;
DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-SA-ITEM-005',
    @Description = N'Route bundle item5', @UomId = 1, @AppUserId = 1;
DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-SA-ITEM-006',
    @Description = N'Route bundle item6', @UomId = 1, @AppUserId = 1;
DELETE FROM #Itm;
INSERT INTO #Itm EXEC Parts.Item_Create
    @ItemTypeId = 4, @PartNumber = N'TEST-SA-ITEM-007',
    @Description = N'Route bundle item7', @UomId = 1, @AppUserId = 1;
DROP TABLE #Itm;

-- OperationTemplates: 3 active + 1 to-be-deprecated
CREATE TABLE #Ot (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Ot EXEC Parts.OperationTemplate_Create
    @Code = N'TEST-SA-OT-1', @Name = N'SA OT 1',
    @AreaLocationId = 3, @AppUserId = 1;
SELECT @Ot1 = NewId FROM #Ot; DELETE FROM #Ot;
INSERT INTO #Ot EXEC Parts.OperationTemplate_Create
    @Code = N'TEST-SA-OT-2', @Name = N'SA OT 2',
    @AreaLocationId = 3, @AppUserId = 1;
SELECT @Ot2 = NewId FROM #Ot; DELETE FROM #Ot;
INSERT INTO #Ot EXEC Parts.OperationTemplate_Create
    @Code = N'TEST-SA-OT-3', @Name = N'SA OT 3',
    @AreaLocationId = 3, @AppUserId = 1;
SELECT @Ot3 = NewId FROM #Ot; DELETE FROM #Ot;
DROP TABLE #Ot;
GO

-- =============================================
-- Test 1: SaveAll on fresh Draft (zero steps → 3 steps).
--   Verifies: Status=1, 3 rows inserted, SequenceNumber 1/2/3.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @ItId BIGINT, @RtId BIGINT;
DECLARE @Ot1 BIGINT, @Ot2 BIGINT, @Ot3 BIGINT;

SELECT @ItId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SA-ITEM-001';
SELECT @Ot1  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-1';
SELECT @Ot2  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-2';
SELECT @Ot3  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-3';

CREATE TABLE #Rt (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId, @Name = N'TEST-SA-RT-001', @AppUserId = 1;
SELECT @RtId = NewId FROM #Rt;
DROP TABLE #Rt;

DECLARE @Json1 NVARCHAR(MAX) =
    N'[' +
    N'{"Id":null,"OperationTemplateId":' + CAST(@Ot1 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":"first"},' +
    N'{"Id":null,"OperationTemplateId":' + CAST(@Ot2 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":"second"},' +
    N'{"Id":null,"OperationTemplateId":' + CAST(@Ot3 AS NVARCHAR(20)) + N',"IsRequired":false,"Description":"third"}' +
    N']';

CREATE TABLE #Sa1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Sa1 EXEC Parts.RouteTemplate_SaveAll
    @Id            = @RtId,
    @Name          = N'TEST-SA-RT-001-Renamed',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = @Json1;
SELECT @S = Status, @M = Message FROM #Sa1;
DROP TABLE #Sa1;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SAFresh] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StepCount INT = (SELECT COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @RtId);
EXEC test.Assert_RowCount
    @TestName      = N'[SAFresh] 3 steps inserted',
    @ExpectedCount = 3,
    @ActualCount   = @StepCount;

DECLARE @SeqOk NVARCHAR(1) = CASE
    WHEN (SELECT COUNT(*) FROM Parts.RouteStep
          WHERE RouteTemplateId = @RtId AND SequenceNumber IN (1,2,3)) = 3
    THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SAFresh] SequenceNumber covers 1/2/3',
    @Expected = N'1',
    @Actual   = @SeqOk;

DECLARE @HdrName NVARCHAR(200);
SELECT @HdrName = Name FROM Parts.RouteTemplate WHERE Id = @RtId;
EXEC test.Assert_IsEqual
    @TestName = N'[SAFresh] Header Name updated',
    @Expected = N'TEST-SA-RT-001-Renamed',
    @Actual   = @HdrName;

-- Audit-readability: Description follows SUBJECT . Route v1 (Draft) . +Step ...; K steps
DECLARE @SaDesc NVARCHAR(2000), @SaNew NVARCHAR(MAX);
SELECT TOP 1 @SaDesc = cl.Description, @SaNew = cl.NewValue
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType nt ON nt.Id = cl.LogEntityTypeId
INNER JOIN Audit.LogEventType et  ON et.Id = cl.LogEventTypeId
WHERE cl.EntityId = @RtId AND nt.Code = N'Route' AND et.Code = N'Updated'
ORDER BY cl.Id DESC;

DECLARE @SaDescOk NVARCHAR(1) = CASE
    WHEN @SaDesc LIKE N'TEST-SA-ITEM-001%Route v1 (Draft)%+Step%#1%3 steps%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SAFresh] Description matches convention shape (+Step tokens)',
    @Expected = N'1',
    @Actual   = @SaDescOk;

DECLARE @SaFkOk NVARCHAR(1) = CASE
    WHEN @SaNew LIKE N'%"OperationTemplate"%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SAFresh] NewValue step list carries resolved OperationTemplate FK',
    @Expected = N'1',
    @Actual   = @SaFkOk;
GO

-- =============================================
-- Test 2: SaveAll updates existing steps in-place + reorders.
--   Submit the existing 3 step Ids reversed → SequenceNumber 1/2/3 maps
--   to the reversed order.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @RtId BIGINT;
DECLARE @StepA BIGINT, @StepB BIGINT, @StepC BIGINT;
DECLARE @Ot1 BIGINT, @Ot2 BIGINT, @Ot3 BIGINT;

SELECT @RtId = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-SA-RT-001-Renamed';
SELECT @Ot1  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-1';
SELECT @Ot2  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-2';
SELECT @Ot3  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-3';

SELECT @StepA = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1;
SELECT @StepB = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2;
SELECT @StepC = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 3;

-- Submit reversed: C, B, A — but keep their OperationTemplateIds the same
DECLARE @Json2 NVARCHAR(MAX) =
    N'[' +
    N'{"Id":' + CAST(@StepC AS NVARCHAR(20)) + N',"OperationTemplateId":' + CAST(@Ot3 AS NVARCHAR(20)) + N',"IsRequired":false,"Description":"third moved up"},' +
    N'{"Id":' + CAST(@StepB AS NVARCHAR(20)) + N',"OperationTemplateId":' + CAST(@Ot2 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":"second middle"},' +
    N'{"Id":' + CAST(@StepA AS NVARCHAR(20)) + N',"OperationTemplateId":' + CAST(@Ot1 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":"first moved down"}' +
    N']';

CREATE TABLE #Sa2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Sa2 EXEC Parts.RouteTemplate_SaveAll
    @Id            = @RtId,
    @Name          = N'TEST-SA-RT-001-Renamed',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = @Json2;
SELECT @S = Status, @M = Message FROM #Sa2;
DROP TABLE #Sa2;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SAReorder] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @StepCSeq INT, @StepBSeq INT, @StepASeq INT;
SELECT @StepCSeq = SequenceNumber FROM Parts.RouteStep WHERE Id = @StepC;
SELECT @StepBSeq = SequenceNumber FROM Parts.RouteStep WHERE Id = @StepB;
SELECT @StepASeq = SequenceNumber FROM Parts.RouteStep WHERE Id = @StepA;
DECLARE @StepCSeqStr NVARCHAR(5) = CAST(@StepCSeq AS NVARCHAR(5));
DECLARE @StepBSeqStr NVARCHAR(5) = CAST(@StepBSeq AS NVARCHAR(5));
DECLARE @StepASeqStr NVARCHAR(5) = CAST(@StepASeq AS NVARCHAR(5));

EXEC test.Assert_IsEqual
    @TestName = N'[SAReorder] Former step-3 now SequenceNumber=1',
    @Expected = N'1', @Actual = @StepCSeqStr;
EXEC test.Assert_IsEqual
    @TestName = N'[SAReorder] Former step-2 still SequenceNumber=2',
    @Expected = N'2', @Actual = @StepBSeqStr;
EXEC test.Assert_IsEqual
    @TestName = N'[SAReorder] Former step-1 now SequenceNumber=3',
    @Expected = N'3', @Actual = @StepASeqStr;

-- Audit-readability: pure reorder (same Ids, same OperationTemplates) emits
-- the Reordered token with no +/~/-Step specifics.
DECLARE @RoDesc NVARCHAR(2000);
SELECT TOP 1 @RoDesc = cl.Description
FROM Audit.ConfigLog cl
INNER JOIN Audit.LogEntityType nt ON nt.Id = cl.LogEntityTypeId
INNER JOIN Audit.LogEventType et  ON et.Id = cl.LogEventTypeId
WHERE cl.EntityId = @RtId AND nt.Code = N'Route' AND et.Code = N'Updated'
ORDER BY cl.Id DESC;

DECLARE @RoDescOk NVARCHAR(1) = CASE
    WHEN @RoDesc LIKE N'TEST-SA-ITEM-001%Route v1 (Draft)%Reordered%3 steps%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SAReorder] Description carries Reordered token',
    @Expected = N'1',
    @Actual   = @RoDescOk;
GO

-- =============================================
-- Test 3: Insert + delete reconciliation.
--   Submit: stepB (keep), stepA (keep), {new}. Step C is omitted →
--   hard-deleted. Expect 3 rows total, original step C gone.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @RtId BIGINT;
DECLARE @StepA BIGINT, @StepB BIGINT, @StepC BIGINT;
DECLARE @Ot1 BIGINT, @Ot2 BIGINT, @Ot3 BIGINT;

SELECT @RtId = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-SA-RT-001-Renamed';
SELECT @Ot1  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-1';
SELECT @Ot2  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-2';
SELECT @Ot3  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-3';

SELECT @StepA = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 3;  -- after Test 2 reorder
SELECT @StepB = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 2;
SELECT @StepC = Id FROM Parts.RouteStep WHERE RouteTemplateId = @RtId AND SequenceNumber = 1;

DECLARE @Json3 NVARCHAR(MAX) =
    N'[' +
    N'{"Id":' + CAST(@StepB AS NVARCHAR(20)) + N',"OperationTemplateId":' + CAST(@Ot2 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":null},' +
    N'{"Id":' + CAST(@StepA AS NVARCHAR(20)) + N',"OperationTemplateId":' + CAST(@Ot1 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":null},' +
    N'{"Id":null,"OperationTemplateId":' + CAST(@Ot3 AS NVARCHAR(20)) + N',"IsRequired":false,"Description":"new bottom"}' +
    N']';

CREATE TABLE #Sa3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Sa3 EXEC Parts.RouteTemplate_SaveAll
    @Id            = @RtId,
    @Name          = N'TEST-SA-RT-001-Renamed',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = @Json3;
SELECT @S = Status, @M = Message FROM #Sa3;
DROP TABLE #Sa3;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SAInsertDelete] Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @TotalRows INT = (SELECT COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @RtId);
EXEC test.Assert_RowCount
    @TestName      = N'[SAInsertDelete] 3 rows total (1 inserted, 1 deleted)',
    @ExpectedCount = 3,
    @ActualCount   = @TotalRows;

DECLARE @OrphanGone INT = (SELECT COUNT(*) FROM Parts.RouteStep WHERE Id = @StepC);
EXEC test.Assert_RowCount
    @TestName      = N'[SAInsertDelete] Omitted step C hard-deleted',
    @ExpectedCount = 0,
    @ActualCount   = @OrphanGone;
GO

-- =============================================
-- Test 4: SaveAll rejects on a Published route
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @ItId BIGINT, @RtId BIGINT;
DECLARE @Ot1 BIGINT;
SELECT @ItId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SA-ITEM-002';
SELECT @Ot1  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-1';

CREATE TABLE #Rt (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId, @Name = N'TEST-SA-RT-PUB', @AppUserId = 1;
SELECT @RtId = NewId FROM #Rt;
DROP TABLE #Rt;

CREATE TABLE #Step (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Step EXEC Parts.RouteStep_Add @RouteTemplateId = @RtId, @OperationTemplateId = @Ot1, @AppUserId = 1;
DROP TABLE #Step;

CREATE TABLE #Pub (Status BIT, Message NVARCHAR(500));
INSERT INTO #Pub EXEC Parts.RouteTemplate_Publish @Id = @RtId, @AppUserId = 1;
DROP TABLE #Pub;

CREATE TABLE #SaP (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SaP EXEC Parts.RouteTemplate_SaveAll
    @Id            = @RtId,
    @Name          = N'TEST-SA-RT-PUB',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = N'[]';
SELECT @S = Status, @M = Message FROM #SaP;
DROP TABLE #SaP;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SAPub] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @PubMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%Cannot edit a Published route%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SAPub] Message names Published rejection',
    @Expected = N'1',
    @Actual   = @PubMsg;
GO

-- =============================================
-- Test 5: SaveAll rejects on a Deprecated route
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @ItId BIGINT, @RtId BIGINT, @Ot1 BIGINT;
SELECT @ItId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SA-ITEM-003';
SELECT @Ot1  = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-1';

CREATE TABLE #Rt (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId, @Name = N'TEST-SA-RT-DEP', @AppUserId = 1;
SELECT @RtId = NewId FROM #Rt;
DROP TABLE #Rt;

CREATE TABLE #Step (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Step EXEC Parts.RouteStep_Add @RouteTemplateId = @RtId, @OperationTemplateId = @Ot1, @AppUserId = 1;
DROP TABLE #Step;

CREATE TABLE #Pub (Status BIT, Message NVARCHAR(500));
INSERT INTO #Pub EXEC Parts.RouteTemplate_Publish @Id = @RtId, @AppUserId = 1;
DROP TABLE #Pub;

CREATE TABLE #Dep (Status BIT, Message NVARCHAR(500));
INSERT INTO #Dep EXEC Parts.RouteTemplate_Deprecate @Id = @RtId, @AppUserId = 1;
DROP TABLE #Dep;

CREATE TABLE #SaD (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SaD EXEC Parts.RouteTemplate_SaveAll
    @Id            = @RtId,
    @Name          = N'TEST-SA-RT-DEP',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = N'[]';
SELECT @S = Status, @M = Message FROM #SaD;
DROP TABLE #SaD;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SADep] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

-- A Published-then-Deprecated row trips the deprecated guard (checked
-- before Published in the proc), so the message names deprecated.
DECLARE @DepMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%deprecated%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SADep] Message names deprecated rejection',
    @Expected = N'1',
    @Actual   = @DepMsg;
GO

-- =============================================
-- Test 6: SaveAll rejects with NULL OperationTemplateId in a step
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @ItId BIGINT, @RtId BIGINT;
SELECT @ItId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SA-ITEM-004';

CREATE TABLE #Rt (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId, @Name = N'TEST-SA-RT-NULLOT', @AppUserId = 1;
SELECT @RtId = NewId FROM #Rt;
DROP TABLE #Rt;

CREATE TABLE #SaN (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SaN EXEC Parts.RouteTemplate_SaveAll
    @Id            = @RtId,
    @Name          = N'TEST-SA-RT-NULLOT',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = N'[{"Id":null,"OperationTemplateId":null,"IsRequired":true,"Description":null}]';
SELECT @S = Status, @M = Message FROM #SaN;
DROP TABLE #SaN;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SANullOT] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @MissOtMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%missing OperationTemplateId%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SANullOT] Message names missing OperationTemplateId',
    @Expected = N'1',
    @Actual   = @MissOtMsg;
GO

-- =============================================
-- Test 7: SaveAll rejects with a stale step Id (Id from a different Route)
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @It5 BIGINT, @It6 BIGINT, @Rt5 BIGINT, @Rt6 BIGINT, @StaleStep BIGINT;
DECLARE @Ot1 BIGINT;
SELECT @It5 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SA-ITEM-005';
SELECT @It6 = Id FROM Parts.Item WHERE PartNumber = N'TEST-SA-ITEM-006';
SELECT @Ot1 = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-1';

CREATE TABLE #Rt (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @It5, @Name = N'TEST-SA-RT-STALE-5', @AppUserId = 1;
SELECT @Rt5 = NewId FROM #Rt; DELETE FROM #Rt;
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @It6, @Name = N'TEST-SA-RT-STALE-6', @AppUserId = 1;
SELECT @Rt6 = NewId FROM #Rt;
DROP TABLE #Rt;

-- Add a step to Rt6 to give us a stale Id
CREATE TABLE #Step (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Step EXEC Parts.RouteStep_Add @RouteTemplateId = @Rt6, @OperationTemplateId = @Ot1, @AppUserId = 1;
SELECT @StaleStep = NewId FROM #Step;
DROP TABLE #Step;

-- Submit Rt5's SaveAll with the step from Rt6 → should reject
DECLARE @Json7 NVARCHAR(MAX) =
    N'[{"Id":' + CAST(@StaleStep AS NVARCHAR(20)) + N',"OperationTemplateId":' + CAST(@Ot1 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":null}]';

CREATE TABLE #SaS (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SaS EXEC Parts.RouteTemplate_SaveAll
    @Id            = @Rt5,
    @Name          = N'TEST-SA-RT-STALE-5',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = @Json7;
SELECT @S = Status, @M = Message FROM #SaS;
DROP TABLE #SaS;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SAStale] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @StaleMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%does not belong%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SAStale] Message names stale-Id rejection',
    @Expected = N'1',
    @Actual   = @StaleMsg;
GO

-- =============================================
-- Test 8: SaveAll rejects with NULL Name
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @ItId BIGINT, @RtId BIGINT;
SELECT @ItId = Id FROM Parts.Item WHERE PartNumber = N'TEST-SA-ITEM-007';

CREATE TABLE #Rt (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #Rt EXEC Parts.RouteTemplate_Create
    @ItemId = @ItId, @Name = N'TEST-SA-RT-NULLNAME', @AppUserId = 1;
SELECT @RtId = NewId FROM #Rt;
DROP TABLE #Rt;

CREATE TABLE #SaN (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SaN EXEC Parts.RouteTemplate_SaveAll
    @Id            = @RtId,
    @Name          = NULL,
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = N'[]';
SELECT @S = Status, @M = Message FROM #SaN;
DROP TABLE #SaN;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SANullName] Status is 0',
    @Expected = N'0',
    @Actual   = @SStr;

DECLARE @MissMsg NVARCHAR(1) = CASE
    WHEN @M LIKE N'%Required parameter missing%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[SANullName] Message names required-parameter missing',
    @Expected = N'1',
    @Actual   = @MissMsg;
GO

-- =============================================
-- Test 9: Audit row written on success
--   Use Rt5 (still Draft after Test 7 rejection) and submit a valid save.
-- =============================================
DECLARE @S BIT, @M NVARCHAR(500), @SStr NVARCHAR(1);
DECLARE @Rt5 BIGINT, @Ot1 BIGINT;
SELECT @Rt5 = Id FROM Parts.RouteTemplate WHERE Name = N'TEST-SA-RT-STALE-5';
SELECT @Ot1 = Id FROM Parts.OperationTemplate WHERE Code = N'TEST-SA-OT-1';

DECLARE @LogBefore INT = (
    SELECT COUNT(*) FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType nt ON nt.Id = cl.LogEntityTypeId
    INNER JOIN Audit.LogEventType et  ON et.Id = cl.LogEventTypeId
    WHERE cl.EntityId = @Rt5 AND nt.Code = N'Route' AND et.Code = N'Updated'
);

DECLARE @JsonA NVARCHAR(MAX) =
    N'[{"Id":null,"OperationTemplateId":' + CAST(@Ot1 AS NVARCHAR(20)) + N',"IsRequired":true,"Description":"audited"}]';

CREATE TABLE #SaA (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #SaA EXEC Parts.RouteTemplate_SaveAll
    @Id            = @Rt5,
    @Name          = N'TEST-SA-RT-STALE-5',
    @EffectiveFrom = N'2026-06-01T00:00:00',
    @AppUserId     = 1,
    @StepsJson     = @JsonA;
SELECT @S = Status, @M = Message FROM #SaA;
DROP TABLE #SaA;

SET @SStr = CAST(@S AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[SAAudit] SaveAll Status is 1',
    @Expected = N'1',
    @Actual   = @SStr;

DECLARE @LogAfter INT = (
    SELECT COUNT(*) FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType nt ON nt.Id = cl.LogEntityTypeId
    INNER JOIN Audit.LogEventType et  ON et.Id = cl.LogEventTypeId
    WHERE cl.EntityId = @Rt5 AND nt.Code = N'Route' AND et.Code = N'Updated'
);
DECLARE @LogDelta INT = @LogAfter - @LogBefore;
EXEC test.Assert_RowCount
    @TestName      = N'[SAAudit] ConfigLog row written (Updated/Route)',
    @ExpectedCount = 1,
    @ActualCount   = @LogDelta;
GO

-- =============================================
-- Cleanup
-- =============================================
DELETE rs
FROM Parts.RouteStep rs
INNER JOIN Parts.RouteTemplate rt ON rt.Id = rs.RouteTemplateId
INNER JOIN Parts.Item it          ON it.Id = rt.ItemId
WHERE it.PartNumber LIKE N'TEST-SA-ITEM-%';

DELETE rt
FROM Parts.RouteTemplate rt
INNER JOIN Parts.Item it ON it.Id = rt.ItemId
WHERE it.PartNumber LIKE N'TEST-SA-ITEM-%';

DELETE FROM Parts.OperationTemplate WHERE Code LIKE N'TEST-SA-OT-%';
DELETE FROM Parts.Item              WHERE PartNumber LIKE N'TEST-SA-ITEM-%';
GO

-- =============================================
-- Final summary
-- =============================================
EXEC test.PrintSummary;
GO
