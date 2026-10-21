-- =============================================
-- File:        0111_ContainerRework/010_rework.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 4 -- container repack. Open for rework (serial + label
--              voided), scrap out of a Closed tray LOT, move loose pieces with
--              Consumption genealogy, stages, resume + re-complete through the existing
--              Lots.Container_Complete (NEW serial), void an emptied container, the
--              super-lot tie-in, and the serialized variants.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0111_ContainerRework/010_rework.sql';
GO
-- ---- teardown (FK-safe): everything this file creates. Containers are found through their
--      TEST-RW- tray LOTs; LOTs are those plus every tray LOT of those containers (a repack
--      mints tray LOTs with ordinary sequence names). ----
DECLARE @TdCon TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdCon (Id) SELECT DISTINCT t.ContainerId FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE l.LotName LIKE N'TEST-RW-%';
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id)
SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RW-%'
UNION SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t WHERE t.ContainerId IN (SELECT Id FROM @TdCon) AND t.FinishedGoodLotId IS NOT NULL;
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.ContainerSerialHistory WHERE ContainerSerialId IN (SELECT cs.Id FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-RW-SN%');
DELETE cs FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-RW-SN%';
DELETE FROM Lots.SerializedPart WHERE SerialNumber LIKE N'TEST-RW-SN%';
DELETE FROM Workorder.ConsumptionEvent WHERE SourceLotId IN (SELECT Id FROM @TdLot) OR ProducedLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @TdLot) OR ChildLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'TEST-RW-%';
DELETE FROM Lots.ContainerRework WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Cfg  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE IsSerialized = 0 AND DeprecatedAt IS NULL AND TraysPerContainer * PartsPerTray >= 8 ORDER BY Id);
DECLARE @Item BIGINT = (SELECT ItemId FROM Parts.ContainerConfig WHERE Id = @Cfg);
DECLARE @PPT  INT    = (SELECT PartsPerTray FROM Parts.ContainerConfig WHERE Id = @Cfg);
DECLARE @TPC  INT    = (SELECT TraysPerContainer FROM Parts.ContainerConfig WHERE Id = @Cfg);
DECLARE @Full INT    = @PPT * @TPC;
DECLARE @CfgS  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE IsSerialized = 1 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @ItemS BIGINT = (SELECT ItemId FROM Parts.ContainerConfig WHERE Id = @CfgS);
DECLARE @Item2 BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL AND Id NOT IN (@Item, @ItemS) ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @Qa   BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE DeprecatedAt IS NULL AND Id NOT IN (@Line, @Term) AND ParentLocationId IS NOT NULL ORDER BY Id DESC);
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);   -- EXEC arguments must be literals or variables: computed expectations go through this
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));

SET @n = CASE WHEN @Cfg IS NOT NULL AND @CfgS IS NOT NULL AND @Full >= 8 THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Rework] fixture: a non-serialized and a serialized container config exist', @Expected = N'ok', @Actual = @n;

-- ---- three FULL completed containers of the same part (A, B: super-lot members; C: untouched) + D of another part ----
DECLARE @C TABLE (Tag NCHAR(1) PRIMARY KEY, Id BIGINT);
DECLARE @Tag NCHAR(1), @Cid BIGINT, @i INT, @Lot BIGINT;
DECLARE tag_cur CURSOR LOCAL FAST_FORWARD FOR SELECT v FROM (VALUES (N'A'), (N'B'), (N'C'), (N'D')) x(v);
OPEN tag_cur; FETCH NEXT FROM tag_cur INTO @Tag;
WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
    VALUES (CASE WHEN @Tag = N'D' THEN @Item2 ELSE @Item END, @Cfg, @Qa, 2, SYSUTCDATETIME(), @App);
    SET @Cid = SCOPE_IDENTITY();
    INSERT INTO @C VALUES (@Tag, @Cid);
    SET @i = 1;
    WHILE @i <= @TPC
    BEGIN
        INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
        VALUES (N'TEST-RW-' + @Tag + CAST(@i AS NVARCHAR(5)), CASE WHEN @Tag = N'D' THEN @Item2 ELSE @Item END, 1, 4, @PPT, 0, @Qa, @App, @Term, 0);
        SET @Lot = SCOPE_IDENTITY();
        INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@Lot, @Lot, 0);
        INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId)
        VALUES (@Cid, @i, @PPT, @Lot, SYSUTCDATETIME(), @App);
        SET @i += 1;
    END
    FETCH NEXT FROM tag_cur INTO @Tag;
END
CLOSE tag_cur; DEALLOCATE tag_cur;
DECLARE @ConA BIGINT = (SELECT Id FROM @C WHERE Tag = N'A');
DECLARE @ConB BIGINT = (SELECT Id FROM @C WHERE Tag = N'B');
DECLARE @ConC BIGINT = (SELECT Id FROM @C WHERE Tag = N'C');
DECLARE @ConD BIGINT = (SELECT Id FROM @C WHERE Tag = N'D');
DECLARE @TrayA1 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @ConA AND TrayPosition = 1);
DECLARE @TrayA2 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @ConA AND TrayPosition = 2);
DECLARE @TrayB1 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @ConB AND TrayPosition = 1);
DECLARE @TrayC1 BIGINT = (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @ConC AND TrayPosition = 1);
DECLARE @LotA1 BIGINT = (SELECT FinishedGoodLotId FROM Lots.ContainerTray WHERE Id = @TrayA1);
DECLARE @LotB1 BIGINT = (SELECT FinishedGoodLotId FROM Lots.ContainerTray WHERE Id = @TrayB1);

-- A's serial is POSTED; B's is claimed but NOT posted. One spare serial for the re-completion.
INSERT INTO Lots.AimShipperIdPool (AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId, Quantity, LotNumber, PostedAt)
VALUES (N'TEST-RW-SER-A', SYSUTCDATETIME(), @ConA, @App, @Full, N'TEST-RW-A1', SYSUTCDATETIME()),
       (N'TEST-RW-SER-B', SYSUTCDATETIME(), @ConB, @App, @Full, N'TEST-RW-B1', NULL);
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, IsVoid) VALUES (@ConA, N'TEST-RW-SER-A', @LabelType, 1, 0);
DECLARE @OldLabelA BIGINT = SCOPE_IDENTITY();

