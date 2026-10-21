-- =============================================
-- File:        0109_ControlledRun/140_deviation_signature.sql
-- Author:      Blue Ridge Automation
-- Description: Super-lot piece 3 -- the signature record and its seam
--              (Quality.ufn_SignatureAllowed, the append-only trigger,
--              SignatureMeaning_Get) and Quality.ControlledRunDeviation_Raise /
--              _ListByRun.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0109_ControlledRun/140_deviation_signature.sql';
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
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @n NVARCHAR(600);

-- An operator with NO network account: present at the terminal by PIN, cannot sign.
INSERT INTO Location.AppUser (AdAccount, DisplayName, Initials, Pin) VALUES (NULL, N'Test Operator CR', N'TCR', N'90917');
DECLARE @NoAd BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAtTerminalId, CrtActive)
VALUES (N'TEST-CR-A', @Item, 1, 1, 10, 10, @Line, @App, @Term, 0);
DECLARE @LotA BIGINT = SCOPE_IDENTITY();

DECLARE @o TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @s TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @j NVARCHAR(MAX) = (SELECT @LotA AS lotId FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRun_Open @Reason = N'deviation test', @MembersJson = @j, @AppUserId = @App;
DECLARE @Run BIGINT = (SELECT NewId FROM @o);
DECLARE @MemA BIGINT = (SELECT Id FROM Quality.ControlledRunMember WHERE LotId = @LotA AND EndedAt IS NULL);

-- ===== the seam =====
SET @n = (SELECT CAST(Quality.ufn_SignatureAllowed(@App, N'ControlledRunRelease') AS NVARCHAR(1)) + N'|'
               + CAST(Quality.ufn_SignatureAllowed(@App, N'DeviationApproval') AS NVARCHAR(1)) + N'|'
               + CAST(Quality.ufn_SignatureAllowed(@NoAd, N'DeviationApproval') AS NVARCHAR(1)) + N'|'
               + CAST(Quality.ufn_SignatureAllowed(@App, N'NoSuchMeaning') AS NVARCHAR(1)) + N'|'
               + CAST(Quality.ufn_SignatureAllowed(NULL, N'DeviationApproval') AS NVARCHAR(1)));
EXEC test.Assert_IsEqual @TestName = N'[Seam] AD-mapped user may sign both meanings; no AD account, unknown meaning, NULL user may not', @Expected = N'1|1|0|0|0', @Actual = @n;

DECLARE @SM TABLE (Id BIGINT, Code NVARCHAR(30), Name NVARCHAR(100), Statement NVARCHAR(500));
INSERT INTO @SM EXEC Quality.SignatureMeaning_Get @Code = N'DeviationApproval';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(LEFT(Statement, 24)) FROM @SM);
EXEC test.Assert_IsEqual @TestName = N'[Seam] SignatureMeaning_Get returns the statement shown to the signer', @Expected = N'1|I approve this deviation', @Actual = @n;
DELETE FROM @SM;
INSERT INTO @SM EXEC Quality.SignatureMeaning_Get @Code = N'Nope';
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) FROM @SM);
EXEC test.Assert_IsEqual @TestName = N'[Seam] unknown meaning = empty set', @Expected = N'0', @Actual = @n;

-- ===== refusals burn no number and write no signature =====
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'  ', @Justification = N'ok', @AppUserId = @App;
SET @n = (SELECT TOP 1 CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o WHERE NewId IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] blank description refused', @Expected = N'0|Describe what deviates.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'porosity', @Justification = NULL, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] blank justification refused', @Expected = N'0|Say why it does not affect part performance.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'porosity', @Justification = N'cosmetic', @AppUserId = @NoAd;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] a user with no network account cannot sign', @Expected = N'0|This user cannot sign a deviation.', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'porosity', @Justification = N'cosmetic', @AffectedQuantity = 0, @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + CASE WHEN Message LIKE N'Pieces affected must be greater than zero%' THEN N'qty' ELSE Message END FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] zero pieces affected refused', @Expected = N'0|qty', @Actual = @n;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = 999999999, @Description = N'porosity', @Justification = N'cosmetic', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] unknown super-lot refused', @Expected = N'0|Super-lot not found.', @Actual = @n;
SET @n = (SELECT CAST((SELECT LastValue FROM Lots.IdentifierSequence WHERE Code = N'ControlledRunDeviation') AS NVARCHAR(10)) + N'|'
               + CAST((SELECT COUNT(*) FROM Quality.Signature) AS NVARCHAR(5)) + N'|' + CAST((SELECT COUNT(*) FROM Quality.ControlledRunDeviation) AS NVARCHAR(5)));
