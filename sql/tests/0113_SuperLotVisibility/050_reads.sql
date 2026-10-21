-- =============================================
-- File:        0113_SuperLotVisibility/050_reads.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 6, Task 5 -- the reads behind LOT Detail,
--              genealogy markers, the super-lot page History tab, the dashboard
--              tile and the Close button:
--                Quality.ControlledRun_ListByLot
--                Quality.ControlledRun_ListMarkers
--                Quality.ControlledRun_ListHistory
--                Quality.ControlledRun_GetOpenSummary
--                Quality.ufn_ControlledRunCloseCheck (+ ControlledRun_Get.CanClose)
--              plus the two display gaps: ListMembers.WasCompleteAtJoin and
--              ListMemberResults.AppliedReturnQty.
--              LOTs named TEST-SLV-%.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0113_SuperLotVisibility/050_reads.sql';
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
DECLARE @n NVARCHAR(MAX), @exp NVARCHAR(MAX), @j NVARCHAR(MAX), @csv NVARCHAR(MAX), @csv2 NVARCHAR(MAX);
DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));

DECLARE @BL TABLE (Seq INT IDENTITY(1,1), ControlledRunId BIGINT, RunNumber NVARCHAR(15), Reason NVARCHAR(500), RunStatusCode NVARCHAR(20),
    MembershipState NVARCHAR(10), JoinMethodName NVARCHAR(100), JoinedAt DATETIME2(3), LeftAt DATETIME2(3), LeftReason NVARCHAR(700),
    ResultsText NVARCHAR(MAX), ReleasedByInitials NVARCHAR(20), ReleasedAt DATETIME2(3), DeviationNumbers NVARCHAR(MAX), ViaContainerName NVARCHAR(60),
    JoinedByInitials NVARCHAR(20), LeftByInitials NVARCHAR(20));
DECLARE @MK TABLE (NodeKind NVARCHAR(10), NodeId BIGINT, RunNumber NVARCHAR(15), ControlledRunId BIGINT, MembershipState NVARCHAR(10));
DECLARE @H TABLE (Seq INT IDENTITY(1,1), EventAt DATETIME2(3), Kind NVARCHAR(20), Detail NVARCHAR(1000), ByInitials NVARCHAR(20));
DECLARE @SM TABLE (OpenCount INT, OldestOpenedAt DATETIME2(3), OldestAgeDays INT, MembersStillTagged INT);
DECLARE @G TABLE (Id BIGINT, RunNumber NVARCHAR(15), StatusCode NVARCHAR(20), Reason NVARCHAR(500), AnchorLotId BIGINT, AnchorLotName NVARCHAR(50),
    SelectionItemId BIGINT, PartNumber NVARCHAR(100), SelectionLocationId BIGINT, LocationName NVARCHAR(200), SelectionFromAt DATETIME2(3),
    SelectionToAt DATETIME2(3), IncludeDescendants BIT, AutoJoinEnabled BIT, AutoJoinEndedAt DATETIME2(3), OpenedByInitials NVARCHAR(20),
    OpenedAt DATETIME2(3), ClosedByInitials NVARCHAR(20), ClosedAt DATETIME2(3), CloseRemarks NVARCHAR(500), MemberCount INT, ClearedCount INT,
    PieceCount INT, CriteriaText NVARCHAR(400), CanClose BIT, CloseBlockedReason NVARCHAR(200));
DECLARE @M TABLE (MemberId BIGINT, Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), PieceCount INT, CrtActive BIT, JoinMethodName NVARCHAR(100), AddedAt DATETIME2(3), EndedAt DATETIME2(3),
    EndReasonName NVARCHAR(100), WasCompleteAtJoin BIT);
DECLARE @MR TABLE (MemberId BIGINT, Kind NVARCHAR(10), LotId BIGINT, ContainerId BIGINT, DisplayName NVARCHAR(60), PartNumber NVARCHAR(100),
    CurrentLocationName NVARCHAR(200), PieceCount INT, CrtActive BIT, AcceptedQty INT, ScrapQty INT, ReworkQty INT, ReturnQty INT, UseAsIsQty INT,
    AppliedScrapQty INT, ResultQty INT, LeftOver INT, HasResult BIT, ReleaseBlockReason NVARCHAR(100), WasCompleteAtJoin BIT, RankLocationId BIGINT,
    AppliedReturnQty INT);

