SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/120_ReadinglessRelease.sql';
GO

-- =============================================
-- A RELEASE WITH A COUNT AND NO READING IS ITS OWN TERM AT SHIFT END
-- (Workorder.ufn_CavityCreditedWithoutReading + breakdown v3.2 + record v3.3, 2026-10-08).
--
-- Operators release baskets mid-shift by typing the pieces, with no press
-- counter reading. That credit was invisible at shift end, so the cavity
-- was proposed the WHOLE reading again for its
-- successor basket -- the same castings credited twice. Prod, 2026-10-07,
-- Machine 11: 515 released without a reading, then reading 1,092 with 54
-- die-wide shots proposed 1,038 for the open basket instead of 523.
--
-- The numbers below are that case. Fixture shape copied from
-- 080_ShotReadingChain.sql (self-contained; nothing depends on seed content).
-- =============================================

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
INSERT INTO @Src (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RLR-%';

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
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DELETE FROM Tools.Tool WHERE Code = N'RLR-DIE';
DELETE FROM Oee.Shift WHERE Id IN (SELECT Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE');
DELETE FROM Oee.ShiftSchedule WHERE Name = N'RLR-FIXTURE-SCHED';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @DieTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ActiveTool BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
DECLARE @ActiveCav BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, ShotCount, CreatedAt, CreatedByUserId)
VALUES (@DieTypeId, N'RLR-DIE', N'Readingless release die', @ActiveTool, 0, @Now, 1);
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
VALUES (N'RLR-A1', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavA, @Now, 1),
       (N'RLR-B1', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavB, @Now, 1);

-- A -SkipDemoSeed build has NO shift schedules, so create one rather than
-- selecting from an empty table (which silently inserts zero shifts and leaves
-- every downstream @ShiftId NULL).
IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSchedule WHERE Name = N'RLR-FIXTURE-SCHED')
    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'RLR-FIXTURE-SCHED', '07:00:00', '15:00:00', 127, CAST(@Now AS DATE), 1);

DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'RLR-FIXTURE-SCHED');
-- CLOSED (ActualEnd set). Oee.Shift carries the filtered unique index
-- UIX_Shift_SingleOpen, so leaving this fixture shift open leaks a second open
-- shift into the shared test database and every later suite that opens one
-- dies with Msg 2601. A closed shift is also the realistic case here: entering
-- output against a previous shift is exactly the retroactive path operators
-- use when they cannot get to the terminal at shift change.
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@SchedId, DATEADD(HOUR, -4, @Now), DATEADD(MINUTE, -5, @Now), N'RLR-FIXTURE');
GO

-- =============================================
-- Test 1: a reading-less release credits the basket and is counted as
--         "credited without a reading" -- and moves NEITHER watermark. The shot
--         count is a fact about the counter; folding these pieces into it is
--         what zeroed the screen on prod (watermark v4.0, rolled back).
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A1');

CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Lots.DieCastLot_Release
    @LotId = @LotA1, @FinalPieceDelta = 515, @ShiftId = @ShiftId,
    @AppUserId = 1, @CellLocationId = @PressA;