EXEC test.Assert_IsEqual @TestName = N'[Deviation] five refusals: no number burned, no signature, no deviation', @Expected = N'0|0|0', @Actual = @n;

-- ===== a Use-As-Is member is blocked until the deviation exists =====
DELETE FROM @o;
SET @j = (SELECT * FROM (VALUES (@MemA, N'Accepted', 8), (@MemA, N'UseAsIs', 2)) v(memberId, dispositionCode, quantity) FOR JSON PATH);
INSERT INTO @o EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @j, @AppUserId = @App;
SET @n = (SELECT ISNULL(ReleaseBlockReason, N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] Use-As-Is with no deviation: blocked', @Expected = N'Use as is needs a deviation', @Actual = @n;

-- ===== the happy path =====
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'  Minor porosity outside the sealing land  ',
    @Justification = N'Outside the functional surface; leak test passed.', @DefectCodeId = @Def, @AffectedQuantity = 2,
    @ExternalReference = N' NCR-2291 ', @AppUserId = @App, @TerminalLocationId = @Term;
DECLARE @Dev BIGINT = (SELECT NewId FROM @o);
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] Status 1, message names the number', @Expected = N'1|Deviation DV000001 signed on super-lot CR000001.', @Actual = @n;
SET @n = (SELECT DeviationNumber + N'|' + ExternalReference + N'|' + Description + N'|' + CAST(AffectedQuantity AS NVARCHAR(5)) FROM Quality.ControlledRunDeviation WHERE Id = @Dev);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] DV000001, texts trimmed', @Expected = N'DV000001|NCR-2291|Minor porosity outside the sealing land|2', @Actual = @n;
SET @n = (SELECT sm.Code + N'|' + CAST(CASE WHEN s.Statement = sm.Statement THEN 1 ELSE 0 END AS NVARCHAR(1)) + N'|' + et.Code + N'|'
               + CAST(CASE WHEN s.EntityId = @Run AND s.AppUserId = @App AND s.TerminalLocationId = @Term THEN 1 ELSE 0 END AS NVARCHAR(1))
          FROM Quality.ControlledRunDeviation d
          JOIN Quality.Signature s ON s.Id = d.SignatureId
          JOIN Quality.SignatureMeaning sm ON sm.Id = s.SignatureMeaningId
          JOIN Audit.LogEntityType et ON et.Id = s.LogEntityTypeId
          WHERE d.Id = @Dev);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] its signature: meaning, the statement copied, what was signed, by whom, where', @Expected = N'DeviationApproval|1|ControlledRun|1', @Actual = @n;
SET @n = (SELECT TOP 1 LEFT(ol.Description, 8) FROM Audit.OperationLog ol JOIN Audit.LogEventType t ON t.Id = ol.LogEventTypeId
          WHERE t.Code = N'ControlledRunDeviationRaised' AND ol.EntityId = @Run);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] one ControlledRunDeviationRaised audit row, subject is the run number', @Expected = N'CR000001', @Actual = @n;
SET @n = (SELECT ISNULL(ReleaseBlockReason, N'ready') FROM Quality.ufn_ControlledRunMemberResults(@Run) WHERE MemberId = @MemA);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] with a signed deviation the Use-As-Is member is ready', @Expected = N'ready', @Actual = @n;

-- the stored statement survives a later rewording of the meaning
UPDATE Quality.SignatureMeaning SET Statement = N'REWORDED LATER' WHERE Code = N'DeviationApproval';
SET @n = (SELECT LEFT(s.Statement, 24) FROM Quality.ControlledRunDeviation d JOIN Quality.Signature s ON s.Id = d.SignatureId WHERE d.Id = @Dev);
EXEC test.Assert_IsEqual @TestName = N'[Signature] rewording the meaning later does not change what was signed', @Expected = N'I approve this deviation', @Actual = @n;
UPDATE Quality.SignatureMeaning
SET Statement = N'I approve this deviation: the condition described does not affect part performance and the affected material is accepted for use as is.'
WHERE Code = N'DeviationApproval';

DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'second', @Justification = N'also fine', @AppUserId = @App;
SET @n = (SELECT DeviationNumber FROM Quality.ControlledRunDeviation WHERE Id = (SELECT NewId FROM @o));
EXEC test.Assert_IsEqual @TestName = N'[Deviation] the next one is DV000002', @Expected = N'DV000002', @Actual = @n;

