SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/090_ReleasePreview.sql';
GO

-- =============================================
-- RELEASE-SIDE READS (2026-09-10).
--
-- Two reads that the Lot Release screen depends on, and one behaviour the
-- screen had wrong for a month:
--
--   Workorder.DieCast_GetReleasePreview -- the arithmetic the Release dialog
--     shows BEFORE the operator commits. Lots.DieCastLot_Release already
--     derived the closing piece delta from a press-counter reading, but the
--     screen never asked for a reading, so closing a basket mid-shift lost
--     that cavity's shots since the last entry unless the operator happened
--     to run Record Shift Output first. The preview and the write have to
--     agree exactly or the dialog lies.
--
--   Lots.Lot_GetOpenByTool v2.0 -- CAVITY-DRIVEN. v1.0 selected FROM Lots.Lot,
--     so a cavity with no open basket produced no row and an out-of-service
--     cavity was simply absent from the screen.
--
-- FIXTURES ARE SELF-CONTAINED (see 080 for why: sibling suites in this folder
-- abort on seed data a -SkipDemoSeed build does not have).
-- =============================================

-- ---- cleanup (reverse FK order) ----
DECLARE @Rp TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Rp (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RPV-%';

DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Rp)
                                        OR DescendantLotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Rp)
                                 OR ChildLotId  IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @Rp) OR ParentLotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Rp);
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DELETE FROM Tools.Tool WHERE Code = N'RPV-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'RPV-FIXTURE-SCHED';
DELETE FROM Quality.DefectCode WHERE Code = N'RPV-DEF';
GO

-- ---- fixture ----
-- Jacques's walkthrough, verbatim: 12 cavities is the real die, three is
-- enough to prove it. Cavities A and B are settled at reading 100; the
-- operator now wants to close A alone with the counter showing 200.
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @DieTypeId  BIGINT = (SELECT Id FROM Tools.ToolType            WHERE Code = N'Die');
DECLARE @ActiveTool BIGINT = (SELECT Id FROM Tools.ToolStatusCode      WHERE Code = N'Active');
DECLARE @ActiveCav  BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @ClosedCav  BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Closed');
DECLARE @CavItemId  BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);

-- Quality.DefectCode is empty in dev/test (the FRS 153-defect load is
-- cutover-only, see 020); Test 6 needs one to hang release scrap on.
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt)
VALUES (N'RPV-DEF', N'Release preview scrap defect', NULL, 0, @Now);

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId)
VALUES (@DieTypeId, N'RPV-DIE', N'Release preview die', @ActiveTool, 0, @Now, 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

-- Cav C is CLOSED and holds no basket: the row that did not exist before v2.0.
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, N'a', @ActiveCav, N'Intake 2-A', @CavItemId, @Now, 1),
       (@ToolId, N'b', @ActiveCav, N'Intake 2-B', @CavItemId, @Now, 1),
       (@ToolId, N'c', @ClosedCav, N'Exhaust 5 Ab', @CavItemId, @Now, 1);

DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ItemId  BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType   WHERE Code = N'Manufactured');
DECLARE @OpenId   BIGINT = (SELECT Id FROM Lots.LotStatusCode   WHERE Code = N'Open');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');

-- MaxPieceCount 200 so the under-fill advisory has something to test against.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                      InventoryAvailable, CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'RPV-A1', @ItemId, @OriginId, @OpenId, 0, 200, 0, @PressA, @ToolId, @CavA, @Now, 1),
       (N'RPV-B1', @ItemId, @OriginId, @OpenId, 0, 200, 0, @PressA, @ToolId, @CavB, @Now, 1);

IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSchedule WHERE Name = N'RPV-FIXTURE-SCHED')
    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'RPV-FIXTURE-SCHED', '07:00:00', '15:00:00', 127, CAST(@Now AS DATE), 1);
DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'RPV-FIXTURE-SCHED');
-- CLOSED: UIX_Shift_SingleOpen makes a leaked open shift everyone else's
-- problem (Msg 2601 in every later suite that opens one).
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@SchedId, DATEADD(HOUR, -4, @Now), DATEADD(MINUTE, -5, @Now), N'RPV-FIXTURE');
GO

-- Settle both cavities at reading 100 -- "100 parts registered against the
-- other cavities already".
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-A1');
DECLARE @LotB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-B1');