DECLARE @S1 NVARCHAR(1) = CAST((SELECT Status FROM #R1) AS NVARCHAR(1));
DROP TABLE #R1;
EXEC test.Assert_IsEqual @TestName=N'[RLR] release with a count and no reading succeeds', @Expected=N'1', @Actual=@S1;

DECLARE @v NVARCHAR(20) = CAST(Workorder.ufn_CavityCreditedWithoutReading(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] cavity a: 515 credited without a reading', @Expected=N'515', @Actual=@v;
SET @v = CAST(Workorder.ufn_CavityCreditedWithoutReading(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] cavity b: nothing credited without a reading', @Expected=N'0', @Actual=@v;
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] the CAVITY watermark does not move without a reading', @Expected=N'0', @Actual=@v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] the DIE watermark does not move without a reading', @Expected=N'0', @Actual=@v;
GO

-- =============================================
-- Test 2: THE MACHINE 11 CASE. Shift-end reading 1,092 with 54 die-wide shots.
--         The successor basket is proposed 523, not 1,038 -- and the shot count
--         still says 1,092, because that is what the counter says.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OpenId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'RLR-A2', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavA, SYSUTCDATETIME(), 1);

CREATE TABLE #BD (
    ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT,
    CavityDescription NVARCHAR(500), CreditedThrough INT, NewShots INT,
    CavityStatusCode NVARCHAR(30), ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(50),
    PriorScrapThisShift INT, DieWideShots INT, IsPending BIT,
    CreditedWithoutReading INT, IsCavityCarrier BIT);
INSERT INTO #BD EXEC Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId = @ToolId, @ShiftId = @ShiftId, @CounterReading = 1092, @CellLocationId = @PressA, @DieWideShots = 54;

DECLARE @v NVARCHAR(40) = (SELECT CAST(ProposedGood AS NVARCHAR(20)) FROM #BD WHERE LotName = N'RLR-A2');
EXEC test.Assert_IsEqual @TestName=N'[RLR] successor basket proposed 523 (1092 - 54 - 515), not 1038', @Expected=N'523', @Actual=@v;
SET @v = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM #BD WHERE LotName = N'RLR-A2');
EXEC test.Assert_IsEqual @TestName=N'[RLR] its shot count is still the counter (1092)', @Expected=N'1092', @Actual=@v;
SET @v = (SELECT CAST(MIN(CreditedWithoutReading) AS NVARCHAR(20)) + N'/' + CAST(MAX(CreditedWithoutReading) AS NVARCHAR(20)) + N'/' + CAST(COUNT(*) AS NVARCHAR(20))
          FROM #BD WHERE CavityCode = N'a');
EXEC test.Assert_IsEqual @TestName=N'[RLR] both rows of cavity a carry 515 already released', @Expected=N'515/515/2', @Actual=@v;
SET @v = (SELECT CAST(CAST(IsCavityCarrier AS INT) AS NVARCHAR(1)) FROM #BD WHERE LotName = N'RLR-A2')
       + (SELECT CAST(CAST(IsCavityCarrier AS INT) AS NVARCHAR(1)) FROM #BD WHERE LotName = N'RLR-A1');
EXEC test.Assert_IsEqual @TestName=N'[RLR] the OPEN basket carries the cavity; the released one does not', @Expected=N'10', @Actual=@v;
SET @v = (SELECT CAST(ProposedGood AS NVARCHAR(20)) + N'/' + CAST(CreditedWithoutReading AS NVARCHAR(20)) + N'/' + CAST(CAST(IsCavityCarrier AS INT) AS NVARCHAR(1))
          FROM #BD WHERE LotName = N'RLR-B1');
EXEC test.Assert_IsEqual @TestName=N'[RLR] a cavity that never rolled: full 1038, nothing released, carries itself', @Expected=N'1038/0/1', @Actual=@v;
SET @v = (SELECT CAST(CAST(IsCavityCarrier AS INT) AS NVARCHAR(1)) + N'/' + CAST(CAST(IsPending AS INT) AS NVARCHAR(1)) FROM #BD WHERE CavityCode = N'c');
EXEC test.Assert_IsEqual @TestName=N'[RLR] a basketless cavity is pending and carries nothing', @Expected=N'0/1', @Actual=@v;
SET @v = (SELECT CAST(SUM(CAST(IsCavityCarrier AS INT)) AS NVARCHAR(20)) FROM #BD);
EXEC test.Assert_IsEqual @TestName=N'[RLR] exactly one carrier per cavity that has a basket', @Expected=N'2', @Actual=@v;
DROP TABLE #BD;
GO

-- =============================================
-- Test 3: submit that entry. The reading becomes the watermark, the released
--         pieces before it are inside its span (nothing left "without a
--         reading"), and a cavity that took a real credit gets no extra row.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A1');
DECLARE @LotA2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A2');
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-B1');
-- the released basket's line rides along, as the screen sends it
DECLARE @Json NVARCHAR(MAX) =
    N'[{"lotId":' + CAST(@LotA1 AS NVARCHAR(20)) + N',"pieceDelta":0,"scrapLines":[]},'
  + N' {"lotId":' + CAST(@LotA2 AS NVARCHAR(20)) + N',"pieceDelta":523,"scrapLines":[]},'
  + N' {"lotId":' + CAST(@LotB1 AS NVARCHAR(20)) + N',"pieceDelta":1038,"scrapLines":[]}]';

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json,
    @AppUserId = 1, @CounterReading = 1092, @CellLocationId = @PressA;
DECLARE @S2 NVARCHAR(1) = CAST((SELECT Status FROM #R2) AS NVARCHAR(1));
DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName=N'[RLR] shift-end entry at reading 1092 succeeds', @Expected=N'1', @Actual=@S2;

DECLARE @v NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] cavity a watermark is the reading (1092)', @Expected=N'1092', @Actual=@v;
SET @v = CAST(Workorder.ufn_CavityCreditedWithoutReading(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] the 515 is now inside that reading -- nothing left without one', @Expected=N'0', @Actual=@v;
DECLARE @n INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution c INNER JOIN Lots.Lot l ON l.Id = c.LotId
                  WHERE l.ToolCavityId = @CavA AND c.ShotCounterReading = 1092);
EXEC test.Assert_RowCount @TestName=N'[RLR] a cavity that took a real credit gets ONE reading row, no extra anchor', @ExpectedCount=1, @ActualCount=@n;
SET @v = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ToolId);
EXEC test.Assert_IsEqual @TestName=N'[RLR] die life counts the shift once (1092)', @Expected=N'1092', @Actual=@v;
GO

-- =============================================
-- Test 4: THE MACHINE 304 CASE. Every basket on the cavity is released, so
--         there is nothing to credit -- but the cavity still has a carrier
--         row, and Submit still records the reading and the disposition.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-B1');
DECLARE @Reason BIGINT = (SELECT TOP 1 Id FROM Workorder.DieCastVarianceReason ORDER BY RequiresNote, Id);

-- release b's only basket by count: 40 typed, of which the counter saw 8
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Lots.DieCastLot_Release
    @LotId = @LotB1, @FinalPieceDelta = 40, @ShiftId = @ShiftId,
    @AppUserId = 1, @CellLocationId = @PressA;
DROP TABLE #R3;
DECLARE @PcBefore NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotB1);

CREATE TABLE #BD (
    ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT,
    CavityDescription NVARCHAR(500), CreditedThrough INT, NewShots INT,
    CavityStatusCode NVARCHAR(30), ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(50),
    PriorScrapThisShift INT, DieWideShots INT, IsPending BIT,
    CreditedWithoutReading INT, IsCavityCarrier BIT);
INSERT INTO #BD EXEC Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId = @ToolId, @ShiftId = @ShiftId, @CounterReading = 1100, @CellLocationId = @PressA, @DieWideShots = 0;
DECLARE @v NVARCHAR(40) = (SELECT CAST(CAST(IsOpen AS INT) AS NVARCHAR(1)) + N'/' + CAST(CAST(IsCavityCarrier AS INT) AS NVARCHAR(1)) + N'/'
                                + CAST(NewShots AS NVARCHAR(20)) + N'/' + CAST(CreditedWithoutReading AS NVARCHAR(20)) + N'/' + CAST(ProposedGood AS NVARCHAR(20))
                           FROM #BD WHERE LotName = N'RLR-B1');
-- released, carrier, 8 shots since 1092, 40 released, nothing proposed: unaccounted would be 8 - 40 = -32
EXEC test.Assert_IsEqual @TestName=N'[RLR] all-released cavity: its last basket carries 8 shots against 40 released', @Expected=N'0/1/8/40/0', @Actual=@v;
DROP TABLE #BD;

DECLARE @Json NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotB1 AS NVARCHAR(20))
    + N',"pieceDelta":0,"scrapLines":[],"varianceReasonId":' + CAST(@Reason AS NVARCHAR(20)) + N',"varianceNote":"carried over"}]';
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json,
    @AppUserId = 1, @CounterReading = 1100, @CellLocationId = @PressA;
DECLARE @S4 NVARCHAR(1) = CAST((SELECT Status FROM #R4) AS NVARCHAR(1));
DECLARE @M4 NVARCHAR(500) = (SELECT Message FROM #R4);
DROP TABLE #R4;
EXEC test.Assert_IsEqual @TestName=N'[RLR] shift-end entry with NO open basket succeeds', @Expected=N'1', @Actual=@S4;

DECLARE @n INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution
                  WHERE LotId = @LotB1 AND PieceDelta = 0 AND ShotCounterReading = 1100
                    AND VarianceReasonId = @Reason AND VarianceNote = N'carried over' AND ToolCavityId IS NULL);
EXEC test.Assert_RowCount @TestName=N'[RLR] reading + disposition stored on ONE zero-piece, cavity-less row', @ExpectedCount=1, @ActualCount=@n;
SET @v = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotB1);
EXEC test.Assert_IsEqual @TestName=N'[RLR] the released basket''s count is not touched', @Expected=@PcBefore, @Actual=@v;
SET @v = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] the shift-end number is on record for the DIE (1100)', @Expected=N'1100', @Actual=@v;
-- ...but the CAVITY is not advanced: the 8 castings since the last release are
-- in whichever basket opens next and must still credit to it (spec 3.6).
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavB, @ShiftId, @PressA) AS NVARCHAR(20))
       + N'/' + CAST(Workorder.ufn_CavityCreditedWithoutReading(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] the all-released CAVITY is not advanced (still 1092, 40 released)', @Expected=N'1092/40', @Actual=@v;

-- the same entry again with nothing new to say writes nothing
DECLARE @RowsBefore INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE LotId = @LotB1);
DECLARE @Json2 NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotB1 AS NVARCHAR(20)) + N',"pieceDelta":0,"scrapLines":[]}]';
CREATE TABLE #R5 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R5 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json2,
    @AppUserId = 1, @CounterReading = 1100, @CellLocationId = @PressA;
DROP TABLE #R5;
DECLARE @RowsAfter INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE LotId = @LotB1);
EXEC test.Assert_RowCount @TestName=N'[RLR] re-submitting the same reading with no disposition adds no row', @ExpectedCount=@RowsBefore, @ActualCount=@RowsAfter;
GO

-- =============================================
-- Test 5: the next basket on that cavity still gets the castings made since
--         the last release -- and an OPEN basket that takes nothing DOES settle
--         its cavity through the reading.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OpenId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'RLR-B2', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavB, SYSUTCDATETIME(), 1);
DECLARE @LotB2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-B2');

CREATE TABLE #BD (
    ToolCavityId BIGINT, CavityCode NVARCHAR(4), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT,
    CavityDescription NVARCHAR(500), CreditedThrough INT, NewShots INT,
    CavityStatusCode NVARCHAR(30), ConfiguredItemId BIGINT, ConfiguredPartNumber NVARCHAR(50),
    PriorScrapThisShift INT, DieWideShots INT, IsPending BIT,
    CreditedWithoutReading INT, IsCavityCarrier BIT);
INSERT INTO #BD EXEC Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId = @ToolId, @ShiftId = @ShiftId, @CounterReading = 1150, @CellLocationId = @PressA, @DieWideShots = 0;
-- 1150 - 1092 = 58 shots; 40 already released by count; the new basket is offered the other 18
DECLARE @v NVARCHAR(40) = (SELECT CAST(NewShots AS NVARCHAR(20)) + N'/' + CAST(CreditedWithoutReading AS NVARCHAR(20)) + N'/' + CAST(ProposedGood AS NVARCHAR(20))
                           + N'/' + CAST(CAST(IsCavityCarrier AS INT) AS NVARCHAR(1)) FROM #BD WHERE LotName = N'RLR-B2');
EXEC test.Assert_IsEqual @TestName=N'[RLR] next basket: 58 shots, 40 released, offered 18 -- nothing stranded', @Expected=N'58/40/18/1', @Actual=@v;
DROP TABLE #BD;

-- the operator says the open basket got nothing from these shots
DECLARE @Json NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotB2 AS NVARCHAR(20)) + N',"pieceDelta":0,"scrapLines":[]}]';
CREATE TABLE #R6 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R6 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json,
    @AppUserId = 1, @CounterReading = 1150, @CellLocationId = @PressA;
DROP TABLE #R6;
DECLARE @n INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution
                  WHERE LotId = @LotB2 AND PieceDelta = 0 AND ShotCounterReading = 1150 AND ToolCavityId = @CavB);
