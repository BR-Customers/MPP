-- =============================================
-- File:        0109_ControlledRun/120_completed_containers.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 2 -- a COMPLETED container's tag is real: its Closed
--              tray LOTs are tagged on join, it cannot ship, its unposted AIM serial is
--              held, it can sit on a real hold at the same time, and the per-container
--              validation still clears it.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/120_completed_containers.sql';
GO

-- ---- teardown (FK-safe): everything this suite creates (LOT names start TEST-CR-) ----
DECLARE @TdLot TABLE (Id BIGINT);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%';
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
DELETE FROM Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'TEST-CR-%';
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
DECLARE @HoldType BIGINT = (SELECT Id FROM Quality.HoldTypeCode WHERE Code = N'Quality');
DECLARE @n NVARCHAR(500);

-- Tray LOTs: Closed (4), as they are once their container completes. One free Closed LOT.
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-CR-T1A',   @Item, 1, 4, 6, @Line, @App, @Term, 0),   -- container 1, tray 1
       (N'TEST-CR-T1B',   @Item, 1, 4, 6, @Line, @App, @Term, 0),   -- container 1, tray 2
       (N'TEST-CR-T2A',   @Item, 1, 4, 6, @Line, @App, @Term, 0),   -- container 2 (joins by scan)
       (N'TEST-CR-T3A',   @Item, 1, 4, 6, @Line, @App, @Term, 0),   -- container 3 (on a real hold)
       (N'TEST-CR-T4A',   @Item, 1, 1, 6, @Line, @App, @Term, 0),   -- container 4 (still OPEN)
       (N'TEST-CR-T5A',   @Item, 1, 4, 6, @Line, @App, @Term, 0),   -- container 5 (SHIPPED)
       (N'TEST-CR-LOOSE', @Item, 1, 4, 6, @Line, @App, @Term, 0);   -- Closed, NOT a tray
DECLARE @T1A BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T1A');
DECLARE @T1B BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T1B');
DECLARE @T2A BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T2A');
DECLARE @T3A BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T3A');
DECLARE @T4A BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T4A');
DECLARE @T5A BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T5A');
DECLARE @Loose BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-LOOSE');

DECLARE @C TABLE (Seq INT IDENTITY(1,1), Id BIGINT);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
OUTPUT inserted.Id INTO @C (Id)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App),
       (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App),
       (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App),
       (@Item, @Cfg, @Line, 1 /*Open*/,     NULL,             @App),
       (@Item, @Cfg, @Line, 3 /*Shipped*/,  SYSUTCDATETIME(), @App);
DECLARE @Con1 BIGINT = (SELECT Id FROM @C WHERE Seq = 1);
DECLARE @Con2 BIGINT = (SELECT Id FROM @C WHERE Seq = 2);
DECLARE @Con3 BIGINT = (SELECT Id FROM @C WHERE Seq = 3);
DECLARE @Con4 BIGINT = (SELECT Id FROM @C WHERE Seq = 4);
DECLARE @Con5 BIGINT = (SELECT Id FROM @C WHERE Seq = 5);
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES
    (@Con1, 1, @T1A), (@Con1, 2, @T1B), (@Con2, 1, @T2A), (@Con3, 1, @T3A), (@Con4, 1, @T4A), (@Con5, 1, @T5A);

-- Container 1 has a claimed, NOT YET POSTED serial; container 2's serial is ALREADY POSTED.
INSERT INTO Lots.AimShipperIdPool (AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId, Quantity, LotNumber, PostedAt)
VALUES (N'TEST-CR-SER1', SYSUTCDATETIME(), @Con1, @App, 12, N'TEST-CR-T1A', NULL),
       (N'TEST-CR-SER2', SYSUTCDATETIME(), @Con2, @App, 6,  N'TEST-CR-T2A', SYSUTCDATETIME());
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, IsVoid)
VALUES (@Con1, N'TEST-CR-SER1', @LabelType, 1, 0);
DECLARE @Slid1 BIGINT = SCOPE_IDENTITY();

DECLARE @o  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @U  TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(100), Quantity INT,
                   LotNumber NVARCHAR(50), PostAttempts INT, LastPostError NVARCHAR(MAX), ConsumedAtEt DATETIME2(3),
                   LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);

-- before anything: the unposted serial is owed
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @U WHERE AimShipperId = N'TEST-CR-SER1');
EXEC test.Assert_IsEqual @TestName = N'[P2] fixture: the unposted serial is owed to AIM before the container is tagged', @Expected = N'1', @Actual = @n;