DECLARE @Lines NVARCHAR(MAX) =
    N'[{"lotId":' + CAST(@LotA AS NVARCHAR(20)) + N',"pieceDelta":100},'
    + N'{"lotId":' + CAST(@LotB AS NVARCHAR(20)) + N',"pieceDelta":100}]';
DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Lines,
    @ShotLossJson = NULL, @AppUserId = 1, @TerminalLocationId = NULL,
    @CounterReading = 100, @CellLocationId = @PressA;
DECLARE @ws NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W);
EXEC test.Assert_IsEqual @TestName = N'[Fixture] both cavities settled at reading 100',
    @Expected = N'1', @Actual = @ws;
GO

-- =============================================
-- Test 1: the preview does the subtraction. Counter shows 200, cavity A is
--         credited through 100 -> this release adds 100 on top of the 100
--         already on the basket, closing it at 200. That subtraction is the
--         number the operator must never have to work out themselves.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-A1');

DECLARE @P TABLE (LotId BIGINT, LotName NVARCHAR(50), ToolCavityId BIGINT, CavityCode NVARCHAR(4),
                  CavityDescription NVARCHAR(500), ItemId BIGINT, PartNumber NVARCHAR(100),
                  PieceCount INT, MaxPieceCount INT, CreditedThrough INT, DieCreditedThrough INT,
                  NewShots INT, ProjectedPieceCount INT, BelowStandardAfter BIT,
                  ReadingState NVARCHAR(20), ToolId BIGINT);
INSERT INTO @P EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = 200;

DECLARE @v NVARCHAR(20) = (SELECT CAST(CreditedThrough AS NVARCHAR(20)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] CreditedThrough 100', @Expected = N'100', @Actual = @v;
SET @v = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] reading 200 - watermark 100 = 100 new',
    @Expected = N'100', @Actual = @v;
-- 100 already on the basket from the shift-output entry, plus the 100 this
-- release credits. The operator sees both halves and adds neither.
SET @v = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] on the basket now 100', @Expected = N'100', @Actual = @v;
SET @v = (SELECT CAST(ProjectedPieceCount AS NVARCHAR(20)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] basket closes at 200', @Expected = N'200', @Actual = @v;
SET @v = (SELECT ReadingState FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] ReadingState Ok', @Expected = N'Ok', @Actual = @v;
-- BelowStandardAfter is judged on the PROJECTED count, not the current one:
-- a basket that looks half empty before the release is full after it, and
-- warning on the stale number is how the old dialog cried wolf.
SET @v = (SELECT CAST(BelowStandardAfter AS NVARCHAR(10)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] 200 of 200 -> not under standard fill',
    @Expected = N'0', @Actual = @v;

DELETE FROM @P;
INSERT INTO @P EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = 150;
SET @v = (SELECT CAST(ProjectedPieceCount AS NVARCHAR(20)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] reading 150 -> closes at 150', @Expected = N'150', @Actual = @v;
SET @v = (SELECT CAST(BelowStandardAfter AS NVARCHAR(10)) FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] 150 of 200 (75%) -> under standard fill',
    @Expected = N'1', @Actual = @v;

DELETE FROM @P;
INSERT INTO @P EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = 200;
SET @v = (SELECT CavityDescription FROM @P);
EXEC test.Assert_IsEqual @TestName = N'[Preview] carries the cavity NAME, not just its ordinal',
    @Expected = N'Intake 2-A', @Actual = @v;
GO

-- =============================================
-- Test 2: no reading typed yet -> ReadingState None and NOTHING credited, so
--         the dialog opens with honest zeros rather than a guess.
-- =============================================
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-A1');
DECLARE @P2 TABLE (LotId BIGINT, LotName NVARCHAR(50), ToolCavityId BIGINT, CavityCode NVARCHAR(4),
                   CavityDescription NVARCHAR(500), ItemId BIGINT, PartNumber NVARCHAR(100),
                   PieceCount INT, MaxPieceCount INT, CreditedThrough INT, DieCreditedThrough INT,
                   NewShots INT, ProjectedPieceCount INT, BelowStandardAfter BIT,
                   ReadingState NVARCHAR(20), ToolId BIGINT);
INSERT INTO @P2 EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = NULL;
DECLARE @v2 NVARCHAR(20) = (SELECT ReadingState FROM @P2);
EXEC test.Assert_IsEqual @TestName = N'[Preview] no reading -> ReadingState None',
    @Expected = N'None', @Actual = @v2;
SET @v2 = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM @P2);
EXEC test.Assert_IsEqual @TestName = N'[Preview] no reading -> credits nothing',
    @Expected = N'0', @Actual = @v2;

-- a reading BEHIND the die watermark is the typo case the dialog must catch
-- before the press, not after -- same rejection Release itself raises
DELETE FROM @P2;
INSERT INTO @P2 EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = 90;
SET @v2 = (SELECT ReadingState FROM @P2);
EXEC test.Assert_IsEqual @TestName = N'[Preview] reading behind the die watermark -> Behind',
    @Expected = N'Behind', @Actual = @v2;
SET @v2 = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM @P2);
EXEC test.Assert_IsEqual @TestName = N'[Preview] a Behind reading credits nothing',
    @Expected = N'0', @Actual = @v2;
GO

-- =============================================
-- Test 3: the preview and the WRITE agree. Release at the previewed reading
--         and the basket must close at exactly the projected count -- a
--         dialog that quotes a number the write does not use is worse than no
--         dialog at all.
-- =============================================
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-A1');
DECLARE @LotB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-B1');
DECLARE @Whse BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);
IF @Whse IS NULL SET @Whse = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Lots.DieCastLot_Release
    @LotId = @LotA, @StorageLocationId = @Whse, @FinalPieceDelta = NULL,
    @CounterReading = 200, @ScrapLinesJson = NULL, @ShiftId = @ShiftId,
    @AppUserId = 1, @TerminalLocationId = NULL, @CellLocationId = @PressA;
