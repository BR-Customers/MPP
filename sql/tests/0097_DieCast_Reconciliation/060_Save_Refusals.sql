-- =============================================
-- File: 0097_DieCast_Reconciliation/060_Save_Refusals.sql
-- Everything the save refuses, and the words it refuses with (spec sec 5.2,
-- 7.4, sec 8). Every one of these is a clean Status = 0 row -- no exception,
-- no open transaction (the Msg 3915 rule).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/060_Save_Refusals.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700501', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700501', @ShiftKey = N'S4', @Pieces = 100, @Reading = 110, @AtUtc = '2020-01-07T13:00:00';
GO

CREATE TABLE #Res (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
GO

DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @S1 BIGINT = test.ufn_RC(N'S1');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Lot BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700501');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Other  BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'Other');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Code999 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
DECLARE @m NVARCHAR(500);

-- a stale stamp
DELETE FROM #Res;
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @LoadedStamp = N'0.0.0.0.0', @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a shift that changed since it was loaded', @HaystackStr = @m, @NeedleStr = N'changed since you opened it';

-- Other without a note
DELETE FROM #Res;
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Other,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] Other needs a note', @HaystackStr = @m, @NeedleStr = N'needs a note';

-- the die was never mounted on that press
DECLARE @OtherCell BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
                             INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
                             WHERE d.Code = N'DieCastMachine' AND l.Id <> @Cell ORDER BY l.Id);
IF @OtherCell IS NOT NULL
BEGIN
    DECLARE @StampOther NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @OtherCell, @Tool);
    DELETE FROM #Res;
    INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
        @ShiftId = @S4, @CellLocationId = @OtherCell, @ToolId = @Tool, @ReasonId = @Reason,
        @LoadedStamp = @StampOther, @AppUserId = @Usr;
    SET @m = (SELECT Message FROM #Res);
    EXEC test.Assert_Contains @TestName = N'[Refuse] the die was not mounted on that press', @HaystackStr = @m, @NeedleStr = N'was not mounted on';
END

-- production on record with no actual figure (the orphan check)
DELETE FROM #Res;
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = N'[]', @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a LOT on record with no actual figure', @HaystackStr = @m, @NeedleStr = N'no actual figure';
EXEC test.Assert_Contains @TestName = N'[Refuse] ...naming it', @HaystackStr = @m, @NeedleStr = N'99700501';

-- the totals do not add up
DELETE FROM #Res;
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":190}]';
SET @Actual = N'{"totalShots":111,"goodShots":100,"warmUpShots":10}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] total shots must equal good + warm-up', @HaystackStr = @m, @NeedleStr = N'has a typo';

-- the LOT list does not equal total good
DELETE FROM #Res;
SET @Actual = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":150}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] the LOT list must equal actual total good', @HaystackStr = @m, @NeedleStr = N'LOT list totals';

-- one LOT holding more than the shift made
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":200}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a LOT cannot hold more than the shift''s good shots', @HaystackStr = @m, @NeedleStr = N'More pieces than';

-- an LTT from another die
DELETE FROM #Res;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700502', @CavKey = N'CavA', @StatusCode = N'Good';
UPDATE Lots.Lot SET ToolId = NULL WHERE LotName = N'99700502';
SET @Lots = N'[{"ltt":"99700502","quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] an LTT that is not a LOT from this die', @HaystackStr = @m, @NeedleStr = N'Not a LOT from';

-- a malformed LTT
DELETE FROM #Res;
SET @Lots = N'[{"ltt":"12345","toolCavityId":' + CAST(test.ufn_RC(N'CavA') AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] not a valid LTT', @HaystackStr = @m, @NeedleStr = N'8 or 9 digits';

-- a lotId that does not exist at all.
-- This one is here because of HOW it used to fail, not just that it did. Every
-- other check in sec 7 was structurally blind to it: the tool check INNER JOINs
-- Lots.Lot, so the join dropped the row instead of naming it, and the LTT,
-- cavity and part checks are all gated on LotId IS NULL. Its quantity still
-- balanced the sec 9 arithmetic (100 + 100 = 100 good shots x 2 cavities), so
-- the save went ahead, and step (c)'s DieCastCredit_Write wrote no rows, left
-- @LotName NULL and hit Audit.OperationLog.Description NOT NULL -- inside the
-- transaction, so CATCH, so ROLLBACK, so Msg 3915 under the INSERT-EXEC below,
-- so NO result row at all. The INSERT-EXEC capture is therefore the assertion:
-- if the refusal is removed this test does not report a wrong message, it
-- ABORTS the batch. Same shape as the die-life case at the end of this file.
DELETE FROM #Res;
DECLARE @Ghost BIGINT = ISNULL((SELECT MAX(Id) FROM Lots.Lot), 0) + 1000000;
SET @Actual = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
SET @Lots = N'[{"lotId":' + CAST(@Lot   AS NVARCHAR(20)) + N',"quantity":100},'
          + N'{"lotId":' + CAST(@Ghost AS NVARCHAR(20)) + N',"quantity":100}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @GhostStatus NVARCHAR(50) = CAST((SELECT Status FROM #Res) AS NVARCHAR(50));
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_IsEqual @TestName = N'[Refuse] a lotId that no longer exists comes back as a clean status row, not Msg 3915',
    @Expected = N'0', @Actual = @GhostStatus;
EXEC test.Assert_Contains @TestName = N'[Refuse] ...in words a team lead can act on',
    @HaystackStr = @m, @NeedleStr = N'no longer exists';
EXEC test.Assert_Contains @TestName = N'[Refuse] ...telling them what to do about it',
    @HaystackStr = @m, @NeedleStr = N'Reload the shift';
DECLARE @GhostUnexpected NVARCHAR(50) = CASE WHEN @m LIKE N'Unexpected error%' THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Refuse] ...the CATCH never saw it', @Expected = N'no', @Actual = @GhostUnexpected;
-- and it refuses for the RIGHT reason: a real LOT from another die must still
-- get the tool message, which is why the new check sits before the tool check
-- rather than after it.
DECLARE @GhostStoleToolMsg NVARCHAR(50) = CASE WHEN @m LIKE N'%Not a LOT from%' THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Refuse] ...and did not borrow the wrong-die wording',
    @Expected = N'no', @Actual = @GhostStoleToolMsg;

