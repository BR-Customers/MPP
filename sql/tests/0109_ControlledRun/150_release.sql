-- =============================================
-- File:        0109_ControlledRun/150_release.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 3 -- Quality.ControlledRun_Release (the signed bulk
--              release) and what it changes in piece 1: totals, close, cancel, sync.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/150_release.sql';
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
-- the refusals this file provokes are logged against the test operator
DELETE FROM Audit.FailureLog WHERE AppUserId IN (SELECT Id FROM Location.AppUser WHERE Initials = N'TCR');
DELETE FROM Location.AppUser WHERE Initials = N'TCR';
GO

DECLARE @App  BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'SYS');
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Term BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.Code = N'Terminal' AND l.DeprecatedAt IS NULL AND l.ParentLocationId IS NOT NULL ORDER BY l.Id);
DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Term);
DECLARE @Cfg BIGINT = ISNULL((SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item), (SELECT TOP 1 Id FROM Parts.ContainerConfig));
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @LabelType BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
DECLARE @n NVARCHAR(600);

INSERT INTO Location.AppUser (AdAccount, DisplayName, Initials, Pin) VALUES (NULL, N'Test Operator CR', N'TCR', N'90917');
DECLARE @NoAd BIGINT = SCOPE_IDENTITY();

DECLARE @Ids TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
OUTPUT inserted.LotName, inserted.Id INTO @Ids (Name, Id)
VALUES (N'TEST-CR-A',  @Item, 1, 1, 10, 10, @Line, @App, @Term, 0),   -- accepted
       (N'TEST-CR-B',  @Item, 1, 1,  5,  5, @Line, @App, @Term, 0),   -- scrapped to zero (closes, stays tagged)
       (N'TEST-CR-C',  @Item, 1, 1,  8,  8, @Line, @App, @Term, 0),   -- use-as-is (needs a deviation)
       (N'TEST-CR-D',  @Item, 1, 1,  4,  4, @Line, @App, @Term, 0),   -- cleared per unit before release
       (N'TEST-CR-E',  @Item, 1, 1,  3,  3, @Line, @App, @Term, 0),   -- never given a result
       (N'TEST-CR-F',  @Item, 1, 1,  2,  2, @Line, @App, @Term, 0),   -- accepted, left for the second release
       (N'TEST-CR-O',  @Item, 1, 1,  9,  9, @Line, @App, @Term, 0),   -- member of ANOTHER super-lot
       (N'TEST-CR-T1', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0),   -- trays of the completed container
       (N'TEST-CR-T2', @Item, 1, 4,  6,  0, @Line, @App, @Term, 0);
DECLARE @LotA BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-A');
DECLARE @LotB BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-B');
DECLARE @LotC BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-C');
DECLARE @LotD BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-D');
DECLARE @LotE BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-E');
DECLARE @LotF BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-F');
DECLARE @LotO BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-O');
DECLARE @T1 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T1');
DECLARE @T2 BIGINT = (SELECT Id FROM @Ids WHERE Name = N'TEST-CR-T2');
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId)
VALUES (@Item, @Cfg, @Line, 2 /*Complete*/, SYSUTCDATETIME(), @App);
DECLARE @Con BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, FinishedGoodLotId) VALUES (@Con, 1, @T1), (@Con, 2, @T2);
INSERT INTO Lots.AimShipperIdPool (AimShipperId, ConsumedAt, ConsumedByContainerId, ConsumedByUserId, Quantity, LotNumber, PostedAt)
VALUES (N'TEST-CR-SER1', SYSUTCDATETIME(), @Con, @App, 12, N'TEST-CR-T1', NULL);
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, IsVoid) VALUES (@Con, N'TEST-CR-SER1', @LabelType, 1, 0);
DECLARE @Slid BIGINT = SCOPE_IDENTITY();

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX) = (SELECT * FROM (VALUES (@LotA, CAST(NULL AS BIGINT)), (@LotB, NULL), (@LotC, NULL), (@LotD, NULL), (@LotE, NULL), (@LotF, NULL), (NULL, @Con)) v(lotId, containerId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'release test', @SelectionItemId = @Item, @SelectionLocationId = @Line, @MembersJson = @j, @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DELETE FROM @o;
SET @j = (SELECT @LotO AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'the other one', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run2 BIGINT = (SELECT NewId FROM @o);

DECLARE @MemA BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotA AND EndedAt IS NULL);
DECLARE @MemB BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotB AND EndedAt IS NULL);
DECLARE @MemC BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotC AND EndedAt IS NULL);
DECLARE @MemD BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotD AND EndedAt IS NULL);
DECLARE @MemE BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotE AND EndedAt IS NULL);
DECLARE @MemF BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotF AND EndedAt IS NULL);
DECLARE @MemO BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotO AND EndedAt IS NULL);
DECLARE @MemK BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE ContainerId = @Con AND EndedAt IS NULL);

