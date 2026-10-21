-- =============================================
-- File:        0114_SuperLotVisibility/030_lot_events.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 3 -- every super-lot event lands on the
--              LOT. Each of the eight writers (ApplyMembersInternal via Open /
--              AddMembers / Sync, RemoveMember, Close, Cancel, Release,
--              ControlledRunResult_Record, _Void, ControlledRunDeviation_Raise)
--              writes one Lots.LotEventLog row per LOT it touches through
--              Quality.ControlledRun_LogMemberLotEventsInternal (container
--              members: one per tray in the container at that moment).
--              Fix round: the three other paths that touch a member's LOT --
--              Lots.VendorReturn_Cancel (voids the linked result),
--              Lots.ContainerRework_Scrap (an applied scrap result) and
--              Lots.ContainerRework_Void (ends the membership) -- and the one
--              deviation-cover rule in ControlledRun_Release.
--              LOTs named TEST-SLV-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0114_SuperLotVisibility/030_lot_events.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLV-%';
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id) SELECT DISTINCT ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
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
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.ContainerRework WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @Cfg  BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @DefName NVARCHAR(500) = (SELECT Description FROM Quality.DefectCode WHERE Id = @Def);
DECLARE @Dot NVARCHAR(1) = Audit.ufn_MidDot();
DECLARE @n NVARCHAR(600), @exp NVARCHAR(600), @j NVARCHAR(MAX);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));

DECLARE @EvJoined BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotJoined');
DECLARE @EvLeft   BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotLeft');
DECLARE @EvResult BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotResult');
DECLARE @EvVoided BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotResultVoided');
DECLARE @EvDev    BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotDeviation');
DECLARE @EvRel    BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotReleased');
DECLARE @EvCrtOn  BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'CrtActivated');

SET @n = CASE WHEN @App IS NOT NULL AND @Item IS NOT NULL AND @Line IS NOT NULL AND @Cfg IS NOT NULL AND @Def IS NOT NULL
               AND @EvJoined IS NOT NULL AND @EvRel IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Events] fixture: user, item, line, config, defect, event codes', @Expected = N'ok', @Actual = @n;

-- ---- LOTs and one completed container with two trays ----
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-SLV-J1',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),   -- selected at Open, scrapped, released before the deviation
       (N'TEST-SLV-J2',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 1),   -- already CRT-tagged when it joins
       (N'TEST-SLV-J3',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),   -- scanned in by AddMembers, then removed
       (N'TEST-SLV-J5',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),   -- still a member when the super-lot closes
       (N'TEST-SLV-KT1', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0),   -- trays of the completed container
       (N'TEST-SLV-KT2', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0);
DECLARE @J1  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-J1');
DECLARE @J2  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-J2');
DECLARE @J3  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-J3');
DECLARE @J5  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-J5');
DECLARE @KT1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-KT1');
DECLARE @KT2 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-KT2');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App);
DECLARE @K BIGINT = SCOPE_IDENTITY();
DECLARE @KName NVARCHAR(30) = N'Container ' + CAST(@K AS NVARCHAR(20));
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@K, 1, @KT1), (@K, 2, @KT2);

-- ===== Join: Open (Selected) =====
SET @j = (SELECT * FROM (VALUES (@J1, CAST(NULL AS BIGINT)), (@J2, NULL), (NULL, @K)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slv events', @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @RunNumber NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @Run);
DELETE FROM @o;
DECLARE @MemJ1 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @J1 AND EndedAt IS NULL);
DECLARE @MemJ2 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @J2 AND EndedAt IS NULL);
DECLARE @MemK  BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @K AND EndedAt IS NULL);

SET @exp = N'TEST-SLV-J1 ' + @Dot + N' Super-lot ' + @RunNumber + N' ' + @Dot + N' Joined (Selected)';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description = @exp THEN N'ok' ELSE Description END),
                        N'|', (SELECT COUNT(*) FROM Lots.LotEventLog WHERE LotId = @J1 AND LogEventTypeId = @EvCrtOn))
          FROM Lots.LotEventLog WHERE LotId = @J1 AND LogEventTypeId = @EvJoined);
EXEC test.Assert_IsEqual @TestName = N'[Events] join by Open (selected)', @Expected = N'1|ok|1', @Actual = @n;

SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description LIKE N'%Joined (Selected)' THEN N'ok' ELSE Description END),
                        N'|', (SELECT COUNT(*) FROM Lots.LotEventLog WHERE LotId = @J2 AND LogEventTypeId = @EvCrtOn))
          FROM Lots.LotEventLog WHERE LotId = @J2 AND LogEventTypeId = @EvJoined);
EXEC test.Assert_IsEqual @TestName = N'[Events] already-tagged LOT joining gets Joined and no CrtActivated', @Expected = N'1|ok|0', @Actual = @n;

SET @n = (SELECT CONCAT(COUNT(*), N'|', SUM(CASE WHEN Description LIKE N'%' + @KName + N' ' + @Dot + N' Joined (Selected)' THEN 1 ELSE 0 END),
                        N'|', COUNT(DISTINCT LotId))
          FROM Lots.LotEventLog WHERE LotId IN (@KT1, @KT2) AND LogEventTypeId = @EvJoined);
EXEC test.Assert_IsEqual @TestName = N'[Events] container join: each tray gets Joined', @Expected = N'2|2|2', @Actual = @n;

-- ===== Join: AddMembers (Scanned in) =====
SET @j = (SELECT @J3 AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
DELETE FROM @s;
DECLARE @MemJ3 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @J3 AND EndedAt IS NULL);
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description LIKE N'TEST-SLV-J3 %Super-lot ' + @RunNumber + N' %Joined (Scanned in)' THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @J3 AND LogEventTypeId = @EvJoined);
EXEC test.Assert_IsEqual @TestName = N'[Events] join by AddMembers (scanned in)', @Expected = N'1|ok', @Actual = @n;

-- ===== Join: sync (AutoJoined) on a second super-lot, then Cancel it =====
DECLARE @OldCrt BIT = (SELECT CrtEnabled FROM Parts.Item WHERE Id = @Item);
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @Item;
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slv window', @MembersJson = NULL, @AutoJoinEnabled = 1,
    @SelectionItemId = @Item, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o);
DELETE FROM @o;
DECLARE @Opened2 DATETIME2(3) = (SELECT OpenedAt FROM Quality.ControlledRun WHERE Id = @Run2);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive, CreatedAt)
VALUES (N'TEST-SLV-J4', @Item, 1, 1, 10, 10, @Line, @App, @Term, 1, DATEADD(SECOND, 1, @Opened2));
DECLARE @J4 BIGINT = SCOPE_IDENTITY();
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run2, @AppUserId = @App;
DELETE FROM @s;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description LIKE N'%Joined (New production)' THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @J4 AND LogEventTypeId = @EvJoined);
EXEC test.Assert_IsEqual @TestName = N'[Events] join by sync (auto-joined) writes Joined', @Expected = N'1|ok', @Actual = @n;

INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run2, @Remarks = N'opened by mistake', @AppUserId = @App;
DELETE FROM @s;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description LIKE N'TEST-SLV-J4 %Left (super-lot cancelled)' THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @J4 AND LogEventTypeId = @EvLeft);
EXEC test.Assert_IsEqual @TestName = N'[Events] cancelled', @Expected = N'1|ok', @Actual = @n;
UPDATE Parts.Item SET CrtEnabled = @OldCrt WHERE Id = @Item;

-- ===== Removed =====
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemJ3, @Remarks = N'scanned by mistake', @AppUserId = @App;
DELETE FROM @s;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description LIKE N'TEST-SLV-J3 %Left (removed: scanned by mistake)' THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @J3 AND LogEventTypeId = @EvLeft);
EXEC test.Assert_IsEqual @TestName = N'[Events] removed', @Expected = N'1|ok', @Actual = @n;

-- ===== Results =====
SET @j = (SELECT * FROM (VALUES (@MemJ1, N'Scrap',    2, @Def),
                                (@MemJ2, N'Accepted', 5, CAST(NULL AS BIGINT)),
                                (@MemK,  N'Accepted', 12, NULL)) v(memberId, dispositionCode, quantity, defectCodeId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Events] fixture: results recorded', @Expected = N'1', @Actual = @n;
DELETE FROM @o;

SET @exp = N'TEST-SLV-J1 ' + @Dot + N' Super-lot ' + @RunNumber + N' ' + @Dot + N' Result recorded ' + @Dot + N' Scrap 2 (' + @DefName + N')';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description = @exp THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @J1 AND LogEventTypeId = @EvResult);
EXEC test.Assert_IsEqual @TestName = N'[Events] result scrap on LOT', @Expected = N'1|ok', @Actual = @n;

