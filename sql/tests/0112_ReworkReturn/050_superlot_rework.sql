-- =============================================
-- File:        0112_ReworkReturn/050_superlot_rework.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, Task 5 -- the super-lot side of trim rework (spec 4.5):
--                * a member LOT with an OPEN rework reads ReleaseBlockReason
--                  'At trim rework' and ControlledRun_Release refuses it;
--                * the Trim OUT that closes the rework lifts the block;
--                * Quality.ControlledRun_ListMemberRework lists it (StartedAt in ET);
--                * 'Rework' is no longer a recordable result entry; ReworkQty stays 0.
--              Fixture: as 040_trim_pass.sql (item 12232-59B-0000, TRIM1, a whole-day
--              fixture schedule); LOTs named TEST-SLR-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/050_superlot_rework.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLR-%';
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-SLR-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST-SLR-FIXTURE-SCHED';
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST-SLR-FIXTURE-SCHED', '00:00:00', '23:59:59', 127, DATEADD(DAY, -1, CAST(SYSUTCDATETIME() AS DATE)), 1);
DECLARE @LocalToday DATETIME2(3) = CAST(CAST(CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE) AS DATETIME2(3));
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES ((SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'TEST-SLR-FIXTURE-SCHED'),
        DATEADD(MINUTE, 1, @LocalToday), DATEADD(MINUTE, 2, @LocalToday), N'TEST-SLR-FIXTURE');
GO

DECLARE @App   BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Sup   BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Id <> @App AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @Dest  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');
DECLARE @Rt    BIGINT = (SELECT TOP 1 Id FROM Parts.RouteTemplate WHERE ItemId = @Item AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL ORDER BY VersionNumber DESC);
DECLARE @Safe  BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE l.DeprecatedAt IS NULL AND d.IsProductionDestination = 0 AND l.Id <> @Dest
      AND EXISTS (SELECT 1 FROM Location.ufn_AncestorLocationIds(l.Id) a
                  JOIN Parts.v_EffectiveItemLocation e ON e.LocationId = a.LocationId AND e.ItemId = @Item)
    ORDER BY l.Id);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Defect BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @otIn  BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimIn');
DECLARE @otOut BIGINT = (SELECT rs.OperationTemplateId FROM Parts.RouteStep rs JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId WHERE rs.RouteTemplateId = @Rt AND oty.Code = N'TrimOut');
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @L BIGINT;
DECLARE @Scrap5 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":5}]';
DECLARE @Scrap1 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":1}]';
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @Mv TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Te TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @o  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @MR TABLE (MemberId BIGINT, Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), PieceCount INT, CrtActive BIT, AcceptedQty INT, ScrapQty INT, ReworkQty INT, ReturnQty INT, UseAsIsQty INT,
    AppliedScrapQty INT, ResultQty INT, LeftOver INT, HasResult BIT, ReleaseBlockReason NVARCHAR(100), WasCompleteAtJoin BIT, RankLocationId BIGINT,
    AppliedReturnQty INT);
DECLARE @RW TABLE (MemberId BIGINT, LotReworkId BIGINT, StartedAt DATETIME2(3), ApprovedByInitials NVARCHAR(20));

SET @n = CASE WHEN @Item IS NOT NULL AND @Dest IS NOT NULL AND @Safe IS NOT NULL AND @Sup IS NOT NULL
               AND @otIn IS NOT NULL AND @otOut IS NOT NULL AND @Defect IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] fixture: item, route, trim shop, a second user', @Expected = N'ok', @Actual = @n;

-- first pass: 95 good + 5 scrap
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Safe, @PieceCount = 100, @AppUserId = @App, @LotName = N'TEST-SLR-1';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @L1 BIGINT = @L;
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn';
DELETE FROM @Mv;
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L1, @OperationTemplateId = @otIn, @AppUserId = @App;
DELETE FROM @Te;
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L1, @OperationTemplateId = @otOut, @ShotCount = 95, @ScrapLinesJson = @Scrap5, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] fixture: first pass Trim OUT succeeds', @Expected = N'1', @Actual = @n;
UPDATE Workorder.ProductionEvent SET EventAt = DATEADD(MINUTE, -5, EventAt) WHERE LotId = @L1;
UPDATE Workorder.RejectEvent SET RecordedAt = DATEADD(MINUTE, -5, RecordedAt) WHERE LotId = @L1;

-- the LOT becomes a member of an open super-lot
DECLARE @j NVARCHAR(MAX) = (SELECT @L1 AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'rework test', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DELETE FROM @o;
DECLARE @Mem BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @L1 AND EndedAt IS NULL);
SET @n = CASE WHEN @Run IS NOT NULL AND @Mem IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] fixture: super-lot opened with the LOT as a member', @Expected = N'ok', @Actual = @n;

-- no rework yet
INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @Run;
SELECT @n = ReleaseBlockReason FROM @MR WHERE MemberId = @Mem; DELETE FROM @MR;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] no rework: block reason is No results yet', @Expected = N'No results yet', @Actual = @n;
INSERT INTO @RW EXEC Quality.ControlledRun_ListMemberRework @ControlledRunId = @Run;
SET @n = CAST((SELECT COUNT(*) FROM @RW) AS NVARCHAR(10)); DELETE FROM @RW;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] no rework: ListMemberRework is empty', @Expected = N'0', @Actual = @n;