-- a reject amount that does not divide across the cavities it covers
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":189}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":11}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a reject amount that will not divide across the cavities', @HaystackStr = @m, @NeedleStr = N'does not divide evenly';

-- warm-up is not a reject line
DELETE FROM #Res;
SET @Rej = N'[{"defectCodeId":' + CAST(@Code999 AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] warm-up belongs in warm-up shots', @HaystackStr = @m, @NeedleStr = N'entered as warm-up shots';

-- A reject line approved by a DEPRECATED user (proc 1.4). This check was here
-- from 1.0 but asked existence only, so a deprecated approver was accepted
-- here and refused by Workorder.DieCastShiftOutput_Record 3.2 -- one column,
-- Workorder.RejectEvent.ApprovedByUserId, two rules. The pair below is the
-- point: the SAME payload with an ACTIVE approver must get past this gate and
-- fail on something else, so the assertion is about being ACTIVE and not
-- merely about naming an approver at all. Quantity 11 against 2 cavities is
-- the next refusal along.
DELETE FROM #Res;
INSERT INTO Location.AppUser (DisplayName, Initials, Pin, CreatedAt, DeprecatedAt)
VALUES (N'0097/060 deprecated approver', N'ZRSD', N'93821', SYSUTCDATETIME(), SYSUTCDATETIME());
DECLARE @DepAppr BIGINT = SCOPE_IDENTITY();
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":189}]';
SET @Rej = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":11,"approvedByUserId":'
         + CAST(@DepAppr AS NVARCHAR(20)) + N'}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_IsEqual @TestName = N'[Refuse] a reject line approved by a deprecated user',
    @Expected = N'A scrap line''s approver is not an active user; pick the approver again.', @Actual = @m;

-- the same payload, an ACTIVE approver: past the gate, onto the next refusal
DELETE FROM #Res;
SET @Rej = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":11,"approvedByUserId":'
         + CAST(@Usr AS NVARCHAR(20)) + N'}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] ...but an ACTIVE approver on the same line is not refused for it',
    @HaystackStr = @m, @NeedleStr = N'does not divide evenly';

DELETE FROM Location.AppUser WHERE Id = @DepAppr;

-- a move to a shift more than two away
DELETE FROM #Res;
DECLARE @C BIGINT = (SELECT Id FROM Workorder.DieCastContribution WHERE LotId = @Lot AND PieceDelta = 100);
DECLARE @Moves NVARCHAR(MAX) = N'[{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20))
    + N',"toShiftId":' + CAST(@S1 AS NVARCHAR(20)) + N'}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @MovesJson = @Moves, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] a move further than two shifts away', @HaystackStr = @m, @NeedleStr = N'within two shifts';

-- A move the worker cannot land: the SAME contribution named twice with two
-- different targets. The worker deduplicates on (entity type, entity id), so it
-- can honour only one of them -- and a worker emits no result set, so before
-- Save 1.1 this reported SUCCESS on a decision it had half-applied.
--
-- Save 1.1 caught it INSIDE the transaction, which was the wrong place: that
-- path ended in the CATCH, and a ROLLBACK inside a proc invoked by INSERT-EXEC
-- raises Msg 3915, so a team lead got no message at all -- the capture below is
-- exactly what used to break. Save 1.6 refuses the payload BEFORE the
-- transaction, so this is now an ordinary clean Status = 0 row, asserted through
-- INSERT-EXEC like every other refusal in this file.
DECLARE @S3 BIGINT = test.ufn_RC(N'S3'), @S5 BIGINT = test.ufn_RC(N'S5');
DECLARE @DupMoves NVARCHAR(MAX) =
      N'[{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'},'
    + N'{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S5 AS NVARCHAR(20)) + N'}]';
