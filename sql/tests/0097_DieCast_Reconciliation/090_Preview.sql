-- =============================================
-- File: 0097_DieCast_Reconciliation/090_Preview.sql
-- The confirmation panel's preview. The team lead sees what will change before
-- they commit, and the only way that promise can be kept is for the preview and
-- the save to BE the same computation: Workorder.DieCastShiftReconciliation_Save
-- with @PreviewOnly = 1 runs sections 1-12 and returns immediately before
-- BEGIN TRANSACTION.
--
-- The load-bearing assertion in this file is [Preview] the plan the preview
-- showed is the plan the save applied -- the two PlanJson values compared
-- character for character. If a future change reintroduces a second computation
-- anywhere, that one assertion fails.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/090_Preview.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700701', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700702', @CavKey = N'CavB', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700701', @ShiftKey = N'S4', @Pieces = 100, @Reading = 100, @AtUtc = '2020-01-07T13:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700702', @ShiftKey = N'S4', @Pieces = 100, @Reading = 100, @AtUtc = '2020-01-07T13:00:01';
GO

-- ============ 1: a preview writes nothing at all ============
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @v NVARCHAR(400), @m NVARCHAR(500);

DECLARE @Before NVARCHAR(400) = (
    SELECT CONCAT((SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastContribution c JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Lots.Lot WHERE ToolId = @Tool), N'|',
                  (SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool)));

-- 120 good shots x 2 cavities = 240 good, 20 warm-up, so 120 per LOT against 100
-- already on record: an ADDITION of 20 on each, plus a reading that raises die life.
DECLARE @Stamp NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @Lots NVARCHAR(MAX) = N'[{"ltt":"99700701","quantity":120},{"ltt":"99700702","quantity":120}]';
DECLARE @Actual NVARCHAR(MAX) = N'{"totalShots":140,"goodShots":120,"warmUpShots":20}';

CREATE TABLE #P (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #P EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr,
    @PreviewOnly = 1;

DECLARE @After NVARCHAR(400) = (
    SELECT CONCAT((SELECT COUNT(*) FROM Workorder.DieCastShiftReconciliation WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastContribution c JOIN Lots.Lot l ON l.Id = c.LotId WHERE l.ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Workorder.DieCastCounterAnchor WHERE ToolId = @Tool), N'|',
                  (SELECT COUNT(*) FROM Lots.Lot WHERE ToolId = @Tool), N'|',
                  (SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool)));