SET @n = CASE WHEN @App IS NOT NULL AND @Item IS NOT NULL AND @Line IS NOT NULL AND @Cfg IS NOT NULL AND @Def IS NOT NULL THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Reads] fixture: user, item, line, config, defect', @Expected = N'ok', @Actual = @n;

-- ===== Summary before anything is open =====
INSERT INTO @SM EXEC Quality.ControlledRun_GetOpenSummary;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MAX(OpenCount), N'|', ISNULL(CONVERT(NVARCHAR(30), MAX(OldestOpenedAt), 121), N'NULL'),
                        N'|', ISNULL(CAST(MAX(OldestAgeDays) AS NVARCHAR(10)), N'NULL'), N'|', MAX(MembersStillTagged)) FROM @SM);
EXEC test.Assert_IsEqual @TestName = N'[Summary] none open: 0, NULL, NULL, 0 (one row always)', @Expected = N'1|0|NULL|NULL|0', @Actual = @n;
DELETE FROM @SM;

-- ---- LOTs: N never in a super-lot; A direct member (removed, re-joined, released);
--      B in a second super-lot; T1 / T2 trays of completed container K ----
DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-SLV-RN',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-SLV-RA',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-SLV-RB',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),
       (N'TEST-SLV-RT1', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0),
       (N'TEST-SLV-RT2', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0);
DECLARE @N0 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-RN');
DECLARE @A  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-RA');
DECLARE @B  BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-RB');
DECLARE @T1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-RT1');
DECLARE @T2 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-SLV-RT2');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App);
DECLARE @K BIGINT = SCOPE_IDENTITY();
DECLARE @KName NVARCHAR(30) = N'Container ' + CAST(@K AS NVARCHAR(20));
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@K, 1, @T1), (@K, 2, @T2);

-- ---- R1: A and K selected ----
SET @j = (SELECT * FROM (VALUES (@A, CAST(NULL AS BIGINT)), (NULL, @K)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'reads one', @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @R1 BIGINT = (SELECT NewId FROM @o);
DECLARE @RN1 NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @R1);
DELETE FROM @o;
DECLARE @MemA1 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @A AND EndedAt IS NULL);
DECLARE @MemK  BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @K AND EndedAt IS NULL);

-- A removed, then re-joins the same super-lot (scanned in)
INSERT INTO @s EXEC Quality.ControlledRun_RemoveMember @MemberId = @MemA1, @Remarks = N'wrong part', @AppUserId = @App;
DELETE FROM @s;
-- push the first membership back in time so "newest first" is unambiguous
UPDATE Quality.ControlledRunMember
SET AddedAt = DATEADD(HOUR, -3, AddedAt), EndedAt = DATEADD(HOUR, -2, EndedAt)
WHERE Id = @MemA1;
SET @j = (SELECT @A AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @R1, @MembersJson = @j, @AppUserId = @App;
DELETE FROM @s;
DECLARE @MemA2 BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @A AND EndedAt IS NULL);
SET @n = CASE WHEN @R1 IS NOT NULL AND @MemA1 IS NOT NULL AND @MemK IS NOT NULL AND @MemA2 IS NOT NULL AND @MemA2 <> @MemA1 THEN N'ok' ELSE N'missing' END;
EXEC test.Assert_IsEqual @TestName = N'[Reads] fixture: R1 opened, A removed and re-joined', @Expected = N'ok', @Actual = @n;

-- ===== ListByLot: never in a super-lot =====
INSERT INTO @BL (ControlledRunId, RunNumber, Reason, RunStatusCode, MembershipState, JoinMethodName, JoinedAt, LeftAt, LeftReason,
                 ResultsText, ReleasedByInitials, ReleasedAt, DeviationNumbers, ViaContainerName,
                 JoinedByInitials, LeftByInitials)
EXEC Quality.ControlledRun_ListByLot @LotId = @N0;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @BL);
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] never in a super-lot: empty', @Expected = N'0', @Actual = @n;