DELETE FROM #Res;
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @MovesJson = @DupMoves, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @DupStatus NVARCHAR(50) = CAST((SELECT Status FROM #Res) AS NVARCHAR(50));
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_IsEqual @TestName = N'[Refuse] a move the worker could not land comes back as a clean status row, not Msg 3915',
    @Expected = N'0', @Actual = @DupStatus;
EXEC test.Assert_IsEqual @TestName = N'[Refuse] ...naming the contradiction in words a team lead can act on',
    @Expected = N'The same entry is listed twice, going to two different shifts. Pick one shift for it and try again.',
    @Actual = @m;
DECLARE @DupShift NVARCHAR(50) = CAST((SELECT ShiftId FROM Workorder.DieCastContribution WHERE Id = @C) AS NVARCHAR(50));
DECLARE @WantShift NVARCHAR(50) = CAST(@S4 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] ...and nothing moved',
    @Expected = @WantShift, @Actual = @DupShift;
DECLARE @DupMoveRows NVARCHAR(50) = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationMove m
    INNER JOIN Workorder.DieCastShiftReconciliation h ON h.Id = m.ReconciliationId
    WHERE h.ToolId = @Tool) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] ...leaving no move on record',
    @Expected = N'0', @Actual = @DupMoveRows;

-- The same row named twice with the SAME target is NOT the contradiction and
-- must still be accepted -- it is the idempotent skip the whole feature rests
-- on. S1 is further than two shifts away, so the DISTANCE guard is what refuses
-- it; getting THAT message is the proof it got past the duplicate gate.
DELETE FROM #Res;
DECLARE @SameMoves NVARCHAR(MAX) =
      N'[{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S1 AS NVARCHAR(20)) + N'},'
    + N'{"entityType":"Contribution","entityId":' + CAST(@C AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S1 AS NVARCHAR(20)) + N'}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @MovesJson = @SameMoves, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] ...but the same row twice with the SAME target is not a contradiction',
    @HaystackStr = @m, @NeedleStr = N'within two shifts';

-- ---- migration 0099: a row with NO shift at all ----
-- The save used to test `c.ShiftId = @ShiftId`, and @ShiftId is never NULL, so
-- an unattributed contribution was silently unmovable -- the exact gap the
-- feature exists to close. It is now "this shift OR no shift", with the press
-- and die scoping UNCHANGED. Both halves are pinned here, and neither writes
-- anything: each is refused by the NEXT gate along, and WHICH message comes back
-- is the whole assertion.
--
-- Neither insert disturbs @Stamp: Workorder.ufn_DieCastShiftStamp counts rows
-- WHERE c.ShiftId = @ShiftId, so a NULL-shift row is invisible to it.
DELETE FROM #Res;
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId)
VALUES (@Lot, NULL, 7, @Usr, '2020-01-07T13:05:00', @Cell);
DECLARE @NoShiftC BIGINT = SCOPE_IDENTITY();
DECLARE @NoShiftMoves NVARCHAR(MAX) = N'[{"entityType":"Contribution","entityId":' + CAST(@NoShiftC AS NVARCHAR(20))
    + N',"toShiftId":' + CAST(@S1 AS NVARCHAR(20)) + N'}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @MovesJson = @NoShiftMoves, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
-- S1 is further than two shifts from S4, so the DISTANCE guard is what refuses
-- it. Getting that message at all means the shiftless row got PAST the
-- recorded-against-this-shift gate, which before 0099 it could not.
EXEC test.Assert_Contains @TestName = N'[Refuse] a SHIFTLESS row on this press reaches the distance guard -- it is no longer rejected as unrecorded',
    @HaystackStr = @m, @NeedleStr = N'within two shifts';

