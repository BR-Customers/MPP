SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/080_ShotReadingChain.sql';
GO

-- =============================================
-- Die-cast SHOT-READING CHAIN (migration 0073, spec 2026-09-09).
--
-- The press counter resets each shift, so the number the operator types is a
-- READING. Every cavity carries a credited-through watermark starting at 0,
-- and a basket's credit is (reading - watermark). The reading typed at a
-- release closes the outgoing basket AND anchors the incoming one.
--
-- FIXTURES ARE SELF-CONTAINED. Three sibling suites in this folder abort with
-- Msg 515 because they hunt for seed data a -SkipDemoSeed build does not
-- contain; nothing here depends on seed content beyond code tables.
-- =============================================

-- ---- cleanup (reverse FK order) ----
-- Every FK that references Lots.Lot, cleared before the LOTs themselves.
-- Release writes LotMovement + LotStatusHistory + LotEventLog rows, so a
-- teardown that only clears contributions fails with Msg 547.
DECLARE @Src TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Src (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SRC-%';

DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Src)
                                        OR DescendantLotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Src)
                                 OR ChildLotId  IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @Src) OR ParentLotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Src);
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DELETE FROM Tools.Tool WHERE Code = N'SRC-DIE';
DELETE FROM Oee.Shift WHERE Id IN (SELECT Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'SRC-FIXTURE-SCHED';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveTool BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @ActiveCav BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId)
VALUES (@DieTypeId, N'SRC-DIE', N'Shot reading chain die', @ActiveTool, 0, @Now, 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

DECLARE @ClosedCav BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Closed');
DECLARE @CavItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);

-- Cav C is CLOSED and never gets a basket -- the case that produced no row at
-- all before v2.1, which is why an out-of-service cavity was invisible.
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, N'a', @ActiveCav, N'Cav A', NULL, @Now, 1),
       (@ToolId, N'b', @ActiveCav, N'Cav B', NULL, @Now, 1),
       (@ToolId, N'c', @ClosedCav, N'Cav C', @CavItemId, @Now, 1);

-- two presses: the second exists only to prove the watermark is press-scoped
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @PressB BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Id <> @PressA ORDER BY Id);

DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OpenId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'SRC-A1', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavA, @Now, 1),
       (N'SRC-B1', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavB, @Now, 1);

-- A -SkipDemoSeed build has NO shift schedules, so create one rather than
-- selecting from an empty table (which silently inserts zero shifts and leaves
-- every downstream @ShiftId NULL).
IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSchedule WHERE Name = N'SRC-FIXTURE-SCHED')
    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'SRC-FIXTURE-SCHED', '07:00:00', '15:00:00', 127, CAST(@Now AS DATE), 1);

DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'SRC-FIXTURE-SCHED');
-- CLOSED (ActualEnd set). Oee.Shift carries the filtered unique index
-- UIX_Shift_SingleOpen, so leaving this fixture shift open leaks a second open
-- shift into the shared test database and every later suite that opens one
-- dies with Msg 2601. A closed shift is also the realistic case here: entering
-- output against a previous shift is exactly the retroactive path operators
-- use when they cannot get to the terminal at shift change.
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@SchedId, DATEADD(HOUR, -4, @Now), DATEADD(MINUTE, -5, @Now), N'SRC-FIXTURE');
GO

-- =============================================
-- Test 1: a cavity that never rolled is credited the WHOLE reading.
--         This is the pre-change behaviour and must not regress.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);

DECLARE @Wm NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SRC] fresh cavity watermark is 0', @Expected=N'0', @Actual=@Wm;
GO

-- =============================================
-- Test 2: mid-shift release splits the shift 1450 / 550 on the rolled cavity,
--         while the untouched cavity is still credited the full 2000.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SRC-A1');

-- release basket A1 at reading 1450
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Lots.DieCastLot_Release
    @LotId = @LotA1, @CounterReading = 1450, @ShiftId = @ShiftId,
    @AppUserId = 1, @CellLocationId = @PressA;
DECLARE @S1 NVARCHAR(1) = CAST((SELECT Status FROM #R1) AS NVARCHAR(1));
DECLARE @M1 NVARCHAR(500) = (SELECT Message FROM #R1);
DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName=N'[SRC] release with a reading succeeds', @Expected=N'1', @Actual=@S1;

DECLARE @A1Pieces NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotA1);
EXEC test.Assert_IsEqual @TestName=N'[SRC] released basket credited 1450 (derived, not typed)', @Expected=N'1450', @Actual=@A1Pieces;

DECLARE @WmA NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SRC] rolled cavity watermark advanced to 1450', @Expected=N'1450', @Actual=@WmA;

DECLARE @WmB NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SRC] untouched cavity watermark still 0', @Expected=N'0', @Actual=@WmB;

-- die life advanced by the release (the changeover-ghosting fix)
DECLARE @Shots1 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ToolId);
EXEC test.Assert_IsEqual @TestName=N'[SRC] release advanced ShotCount to 1450', @Expected=N'1450', @Actual=@Shots1;
GO

