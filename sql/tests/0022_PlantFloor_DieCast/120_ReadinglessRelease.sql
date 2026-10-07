SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/120_ReadinglessRelease.sql';
GO

-- =============================================
-- A RELEASE WITH A COUNT AND NO READING ADVANCES THE CAVITY
-- (Workorder.ufn_CavityShotWatermark v4.0, 2026-10-07).
--
-- Operators release baskets mid-shift by typing the pieces, with no press
-- counter reading. Before v4.0 that credit was invisible to the cavity
-- watermark, so the shift-end entry proposed the WHOLE reading to the
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
-- Test 1: a reading-less release credits the basket, advances the CAVITY, and
--         leaves the DIE watermark and die life alone (no reading = no shots
--         to add to die life; the next real reading adds them once).
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

DECLARE @NullReading INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution
                            WHERE LotId = @LotA1 AND PieceDelta = 515 AND ShotCounterReading IS NULL);
EXEC test.Assert_RowCount @TestName=N'[RLR] its credit row carries no reading', @ExpectedCount=1, @ActualCount=@NullReading;

DECLARE @WmA NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] released cavity is credited through 515', @Expected=N'515', @Actual=@WmA;

DECLARE @WmB NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] the other cavity is untouched', @Expected=N'0', @Actual=@WmB;

DECLARE @DieWm NVARCHAR(20) = CAST(Workorder.ufn_DieShotWatermark(@ToolId, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] DIE watermark does not move without a reading', @Expected=N'0', @Actual=@DieWm;

DECLARE @Shots NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ToolId);
EXEC test.Assert_IsEqual @TestName=N'[RLR] die life does not move without a reading', @Expected=N'0', @Actual=@Shots;
GO

-- =============================================
-- Test 2: THE PROD CASE. Shift-end reading 1,092 with 54 die-wide shots:
--         the successor basket is proposed 523, not 1,038.
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
    PriorScrapThisShift INT, DieWideShots INT, IsPending BIT);
INSERT INTO #BD EXEC Workorder.DieCast_GetShiftOutputBreakdown
    @ToolId = @ToolId, @ShiftId = @ShiftId, @CounterReading = 1092, @CellLocationId = @PressA, @DieWideShots = 54;