-- A and B are members of an open super-lot (their Closed trays get tagged: piece 2)
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@ConA), (@ConB)) v(containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'repack test', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @MemA BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @ConA AND EndedAt IS NULL);
DECLARE @MemB BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @ConB AND EndedAt IS NULL);
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@MemA, N'Accepted', @Full - 3), (@MemB, N'Accepted', @Full)) v(memberId, dispositionCode, quantity) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT ISNULL(MAX(ReleaseBlockReason), N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId IN (@MemA, @MemB));
EXEC test.Assert_IsEqual @TestName = N'[Rework] fixture: both members have results and are ready to release', @Expected = N'ready', @Actual = @n;

DECLARE @U TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(100), Quantity INT,
                  LotNumber NVARCHAR(50), PostAttempts INT, LastPostError NVARCHAR(MAX), ConsumedAtEt DATETIME2(3),
                  LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);

-- ===== 1. open for rework =====
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConA, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @RwA BIGINT = (SELECT NewId FROM @o);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%opened for rework. Serial TEST-RW-SER-A is voided%' THEN N'msg' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] Status 1; the message names the voided serial', @Expected = N'1|msg', @Actual = @n;
SET @n = (SELECT cs.Code + N'|' + CASE WHEN c.CompletedAt IS NULL THEN N'null' ELSE N'set' END FROM Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId WHERE c.Id = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[Open] status ReworkProcessing, CompletedAt cleared', @Expected = N'ReworkProcessing|null', @Actual = @n;
SET @n = (SELECT CAST(OriginalPieceCount AS NVARCHAR(10)) + N'|' + OriginalAimShipperId + N'|' + CAST(CASE WHEN OriginalShippingLabelId = @OldLabelA AND OriginalCompletedAt IS NOT NULL THEN 1 ELSE 0 END AS NVARCHAR(1))
          FROM Lots.ContainerRework WHERE Id = @RwA);
SET @e = CAST(@Full AS NVARCHAR(10)) + N'|TEST-RW-SER-A|1';
EXEC test.Assert_IsEqual @TestName = N'[Open] the rework row records what the container was', @Expected = @e, @Actual = @n;
SET @n = (SELECT CAST(IsVoid AS NVARCHAR(1)) + N'|' + CAST(CASE WHEN VoidedAt IS NOT NULL AND VoidedByUserId = @App THEN 1 ELSE 0 END AS NVARCHAR(1)) FROM Lots.ShippingLabel WHERE Id = @OldLabelA);
EXEC test.Assert_IsEqual @TestName = N'[Open] the shipping label is voided', @Expected = N'1|1', @Actual = @n;
SET @n = (SELECT CASE WHEN VoidedAt IS NOT NULL THEN N'voided' ELSE N'live' END + N'|' + CASE WHEN PostedAt IS NOT NULL THEN N'posted' ELSE N'unposted' END
          FROM Lots.AimShipperIdPool WHERE AimShipperId = N'TEST-RW-SER-A');
EXEC test.Assert_IsEqual @TestName = N'[Open] the serial is voided on the pool row; nothing about its post changes', @Expected = N'voided|posted', @Actual = @n;
SET @n = (SELECT CAST(SUM(CAST(l.CrtActive AS INT)) AS NVARCHAR(5)) + N'|' + CAST(MIN(l.LotStatusId) AS NVARCHAR(5)) + N'|' + CAST(MAX(l.LotStatusId) AS NVARCHAR(5))
          FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE t.ContainerId = @ConA);
SET @e = CAST(@TPC AS NVARCHAR(5)) + N'|4|4';
EXEC test.Assert_IsEqual @TestName = N'[Open] the tray LOTs are NOT reopened: still Closed (4), still tagged', @Expected = @e, @Actual = @n;
SET @n = (SELECT ISNULL(ReleaseBlockReason, N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Open] a member being reworked cannot be released', @Expected = N'Being reworked', @Actual = @n;
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%Being reworked%' THEN N'reworked' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] the signed release refuses it, by reason', @Expected = N'0|reworked', @Actual = @n;
INSERT INTO @s EXEC Lots.Container_ValidateCrt @ContainerId = @ConA, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Open] it cannot be validated one at a time either', @Expected = N'0', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConA, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%already open for rework%' THEN N'already' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] a second open is refused', @Expected = N'0|already', @Actual = @n;

-- B: its serial was never posted. Voiding it must take it out of the AIM sweep for good.
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;      -- (tagged, so already held; clear the tag to prove the VOID is what holds it)
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConB, @AppUserId = @App;
UPDATE l SET CrtActive = 0 FROM Lots.Lot l JOIN Lots.ContainerTray t ON t.FinishedGoodLotId = l.Id WHERE t.ContainerId = @ConB;
DELETE FROM @U;
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @U WHERE AimShipperId = N'TEST-RW-SER-B');
EXEC test.Assert_IsEqual @TestName = N'[Open] a voided, never-posted serial is not offered to the AIM sweep, even untagged', @Expected = N'0', @Actual = @n;
UPDATE l SET CrtActive = 1 FROM Lots.Lot l JOIN Lots.ContainerTray t ON t.FinishedGoodLotId = l.Id WHERE t.ContainerId = @ConB;

DECLARE @V TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, PartNumber NVARCHAR(100), Quantity INT, LotNumber NVARCHAR(50),
    WasPosted BIT, PostedAt DATETIME2(3), VoidedAt DATETIME2(3), VoidedByInitials NVARCHAR(20), VoidReason NVARCHAR(200), ReplacedByAimShipperId NVARCHAR(50));