-- ===== 1. a completed container joins at open =====
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (CAST(NULL AS BIGINT), @Con1), (NULL, @Con4)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'piece 2', @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[P2] open with a completed and an open container: Status 1', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(a.CrtActive AS NVARCHAR(1)) + N'|' + CAST(b.CrtActive AS NVARCHAR(1)) FROM Lots.Lot a, Lots.Lot b WHERE a.Id = @T1A AND b.Id = @T1B);
EXEC test.Assert_IsEqual @TestName = N'[P2] every Closed tray LOT of the completed container is tagged', @Expected = N'1|1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Lots.LotEventLog lel JOIN Audit.LogEventType t ON t.Id = lel.LogEventTypeId
          WHERE t.Code = N'CrtActivated' AND lel.LotId IN (@T1A, @T1B));
EXEC test.Assert_IsEqual @TestName = N'[P2] one CrtActivated row per tray LOT', @Expected = N'2', @Actual = @n;
SET @n = (SELECT CAST(CrtSetByRun AS NVARCHAR(1)) + N'|' + CAST(WasCompleteAtJoin AS NVARCHAR(1)) FROM Quality.ControlledRunMember WHERE ContainerId = @Con1);
EXEC test.Assert_IsEqual @TestName = N'[P2] completed container: CrtSetByRun 1, WasCompleteAtJoin 1', @Expected = N'1|1', @Actual = @n;
SET @n = (SELECT CAST(CrtSetByRun AS NVARCHAR(1)) + N'|' + CAST(WasCompleteAtJoin AS NVARCHAR(1)) FROM Quality.ControlledRunMember WHERE ContainerId = @Con4);
EXEC test.Assert_IsEqual @TestName = N'[P2] open container: tagged, WasCompleteAtJoin 0', @Expected = N'1|0', @Actual = @n;
SET @n = (SELECT CAST(ms.CrtActive AS NVARCHAR(1)) FROM Quality.ufn_ControlledRunMemberState(@Run) ms WHERE ms.ContainerId = @Con1);
EXEC test.Assert_IsEqual @TestName = N'[P2] the member reads as tagged', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(LotStatusId AS NVARCHAR(5)) FROM Lots.Lot WHERE Id = @T1A);
EXEC test.Assert_IsEqual @TestName = N'[P2] tagging does not reopen the tray LOT (still Closed)', @Expected = N'4', @Actual = @n;

-- ===== 2. it cannot ship, and its unposted serial is held =====
INSERT INTO @s EXEC Lots.Container_Ship @ShippingLabelId = @Slid1, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%Controlled Run Tag%' THEN N'crt' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[P2] Container_Ship refuses the tagged container', @Expected = N'0|crt', @Actual = @n;
DELETE FROM @U;
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @U WHERE AimShipperId = N'TEST-CR-SER1');
EXEC test.Assert_IsEqual @TestName = N'[P2] the unposted serial leaves the owed-to-AIM list', @Expected = N'0', @Actual = @n;

-- ===== 3. what is still NOT taggable =====
DELETE FROM @s;
SET @j = (SELECT @Loose AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) FROM @s s, Lots.Lot l WHERE l.Id = @Loose);
EXEC test.Assert_IsEqual @TestName = N'[P2] a Closed LOT that is not a tray is refused and stays untagged', @Expected = N'0|0', @Actual = @n;
DELETE FROM @s;
SET @j = (SELECT @Con5 AS containerId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) FROM @s s, Lots.Lot l WHERE l.Id = @T5A);
EXEC test.Assert_IsEqual @TestName = N'[P2] a shipped container is refused and its tray stays untagged', @Expected = N'0|0', @Actual = @n;

-- ===== 4. join by scan (AddMembers), serial ALREADY posted =====
DELETE FROM @s;
SET @j = (SELECT @Con2 AS containerId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) + N'|' + CAST(m.WasCompleteAtJoin AS NVARCHAR(1))
          FROM @s s, Lots.Lot l, Quality.ControlledRunMember m WHERE l.Id = @T2A AND m.ContainerId = @Con2 AND m.EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[P2] a completed container added by scan: tagged, WasCompleteAtJoin 1', @Expected = N'1|1|1', @Actual = @n;
SET @n = (SELECT CASE WHEN PostedAt IS NOT NULL THEN N'posted' ELSE N'unposted' END + N'|' + CAST(PostAttempts AS NVARCHAR(5))
          FROM Lots.AimShipperIdPool WHERE AimShipperId = N'TEST-CR-SER2');
