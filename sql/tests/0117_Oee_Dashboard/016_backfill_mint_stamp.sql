-- =============================================
-- File:         0117_Oee_Dashboard/016_backfill_mint_stamp.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-30
-- Description:  Lots.Lot_BackfillMintStamp (OEE dashboard spec v0.3.1 sec 7.5):
--               stamps ShiftId + MintedPieceCount on LOTs minted before
--               migration 0117. Candidates are LOTs a MINT produced: the child of
--               a Consumption edge whose source is a different part (BOM / Machining
--               OUT mint) or a Received-origin LOT of the same part (pass-through).
--               A rework child (Consumption from a same-part Manufactured LOT),
--               a split child and a merge output are not candidates. Minted
--               quantity comes from the LotCreated birth audit, else is rebuilt
--               as current PieceCount + scrap + pieces split / moved out; a LOT
--               that was merged away is reported NotReconstructable and left alone.
--               LOTs are built directly so each case is explicit.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0117_Oee_Dashboard/016_backfill_mint_stamp.sql';
GO

-- ---- reset ----
DELETE FROM Lots.LotEventLog  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%');
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%')
                                 OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%';
DELETE FROM Quality.DefectCode WHERE Code = N'ZZ-BF-DEF';
DELETE FROM Parts.Item WHERE PartNumber IN (N'ZZ-BF-CAST', N'ZZ-BF-FG');
DELETE FROM Oee.Shift WHERE Remarks = N'TEST_BF';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_BF_A';
GO

-- ---- fixture ----
EXEC test.OeeDashFixture_Build;
GO
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'TEST_BF_A', N'BF 07:01-15:01', '07:01:00', '15:01:00', 127, '2020-01-01', 1);
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (SCOPE_IDENTITY(), '2030-02-05T07:01:00', '2030-02-05T15:01:00', N'TEST_BF');

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt, ChargeToPartyId)
SELECT N'ZZ-BF-DEF', N'BF test defect', NULL, 0, SYSUTCDATETIME(), p.Id FROM Quality.ChargeToParty p WHERE p.Code = N'MachineShop';

INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'Component'),    N'ZZ-BF-CAST', N'BF casting', 1, SYSUTCDATETIME(), 1),
       ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'ZZ-BF-FG',   N'BF finished good', 1, SYSUTCDATETIME(), 1);
GO

DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-BF-CAST');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'ZZ-BF-FG');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Rcv  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-P');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'ZZ-DSH-MA-L-T1');
-- 10:00 LOCAL on 2030-02-05 (inside TEST_BF_A), and a 2029 instant no shift covers.
DECLARE @At   DATETIME2(3) = CAST(CAST('2030-02-05T10:00:00' AS DATETIME2(3)) AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @Old  DATETIME2(3) = '2029-06-01T12:00:00';

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId)
VALUES (N'ZZ-BF-CAST',  @Cast, @Mfg, @Good, 100, 100, @Line, 1, @At,  @Term),  -- consumed source
       (N'ZZ-BF-RCV',   @Fg,   @Rcv, @Good,  50,  50, @Line, 1, @At,  @Term),  -- received finished
       (N'ZZ-BF-M1',    @Fg,   @Mfg, @Good,   8,   8, @Line, 1, @At,  @Term),  -- minted 10 (audit), 2 scrapped later
       (N'ZZ-BF-M2',    @Fg,   @Mfg, @Good,   6,   6, @Line, 1, @At,  @Term),  -- minted 10 (no audit): 6 + 1 scrap + 3 split out
       (N'ZZ-BF-M2-01', @Fg,   @Mfg, @Good,   3,   3, @Line, 1, @At,  @Term),  -- split child of M2
       (N'ZZ-BF-PT',    @Fg,   @Mfg, @Good,  24,  24, @Line, 1, @At,  @Term),  -- pass-through mint from RCV
       (N'ZZ-BF-RW',    @Fg,   @Mfg, @Good,   2,   2, @Line, 1, @At,  @Term),  -- rework child (Consumption from M1)
       (N'ZZ-BF-MG',    @Fg,   @Mfg, @Good,   0,   0, @Line, 1, @At,  @Term),  -- minted, then merged away
       (N'ZZ-BF-NS',    @Fg,   @Mfg, @Good,   5,   5, @Line, 1, @Old, @Term);  -- minted when no shift covers