-- =============================================
-- Test 3: successor basket on the rolled cavity gets only the remainder.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);
DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OpenId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'SRC-A2', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavA, SYSUTCDATETIME(), 1);

DECLARE @LotA2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SRC-A2');
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SRC-B1');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"lotId":' + CAST(@LotA2 AS NVARCHAR(20)) + N',"pieceDelta":550,"scrapLines":[]},'
  + N' {"lotId":' + CAST(@LotB1 AS NVARCHAR(20)) + N',"pieceDelta":2000,"scrapLines":[]}]';

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json,
    @AppUserId = 1, @CounterReading = 2000, @CellLocationId = @PressA;
DECLARE @S2 NVARCHAR(1) = CAST((SELECT Status FROM #R2) AS NVARCHAR(1));
DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName=N'[SRC] shift-output at reading 2000 succeeds', @Expected=N'1', @Actual=@S2;

DECLARE @A2 NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotA2);
EXEC test.Assert_IsEqual @TestName=N'[SRC] successor basket got only the remainder 550', @Expected=N'550', @Actual=@A2;

DECLARE @B1 NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotB1);
EXEC test.Assert_IsEqual @TestName=N'[SRC] untouched cavity got the full 2000', @Expected=N'2000', @Actual=@B1;

-- 1450 + 550 = 2000: the DELTA rule, not the sum of readings (which would be 3450)
DECLARE @Shots2 NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ToolId);
EXEC test.Assert_IsEqual @TestName=N'[SRC] ShotCount totals the shift once (2000, not 3450)', @Expected=N'2000', @Actual=@Shots2;
GO

-- =============================================
-- Test 4: a reading BEHIND the die watermark is rejected and writes nothing.
--         Guards a typo (200 for 2000) and an out-of-order entry.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SRC-B1');
DECLARE @Before NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotB1);
DECLARE @ShotsBefore NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ToolId);

DECLARE @BadJson NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotB1 AS NVARCHAR(20)) + N',"pieceDelta":10,"scrapLines":[]}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @BadJson,
    @AppUserId = 1, @CounterReading = 200, @CellLocationId = @PressA;
DECLARE @S3 NVARCHAR(1) = CAST((SELECT Status FROM #R3) AS NVARCHAR(1));
DECLARE @M3 NVARCHAR(500) = (SELECT Message FROM #R3);
DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName=N'[SRC] backwards reading rejected', @Expected=N'0', @Actual=@S3;
EXEC test.Assert_Contains @TestName=N'[SRC] rejection names the last recorded reading', @HaystackStr=@M3, @NeedleStr=N'2000';

DECLARE @After NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotB1);
EXEC test.Assert_IsEqual @TestName=N'[SRC] rejected entry wrote no pieces', @Expected=@Before, @Actual=@After;
DECLARE @ShotsAfter NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ToolId);
EXEC test.Assert_IsEqual @TestName=N'[SRC] rejected entry did not advance ShotCount', @Expected=@ShotsBefore, @Actual=@ShotsAfter;
GO

-- =============================================
-- Test 5: the watermark is PRESS-scoped, so a die moved to another press (E5)
--         and a changeover on the same press (E6) both reset with no
--         special-casing.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @PressB BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Id <> @PressA ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);

DECLARE @SamePress NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SRC] watermark on the original press is 2000', @Expected=N'2000', @Actual=@SamePress;

DECLARE @OtherPress NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressB) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SRC] watermark on a DIFFERENT press resets to 0 (E5/E6)', @Expected=N'0', @Actual=@OtherPress;

DECLARE @OtherShift NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, 999999999, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[SRC] watermark in another shift resets to 0 (counter reset)', @Expected=N'0', @Actual=@OtherShift;
GO

-- =============================================
-- Test 6: releasing with a reading but no new production still writes the
--         anchor row, so the next basket is not over-credited.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SRC-B1');

-- reading unchanged at 2000 -> derived delta is 0
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Lots.DieCastLot_Release
    @LotId = @LotB1, @CounterReading = 2000, @ShiftId = @ShiftId,
    @AppUserId = 1, @CellLocationId = @PressA;
DECLARE @S4 NVARCHAR(1) = CAST((SELECT Status FROM #R4) AS NVARCHAR(1));
DROP TABLE #R4;
EXEC test.Assert_IsEqual @TestName=N'[SRC] zero-delta release succeeds', @Expected=N'1', @Actual=@S4;

DECLARE @Anchor INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution
                       WHERE LotId = @LotB1 AND PieceDelta = 0 AND ShotCounterReading = 2000);
EXEC test.Assert_RowCount @TestName=N'[SRC] zero-delta release still wrote the anchor row',
    @ExpectedCount=1, @ActualCount=@Anchor;
GO

-- =============================================
-- Test 7: a CLOSED cavity with no basket still appears, carrying its status
--         and the part it is configured to cut (0072). Before v2.1 the row
--         source was Lots.Lot, so this cavity produced no row at all.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);

