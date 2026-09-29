-- =============================================
-- File: 0097_DieCast_Reconciliation/070_Save_Writes.sql
-- The three shapes the design was written against, on the fixture die:
--   A  an entry filed against the wrong shift, and the shift's own production
--      missing (Machine 11, 09-17);
--   B  a shift with NOTHING recorded, entered from its LTTs (Machine 202);
--   C  a reduction -- recorded is higher than actual;
--   D  a second pass over C's shift that exercises what C could not: the
--      DOWNWARD scrap direction (C's warm-up actual equalled its record, so
--      both scrap inserts emitted nothing), and an OPEN LOT the count lock has
--      locked because it was consumed into another -- the one place status and
--      lock disagree, where the count must stand and the production must not.
-- Shift end S4 = 15:00 ET = 20:00 UTC, so backfilled rows land at 19:59:59 (A1).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/070_Save_Writes.sql';
GO
EXEC test.DieCastRecon_Setup;
-- the two LOTs the misfiled entry credited (released, then counted at trim)
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700601', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700602', @CavKey = N'CavB', @StatusCode = N'Good';
-- the two LOTs this shift's production belongs in: one correctable, one locked
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700603', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700604', @CavKey = N'CavB', @StatusCode = N'Good';
GO
-- the misfiled entry: the NIGHT shift's numbers, filed under S4, entered 08:35 ET
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700601', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700602', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:01';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:02';
-- earlier production already in the two S4 LOTs, from S2
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700603', @ShiftKey = N'S2', @Pieces = 500, @Reading = 500, @AtUtc = '2020-01-06T22:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700604', @ShiftKey = N'S2', @Pieces = 500, @Reading = 500, @AtUtc = '2020-01-06T22:00:01';
GO
-- 99700604 has been counted at trim: its count stands (spec 3.3)
DECLARE @Tmpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
                        INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
                        WHERE oty.Code <> N'DieCast' ORDER BY ot.Id);
IF @Tmpl IS NOT NULL
    INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId)
    SELECT l.Id, @Tmpl, '2020-01-08T14:00:00', test.ufn_RC(N'Usr') FROM Lots.Lot l WHERE l.LotName = N'99700604';
GO

-- ============ A: move the misfiled entry, then backfill the shift ============
DECLARE @S3 BIGINT = test.ufn_RC(N'S3'), @S4 BIGINT = test.ufn_RC(N'S4');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @L3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700603');
DECLARE @L4 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700604');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

DECLARE @Moves NVARCHAR(MAX) = (
    SELECT STRING_AGG(x.j, N',') FROM (
        SELECT N'{"entityType":"Contribution","entityId":' + CAST(c.Id AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'}' AS j
        FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
        WHERE c.ShiftId = @S4 AND l.LotName IN (N'99700601', N'99700602')
        UNION ALL
        SELECT N'{"entityType":"Reject","entityId":' + CAST(r.Id AS NVARCHAR(20)) + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'}'
        FROM Workorder.RejectEvent r WHERE r.ShiftId = @S4 AND r.ToolId = @Tool) x);
SET @Moves = N'[' + @Moves + N']';

-- actual: 1121 shots, 1083 good, 38 warm-up; 6 test parts across 2 cavities;
-- total good = 1083 x 2 - 6 = 2160, so 1080 in each of the two LOTs.
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":1121,"goodShots":1083,"warmUpShots":38}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@L3 AS NVARCHAR(20)) + N',"quantity":1080},'
                            + N'{"lotId":' + CAST(@L4 AS NVARCHAR(20)) + N',"quantity":1080}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":6,"approvedByUserId":' + CAST(@Usr AS NVARCHAR(20)) + N'}]';

CREATE TABLE #A (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #A EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @MovesJson = @Moves, @LotsJson = @Lots, @RejectsJson = @Rej,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecId BIGINT = (SELECT NewId FROM #A);
SET @v = CAST((SELECT Status FROM #A) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the save succeeds', @Expected = N'1', @Actual = @v;
DROP TABLE #A;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
               WHERE c.ShiftId = @S3 AND l.LotName IN (N'99700601', N'99700602')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the misfiled credits now belong to the night shift', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ShiftId = @S3 AND ToolId = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] so did its warm-up rows', @Expected = N'2', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastReconciliationMove WHERE ReconciliationId = @RecId) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] every moved row is recorded', @Expected = N'4', @Actual = @v;

SET @v = (SELECT CONCAT(SUM(PieceDelta), N'|', COUNT(*)) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] the shift''s own 2,160 pieces are credited, one row per LOT', @Expected = N'2160|2', @Actual = @v;
SET @v = (SELECT CONVERT(NVARCHAR(19), MIN(EventAt), 126) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] backfilled one second inside the shift (A1)', @Expected = N'2020-01-07T19:59:59', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId AND ShotCounterReading IS NOT NULL) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] a reconciliation credit carries no reading -- the anchor does (A3)', @Expected = N'0', @Actual = @v;

-- 0099, end to end and through the real Save: BOTH kinds of row this
-- reconciliation touched carry the Reconciled stamp -- the ones it WROTE (via
-- DieCastCredit_Write) and the ones it MOVED (via DieCastEntry_Restamp). That
-- one column is the whole of Oee.ShiftOverride_Restamp's exclusion now, so a
-- writer that misses it hands the team lead's decision back to the resolver.
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution dc
               INNER JOIN Oee.ShiftAttributionSource sas ON sas.Id = dc.ShiftAttributionSourceId
               WHERE dc.ReconciliationId = @RecId AND sas.Code <> N'Reconciled') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] every credit the save WROTE is stamped Reconciled', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution dc
               INNER JOIN Lots.Lot l ON l.Id = dc.LotId
               INNER JOIN Oee.ShiftAttributionSource sas ON sas.Id = dc.ShiftAttributionSourceId
               WHERE dc.ShiftId = @S3 AND l.LotName IN (N'99700601', N'99700602')
                 AND sas.Code = N'Reconciled') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] every credit the save MOVED is stamped Reconciled too', @Expected = N'2', @Actual = @v;

SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L3) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the released, unlocked LOT is corrected 500 -> 1,580', @Expected = N'1580', @Actual = @v;
SET @v = (SELECT TOP 1 Reason FROM Lots.LotAttributeChange WHERE LotId = @L3 ORDER BY Id DESC);
EXEC test.Assert_Contains @TestName = N'[A] ...with the reconciliation named in the reason', @HaystackStr = @v, @NeedleStr = N'Shift reconciliation #';
SET @v = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @L4) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the LOT counted at trim keeps its count', @Expected = N'500', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecId AND LotId = @L4) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] ...but its production is still recorded in full', @Expected = N'1', @Actual = @v;

SET @v = CAST((SELECT SUM(Quantity) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND DefectCodeId = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] warm-up: 38 shots on each of two cavities', @Expected = N'76', @Actual = @v;
SET @v = CAST((SELECT SUM(Quantity) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND DefectCodeId = @Code008) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the 6 test parts, spread across the cavities', @Expected = N'6', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecId AND ApprovedByUserId = @Usr) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] Approved by is stamped on the reject rows', @Expected = N'2', @Actual = @v;

SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S4, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] the shift''s reading is now the actual total', @Expected = N'1121', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[A] die life advanced by the shift''s shots', @Expected = N'11121', @Actual = @v;
SET @v = (SELECT CONCAT(DieShotCountBefore, N'|', DieShotCountAfter) FROM Workorder.DieCastShiftReconciliation WHERE Id = @RecId);
EXEC test.Assert_IsEqual @TestName = N'[A] the header records die life either side', @Expected = N'10000|11121', @Actual = @v;

-- re-running the same reconciliation writes nothing
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
CREATE TABLE #A2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #A2 EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @v = (SELECT Message FROM #A2);
EXEC test.Assert_Contains @TestName = N'[A] running it again finds nothing to do', @HaystackStr = @v, @NeedleStr = N'already matches actual';
DROP TABLE #A2;
GO

-- ============ B: a shift with nothing recorded, entered from its LTTs ============
DECLARE @S5 BIGINT = test.ufn_RC(N'S5'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr'), @CavA BIGINT = test.ufn_RC(N'CavA'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S5, @Cell, @Tool);
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- actual 110 shots, 100 good, 10 warm-up, 2 test parts => total good 198
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
DECLARE @Lots NVARCHAR(MAX) =
      N'[{"ltt":"99700611","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":66},'
    + N'{"ltt":"99700612","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":33},'
    + N'{"ltt":"99700613","toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"quantity":99}]';
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":2}]';

CREATE TABLE #B (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #B EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecB BIGINT = (SELECT NewId FROM #B);
SET @v = CAST((SELECT Status FROM #B) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] a shift with nothing on record saves', @Expected = N'1', @Actual = @v;
DROP TABLE #B;

SET @v = (SELECT CONCAT(COUNT(*), N'|', SUM(l.PieceCount)) FROM Lots.Lot l WHERE l.LotName IN (N'99700611', N'99700612', N'99700613'));
EXEC test.Assert_IsEqual @TestName = N'[B] three LOTs created, holding what the sheet says', @Expected = N'3|198', @Actual = @v;
SET @v = (SELECT CONCAT(sc.Code, N'|', loc.Code, N'|', CONVERT(NVARCHAR(10), l.CastDate, 23), N'|', l.ProducedAtLocationId)
          FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
          JOIN Location.Location loc ON loc.Id = l.CurrentLocationId WHERE l.LotName = N'99700611');
SET @Want = CONCAT(N'Good|WHSE|2020-01-07|', @Cell);
EXEC test.Assert_IsEqual @TestName = N'[B] released to Warehouse, cast-dated, produced at the press', @Expected = @Want, @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S5, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] the shift now has its reading', @Expected = N'110', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[B] die life advanced again', @Expected = N'11231', @Actual = @v;
-- approvedByUserId is OPTIONAL (proc 1.4): B's reject line carries none, so its
-- two rows record with ApprovedByUserId NULL. [A] above is the other half --
-- an ACTIVE approver is stamped. Between them: supplied and checked, omitted
-- and untouched.
SET @v = (SELECT CONCAT(COUNT(*), N'|', COUNT(ApprovedByUserId)) FROM Workorder.RejectEvent
          WHERE ReconciliationId = @RecB AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[B] a reject line with no approver records, ApprovedByUserId left NULL',
    @Expected = N'2|0', @Actual = @v;
GO

-- ============ C: a reduction ============
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @v NVARCHAR(400);

EXEC test.DieCastRecon_SeedLot @Ltt = N'99700621', @CavKey = N'CavA';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700622', @CavKey = N'CavB';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700621', @ShiftKey = N'S1', @Pieces = 590, @Reading = 600, @AtUtc = '2020-01-06T16:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700622', @ShiftKey = N'S1', @Pieces = 590, @Reading = 600, @AtUtc = '2020-01-06T16:00:01';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S1', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 10, @AtUtc = '2020-01-06T16:00:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S1', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 10, @AtUtc = '2020-01-06T16:00:02';

DECLARE @L1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700621');
DECLARE @L2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700622');
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
-- actual is LOWER: 580 shots, 570 good, 10 warm-up => 1,140 total good, 570 each
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":580,"goodShots":570,"warmUpShots":10}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@L1 AS NVARCHAR(20)) + N',"quantity":570},'
                            + N'{"lotId":' + CAST(@L2 AS NVARCHAR(20)) + N',"quantity":570}]';

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #C EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S1, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecC BIGINT = (SELECT NewId FROM #C);
SET @v = CAST((SELECT Status FROM #C) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] a reduction saves', @Expected = N'1', @Actual = @v;
DROP TABLE #C;

SET @v = (SELECT CONCAT(SUM(PieceDelta), N'|', COUNT(*)) FROM Workorder.DieCastContribution WHERE ReconciliationId = @RecC);
EXEC test.Assert_IsEqual @TestName = N'[C] written as compensating rows, not by editing history', @Expected = N'-40|2', @Actual = @v;
SET @v = (SELECT CONCAT(PieceCount, N'|', InventoryAvailable) FROM Lots.Lot WHERE Id = @L1);
EXEC test.Assert_IsEqual @TestName = N'[C] the open LOT comes down to actual', @Expected = N'570|570', @Actual = @v;
-- The reconciliation id is the ONLY reason those two negatives were legal:
-- the identical row without one has to be refused by the CHECK. Attempted for
-- real -- counting the rows above proves nothing about the constraint.
DECLARE @CkErr NVARCHAR(4000) = N'(no error)';
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO Workorder.DieCastContribution
        (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId)
    VALUES (@L1, @S1, -20, @Usr, '2020-01-06T16:00:03', @Cell);
    ROLLBACK;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @CkErr = ERROR_MESSAGE();
END CATCH
EXEC test.Assert_Contains @TestName = N'[C] the same negative without a reconciliation is refused by the CHECK',
    @HaystackStr = @CkErr, @NeedleStr = N'CK_DieCastContribution_DeltaNonNeg';
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S1, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] the anchor lowers the shift''s reading 600 -> 580', @Expected = N'580', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[C] die life comes down by the same 20', @Expected = N'11211', @Actual = @v;
SET @v = (SELECT TOP 1 ol.Description FROM Audit.OperationLog ol
          JOIN Audit.LogEventType ev ON ev.Id = ol.LogEventTypeId
          WHERE ol.EntityId = @RecC AND ev.Code = N'DieCastShiftReconciled' ORDER BY ol.Id DESC);
EXEC test.Assert_Contains @TestName = N'[C] the audit row names what came off', @HaystackStr = @v, @NeedleStr = N'-40 good';
GO

-- ====== D: scrap that comes DOWN, and an Open LOT the lock has locked ======
-- Second pass over S1. After C: both LOTs hold 570 and S1 records 570 each,
-- 10 warm-up per cavity, reading 580.
--
-- Two things C could not reach:
--  * a NEGATIVE reject row. C's warm-up actual was 10 against a record of 10,
--    so both scrap inserts produced zero rows. Nothing anywhere tested the
--    downward direction, and RejectEvent.Quantity has no CHECK to catch a sign
--    error the way DieCastContribution.PieceDelta does. Here the actual
--    warm-up is 5 against a record of 10, and an 008 row of 7 is on record
--    that the sheet does not show at all.
--  * an OPEN LOT that is locked. Lots.ufn_DieCastLotCountLock locks a LOT that
--    appears as a genealogy PARENT whatever its status, so 99700622 -- open,
--    consumed into 99700623 -- is open AND locked. Its count must stand and
--    its production must still be recorded in full.
DECLARE @S1 BIGINT = test.ufn_RC(N'S1'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Code999 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
DECLARE @v NVARCHAR(400);

DECLARE @L1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700621');
DECLARE @L2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700622');

-- 99700622 is consumed into 99700623: open, but the count lock says locked
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700623', @CavKey = N'CavB';
DECLARE @L3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700623');
INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, EventAt)
VALUES (@L2, @L3, (SELECT Id FROM Lots.GenealogyRelationshipType WHERE Code = N'Consumption'),
        570, @Usr, '2020-01-08T12:00:00');
SET @v = CAST((SELECT lk.IsLocked FROM Lots.ufn_DieCastLotCountLock(@L2) lk) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[D] an Open LOT consumed into another is locked all the same', @Expected = N'1', @Actual = @v;

-- an 008 row on record for CavA that the press sheet does not show
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S1', @CavKey = N'CavA', @DefectCode = N'008', @Qty = 7, @AtUtc = '2020-01-06T16:00:04';

DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S1, @Cell, @Tool);
-- 580 shots, 575 good, 5 warm-up, no rejects => total good 575 x 2 = 1,150
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":580,"goodShots":575,"warmUpShots":5}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@L1 AS NVARCHAR(20)) + N',"quantity":575},'
                            + N'{"lotId":' + CAST(@L2 AS NVARCHAR(20)) + N',"quantity":575}]';

CREATE TABLE #D (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #D EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S1, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecD BIGINT = (SELECT NewId FROM #D);
SET @v = CAST((SELECT Status FROM #D) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[D] the second pass saves', @Expected = N'1', @Actual = @v;
DROP TABLE #D;

-- the count rule where status and lock disagree
SET @v = (SELECT CONCAT(PieceCount, N'|', InventoryAvailable) FROM Lots.Lot WHERE Id = @L2);
EXEC test.Assert_IsEqual @TestName = N'[D] the Open LOT already consumed keeps its count', @Expected = N'570|570', @Actual = @v;
SET @v = (SELECT CONCAT(SUM(PieceDelta), N'|', COUNT(*)) FROM Workorder.DieCastContribution
          WHERE ReconciliationId = @RecD AND LotId = @L2);
EXEC test.Assert_IsEqual @TestName = N'[D] ...and its production is still recorded in full', @Expected = N'5|1', @Actual = @v;
SET @v = (SELECT CONCAT(PieceCount, N'|', InventoryAvailable) FROM Lots.Lot WHERE Id = @L1);
EXEC test.Assert_IsEqual @TestName = N'[D] the Open LOT nothing has consumed does move', @Expected = N'575|575', @Actual = @v;

-- the downward scrap direction, both inserts
SET @v = (SELECT CONCAT(SUM(Quantity), N'|', COUNT(*)) FROM Workorder.RejectEvent
          WHERE ReconciliationId = @RecD AND DefectCodeId = @Code999);
EXEC test.Assert_IsEqual @TestName = N'[D] warm-up 10 -> 5 backs out -5 on each of two cavities', @Expected = N'-10|2', @Actual = @v;
SET @v = (SELECT CONCAT(SUM(Quantity), N'|', COUNT(*)) FROM Workorder.RejectEvent
          WHERE ReconciliationId = @RecD AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[D] an 008 row the sheet does not show comes off in full', @Expected = N'-7|1', @Actual = @v;
SET @v = CAST((SELECT SUM(Quantity) FROM Workorder.RejectEvent
               WHERE ShiftId = @S1 AND ToolId = @Tool AND DefectCodeId = @Code999) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[D] so the shift now reads the actual 5 warm-up per cavity', @Expected = N'10', @Actual = @v;
SET @v = CAST((SELECT ISNULL(SUM(Quantity), 0) FROM Workorder.RejectEvent
               WHERE ShiftId = @S1 AND ToolId = @Tool AND DefectCodeId = @Code008) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[D] ...and no 008 scrap at all', @Expected = N'0', @Actual = @v;
GO

-- ====== E: the moves lower the watermark, and the die-life guard knows it ======
-- The trap the sec-12 guard (Save 1.6) must not fall into. The guard is
-- pre-transaction, but the die-life delta it has to judge depends on the
-- watermark AFTER the payload's moves -- and a move can only ever LOWER it,
-- because Oee.ufn_ShiftNeighbours excludes the shift being reconciled, so
-- nothing is ever moved ONTO it. Gating on the watermark AS IT IS NOW would
-- OVER-REFUSE: it would reject exactly the save this feature exists for.
--
-- S4 records two credits: 100 pieces at a reading of 30,000 -- the wrong number,
-- which is why it is being moved off to the night shift -- and 200 pieces at an
-- honest 110. The declared actual is 200 shots.
--   watermark as it is now : 30,000  ->  delta 200 - 30,000 = -29,800
--                            against 10,000 lifetime shots that is BELOW ZERO,
--                            so the naive guard refuses.
--   watermark after the move:    110  ->  delta 200 -    110 =     +90, fine.
-- The save must succeed, and die life must move by +90.
--
-- Fresh fixture: D left S1..S5 carrying four sections' worth of history.
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700701', @CavKey = N'CavA', @StatusCode = N'Open';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700702', @CavKey = N'CavB', @StatusCode = N'Open';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700701', @ShiftKey = N'S4', @Pieces = 100, @Reading = 30000, @AtUtc = '2020-01-07T13:20:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700702', @ShiftKey = N'S4', @Pieces = 200, @Reading = 110,   @AtUtc = '2020-01-07T13:21:00';
GO

DECLARE @S3 BIGINT = test.ufn_RC(N'S3'), @S4 BIGINT = test.ufn_RC(N'S4');
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @v NVARCHAR(400);

DECLARE @E1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700701');
DECLARE @E2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'99700702');
DECLARE @CBad BIGINT = (SELECT c.Id FROM Workorder.DieCastContribution c
                        WHERE c.LotId = @E1 AND c.ShotCounterReading = 30000);
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S4, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[E] before the save the shift''s record still reads the wrong 30,000',
    @Expected = N'30000', @Actual = @v;

DECLARE @Moves NVARCHAR(MAX) = N'[{"entityType":"Contribution","entityId":' + CAST(@CBad AS NVARCHAR(20))
    + N',"toShiftId":' + CAST(@S3 AS NVARCHAR(20)) + N'}]';
-- 200 shots, 200 good, 0 warm-up => total good 200 x 2 cavities = 400.
-- 701 loses its 100 to the night shift, so its gap is the full 200.
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":200,"goodShots":200,"warmUpShots":0}';
DECLARE @Lots NVARCHAR(MAX) = N'[{"lotId":' + CAST(@E1 AS NVARCHAR(20)) + N',"quantity":200},'
                            + N'{"lotId":' + CAST(@E2 AS NVARCHAR(20)) + N',"quantity":200}]';

CREATE TABLE #E (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #E EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @MovesJson = @Moves, @LotsJson = @Lots,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @EMsg NVARCHAR(500) = (SELECT Message FROM #E);
SET @v = CAST((SELECT Status FROM #E) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[E] a save whose moves lower the watermark is NOT refused for die life',
    @Expected = N'1', @Actual = @v;
EXEC test.Assert_Contains @TestName = N'[E] ...and in particular not for the lifetime shot count',
    @HaystackStr = @EMsg, @NeedleStr = N'reconciled.';
DROP TABLE #E;

SET @v = CAST((SELECT ShiftId FROM Workorder.DieCastContribution WHERE Id = @CBad) AS NVARCHAR(400));
DECLARE @WantS3 NVARCHAR(400) = CAST(@S3 AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[E] the wrong reading went to the night shift with its row',
    @Expected = @WantS3, @Actual = @v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@Tool, @S4, @Cell) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[E] the shift now reads the declared 200', @Expected = N'200', @Actual = @v;
SET @v = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[E] die life moved by the POST-move delta of +90, not the pre-move -29,800',
    @Expected = N'10090', @Actual = @v;
GO

-- ====== F..I: scrap is reconciled PER APPROVER (Save 1.11) ======
-- Workorder.DieCastShiftReconciliation_ListRejects 1.1 reshaped the READ side
-- around one principle: scrap approval "must not name the wrong person, and it
-- must not silently lose one". Until Save 1.11 the WRITE side did not hold it --
-- @RejTarget was keyed on (DefectCodeId, ToolCavityId) and took
-- MAX(ApprovedByUserId), so two lines on one defect code and one cavity signed
-- by two different QAS merged: the quantity right, one approver picked
-- arbitrarily, the other gone off a Honda-traceable record.
--
-- These four sections are what holds the write side to it. Fresh fixture: E left
-- S3/S4 carrying its own history, and every section below wants a clean shift.
EXEC test.DieCastRecon_Setup;
GO

-- ============ F: two approvers, one defect code, one cavity ============
-- The shape the old key could not represent at all. Both lines name ItemA, so
-- both land on cavity a, and they differ ONLY in who signed.
DECLARE @S5 BIGINT = test.ufn_RC(N'S5'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr'), @Usr2 BIGINT = test.ufn_RC(N'Usr2');
DECLARE @CavA BIGINT = test.ufn_RC(N'CavA'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @ItemA BIGINT = test.ufn_RC(N'ItemA');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- 100 good shots x 2 cavities - 10 no-good = 190, so 95 in each of two new LOTs.
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S5, @Cell, @Tool);
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":110,"goodShots":100,"warmUpShots":10}';
DECLARE @Lots NVARCHAR(MAX) =
      N'[{"ltt":"99700811","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":95},'
    + N'{"ltt":"99700812","toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"quantity":95}]';
DECLARE @Rej NVARCHAR(MAX) =
      N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"itemId":' + CAST(@ItemA AS NVARCHAR(20))
    + N',"quantity":4,"approvedByUserId":' + CAST(@Usr AS NVARCHAR(20)) + N'},'
    + N'{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"itemId":' + CAST(@ItemA AS NVARCHAR(20))
    + N',"quantity":6,"approvedByUserId":' + CAST(@Usr2 AS NVARCHAR(20)) + N'}]';

CREATE TABLE #F (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #F EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecF BIGINT = (SELECT NewId FROM #F);
SET @v = CAST((SELECT Status FROM #F) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[F] two approvers on one defect code and one cavity saves', @Expected = N'1', @Actual = @v;
DROP TABLE #F;

-- THE assertion of this section. Two rows, two approvers, ten pieces between
-- them -- not one row of ten with a name chosen by MAX().
SET @v = (SELECT CONCAT(COUNT(*), N'|', COUNT(DISTINCT ApprovedByUserId), N'|', SUM(Quantity))
          FROM Workorder.RejectEvent WHERE ReconciliationId = @RecF AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[F] both approvers are represented, neither is lost',
    @Expected = N'2|2|10', @Actual = @v;
-- and each owns only what THEY approved
SET @v = (SELECT CONCAT(SUM(CASE WHEN ApprovedByUserId = @Usr  THEN Quantity ELSE 0 END), N'|',
                        SUM(CASE WHEN ApprovedByUserId = @Usr2 THEN Quantity ELSE 0 END))
          FROM Workorder.RejectEvent WHERE ReconciliationId = @RecF AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[F] ...each carrying only the quantity that person approved',
    @Expected = N'4|6', @Actual = @v;
-- both rows are stamped against the SAME cavity: the grain split them by
-- approver, not by moving one of them somewhere else.
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent
               WHERE ReconciliationId = @RecF AND DefectCodeId = @Code008 AND ToolCavityId = @CavA) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[F] ...both against cavity a, which is what made them collide',
    @Expected = N'2', @Actual = @v;

-- READ AND WRITE GRAIN AGREE. ListRejects groups by (DefectCode, Part,
-- Approver); the save groups by (DefectCode, Cavity, Approver). A part maps to
-- the cavities making it -- here ItemA to cavity a -- so the same two facts come
-- back out of the read as went in through the write.
CREATE TABLE #FR (DefectCodeId BIGINT, DefectCode NVARCHAR(50), Defect NVARCHAR(500), IsNonRejectScrap BIT,
                  ItemId BIGINT, PartNumber NVARCHAR(50), Quantity INT, Cavities INT,
                  ApprovedByUserId BIGINT, ApprovedBy NVARCHAR(10));
INSERT INTO #FR EXEC Workorder.DieCastShiftReconciliation_ListRejects
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = (SELECT CONCAT(COUNT(*), N'|', SUM(Quantity)) FROM #FR WHERE DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[F] the read side shows the same two facts the write side wrote',
    @Expected = N'2|10', @Actual = @v;
SET @v = (SELECT CONCAT(MAX(CASE WHEN ApprovedByUserId = @Usr  THEN Quantity END), N'|',
                        MAX(CASE WHEN ApprovedByUserId = @Usr2 THEN Quantity END))
          FROM #FR WHERE DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[F] ...attributed to the same two people', @Expected = N'4|6', @Actual = @v;
DROP TABLE #FR;
GO

-- ============ G: two unapproved sides must MEET, not pass each other ============
-- ApprovedByUserId is nullable on both sides of section 10's FULL JOIN, and
-- NULL = NULL is UNKNOWN. A recorded row with no approver and a typed line with
-- no approver, at the same quantity, are the SAME fact: the honest answer is no
-- scrap rows at all. A plain equality would strand them on opposite sides of the
-- join and write a spurious "-5 then +5" pair instead -- two rows that never net
-- to zero in ListRejects because they are not even the same grain any more.
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @CavA BIGINT = test.ufn_RC(N'CavA'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @ItemA BIGINT = test.ufn_RC(N'ItemA');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @v NVARCHAR(400);

-- 5 pieces of 008 on record against cavity a, signed by NOBODY (the fixture's
-- default, and the ordinary shape for scrap entered without a QAS present).
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'008', @Qty = 5,
    @AtUtc = '2020-01-07T13:10:00';

DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
-- 100 good shots x 2 - 5 no-good = 195. warm-up 0 against 0 on record, so the
-- warm-up half of section 10 emits nothing and any scrap row that appears came
-- from the 008 comparison.
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":100,"goodShots":100,"warmUpShots":0}';
DECLARE @Lots NVARCHAR(MAX) =
      N'[{"ltt":"99700821","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":98},'
    + N'{"ltt":"99700822","toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"quantity":97}]';
-- the SAME 5 pieces, typed off the press sheet, also with no approver
DECLARE @Rej NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20))
    + N',"itemId":' + CAST(@ItemA AS NVARCHAR(20)) + N',"quantity":5}]';

CREATE TABLE #G (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #G EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej,
    @LoadedStamp = @Stamp, @AppUserId = @Usr, @PreviewOnly = 1;
DECLARE @PlanG NVARCHAR(MAX) = (SELECT PlanJson FROM #G);
SET @v = ISNULL((SELECT Message FROM #G), N'(null)');
EXEC test.Assert_Contains @TestName = N'[G] the payload previews rather than being refused',
    @HaystackStr = @v, @NeedleStr = N'Nothing is saved yet';
-- THE assertion: the plan proposes NO scrap movement whatsoever.
SET @v = CAST((SELECT COUNT(*) FROM OPENJSON(@PlanG, N'$.scrap')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[G] an unapproved line meets the unapproved row on record: no scrap rows',
    @Expected = N'0', @Actual = @v;
DROP TABLE #G;

-- and the same through the real save, because a plan is only a promise
CREATE TABLE #G2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #G2 EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecG BIGINT = (SELECT NewId FROM #G2);
SET @v = CAST((SELECT Status FROM #G2) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[G] the save runs (the new LOTs are the reason there is anything to do)',
    @Expected = N'1', @Actual = @v;
DROP TABLE #G2;
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ReconciliationId = @RecG) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[G] ...and writes no reject row at all', @Expected = N'0', @Actual = @v;
SET @v = (SELECT CONCAT(COUNT(*), N'|', SUM(Quantity)) FROM Workorder.RejectEvent
          WHERE ShiftId = @S4 AND ToolId = @Tool AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[G] ...so the shift still reads the one 5-piece row it already had',
    @Expected = N'1|5', @Actual = @v;
GO

-- ============ H: a reduction for ONE approver only ============
-- Cavity a carries 10 pieces of 008 signed by Usr and 6 signed by Usr2. The
-- press sheet says Usr approved only 4; Usr2's 6 is right. The negative must
-- land against Usr and Usr2 must not be touched.
DECLARE @S2 BIGINT = test.ufn_RC(N'S2'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr'), @Usr2 BIGINT = test.ufn_RC(N'Usr2');
DECLARE @CavA BIGINT = test.ufn_RC(N'CavA'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @ItemA BIGINT = test.ufn_RC(N'ItemA');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @v NVARCHAR(400);

EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S2', @CavKey = N'CavA', @DefectCode = N'008', @Qty = 10,
    @AtUtc = '2020-01-06T16:10:00', @ApprovedByUserId = @Usr;
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S2', @CavKey = N'CavA', @DefectCode = N'008', @Qty = 6,
    @AtUtc = '2020-01-06T16:10:01', @ApprovedByUserId = @Usr2;

DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S2, @Cell, @Tool);
-- 50 good shots x 2 - 10 no-good = 90, so 45 in each of two new LOTs.
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":50,"goodShots":50,"warmUpShots":0}';
DECLARE @Lots NVARCHAR(MAX) =
      N'[{"ltt":"99700831","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":45},'
    + N'{"ltt":"99700832","toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"quantity":45}]';
DECLARE @Rej NVARCHAR(MAX) =
      N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"itemId":' + CAST(@ItemA AS NVARCHAR(20))
    + N',"quantity":4,"approvedByUserId":' + CAST(@Usr AS NVARCHAR(20)) + N'},'
    + N'{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"itemId":' + CAST(@ItemA AS NVARCHAR(20))
    + N',"quantity":6,"approvedByUserId":' + CAST(@Usr2 AS NVARCHAR(20)) + N'}]';

CREATE TABLE #H (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #H EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @RejectsJson = @Rej,
    @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecH BIGINT = (SELECT NewId FROM #H);
SET @v = CAST((SELECT Status FROM #H) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[H] a per-approver reduction saves', @Expected = N'1', @Actual = @v;
DROP TABLE #H;

SET @v = (SELECT CONCAT(COUNT(*), N'|', SUM(Quantity)) FROM Workorder.RejectEvent
          WHERE ReconciliationId = @RecH AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[H] exactly one compensating row, for the six pieces that came off',
    @Expected = N'1|-6', @Actual = @v;
SET @v = (SELECT CONCAT(SUM(CASE WHEN ApprovedByUserId = @Usr  THEN Quantity ELSE 0 END), N'|',
                        SUM(CASE WHEN ApprovedByUserId = @Usr2 THEN Quantity ELSE 0 END))
          FROM Workorder.RejectEvent WHERE ReconciliationId = @RecH AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[H] ...against the approver whose figure was wrong, and nobody else',
    @Expected = N'-6|0', @Actual = @v;
-- what the shift now says about each of them
SET @v = (SELECT CONCAT(SUM(CASE WHEN ApprovedByUserId = @Usr  THEN Quantity ELSE 0 END), N'|',
                        SUM(CASE WHEN ApprovedByUserId = @Usr2 THEN Quantity ELSE 0 END))
          FROM Workorder.RejectEvent WHERE ShiftId = @S2 AND ToolId = @Tool AND DefectCodeId = @Code008);
EXEC test.Assert_IsEqual @TestName = N'[H] ...so the record reads 4 approved by one and 6 by the other',
    @Expected = N'4|6', @Actual = @v;
GO

-- ============ I: a removal keeps the name, so the pair nets to zero ============
-- A recorded row the press sheet does not show at all comes off in full. There
-- is no typed line to take the approver from, so the compensating negative must
-- take it from the row it cancels -- otherwise ListRejects sees +8 by a person
-- and -8 by nobody: two rows of DIFFERENT grain, so its HAVING SUM(...) <> 0
-- can never net them away and the discrepancy is on screen for ever.
DECLARE @S3 BIGINT = test.ufn_RC(N'S3'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr'), @Usr2 BIGINT = test.ufn_RC(N'Usr2');
DECLARE @CavA BIGINT = test.ufn_RC(N'CavA'), @CavB BIGINT = test.ufn_RC(N'CavB');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @v NVARCHAR(400);

EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S3', @CavKey = N'CavA', @DefectCode = N'008', @Qty = 8,
    @AtUtc = '2020-01-07T02:00:00', @ApprovedByUserId = @Usr2;

DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S3, @Cell, @Tool);
-- 50 good shots x 2 - 0 no-good = 100, so 50 in each of two new LOTs.
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":50,"goodShots":50,"warmUpShots":0}';
DECLARE @Lots NVARCHAR(MAX) =
      N'[{"ltt":"99700841","toolCavityId":' + CAST(@CavA AS NVARCHAR(20)) + N',"quantity":50},'
    + N'{"ltt":"99700842","toolCavityId":' + CAST(@CavB AS NVARCHAR(20)) + N',"quantity":50}]';

CREATE TABLE #I (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #I EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S3, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @RecI BIGINT = (SELECT NewId FROM #I);
SET @v = CAST((SELECT Status FROM #I) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[I] a sheet that omits a recorded row saves', @Expected = N'1', @Actual = @v;
DROP TABLE #I;

SET @v = (SELECT CONCAT(COUNT(*), N'|', SUM(Quantity), N'|', MAX(ApprovedByUserId))
          FROM Workorder.RejectEvent WHERE ReconciliationId = @RecI AND DefectCodeId = @Code008);
DECLARE @WantI NVARCHAR(400) = CONCAT(N'1|-8|', @Usr2);
EXEC test.Assert_IsEqual @TestName = N'[I] the compensating negative carries the approver of the row it cancels',
    @Expected = @WantI, @Actual = @v;

-- and therefore the read side nets it away rather than showing a phantom pair
CREATE TABLE #IR (DefectCodeId BIGINT, DefectCode NVARCHAR(50), Defect NVARCHAR(500), IsNonRejectScrap BIT,
                  ItemId BIGINT, PartNumber NVARCHAR(50), Quantity INT, Cavities INT,
                  ApprovedByUserId BIGINT, ApprovedBy NVARCHAR(10));
INSERT INTO #IR EXEC Workorder.DieCastShiftReconciliation_ListRejects
    @ShiftId = @S3, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #IR WHERE DefectCodeId = @Code008) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[I] ...so a net-zero pair still drops out of the read entirely',
    @Expected = N'0', @Actual = @v;
DROP TABLE #IR;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