INSERT INTO @V EXEC Lots.AimShipperIdPool_ListVoided;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(CAST(WasPosted AS INT)) AS NVARCHAR(5)) FROM @V WHERE AimShipperId LIKE N'TEST-RW-%');
EXEC test.Assert_IsEqual @TestName = N'[Voided list] both voided serials listed; one of them is one AIM still believes', @Expected = N'2|1', @Actual = @n;
DELETE FROM @V;
INSERT INTO @V EXEC Lots.AimShipperIdPool_ListVoided @OnlyPosted = 1;
SET @n = (SELECT MAX(AimShipperId) FROM @V WHERE AimShipperId LIKE N'TEST-RW-%');
EXEC test.Assert_IsEqual @TestName = N'[Voided list] OnlyPosted = the cancellation worklist', @Expected = N'TEST-RW-SER-A', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = 999999999, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] unknown container', @Expected = N'0|Container not found.', @Actual = @n;

-- ===== 2. scrap out of a Closed tray LOT =====
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayA1, @DefectCodeId = @Def, @Quantity = 2, @Remarks = N'  porosity  ', @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Rej1 BIGINT = (SELECT NewId FROM @o);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] Status 1', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(l.PieceCount AS NVARCHAR(5)) + N'|' + CAST(t.PartsClosedCount AS NVARCHAR(5)) + N'|' + CAST(l.LotStatusId AS NVARCHAR(5))
          FROM Lots.Lot l JOIN Lots.ContainerTray t ON t.FinishedGoodLotId = l.Id WHERE t.Id = @TrayA1);
SET @e = CAST(@PPT - 2 AS NVARCHAR(5)) + N'|' + CAST(@PPT - 2 AS NVARCHAR(5)) + N'|4';
EXEC test.Assert_IsEqual @TestName = N'[Scrap] tray LOT and tray both lose 2; the LOT stays Closed', @Expected = @e, @Actual = @n;
SET @n = (SELECT CAST(Quantity AS NVARCHAR(5)) + N'|' + Remarks + N'|' + CAST(CASE WHEN LotId = @LotA1 AND ItemId = @Item AND TerminalLocationId = @Term THEN 1 ELSE 0 END AS NVARCHAR(1))
          FROM Workorder.RejectEvent WHERE Id = @Rej1);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a real RejectEvent against the tray LOT', @Expected = N'2|porosity|1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MAX(rr.Quantity) AS NVARCHAR(5)) FROM Quality.ControlledRunResult rr
          WHERE rr.ControlledRunMemberId = @MemA AND rr.RejectEventId = @Rej1 AND rr.VoidedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a super-lot member: the scrap is also an APPLIED result entry', @Expected = N'1|2', @Actual = @n;
SET @n = (SELECT CAST(ScrapQty AS NVARCHAR(5)) + N'|' + CAST(AppliedScrapQty AS NVARCHAR(5)) + N'|' + CAST(LeftOver AS NVARCHAR(5)) FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] Results agree: 2 scrap applied, 1 piece still left over', @Expected = N'2|2|1', @Actual = @n;

-- apply a scrap that piece 3 only RECORDED
DELETE FROM @o;
SET @j = (SELECT @MemA AS memberId, N'Scrap' AS dispositionCode, 1 AS quantity, @Def AS defectCodeId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DECLARE @Intent BIGINT = (SELECT NewId FROM @o);
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayA2, @DefectCodeId = @Def, @Quantity = 2, @ControlledRunResultId = @Intent, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'That recorded scrap does not match%' THEN N'mismatch' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] applying a recorded scrap with the wrong quantity is refused', @Expected = N'0|mismatch', @Actual = @n;
DELETE FROM @o;
-- (defect and quantity left out: they are taken from the recorded scrap, as the Repack screen does)
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayA2, @ControlledRunResultId = @Intent, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST(CASE WHEN rr.RejectEventId = o.NewId THEN 1 ELSE 0 END AS NVARCHAR(1)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult x JOIN Quality.DispositionCode d ON d.Id = x.DispositionCodeId
                       WHERE x.ControlledRunMemberId = @MemA AND d.Code = N'Scrap') AS NVARCHAR(5))
          FROM @o o, Quality.ControlledRunResult rr WHERE rr.Id = @Intent);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] applying a recorded scrap points IT at the reject; no second entry', @Expected = N'1|1|2', @Actual = @n;
SET @n = (SELECT CAST(LeftOver AS NVARCHAR(5)) FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] the member is now fully accounted for', @Expected = N'0', @Actual = @n;

DECLARE @RejBefore INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId IN (SELECT FinishedGoodLotId FROM Lots.ContainerTray WHERE ContainerId IN (@ConA, @ConB, @ConC)));
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayA1, @DefectCodeId = @Def, @Quantity = 999, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%is too many.' THEN N'toomany' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] more than the tray holds is refused', @Expected = N'0|toomany', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayC1, @DefectCodeId = @Def, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%is not open for rework.' THEN N'notopen' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a container that is NOT open for rework cannot be scrapped from', @Expected = N'0|notopen', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayA1, @DefectCodeId = @Def, @Quantity = 1, @ContainerSerialId = 12345, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'This part is not serialized%' THEN N'notserial' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] a serial against a part that is not serialized is refused', @Expected = N'0|notserial', @Actual = @n;
SET @n = (SELECT CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId IN (SELECT FinishedGoodLotId FROM Lots.ContainerTray WHERE ContainerId IN (@ConA, @ConB, @ConC))) - @RejBefore AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Scrap] the refusals wrote nothing', @Expected = N'0', @Actual = @n;

-- ===== 3. move loose pieces (A is short 3; B is the donor) =====
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayB1, @ToContainerId = @ConA, @Quantity = 3, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%is not refill-ready.' THEN N'notready' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Move] the receiver must be refill-ready', @Expected = N'0|notready', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConA, @StageCode = N'Filling', @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + cs.Code FROM @s s, Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId WHERE c.Id = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[Stage] Filling -> ReworkFilling', @Expected = N'1|ReworkFilling', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayB1, @ToContainerId = @ConA, @Quantity = 4, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%has room for 3 more pieces; 4 is too many.' THEN N'room' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Move] more than the receiver has room for is refused', @Expected = N'0|room', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayA1, @ToContainerId = @ConA, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Move] same container refused', @Expected = N'0|Those pieces are already in that container.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayC1, @ToContainerId = @ConA, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%is not open for rework.' THEN N'donor' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Move] the DONOR must itself be open for rework', @Expected = N'0|donor', @Actual = @n;

