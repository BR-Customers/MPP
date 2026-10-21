-- =============================================
-- File:        0113_SuperLotVisibility/020_fold_and_helper.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 2 -- the membership fold
--              (Quality.ufn_ControlledRunMembershipsForLot), the open-run
--              lookup (Quality.ufn_OpenControlledRunForLot), the silent per-LOT
--              event helper (Quality.ControlledRun_LogMemberLotEventsInternal) and
--              ControlledRun_GetOpenByMember v1.1 (output unchanged).
--              LOTs named TEST-SLV-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0113_SuperLotVisibility/020_fold_and_helper.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLV-%';
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id) SELECT DISTINCT ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

DECLARE @App       BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @ItemId BIGINT, @Cell BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @Cell = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @ItemId), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @n NVARCHAR(600);
DECLARE @j NVARCHAR(MAX);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @B TABLE (Id BIGINT, RunNumber NVARCHAR(15));

SET @n = CASE WHEN @App IS NOT NULL AND @ItemId IS NOT NULL AND @Cell IS NOT NULL AND @Cfg IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SLV] fixture: user, item, location, container config', @Expected = N'ok', @Actual = @n;

-- ---- LOTs ----
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-SLV-A',  @ItemId, @OriginMfg, 1, 10, 0, @Cell, @App, 0),   -- direct LOT member
       (N'TEST-SLV-N',  @ItemId, @OriginMfg, 1, 10, 0, @Cell, @App, 0),   -- never in a super-lot
       (N'TEST-SLV-T1', @ItemId, @OriginMfg, 1, 6,  0, @Cell, @App, 0),   -- tray in container at join (2 trays)
       (N'TEST-SLV-T1B',@ItemId, @OriginMfg, 1, 6,  0, @Cell, @App, 0),
       (N'TEST-SLV-T2', @ItemId, @OriginMfg, 1, 6,  0, @Cell, @App, 0),   -- tray repacked in after the membership ended
       (N'TEST-SLV-T3', @ItemId, @OriginMfg, 1, 6,  0, @Cell, @App, 0);   -- tray moved in while the membership was open
DECLARE @A  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-A');
DECLARE @N0 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-N');
DECLARE @T1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-T1');
DECLARE @T1B BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-T1B');
DECLARE @T2 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-T2');
DECLARE @T3 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-T3');

-- three completed containers; C1 has two trays
DECLARE @C1 BIGINT, @C2 BIGINT, @C3 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@ItemId, @Cfg, @Cell, 2, SYSUTCDATETIME(), @App);
SET @C1 = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@ItemId, @Cfg, @Cell, 2, SYSUTCDATETIME(), @App);
SET @C2 = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@ItemId, @Cfg, @Cell, 2, SYSUTCDATETIME(), @App);
SET @C3 = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@C1, 1, @T1), (@C1, 2, @T1B);

-- ---- four separate super-lots: A (LOT), C1, C2, C3 ----
SET @j = (SELECT @A AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slv A', @MembersJson = @j, @AppUserId = @App;
DECLARE @RunA BIGINT = (SELECT NewId FROM @o); DELETE FROM @o;
SET @j = (SELECT @C1 AS containerId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slv C1', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run1 BIGINT = (SELECT NewId FROM @o); DELETE FROM @o;
SET @j = (SELECT @C2 AS containerId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slv C2', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o); DELETE FROM @o;
SET @j = (SELECT @C3 AS containerId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slv C3', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run3 BIGINT = (SELECT NewId FROM @o); DELETE FROM @o;
DECLARE @MemA  BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ControlledRunId = @RunA);
DECLARE @Mem1  BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run1);
DECLARE @Mem2  BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run2);
DECLARE @Mem3  BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run3);
SET @n = CASE WHEN @MemA IS NOT NULL AND @Mem1 IS NOT NULL AND @Mem2 IS NOT NULL AND @Mem3 IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SLV] fixture: four memberships opened', @Expected = N'ok', @Actual = @n;

-- C2: membership ran -3h..-1h, tray T2 was repacked in NOW (after it ended).
UPDATE Quality.ControlledRunMember
SET AddedAt = DATEADD(HOUR, -3, SYSUTCDATETIME()), EndedAt = DATEADD(HOUR, -1, SYSUTCDATETIME()),
    EndedByUserId = @App, ControlledRunMemberEndReasonId = 1
WHERE Id = @Mem2;
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId, ClosedAt) VALUES (@C2, 1, @T2, SYSUTCDATETIME());
-- C3: membership open since -3h, tray T3 moved in -1h (while open).
UPDATE Quality.ControlledRunMember SET AddedAt = DATEADD(HOUR, -3, SYSUTCDATETIME()) WHERE Id = @Mem3;
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId, ClosedAt) VALUES (@C3, 1, @T3, DATEADD(HOUR, -1, SYSUTCDATETIME()));

-- ===== Fold =====
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(RunNumber), N'|', ISNULL(CAST(MIN(ViaContainerId) AS NVARCHAR(20)), N'null'))
          FROM Quality.ufn_ControlledRunMembershipsForLot(@A));
EXEC test.Assert_IsEqual @TestName = N'[Fold] LOT member listed',
    @Expected = N'1|CR000001|null', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ufn_ControlledRunMembershipsForLot(@N0));