-- ===== ListByLot: two memberships, newest first =====
DELETE FROM @BL;
INSERT INTO @BL (ControlledRunId, RunNumber, Reason, RunStatusCode, MembershipState, JoinMethodName, JoinedAt, LeftAt, LeftReason,
                 ResultsText, ReleasedByInitials, ReleasedAt, DeviationNumbers, ViaContainerName,
                 JoinedByInitials, LeftByInitials)
EXEC Quality.ControlledRun_ListByLot @LotId = @A;
SET @n = (SELECT STRING_AGG(CONCAT(RunNumber, N'|', Reason, N'|', RunStatusCode, N'|', MembershipState, N'|', JoinMethodName, N'|',
                                   ISNULL(LeftReason, N'-'), N'|', CASE WHEN LeftAt IS NULL THEN N'open' ELSE N'left' END, N'|',
                                   ISNULL(ViaContainerName, N'direct')), N' / ') WITHIN GROUP (ORDER BY Seq) FROM @BL);
SET @exp = @RN1 + N'|reads one|Open|Open|Scanned in|-|open|direct / ' + @RN1 + N'|reads one|Open|Removed|Selected|Removed: wrong part|left|direct';
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] two memberships newest first incl. re-join after removal', @Expected = @exp, @Actual = @n;
SET @n = (SELECT STRING_AGG(CONCAT(ISNULL(JoinedByInitials, N'NULL'), N'>', ISNULL(LeftByInitials, N'NULL')), N' / ') WITHIN GROUP (ORDER BY Seq) FROM @BL);
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] JoinedByInitials / LeftByInitials (open: no leaver; removed: both)', @Expected = N'SYS>NULL / SYS>SYS', @Actual = @n;
SET @exp = (SELECT CONVERT(NVARCHAR(30), CAST(AddedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121) + N'|'
                 + CONVERT(NVARCHAR(30), CAST(EndedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121)
            FROM Quality.ControlledRunMember WHERE Id = @MemA1);
SET @n = (SELECT CONVERT(NVARCHAR(30), JoinedAt, 121) + N'|' + CONVERT(NVARCHAR(30), LeftAt, 121) FROM @BL WHERE Seq = (SELECT MIN(Seq) + 1 FROM @BL));
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] JoinedAt / LeftAt are Eastern', @Expected = @exp, @Actual = @n;

-- ===== ListByLot: a tray LOT shows its container's membership =====
DELETE FROM @BL;
INSERT INTO @BL (ControlledRunId, RunNumber, Reason, RunStatusCode, MembershipState, JoinMethodName, JoinedAt, LeftAt, LeftReason,
                 ResultsText, ReleasedByInitials, ReleasedAt, DeviationNumbers, ViaContainerName,
                 JoinedByInitials, LeftByInitials)
EXEC Quality.ControlledRun_ListByLot @LotId = @T1;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(RunNumber), N'|', MIN(MembershipState), N'|', MIN(ViaContainerName)) FROM @BL);
SET @exp = N'1|' + @RN1 + N'|Open|' + @KName;
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] tray LOT shows container''s run with ViaContainerName', @Expected = @exp, @Actual = @n;

