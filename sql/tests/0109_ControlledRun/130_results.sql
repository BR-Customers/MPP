-- =============================================
-- File:        0109_ControlledRun/130_results.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 3 -- inspection results: Quality.ControlledRunResult_Record
--              (counts, real scrap on a LOT, recorded-only scrap on a container),
--              _Void, _ListByRun, ControlledRun_ListMemberResults and
--              ufn_ControlledRunMemberResults.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/130_results.sql';
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
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Def2 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL AND Id <> @Def ORDER BY Id);
DECLARE @n NVARCHAR(500);

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-CR-A',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-CR-B',  @Item, 1, 1,  5,  5, @Line, @App, @Term, 0),
       (N'TEST-CR-H',  @Item, 1, 2,  8,  8, @Line, @App, @Term, 0),   -- on a real hold
       (N'TEST-CR-N',  @Item, 1, 1,  4,  4, @Line, @App, @Term, 0),   -- member, never given a result
       (N'TEST-CR-X',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),   -- NOT a member
       (N'TEST-CR-T1', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0);   -- tray of the completed container
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-A');
DECLARE @LotB BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-B');
DECLARE @LotH BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-H');
DECLARE @LotN BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-N');
DECLARE @LotX BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-X');
DECLARE @LotT BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T1');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @LotT);

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA, CAST(NULL AS BIGINT)), (@LotB, NULL), (@LotH, NULL), (@LotN, NULL), (NULL, @Con)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'results test', @SelectionLocationId = @Line, @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @MemA BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotA AND EndedAt IS NULL);
DECLARE @MemB BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotB AND EndedAt IS NULL);
DECLARE @MemH BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotH AND EndedAt IS NULL);
DECLARE @MemN BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotN AND EndedAt IS NULL);
DECLARE @MemC BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @Con AND EndedAt IS NULL);
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Results] fixture: five members', @Expected = N'5', @Actual = @n;

DECLARE @MR TABLE (MemberId BIGINT, Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), PieceCount INT, CrtActive BIT, AcceptedQty INT, ScrapQty INT, ReworkQty INT, ReturnQty INT, UseAsIsQty INT,
    AppliedScrapQty INT, ResultQty INT, LeftOver INT, HasResult BIT, ReleaseBlockReason NVARCHAR(100), WasCompleteAtJoin BIT, RankLocationId BIGINT,
    AppliedReturnQty INT);
DECLARE @RL TABLE (ResultId BIGINT, MemberId BIGINT, DisplayName NVARCHAR(60), DispositionCode NVARCHAR(50), DispositionName NVARCHAR(100),
    Quantity INT, DefectCode NVARCHAR(50), DefectDescription NVARCHAR(500), Remarks NVARCHAR(500), RecordedByInitials NVARCHAR(20),
    RecordedAt DATETIME2(3), IsApplied BIT, IsVoided BIT, CanVoid BIT);

-- before any entry
INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(ReleaseBlockReason) + N'|' + CAST(SUM(LeftOver) AS NVARCHAR(10)) FROM @MR);
EXEC test.Assert_IsEqual @TestName = N'[Results] before any entry: every member "No results yet", left over = all pieces (10+5+8+4+6)', @Expected = N'5|No results yet|33', @Actual = @n;
SET @n = (SELECT CAST(CASE WHEN RankLocationId = @Line THEN 1 ELSE 0 END AS NVARCHAR(1)) FROM @MR WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Results] RankLocationId is the super-lot''s made-at location', @Expected = N'1', @Actual = @n;

-- ===== 1. one member, three outcomes, one submit =====
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@MemA, N'Accepted', 6, CAST(NULL AS BIGINT), CAST(NULL AS NVARCHAR(50))),
                                (@MemA, N'Scrap',    3, @Def, N'  at bore  '),
                                (@MemA, N'UseAsIs',  1, NULL, NULL)) v(memberId, dispositionCode, quantity, defectCodeId, remarks) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'3 results recorded on super-lot CR000001. 3 scrapped.' THEN N'msg' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] Status 1 and a plain message', @Expected = N'1|msg', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(Quantity) AS NVARCHAR(5)) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Record] three entries, 10 pieces', @Expected = N'3|10', @Actual = @n;