-- ...and the other half: press and die scoping still refuses a shiftless row
-- that belongs to a different press. Same far target, so if scoping had been
-- lost with the shift test, this would come back with the distance message
-- instead.
IF @OtherCell IS NOT NULL
BEGIN
    DELETE FROM #Res;
    INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId)
    VALUES (@Lot, NULL, 8, @Usr, '2020-01-07T13:06:00', @OtherCell);
    DECLARE @ElsewhereC BIGINT = SCOPE_IDENTITY();
    DECLARE @ElsewhereMoves NVARCHAR(MAX) = N'[{"entityType":"Contribution","entityId":' + CAST(@ElsewhereC AS NVARCHAR(20))
        + N',"toShiftId":' + CAST(@S1 AS NVARCHAR(20)) + N'}]';
    INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
        @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
        @MovesJson = @ElsewhereMoves, @LoadedStamp = @Stamp, @AppUserId = @Usr;
    SET @m = (SELECT Message FROM #Res);
    EXEC test.Assert_Contains @TestName = N'[Refuse] a shiftless row on ANOTHER press is still not this reconciliation''s business',
        @HaystackStr = @m, @NeedleStr = N'not recorded against this shift, press and die';
    DELETE FROM Workorder.DieCastContribution WHERE Id = @ElsewhereC;
END
DELETE FROM Workorder.DieCastContribution WHERE Id = @NoShiftC;

-- nothing to do
DELETE FROM #Res;
SET @Lots = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"quantity":100}]';
SET @Actual = N'{"totalShots":110,"goodShots":100,"warmUpShots":5}';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_Contains @TestName = N'[Refuse] totals that still do not add up', @HaystackStr = @m, @NeedleStr = N'has a typo';

-- ---- die life may not go below zero (Save 1.6, sec 12) ----
-- A wrong actual total shots is a TEAM LEAD'S TYPO. Until 1.6 it was a
-- RAISERROR inside the transaction, after the die-life UPDATE, so it reached the
-- CATCH -- which logs a FailureLog defect, answers "Unexpected error" and
-- re-raises as critical. Captured through INSERT-EXEC, as the screen and every
-- other test here capture it, the CATCH's ROLLBACK raised Msg 3915 and the
-- status row never ran: the message reached nobody. The INSERT-EXEC below is the
-- whole point of this test.
--
-- The fixture die carries 10,000 lifetime shots. A shift whose record reads
-- 30,000 and whose declared actual is 200 asks for -29,800, which is more life
-- than the die has.
--
-- These seeds put NEW contributions on S4, which changes
-- Workorder.ufn_DieCastShiftStamp -- so @Stamp is recomputed, and this block
-- must stay LAST, after every test above that uses the old stamp.
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700601', @CavKey = N'CavA', @StatusCode = N'Open';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700602', @CavKey = N'CavB', @StatusCode = N'Open';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700601', @ShiftKey = N'S4', @Pieces = 100, @Reading = 30000, @AtUtc = '2020-01-07T13:10:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700602', @ShiftKey = N'S4', @Pieces = 200, @Reading = NULL,  @AtUtc = '2020-01-07T13:11:00';
SET @Stamp = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);

DECLARE @L601 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700601');
DECLARE @L602 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700602');
-- 200 shots, 200 good, 0 warm-up => total good 200 x 2 cavities = 400, and the
-- three LOTs on record for this shift hold exactly that, each at or under 200.
-- Every gap is zero, so nothing but the reading is in question.
DELETE FROM #Res;
SET @Actual = N'{"totalShots":200,"goodShots":200,"warmUpShots":0}';
SET @Lots = N'[{"lotId":' + CAST(@Lot  AS NVARCHAR(20)) + N',"quantity":100},'
          + N'{"lotId":' + CAST(@L601 AS NVARCHAR(20)) + N',"quantity":100},'
          + N'{"lotId":' + CAST(@L602 AS NVARCHAR(20)) + N',"quantity":200}]';
INSERT INTO #Res EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @LifeStatus NVARCHAR(50) = CAST((SELECT Status FROM #Res) AS NVARCHAR(50));
SET @m = (SELECT Message FROM #Res);
EXEC test.Assert_IsEqual @TestName = N'[Refuse] die life below zero comes back as a clean status row, not Msg 3915',
    @Expected = N'0', @Actual = @LifeStatus;
EXEC test.Assert_Contains @TestName = N'[Refuse] ...in words a team lead can act on',
    @HaystackStr = @m, @NeedleStr = N'lifetime shot count below zero';
EXEC test.Assert_Contains @TestName = N'[Refuse] ...naming the shots it has and the shots it was asked for',
    @HaystackStr = @m, @NeedleStr = N'10000 now, -29800 from this shift';
EXEC test.Assert_Contains @TestName = N'[Refuse] ...and NOT as an unexpected error',
    @HaystackStr = @m, @NeedleStr = N'Check the actual total shots';
DECLARE @LifeUnexpected NVARCHAR(50) = CASE WHEN @m LIKE N'Unexpected error%' THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Refuse] ...the CATCH never saw it', @Expected = N'no', @Actual = @LifeUnexpected;
DECLARE @LifeShots NVARCHAR(50) = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] ...and die life is untouched', @Expected = N'10000', @Actual = @LifeShots;

-- nothing was written by ANY of the refusals
DECLARE @v NVARCHAR(50) = CAST((SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] not one refusal wrote a header row', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @Lot) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Refuse] and no LOT count moved', @Expected = N'100', @Actual = @v;
GO

DROP TABLE #Res;
EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