SET @exp = N'% ' + @Dot + N' ' + @KName + N' ' + @Dot + N' Result recorded ' + @Dot + N' Accepted 12';
SET @n = (SELECT CONCAT(COUNT(*), N'|', SUM(CASE WHEN Description LIKE @exp THEN 1 ELSE 0 END), N'|', COUNT(DISTINCT LotId))
          FROM Lots.LotEventLog WHERE LotId IN (@KT1, @KT2) AND LogEventTypeId = @EvResult);
EXEC test.Assert_IsEqual @TestName = N'[Events] result on container names the container on each tray', @Expected = N'2|2|2', @Actual = @n;

-- ===== Void (J2's entry), then the right number again =====
DECLARE @ResJ2 BIGINT = (SELECT Id FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemJ2 AND VoidedAt IS NULL);
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResJ2, @Remarks = N'typo', @AppUserId = @App;
DELETE FROM @s;
SET @exp = N'TEST-SLV-J2 ' + @Dot + N' Super-lot ' + @RunNumber + N' ' + @Dot + N' Result voided ' + @Dot + N' Accepted 5 (typo)';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description = @exp THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @J2 AND LogEventTypeId = @EvVoided);
EXEC test.Assert_IsEqual @TestName = N'[Events] result voided', @Expected = N'1|ok', @Actual = @n;
SET @j = (SELECT @MemJ2 AS memberId, N'Accepted' AS dispositionCode, 10 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;

-- ===== Release J1 before any deviation =====
SET @j = N'[' + CAST(@MemJ1 AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
SET @exp = N'1|1 member released from super-lot ' + @RunNumber + N'. 2 still in it.';
EXEC test.Assert_IsEqual @TestName = N'[Events] fixture: J1 released', @Expected = @exp, @Actual = @n;
DELETE FROM @o;
SET @exp = N'TEST-SLV-J1 ' + @Dot + N' Super-lot ' + @RunNumber + N' ' + @Dot + N' Released ' + @Dot + N' signed SYS';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description = @exp THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @J1 AND LogEventTypeId = @EvRel);
EXEC test.Assert_IsEqual @TestName = N'[Events] release with no deviation names only the signer', @Expected = N'1|ok', @Actual = @n;

-- ===== Deviation: covers J2 and K's trays; not released J1, not removed J3 =====
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'porosity cosmetic',
    @Justification = N'no effect on function', @AppUserId = @App;
DECLARE @DevId BIGINT = (SELECT NewId FROM @o);
DECLARE @DV NVARCHAR(15) = (SELECT DeviationNumber FROM Quality.ControlledRunDeviation WHERE Id = @DevId);
DELETE FROM @o;
SET @n = (SELECT CONCAT(
            SUM(CASE WHEN LotId = @J2 THEN 1 ELSE 0 END), N'|',
            SUM(CASE WHEN LotId IN (@KT1, @KT2) THEN 1 ELSE 0 END), N'|',
            SUM(CASE WHEN LotId IN (@J1, @J3) THEN 1 ELSE 0 END), N'|',
            SUM(CASE WHEN Description LIKE N'%Deviation ' + @DV + N' raised' THEN 1 ELSE 0 END))
          FROM Lots.LotEventLog WHERE LotId IN (@J1, @J2, @J3, @KT1, @KT2) AND LogEventTypeId = @EvDev);
EXEC test.Assert_IsEqual @TestName = N'[Events] deviation: open members only, released-then-removed member gets none', @Expected = N'1|2|0|3', @Actual = @n;

-- ===== Release J2 and K: signer and the deviation =====
SET @j = N'[' + CAST(@MemJ2 AS NVARCHAR(20)) + N',' + CAST(@MemK AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
DELETE FROM @o;
SET @exp = N'% ' + @Dot + N' Released ' + @Dot + N' signed SYS ' + @Dot + N' Deviation ' + @DV;
SET @n = (SELECT CONCAT(COUNT(*), N'|', SUM(CASE WHEN Description LIKE @exp THEN 1 ELSE 0 END), N'|',
                        SUM(CASE WHEN LotId IN (@KT1, @KT2) AND Description LIKE N'%' + @KName + N' %' THEN 1 ELSE 0 END))
          FROM Lots.LotEventLog WHERE LotId IN (@J2, @KT1, @KT2) AND LogEventTypeId = @EvRel);
EXEC test.Assert_IsEqual @TestName = N'[Events] release names signer and deviation', @Expected = N'3|3|2', @Actual = @n;

-- ===== Close: only members still in it get 'Left (super-lot closed)' =====
SET @j = (SELECT @J5 AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.Lot_ClearCrt @LotId = @J5, @AppUserId = @App;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Events] fixture: super-lot closed', @Expected = N'1', @Actual = @n;
DELETE FROM @s;
SET @n = (SELECT CONCAT(
            SUM(CASE WHEN LotId = @J5 AND Description LIKE N'TEST-SLV-J5 %Left (super-lot closed)' THEN 1 ELSE 0 END), N'|',
            SUM(CASE WHEN Description LIKE N'%Left (super-lot closed)' THEN 1 ELSE 0 END), N'|',
            SUM(CASE WHEN LotId = @J3 THEN 1 ELSE 0 END))
          FROM Lots.LotEventLog WHERE LotId IN (@J1, @J2, @J3, @J5, @KT1, @KT2) AND LogEventTypeId = @EvLeft);
EXEC test.Assert_IsEqual @TestName = N'[Events] closed: only open members', @Expected = N'1|1|1', @Actual = @n;
GO

-- ===== Fix round: the other paths that touch a member's LOT =====
DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @Cfg  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ISNULL(IsSerialized, 0) = 0 ORDER BY Id);
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @DefName NVARCHAR(500) = (SELECT Description FROM Quality.DefectCode WHERE Id = @Def);
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Dot NVARCHAR(1) = Audit.ufn_MidDot();
DECLARE @n NVARCHAR(600), @exp NVARCHAR(600), @j NVARCHAR(MAX);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @EvLeft   BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotLeft');
DECLARE @EvResult BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotResult');
DECLARE @EvVoided BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotResultVoided');
DECLARE @EvRel    BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ControlledRunLotReleased');

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-SLV-V1',  @Item, @OriginRcv, 1, 10, 10, @Line, @App, @Term, 0),   -- received LOT: a vendor return, then cancelled
       (N'TEST-SLV-L1',  @Item, 1,          1, 10, 10, @Line, @App, @Term, 0),   -- joins AFTER the deviation, then released
       (N'TEST-SLV-RT1', @Item, 1,          4,  2,  0, @Line, @App, @Term, 0),   -- trays of the container under rework
       (N'TEST-SLV-RT2', @Item, 1,          4,  2,  0, @Line, @App, @Term, 0);
DECLARE @V1  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-V1');
DECLARE @L1  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-L1');
DECLARE @RT1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-RT1');
DECLARE @RT2 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-RT2');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App);
DECLARE @KR BIGINT = SCOPE_IDENTITY();
DECLARE @KRName NVARCHAR(30) = N'Container ' + CAST(@KR AS NVARCHAR(20));
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId)
VALUES (@KR, 1, 2, @RT1, SYSUTCDATETIME(), @App), (@KR, 2, 2, @RT2, SYSUTCDATETIME(), @App);
DECLARE @TrayR1 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @KR AND TrayPosition = 1);
DECLARE @TrayR2 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @KR AND TrayPosition = 2);

