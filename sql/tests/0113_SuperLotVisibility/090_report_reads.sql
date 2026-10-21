-- =============================================
-- File:        0113_SuperLotVisibility/090_report_reads.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 9 -- the two report reads:
--              Quality.ControlledRun_ReportMembers (one row per member, ended
--              included, with join / leave text and the "other" notes) and
--              Quality.ControlledRun_ReportOutcomes (Outcome + Defect sections).
--              LOTs named TEST-SLR-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0113_SuperLotVisibility/090_report_reads.sql';
GO
-- ---- teardown (FK-safe) ----
DECLARE @TdLot TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @TdLot (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'TEST-SLR-%';
DECLARE @TdCon TABLE (Id BIGINT PRIMARY KEY);
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
DELETE FROM Lots.LotRework WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM @TdLot) OR ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.AimShipperIdPool WHERE AimShipperId LIKE N'TEST-SLR-%';
DELETE FROM Lots.ContainerRework WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @TdLot);
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.Container WHERE Id IN (SELECT Id FROM @TdCon);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @TdLot) OR DescendantLotId IN (SELECT Id FROM @TdLot);
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
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Def2 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL AND Id <> @Def ORDER BY Id);
DECLARE @n  NVARCHAR(600);
DECLARE @n2 NVARCHAR(600);

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-SLR-A',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-SLR-B',  @Item, 1, 1,  6,  6, @Line, @App, @Term, 0),
       (N'TEST-SLR-C',  @Item, 1, 1,  5,  5, @Line, @App, @Term, 0),
       (N'TEST-SLR-D',  @Item, 1, 1,  4,  4, @Line, @App, @Term, 0),
       (N'TEST-SLR-T1', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0);
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLR-A');
DECLARE @LotB BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLR-B');
DECLARE @LotC BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLR-C');
DECLARE @LotD BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLR-D');
DECLARE @LotT BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLR-T1');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2, SYSUTCDATETIME(), @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LotT);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA, CAST(NULL AS BIGINT)), (@LotB, NULL), (@LotC, NULL), (@LotD, NULL), (NULL, @Con)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'report test', @SelectionLocationId = @Line, @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @MemA BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotA AND EndedAt IS NULL);
DECLARE @MemB BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotB AND EndedAt IS NULL);
DECLARE @MemC BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotC AND EndedAt IS NULL);
DECLARE @MemD BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotD AND EndedAt IS NULL);
DECLARE @MemK BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @Con AND EndedAt IS NULL);
SET @n = CASE WHEN @App IS NOT NULL AND @Def2 IS NOT NULL AND @Run IS NOT NULL AND @MemA IS NOT NULL AND @MemB IS NOT NULL AND @MemC IS NOT NULL AND @MemD IS NOT NULL AND @MemK IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Report] fixture: five members', @Expected = N'ok', @Actual = @n;

-- Live: 22 accepted, 7 scrap (Def 4 / Def2 3), 1 use-as-is = 30. D's Use-As-Is 2 is voided below.
SET @j = (SELECT * FROM (VALUES (@MemA, N'Accepted', 6, CAST(NULL AS BIGINT)), (@MemA, N'Scrap', 3, @Def), (@MemA, N'UseAsIs', 1, NULL),
                                (@MemB, N'Accepted', 3, NULL), (@MemB, N'Scrap', 2, @Def2), (@MemB, N'Scrap', 1, @Def2),
                                (@MemC, N'Accepted', 3, NULL), (@MemC, N'Scrap', 1, @Def),
                                (@MemD, N'Accepted', 4, NULL), (@MemD, N'UseAsIs', 2, NULL),
                                (@MemK, N'Accepted', 6, NULL)) v(memberId, dispositionCode, quantity, defectCodeId) FOR JSON PATH);
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Report] fixture: results recorded', @Expected = N'1', @Actual = @n;
DECLARE @VoidResult BIGINT = (SELECT TOP 1 Id FROM Quality.ControlledRunResult
    WHERE ControlledRunMemberId = @MemD AND DispositionCodeId = (SELECT Id FROM Quality.DispositionCode WHERE Code = N'UseAsIs'));
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @VoidResult, @Remarks = N'miscounted', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Report] fixture: one result voided', @Expected = N'1', @Actual = @n;