DECLARE @SeqBefore BIGINT = (SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot');
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayB1, @ToContainerId = @ConA, @Quantity = 3, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @NewTray BIGINT = (SELECT NewId FROM @o);
DECLARE @NewLot BIGINT = (SELECT FinishedGoodLotId FROM Lots.ContainerTray WHERE Id = @NewTray);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'3 moved into container %; it now holds ' + CAST(@Full AS NVARCHAR(10)) + N' of ' + CAST(@Full AS NVARCHAR(10)) + N'.' THEN N'full' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Move] Status 1; the receiver is full again', @Expected = N'1|full', @Actual = @n;
SET @n = (SELECT CAST(t.ContainerId AS NVARCHAR(20)) + N'|' + CAST(t.PartsClosedCount AS NVARCHAR(5)) + N'|' + CAST(l.PieceCount AS NVARCHAR(5)) + N'|' + CAST(l.LotStatusId AS NVARCHAR(5))
               + N'|' + CAST(l.LotOriginTypeId AS NVARCHAR(5)) + N'|' + CAST(l.ItemId AS NVARCHAR(20)) + N'|' + CAST(l.InventoryAvailable AS NVARCHAR(5))
          FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE t.Id = @NewTray);
SET @e = CAST(@ConA AS NVARCHAR(20)) + N'|3|3|4|1|' + CAST(@Item AS NVARCHAR(20)) + N'|0';
EXEC test.Assert_IsEqual @TestName = N'[Move] a NEW tray LOT in the receiver: 3 pieces, Closed (4), Manufactured (1), same part, nothing available',
    @Expected = @e, @Actual = @n;
SET @n = (SELECT CAST(l.PieceCount AS NVARCHAR(5)) + N'|' + CAST(t.PartsClosedCount AS NVARCHAR(5)) FROM Lots.Lot l JOIN Lots.ContainerTray t ON t.FinishedGoodLotId = l.Id WHERE t.Id = @TrayB1);
SET @e = CAST(@PPT - 3 AS NVARCHAR(5)) + N'|' + CAST(@PPT - 3 AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[Move] the donor tray LOT and tray both lose 3', @Expected = @e, @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MAX(g.RelationshipTypeId) AS NVARCHAR(5)) + N'|' + CAST(MAX(g.PieceCount) AS NVARCHAR(5))
          FROM Lots.LotGenealogy g WHERE g.ParentLotId = @LotB1 AND g.ChildLotId = @NewLot);
EXEC test.Assert_IsEqual @TestName = N'[Move] one Consumption (3) genealogy edge donor LOT -> new LOT, for 3 pieces', @Expected = N'1|3|3', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Lots.LotGenealogyClosure WHERE DescendantLotId = @NewLot AND AncestorLotId IN (@LotB1, @NewLot));
EXEC test.Assert_IsEqual @TestName = N'[Move] closure: the new LOT descends from itself and from the donor LOT', @Expected = N'2', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MAX(ce.PieceCount) AS NVARCHAR(5)) + N'|' + CAST(MAX(CASE WHEN ce.ConsumedItemId = ce.ProducedItemId AND ce.ProducedContainerId = @ConA AND ce.TrayId = @NewTray THEN 1 ELSE 0 END) AS NVARCHAR(1))
          FROM Workorder.ConsumptionEvent ce WHERE ce.SourceLotId = @LotB1 AND ce.ProducedLotId = @NewLot);
EXEC test.Assert_IsEqual @TestName = N'[Move] one ConsumptionEvent, same Item both sides, pointing at the receiving container and tray', @Expected = N'1|3|1', @Actual = @n;
SET @n = (SELECT CAST(d.CrtActive AS NVARCHAR(1)) + N'|' + CAST(n.CrtActive AS NVARCHAR(1)) FROM Lots.Lot d, Lots.Lot n WHERE d.Id = @LotB1 AND n.Id = @NewLot);
EXEC test.Assert_IsEqual @TestName = N'[Move] the new LOT inherits the donor LOT''s Controlled Run Tag', @Expected = N'1|1', @Actual = @n;
SET @n = (SELECT CAST((SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'Lot') - @SeqBefore AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Move] exactly one LOT number used (the refusals burned none)', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(SUM(t.PartsClosedCount) AS NVARCHAR(10)) + N'|' + CAST(SUM(l.PieceCount) AS NVARCHAR(10)) FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE t.ContainerId = @ConA);
SET @e = CAST(@Full AS NVARCHAR(10)) + N'|' + CAST(@Full AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Move] receiver: trays and tray LOTs agree at the full count', @Expected = @e, @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConD, @StageCode = N'Filling', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%is not open for rework.' THEN N'notopen' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Stage] a container that is not in rework has no stage to change', @Expected = N'0|notopen', @Actual = @n;
DELETE FROM @o; INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConD, @AppUserId = @App;
DELETE FROM @s; INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConD, @StageCode = N'Filling', @AppUserId = @App;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayB1, @ToContainerId = @ConD, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%holds a different part.' THEN N'part' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Move] a container of a different part is refused', @Expected = N'0|part', @Actual = @n;

-- ===== 4. reads =====
DECLARE @G TABLE (ContainerId BIGINT, StatusCode NVARCHAR(50), StatusName NVARCHAR(100), ItemId BIGINT, PartNumber NVARCHAR(100), ItemDescription NVARCHAR(500),
    CurrentLocationId BIGINT, CurrentLocationName NVARCHAR(200), IsSerialized BIT, TargetParts INT, Pieces INT, ShortBy INT, LiveAimShipperId NVARCHAR(50),
    OriginalAimShipperId NVARCHAR(50), ReworkOpenedAt DATETIME2(3), ReworkOpenedByInitials NVARCHAR(20), RunNumber NVARCHAR(15), ControlledRunId BIGINT, MemberId BIGINT,
    InRework BIT, CanOpen BIT, CanScrapOrMove BIT, CanSetFilling BIT, CanSetProcessing BIT, CanCompleteHere BIT, CanVoid BIT);
