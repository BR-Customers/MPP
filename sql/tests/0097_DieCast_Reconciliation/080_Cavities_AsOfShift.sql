-- =============================================
-- File: 0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql
-- Which cavities a past shift is reconciled against. Two WRONG answers have
-- been shipped for this, and this file pins the set against BOTH of them.
--
-- WRONG ANSWER 1 -- "as of now" (`tc.DeprecatedAt IS NULL`, before Save 1.7).
-- A cavity that ran during the shift and has since been deprecated was
-- invisible to the comparison, so its recorded scrap could never be backed out:
-- the save answered "Nothing to save: the record already matches actual" while
-- ListRejects (which has no cavity filter at all, and should not) went on
-- showing the scrap. The team lead saw a discrepancy they had no way to clear.
--
-- WRONG ANSWER 2 -- "an interval overlap", adding `tc.CreatedAt < @EndUtc`
-- (Save 1.7, lived one day). CreatedAt is a CONFIGURATION timestamp -- when a
-- person typed the cavity into the MES -- and says nothing about whether the
-- cavity was on the die. The 2026-09-18 production snapshot settled it: 88 of
-- 149 cavities across 17 dies were configured on 2026-09-17, the day AFTER the
-- 2026-09-16 night shift this whole feature exists to reconcile, so that bound
-- resolved 17 dies to zero cavities and refused the founding shift outright.
-- Machine 11's DMO125 was configured a month earlier and would have passed the
-- acceptance replay -- the bound "worked" by luck of configuration order.
--
-- THE ANSWER (Save 1.8, GetHeader 1.2): the DeprecatedAt half ALONE.
--   cs.Code = N'Active' AND (tc.DeprecatedAt IS NULL OR tc.DeprecatedAt > start)
-- Deprecation is a real manufacturing fact about a real date, so comparing it
-- to the shift is sound. Creation is not, so nothing compares it. The worst
-- case is a picker offering a cavity for a shift that predates it, which a team
-- lead simply does not choose -- strictly better than refusing 17 dies.
--
-- The die is given four extra cavities so that ALL THREE answers differ in
-- MEMBERSHIP and in SIZE -- a count that happened to match would prove nothing:
--
--   code  created      deprecated    CORRECT   as-of-now   interval-overlap
--   ----  -----------  ------------  --------  ----------  ----------------
--   a     (default)    --            IN        IN          out  (fixture)
--   b     (default)    --            IN        IN          out  (fixture)
--   c     2019-12-01   2020-06-01    IN        out         IN
--   e     2019-12-01   2020-06-01    IN        out         IN
--   d     2020-06-01   --            IN        IN          out
--   f     2019-12-01   2019-12-15    out       out         out
--
--   CORRECT          : {a, b, c, d, e} = 5
--   as of now        : {a, b, d}       = 3
--   interval overlap : {c, e}          = 2
--
-- a and b take the DEFAULT CreatedAt (today), which is the prod shape: a cavity
-- configured years after the shift it ran in. f is deprecated BEFORE the shift
-- and must stay out -- it is what keeps the load-bearing DeprecatedAt half, and
-- the "Choose a cavity that was on this die during" refusal, under test.
-- Every assertion below turns on those differences. Fixture shifts are
-- 06-07 January 2020.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/080_Cavities_AsOfShift.sql';
GO
EXEC test.DieCastRecon_Setup;
GO

DECLARE @Tool BIGINT = test.ufn_RC(N'Tool'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @ItemA BIGINT = test.ufn_RC(N'ItemA'), @ItemB BIGINT = test.ufn_RC(N'ItemB');
DECLARE @Active BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

-- c and e: on the die during the shift, deprecated five months later. These are
-- the cavities the DeprecatedAt half exists for -- it must keep them IN.
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedAt, DeprecatedAt, CreatedByUserId)
VALUES (@Tool, N'c', @Active, N'RC cavity c -- deprecated AFTER the shift', @ItemA, '2019-12-01T00:00:00', '2020-06-01T00:00:00', @Usr),
       (@Tool, N'e', @Active, N'RC cavity e -- deprecated AFTER the shift', @ItemA, '2019-12-01T00:00:00', '2020-06-01T00:00:00', @Usr);