INSERT INTO Lots.LotRework (LotId, ReEntrySequenceNumber, LotMovementId, MovedByUserId, ApprovedByUserId, TerminalLocationId)
VALUES (@LotD, 1, 0, @App, @App, @Term);
INSERT INTO Lots.VendorReturn (LotId, Quantity, PieceCountTaken, InventoryTaken, MarkedByUserId, TerminalLocationId)
VALUES (@LotC, 2, 2, 2, @App, @Term);
INSERT INTO Lots.ContainerRework (ContainerId, OpenedByUserId, OriginalAimShipperId, OriginalPieceCount)
VALUES (@Con, @App, N'TEST-SLR-OLD', 6);
INSERT INTO Lots.AimShipperIdPool (AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId)
VALUES (N'TEST-SLR-NEW', SYSUTCDATETIME(), @Con, @App);

DECLARE @MR TABLE (MemberId BIGINT, Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), PieceCount INT, CrtActive BIT, AcceptedQty INT, ScrapQty INT, ReworkQty INT, ReturnQty INT, UseAsIsQty INT,
    AppliedScrapQty INT, ResultQty INT, LeftOver INT, HasResult BIT, ReleaseBlockReason NVARCHAR(100), WasCompleteAtJoin BIT, RankLocationId BIGINT);
DECLARE @OC TABLE (Section NVARCHAR(20), Label NVARCHAR(200), Pieces INT);
DECLARE @RM TABLE (MemberName NVARCHAR(60), PartNumber NVARCHAR(100), PieceCount INT, JoinedText NVARCHAR(100), LeftText NVARCHAR(100),
    AcceptedQty INT, ScrapQty INT, OtherText NVARCHAR(500));
INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @Run;
INSERT INTO @OC EXEC Quality.ControlledRun_ReportOutcomes @Id = @Run;
INSERT INTO @RM EXEC Quality.ControlledRun_ReportMembers @Id = @Run;

SET @n = (SELECT CONCAT((SELECT SUM(Pieces) FROM @OC WHERE Section = N'Outcome'), N'|', (SELECT SUM(ResultQty) FROM @MR)));
EXEC test.Assert_IsEqual @TestName = N'[Report] outcome totals equal ControlledRun_ListMemberResults totals for the same run', @Expected = N'30|30', @Actual = @n;
SET @n = (SELECT CONCAT(SUM(AcceptedQty), N'|', SUM(ScrapQty), N'|', SUM(ReworkQty), N'|', SUM(UseAsIsQty), N'|', SUM(ReturnQty)) FROM @MR);
SET @n2 = (SELECT CONCAT(
    (SELECT ISNULL(SUM(Pieces), 0) FROM @OC WHERE Section = N'Outcome' AND Label = N'Accepted'), N'|',
    (SELECT ISNULL(SUM(Pieces), 0) FROM @OC WHERE Section = N'Outcome' AND Label = N'Scrap'), N'|',
    (SELECT ISNULL(SUM(Pieces), 0) FROM @OC WHERE Section = N'Outcome' AND Label = N'Rework'), N'|',
    (SELECT ISNULL(SUM(Pieces), 0) FROM @OC WHERE Section = N'Outcome' AND Label = N'Use As-Is'), N'|',
    (SELECT ISNULL(SUM(Pieces), 0) FROM @OC WHERE Section = N'Outcome' AND Label = N'Return to Supplier')));
EXEC test.Assert_IsEqual @TestName = N'[Report] each outcome line equals the screen per-outcome sum', @Expected = @n, @Actual = @n2;
EXEC test.Assert_IsEqual @TestName = N'[Report] outcome values: accepted 22, scrap 7, rework 0, use as is 1, return 0', @Expected = N'22|7|0|1|0', @Actual = @n2;