INSERT INTO @G EXEC Lots.ContainerRework_Get @ContainerId = @ConA;
SET @n = (SELECT StatusCode + N'|' + CAST(ShortBy AS NVARCHAR(5)) + N'|' + ISNULL(LiveAimShipperId, N'none') + N'|' + OriginalAimShipperId + N'|' + RunNumber + N'|'
               + CAST(InRework AS NVARCHAR(1)) + CAST(CanOpen AS NVARCHAR(1)) + CAST(CanScrapOrMove AS NVARCHAR(1)) + CAST(CanSetFilling AS NVARCHAR(1))
               + CAST(CanSetProcessing AS NVARCHAR(1)) + CAST(CanCompleteHere AS NVARCHAR(1)) + CAST(CanVoid AS NVARCHAR(1)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] refill-ready and full: no live serial, the old one remembered, what may be done now', @Expected = N'ReworkFilling|0|none|TEST-RW-SER-A|CR000001|1010110', @Actual = @n;
DELETE FROM @G;
INSERT INTO @G EXEC Lots.ContainerRework_Get @ContainerId = @ConC;
SET @n = (SELECT StatusCode + N'|' + CAST(InRework AS NVARCHAR(1)) + CAST(CanOpen AS NVARCHAR(1)) + CAST(CanScrapOrMove AS NVARCHAR(1)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] an untouched complete container can only be opened', @Expected = N'Complete|010', @Actual = @n;

DECLARE @TL TABLE (ContainerTrayId BIGINT, TrayPosition INT, Pieces INT, LotId BIGINT, LotName NVARCHAR(50), CrtActive BIT, MovedFromLotName NVARCHAR(50));
INSERT INTO @TL EXEC Lots.ContainerRework_ListTrays @ContainerId = @ConA;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(Pieces) AS NVARCHAR(10)) + N'|' + MAX(MovedFromLotName) FROM @TL);
SET @e = CAST(@TPC + 1 AS NVARCHAR(5)) + N'|' + CAST(@Full AS NVARCHAR(10)) + N'|TEST-RW-B1';
EXEC test.Assert_IsEqual @TestName = N'[ListTrays] the original trays plus the top-up tray, which says where it came from', @Expected = @e, @Actual = @n;

DECLARE @TG TABLE (ContainerId BIGINT, CurrentLocationName NVARCHAR(200), Pieces INT, TargetParts INT, Room INT);
INSERT INTO @TG EXEC Lots.ContainerRework_ListTargets @ContainerId = @ConB;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @TG);
EXEC test.Assert_IsEqual @TestName = N'[ListTargets] A is full, D is another part: nowhere for B''s pieces to go', @Expected = N'0', @Actual = @n;

-- ===== 5. send to the line, resume, recall, resume, re-complete =====
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConA, @StageCode = N'Filling', @LocationId = @Line, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(CASE WHEN c.CurrentLocationId = @Line THEN 1 ELSE 0 END AS NVARCHAR(1)) FROM @s s, Lots.Container c WHERE c.Id = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[Stage] send to line: the container is now at the line', @Expected = N'1|1', @Actual = @n;
DECLARE @AL TABLE (ContainerId BIGINT, PartNumber NVARCHAR(100), ItemDescription NVARCHAR(500), Pieces INT, TargetParts INT, ShortBy INT, PartsPerTray INT, RunNumber NVARCHAR(15));
INSERT INTO @AL EXEC Lots.ContainerRework_ListAtLocation @LocationId = @Line;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(RunNumber) FROM @AL WHERE ContainerId = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[ListAtLocation] the line sees one refill-ready container waiting', @Expected = N'1|CR000001', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Resume @ContainerId = @ConB, @CellLocationId = @Line, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%is not refill-ready yet.' THEN N'notyet' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Resume] a container still in processing cannot be picked up', @Expected = N'0|notyet', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Resume @ContainerId = @ConA, @CellLocationId = @Line, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + cs.Code + N'|' + CAST(CASE WHEN c.CurrentLocationId = @Line AND c.StationLocationId = @Term THEN 1 ELSE 0 END AS NVARCHAR(1))
               + N'|' + CAST(CASE WHEN r.ResumedAt IS NOT NULL AND r.ResumedAtLocationId = @Line THEN 1 ELSE 0 END AS NVARCHAR(1))
          FROM @s s, Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId, Lots.ContainerRework r WHERE c.Id = @ConA AND r.Id = @RwA);
EXEC test.Assert_IsEqual @TestName = N'[Resume] it is the Open container at the line, owned by the station that picked it up; the rework row says who and where', @Expected = N'1|Open|1|1', @Actual = @n;
SET @n = (SELECT CAST(CASE WHEN (SELECT TOP 1 Id FROM Lots.Container WHERE CurrentLocationId = @Line AND ItemId = @Item AND ContainerStatusCodeId = 1 ORDER BY OpenedAt, Id) = @ConA THEN 1 ELSE 0 END AS NVARCHAR(1)));
EXEC test.Assert_IsEqual @TestName = N'[Resume] it is the one the line''s own pick (oldest open, by OpenedAt) lands on', @Expected = N'1', @Actual = @n;
SET @n = (SELECT ISNULL(ReleaseBlockReason, N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Resume] resumed but not complete: still "Being reworked"', @Expected = N'Being reworked', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConA, @StageCode = N'Processing', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%Recall it to refill-ready first.' THEN N'recall' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Stage] a container at the line cannot jump straight back to processing', @Expected = N'0|recall', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConA, @StageCode = N'Filling', @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + cs.Code + N'|' + CASE WHEN r.ResumedAt IS NULL THEN N'cleared' ELSE N'still' END
          FROM @s s, Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId, Lots.ContainerRework r WHERE c.Id = @ConA AND r.Id = @RwA);