EXEC test.Assert_IsEqual @TestName = N'[Fold] never in a super-lot: empty', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(ViaContainerId) - @C1, N'|', MIN(ControlledRunId) - @Run1)
          FROM Quality.ufn_ControlledRunMembershipsForLot(@T1));
EXEC test.Assert_IsEqual @TestName = N'[Fold] tray in container at join: listed via container', @Expected = N'1|0|0', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ufn_ControlledRunMembershipsForLot(@T2));
EXEC test.Assert_IsEqual @TestName = N'[Fold] tray moved in (ClosedAt) after the membership ended: not listed', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(ViaContainerId) - @C3, N'|', MIN(ControlledRunId) - @Run3)
          FROM Quality.ufn_ControlledRunMembershipsForLot(@T3));
EXEC test.Assert_IsEqual @TestName = N'[Fold] tray moved in while the membership was open: listed', @Expected = N'1|0|0', @Actual = @n;

-- ===== Open =====
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(ControlledRunId) - @Run1) FROM Quality.ufn_OpenControlledRunForLot(@T1));
EXEC test.Assert_IsEqual @TestName = N'[Open] tray LOT resolves its container''s open run', @Expected = N'1|0', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ufn_OpenControlledRunForLot(@T2));
EXEC test.Assert_IsEqual @TestName = N'[Open] ended membership: empty', @Expected = N'0', @Actual = @n;

-- ===== Helper =====
DECLARE @mj NVARCHAR(MAX) = N'[' + CAST(@MemA AS NVARCHAR(20)) + N']';
EXEC Quality.ControlledRun_LogMemberLotEventsInternal @MemberIdsJson = @mj, @LogEventTypeCode = N'ControlledRunLotJoined',
     @ActionText = N'Joined', @AppUserId = @App;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description LIKE N'TEST-SLV-A %Super-lot CR%Joined' THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @A AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotJoined')
            AND RIGHT(Description, 7) = N' Joined' /* the direct helper call, not Open's own 'Joined (Selected)' row (Task 3) */);
EXEC test.Assert_IsEqual @TestName = N'[Helper] LOT member: one row, Description contains ''Super-lot CR''', @Expected = N'1|ok', @Actual = @n;
SET @n = (SELECT JSON_VALUE(NewValue, '$.Lot.Code') + N'|' + JSON_VALUE(NewValue, '$.ControlledRun.Code') + N'|' + ISNULL(JSON_VALUE(NewValue, '$.Container.Id'), N'null')
          FROM Lots.LotEventLog WHERE LotId = @A AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotJoined')
            AND RIGHT(Description, 7) = N' Joined' /* the direct helper call, not Open's own 'Joined (Selected)' row (Task 3) */);
EXEC test.Assert_IsEqual @TestName = N'[Helper] NewValue carries resolved-name Lot, ControlledRun and null Container',
    @Expected = N'TEST-SLV-A|CR000001|null', @Actual = @n;

SET @mj = N'[' + CAST(@Mem1 AS NVARCHAR(20)) + N']';
EXEC Quality.ControlledRun_LogMemberLotEventsInternal @MemberIdsJson = @mj, @LogEventTypeCode = N'ControlledRunLotResult',
     @ActionText = N'Result recorded', @AppUserId = @App;
SET @n = (SELECT CONCAT(COUNT(*), N'|', SUM(CASE WHEN Description LIKE N'%Super-lot CR%Container ' + CAST(@C1 AS NVARCHAR(20)) + N' %Result recorded' THEN 1 ELSE 0 END))
          FROM Lots.LotEventLog WHERE LotId IN (@T1, @T1B) AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotResult'));
EXEC test.Assert_IsEqual @TestName = N'[Helper] container member with 2 trays: 2 rows, each names the container', @Expected = N'2|2', @Actual = @n;
SET @n = (SELECT JSON_VALUE(NewValue, '$.Container.Id') FROM Lots.LotEventLog WHERE LotId = @T1 AND LogEventTypeId = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotResult'));
DECLARE @ExpC1 NVARCHAR(20) = CAST(@C1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Helper] container member: NewValue.Container.Id', @Expected = @ExpC1, @Actual = @n;

-- ===== GetOpenByMember unchanged =====
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @LotId = @A;
SET @n = (SELECT RunNumber FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] unchanged: a member LOT', @Expected = N'CR000001', @Actual = @n;
DELETE FROM @B;
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @LotId = @T1;
SET @n = (SELECT CAST(Id - @Run1 AS NVARCHAR(10)) FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] unchanged: a tray LOT resolves through its container', @Expected = N'0', @Actual = @n;
DELETE FROM @B;
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @ContainerId = @C1;
SET @n = (SELECT CAST(Id - @Run1 AS NVARCHAR(10)) FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] unchanged: a container', @Expected = N'0', @Actual = @n;
DELETE FROM @B;
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @LotId = @N0;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] unchanged: a LOT in no super-lot -> empty set', @Expected = N'0', @Actual = @n;
DELETE FROM @B;
INSERT INTO @B EXEC Quality.ControlledRun_GetOpenByMember @LotId = @T2;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @B);
EXEC test.Assert_IsEqual @TestName = N'[GetOpenByMember] unchanged: a tray LOT whose container membership ended -> empty', @Expected = N'0', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLV-%';
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id) SELECT DISTINCT ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO
EXEC test.EndTestFile;
GO