-- d: CONFIGURED five months AFTER the shift, and still active today. It is IN,
-- deliberately -- see WRONG ANSWER 2 above. This row is the one an interval
-- overlap would exclude, and prod is full of them.
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'd', @Active, N'RC cavity d -- configured AFTER the shift', @ItemB, '2020-06-01T00:00:00', @Usr);
-- f: came off the die three weeks BEFORE the shift. It is OUT, and it is the
-- only thing keeping the DeprecatedAt half honest: delete the half and f joins
-- the set, so every membership assertion below moves.
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedAt, DeprecatedAt, CreatedByUserId)
VALUES (@Tool, N'f', @Active, N'RC cavity f -- deprecated BEFORE the shift', @ItemA, '2019-12-01T00:00:00', '2019-12-15T00:00:00', @Usr);
GO

-- ============ 1: the read and the save agree on the same cavity set ============
-- ActiveCavities is not decoration: the screen computes the total good it
-- expects as (good shots x ActiveCavities - no-good), and the save recomputes
-- the same figure from ITS cavity set and refuses any mismatch. If one were
-- resolved as of the shift and the other as of now, a correctly entered press
-- sheet would become unsaveable the moment a cavity was deprecated.
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @v NVARCHAR(400);

CREATE TABLE #H (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3), IsOpen BIT,
                 CellLocationId BIGINT, PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT,
                 AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ActiveCavities INT, DieShotCount INT,
                 RecordedTotalShots INT, RecordedWarmUpShots INT, RecordedNoGood INT, RecordedGood INT,
                 HasShiftEndNumber BIT, Stamp NVARCHAR(100), LastReconciledAtEt DATETIME2(3), LastReconciledBy NVARCHAR(20));
INSERT INTO #H EXEC Workorder.DieCastShiftReconciliation_GetHeader
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT ActiveCavities FROM #H) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] the header counts 5 -- every cavity not already off the die, whenever it was configured',
    @Expected = N'5', @Actual = @v;
DROP TABLE #H;
GO

-- ============ 2: A7 divides across the cavities that were running THEN ============
-- A reject line with no part named spans every cavity in the set, and its amount
-- must divide evenly across it. The message names the number the save actually
-- used, so this asserts the A7 span itself. 3 divides the as-of-now set of 3
-- evenly and would fall through to a different message entirely; against the
-- interval-overlap set of 2 the message would say 2. Only the correct set says 5.
DECLARE @S3 BIGINT = test.ufn_RC(N'S3'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @m NVARCHAR(500);

CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @Stamp3 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S3, @Cell, @Tool);
DECLARE @Rej3 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@Code008 AS NVARCHAR(20)) + N',"quantity":3}]';
INSERT INTO #R EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S3, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":0,"goodShots":0,"warmUpShots":0}', @RejectsJson = @Rej3,
    @LoadedStamp = @Stamp3, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #R);
EXEC test.Assert_Contains @TestName = N'[Cav] an A7 reject line divides across the cavities that had not come off the die',
    @HaystackStr = @m, @NeedleStr = N'does not divide evenly across 5 cavities';
DROP TABLE #R;
GO

-- ============ 3: scrap on a since-deprecated cavity can be backed out ============
-- The whole complaint, end to end. 9 pieces of 008 are on record for S4 against
-- cavity c -- basketless, which is the 0084 shape -- and the press sheet shows
-- no 008 at all. Nothing else about the shift is in question: no production, no
-- reading, no warm-up, so the ONLY thing the save can find to do is back that 9
-- out. Under the old as-of-now rule cavity c was not in the set, the gap query
-- in sec 10 filters the recorded rows down to the set, there was no gap, and the
-- save answered "Nothing to save".
DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code008 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'008');
DECLARE @Code999 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
DECLARE @v NVARCHAR(400), @m NVARCHAR(500);

DECLARE @CavC BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @Tool AND CavityCode = N'c');
DECLARE @CavD BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @Tool AND CavityCode = N'd');
INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                   DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
SELECT NULL, NULL, tc.ItemId, @Tool, tc.Id, @S4, @Cell, @Code008, 9, NULL, N'fixture', @Usr, NULL, '2020-01-07T13:00:00'
FROM Tools.ToolCavity tc WHERE tc.Id = @CavC;