EXEC test.Assert_IsEqual @TestName = N'[Preview] a preview writes nothing', @Expected = @Before, @Actual = @After;
SET @v = CAST((SELECT Status FROM #P) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and reports that it would save', @Expected = N'1', @Actual = @v;
SET @v = CAST(ISNULL((SELECT CAST(NewId AS NVARCHAR(20)) FROM #P), N'(null)') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...with no reconciliation id, because none was created',
    @Expected = N'(null)', @Actual = @v;
SET @m = (SELECT Message FROM #P);
EXEC test.Assert_Contains @TestName = N'[Preview] ...and says so in plain words',
    @HaystackStr = @m, @NeedleStr = N'Nothing is saved yet';

-- ============ 2: the plan the preview showed is the plan the save applied ============
-- THE assertion. One computation, so one answer.
DECLARE @PreviewPlan NVARCHAR(MAX) = (SELECT PlanJson FROM #P);
CREATE TABLE #Sv (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #Sv EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @Actual, @LotsJson = @Lots, @LoadedStamp = @Stamp, @AppUserId = @Usr;
DECLARE @SavePlan NVARCHAR(MAX) = (SELECT PlanJson FROM #Sv);
SET @v = CAST((SELECT Status FROM #Sv) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] the same payload saves', @Expected = N'1', @Actual = @v;
DECLARE @Same NVARCHAR(50) = CASE WHEN @PreviewPlan = @SavePlan THEN N'identical' ELSE N'DIFFERENT' END;
EXEC test.Assert_IsEqual @TestName = N'[Preview] the plan the preview showed is the plan the save applied',
    @Expected = N'identical', @Actual = @Same;

-- and the plan was not a description of nothing
SET @v = JSON_VALUE(@PreviewPlan, N'$.totals.piecesAdded');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...20 pieces added to each of two LOTs', @Expected = N'40', @Actual = @v;
SET @v = JSON_VALUE(@PreviewPlan, N'$.hasReduction');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and nothing here is a reduction', @Expected = N'false', @Actual = @v;

-- the predicted die life is the die life the save landed on
SET @v = JSON_VALUE(@PreviewPlan, N'$.dieLife.after');
DECLARE @WantShot NVARCHAR(400) = CAST((SELECT ShotCount FROM Tools.Tool WHERE Id = @Tool) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] die life before -> after is a prediction the save kept',
    @Expected = @WantShot, @Actual = @v;
DROP TABLE #Sv;
DROP TABLE #P;
GO

-- ============ 3: a preview refuses exactly what the save refuses ============
-- Word for word, because it is the same GOTO Fail.
DECLARE @S2 BIGINT = test.ufn_RC(N'S2'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @v NVARCHAR(400);
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S2, @Cell, @Tool);
-- total <> good + warm-up: a typo the team lead must see before they commit
DECLARE @BadActual NVARCHAR(MAX) = N'{"totalShots":100,"goodShots":80,"warmUpShots":15}';

CREATE TABLE #PF (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PF EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @BadActual, @LoadedStamp = @Stamp2, @AppUserId = @Usr, @PreviewOnly = 1;
DECLARE @PreviewMsg NVARCHAR(500) = (SELECT Message FROM #PF);
DECLARE @PreviewStatus NVARCHAR(10) = CAST((SELECT Status FROM #PF) AS NVARCHAR(10));

CREATE TABLE #SF (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #SF EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = @BadActual, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
DECLARE @SaveMsg NVARCHAR(500) = (SELECT Message FROM #SF);

EXEC test.Assert_IsEqual @TestName = N'[Preview] a preview refuses what the save refuses, word for word',
    @Expected = @SaveMsg, @Actual = @PreviewMsg;
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...as a refusal, not as a plan',
    @Expected = N'0', @Actual = @PreviewStatus;
SET @v = ISNULL((SELECT PlanJson FROM #PF), N'(null)');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...with no plan attached to it', @Expected = N'(null)', @Actual = @v;
DROP TABLE #PF;
DROP TABLE #SF;
GO

-- ============ 4: a refused preview leaves no FailureLog row ============
-- A team lead previews a half-typed sheet repeatedly; their typing is not a
-- system failure and must not fill Audit.FailureLog. A refused SAVE still logs.
DECLARE @S2 BIGINT = test.ufn_RC(N'S2'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @v NVARCHAR(400);
DECLARE @Proc NVARCHAR(200) = N'Workorder.DieCastShiftReconciliation_Save';
DECLARE @LogBefore INT = (SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = @Proc);
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S2, @Cell, @Tool);

CREATE TABLE #PL (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PL EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":100,"goodShots":80,"warmUpShots":15}',
    @LoadedStamp = @Stamp2, @AppUserId = @Usr, @PreviewOnly = 1;
SET @v = CAST((SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = @Proc) - @LogBefore AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] a refused preview logs no failure', @Expected = N'0', @Actual = @v;
DELETE FROM #PL;

INSERT INTO #PL EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":100,"goodShots":80,"warmUpShots":15}',
    @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @v = CAST((SELECT COUNT(*) FROM Audit.FailureLog WHERE ProcedureName = @Proc) - @LogBefore AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...but a refused SAVE still does', @Expected = N'1', @Actual = @v;
DROP TABLE #PL;
GO

-- ============ 5: the amber tick box is a fact, not a guess ============
-- Spec sec 7.5: amber covers a reduction in PRODUCTION, DIE LIFE or a COUNT.
-- Backing scrap OUT is none of those -- it raises good production -- so it is
-- deliberately not amber, and the screen must not decide that for itself.
DECLARE @S5 BIGINT = test.ufn_RC(N'S5'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @v NVARCHAR(400);

-- 12 pieces of 008 on record for S5 against cavity a, basketless (the 0084 shape)
DECLARE @CavA BIGINT = test.ufn_RC(N'CavA');
INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                   DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
SELECT NULL, NULL, tc.ItemId, @Tool, tc.Id, @S5, @Cell, @Code008, 12, NULL, N'fixture', @Usr, NULL, '2020-01-07T20:00:00'
FROM Tools.ToolCavity tc WHERE tc.Id = @CavA;

DECLARE @Stamp5 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S5, @Cell, @Tool);
CREATE TABLE #PS (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PS EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":0,"goodShots":0,"warmUpShots":0}',
    @LoadedStamp = @Stamp5, @AppUserId = @Usr, @PreviewOnly = 1;
DECLARE @ScrapPlan NVARCHAR(MAX) = (SELECT PlanJson FROM #PS);
SET @v = JSON_VALUE(@ScrapPlan, N'$.hasReduction');
EXEC test.Assert_IsEqual @TestName = N'[Preview] backing scrap out is not a reduction',
    @Expected = N'false', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM OPENJSON(@ScrapPlan, N'$.scrap')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and the scrap line is on the plan for the team lead to see',
    @Expected = N'1', @Actual = @v;
SET @v = (SELECT TOP 1 CAST(JSON_VALUE(value, N'$.delta') AS NVARCHAR(400)) FROM OPENJSON(@ScrapPlan, N'$.scrap'));
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...as a negative delta against its cavity',
    @Expected = N'-12', @Actual = @v;
-- the empty groups are [] and not missing keys: a binding that reads $.moves
-- must get a list, on every plan, or the screen errors on the empty path.
SET @v = ISNULL(JSON_QUERY(@ScrapPlan, N'$.moves'), N'(missing)');
EXEC test.Assert_IsEqual @TestName = N'[Preview] an empty group is [], never a missing key',
    @Expected = N'[]', @Actual = @v;
DROP TABLE #PS;
GO

-- ============ 6: a reduction IS flagged ============
-- Both LOTs carry 120 from section 2. Declaring 110 each takes them DOWN, which
-- is production reduced and must arm the tick box.
--
-- THE FIGURES ARE CONSTRAINED, not free. Every one of them is forced:
--   * total = good + warm (sec 9), and no LOT may exceed the shift's good shots
--     ("More pieces than the shift's N good shots made"), so a reduction cannot
--     be written by lowering ONE LOT below a good-shot count the other exceeds.
--   * good x 2 cavities - no-good = the LOT sum, so 110 good shots forces
--     110 + 110.
--   * total is 140, which is the anchor section 2's save declared, so the
--     die-life delta here is ZERO and hasReduction is armed by the LOT gaps
--     ALONE -- if the total were lower, a die-life reduction would arm it too
--     and the assertion would no longer be about a LOT.
--   * warm goes 20 -> 30, an ADDITION of scrap, which is deliberately not a
--     reduction and must not arm the box by itself.
--
-- pieceCountAfter is 110, and the reason it moves at all is worth writing down.
-- Section 2's save corrected 99700701's count 100 -> 120 through
-- Lots.Lot_ApplyPieceCountCorrection, which writes a Lots.LotAttributeChange
-- row -- and a post-release count correction is one of the four things
-- Lots.ufn_DieCastLotCountLock locks a LOT for. It does NOT lock here, because
-- that clause carries `ac.Reason NOT LIKE N'Shift reconciliation #%'`: a
-- reconciliation's own correction is deliberately exempt, so a second
-- reconciliation of the same shift can still put the count right. The LOT is
-- therefore still Good-and-unlocked, CorrectCount stays 1, and the count
-- follows the gap down to 120 - 10 = 110.
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'WrongNumbers');
DECLARE @v NVARCHAR(400);
DECLARE @Stamp4 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
DECLARE @Down NVARCHAR(MAX) = N'[{"ltt":"99700701","quantity":110},{"ltt":"99700702","quantity":110}]';

CREATE TABLE #PD (Status BIT, Message NVARCHAR(500), NewId BIGINT, PlanJson NVARCHAR(MAX));
INSERT INTO #PD EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":140,"goodShots":110,"warmUpShots":30}',
    @LotsJson = @Down, @LoadedStamp = @Stamp4, @AppUserId = @Usr, @PreviewOnly = 1;
DECLARE @DownPlan NVARCHAR(MAX) = (SELECT PlanJson FROM #PD);
-- the preview must have produced a plan at all: a refusal returns NULL here and
-- every JSON_VALUE below would silently read NULL rather than a wrong number.
SET @v = ISNULL((SELECT Message FROM #PD), N'(null)');
EXEC test.Assert_Contains @TestName = N'[Preview] a reduction previews rather than being refused',
    @HaystackStr = @v, @NeedleStr = N'Nothing is saved yet';
SET @v = JSON_VALUE(@DownPlan, N'$.dieLife.delta');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...with die life unchanged, so only the LOTs can arm the box',
    @Expected = N'0', @Actual = @v;
SET @v = JSON_VALUE(@DownPlan, N'$.hasReduction');
EXEC test.Assert_IsEqual @TestName = N'[Preview] taking a LOT down is a reduction, and the plan says so',
    @Expected = N'true', @Actual = @v;
SET @v = JSON_VALUE(@DownPlan, N'$.totals.piecesRemoved');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...naming how many pieces come off', @Expected = N'20', @Actual = @v;
SET @v = (SELECT TOP 1 CAST(JSON_VALUE(value, N'$.pieceCountBefore') AS NVARCHAR(400))
          FROM OPENJSON(@DownPlan, N'$.lots') WHERE JSON_VALUE(value, N'$.ltt') = N'99700701');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...what each LOT''s count is now', @Expected = N'120', @Actual = @v;
SET @v = (SELECT TOP 1 CAST(JSON_VALUE(value, N'$.pieceCountAfter') AS NVARCHAR(400))
          FROM OPENJSON(@DownPlan, N'$.lots') WHERE JSON_VALUE(value, N'$.ltt') = N'99700701');
EXEC test.Assert_IsEqual @TestName = N'[Preview] ...and what each LOT''s count becomes', @Expected = N'110', @Actual = @v;
DROP TABLE #PD;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
