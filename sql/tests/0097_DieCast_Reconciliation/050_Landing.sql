-- =============================================
-- File: 0097_DieCast_Reconciliation/050_Landing.sql
-- The landing list (spec sec 6.1) and the dashboard signal (sec 6.4).
-- "No entry" is neutral -- the MES cannot tell a missed entry from a press
-- that did not run. Amber is only ever a positive finding: production
-- released with no shift-end number.
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
                 DieName NVARCHAR(200), ContributionRows INT, GoodRecorded INT);
INSERT INTO #U EXEC Workorder.DieCastShift_ListUnreconciled @Days = 7, @AtMoment = @At;
SET @v = CAST((SELECT COUNT(*) FROM #U WHERE ShiftId = test.ufn_RC(N'S2')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] flags the shift with no shift-end number', @Expected = N'1', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM #U WHERE ShiftId = test.ufn_RC(N'S1')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Dashboard] does not flag a shift that has its number', @Expected = N'0', @Actual = @v;
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
                  DieName NVARCHAR(200), ContributionRows INT, GoodRecorded INT);
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

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