CREATE TABLE #BD (
    ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT,
    CavityDescription NVARCHAR(500), CreditedThrough INT, NewShots INT,
    CavityStatusCode NVARCHAR(30), ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(50),
    -- v3.0 appended trailing columns (0084 / task 4).
    PriorScrapThisShift INT, DieWideShots INT, IsPending BIT);
INSERT INTO #BD EXEC Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId = @ToolId, @ShiftId = @ShiftId, @CounterReading = 2000, @CellLocationId = @PressA;

DECLARE @CavCRows INT = (SELECT COUNT(*) FROM #BD WHERE CavityCode = N'c');
EXEC test.Assert_RowCount @TestName=N'[SRC] basketless cavity still returns a row',
    @ExpectedCount=1, @ActualCount=@CavCRows;

DECLARE @CavCStatus NVARCHAR(30) = (SELECT CavityStatusCode FROM #BD WHERE CavityCode = N'c');
EXEC test.Assert_IsEqual @TestName=N'[SRC] basketless cavity reports its Closed status',
    @Expected=N'Closed', @Actual=@CavCStatus;

DECLARE @CavCPart NVARCHAR(50) = (SELECT ConfiguredPartNumber FROM #BD WHERE CavityCode = N'c');
EXEC test.Assert_IsNotNull @TestName=N'[SRC] basketless cavity still names its configured part',
    @Value=@CavCPart;

-- it proposes nothing (no basket to credit) but DOES report the shots that ran
DECLARE @CavCProp NVARCHAR(20) = (SELECT CAST(ProposedGood AS NVARCHAR(20)) FROM #BD WHERE CavityCode = N'c');
EXEC test.Assert_IsEqual @TestName=N'[SRC] basketless cavity proposes 0 good', @Expected=N'0', @Actual=@CavCProp;
DECLARE @CavCShots NVARCHAR(20) = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM #BD WHERE CavityCode = N'c');
EXEC test.Assert_IsEqual @TestName=N'[SRC] basketless cavity still reports its shots', @Expected=N'2000', @Actual=@CavCShots;
DROP TABLE #BD;
GO

-- =============================================
-- Test 8: a basket released EARLIER THIS SHIFT still accepts scrap, because
--         MPP records scrap once, at end of shift, from a paper form.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SRC-A1');
DECLARE @Defect BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);

DECLARE @ScrapJson NVARCHAR(MAX) =
    N'[{"lotId":' + CAST(@LotA1 AS NVARCHAR(20)) + N',"pieceDelta":0,"scrapLines":[{"defectCodeId":'
  + CAST(@Defect AS NVARCHAR(20)) + N',"quantity":7}]}]';
CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R7 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @ScrapJson,
    @AppUserId = 1, @CounterReading = 2000, @CellLocationId = @PressA;
DECLARE @S7 NVARCHAR(1) = CAST((SELECT Status FROM #R7) AS NVARCHAR(1));
DECLARE @M7 NVARCHAR(500) = (SELECT Message FROM #R7);
DROP TABLE #R7;
EXEC test.Assert_IsEqual @TestName=N'[SRC] closed basket accepts scrap at shift end', @Expected=N'1', @Actual=@S7;

DECLARE @Rej INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE LotId = @LotA1 AND Quantity = 7);
EXEC test.Assert_RowCount @TestName=N'[SRC] the scrap actually landed on the closed basket',
    @ExpectedCount=1, @ActualCount=@Rej;
GO

-- =============================================
-- Test 9: ...but a closed basket is SETTLED -- it may never take more pieces.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'SRC-A1');
DECLARE @BeforePc NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotA1);

DECLARE @PieceJson NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotA1 AS NVARCHAR(20)) + N',"pieceDelta":99,"scrapLines":[]}]';
CREATE TABLE #R8 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R8 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @PieceJson,
    @AppUserId = 1, @CounterReading = 2000, @CellLocationId = @PressA;
DECLARE @S8 NVARCHAR(1) = CAST((SELECT Status FROM #R8) AS NVARCHAR(1));
DROP TABLE #R8;
EXEC test.Assert_IsEqual @TestName=N'[SRC] closed basket rejects more pieces', @Expected=N'0', @Actual=@S8;

DECLARE @AfterPc NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotA1);
EXEC test.Assert_IsEqual @TestName=N'[SRC] rejected piece add left the closed basket alone',
    @Expected=@BeforePc, @Actual=@AfterPc;
GO

-- =============================================
-- TEARDOWN. Oee.Shift is GLOBAL state: 0046_Shift_Reconcile computes backfill
-- from whatever shift rows exist, so a fixture shift left behind changes ITS
-- results even though every assertion here passed. Cleaning up only at the
-- START of a file is not enough in a shared database -- the damage lands on
-- whatever runs next.
-- =============================================
DECLARE @Src TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Src (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'SRC-%';

DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @Src)
                                        OR DescendantLotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @Src)
                                 OR ChildLotId  IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @Src) OR ParentLotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @Src);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @Src);
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'SRC-DIE');
DELETE FROM Tools.Tool WHERE Code = N'SRC-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'SRC-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'SRC-FIXTURE-SCHED';
GO

EXEC test.EndTestFile;
GO