-- ===== Results on A's current membership: scrap 2, accepted 3 (voided), accepted 5 =====
SET @j = (SELECT * FROM (VALUES (@MemA2, N'Scrap', 2, @Def), (@MemA2, N'Accepted', 3, CAST(NULL AS BIGINT))) v(memberId, dispositionCode, quantity, defectCodeId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @R1, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;
DECLARE @ResAcc BIGINT = (SELECT r.Id FROM Quality.ControlledRunResult r JOIN Quality.DispositionCode dc ON dc.Id = r.DispositionCodeId
                          WHERE r.ControlledRunMemberId = @MemA2 AND dc.Code = N'Accepted');
INSERT INTO @s EXEC Quality.ControlledRunResult_Void @ResultId = @ResAcc, @Remarks = N'typo', @AppUserId = @App;
DELETE FROM @s;
SET @j = (SELECT @MemA2 AS memberId, N'Accepted' AS dispositionCode, 5 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @R1, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Quality.ControlledRunResult WHERE ControlledRunMemberId = @MemA2);
EXEC test.Assert_IsEqual @TestName = N'[Reads] fixture: three result entries on A', @Expected = N'3', @Actual = @n;

DELETE FROM @BL;
INSERT INTO @BL (ControlledRunId, RunNumber, Reason, RunStatusCode, MembershipState, JoinMethodName, JoinedAt, LeftAt, LeftReason,
                 ResultsText, ReleasedByInitials, ReleasedAt, DeviationNumbers, ViaContainerName,
                 JoinedByInitials, LeftByInitials)
EXEC Quality.ControlledRun_ListByLot @LotId = @A;
SET @n = (SELECT ISNULL(ResultsText, N'NULL') + N' / ' + ISNULL((SELECT ResultsText FROM @BL WHERE Seq = (SELECT MIN(Seq) + 1 FROM @BL)), N'NULL') FROM @BL WHERE Seq = (SELECT MIN(Seq) FROM @BL));
SET @exp = N'Scrap 2 (' + @DefName + N'), Accepted 5 / NULL';
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] ResultsText excludes voided', @Expected = @exp, @Actual = @n;

-- ===== Deviation while A (2nd membership) and K are in; then release A =====
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @R1, @Description = N'cosmetic only',
    @Justification = N'no effect on function', @AppUserId = @App;
DECLARE @DevId BIGINT = (SELECT NewId FROM @o);
DECLARE @DV NVARCHAR(15) = (SELECT DeviationNumber FROM Quality.ControlledRunDeviation WHERE Id = @DevId);
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA2 AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @R1, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Reads] fixture: A released', @Expected = N'1', @Actual = @n;
DELETE FROM @o;

DELETE FROM @BL;
INSERT INTO @BL (ControlledRunId, RunNumber, Reason, RunStatusCode, MembershipState, JoinMethodName, JoinedAt, LeftAt, LeftReason,
                 ResultsText, ReleasedByInitials, ReleasedAt, DeviationNumbers, ViaContainerName,
                 JoinedByInitials, LeftByInitials)
EXEC Quality.ControlledRun_ListByLot @LotId = @A;
SET @exp = (SELECT N'Released|Released|SYS|' + CONVERT(NVARCHAR(30), CAST(rl.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121)
                 + N'|' + @DV + N' / NULL'
            FROM Quality.ControlledRunMember m JOIN Quality.ControlledRunRelease rl ON rl.Id = m.ControlledRunReleaseId WHERE m.Id = @MemA2);
SET @n = (SELECT MembershipState + N'|' + ISNULL(LeftReason, N'-') + N'|' + ISNULL(ReleasedByInitials, N'-') + N'|'
               + ISNULL(CONVERT(NVARCHAR(30), ReleasedAt, 121), N'-') + N'|' + ISNULL(DeviationNumbers, N'NULL')
               + N' / ' + ISNULL((SELECT DeviationNumbers FROM @BL WHERE Seq = (SELECT MIN(Seq) + 1 FROM @BL)), N'NULL')
          FROM @BL WHERE Seq = (SELECT MIN(Seq) FROM @BL));
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] release + deviation (the removed membership is not covered)', @Expected = @exp, @Actual = @n;

DELETE FROM @BL;
INSERT INTO @BL (ControlledRunId, RunNumber, Reason, RunStatusCode, MembershipState, JoinMethodName, JoinedAt, LeftAt, LeftReason,
                 ResultsText, ReleasedByInitials, ReleasedAt, DeviationNumbers, ViaContainerName,
                 JoinedByInitials, LeftByInitials)
EXEC Quality.ControlledRun_ListByLot @LotId = @T2;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(DeviationNumbers), N'|', ISNULL(MIN(ReleasedByInitials), N'-')) FROM @BL);
SET @exp = N'1|' + @DV + N'|-';
EXEC test.Assert_IsEqual @TestName = N'[ListByLot] tray LOT: deviation covers its container, not released yet', @Expected = @exp, @Actual = @n;

-- ===== R2: B, hand-picked, opened three days ago =====
SET @j = (SELECT @B AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'reads two', @SelectionItemId = @Item, @MembersJson = @j, @AppUserId = @App;
DECLARE @R2 BIGINT = (SELECT NewId FROM @o);
DECLARE @RN2 NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @R2);
DELETE FROM @o;
UPDATE Quality.ControlledRun SET OpenedAt = DATEADD(HOUR, -73, SYSUTCDATETIME()) WHERE Id = @R2;

