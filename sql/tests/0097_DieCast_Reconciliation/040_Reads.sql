-- =============================================
-- File: 0097_DieCast_Reconciliation/040_Reads.sql
-- The reads behind the reconciliation screen (spec sec 6.2, amendment A6).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0097_DieCast_Reconciliation/040_Reads.sql';
GO
EXEC test.DieCastRecon_Setup;
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700301', @CavKey = N'CavA', @StatusCode = N'Good';
EXEC test.DieCastRecon_SeedLot @Ltt = N'99700302', @CavKey = N'CavB', @StatusCode = N'Good';
GO
-- One entry: two credits and two warm-up rows by the same user, seconds apart,
-- all filed under S4 but entered during S4's morning (08:35 ET = 13:35 UTC).
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700301', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:00';
EXEC test.DieCastRecon_SeedCredit @Ltt = N'99700302', @ShiftKey = N'S4', @Pieces = 953, @Reading = 991, @AtUtc = '2020-01-07T13:35:02';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:03';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavB', @DefectCode = N'999', @Qty = 35, @AtUtc = '2020-01-07T13:35:03';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavA', @DefectCode = N'008', @Qty = 3,  @AtUtc = '2020-01-07T13:35:04';
EXEC test.DieCastRecon_SeedReject @ShiftKey = N'S4', @CavKey = N'CavB', @DefectCode = N'008', @Qty = 3,  @AtUtc = '2020-01-07T13:35:04';
GO

DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- ---- GetHeader ----
CREATE TABLE #H (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3), IsOpen BIT,
                 CellLocationId BIGINT, PressCode NVARCHAR(50), PressName NVARCHAR(200), ToolId BIGINT,
                 AssetNumber NVARCHAR(50), DieName NVARCHAR(200), ActiveCavities INT, DieShotCount INT,
                 RecordedTotalShots INT, RecordedWarmUpShots INT, RecordedNoGood INT, RecordedGood INT,
                 HasShiftEndNumber BIT, Stamp NVARCHAR(100), LastReconciledAtEt DATETIME2(3), LastReconciledBy NVARCHAR(20));