-- results: everything except E
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@MemA, N'Accepted', 10, CAST(NULL AS BIGINT)),
                                (@MemB, N'Scrap',     5, @Def),
                                (@MemC, N'Accepted',  6, NULL),
                                (@MemC, N'UseAsIs',   2, NULL),
                                (@MemD, N'Accepted',  4, NULL),
                                (@MemF, N'Accepted',  2, NULL),
                                (@MemK, N'Accepted', 12, NULL)) v(memberId, dispositionCode, quantity, defectCodeId) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(o.Status AS NVARCHAR(1)) + N'|' + CAST(l.LotStatusId AS NVARCHAR(5)) + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) FROM @o o, Lots.Lot l WHERE l.Id = @LotB);
EXEC test.Assert_IsEqual @TestName = N'[Release] fixture: results in; LOT B scrapped to zero is Closed and still tagged', @Expected = N'1|4|1', @Actual = @n;

-- D is cleared one at a time on LOT Detail first (still allowed for a member, spec D5)
INSERT INTO @s EXEC Lots.Lot_ClearCrt @LotId = @LotD, @AppUserId = @App;
SET @n = (SELECT CAST(s.Status AS NVARCHAR(1)) + N'|' + CAST(l.CrtActive AS NVARCHAR(1)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE Id = @MemD AND EndedAt IS NULL) AS NVARCHAR(1))
          FROM @s s, Lots.Lot l WHERE l.Id = @LotD);
EXEC test.Assert_IsEqual @TestName = N'[Release] a member may still be cleared per unit; it stays a member', @Expected = N'1|0|1', @Actual = @n;

DECLARE @SigBefore INT = (SELECT COUNT(*) FROM Quality.Signature);

-- ===== refusals: nothing released =====
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 0, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'Confirm that the 200[%] inspection was completed%' THEN N'confirm' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] without the confirmation nothing is released', @Expected = N'0|confirm', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = NULL, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] a NULL confirmation is not a confirmation', @Expected = N'0', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @NoAd;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] a user with no network account cannot sign', @Expected = N'0|This user cannot sign a release.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = N'[]', @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] nothing ticked', @Expected = N'0|Tick at least one member to release.', @Actual = @n;
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N',' + CAST(@MemE AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] a member with no result blocks the whole release, by name', @Expected = N'0|TEST-CR-E: No results yet. Nothing was released.', @Actual = @n;
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N',' + CAST(@MemC AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] Use-As-Is without a deviation blocks the whole release', @Expected = N'0|TEST-CR-C: Use as is needs a deviation. Nothing was released.', @Actual = @n;
-- Review focus: a member id from ANOTHER super-lot in the ticked list
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N',' + CAST(@MemO AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'1 of the ticked members are no longer in super-lot CR000001%' THEN N'foreign' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] a member of another super-lot in the list refuses the whole release', @Expected = N'0|foreign', @Actual = @n;
SET @n = (SELECT CAST((SELECT COUNT(*) FROM Quality.Signature) - @SigBefore AS NVARCHAR(5)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.ControlledRunRelease) AS NVARCHAR(5)) + N'|'
               + CAST((SELECT CrtActive FROM Lots.Lot WHERE Id = @LotA) AS NVARCHAR(1)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND EndedAt IS NULL) AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Release] seven refusals: no signature, no release row, A still tagged, all 7 still members', @Expected = N'0|0|1|7', @Actual = @n;