-- ===== Markers =====
SET @csv = N' ,' + CAST(@A AS NVARCHAR(20)) + N',abc,, ' + CAST(@N0 AS NVARCHAR(20)) + N' ,12x,' + CAST(@A AS NVARCHAR(20));
SET @csv2 = N'';
INSERT INTO @MK EXEC Quality.ControlledRun_ListMarkers @LotIdsCsv = @csv, @ContainerIdsCsv = @csv2;
SET @n = (SELECT STRING_AGG(CONCAT(NodeKind, N'|', NodeId - @A, N'|', RunNumber, N'|', ControlledRunId - @R1, N'|', MembershipState), N' / ') FROM @MK);
SET @exp = N'Lot|0|' + @RN1 + N'|0|Released';
EXEC test.Assert_IsEqual @TestName = N'[Markers] csv with blanks and junk (one marker per node and super-lot, the latest membership)', @Expected = @exp, @Actual = @n;
DELETE FROM @MK;
SET @csv = NULL;
INSERT INTO @MK EXEC Quality.ControlledRun_ListMarkers @LotIdsCsv = @csv, @ContainerIdsCsv = @csv;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @MK);
EXEC test.Assert_IsEqual @TestName = N'[Markers] NULL lists: empty', @Expected = N'0', @Actual = @n;
SET @csv = CAST(@T1 AS NVARCHAR(20)) + N',' + CAST(@N0 AS NVARCHAR(20));
SET @csv2 = CAST(@K AS NVARCHAR(20));
INSERT INTO @MK EXEC Quality.ControlledRun_ListMarkers @LotIdsCsv = @csv, @ContainerIdsCsv = @csv2;
SET @n = (SELECT STRING_AGG(CONCAT(NodeKind, N'|', RunNumber, N'|', MembershipState, N'|',
                                   CASE WHEN NodeId = @T1 AND NodeKind = N'Lot' THEN N'T1' WHEN NodeId = @K AND NodeKind = N'Container' THEN N'K' ELSE N'?' END), N' / ')
                    WITHIN GROUP (ORDER BY NodeKind, NodeId) FROM @MK);
SET @exp = N'Container|' + @RN1 + N'|Open|K / Lot|' + @RN1 + N'|Open|T1';
EXEC test.Assert_IsEqual @TestName = N'[Markers] tray LOT via container', @Expected = @exp, @Actual = @n;

-- ===== History =====
INSERT INTO @H (EventAt, Kind, Detail, ByInitials) EXEC Quality.ControlledRun_ListHistory @Id = @R1;
SET @n = (SELECT CONCAT(
            (SELECT COUNT(*) FROM @H a JOIN @H b ON b.Seq = a.Seq + 1 WHERE b.EventAt > a.EventAt), N'|',
            (SELECT STRING_AGG(Kind, N',') WITHIN GROUP (ORDER BY Kind) FROM (SELECT DISTINCT Kind FROM @H) k), N'|',
            (SELECT COUNT(*) FROM @H WHERE Kind = N'Signature')));
EXEC test.Assert_IsEqual @TestName = N'[History] newest first; kinds; two signatures (deviation + release)',
    @Expected = N'0|Deviation,Member,Opened,Released,Result,Signature|2', @Actual = @n;
SET @exp = (SELECT sm.Name + N' ' + @Dot + N' "' + sg.Statement + N'"'
            FROM Quality.ControlledRunRelease rl
            JOIN Quality.Signature sg ON sg.Id = rl.SignatureId
            JOIN Quality.SignatureMeaning sm ON sm.Id = sg.SignatureMeaningId
            WHERE rl.ControlledRunId = @R1);