EXEC test.Assert_RowCount @TestName=N'[RLR] an open basket that takes nothing gets a zero-piece row WITH its cavity', @ExpectedCount=1, @ActualCount=@n;
SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavB, @ShiftId, @PressA) AS NVARCHAR(20))
       + N'/' + CAST(Workorder.ufn_CavityCreditedWithoutReading(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] ...and that settles the cavity through the reading (1150, 0 released)', @Expected=N'1150/0', @Actual=@v;
GO

-- =============================================
-- Test 6: every basket released, nothing to dispose of: ONE die-level row
--         still records the shift-end number, and only once.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A2');

CREATE TABLE #R7 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R7 EXEC Lots.DieCastLot_Release
    @LotId = @LotA2, @FinalPieceDelta = 5, @ShiftId = @ShiftId, @AppUserId = 1, @CellLocationId = @PressA;
DELETE FROM #R7;
DECLARE @Json NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotA2 AS NVARCHAR(20)) + N',"pieceDelta":0,"scrapLines":[]}]';
INSERT INTO #R7 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json,
    @AppUserId = 1, @CounterReading = 1200, @CellLocationId = @PressA;
DELETE FROM #R7;
INSERT INTO #R7 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json,
    @AppUserId = 1, @CounterReading = 1200, @CellLocationId = @PressA;