-- what the team lead sees before they save: the read has never filtered by
-- cavity, so the 9 is on the screen whatever the save thinks.
CREATE TABLE #LR (DefectCodeId BIGINT, DefectCode NVARCHAR(20), Defect NVARCHAR(200), IsNonRejectScrap BIT,
                  ItemId BIGINT, PartNumber NVARCHAR(50), Quantity INT, Cavities INT,
                  ApprovedByUserId BIGINT, ApprovedBy NVARCHAR(20));
INSERT INTO #LR EXEC Workorder.DieCastShiftReconciliation_ListRejects
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST(ISNULL((SELECT SUM(Quantity) FROM #LR WHERE DefectCodeId = @Code008), 0) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] the screen shows scrap on the deprecated cavity -- it always did',
    @Expected = N'9', @Actual = @v;
DELETE FROM #LR;

DECLARE @Stamp4 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S4, @Cell, @Tool);
CREATE TABLE #S (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #S EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":0,"goodShots":0,"warmUpShots":0}',
    @LoadedStamp = @Stamp4, @AppUserId = @Usr;
DECLARE @RecId BIGINT = (SELECT NewId FROM #S);
SET @v = CAST((SELECT Status FROM #S) AS NVARCHAR(400));
SET @m = (SELECT Message FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Cav] a deprecated cavity''s scrap gives the save something to do',
    @Expected = N'1', @Actual = @v;
DECLARE @NotNothing NVARCHAR(50) = CASE WHEN @m LIKE N'%already matches actual%' THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...it does NOT answer "the record already matches actual"',
    @Expected = N'no', @Actual = @NotNothing;
DROP TABLE #S;

SET @v = (SELECT CONCAT(SUM(Quantity), N'|', COUNT(*), N'|', MAX(ToolCavityId)) FROM Workorder.RejectEvent
          WHERE ReconciliationId = @RecId AND DefectCodeId = @Code008);
DECLARE @WantBackout NVARCHAR(400) = CONCAT(N'-9|1|', @CavC);
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...backing the 9 out with one compensating row, against that cavity',
    @Expected = @WantBackout, @Actual = @v;
SET @v = CAST(ISNULL((SELECT SUM(Quantity) FROM Workorder.RejectEvent
                      WHERE ShiftId = @S4 AND ToolId = @Tool AND DefectCodeId = @Code008), 0) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...so the shift now has no 008 scrap on record', @Expected = N'0', @Actual = @v;

INSERT INTO #LR EXEC Workorder.DieCastShiftReconciliation_ListRejects
    @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #LR WHERE DefectCodeId = @Code008) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...and the screen agrees with the save: the discrepancy is cleared',
    @Expected = N'0', @Actual = @v;
DROP TABLE #LR;
GO

-- ============ 4: which cavities, exactly -- membership, not a count ============
-- Warm-up fans out one row per cavity in the set, so a shift whose only content
-- is warm-up names the set directly. S5, 3 warm-up shots, nothing else.
DECLARE @S5 BIGINT = test.ufn_RC(N'S5'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @Code999 BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'999');
DECLARE @v NVARCHAR(400);

DECLARE @Stamp5 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S5, @Cell, @Tool);
CREATE TABLE #W (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #W EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S5, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @ActualJson = N'{"totalShots":3,"goodShots":0,"warmUpShots":3}',
    @LoadedStamp = @Stamp5, @AppUserId = @Usr;
DECLARE @RecW BIGINT = (SELECT NewId FROM #W);
SET @v = CAST((SELECT Status FROM #W) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] a warm-up-only shift saves', @Expected = N'1', @Actual = @v;
DROP TABLE #W;

-- the cavity codes the warm-up actually landed on, in order
SET @v = (SELECT STRING_AGG(tc.CavityCode, N',') WITHIN GROUP (ORDER BY tc.CavityCode)
          FROM Workorder.RejectEvent re
          INNER JOIN Tools.ToolCavity tc ON tc.Id = re.ToolCavityId
          WHERE re.ReconciliationId = @RecW AND re.DefectCodeId = @Code999);
-- a,b,c,d,e -- and NOT f, which had already come off the die. d is present on
-- purpose: it was configured after the shift, and configuration date is not a
-- fact about the die (see WRONG ANSWER 2 at the top of this file).
EXEC test.Assert_IsEqual @TestName = N'[Cav] warm-up fans out to every cavity not already off the die -- f excluded, d included',
    @Expected = N'a,b,c,d,e', @Actual = @v;
GO

-- ============ 5: the cavity a NEW LOT may be entered against ============
-- Same rule on the other side of the proc (sec 7). A team lead typing in a
-- basket the shift made has to be able to name the cavity that cast it, even if
-- that cavity has since come off the die -- and must NOT be able to name one
-- that had ALREADY come off before the shift started. Nothing here writes: each
-- case is refused by one gate or the next, and WHICH message comes back is the
-- whole assertion.
DECLARE @S2 BIGINT = test.ufn_RC(N'S2'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Reason BIGINT = (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry');
DECLARE @m NVARCHAR(500);
DECLARE @CavC BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @Tool AND CavityCode = N'c');
DECLARE @CavD BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @Tool AND CavityCode = N'd');
DECLARE @CavF BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @Tool AND CavityCode = N'f');
DECLARE @Stamp2 NVARCHAR(100) = Workorder.ufn_DieCastShiftStamp(@S2, @Cell, @Tool);

CREATE TABLE #N (Status BIT, Message NVARCHAR(500), NewId BIGINT);
-- Cavity f was deprecated three weeks BEFORE this shift, so it genuinely was not
-- on the die: it is the one case sec 7 still refuses, and the only assertion
-- that keeps the DeprecatedAt half of the predicate under test.
DECLARE @LotsF NVARCHAR(MAX) = N'[{"ltt":"99700900","toolCavityId":' + CAST(@CavF AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #N EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @LotsJson = @LotsF, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #N);
EXEC test.Assert_Contains @TestName = N'[Cav] a new LOT cannot name a cavity deprecated BEFORE the shift',
    @HaystackStr = @m, @NeedleStr = N'Choose a cavity that was on this die during';

-- Cavity d was CONFIGURED five months after this shift, and it is accepted --
-- deliberately. This assertion was the opposite way round for one day (Save 1.7)
-- and production killed it: 88 of prod's 149 cavities across 17 dies were
-- configured on 2026-09-17, the day after the shift the screen exists to
-- reconcile, so refusing on configuration date refused 17 dies outright.
-- CreatedAt records who typed what and when, never what was bolted to the die.
-- Getting PAST the cavity gate is the assertion; the missing-actual-figure gate
-- then refuses it, which is why nothing is written.
DELETE FROM #N;
DECLARE @LotsD NVARCHAR(MAX) = N'[{"ltt":"99700901","toolCavityId":' + CAST(@CavD AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #N EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @LotsJson = @LotsD, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #N);
EXEC test.Assert_Contains @TestName = N'[Cav] but a cavity CONFIGURED after the shift is one it CAN name (prod: 88 of 149 are)',
    @HaystackStr = @m, @NeedleStr = N'Enter the actual total shots';

-- cavity c was on the die then, and is deprecated now: it must get PAST that
-- gate and be refused by the missing-actual-figure gate instead.
DELETE FROM #N;
DECLARE @LotsC NVARCHAR(MAX) = N'[{"ltt":"99700902","toolCavityId":' + CAST(@CavC AS NVARCHAR(20)) + N',"quantity":10}]';
INSERT INTO #N EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId = @S2, @CellLocationId = @Cell, @ToolId = @Tool, @ReasonId = @Reason,
    @LotsJson = @LotsC, @LoadedStamp = @Stamp2, @AppUserId = @Usr;
SET @m = (SELECT Message FROM #N);
EXEC test.Assert_Contains @TestName = N'[Cav] ...but one deprecated AFTER the shift is a cavity it CAN name',
    @HaystackStr = @m, @NeedleStr = N'Enter the actual total shots';
DROP TABLE #N;

DECLARE @v NVARCHAR(400) = CAST((SELECT COUNT(*) FROM Lots.Lot WHERE LotName IN (N'99700900', N'99700901', N'99700902')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Cav] ...and none of the three refusals minted a LOT', @Expected = N'0', @Actual = @v;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