SET @j = (SELECT * FROM (VALUES (@V1, CAST(NULL AS BIGINT)), (NULL, @KR)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slv fix round', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @RunNumber NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @Run);
DELETE FROM @o;
DECLARE @MemV1 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @V1 AND EndedAt IS NULL);
SET @n = CASE WHEN @Run IS NOT NULL AND @MemV1 IS NOT NULL AND @Cfg IS NOT NULL AND @OriginRcv IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Events] fix fixture: super-lot with a received LOT and a container', @Expected = N'ok', @Actual = @n;

-- ---- VendorReturn_Cancel voids the linked result: on the LOT too ----
SET @j = (SELECT @MemV1 AS memberId, N'ReturnToSupplier' AS dispositionCode, 3 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;
DECLARE @VR BIGINT = (SELECT Id FROM Lots.VendorReturn WHERE LotId = @V1 AND CancelledAt IS NULL);
INSERT INTO @s EXEC Lots.VendorReturn_Cancel @VendorReturnId = @VR, @CancelRemarks = N'counted wrong', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Events] fix fixture: vendor return cancelled', @Expected = N'1', @Actual = @n;
DELETE FROM @s;
SET @exp = N'TEST-SLV-V1 ' + @Dot + N' Super-lot ' + @RunNumber + N' ' + @Dot + N' Result voided ' + @Dot + N' Return to Supplier 3 (counted wrong)';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description = @exp THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @V1 AND LogEventTypeId = @EvVoided);
EXEC test.Assert_IsEqual @TestName = N'[Events] vendor return cancelled: the voided result is on the LOT', @Expected = N'1|ok', @Actual = @n;