EXEC test.Assert_IsEqual @TestName = N'[Stage] recall from the line: back to ReworkFilling, no longer resumed', @Expected = N'1|ReworkFilling|cleared', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Resume @ContainerId = @ConA, @CellLocationId = @Line, @AppUserId = @App;

-- Review finding: a gap that is not a whole number of trays must never reach a line. D is
-- refill-ready and full; take ONE piece out of it and it is short by 1.
DECLARE @TrayD1 BIGINT = (SELECT TOP 1 Id FROM Lots.ContainerTray WHERE ContainerId = @ConD ORDER BY TrayPosition);
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayD1, @DefectCodeId = @Def, @Quantity = 1, @AppUserId = @App;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Resume @ContainerId = @ConD, @CellLocationId = @Line, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CASE WHEN s.Message LIKE N'%is short by 1, which is not a whole number of trays%' THEN N'ragged' ELSE s.Message END
               + N'|' + cs.Code FROM @s s, Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId WHERE c.Id = @ConD);
EXEC test.Assert_IsEqual @TestName = N'[Resume] a gap that is not a whole number of trays cannot go to a line (it would be packed past its target)', @Expected = N'0|ragged|ReworkFilling', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConD, @StageCode = N'Filling', @LocationId = @Line, @AppUserId = @App;
DELETE FROM @AL;
INSERT INTO @AL EXEC Lots.ContainerRework_ListAtLocation @LocationId = @Line;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @AL WHERE ContainerId = @ConD);
EXEC test.Assert_IsEqual @TestName = N'[ListAtLocation] ...and the line is not offered it', @Expected = N'0', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = 999999999, @DefectCodeId = @Def, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Scrap] an unknown tray says so (the first failing rule is the message)', @Expected = N'0|Tray not found.', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Resume @ContainerId = 999999999, @CellLocationId = @Line, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Resume] an unknown container says so', @Expected = N'0|Container not found.', @Actual = @n;

-- re-complete through the EXISTING, unmodified completion proc
INSERT INTO Lots.AimShipperIdPool (AimShipperId) VALUES (N'TEST-RW-NEW1');
UPDATE Lots.AimShipperIdPool SET FetchedAt = '2000-01-01' WHERE AimShipperId = N'TEST-RW-NEW1';     -- FIFO: make it the next one claimed
DECLARE @CC TABLE (Status BIT, Message NVARCHAR(500), ShippingLabelId BIGINT, AimShipperId NVARCHAR(50));
INSERT INTO @CC EXEC Lots.Container_Complete @ContainerId = @ConA, @OperatorConfirmed = 1, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + ISNULL(AimShipperId, N'none') FROM @CC);
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] Lots.Container_Complete completes it and claims a NEW serial', @Expected = N'1|TEST-RW-NEW1', @Actual = @n;
SET @n = (SELECT cs.Code + N'|' + CASE WHEN c.CompletedAt IS NOT NULL THEN N'set' ELSE N'null' END FROM Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId WHERE c.Id = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] Complete again, CompletedAt set again', @Expected = N'Complete|set', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(CASE WHEN IsVoid = 0 THEN 1 ELSE 0 END) AS NVARCHAR(5)) + N'|' + MAX(CASE WHEN IsVoid = 0 THEN AimShipperId END)
          FROM Lots.ShippingLabel WHERE ContainerId = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] two labels on record: the old one void, one live carrying the new serial', @Expected = N'2|1|TEST-RW-NEW1', @Actual = @n;
DELETE FROM @G;
INSERT INTO @G EXEC Lots.ContainerRework_Get @ContainerId = @ConA;
SET @n = (SELECT StatusCode + N'|' + LiveAimShipperId + N'|' + OriginalAimShipperId + N'|' + CAST(InRework AS NVARCHAR(1)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] its serial, read by container, is the NEW one; no longer in rework', @Expected = N'Complete|TEST-RW-NEW1|TEST-RW-SER-A|0', @Actual = @n;
SET @n = (SELECT CAST(MIN(l.LotStatusId) AS NVARCHAR(5)) + N'|' + CAST(MAX(l.LotStatusId) AS NVARCHAR(5)) FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE t.ContainerId = @ConA);
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] every tray LOT, the top-up one included, is Closed', @Expected = N'4|4', @Actual = @n;
DECLARE @LP TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
INSERT INTO @LP EXEC Lots.Container_ListPendingValidation @LocationId = NULL, @ContainerId = @ConA;
SET @n = (SELECT ISNULL(MAX(AimShipperId), N'none') FROM @LP);
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] pending validation shows the LIVE serial, never the voided one', @Expected = N'TEST-RW-NEW1', @Actual = @n;
DELETE FROM @U;
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @U WHERE AimShipperId LIKE N'TEST-RW-%');
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] still a tagged super-lot member: the new serial is held from AIM', @Expected = N'0', @Actual = @n;