SET @n = (SELECT CAST(CASE WHEN (SELECT NewId FROM @o) = (SELECT MIN(Id) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemA) THEN 1 ELSE 0 END AS NVARCHAR(1)));
EXEC test.Assert_IsEqual @TestName = N'[Record] NewId is the first entry', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(PieceCount AS NVARCHAR(5)) + N'|' + CAST(InventoryAvailable AS NVARCHAR(5)) + N'|' + CAST(LotStatusId AS NVARCHAR(5)) + N'|' + CAST(CrtActive AS NVARCHAR(1)) FROM Lots.Lot WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[Record] scrap on a LOT is real: 10 -> 7 pieces, still Good, still tagged', @Expected = N'7|7|1|1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MAX(re.Quantity) AS NVARCHAR(5)) + N'|' + MAX(re.Remarks)
               + N'|' + CAST(MAX(CASE WHEN re.ItemId = @Item AND re.TerminalLocationId = @Term THEN 1 ELSE 0 END) AS NVARCHAR(1))
          FROM Workorder.RejectEvent re WHERE re.LotId = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[Record] one RejectEvent: qty, trimmed remarks, part and terminal stamped', @Expected = N'1|3|at bore|1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunResult rr JOIN Workorder.RejectEvent re ON re.Id = rr.RejectEventId
          WHERE rr.ControlledRunMemberId = @MemA AND re.LotId = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[Record] the Scrap entry points at its RejectEvent', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemA AND RejectEventId IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Record] count-only outcomes carry no RejectEvent', @Expected = N'2', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunResultRecorded' AND ol.EntityId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Record] one ControlledRunResultRecorded audit row for the call', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'RejectEventRecorded' AND ol.EntityId IN (SELECT Id FROM Workorder.RejectEvent WHERE LotId = @LotA));
EXEC test.Assert_IsEqual @TestName = N'[Record] the scrap writes the same RejectEventRecorded audit row the line does', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(AcceptedQty AS NVARCHAR(5)) + N'|' + CAST(ScrapQty AS NVARCHAR(5)) + N'|' + CAST(UseAsIsQty AS NVARCHAR(5)) + N'|'
               + CAST(AppliedScrapQty AS NVARCHAR(5)) + N'|' + CAST(ResultQty AS NVARCHAR(5)) + N'|' + CAST(LeftOver AS NVARCHAR(5)) + N'|' + CAST(HasResult AS NVARCHAR(1))
          FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Results] member sums; left over = 7 pieces + 3 applied - 10 accounted = 0', @Expected = N'6|3|1|3|10|0|1', @Actual = @n;
SET @n = (SELECT ReleaseBlockReason FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Results] Use-As-Is with no deviation blocks release, and says why', @Expected = N'Use as is needs a deviation', @Actual = @n;

-- ===== 2. scrap that takes a LOT to zero closes it; it stays tagged =====
DELETE FROM @o;
SET @j = (SELECT @MemB AS memberId, N'Scrap' AS dispositionCode, 5 AS quantity, @Def2 AS defectCodeId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST(l.PieceCount AS NVARCHAR(5)) + N'|' + CAST(l.LotStatusId AS NVARCHAR(5)) + N'|' + CAST(l.CrtActive AS NVARCHAR(1))
          FROM @o o, Lots.Lot l WHERE l.Id = @LotB);
EXEC test.Assert_IsEqual @TestName = N'[Record] scrapping every piece closes the LOT (4) and leaves it tagged', @Expected = N'1|0|4|1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Lots.LotStatusHistory WHERE LotId = @LotB AND NewStatusId = 4);
EXEC test.Assert_IsEqual @TestName = N'[Record] the close writes a LotStatusHistory row', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(LeftOver AS NVARCHAR(5)) + N'|' + ISNULL(ReleaseBlockReason, N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemB);
EXEC test.Assert_IsEqual @TestName = N'[Results] a fully scrapped member: nothing left over, ready to release', @Expected = N'0|ready', @Actual = @n;

-- ===== 3. a LOT on a real hold is scrapped in place and stays held =====
DELETE FROM @o;
SET @j = (SELECT @MemH AS memberId, N'Scrap' AS dispositionCode, 2 AS quantity, @Def AS defectCodeId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST(l.PieceCount AS NVARCHAR(5)) + N'|' + CAST(l.LotStatusId AS NVARCHAR(5)) FROM @o o, Lots.Lot l WHERE l.Id = @LotH);
EXEC test.Assert_IsEqual @TestName = N'[Record] a held LOT member is scrapped in place: 8 -> 6, still on Hold (2)', @Expected = N'1|6|2', @Actual = @n;

-- ===== 4. scrap on a container is recorded, not applied =====
DELETE FROM @o;
SET @j = (SELECT @MemC AS memberId, N'Scrap' AS dispositionCode, 2 AS quantity, @Def AS defectCodeId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST(l.PieceCount AS NVARCHAR(5)) + N'|'
               + CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @LotT) AS NVARCHAR(5)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemC AND RejectEventId IS NULL) AS NVARCHAR(5))
          FROM @o o, Lots.Lot l WHERE l.Id = @LotT);