DECLARE @rs NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R);
EXEC test.Assert_IsEqual @TestName = N'[Write] release at the previewed reading succeeds',
    @Expected = N'1', @Actual = @rs;

DECLARE @pc NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[Write] basket closed at the projected 200 pc',
    @Expected = N'200', @Actual = @pc;

-- Cavity A is now settled at 200; B is still at 100. That difference is the
-- whole point -- at shift end B gets credited from 100 and A's SUCCESSOR from
-- 200, so nothing is counted twice and nothing is lost.
DECLARE @CavA BIGINT = (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @LotA);
DECLARE @CavB BIGINT = (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @LotB);
DECLARE @wa NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Write] released cavity now credited through 200',
    @Expected = N'200', @Actual = @wa;
DECLARE @wb NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual N'[Write] its neighbour is untouched at 100', N'100', @wb;
GO

-- =============================================
-- Test 4: Lot_GetOpenByTool v2.0 lists EVERY cavity. Cavity A has just been
--         released and cavity C is Closed -- both used to vanish, which is
--         what made the screen look like it was hiding things.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DECLARE @OB TABLE (ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50),
                   PieceCount INT, MaxPieceCount INT, BelowStandardRelease BIT, OpenedAt DATETIME2(3),
                   ContributorCount INT, CavityDescription NVARCHAR(500), CavityStatusCode NVARCHAR(50),
                   ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(100));
INSERT INTO @OB EXEC Lots.Lot_GetOpenByTool @ToolId = @ToolId;