-- now it can be released, and only the NEW serial is owed to AIM
SET @n = (SELECT ISNULL(ReleaseBlockReason, N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Re-complete] the member is ready to release again', @Expected = N'ready', @Actual = @n;
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
DELETE FROM @U;
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;
SET @n = (SELECT CAST((SELECT TOP 1 Status FROM @o) AS NVARCHAR(1)) + N'|' + ISNULL((SELECT STRING_AGG(AimShipperId, N',') FROM @U WHERE AimShipperId LIKE N'TEST-RW-%'), N'none'));
EXEC test.Assert_IsEqual @TestName = N'[Release] released: exactly the NEW serial is owed to AIM; the voided ones never are', @Expected = N'1|TEST-RW-NEW1', @Actual = @n;

-- ===== 6. void an emptied container =====
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Void @ContainerId = @ConB, @Remarks = N'emptied', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%still holds ' + CAST(@Full - 3 AS NVARCHAR(10)) + N' pieces. Move or scrap them first.' THEN N'pieces' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] refused while it still holds pieces', @Expected = N'0|pieces', @Actual = @n;
DECLARE @t BIGINT, @q INT;
DECLARE b_cur CURSOR LOCAL FAST_FORWARD FOR SELECT Id, PartsClosedCount FROM Lots.ContainerTray WHERE ContainerId = @ConB AND PartsClosedCount > 0;
OPEN b_cur; FETCH NEXT FROM b_cur INTO @t, @q;
WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM @o;
    INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @t, @DefectCodeId = @Def, @Quantity = @q, @AppUserId = @App;
    FETCH NEXT FROM b_cur INTO @t, @q;
END
CLOSE b_cur; DEALLOCATE b_cur;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Void @ContainerId = @ConB, @Remarks = N'   ', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] a reason is required', @Expected = N'0|A reason is required to void a container.', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Void @ContainerId = @ConB, @Remarks = N'all good parts moved, rest scrapped', @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + cs.Code + N'|' + CASE WHEN s.Message LIKE N'%It has left super-lot CR000001.' THEN N'left' ELSE s.Message END
          FROM @s s, Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId WHERE c.Id = @ConB);
EXEC test.Assert_IsEqual @TestName = N'[Void] an emptied container is voided and leaves its super-lot', @Expected = N'1|Void|left', @Actual = @n;
SET @n = (SELECT CAST(ControlledRunMemberEndReasonId AS NVARCHAR(5)) + N'|' + EndRemarks FROM Quality.ControlledRunMember WHERE Id = @MemB);
EXEC test.Assert_IsEqual @TestName = N'[Void] membership ended as ContainerVoided (5) with the reason', @Expected = N'5|all good parts moved, rest scrapped', @Actual = @n;
SET @n = (SELECT CAST(SUM(CAST(l.CrtActive AS INT)) AS NVARCHAR(5)) FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE t.ContainerId = @ConB);
EXEC test.Assert_IsEqual @TestName = N'[Void] no empty tray LOT is left tagged', @Expected = N'0', @Actual = @n;
DECLARE @RG TABLE (Id BIGINT, RunNumber NVARCHAR(15), StatusCode NVARCHAR(20), Reason NVARCHAR(500), AnchorLotId BIGINT, AnchorLotName NVARCHAR(50),
    SelectionItemId BIGINT, PartNumber NVARCHAR(100), SelectionLocationId BIGINT, LocationName NVARCHAR(200), SelectionFromAt DATETIME2(3),
    SelectionToAt DATETIME2(3), IncludeDescendants BIT, AutoJoinEnabled BIT, AutoJoinEndedAt DATETIME2(3), OpenedByInitials NVARCHAR(20),
    OpenedAt DATETIME2(3), ClosedByInitials NVARCHAR(20), ClosedAt DATETIME2(3), CloseRemarks NVARCHAR(500), MemberCount INT, ClearedCount INT,
    PieceCount INT, CriteriaText NVARCHAR(400), CanClose BIT, CloseBlockedReason NVARCHAR(200));
INSERT INTO @RG EXEC Quality.ControlledRun_Get @Id = @Run;
SET @n = (SELECT CAST(MemberCount AS NVARCHAR(5)) + N'|' + CAST(ClearedCount AS NVARCHAR(5)) FROM @RG);
EXEC test.Assert_IsEqual @TestName = N'[Void] the super-lot still counts both: one released, one voided, both cleared', @Expected = N'2|2', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] with nothing outstanding the super-lot closes', @Expected = N'1', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConB, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%is Void. Only a completed, unshipped container%' THEN N'void' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Open] a voided container cannot be reopened', @Expected = N'0|void', @Actual = @n;

-- ===== 7. serialized: one serial at a time =====
DECLARE @LotS1 BIGINT, @LotS2 BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
VALUES (N'TEST-RW-S1', @ItemS, 1, 4, 2, 0, @Qa, @App, @Term, 0);
SET @LotS1 = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
VALUES (N'TEST-RW-S2', @ItemS, 1, 4, 1, 0, @Qa, @App, @Term, 0);
SET @LotS2 = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotS1, @LotS1, 0), (@LotS2, @LotS2, 0);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId) VALUES (@ItemS, @CfgS, @Qa, 2, SYSUTCDATETIME(), @App);
DECLARE @ConS1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId) VALUES (@ItemS, @CfgS, @Qa, 2, SYSUTCDATETIME(), @App);
DECLARE @ConS2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId) VALUES (@ConS1, 1, 2, @LotS1, SYSUTCDATETIME(), @App);
DECLARE @TrayS1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, ClosedByUserId) VALUES (@ConS2, 1, 1, @LotS2, SYSUTCDATETIME(), @App);
DECLARE @TrayS2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId) VALUES (N'TEST-RW-SN1', @ItemS, @LotS1, SYSUTCDATETIME(), @App);
DECLARE @Sp1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId) VALUES (N'TEST-RW-SN2', @ItemS, @LotS1, SYSUTCDATETIME(), @App);
DECLARE @Sp2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.SerializedPart (SerialNumber, ItemId, ProducingLotId, EtchedAt, EtchedByUserId) VALUES (N'TEST-RW-SN3', @ItemS, @LotS2, SYSUTCDATETIME(), @App);
DECLARE @Sp3 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed) VALUES (@ConS1, @TrayS1, @Sp1, 1, 0);
DECLARE @Cs1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed) VALUES (@ConS1, @TrayS1, @Sp2, 1, 0);
DECLARE @Cs2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerSerial (ContainerId, ContainerTrayId, SerializedPartId, TrayPosition, HardwareInterlockBypassed) VALUES (@ConS2, @TrayS2, @Sp3, 1, 0);
DECLARE @Cs3 BIGINT = SCOPE_IDENTITY();
DELETE FROM @o; INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConS1, @AppUserId = @App;
DELETE FROM @o; INSERT INTO @o EXEC Lots.ContainerRework_Open @ContainerId = @ConS2, @AppUserId = @App;
DELETE FROM @s; INSERT INTO @s EXEC Lots.ContainerRework_SetStage @ContainerId = @ConS2, @StageCode = N'Filling', @AppUserId = @App;

DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayS1, @DefectCodeId = @Def, @Quantity = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] a quantity with no serial is refused', @Expected = N'0|This part is serialized: pick the serial.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayS1, @DefectCodeId = @Def, @Quantity = 2, @ContainerSerialId = @Cs1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] more than one per call is refused', @Expected = N'0|A serialized part is handled one serial at a time.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayS1, @DefectCodeId = @Def, @Quantity = 1, @ContainerSerialId = @Cs3, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] a serial from ANOTHER container is refused', @Expected = N'0|That serial is not in this tray.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayS1, @DefectCodeId = @Def, @Quantity = 1, @ContainerSerialId = @Cs1, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CASE WHEN cs.RemovedAt IS NOT NULL AND cs.RemovedRejectEventId = o.NewId THEN N'removed' ELSE N'still' END
               + N'|' + CAST(l.PieceCount AS NVARCHAR(5)) FROM @o o, Lots.ContainerSerial cs, Lots.Lot l WHERE cs.Id = @Cs1 AND l.Id = @LotS1);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] scrap one serial: marked removed against the reject, LOT down to 1', @Expected = N'1|removed|1', @Actual = @n;
DECLARE @LS TABLE (SerializedPartId BIGINT, SerialNumber NVARCHAR(100), TrayPosition INT, ProducingLotId BIGINT, ProducingLotName NVARCHAR(50), RemovedAt DATETIME2(3), RemovedReason NVARCHAR(500), MovedInFromContainerName NVARCHAR(50), MovedInAt DATETIME2(3));
INSERT INTO @LS EXEC Lots.Container_ListSerials @ContainerId = @ConS1;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(SerialNumber) FROM @LS);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] the scrapped serial is gone from the container''s serial list', @Expected = N'1|TEST-RW-SN2', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_Scrap @ContainerTrayId = @TrayS1, @DefectCodeId = @Def, @Quantity = 1, @ContainerSerialId = @Cs1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] a serial already scrapped cannot be scrapped again', @Expected = N'0|That serial is not in this tray.', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @TrayS1, @ToContainerId = @ConS2, @Quantity = 1, @ContainerSerialId = @Cs2, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST(CASE WHEN cs.ContainerId = @ConS2 AND cs.ContainerTrayId = o.NewId THEN 1 ELSE 0 END AS NVARCHAR(1))
               + N'|' + CAST((SELECT COUNT(*) FROM Lots.ContainerSerialHistory h WHERE h.ContainerSerialId = @Cs2 AND h.OldContainerId = @ConS1 AND h.NewContainerId = @ConS2 AND h.MigrationReasonCode = N'SuperLotRepack') AS NVARCHAR(5))
               + N'|' + CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @LotS1) AS NVARCHAR(5))
          FROM @o o, Lots.ContainerSerial cs WHERE cs.Id = @Cs2);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] move one serial: it goes to the receiver''s new tray with a history row; donor LOT empty', @Expected = N'1|1|1|0', @Actual = @n;
SET @n = (SELECT ce.ProducedSerialNumber FROM Workorder.ConsumptionEvent ce WHERE ce.SourceLotId = @LotS1 AND ce.ProducedContainerId = @ConS2);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] the consumption names the serial that moved', @Expected = N'TEST-RW-SN2', @Actual = @n;
DECLARE @RS TABLE (ContainerSerialId BIGINT, SerialNumber NVARCHAR(100), ContainerTrayId BIGINT, TrayPosition INT, ProducingLotName NVARCHAR(50));
INSERT INTO @RS EXEC Lots.ContainerRework_ListSerials @ContainerId = @ConS2;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MIN(SerialNumber) + N'|' + MAX(ProducingLotName) FROM @RS);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] the receiver lists both serials; a moved one still names the LOT that made it', @Expected = N'2|TEST-RW-SN2|TEST-RW-S2', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.ContainerRework_Void @ContainerId = @ConS1, @Remarks = N'emptied', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Serialized] the emptied donor can be voided', @Expected = N'1', @Actual = @n;
GO
-- ---- teardown (FK-safe): everything this file creates. Containers are found through their
--      TEST-RW- tray LOTs; LOTs are those plus every tray LOT of those containers (a repack
--      mints tray LOTs with ordinary sequence names). ----
DECLARE @TdCon TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdCon (Id) SELECT DISTINCT t.ContainerId FROM Lots.ContainerTray t JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId WHERE l.LotName LIKE N'TEST-RW-%';
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id)
SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-RW-%'
UNION SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t WHERE t.ContainerId IN (SELECT Id FROM @TdCon) AND t.FinishedGoodLotId IS NOT NULL;
DELETE FROM Quality.ControlledRunResult;
DELETE FROM Quality.ControlledRunLabel;
DELETE FROM Quality.ControlledRunMember;
DELETE FROM Quality.ControlledRunRelease;
DELETE FROM Quality.ControlledRunDeviation;
ALTER TABLE Quality.Signature DISABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.Signature;
ALTER TABLE Quality.Signature ENABLE TRIGGER TR_Signature_Immutable;
DELETE FROM Quality.ControlledRun;
DELETE FROM Lots.ContainerSerialHistory WHERE ContainerSerialId IN (SELECT cs.Id FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-RW-SN%');
DELETE cs FROM Lots.ContainerSerial cs JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId WHERE sp.SerialNumber LIKE N'TEST-RW-SN%';
DELETE FROM Lots.SerializedPart WHERE SerialNumber LIKE N'TEST-RW-SN%';
DELETE FROM Workorder.ConsumptionEvent WHERE SourceLotId IN (SELECT Id FROM @TdLot) OR ProducedLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @TdLot) OR ChildLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'TEST-RW-%';
DELETE FROM Lots.ContainerRework WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

EXEC test.EndTestFile;
GO