SET @n = (SELECT CAST(SUM(Pieces) AS NVARCHAR(5)) FROM @OC WHERE Section = N'Outcome' AND Label = N'Use As-Is');
EXEC test.Assert_IsEqual @TestName = N'[Report] voided results excluded (the voided Use-As-Is 2 is not counted)', @Expected = N'1', @Actual = @n;

SET @n = (SELECT CONCAT(COUNT(*), N'|', SUM(Pieces)) FROM @OC WHERE Section = N'Defect');
EXEC test.Assert_IsEqual @TestName = N'[Report] two defect lines totalling the scrap pieces', @Expected = N'2|7', @Actual = @n;
DECLARE @Def1Label NVARCHAR(600) = (SELECT CONCAT(Code, N' - ', Description) FROM Quality.DefectCode WHERE Id = @Def);
SET @n = (SELECT CONCAT(Pieces, N'|', CASE WHEN Label = @Def1Label THEN N'label' ELSE Label END) FROM @OC WHERE Section = N'Defect' AND Label = @Def1Label);
EXEC test.Assert_IsEqual @TestName = N'[Report] defect label is "<code> - <description>" with its pieces', @Expected = N'4|label', @Actual = @n;

SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @RM);
EXEC test.Assert_IsEqual @TestName = N'[Report] one row per member', @Expected = N'5', @Actual = @n;
DECLARE @e NVARCHAR(600);
DECLARE @Md NVARCHAR(10) = FORMAT(CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 'MM/dd');
SET @n = (SELECT CONCAT(JoinedText, N'|', ISNULL(LeftText, N'-'), N'|', AcceptedQty, N'|', ScrapQty) FROM @RM WHERE MemberName = N'TEST-SLR-A');
SET @e = CONCAT(N'Selected ', @Md, N'|-|6|3');
EXEC test.Assert_IsEqual @TestName = N'[Report] member row: joined text, still in, accepted and scrap', @Expected = @e, @Actual = @n;
SET @n = (SELECT ISNULL(OtherText, N'-') FROM @RM WHERE MemberName = N'TEST-SLR-A');
EXEC test.Assert_IsEqual @TestName = N'[Report] a member with nothing special has no other text', @Expected = N'-', @Actual = @n;
SET @n = (SELECT OtherText FROM @RM WHERE MemberName = N'TEST-SLR-D');
SET @e = CONCAT(N'trim rework ', @Md);
EXEC test.Assert_IsEqual @TestName = N'[Report] trim rework text', @Expected = @e, @Actual = @n;
SET @n = (SELECT OtherText FROM @RM WHERE MemberName = N'TEST-SLR-C');
EXEC test.Assert_IsEqual @TestName = N'[Report] returned text', @Expected = N'returned 2', @Actual = @n;
SET @n = (SELECT OtherText FROM @RM WHERE MemberName = CONCAT(N'Container ', @Con));
EXEC test.Assert_IsEqual @TestName = N'[Report] repacked container shows old -> new serial', @Expected = N'repack TEST-SLR-OLD -> TEST-SLR-NEW', @Actual = @n;

UPDATE Quality.ControlledRunMember SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @App, ControlledRunMemberEndReasonId = 1 WHERE Id = @MemB;
DELETE FROM @RM;
INSERT INTO @RM EXEC Quality.ControlledRun_ReportMembers @Id = @Run;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MAX(CASE WHEN MemberName = N'TEST-SLR-B' THEN LeftText END)) FROM @RM);
SET @e = CONCAT(N'5|Removed ', @Md);
EXEC test.Assert_IsEqual @TestName = N'[Report] an ended member is still listed, with how and when it left', @Expected = @e, @Actual = @n;

DELETE FROM @RM; DELETE FROM @OC;
INSERT INTO @RM EXEC Quality.ControlledRun_ReportMembers @Id = -1;
INSERT INTO @OC EXEC Quality.ControlledRun_ReportOutcomes @Id = -1;
SET @n = CONCAT((SELECT COUNT(*) FROM @RM), N'|', (SELECT COUNT(*) FROM @OC));
EXEC test.Assert_IsEqual @TestName = N'[Report] unknown run: both reads return an empty set', @Expected = N'0|0', @Actual = @n;
GO