DECLARE @L TABLE (Name NVARCHAR(50) PRIMARY KEY, Id BIGINT);
INSERT INTO @L SELECT LotName, Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%';
DECLARE @CastL BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-CAST'), @RcvL BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-RCV'),
        @M1 BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-M1'),  @M2 BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-M2'),
        @M201 BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-M2-01'), @Pt BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-PT'),
        @Rw BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-RW'),  @Mg BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-MG'),
        @Ns BIGINT = (SELECT Id FROM @L WHERE Name = N'ZZ-BF-NS');

-- genealogy: 3 = Consumption, 1 = Split, 2 = Merge
INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId)
VALUES (@CastL, @M1,   3, 10, 1, @Term),
       (@CastL, @M2,   3, 10, 1, @Term),
       (@M2,    @M201, 1,  3, 1, @Term),
       (@RcvL,  @Pt,   3, 24, 1, @Term),
       (@M1,    @Rw,   3,  2, 1, @Term),
       (@CastL, @Mg,   3,  7, 1, @Term),
       (@Mg,    @M201, 2,  7, 1, @Term),
       (@CastL, @Ns,   3,  5, 1, @Term);

-- birth audits (what Assembly_CompleteTray writes): M1 born 10, PT born 24
DECLARE @nv NVARCHAR(MAX) = N'{"Id":' + CAST(@M1 AS NVARCHAR(20)) + N',"LotName":"ZZ-BF-M1","PieceCount":10}';
EXEC Audit.Audit_LogOperation @AppUserId = 1, @TerminalLocationId = @Term, @LocationId = @Line,
    @LogEntityTypeCode = N'Lot', @EntityId = @M1, @LogEventTypeCode = N'LotCreated',
    @LogSeverityCode = N'Info', @Description = N'ZZ-BF-M1 minted', @OldValue = NULL, @NewValue = @nv;
SET @nv = N'{"Id":' + CAST(@Pt AS NVARCHAR(20)) + N',"LotName":"ZZ-BF-PT","PieceCount":24}';
EXEC Audit.Audit_LogOperation @AppUserId = 1, @TerminalLocationId = @Term, @LocationId = @Line,
    @LogEntityTypeCode = N'Lot', @EntityId = @Pt, @LogEventTypeCode = N'LotCreated',
    @LogSeverityCode = N'Info', @Description = N'ZZ-BF-PT minted', @OldValue = NULL, @NewValue = @nv;

-- later scrap: M1 2 pcs, M2 1 pc
DECLARE @Def BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'ZZ-BF-DEF');
INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, CellLocationId, Remarks)
VALUES (@M1, @Def, 2, 1, @At, @Fg, @Line, N'ZZ-BF'),
       (@M2, @Def, 1, 1, @At, @Fg, @Line, N'ZZ-BF');
GO

-- =============================================
-- Rehearsal: @Commit = 0 reports, writes nothing
-- =============================================
CREATE TABLE #B (LotId BIGINT, LotName NVARCHAR(50), ShiftId BIGINT, MintedPieceCount INT, Outcome NVARCHAR(30));
INSERT INTO #B EXEC Lots.Lot_BackfillMintStamp @Commit = 0, @AppUserId = 1;

DECLARE @ShiftExp NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM Oee.Shift WHERE Remarks = N'TEST_BF');
DECLARE @v NVARCHAR(200);
DECLARE @e10s NVARCHAR(60) = N'Stamped/' + @ShiftExp + N'/10';