-- ===== the deviation, then the release =====
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'minor porosity', @Justification = N'cosmetic', @AppUserId = @App;

DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N',' + CAST(@MemB AS NVARCHAR(20)) + N',' + CAST(@MemC AS NVARCHAR(20)) + N','
       + CAST(@MemD AS NVARCHAR(20)) + N',' + CAST(@MemK AS NVARCHAR(20)) + N',' + CAST(@MemA AS NVARCHAR(20)) + N']';     -- A twice: counted once
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @Remarks = N'  first batch  ',
    @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Rel BIGINT = (SELECT NewId FROM @o);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] Status 1; message says what is left', @Expected = N'1|5 members released from super-lot CR000001. 2 still in it.', @Actual = @n;
SET @n = (SELECT CAST(SUM(CAST(CrtActive AS INT)) AS NVARCHAR(5)) FROM Lots.Lot WHERE Id IN (@LotA, @LotB, @LotC, @LotD, @T1, @T2));
EXEC test.Assert_IsEqual @TestName = N'[Release] every LOT of the ticked members is cleared, the container''s Closed trays included', @Expected = N'0', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(COUNT(DISTINCT lel.LotId) AS NVARCHAR(5))
          FROM Lots.LotEventLog lel JOIN Audit.LogEventType t ON t.Id = lel.LogEventTypeId
          WHERE t.Code = N'CrtCleared' AND lel.LotId IN (@LotA, @LotB, @LotC, @T1, @T2) AND lel.Description LIKE N'%(super-lot CR000001 release)');
EXEC test.Assert_IsEqual @TestName = N'[Release] ONE CrtCleared row per LOT cleared (A, B, C and both trays), naming the release', @Expected = N'5|5', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Lots.LotEventLog lel JOIN Audit.LogEventType t ON t.Id = lel.LogEventTypeId
          WHERE t.Code = N'CrtCleared' AND lel.LotId = @LotD);
EXEC test.Assert_IsEqual @TestName = N'[Release] the member cleared per unit beforehand gets no second CrtCleared row', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + CAST(MIN(ControlledRunMemberEndReasonId) AS NVARCHAR(5)) + N'|'
               + CAST(MIN(CASE WHEN ControlledRunReleaseId = @Rel AND EndedByUserId = @App THEN 1 ELSE 0 END) AS NVARCHAR(1))
          FROM Quality.ControlledRunMember WHERE Id IN (@MemA, @MemB, @MemC, @MemD, @MemK) AND EndedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName = N'[Release] five memberships ended as Released (4), each pointing at the release', @Expected = N'5|4|1', @Actual = @n;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunMember WHERE Id IN (@MemE, @MemF) AND EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Release] unticked members are untouched', @Expected = N'2', @Actual = @n;
SET @n = (SELECT CAST(CrtActive AS NVARCHAR(1)) FROM Lots.Lot WHERE Id = @LotF);
EXEC test.Assert_IsEqual @TestName = N'[Release] an unticked member stays tagged', @Expected = N'1', @Actual = @n;
SET @n = (SELECT CAST(rl.InspectionConfirmed AS NVARCHAR(1)) + N'|' + CAST(rl.MemberCount AS NVARCHAR(5)) + N'|' + rl.Remarks + N'|' + sm.Code + N'|'
               + CAST(CASE WHEN s.Statement = sm.Statement AND s.AppUserId = @App AND s.EntityId = @Run THEN 1 ELSE 0 END AS NVARCHAR(1))
          FROM Quality.ControlledRunRelease rl
          JOIN Quality.Signature s ON s.Id = rl.SignatureId
          JOIN Quality.SignatureMeaning sm ON sm.Id = s.SignatureMeaningId
          WHERE rl.Id = @Rel);