DECLARE @v NVARCHAR(20) = (SELECT CAST(ProposedGood AS NVARCHAR(20)) FROM #BD WHERE LotName = N'RLR-A2');
EXEC test.Assert_IsEqual @TestName=N'[RLR] successor basket proposed 523 (1092 - 515 - 54), not 1038', @Expected=N'523', @Actual=@v;

SET @v = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM #BD WHERE LotName = N'RLR-A2');
EXEC test.Assert_IsEqual @TestName=N'[RLR] its shot count is net of the release too (577), so variance stays honest', @Expected=N'577', @Actual=@v;

SET @v = (SELECT CAST(ProposedGood AS NVARCHAR(20)) FROM #BD WHERE LotName = N'RLR-B1');
EXEC test.Assert_IsEqual @TestName=N'[RLR] a cavity that never rolled is still proposed the full 1038', @Expected=N'1038', @Actual=@v;

SET @v = (SELECT CAST(ProposedGood AS NVARCHAR(20)) FROM #BD WHERE LotName = N'RLR-A1');
EXEC test.Assert_IsEqual @TestName=N'[RLR] the released basket itself proposes 0', @Expected=N'0', @Actual=@v;
DROP TABLE #BD;
GO

-- =============================================
-- Test 3: once a reading is recorded it IS the watermark. The reading-less
--         release before it is inside that reading's span and is not added
--         again (1092, not 1607).
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A2');
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-B1');
DECLARE @Json NVARCHAR(MAX) =
    N'[{"lotId":' + CAST(@LotA2 AS NVARCHAR(20)) + N',"pieceDelta":523,"scrapLines":[]},'
  + N' {"lotId":' + CAST(@LotB1 AS NVARCHAR(20)) + N',"pieceDelta":1038,"scrapLines":[]}]';

CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json,
    @AppUserId = 1, @CounterReading = 1092, @CellLocationId = @PressA;
DECLARE @S2 NVARCHAR(1) = CAST((SELECT Status FROM #R2) AS NVARCHAR(1));
DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName=N'[RLR] shift-end entry at reading 1092 succeeds', @Expected=N'1', @Actual=@S2;

DECLARE @Wm NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] watermark is the reading (1092), earlier release not re-added', @Expected=N'1092', @Actual=@Wm;

DECLARE @Shots NVARCHAR(20) = (SELECT CAST(ShotCount AS NVARCHAR(20)) FROM Tools.Tool WHERE Id = @ToolId);
EXEC test.Assert_IsEqual @TestName=N'[RLR] die life counts the shift once (1092)', @Expected=N'1092', @Actual=@Shots;
GO

-- =============================================
-- Test 4: a reading-less release AFTER the reading adds on top of it, and the
--         release preview for the next basket subtracts it.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'a');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotA2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A2');
DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OpenId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Lots.DieCastLot_Release
    @LotId = @LotA2, @FinalPieceDelta = 5, @ShiftId = @ShiftId,
    @AppUserId = 1, @CellLocationId = @PressA;
DECLARE @S3 NVARCHAR(1) = CAST((SELECT Status FROM #R3) AS NVARCHAR(1));
DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName=N'[RLR] second reading-less release succeeds', @Expected=N'1', @Actual=@S3;

DECLARE @Wm NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavA, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] credited through 1097 (reading 1092 + 5 since)', @Expected=N'1097', @Actual=@Wm;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'RLR-A3', @ItemId, @OriginId, @OpenId, 0, 0, @PressA, @ToolId, @CavA, SYSUTCDATETIME(), 1);
DECLARE @LotA3 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-A3');

CREATE TABLE #PV (
    LotId BIGINT, LotName NVARCHAR(50), ToolCavityId BIGINT, CavityCode NVARCHAR(4),
    CavityDescription NVARCHAR(500), ItemId BIGINT, PartNumber NVARCHAR(50), PieceCount INT,
    MaxPieceCount INT, CreditedThrough INT, DieCreditedThrough INT, NewShots INT,
    ProjectedPieceCount INT, BelowStandardAfter BIT, ReadingState NVARCHAR(20), ToolId BIGINT);
INSERT INTO #PV EXEC Workorder.DieCast_GetReleasePreview
    @LotId = @LotA3, @ShiftId = @ShiftId, @CellLocationId = @PressA, @CounterReading = 1200;
DECLARE @Pv NVARCHAR(20) = (SELECT CAST(NewShots AS NVARCHAR(20)) FROM #PV);
DROP TABLE #PV;
EXEC test.Assert_IsEqual @TestName=N'[RLR] release preview at 1200 shows 103 new shots (1200 - 1097)', @Expected=N'103', @Actual=@Pv;
GO

-- =============================================
-- Test 5: a row a RECONCILIATION wrote is not a casting event here. Only
--         'Derived' rows advance the cavity (Oee.ShiftAttributionSource, 0099).
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'RLR-DIE');
DECLARE @CavB BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityCode = N'b');
DECLARE @PressA BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'RLR-FIXTURE' ORDER BY Id DESC);
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'RLR-B1');
DECLARE @Reconciled BIGINT = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Reconciled');

DECLARE @Before NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] cavity b sits at its reading (1092)', @Expected=N'1092', @Actual=@Before;

INSERT INTO Workorder.DieCastContribution
    (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId, ShiftAttributionSourceId)
VALUES (@LotB1, @ShiftId, 100, 1, SYSUTCDATETIME(), @PressA, NULL, @CavB, @Reconciled);

DECLARE @After NVARCHAR(20) = CAST(Workorder.ufn_CavityShotWatermark(@CavB, @ShiftId, @PressA) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[RLR] a reconciliation credit does not advance the cavity', @Expected=N'1092', @Actual=@After;
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
