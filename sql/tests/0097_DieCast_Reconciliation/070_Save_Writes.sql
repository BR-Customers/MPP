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

CREATE TABLE #A (Status BIT, Message NVARCHAR(500), NewId BIGINT);
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
CREATE TABLE #A2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
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

CREATE TABLE #B (Status BIT, Message NVARCHAR(500), NewId BIGINT);
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

CREATE TABLE #C (Status BIT, Message NVARCHAR(500), NewId BIGINT);
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

CREATE TABLE #D (Status BIT, Message NVARCHAR(500), NewId BIGINT);
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

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