DECLARE @n NVARCHAR(20) = CAST((SELECT COUNT(*) FROM @OB) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[OpenByTool] one row per cavity, all three',
    @Expected = N'3', @Actual = @n;

DECLARE @closed NVARCHAR(50) = (SELECT CavityStatusCode FROM @OB WHERE CavityDescription = N'Exhaust 5 Ab');
EXEC test.Assert_IsEqual @TestName = N'[OpenByTool] the Closed cavity is present, and says so',
    @Expected = N'Closed', @Actual = @closed;

DECLARE @noBasket NVARCHAR(10) = CAST(
    (SELECT COUNT(*) FROM @OB WHERE LotId IS NULL) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpenByTool] released + closed cavities carry a NULL LotId',
    @Expected = N'2', @Actual = @noBasket;

DECLARE @nm NVARCHAR(500) = (SELECT CavityDescription FROM @OB WHERE LotName = N'RPV-B1');
EXEC test.Assert_IsEqual @TestName = N'[OpenByTool] carries the cavity NAME for the row title',
    @Expected = N'Intake 2-B', @Actual = @nm;

-- a basketless cavity must not fake an under-fill or a contributor
DECLARE @bs NVARCHAR(10) = CAST(
    (SELECT COUNT(*) FROM @OB WHERE LotId IS NULL AND (BelowStandardRelease = 1 OR ContributorCount <> 0))
    AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[OpenByTool] basketless rows carry no basket metrics',
    @Expected = N'0', @Actual = @bs;
GO

-- =============================================
-- Test 5: a LOT that is not an open basket returns NO ROWS -- the dialog's
--         empty shape, never an invented 404 (FDS-11-011).
-- =============================================
DECLARE @LotA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-A1');   -- released in Test 3
DECLARE @P5 TABLE (LotId BIGINT, LotName NVARCHAR(50), ToolCavityId BIGINT, CavityCode NVARCHAR(4),
                   CavityDescription NVARCHAR(500), ItemId BIGINT, PartNumber NVARCHAR(100),
                   PieceCount INT, MaxPieceCount INT, CreditedThrough INT, DieCreditedThrough INT,
                   NewShots INT, ProjectedPieceCount INT, BelowStandardAfter BIT,
                   ReadingState NVARCHAR(20), ToolId BIGINT);
INSERT INTO @P5 EXEC Workorder.DieCast_GetReleasePreview @LotId = @LotA;
DECLARE @n5 NVARCHAR(10) = CAST((SELECT COUNT(*) FROM @P5) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Preview] a closed basket returns no rows',
    @Expected = N'0', @Actual = @n5;

DELETE FROM @P5;
INSERT INTO @P5 EXEC Workorder.DieCast_GetReleasePreview @LotId = -1;
SET @n5 = CAST((SELECT COUNT(*) FROM @P5) AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Preview] an unknown LOT returns no rows',
    @Expected = N'0', @Actual = @n5;
GO

-- =============================================
-- Test 6: RELEASE SCRAP IS CAVITY-ATTRIBUTED (migration 0084, spec sec 3.3).
--
--         Die-cast scrap is a fact about (Shift, Press, Tool, Cavity, Part),
--         and that identity is STAMPED on the reject row -- never derived
--         through the LOT. This proc's CONTRIBUTION row was taught that on
--         2026-09-14 (v2.1, for ufn_CavityShotWatermark v3.0); the RejectEvent
--         insert a few lines below it was missed and kept the pre-0084 column
--         list -- no ItemId, ToolId, ToolCavityId, ShiftId or CellLocationId.
--
--         The cost is invisible at the write and total at the read:
--         DieCast_GetShiftOutputBreakdown computes PriorScrapThisShift as
--             WHERE re.ShiftId = @ShiftId AND re.ToolCavityId = tc.Id
--         so a release-scrap row carrying NULL for both is UNREACHABLE. The
--         SHIFT SCRAP column on Reconcile Shift reads 0 for scrap that was
--         genuinely recorded, and no amount of Compute or Refresh will ever
--         change it -- which is why it presents as a broken refresh rather
--         than as lost data.
--
--         Live evidence (Dev, 2026-09-15): reject 20054, lot 20265, qty 10,
--         written beside contribution 20102 (cavity 30, shift 20107). The
--         column reported 0 against an actual 10.
--
--         Quality.Reject_GetPartMatrix / _SearchDetail resolve the part from
--         re.ItemId as well, so the same row also buckets as an unmapped part
--         in plant scrap reporting.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE' ORDER BY Id DESC);
DECLARE @LotB    BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-B1');
DECLARE @CavB    BIGINT = (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @LotB);
DECLARE @ItemB   BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @LotB);
DECLARE @Whse    BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);
IF @Whse IS NULL SET @Whse = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Defect  BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'RPV-DEF');

-- Cavity B is credited through 100; close it at reading 200 with 7 scrap.
DECLARE @Scrap NVARCHAR(MAX) =
    N'[{"defectCodeId":' + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":7}]';
DECLARE @R6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R6 EXEC Lots.DieCastLot_Release
    @LotId = @LotB, @StorageLocationId = @Whse, @FinalPieceDelta = NULL,
    @CounterReading = 200, @ScrapLinesJson = @Scrap, @ShiftId = @ShiftId,
    @AppUserId = 1, @TerminalLocationId = NULL, @CellLocationId = @PressA;
DECLARE @v6 NVARCHAR(50) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R6);
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] release with a scrap line succeeds',
    @Expected = N'1', @Actual = @v6;

SET @v6 = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent
                WHERE LotId = @LotB AND DefectCodeId = @Defect) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] one reject row written',
    @Expected = N'1', @Actual = @v6;

-- The five stamps, each asserted on its own so a failure names the column that
-- was dropped rather than a bare "identity is wrong".
DECLARE @e6 NVARCHAR(50);