SET @exp = @exp + N' ' + @Dot + N' ' + CAST((SELECT MemberCount FROM Quality.ControlledRunRelease WHERE ControlledRunId = @R1) AS NVARCHAR(10)) + N' members';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(ByInitials)) FROM @H WHERE Kind = N'Signature' AND Detail = @exp);
EXEC test.Assert_IsEqual @TestName = N'[History] release signature Detail: meaning, statement, member count', @Expected = N'1|SYS', @Actual = @n;
SET @exp = N'Deviation ' + @DV + N' ' + @Dot + N' cosmetic only';
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(ByInitials)) FROM @H WHERE Kind = N'Signature' AND Detail = @exp);
EXEC test.Assert_IsEqual @TestName = N'[History] deviation signature Detail: number and description', @Expected = N'1|SYS', @Actual = @n;
SET @exp = (SELECT CONVERT(NVARCHAR(30), CAST(ol.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121)
            FROM Audit.OperationLog ol
            JOIN Audit.LogEntityType et ON et.Id = ol.LogEntityTypeId AND et.Code = N'ControlledRun'
            JOIN Audit.LogEventType ev ON ev.Id = ol.LogEventTypeId AND ev.Code = N'ControlledRunOpened'
            WHERE ol.EntityId = @R1);
SET @n = (SELECT CONVERT(NVARCHAR(30), EventAt, 121) + N'|' + CASE WHEN Detail LIKE N'Opened: %' THEN N'ok' ELSE Detail END FROM @H WHERE Kind = N'Opened');
SET @exp = @exp + N'|ok';
EXEC test.Assert_IsEqual @TestName = N'[History] EventAt Eastern; Detail drops the run-number prefix', @Expected = @exp, @Actual = @n;
DELETE FROM @H;
INSERT INTO @H (EventAt, Kind, Detail, ByInitials) EXEC Quality.ControlledRun_ListHistory @Id = 999999999;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @H);
EXEC test.Assert_IsEqual @TestName = N'[History] unknown run: empty', @Expected = N'0', @Actual = @n;

-- ===== Summary: R1 (K still tagged) and R2 (B tagged) =====
INSERT INTO @SM EXEC Quality.ControlledRun_GetOpenSummary;
SET @exp = (SELECT N'2|' + CONVERT(NVARCHAR(30), CAST(OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)), 121) + N'|3|2'
            FROM Quality.ControlledRun WHERE Id = @R2);
SET @n = (SELECT CONCAT(OpenCount, N'|', CONVERT(NVARCHAR(30), OldestOpenedAt, 121), N'|', OldestAgeDays, N'|', MembersStillTagged) FROM @SM);
EXEC test.Assert_IsEqual @TestName = N'[Summary] two open', @Expected = @exp, @Actual = @n;

-- ===== ListMembers.WasCompleteAtJoin / ListMemberResults.AppliedReturnQty (last columns) =====
INSERT INTO @M EXEC Quality.ControlledRun_ListMembers @Id = @R1;
SET @exp = (SELECT CAST(WasCompleteAtJoin AS NVARCHAR(1)) FROM Quality.ControlledRunMember WHERE Id = @MemK);
SET @n = (SELECT CAST(WasCompleteAtJoin AS NVARCHAR(1)) FROM @M WHERE MemberId = @MemK);
EXEC test.Assert_IsEqual @TestName = N'[ListMembers] WasCompleteAtJoin is the last column', @Expected = @exp, @Actual = @n;
INSERT INTO @MR EXEC Quality.ControlledRun_ListMemberResults @Id = @R1;
SET @n = (SELECT CONCAT(COUNT(*), N'|', MIN(AppliedReturnQty)) FROM @MR WHERE MemberId = @MemK);
EXEC test.Assert_IsEqual @TestName = N'[ListMemberResults] AppliedReturnQty is the last column', @Expected = N'1|0', @Actual = @n;

-- ===== CloseCheck: each reason equals Close's message for the same state =====
DECLARE @Chk NVARCHAR(200), @Msg NVARCHAR(500), @Agree NVARCHAR(MAX) = N'';
-- (a) members still tagged (R1: K)
SET @Chk = (SELECT Reason FROM Quality.ufn_ControlledRunCloseCheck(@R1));
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @R1, @AppUserId = @App;
SET @Msg = (SELECT Message FROM @s); DELETE FROM @s;
SET @Agree = @Agree + CASE WHEN @Chk = @Msg AND @Chk = N'1 of 1 members are still CRT-tagged.' THEN N'tagged ok' ELSE N'tagged [' + ISNULL(@Chk, N'NULL') + N'] vs [' + ISNULL(@Msg, N'NULL') + N']' END;
-- (b) window open (R2, temporarily)
UPDATE Quality.ControlledRun SET AutoJoinEnabled = 1 WHERE Id = @R2;
SET @Chk = (SELECT Reason FROM Quality.ufn_ControlledRunCloseCheck(@R2));
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @R2, @AppUserId = @App;
SET @Msg = (SELECT Message FROM @s); DELETE FROM @s;
UPDATE Quality.ControlledRun SET AutoJoinEnabled = 0 WHERE Id = @R2;
SET @Agree = @Agree + N' / ' + CASE WHEN @Chk = @Msg AND @Chk = N'End the window before closing.' THEN N'window ok' ELSE N'window [' + ISNULL(@Chk, N'NULL') + N'] vs [' + ISNULL(@Msg, N'NULL') + N']' END;

