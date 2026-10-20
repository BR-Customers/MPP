-- =============================================
-- File:        0112_ReworkReturn/080_member_origin.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 5, Task 10 -- Quality.ControlledRun_ListMemberOrigin,
--              the read that decides whether the Results tab shows "Return to vendor":
--                * a Received and a ReceivedOffsite LOT member: CanReturnToVendor 1;
--                * a Manufactured LOT member: 0, origin code still returned;
--                * a container member: LotOriginCode NULL, CanReturnToVendor 0;
--                * a member whose membership ended is not listed;
--                * an unknown run returns no rows.
--              LOTs named TEST-VR-O%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0112_ReworkReturn/080_member_origin.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-VR-O%';
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
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OriginOff BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'ReceivedOffsite');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @ItemId BIGINT, @Cell BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @Cell = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)
ORDER BY eil.LocationId;
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @ItemId), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @n NVARCHAR(600);
DECLARE @e NVARCHAR(600);
DECLARE @L BIGINT;
DECLARE @j NVARCHAR(MAX);
DECLARE @Lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @o  TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s  TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @MO TABLE (MemberId BIGINT, LotOriginCode NVARCHAR(50), CanReturnToVendor BIT);

SET @n = CASE WHEN @App IS NOT NULL AND @OriginRcv IS NOT NULL AND @OriginOff IS NOT NULL AND @OriginMfg IS NOT NULL
               AND @ItemId IS NOT NULL AND @Cell IS NOT NULL AND @Cfg IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] fixture: user, origins, item, location, container config', @Expected = N'ok', @Actual = @n;

-- ---- LOTs: Received, ReceivedOffsite, Manufactured, and one Received that will leave the run ----
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-VR-OR';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LR BIGINT = @L;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-VR-OO';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LO BIGINT = @L;
UPDATE Lots.Lot SET LotOriginTypeId = @OriginOff WHERE Id = @LO;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-VR-OM';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LM BIGINT = @L;
UPDATE Lots.Lot SET LotOriginTypeId = @OriginMfg WHERE Id = @LM;
INSERT INTO @Lc EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = @App, @LotName = N'TEST-VR-OX';
SELECT @L = NewId FROM @Lc; DELETE FROM @Lc;
DECLARE @LX BIGINT = @L;
-- a completed container holding one Manufactured tray LOT (as 070_superlot_return.sql)
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-VR-OT', @ItemId, @OriginMfg, 1, 6, 0, @Cell, @App, 0);
DECLARE @LT BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-VR-OT');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@ItemId, @Cfg, @Cell, 2 /*Complete*/, SYSUTCDATETIME(), @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LT);

SET @j = (SELECT * FROM (VALUES (@LR, CAST(NULL AS BIGINT)), (@LO, NULL), (@LM, NULL), (NULL, @Con), (@LX, NULL)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'origin test', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o); DELETE FROM @o;
DECLARE @MemR BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LR AND EndedAt IS NULL);
DECLARE @MemO BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LO AND EndedAt IS NULL);
DECLARE @MemM BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LM AND EndedAt IS NULL);
DECLARE @MemC BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @Con AND EndedAt IS NULL);
DECLARE @MemX BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LX AND EndedAt IS NULL);
SET @n = CASE WHEN @Run IS NOT NULL AND @MemR IS NOT NULL AND @MemO IS NOT NULL AND @MemM IS NOT NULL
               AND @MemC IS NOT NULL AND @MemX IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] fixture: super-lot opened with five members', @Expected = N'ok', @Actual = @n;

INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemX, @Remarks = N'origin test', @AppUserId = @App;
SELECT @n = CAST(Status AS NVARCHAR(1)) FROM @s; DELETE FROM @s;
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] fixture: one member removed', @Expected = N'1', @Actual = @n;

INSERT INTO @MO EXEC Quality.ControlledRun_ListMemberOrigin @ControlledRunId = @Run;

SET @n = CAST((SELECT COUNT(*) FROM @MO) AS NVARCHAR(5)) + N'|' + CAST((SELECT COUNT(*) FROM @MO WHERE MemberId = @MemX) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] four current members listed; the removed one is not', @Expected = N'4|0', @Actual = @n;
SET @n = (SELECT ISNULL(LotOriginCode, N'<NULL>') + N'|' + CAST(CanReturnToVendor AS NVARCHAR(1)) FROM @MO WHERE MemberId = @MemR);
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] Received LOT member: can return', @Expected = N'Received|1', @Actual = @n;
SET @n = (SELECT ISNULL(LotOriginCode, N'<NULL>') + N'|' + CAST(CanReturnToVendor AS NVARCHAR(1)) FROM @MO WHERE MemberId = @MemO);
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] ReceivedOffsite LOT member: can return', @Expected = N'ReceivedOffsite|1', @Actual = @n;
SET @n = (SELECT ISNULL(LotOriginCode, N'<NULL>') + N'|' + CAST(CanReturnToVendor AS NVARCHAR(1)) FROM @MO WHERE MemberId = @MemM);
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] Manufactured LOT member: cannot return', @Expected = N'Manufactured|0', @Actual = @n;
SET @n = (SELECT ISNULL(LotOriginCode, N'<NULL>') + N'|' + CAST(CanReturnToVendor AS NVARCHAR(1)) FROM @MO WHERE MemberId = @MemC);
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] container member: no origin, cannot return', @Expected = N'<NULL>|0', @Actual = @n;
DELETE FROM @MO;

DECLARE @Missing BIGINT = -1;
INSERT INTO @MO EXEC Quality.ControlledRun_ListMemberOrigin @ControlledRunId = @Missing;
SET @n = CAST((SELECT COUNT(*) FROM @MO) AS NVARCHAR(5));
EXEC test.Assert_IsEqual @TestName = N'[SlOrg] unknown run: no rows', @Expected = N'0', @Actual = @n;
DELETE FROM @MO;
GO

-- ---- teardown ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-VR-O%';
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
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @TdLot);
UPDATE Lots.IdentifierSequence SET LastValue = 0 WHERE Code IN (N'ControlledRun', N'ControlledRunDeviation');
GO

EXEC test.EndTestFile;
GO