DECLARE @DL TABLE (Id BIGINT, DeviationNumber NVARCHAR(15), ExternalReference NVARCHAR(50), Description NVARCHAR(1000), Justification NVARCHAR(1000),
    DefectCode NVARCHAR(50), DefectDescription NVARCHAR(500), AffectedQuantity INT, SignedByInitials NVARCHAR(20), SignedByName NVARCHAR(200), RaisedAt DATETIME2(3));
INSERT INTO @DL EXEC Quality.ControlledRunDeviation_ListByRun @Id = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MIN(DeviationNumber) + N'|' + MAX(SignedByInitials) FROM @DL);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] ListByRun returns both, with who signed', @Expected = N'2|DV000001|SYS', @Actual = @n;

DECLARE @SL TABLE (SignatureId BIGINT, SignedAt DATETIME2(3), SignedByInitials NVARCHAR(20), SignedByName NVARCHAR(200), MeaningCode NVARCHAR(30),
    MeaningName NVARCHAR(100), Statement NVARCHAR(500), Summary NVARCHAR(300));
INSERT INTO @SL EXEC Quality.ControlledRun_ListSignatures @Id = @Run;
SET @n = (SELECT CAST(COUNT(*) AS NVARCHAR(5)) + N'|' + MAX(MeaningCode) + N'|' + MIN(LEFT(Summary, 18)) FROM @SL);
EXEC test.Assert_IsEqual @TestName = N'[Signature] ListSignatures: two deviation approvals with a summary line', @Expected = N'2|DeviationApproval|Deviation DV000001', @Actual = @n;

-- ===== signatures are append-only =====
DECLARE @Sig BIGINT = (SELECT SignatureId FROM Quality.ControlledRunDeviation WHERE Id = @Dev);
BEGIN TRY
    UPDATE Quality.Signature SET Statement = N'tampered' WHERE Id = @Sig;
    SET @n = N'updated';
END TRY
BEGIN CATCH
    SET @n = CASE WHEN ERROR_MESSAGE() LIKE N'%append-only%' THEN N'refused' ELSE ERROR_MESSAGE() END;
END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Signature] UPDATE is refused by the trigger', @Expected = N'refused', @Actual = @n;
BEGIN TRY
    DELETE FROM Quality.Signature WHERE Id = -1;        -- touches no row: nothing to protect, no error
    SET @n = N'no rows, no error';
END TRY
BEGIN CATCH SET @n = ERROR_MESSAGE(); END CATCH
EXEC test.Assert_IsEqual @TestName = N'[Signature] a statement that touches no row is not an error', @Expected = N'no rows, no error', @Actual = @n;
BEGIN TRY
    ALTER TABLE Quality.ControlledRunDeviation NOCHECK CONSTRAINT FK_ControlledRunDeviation_Signature;
    DELETE FROM Quality.Signature WHERE Id = @Sig;
    SET @n = N'deleted';
END TRY
BEGIN CATCH
    SET @n = CASE WHEN ERROR_MESSAGE() LIKE N'%append-only%' THEN N'refused' ELSE ERROR_MESSAGE() END;
END CATCH
ALTER TABLE Quality.ControlledRunDeviation WITH CHECK CHECK CONSTRAINT FK_ControlledRunDeviation_Signature;
EXEC test.Assert_IsEqual @TestName = N'[Signature] DELETE is refused by the trigger even with the FK out of the way', @Expected = N'refused', @Actual = @n;
SET @n = (SELECT LEFT(Statement, 24) FROM Quality.Signature WHERE Id = @Sig);
EXEC test.Assert_IsEqual @TestName = N'[Signature] the row is intact afterwards', @Expected = N'I approve this deviation', @Actual = @n;

-- ===== a closed super-lot takes no deviation =====
DELETE FROM @s;
INSERT INTO @s EXEC Quality.ControlledRun_Cancel @Id = @Run, @Remarks = N'test over', @AppUserId = @App;
DELETE FROM @o;
INSERT INTO @o EXEC Quality.ControlledRunDeviation_Raise @ControlledRunId = @Run, @Description = N'late', @Justification = N'late', @AppUserId = @App;
SET @n = (SELECT CAST(Status AS NVARCHAR(1)) + N'|' + Message FROM @o);
EXEC test.Assert_IsEqual @TestName = N'[Deviation] refused once the super-lot is not open', @Expected = N'0|Super-lot CR000001 is not open.', @Actual = @n;
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