SET @v = (SELECT Outcome + N'/' + ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') + N'/' + ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM #B WHERE LotName = N'ZZ-BF-M1');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] @Commit=0 reports minted FG Stamped with shift + minted qty incl. later scrap',
    @Expected = @e10s, @Actual = @v;
SET @v = (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-M1');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] @Commit=0 leaves ShiftId NULL', @Expected = N'NULL', @Actual = @v;
DROP TABLE #B;
GO

-- =============================================
-- Commit
-- =============================================
CREATE TABLE #B (LotId BIGINT, LotName NVARCHAR(50), ShiftId BIGINT, MintedPieceCount INT, Outcome NVARCHAR(30));
INSERT INTO #B EXEC Lots.Lot_BackfillMintStamp @Commit = 1, @AppUserId = 1;

DECLARE @ShiftExp NVARCHAR(20) = (SELECT CAST(Id AS NVARCHAR(20)) FROM Oee.Shift WHERE Remarks = N'TEST_BF');
DECLARE @v NVARCHAR(200);
DECLARE @e10 NVARCHAR(60) = @ShiftExp + N'/10', @e24 NVARCHAR(60) = @ShiftExp + N'/24';

SET @v = (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') + N'/' + ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-M1');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] minted FG gets shift + minted qty incl. later scrap (audit)', @Expected = @e10, @Actual = @v;

SET @v = (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') + N'/' + ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-M2');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] no birth audit -> rebuilt as current + scrap + split out', @Expected = @e10, @Actual = @v;

SET @v = (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') + N'/' + ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-PT');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] pass-through mint stamped', @Expected = @e24, @Actual = @v;

SET @v = (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') + N'/' + ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-M2-01');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] split child untouched', @Expected = N'NULL/NULL', @Actual = @v;

SET @v = (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') + N'/' + ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-RW');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] rework child (same-part Manufactured source) untouched', @Expected = N'NULL/NULL', @Actual = @v;

SET @v = (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') + N'/' + ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-RCV');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] received FG untouched', @Expected = N'NULL/NULL', @Actual = @v;

SET @v = (SELECT Outcome FROM #B WHERE LotName = N'ZZ-BF-MG') + N'/'
       + (SELECT ISNULL(CAST(MintedPieceCount AS NVARCHAR(10)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-MG');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] merged-away LOT -> NotReconstructable, untouched', @Expected = N'NotReconstructable/NULL', @Actual = @v;

SET @v = (SELECT Outcome FROM #B WHERE LotName = N'ZZ-BF-NS') + N'/'
       + (SELECT ISNULL(CAST(ShiftId AS NVARCHAR(20)), N'NULL') FROM Lots.Lot WHERE LotName = N'ZZ-BF-NS');
EXEC test.Assert_IsEqual @TestName = N'[Backfill] no covering shift -> NoShift, untouched', @Expected = N'NoShift/NULL', @Actual = @v;

DECLARE @n INT = (SELECT COUNT(*) FROM #B WHERE LotName IN (N'ZZ-BF-M2-01', N'ZZ-BF-RW', N'ZZ-BF-RCV', N'ZZ-BF-CAST'));
EXEC test.Assert_RowCount @TestName = N'[Backfill] non-candidates are not even reported', @ExpectedCount = 0, @ActualCount = @n;
DROP TABLE #B;
GO

-- =============================================
-- Second run stamps nothing
-- =============================================
CREATE TABLE #B (LotId BIGINT, LotName NVARCHAR(50), ShiftId BIGINT, MintedPieceCount INT, Outcome NVARCHAR(30));
INSERT INTO #B EXEC Lots.Lot_BackfillMintStamp @Commit = 1, @AppUserId = 1;
DECLARE @n INT = (SELECT COUNT(*) FROM #B WHERE Outcome = N'Stamped' AND LotName LIKE N'ZZ-BF-%');
EXEC test.Assert_RowCount @TestName = N'[Backfill] second run stamps nothing', @ExpectedCount = 0, @ActualCount = @n;
DROP TABLE #B;
GO

-- ---- cleanup ----
DELETE FROM Lots.LotEventLog  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%');
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%')
                                 OR ParentLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'ZZ-BF-%';
DELETE FROM Quality.DefectCode WHERE Code = N'ZZ-BF-DEF';
DELETE FROM Parts.Item WHERE PartNumber IN (N'ZZ-BF-CAST', N'ZZ-BF-FG');
DELETE FROM Oee.Shift WHERE Remarks = N'TEST_BF';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'TEST_BF_A';
EXEC test.OeeDashFixture_Teardown;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