EXEC test.Assert_IsEqual @TestName = N'[Record] container scrap: recorded, tray LOT untouched, no RejectEvent', @Expected = N'1|6|0|1', @Actual = @n;
SET @n = (SELECT CAST(ScrapQty AS NVARCHAR(5)) + N'|' + CAST(AppliedScrapQty AS NVARCHAR(5)) + N'|' + CAST(LeftOver AS NVARCHAR(5)) FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemC);
EXEC test.Assert_IsEqual @TestName = N'[Results] container: 2 scrap recorded, 0 applied, 4 of 6 left over', @Expected = N'2|0|4', @Actual = @n;

-- ===== 5. refusals: whole call refused, nothing written =====
DECLARE @RowsBefore INT = (SELECT COUNT(*) FROM Quality.ControlledRunResult);
DECLARE @RejBefore INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId IN (@LotA, @LotB, @LotH, @LotN, @LotT, @LotX));

DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@MemN, N'Accepted', 4), (CAST(999999999 AS BIGINT), N'Accepted', 1)) v(memberId, dispositionCode, quantity) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'Entry 2 is not a current member of super-lot CR000001.' THEN N'entry2' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] an entry for something that is not a member refuses the WHOLE call', @Expected = N'0|entry2', @Actual = @n;

DELETE FROM @o;
SET @j = (SELECT @MemN AS memberId, N'Maybe' AS dispositionCode, 1 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'TEST-CR-N: unknown outcome%' THEN N'unknown' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] unknown outcome refused', @Expected = N'0|unknown', @Actual = @n;

DELETE FROM @o;
SET @j = (SELECT @MemN AS memberId, N'Accepted' AS dispositionCode, 0 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%greater than zero%' THEN N'qty' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] zero quantity refused', @Expected = N'0|qty', @Actual = @n;

DELETE FROM @o;
SET @j = (SELECT @MemN AS memberId, N'Scrap' AS dispositionCode, 1 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%scrap needs a defect reason%' THEN N'defect' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] scrap without a defect reason refused', @Expected = N'0|defect', @Actual = @n;

DELETE FROM @o;
SET @j = (SELECT @MemB AS memberId, N'Scrap' AS dispositionCode, 1 AS quantity, @Def AS defectCodeId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'TEST-CR-B is Closed and cannot be scrapped.' THEN N'closed' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] scrap on a Closed LOT member refused', @Expected = N'0|closed', @Actual = @n;

-- Review focus: two scrap entries for ONE LOT that together exceed it (A holds 7).
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@MemA, N'Scrap', 4, @Def), (@MemA, N'Scrap', 4, @Def2)) v(memberId, dispositionCode, quantity, defectCodeId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'TEST-CR-A: scrap of 8 is more than the 7 pieces it holds.' THEN N'over' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] two scrap lines that TOGETHER exceed the LOT are refused as a whole', @Expected = N'0|over', @Actual = @n;

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = N'not json', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] junk JSON: nothing to record, never an error', @Expected = N'0|No results to record.', @Actual = @n;

SET @n = (SELECT CAST((SELECT COUNT(*) FROM Quality.ControlledRunResult) - @RowsBefore AS NVARCHAR(5)) + N'|'
               + CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId IN (@LotA, @LotB, @LotH, @LotN, @LotT, @LotX)) - @RejBefore AS NVARCHAR(5)) + N'|'
               + CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @LotA) AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Record] every refusal wrote nothing: no entries, no rejects, LOT A still 7', @Expected = N'0|0|7', @Actual = @n;

-- ===== 6. many members in one call ("mark the rest as all accepted") =====
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@MemN, N'Accepted', 4), (@MemH, N'Accepted', 6)) v(memberId, dispositionCode, quantity) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST((SELECT SUM(LeftOver) FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId IN (@MemN, @MemH)) AS NVARCHAR(5)) FROM @o o);
EXEC test.Assert_IsEqual @TestName = N'[Record] one call, two members: both fully accounted for', @Expected = N'1|0', @Actual = @n;