INSERT INTO #H EXEC Workorder.DieCastShiftReconciliation_GetHeader @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = (SELECT CONCAT(ActiveCavities, N'|', DieShotCount, N'|', RecordedTotalShots, N'|', RecordedWarmUpShots, N'|', RecordedNoGood, N'|', RecordedGood, N'|', HasShiftEndNumber) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[Header] cavities, die life and what is on record', @Expected = N'2|10000|991|35|6|1906|1', @Actual = @v;
SET @v = (SELECT AssetNumber + N' / ' + DieName FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[Header] the die by asset number and name', @Expected = N'RC-DIE / Reconciliation Test Die', @Actual = @v;
SET @v = (SELECT CONVERT(NVARCHAR(19), StartEt, 126) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[Header] shift window is Eastern, as stored', @Expected = N'2020-01-07T07:00:00', @Actual = @v;
DROP TABLE #H;

-- ---- ListEntries ----
CREATE TABLE #E (EntryKey NVARCHAR(100), EnteredAtEt DATETIME2(3), EnteredBy NVARCHAR(20), ReconciliationId BIGINT,
                 EnteredDuringShiftId BIGINT, EnteredDuringShift NVARCHAR(120), Reading INT, Pieces INT, Lots INT,
                 WarmUpPieces INT, OtherScrapPieces INT, [RowCount] INT, ContributionIds NVARCHAR(MAX), RejectIds NVARCHAR(MAX));
INSERT INTO #E EXEC Workorder.DieCastShiftReconciliation_ListEntries @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #E) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Entries] six rows seconds apart are ONE entry', @Expected = N'1', @Actual = @v;
SET @v = (SELECT CONCAT(Reading, N'|', Pieces, N'|', Lots, N'|', WarmUpPieces, N'|', OtherScrapPieces, N'|', [RowCount]) FROM #E);
EXEC test.Assert_IsEqual @TestName = N'[Entries] its reading, pieces, LOTs, warm-up, scrap and row count', @Expected = N'991|1906|2|70|6|6', @Actual = @v;
SET @v = (SELECT CONVERT(NVARCHAR(19), EnteredAtEt, 126) FROM #E);
EXEC test.Assert_IsEqual @TestName = N'[Entries] entered-at is Eastern', @Expected = N'2020-01-07T08:35:00', @Actual = @v;
SET @v = CAST((SELECT EnteredDuringShiftId FROM #E) AS NVARCHAR(400));
SET @Want = CAST(@S4 AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Entries] entered-during resolves from the clock', @Expected = @Want, @Actual = @v;
SET @v = CAST((SELECT LEN(ContributionIds) - LEN(REPLACE(ContributionIds, N',', N'')) + 1 FROM #E) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Entries] carries both contribution ids for the move', @Expected = N'2', @Actual = @v;
DROP TABLE #E;
GO

DECLARE @S4 BIGINT = test.ufn_RC(N'S4'), @Cell BIGINT = test.ufn_RC(N'Cell'), @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @v NVARCHAR(400), @Want NVARCHAR(400);

-- ---- ListLots ----
CREATE TABLE #L (LotId BIGINT, Ltt NVARCHAR(50), ItemId BIGINT, PartNumber NVARCHAR(50), PartDescription NVARCHAR(200),
                 ToolCavityId BIGINT, CavityCode NVARCHAR(10), Recorded INT, PieceCount INT, InventoryAvailable INT,
                 StatusCode NVARCHAR(20), StatusName NVARCHAR(100), NowAt NVARCHAR(200), ReleasedAtEt DATETIME2(3),
                 IsLocked BIT, LockReason NVARCHAR(200));
INSERT INTO #L EXEC Workorder.DieCastShiftReconciliation_ListLots @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #L) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Lots] both LOTs credited in the shift', @Expected = N'2', @Actual = @v;
SET @v = (SELECT CONCAT(Recorded, N'|', PieceCount, N'|', StatusCode, N'|', IsLocked) FROM #L WHERE Ltt = N'99700301');
EXEC test.Assert_IsEqual @TestName = N'[Lots] recorded in THIS shift, plus the LOT''s own count and lock', @Expected = N'953|953|Good|0', @Actual = @v;
DROP TABLE #L;

-- ---- ListRejects ----
CREATE TABLE #R (DefectCodeId BIGINT, DefectCode NVARCHAR(20), Defect NVARCHAR(200), IsNonRejectScrap BIT,
                 ItemId BIGINT, PartNumber NVARCHAR(50), Quantity INT, Cavities INT, ApprovedBy NVARCHAR(20));
INSERT INTO #R EXEC Workorder.DieCastShiftReconciliation_ListRejects @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #R WHERE DefectCode = N'999') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Rejects] warm-up is not a reject line', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT SUM(Quantity) FROM #R WHERE DefectCode = N'008') AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Rejects] the test parts, per part', @Expected = N'6', @Actual = @v;
DROP TABLE #R;

-- ---- ListMoveTargets ----
-- The fixture stops at S5, so S4 has no shift two AHEAD of it. One more
-- RC-FIXTURE shift the day after gives the radius a target on both sides;
-- test.DieCastRecon_Cleanup removes it with the rest (Remarks = 'RC-FIXTURE').
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT s.ShiftScheduleId, '2020-01-08T07:00:00', '2020-01-08T15:00:00', N'RC-FIXTURE'
FROM Oee.Shift s WHERE s.Id = test.ufn_RC(N'S5');
DECLARE @S6 BIGINT = (SELECT Id FROM Oee.Shift WHERE Remarks = N'RC-FIXTURE' AND ActualStart = '2020-01-08T07:00:00');

CREATE TABLE #M (ShiftId BIGINT, ShiftLabel NVARCHAR(120), StartEt DATETIME2(3), EndEt DATETIME2(3), Offset INT, GoodRecorded INT);
INSERT INTO #M EXEC Workorder.DieCastShiftReconciliation_ListMoveTargets @ShiftId = @S4, @CellLocationId = @Cell, @ToolId = @Tool;
SET @v = CAST((SELECT COUNT(*) FROM #M WHERE ShiftId IN (test.ufn_RC(N'S2'), test.ufn_RC(N'S3'), test.ufn_RC(N'S5'), @S6)) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Targets] four shifts within two of S4', @Expected = N'4', @Actual = @v;
SET @v = CAST((SELECT COUNT(*) FROM #M WHERE ShiftId = test.ufn_RC(N'S1')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Targets] a shift three away is not offered', @Expected = N'0', @Actual = @v;
SET @v = CAST((SELECT GoodRecorded FROM #M WHERE ShiftId = test.ufn_RC(N'S3')) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Targets] each target shows what it already holds', @Expected = N'0', @Actual = @v;
DROP TABLE #M;

-- ---- Reason_List ----
CREATE TABLE #Rs (Id BIGINT, Code NVARCHAR(50), Name NVARCHAR(100), RequiresNote BIT);
INSERT INTO #Rs EXEC Workorder.DieCastReconciliationReason_List;
SET @v = CAST((SELECT COUNT(*) FROM #Rs) AS NVARCHAR(400));
EXEC test.Assert_IsEqual @TestName = N'[Reasons] four, in order', @Expected = N'4', @Actual = @v;
DROP TABLE #Rs;
GO

-- ---- ResolveLtt ----
DECLARE @Tool BIGINT = test.ufn_RC(N'Tool');
DECLARE @v NVARCHAR(400);
CREATE TABLE #X (Ltt NVARCHAR(50), Result NVARCHAR(20), LotId BIGINT, ToolCavityId BIGINT, CavityCode NVARCHAR(10),
                 ItemId BIGINT, PartNumber NVARCHAR(50), PieceCount INT, Message NVARCHAR(400));
INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'99700999', @ToolId = @Tool;
SET @v = (SELECT Result FROM #X);
EXEC test.Assert_IsEqual @TestName = N'[Ltt] an unused, valid LTT is New', @Expected = N'New', @Actual = @v;
DELETE FROM #X;
INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'12345', @ToolId = @Tool;
SET @v = (SELECT Result FROM #X);
EXEC test.Assert_IsEqual @TestName = N'[Ltt] five digits is not an LTT', @Expected = N'Invalid', @Actual = @v;
DELETE FROM #X;
INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'99700301', @ToolId = @Tool;
SET @v = (SELECT CONCAT(Result, N'|', CavityCode) FROM #X);
EXEC test.Assert_IsEqual @TestName = N'[Ltt] a LOT on this die resolves to its cavity', @Expected = N'OnThisDie|a', @Actual = @v;
DELETE FROM #X;
-- Any die that is not this one. The reset database carries no tool other than
-- the fixture's, and creating one would outlive DieCastRecon_Cleanup (it drops
-- RC-DIE only), so an id that is no die at all stands in: this read compares
-- @ToolId to the LOT's and never joins it.
DECLARE @Other BIGINT = ISNULL((SELECT TOP 1 Id FROM Tools.Tool WHERE Code <> N'RC-DIE' ORDER BY Id), -1);
INSERT INTO #X EXEC Lots.DieCastLot_ResolveLtt @Ltt = N'99700301', @ToolId = @Other;
SET @v = (SELECT Result FROM #X);
EXEC test.Assert_IsEqual @TestName = N'[Ltt] a LOT from another die is refused', @Expected = N'Elsewhere', @Actual = @v;
SET @v = (SELECT Message FROM #X);
EXEC test.Assert_Contains @TestName = N'[Ltt] ...naming where it belongs', @HaystackStr = @v, @NeedleStr = N'Asset # RC-DIE';
DROP TABLE #X;
GO

EXEC test.DieCastRecon_Cleanup;
GO
EXEC test.EndTestFile;
GO