DROP TABLE #R7;

DECLARE @n INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution
                  WHERE LotId = @LotA2 AND PieceDelta = 0 AND ShotCounterReading = 1200 AND ToolCavityId IS NULL);
EXEC test.Assert_RowCount @TestName=N'[RLR] no open basket, no disposition: ONE die-level row, not one per submit', @ExpectedCount=1, @ActualCount=@n;
DECLARE @v NVARCHAR(40) = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20))
       + N'/' + CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20))
       + N'/' + CAST(Workorder.ufn_CavityCreditedWithoutReading(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] die at 1200; cavity a not advanced (1092) with its 5 still to credit', @Expected=N'1200/1092/5', @Actual=@v;
GO

-- =============================================
-- Test 7: a row a RECONCILIATION wrote is not a release by count. Only
--         'Derived' rows are counted (Oee.ShiftAttributionSource, 0099).
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A2');
DECLARE @Reconciled BIGINT = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Reconciled');

INSERT INTO Workorder.DieCastContribution
    (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId, ShiftAttributionSourceId)
VALUES (@LotA2, @ShiftId, 100, 1, SYSUTCDATETIME(), @PressA, NULL, @CavA, @Reconciled);

DECLARE @v NVARCHAR(20) = CAST(Workorder.ufn_CavityCreditedWithoutReading(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] a reconciliation credit is not counted as released without a reading', @Expected=N'5', @Actual=@v;
GO

-- =============================================
-- TEARDOWN. Oee.Shift is GLOBAL state: 0046_Shift_Reconcile computes backfill
-- from whatever shift rows exist, so a fixture shift left behind changes ITS
-- results even though every assertion here passed. Cleaning up only at the
-- START of a file is not enough in a shared database -- the damage lands on
-- whatever runs next.
-- =============================================
DECLARE @Src TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Src (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'RLR-%';

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
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DELETE FROM Tools.Tool WHERE Code = N'RLR-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'RLR-FIXTURE-SCHED';
GO

EXEC test.EndTestFile;
GO