-- ===== 7. the entry log =====
INSERT INTO @RL EXEC Quality.ControlledRunResult_ListByRun @Id = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(CAST(IsApplied AS INT)) AS NVARCHAR(5)) + N'|' + CAST(SUM(CAST(CanVoid AS INT)) AS NVARCHAR(5)) FROM @RL);
EXEC test.Assert_IsEqual @TestName = N'[ListByRun] 8 live entries; 3 applied scrap; the other 5 can be voided', @Expected = N'8|3|5', @Actual = @n;
SET @n = (SELECT CAST(IsApplied AS NVARCHAR(1)) + N'|' + CAST(CanVoid AS NVARCHAR(1)) + N'|' + RecordedByInitials FROM @RL WHERE MemberId = @MemC);
EXEC test.Assert_IsEqual @TestName = N'[ListByRun] container scrap: not applied, can be voided', @Expected = N'0|1|SYS', @Actual = @n;

-- ===== 8. void =====
DECLARE @ResAcc BIGINT = (SELECT ResultId FROM @RL WHERE MemberId = @MemA AND DispositionCode = N'Accepted');
DECLARE @ResScr BIGINT = (SELECT ResultId FROM @RL WHERE MemberId = @MemA AND DispositionCode = N'Scrap');
DECLARE @ResUai BIGINT = (SELECT ResultId FROM @RL WHERE MemberId = @MemA AND DispositionCode = N'UseAsIs');

INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResAcc, @Remarks = N'   ', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] a reason is required', @Expected = N'0|A reason is required to void an entry.', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResScr, @Remarks = N'typo', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'These pieces were already taken off TEST-CR-A%' THEN N'applied' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] a scrap that took pieces off a LOT cannot be voided', @Expected = N'0|applied', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResUai, @Remarks = N'  was fine after all  ', @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + rr.VoidRemarks + N'|' + CAST(CASE WHEN rr.VoidedAt IS NOT NULL AND rr.VoidedByUserId = @App THEN 1 ELSE 0 END AS NVARCHAR(1))
               + N'|' + CAST(rr.Quantity AS NVARCHAR(5))
          FROM @s s, Quality.ControlledRunResult rr WHERE rr.Id = @ResUai);
EXEC test.Assert_IsEqual @TestName = N'[Void] the entry is stamped, never deleted or changed', @Expected = N'1|was fine after all|1|1', @Actual = @n;
SET @n = (SELECT CAST(UseAsIsQty AS NVARCHAR(5)) + N'|' + CAST(LeftOver AS NVARCHAR(5)) + N'|' + ISNULL(ReleaseBlockReason, N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Void] a voided entry stops counting: 1 left over again, the Use-As-Is block is gone', @Expected = N'0|1|ready', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunResultVoided' AND ol.EntityId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Void] one ControlledRunResultVoided audit row', @Expected = N'1', @Actual = @n;

DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResUai, @Remarks = N'again', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] a second void is refused', @Expected = N'0|This entry is already voided.', @Actual = @n;

DELETE FROM @RL;
INSERT INTO @RL EXEC Quality.ControlledRunResult_ListByRun @Id = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @RL);
DELETE FROM @RL;
INSERT INTO @RL EXEC Quality.ControlledRunResult_ListByRun @Id = @Run, @IncludeVoided = 1;
SET @n = @n + N'|' + (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(SUM(CAST(IsVoided AS INT)) AS NVARCHAR(5)) FROM @RL);
EXEC test.Assert_IsEqual @TestName = N'[ListByRun] voided entries are hidden by default and shown on request', @Expected = N'7|8|1', @Actual = @n;

-- a member that has left the super-lot: its entries are closed history
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemN, @Remarks = N'not part of this', @AppUserId = @App;
DECLARE @ResN BIGINT = (SELECT TOP 1 Id FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemN);
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResN, @Remarks = N'late', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] an entry of a member that left the super-lot cannot be voided', @Expected = N'0|TEST-CR-N is no longer in the super-lot.', @Actual = @n;
DELETE FROM @o;
SET @j = (SELECT @MemN AS memberId, N'Accepted' AS dispositionCode, 1 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'Entry 1 is not a current member%' THEN N'gone' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] no results against a member that has been removed', @Expected = N'0|gone', @Actual = @n;

-- ===== 9. a super-lot that is not open takes no results =====
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run, @Remarks = N'test over', @AppUserId = @App;
DELETE FROM @o;
SET @j = (SELECT @MemA AS memberId, N'Accepted' AS dispositionCode, 1 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Record] refused once the super-lot is not open', @Expected = N'0|Super-lot CR000001 is not open.', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResAcc, @Remarks = N'late', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Void] refused once the super-lot is not open', @Expected = N'0|Super-lot CR000001 is not open.', @Actual = @n;
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

EXEC test.EndTestFile;
GO
