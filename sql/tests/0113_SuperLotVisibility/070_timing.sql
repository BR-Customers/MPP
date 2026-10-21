-- =============================================
-- File:        0113_SuperLotVisibility/070_timing.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 7 -- timing gaps closed under the lock.
--              ControlledRunResult_Record v1.5 re-checks the LOT status inside
--              its vendor-return UPDATE; ControlledRun_Release v1.2 re-reads each
--              member's ready state inside the transaction. The race cannot be
--              produced in one session, so these pin the ordinary paths.
--              LOTs named TEST-SLT-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0113_SuperLotVisibility/070_timing.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLT-%';
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
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @n NVARCHAR(600), @j NVARCHAR(MAX);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-SLT-V1', @Item, @OriginRcv, 1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-SLT-R1', @Item, 1,           1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-SLT-R2', @Item, 1,           1, 10, 10, @Line, @App, @Term, 0);
DECLARE @V1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLT-V1');
DECLARE @R1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLT-R1');
DECLARE @R2 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLT-R2');

SET @j = (SELECT * FROM (VALUES (@V1), (@R1), (@R2)) v(lotId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'slt timing', @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DELETE FROM @o;
DECLARE @MemV1 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @V1 AND EndedAt IS NULL);
DECLARE @MemR1 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @R1 AND EndedAt IS NULL);
DECLARE @MemR2 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @R2 AND EndedAt IS NULL);
SET @n = CASE WHEN @Run IS NOT NULL AND @MemV1 IS NOT NULL AND @MemR1 IS NOT NULL AND @MemR2 IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Timing] fixture: super-lot with three LOT members', @Expected = N'ok', @Actual = @n;

-- ---- Record return on a Good received LOT still succeeds (status re-check under the lock) ----
SET @j = (SELECT @MemV1 AS memberId, N'ReturnToSupplier' AS dispositionCode, 3 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Timing] Record return on a Good received LOT still succeeds', @Expected = N'1', @Actual = @n;
DELETE FROM @o;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(l.PieceCount))
          FROM Lots.VendorReturn vr JOIN Lots.Lot l ON l.Id = vr.LotId WHERE vr.LotId = @V1 AND vr.CancelledAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Timing] the return row exists and the LOT lost 3 pieces', @Expected = N'1|7', @Actual = @n;

-- ---- Release of ready members still succeeds ----
SET @j = (SELECT @MemR1 AS memberId, N'Accepted' AS dispositionCode, 10 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;

-- ---- Release with a not-ready member (R2 has no result) is still refused before the transaction ----
SET @j = N'[' + CAST(@MemR1 AS NVARCHAR(20)) + N',' + CAST(@MemR2 AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CONCAT(CAST(Status AS NVARCHAR(1)), N'|', CASE WHEN Message LIKE N'%Nothing was released.' THEN N'refused' ELSE Message END) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Timing] Release with a not-ready member is still refused before the transaction', @Expected = N'0|refused', @Actual = @n;
DELETE FROM @o;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND EndedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[Timing] the refused release ended no membership', @Expected = N'0', @Actual = @n;

SET @j = N'[' + CAST(@MemR1 AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Timing] Release of ready members still succeeds', @Expected = N'1', @Actual = @n;
DELETE FROM @o;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunMember WHERE Id = @MemR1 AND EndedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[Timing] the released member is ended', @Expected = N'1', @Actual = @n;

-- ---- structural: the status guard sits in the vendor-return block (not just the scrap block) ----
DECLARE @Def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'Quality.ControlledRunResult_Record'));
DECLARE @RetPos INT = CHARINDEX(N'DECLARE return_cur', @Def);
DECLARE @Tail NVARCHAR(MAX) = SUBSTRING(@Def, @RetPos, 4000);
DECLARE @UpdPos INT = CHARINDEX(N'WITH (UPDLOCK, HOLDLOCK)', @Tail);
SET @n = CASE WHEN @RetPos > 0 AND @UpdPos > 0
               AND CHARINDEX(N'LotStatusId NOT IN', SUBSTRING(@Tail, @UpdPos, 400)) > 0
               AND CHARINDEX(N'SUPERLOT_STATUS', SUBSTRING(@Tail, @UpdPos, 900)) > 0
              THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Timing] Record re-checks status under the lock in the vendor-return UPDATE', @Expected = N'ok', @Actual = @n;
GO

-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLT-%';
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
EXEC test.EndTestFile;
GO