SET @e6 = CAST(@CavB AS NVARCHAR(50));
SET @v6 = ISNULL(CAST((SELECT ToolCavityId FROM Workorder.RejectEvent
                       WHERE LotId = @LotB AND DefectCodeId = @Defect) AS NVARCHAR(50)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] stamps ToolCavityId',
    @Expected = @e6, @Actual = @v6;

SET @e6 = CAST(@ShiftId AS NVARCHAR(50));
SET @v6 = ISNULL(CAST((SELECT ShiftId FROM Workorder.RejectEvent
                       WHERE LotId = @LotB AND DefectCodeId = @Defect) AS NVARCHAR(50)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] stamps ShiftId',
    @Expected = @e6, @Actual = @v6;

SET @e6 = CAST(@ItemB AS NVARCHAR(50));
SET @v6 = ISNULL(CAST((SELECT ItemId FROM Workorder.RejectEvent
                       WHERE LotId = @LotB AND DefectCodeId = @Defect) AS NVARCHAR(50)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] stamps ItemId (Reject_GetPartMatrix reads it)',
    @Expected = @e6, @Actual = @v6;

SET @e6 = CAST(@ToolId AS NVARCHAR(50));
SET @v6 = ISNULL(CAST((SELECT ToolId FROM Workorder.RejectEvent
                       WHERE LotId = @LotB AND DefectCodeId = @Defect) AS NVARCHAR(50)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] stamps ToolId (several dies make one part)',
    @Expected = @e6, @Actual = @v6;

SET @e6 = CAST(@PressA AS NVARCHAR(50));
SET @v6 = ISNULL(CAST((SELECT CellLocationId FROM Workorder.RejectEvent
                       WHERE LotId = @LotB AND DefectCodeId = @Defect) AS NVARCHAR(50)), N'<NULL>');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] stamps CellLocationId (the press)',
    @Expected = @e6, @Actual = @v6;
GO

-- =============================================
-- Test 7: ...and therefore the SHIFT SCRAP column on Reconcile Shift SEES it.
--         This is the assertion that guards the reported symptom -- Test 6
--         pins the columns, this one pins the read that consumes them.
-- =============================================
DECLARE @ToolId  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DECLARE @PressA  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE' ORDER BY Id DESC);
DECLARE @LotB    BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RPV-B1');
DECLARE @CavB    BIGINT = (SELECT ToolCavityId FROM Lots.Lot WHERE Id = @LotB);
DECLARE @CavA    BIGINT = (SELECT Id FROM Tools.ToolCavity
                           WHERE ToolId = @ToolId AND CavityCode = N'a');

DECLARE @B TABLE (ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50),
                  IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT,
                  ItemId BIGINT, CavityDescription NVARCHAR(500), CreditedThrough INT, NewShots INT,
                  CavityStatusCode NVARCHAR(50), ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(100),
                  PriorScrapThisShift INT, DieWideShots INT, IsPending BIT);
INSERT INTO @B EXEC Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId = @ToolId, @ShiftId = @ShiftId, @CounterReading = 200,
    @CellLocationId = @PressA, @DieWideShots = 0;

DECLARE @v7 NVARCHAR(50) = ISNULL(CAST((SELECT TOP 1 PriorScrapThisShift FROM @B
                                        WHERE ToolCavityId = @CavB) AS NVARCHAR(50)), N'<no row>');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] SHIFT SCRAP column reports the 7 released',
    @Expected = N'7', @Actual = @v7;

-- ...and does not smear it across the die. Cavity A released clean in Test 3.
SET @v7 = ISNULL(CAST((SELECT TOP 1 PriorScrapThisShift FROM @B
                       WHERE ToolCavityId = @CavA) AS NVARCHAR(50)), N'<no row>');
EXEC test.Assert_IsEqual @TestName = N'[ReleaseScrap] a clean cavity still reports 0',
    @Expected = N'0', @Actual = @v7;
GO

-- =============================================
-- TEARDOWN. Oee.Shift is GLOBAL state (see 080): a fixture shift left behind
-- changes what 0046_Shift_Reconcile computes even though everything here
-- passed.
-- =============================================
DECLARE @Rp TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Rp (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RPV-%';

DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Rp)
                                        OR DescendantLotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Rp)
                                 OR ChildLotId  IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @Rp) OR ParentLotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @Rp);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Rp);
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RPV-DIE');
DELETE FROM Tools.Tool WHERE Code = N'RPV-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'RPV-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'RPV-FIXTURE-SCHED';
DELETE FROM Quality.DefectCode WHERE Code = N'RPV-DEF';
GO

EXEC test.EndTestFile;
GO