EXEC test.Assert_IsEqual @TestName = N'[Release] one release row: confirmed, 5 members, remarks trimmed; one signature with the statement', @Expected = N'1|5|first batch|ControlledRunRelease|1', @Actual = @n;
SET @n = (SELECT CAST((SELECT COUNT(*) FROM Quality.Signature) - @SigBefore AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Release] exactly two signatures so far: the deviation and the release', @Expected = N'2', @Actual = @n;
SET @n = (SELECT TOP 1 CASE WHEN ol.Description LIKE N'CR000001%Released%4 LOTs, 1 containers; signed by SYS: first batch' THEN N'ok' ELSE ol.Description END
          FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunReleased' AND ol.EntityId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Release] one ControlledRunReleased audit row in the audit convention', @Expected = N'ok', @Actual = @n;

-- ===== released material is usable again =====
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Lots.ufn_CrtBlocksAdvance(@LotA) b CROSS APPLY (SELECT b.* FOR JSON PATH) x(j) WHERE x.j LIKE N'%true%');
EXEC test.Assert_IsEqual @TestName = N'[Release] a released LOT is no longer blocked from advancing', @Expected = N'0', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Lots.Container_Ship @ShippingLabelId = @Slid, @AppUserId = @App, @TerminalLocationId = @Term;
SET @n = (SELECT CASE WHEN Message LIKE N'%Controlled Run Tag%' THEN N'still blocked by CRT' ELSE N'not blocked by CRT' END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Release] a released container is no longer stopped at the dock by the tag', @Expected = N'not blocked by CRT', @Actual = @n;
DECLARE @U TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(100), Quantity INT,
                  LotNumber NVARCHAR(50), PostAttempts INT, LastPostError NVARCHAR(MAX), ConsumedAtEt DATETIME2(3),
                  LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 500;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @U WHERE AimShipperId = N'TEST-CR-SER1');
EXEC test.Assert_IsEqual @TestName = N'[Release] the container''s held, unposted serial is owed to AIM again (the sweep posts it)', @Expected = N'1', @Actual = @n;

-- ===== piece 1 reads with released members =====
DECLARE @G TABLE (Id BIGINT, RunNumber NVARCHAR(15), StatusCode NVARCHAR(20), Reason NVARCHAR(500), AnchorLotId BIGINT, AnchorLotName NVARCHAR(50),
    SelectionItemId BIGINT, PartNumber NVARCHAR(100), SelectionLocationId BIGINT, LocationName NVARCHAR(200), SelectionFromAt DATETIME2(3),
    SelectionToAt DATETIME2(3), IncludeDescendants BIT, AutoJoinEnabled BIT, AutoJoinEndedAt DATETIME2(3), OpenedByInitials NVARCHAR(20),
    OpenedAt DATETIME2(3), ClosedByInitials NVARCHAR(20), ClosedAt DATETIME2(3), CloseRemarks NVARCHAR(500), MemberCount INT, ClearedCount INT,
    PieceCount INT, CriteriaText NVARCHAR(400));
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @Run;
SET @n = (SELECT CAST(MemberCount AS NVARCHAR(5)) + N'|' + CAST(ClearedCount AS NVARCHAR(5)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] totals still count released members: 7 members, 5 cleared', @Expected = N'7|5', @Actual = @n;

-- Review focus: a released unit tagged again later (for another reason)
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @LotA;
DELETE FROM @G;
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @Run;
SET @n = (SELECT CAST(MemberCount AS NVARCHAR(5)) + N'|' + CAST(ClearedCount AS NVARCHAR(5)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] a released unit tagged again later does not lower the cleared count', @Expected = N'7|5', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 1, @AppUserId = @App;     -- window on: sync arm (a) now looks at this part and line
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM Quality.ControlledRunMember WHERE LotId = @LotA AND EndedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Sync] the sync never brings a RELEASED unit back, even re-tagged inside the window', @Expected = N'0', @Actual = @n;
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id = @LotA;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_SetAutoJoin @Id = @Run, @Enabled = 0, @AppUserId = @App;

DECLARE @SL TABLE (SignatureId BIGINT, SignedAt DATETIME2(3), SignedByInitials NVARCHAR(20), SignedByName NVARCHAR(200), MeaningCode NVARCHAR(30),
    MeaningName NVARCHAR(100), Statement NVARCHAR(500), Summary NVARCHAR(300));
INSERT INTO @SL EXEC Quality.ControlledRun_ListSignatures @Id = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(CASE WHEN MeaningCode = N'ControlledRunRelease' THEN Summary END) FROM @SL);
EXEC test.Assert_IsEqual @TestName = N'[Signature] ListSignatures shows the release with a summary', @Expected = N'2|Release of 5 members - first batch', @Actual = @n;