-- ---- ContainerRework_Scrap writes an applied scrap result: on each tray ----
INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @KR, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Events] fix fixture: container opened for rework', @Expected = N'1', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayR1, @DefectCodeId = @Def, @Quantity = 2, @AppUserId = @App;
DELETE FROM @o;
SET @exp = N'% ' + @Dot + N' ' + @KRName + N' ' + @Dot + N' Result recorded ' + @Dot + N' Scrap 2 (' + @DefName + N')';
SET @n = (SELECT CONCAT(COUNT(*), N'|', SUM(CASE WHEN Description LIKE @exp THEN 1 ELSE 0 END), N'|', COUNT(DISTINCT LotId))
          FROM Lots.LotEventLog WHERE LotId IN (@RT1, @RT2) AND LogEventTypeId = @EvResult);
EXEC test.Assert_IsEqual @TestName = N'[Events] rework scrap: the applied result is on each tray, naming the container', @Expected = N'2|2|2', @Actual = @n;

-- ---- ContainerRework_Void ends the membership: Left on each (emptied) tray ----
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayR2, @DefectCodeId = @Def, @Quantity = 2, @AppUserId = @App;
DELETE FROM @o;
INSERT INTO @s EXEC Lots.ContainerRework_Void @ContainerId = @KR, @Remarks = N'all scrapped', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Events] fix fixture: emptied container voided', @Expected = N'1', @Actual = @n;
DELETE FROM @s;
SET @exp = N'% ' + @Dot + N' ' + @KRName + N' ' + @Dot + N' Left (container voided)';
SET @n = (SELECT CONCAT(COUNT(*), N'|', SUM(CASE WHEN Description LIKE @exp THEN 1 ELSE 0 END), N'|', COUNT(DISTINCT LotId))
          FROM Lots.LotEventLog WHERE LotId IN (@RT1, @RT2) AND LogEventTypeId = @EvLeft);
EXEC test.Assert_IsEqual @TestName = N'[Events] container voided: Left on each tray', @Expected = N'2|2|2', @Actual = @n;

-- ---- a member that joins after a deviation is raised: its release names no deviation ----
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'cosmetic',
    @Justification = N'no effect on function', @AppUserId = @App;
DELETE FROM @o;
SET @j = (SELECT @L1 AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @j, @AppUserId = @App;
DELETE FROM @s;
DECLARE @MemL1 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @L1 AND EndedAt IS NULL);
SET @j = (SELECT @MemL1 AS memberId, N'Accepted' AS dispositionCode, 10 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;
SET @j = N'[' + CAST(@MemL1 AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Events] fix fixture: late joiner released', @Expected = N'1', @Actual = @n;
DELETE FROM @o;
SET @exp = N'TEST-SLV-L1 ' + @Dot + N' Super-lot ' + @RunNumber + N' ' + @Dot + N' Released ' + @Dot + N' signed SYS';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(CASE WHEN Description = @exp THEN N'ok' ELSE Description END))
          FROM Lots.LotEventLog WHERE LotId = @L1 AND LogEventTypeId = @EvRel);
EXEC test.Assert_IsEqual @TestName = N'[Events] joined after the deviation: release names no deviation', @Expected = N'1|ok', @Actual = @n;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLV-%';
DECLARE @TdCon TABLE (Id BIGINT);
INSERT INTO @TdCon (Id) SELECT DISTINCT ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.VendorReturn WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.ContainerRework WHERE ContainerId IN (SELECT Id FROM @TdCon);
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