-- supervisor moves the member back into trim: the rework opens
INSERT INTO @Mv EXEC Lots.Lot_MoveToValidated @LotId = @L1, @ToLocationId = @Dest, @AppUserId = @App, @OperationTypeCode = N'TrimIn', @OverrideAppUserId = @Sup;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Mv; DELETE FROM @Mv;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] fixture: override move of a member LOT into trim succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.ufn_OpenLotRework(@L1)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] fixture: the rework is open', @Expected = N'1', @Actual = @n;

INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @Run;
SELECT @n = ReleaseBlockReason FROM @MR WHERE MemberId = @Mem; DELETE FROM @MR;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] member with open rework: ReleaseBlockReason = At trim rework', @Expected = N'At trim rework', @Actual = @n;

-- the release refuses it, naming the member and the reason
SET @j = N'[' + CAST(@Mem AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o; DELETE FROM @o;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] ControlledRun_Release refuses while a member is at trim rework',
    @Expected = N'0|TEST-SLR-1: At trim rework. Nothing was released.', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Quality.ControlledRunRelease) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] the refused release wrote no release row', @Expected = N'0', @Actual = @n;

-- the rework outranks a recorded result
SET @j = (SELECT @Mem AS memberId, N'Accepted' AS dispositionCode, 1 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;
INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @Run;
SELECT @n = ReleaseBlockReason FROM @MR WHERE MemberId = @Mem; DELETE FROM @MR;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] a member with a result is still blocked while at rework', @Expected = N'At trim rework', @Actual = @n;
UPDATE Quality.ControlledRunResult SET VoidedAt = SYSUTCDATETIME(), VoidedByUserId = @App, VoidRemarks = N'test' WHERE ControlledRunMemberId = @Mem;

-- ListMemberRework
INSERT INTO @RW EXEC Quality.ControlledRun_ListMemberRework @ControlledRunId = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MIN(CASE WHEN r.MemberId = @Mem AND r.LotReworkId = lr.Id THEN 1 ELSE 0 END) AS NVARCHAR(1)) + N'|'
               + CAST(MIN(CASE WHEN r.StartedAt = CAST(lr.StartedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) THEN 1 ELSE 0 END) AS NVARCHAR(1)) + N'|'
               + ISNULL(MIN(r.ApprovedByInitials), N'<NULL>')
          FROM @RW r CROSS JOIN Lots.LotRework lr WHERE lr.LotId = @L1 AND lr.CompletedAt IS NULL);
SET @e = N'1|1|1|' + (SELECT Initials FROM Location.AppUser WHERE Id = @Sup);
DELETE FROM @RW;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] ListMemberRework returns the member with ET StartedAt and the approver''s initials', @Expected = @e, @Actual = @n;

-- Rework is no longer a recordable result entry
SET @j = (SELECT @Mem AS memberId, N'Rework' AS dispositionCode, 1 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o; DELETE FROM @o;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] recording a Rework entry is refused',
    @Expected = N'0|TEST-SLR-1: rework is recorded by moving the LOT back into trim, not as a result.', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @Mem AND VoidedAt IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] the refused Rework entry wrote nothing', @Expected = N'0', @Actual = @n;

-- re-run Trim OUT: the rework closes, the block lifts
INSERT INTO @Te EXEC Workorder.ProductionEvent_Record @LotId = @L1, @OperationTemplateId = @otIn, @AppUserId = @App;
DELETE FROM @Te;
INSERT INTO @Te EXEC Workorder.TrimOut_Record @ParentLotId = @L1, @OperationTemplateId = @otOut, @ShotCount = 94, @ScrapLinesJson = @Scrap1, @SourceLocationId = @Dest, @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(5)) FROM @Te; DELETE FROM @Te;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] fixture: re-run Trim OUT succeeds', @Expected = N'1', @Actual = @n;
SET @n = CAST((SELECT COUNT(*) FROM Lots.ufn_OpenLotRework(@L1)) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] fixture: the rework is closed', @Expected = N'0', @Actual = @n;
INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @Run;
SELECT @n = ReleaseBlockReason FROM @MR WHERE MemberId = @Mem; DELETE FROM @MR;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] after re-run Trim OUT, block reason is back to No results yet', @Expected = N'No results yet', @Actual = @n;
INSERT INTO @RW EXEC Quality.ControlledRun_ListMemberRework @ControlledRunId = @Run;
SET @n = CAST((SELECT COUNT(*) FROM @RW) AS NVARCHAR(10)); DELETE FROM @RW;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] after re-run Trim OUT, ListMemberRework is empty', @Expected = N'0', @Actual = @n;

-- the column is retained; nothing records into it any more
SET @j = (SELECT @Mem AS memberId, N'Accepted' AS dispositionCode, 94 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;
INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @Run;
SELECT @n = CAST(ReworkQty AS NVARCHAR(10)) + N'|' + CAST(AcceptedQty AS NVARCHAR(10)) + N'|' + ISNULL(ReleaseBlockReason, N'<NULL>') FROM @MR WHERE MemberId = @Mem; DELETE FROM @MR;
EXEC test.Assert_IsEqual @TestName = N'[SlRwk] ReworkQty column still present and 0; the member is releasable again', @Expected = N'0|94|<NULL>', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLR-%';
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
DELETE FROM Oee.Shift WHERE Remarks = N'TEST-SLR-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST-SLR-FIXTURE-SCHED';
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

EXEC test.EndTestFile;
GO