EXEC test.Assert_IsEqual @TestName = N'[P2] tagging an already-posted container changes nothing on its AIM row', @Expected = N'posted|0', @Actual = @n;

-- ===== 5. a tray LOT named as a LOT folds to its container (already a member) =====
DELETE FROM @s;
SET @j = (SELECT @T1A AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%Already in CR000001%' THEN N'already' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[P2] scanning a tray LOT of a member container: already in the super-lot', @Expected = N'0|already', @Actual = @n;

-- ===== 6. a container on a real hold may also be on a super-lot =====
DELETE FROM @o;
INSERT INTO @o EXEC Quality.Hold_Place @ContainerId = @Con3, @HoldTypeCodeId = @HoldType, @Reason = N'piece 2 hold', @AppUserId = @App;
DECLARE @Hold BIGINT = (SELECT NewId FROM @o);
DELETE FROM @s;
SET @j = (SELECT @Con3 AS containerId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + cs.Code + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) + N'|' + CAST(m.WasCompleteAtJoin AS NVARCHAR(1))
          FROM @s s, Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId, Lots.Lot l, Quality.ControlledRunMember m
          WHERE c.Id = @Con3 AND l.Id = @T3A AND m.ContainerId = @Con3 AND m.EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[P2] a held container joins: still on Hold AND tagged (both blocks stand)', @Expected = N'1|Hold|1|1', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.Hold_Release @HoldEventId = @Hold, @ReleaseRemarks = N'done', @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) FROM @s s, Lots.Lot l WHERE l.Id = @T3A);
EXEC test.Assert_IsEqual @TestName = N'[P2] releasing the hold does not clear the Controlled Run Tag', @Expected = N'1|1', @Actual = @n;

-- ===== 7. the super-lot cannot close while a completed container is tagged =====
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'4 of 4 members are still CRT-tagged%' THEN N'4of4' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[P2] close is refused: 4 of 4 members still tagged', @Expected = N'0|4of4', @Actual = @n;

-- ===== 8. removing a tagged container says where to release it =====
DELETE FROM @s;
DECLARE @Mem3 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @Con3 AND EndedAt IS NULL);
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @Mem3, @Remarks = N'wrong one', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%Sign-off tab%' AND Message NOT LIKE N'%LOT Detail%' THEN N'signoff' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[P2] removing a tagged container: message points at Sign-off, not LOT Detail', @Expected = N'1|signoff', @Actual = @n;

-- ===== 9. the per-container validation still clears it, and the serial is owed again =====
DELETE FROM @s;
INSERT INTO @s EXEC Lots.Container_ValidateCrt @ContainerId = @Con1, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(a.CrtActive AS NVARCHAR(1)) + N'|' + CAST(b.CrtActive AS NVARCHAR(1))
          FROM @s s, Lots.Lot a, Lots.Lot b WHERE a.Id = @T1A AND b.Id = @T1B);
EXEC test.Assert_IsEqual @TestName = N'[P2] Container_ValidateCrt clears every tray of a super-lot container (per-unit clear stays allowed)', @Expected = N'1|0|0', @Actual = @n;
DELETE FROM @U;
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @U WHERE AimShipperId = N'TEST-CR-SER1');
EXEC test.Assert_IsEqual @TestName = N'[P2] the serial is owed to AIM again once the tag is cleared', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @U WHERE AimShipperId = N'TEST-CR-SER2');
EXEC test.Assert_IsEqual @TestName = N'[P2] an already-posted serial is never offered for a second post', @Expected = N'0', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.Container_Ship @ShippingLabelId = @Slid1, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CASE WHEN Message LIKE N'%Controlled Run Tag%' THEN N'still blocked by CRT' ELSE N'not blocked by CRT' END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[P2] once validated the Controlled Run Tag no longer stops the ship', @Expected = N'not blocked by CRT', @Actual = @n;
SET @n = (SELECT CAST(ms.CrtActive AS NVARCHAR(1)) FROM Quality.ufn_ControlledRunMemberState(@Run) ms WHERE ms.ContainerId = @Con1);
EXEC test.Assert_IsEqual @TestName = N'[P2] the member now reads as cleared', @Expected = N'0', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-CR-%';
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
DELETE FROM Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'TEST-CR-%';
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotGenealogyClosure
WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

EXEC test.EndTestFile;
GO