-- ===== cancel is refused once a release is signed; close is refused while F is tagged =====
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run, @Remarks = N'oops', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'%has a signed release and cannot be cancelled%' THEN N'signed' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Cancel] refused once a release has been signed', @Expected = N'0|signed', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'2 of 2 members are still CRT-tagged%' THEN N'2of2' ELSE Message END FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Close] still refused while unreleased members are tagged', @Expected = N'0|2of2', @Actual = @n;

-- a member already released cannot be released twice
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'1 of the ticked members are no longer in super-lot%' THEN N'gone' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] a member that was already released cannot be released again', @Expected = N'0|gone', @Actual = @n;

-- ===== the rest, then close =====
DELETE FROM @o;
SET @j = (SELECT @MemE AS memberId, N'Accepted' AS dispositionCode, 3 AS quantity FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
DELETE FROM @o;
SET @j = N'[' + CAST(@MemE AS NVARCHAR(20)) + N',' + CAST(@MemF AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] the last members: the message says it can be closed', @Expected = N'1|2 members released from super-lot CR000001. Nothing is left in it; it can be closed.', @Actual = @n;
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Close @Id = @Run, @Remarks = N'all released', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Close] after a full release the super-lot closes', @Expected = N'1', @Actual = @n;
DELETE FROM @G;
INSERT INTO @G EXEC Quality.ControlledRun_Get @Id = @Run;
SET @n = (SELECT StatusCode + N'|' + CAST(MemberCount AS NVARCHAR(5)) + N'|' + CAST(ClearedCount AS NVARCHAR(5)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[Get] the closed super-lot still reports what it held: 7 members, 7 cleared', @Expected = N'Closed|7|7', @Actual = @n;

-- a released unit is free to join another super-lot (D4)
DELETE FROM @s;
SET @j = (SELECT @LotA AS lotId FOR JSON PATH);
INSERT INTO @s EXEC Quality.ControlledRun_AddMembers @Id = @Run2, @MembersJson = @j, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) FROM @s);
EXEC test.Assert_IsEqual @TestName = N'[Release] a released unit can join a later super-lot', @Expected = N'1', @Actual = @n;

-- a closed super-lot releases nothing
DELETE FROM @o;
SET @j = N'[' + CAST(@MemA AS NVARCHAR(20)) + N']';
INSERT INTO @o EXEC Quality.ControlledRun_Release @Id = @Run, @MemberIdsJson = @j, @InspectionConfirmed = 1, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Release] refused once the super-lot is not open', @Expected = N'0|Super-lot CR000001 is not open.', @Actual = @n;
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
-- the refusals this file provokes are logged against the test operator
DELETE FROM Audit.FailureLog WHERE AppUserId IN (SELECT Id FROM Location.AppUser WHERE Initials = N'TCR');
DELETE FROM Location.AppUser WHERE Initials = N'TCR';
GO

EXEC test.EndTestFile;
GO
