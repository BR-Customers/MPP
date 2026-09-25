-- =============================================
-- File: 0097_DieCast_Reconciliation/050_Landing.sql
-- The landing list (spec sec 6.1) and the dashboard signal (sec 6.4).
-- On the LANDING list "No entry" is neutral colour -- amber there is only ever
-- a positive finding: production released with no shift-end number.
-- On the TILE both claims are reported and each carries its own StatusCode and
-- IsAlerting flag, so the screen can group or suppress either:
--   ReleasedNoShiftEnd (production, no shift-end number) IsAlerting = 1 -- the
--     finding, and the only thing that may be counted;
--   NoEntry (a die assigned across the closed shift, nothing recorded and no
--     shot total entered) IsAlerting = 0 -- IDLE, informational. A die is often
--     left assigned until the next is mounted, so this fires over weekends and
--     between runs; it must never inflate the count of real work.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/050_Landing.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700401', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700402', @CavKey = N'CavB', @StatusCode = N'Good';
GO
-- S1: a proper shift-end entry (a reading). S2: releases only, no reading.
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700401', @ShiftKey = N'S1', @Pieces = 100, @Reading = 110, @AtUtc = '2020-01-06T19:00:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700402', @ShiftKey = N'S2', @Pieces = 66,  @Reading = NULL, @AtUtc = '2020-01-07T01:00:00';
GO

DECLARE @Cell BIGINT = test.ufn_RC(N'Cell');
DECLARE @At DATETIME2(3) = '2020-01-08T12:00:00';   -- UTC "now" for the window
DECLARE @v NVARCHAR(400);

CREATE TABLE #S (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3),
                 ToolId BIGINT, AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ContributionRows INT,
                 GoodRecorded INT, RecordedTotalShots INT, StatusCode NVARCHAR(30),
                 LastReconciledBy NVARCHAR(20), LastReconciledAtEt DATETIME2(3));
INSERT INTO #S EXEC Workorder.DieCastShiftReconciliation_ListShifts @CellLocationId = @Cell, @Days = 7, @AtMoment = @At;