-- [Get] CanClose across the states of R2: tagged -> cleared (closable) -> closed
DECLARE @GetVsClose NVARCHAR(MAX) = N'';
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @R2;
SET @GetVsClose = (SELECT CONCAT(CAST(CanClose AS NVARCHAR(1)), N':', ISNULL(CloseBlockedReason, N'NULL')) FROM @G);
DELETE FROM @G;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @R2, @AppUserId = @App;
SET @GetVsClose = @GetVsClose + N'=' + (SELECT CONCAT(CAST(Status AS NVARCHAR(1)), N':', Message) FROM @s);
DELETE FROM @s;
INSERT INTO @s EXEC Lots.Lot_ClearCrt @LotId = @B, @AppUserId = @App;
DELETE FROM @s;
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @R2;
SET @Chk = (SELECT ISNULL(Reason, N'NULL') FROM Quality.ufn_ControlledRunCloseCheck(@R2));
SET @GetVsClose = @GetVsClose + N' / ' + (SELECT CONCAT(CAST(CanClose AS NVARCHAR(1)), N':', ISNULL(CloseBlockedReason, N'NULL')) FROM @G);
DELETE FROM @G;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @R2, @AppUserId = @App;
SET @GetVsClose = @GetVsClose + N'=' + (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
DELETE FROM @s;
SET @Agree = @Agree + N' / ' + CASE WHEN @Chk = N'NULL' THEN N'closable ok' ELSE N'closable [' + @Chk + N']' END;
-- (c) not open (R2 now closed)
SET @Chk = (SELECT Reason FROM Quality.ufn_ControlledRunCloseCheck(@R2));
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @R2;
SET @GetVsClose = @GetVsClose + N' / ' + (SELECT CONCAT(CAST(CanClose AS NVARCHAR(1)), N':', ISNULL(CloseBlockedReason, N'NULL')) FROM @G);
DELETE FROM @G;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @R2, @AppUserId = @App;
SET @Msg = (SELECT Message FROM @s);
SET @GetVsClose = @GetVsClose + N'=' + (SELECT CONCAT(CAST(Status AS NVARCHAR(1)), N':', Message) FROM @s);
DELETE FROM @s;
SET @Agree = @Agree + N' / ' + CASE WHEN @Chk = @Msg AND @Chk = N'Super-lot ' + @RN2 + N' is not open.' THEN N'not open ok' ELSE N'not open [' + ISNULL(@Chk, N'NULL') + N'] vs [' + ISNULL(@Msg, N'NULL') + N']' END;

EXEC test.Assert_IsEqual @TestName = N'[CloseCheck] each reason equals Close''s message for the same state',
    @Expected = N'tagged ok / window ok / closable ok / not open ok', @Actual = @Agree;
SET @exp = N'0:1 of 1 members are still CRT-tagged.=0:1 of 1 members are still CRT-tagged. / 1:NULL=1 / 0:Super-lot ' + @RN2
         + N' is not open.=0:Super-lot ' + @RN2 + N' is not open.';
EXEC test.Assert_IsEqual @TestName = N'[Get] CanClose 1 exactly when Close succeeds', @Expected = @exp, @Actual = @GetVsClose;
SET @n = (SELECT CONCAT(COUNT(*), N'|', ISNULL(CAST(MIN(CAST(CanClose AS INT)) AS NVARCHAR(1)), N'-')) FROM Quality.ufn_ControlledRunCloseCheck(999999999));
EXEC test.Assert_IsEqual @TestName = N'[CloseCheck] unknown run: no row', @Expected = N'0|-', @Actual = @n;
GO