SET @v = (SELECT StatusCode FROM #S WHERE ShiftId = test.ufn_RC(N'S1'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] a shift with a reading reads Entry recorded', @Expected = N'EntryRecorded', @Actual = @v;
SET @v = (SELECT StatusCode FROM #S WHERE ShiftId = test.ufn_RC(N'S2'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] released with no shift-end number is the amber case', @Expected = N'ReleasedNoShiftEnd', @Actual = @v;
SET @v = (SELECT StatusCode FROM #S WHERE ShiftId = test.ufn_RC(N'S3'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] a quiet shift is neutral, not amber', @Expected = N'NoEntry', @Actual = @v;
SET @v = (SELECT CONCAT(AssetNumber, N'|', GoodRecorded, N'|', RecordedTotalShots) FROM #S WHERE ShiftId = test.ufn_RC(N'S1'));
EXEC test.Assert_IsEqual @TestName = N'[Landing] die asset number, good recorded and the reading', @Expected = N'RC-DIE|100|110', @Actual = @v;
DROP TABLE #S;

CREATE TABLE #U (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), CellLocationId BIGINT,
                 PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT, AssetNumber NVARCHAR(50),
                 DieName NVARCHAR(200), ContributionRows INT, GoodRecorded INT, StatusCode NVARCHAR(30), IsAlerting BIT);
INSERT INTO #U EXEC Workorder.DieCastShift_ListUnreconciled @Days = 7, @AtMoment = @At;
SET @v = (SELECT CONCAT(COUNT(*), N'|', MAX(CAST(IsAlerting AS INT))) FROM #U
          WHERE ShiftId = test.ufn_RC(N'S2') AND ToolId = test.ufn_RC(N'Tool') AND StatusCode = N'ReleasedNoShiftEnd');
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] flags the shift with no shift-end number', @Expected = N'1|1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM #U WHERE ShiftId = test.ufn_RC(N'S1')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] does not flag a shift that has its number', @Expected = N'0', @Actual = @v;

-- Widened scope: a die assigned across a CLOSED shift that recorded nothing is
-- reported too -- S3 is the fixture's quiet shift and the mount spans it. No
-- shot total was entered, so it is IDLE: visible, StatusCode NoEntry, and
-- IsAlerting 0 so a screen counting real work never picks it up.
SET @v = (SELECT CONCAT(StatusCode, N'|', AssetNumber, N'|', ContributionRows, N'|', CAST(IsAlerting AS INT))
          FROM #U WHERE ShiftId = test.ufn_RC(N'S3') AND ToolId = test.ufn_RC(N'Tool'));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] a die assigned across a quiet closed shift is reported idle, not as work',
     @Expected = N'NoEntry|RC-DIE|0|0', @Actual = @v;

-- ...and the two claims never merge: each shift answers under its own claim
-- only, and the alerting count is the finding alone.
SET @v = (SELECT CONCAT(
            (SELECT COUNT(*) FROM #U WHERE ToolId = test.ufn_RC(N'Tool') AND StatusCode = N'ReleasedNoShiftEnd'
                                       AND ShiftId = test.ufn_RC(N'S2')), N'/',
            (SELECT COUNT(*) FROM #U WHERE ToolId = test.ufn_RC(N'Tool') AND StatusCode = N'NoEntry'
                                       AND ShiftId = test.ufn_RC(N'S2')), N'|',
            (SELECT COUNT(*) FROM #U WHERE ToolId = test.ufn_RC(N'Tool') AND StatusCode = N'ReleasedNoShiftEnd'
                                       AND ShiftId = test.ufn_RC(N'S3')), N'/',
            (SELECT COUNT(*) FROM #U WHERE ToolId = test.ufn_RC(N'Tool') AND StatusCode = N'NoEntry'
                                       AND ShiftId = test.ufn_RC(N'S3')), N'|',
            -- S3/S4/S5 are all quiet and all idle; the alerting count stays 1.
            (SELECT COUNT(*) FROM #U WHERE ToolId = test.ufn_RC(N'Tool') AND IsAlerting = 1), N'/',
            (SELECT COUNT(*) FROM #U WHERE ToolId = test.ufn_RC(N'Tool') AND IsAlerting = 0)));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] released-with-no-number and nothing-recorded stay separable',
     @Expected = N'1/0|0/1|1/3', @Actual = @v;
DROP TABLE #U;
GO

-- A reconciliation clears both the status and the flag.
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @At DATETIME2(3) = '2020-01-08T12:00:00';
DECLARE @v NVARCHAR(400);
INSERT INTO Workorder.DieCastShiftReconciliation (ShiftId, CellLocationId, ToolId, ReasonId, DieShotCountBefore, DieShotCountAfter, AppUserId)
VALUES (test.ufn_RC(N'S2'), @Cell, test.ufn_RC(N'Tool'),
        (SELECT Id FROM Workorder.DieCastReconciliationReason WHERE Code = N'MissedEntry'), 10000, 10000, test.ufn_RC(N'Usr'));

CREATE TABLE #U2 (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), CellLocationId BIGINT,
                  PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT, AssetNumber NVARCHAR(50),
                  DieName NVARCHAR(200), ContributionRows INT, GoodRecorded INT, StatusCode NVARCHAR(30), IsAlerting BIT);
INSERT INTO #U2 EXEC Workorder.DieCastShift_ListUnreconciled @Days = 7, @AtMoment = @At;
SET @v = CAST((SELECT COUNT(*) FROM #U2 WHERE ShiftId = test.ufn_RC(N'S2')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] a reconciliation clears the flag', @Expected = N'0', @Actual = @v;
DROP TABLE #U2;

CREATE TABLE #S2 (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3),
                  ToolId BIGINT, AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ContributionRows INT,
                  GoodRecorded INT, RecordedTotalShots INT, StatusCode NVARCHAR(30),
                  LastReconciledBy NVARCHAR(20), LastReconciledAtEt DATETIME2(3));
INSERT INTO #S2 EXEC Workorder.DieCastShiftReconciliation_ListShifts @CellLocationId = @Cell, @Days = 7, @AtMoment = @At;
SET @v = (SELECT CONCAT(StatusCode, N'|', ISNULL(LastReconciledBy, N'?')) FROM #S2 WHERE ShiftId = test.ufn_RC(N'S2'));
DECLARE @Want NVARCHAR(400) = CONCAT(N'Reconciled|', (SELECT Initials FROM Location.AppUser WHERE Id = test.ufn_RC(N'Usr')));
EXEC test.Assert_IsEqual @TestName = N'[Landing] ...and the row says who reconciled it', @Expected = @Want, @Actual = @v;
DROP TABLE #S2;
GO

-- A shift whose ONLY record is basketless cavity scrap (0084: RejectEvent
-- carries its own ToolId, ItemId and CellLocationId, LotId NULL). The shift is
-- placed AFTER the fixture mount was released, so the die assignment cannot
-- put the row on the list -- the only route is RejectEvent's stamped ToolId.
-- Reaching the die through Lots.Lot would inner-join on the NULL LotId and
-- drop it silently.
DECLARE @Cell BIGINT = test.ufn_RC(N'Cell'), @Usr BIGINT = test.ufn_RC(N'Usr');
DECLARE @Sched BIGINT = (SELECT TOP 1 ShiftScheduleId FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE');
DECLARE @v NVARCHAR(400);

INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@Sched, '2020-02-05T07:00:00', '2020-02-05T15:00:00', N'RC-FIXTURE');
DECLARE @S6 BIGINT = SCOPE_IDENTITY();

INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                   DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
SELECT NULL, NULL, tc.ItemId, tc.ToolId, tc.Id, @S6, @Cell,
       (SELECT Id FROM Quality.DefectCode WHERE Code = N'999'), 12, NULL, N'fixture', @Usr, NULL, '2020-02-05T13:00:00'
FROM Tools.ToolCavity tc WHERE tc.Id = test.ufn_RC(N'CavA');

CREATE TABLE #S3 (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3),
                  ToolId BIGINT, AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ContributionRows INT,
                  GoodRecorded INT, RecordedTotalShots INT, StatusCode NVARCHAR(30),
                  LastReconciledBy NVARCHAR(20), LastReconciledAtEt DATETIME2(3));
INSERT INTO #S3 EXEC Workorder.DieCastShiftReconciliation_ListShifts
    @CellLocationId = @Cell, @Days = 7, @AtMoment = '2020-02-06T12:00:00';

SET @v = (SELECT CONCAT(COUNT(*), N'|', MAX(AssetNumber), N'|', MAX(ContributionRows))
          FROM #S3 WHERE ShiftId = @S6);
EXEC test.Assert_IsEqual @TestName = N'[Landing] a shift whose only record is basketless cavity scrap still lists its die',
     @Expected = N'1|RC-DIE|0', @Actual = @v;

-- ...and the tile does NOT claim that shift recorded nothing: scrap is a record.
CREATE TABLE #U3 (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), CellLocationId BIGINT,
                  PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT, AssetNumber NVARCHAR(50),
                  DieName NVARCHAR(200), ContributionRows INT, GoodRecorded INT, StatusCode NVARCHAR(30), IsAlerting BIT);
INSERT INTO #U3 EXEC Workorder.DieCastShift_ListUnreconciled @Days = 7, @AtMoment = '2020-02-06T12:00:00';
SET @v = CAST((SELECT COUNT(*) FROM #U3 WHERE ShiftId = @S6) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] a shift with cavity scrap is not claimed to have recorded nothing',
     @Expected = N'0', @Actual = @v;
DROP TABLE #S3;
DROP TABLE #U3;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
