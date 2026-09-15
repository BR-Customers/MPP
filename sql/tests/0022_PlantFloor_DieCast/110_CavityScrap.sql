SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/110_CavityScrap.sql';
GO

-- =============================================
-- CAVITY-ATTRIBUTED DIE-CAST SCRAP (migration 0084).
--
-- Die-cast scrap is a fact about (Shift, Press, Tool, Cavity, Part); the LOT is
-- optional decoration. These assertions pin the SHAPE; behaviour tests follow
-- in later tasks of the same plan.
--
-- NOTE the asymmetry these tests encode, because it is the thing most likely to
-- be "tidied" later: RejectEvent.LotId becomes NULLABLE, while
-- DieCastContribution.LotId stays NOT NULL. See spec sec 3.6 -- a basketless
-- cavity must NOT advance its shot watermark, and that constraint is what
-- stops it.
-- =============================================

DECLARE @v NVARCHAR(20);

SET @v = CAST((SELECT is_nullable FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent') AND name = N'LotId') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] RejectEvent.LotId is nullable',
    @Expected = N'1', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.RejectEvent')
                 AND name IN (N'ItemId', N'ToolId', N'ToolCavityId', N'ShiftId', N'CellLocationId')) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] RejectEvent gained 5 attribution columns',
    @Expected = N'5', @Actual = @v;

SET @v = CAST((SELECT is_nullable FROM sys.columns
               WHERE object_id = OBJECT_ID(N'Workorder.DieCastContribution') AND name = N'LotId') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] DieCastContribution.LotId stays NOT NULL (spec 3.6)',
    @Expected = N'0', @Actual = @v;

-- every index on RejectEvent must remain partition-aligned, or sliding-window
-- TRUNCATE retention (B2) breaks silently at the next maintenance run
SET @v = CAST((SELECT COUNT(*) FROM sys.indexes i
               JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
               WHERE i.object_id = OBJECT_ID(N'Workorder.RejectEvent')
                 AND i.index_id > 0 AND ds.name <> N'ps_MonthlyUtc') AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] every RejectEvent index still ON ps_MonthlyUtc',
    @Expected = N'0', @Actual = @v;

SET @v = CAST((SELECT COUNT(*) FROM Workorder.DieCastVarianceReason) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] DieCastVarianceReason seeded with 5 reasons',
    @Expected = N'5', @Actual = @v;

SET @v = (SELECT CAST(RequiresNote AS NVARCHAR(20)) FROM Workorder.DieCastVarianceReason WHERE Code = N'Unknown');
EXEC test.Assert_IsEqual @TestName = N'[0084] Unknown requires a note',
    @Expected = N'1', @Actual = @v;

SET @v = (SELECT CAST(dc.IsNonRejectScrap AS NVARCHAR(20)) FROM Quality.DefectCode dc WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 Warmup is non-reject scrap',
    @Expected = N'1', @Actual = @v;

SET @v = (SELECT oc.Code FROM Quality.DefectCode dc
          JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 is categorised DieCast',
    @Expected = N'DieCast', @Actual = @v;

SET @v = (SELECT cp.Code FROM Quality.DefectCode dc
          JOIN Quality.ChargeToParty cp ON cp.Id = dc.ChargeToPartyId WHERE dc.Code = N'DC-999');
EXEC test.Assert_IsEqual @TestName = N'[0084] DC-999 charges to DieCast',
    @Expected = N'DieCast', @Actual = @v;

-- backfill: every pre-existing reject must now carry its LOT's part
SET @v = CAST((SELECT COUNT(*) FROM Workorder.RejectEvent re
               JOIN Lots.Lot l ON l.Id = re.LotId
               WHERE re.ItemId IS NULL OR re.ItemId <> l.ItemId) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[0084] ItemId backfilled to match every existing LOT',
    @Expected = N'0', @Actual = @v;
GO

-- =============================================
-- ufn_CavityShotWatermark v3.0 -- reads the stamped cavity directly instead of
-- traversing Lots.Lot (Task 2 of the same plan). Test 1 is a NEUTRALITY
-- assertion: every contribution row still carries a LOT, so the old join and
-- the new column resolve the same cavity -- this must be true both before and
-- after v3.0. Tests 2-3 pin spec 3.6: a basketless cavity must not lose, and
-- must not advance its watermark from, the gap.
--
-- FIXTURES ARE SELF-CONTAINED (see 080_ShotReadingChain.sql for why: sibling
-- suites in this folder abort on seed data a -SkipDemoSeed build does not
-- have).
-- =============================================

-- ---- cleanup (reverse FK order), in case of a partial prior run ----
DECLARE @CsLots TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @CsLots (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CS-%';

DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @CsLots)
                                        OR DescendantLotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @CsLots)
                                 OR ChildLotId  IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @CsLots) OR ParentLotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @CsLots);
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CS-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CS-DIE');
DELETE FROM Tools.Tool WHERE Code = N'CS-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'CS-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'CS-FIXTURE-SCHED';
GO

-- ---- fixtures: one tool, one cavity, one shift, two baskets with a gap ----
-- FIXTURES ARE SELF-CONTAINED for the shift too (see 080_ShotReadingChain.sql):
-- a -SkipDemoSeed build has NO shift schedules/shifts, so an existing-row
-- lookup silently leaves @ShiftId NULL and every downstream call fails with
-- "Required parameter missing." Create our own, CLOSED (Oee.Shift carries the
-- filtered unique index UIX_Shift_SingleOpen -- an OPEN fixture shift here
-- would collide with any other suite that opens one).
DECLARE @Usr BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @ToolId BIGINT, @CavId BIGINT, @ShiftId BIGINT, @ItemId BIGINT, @CellId BIGINT;
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

SELECT TOP 1 @CellId = l.Id FROM Location.Location l
  JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
  WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id;
SELECT TOP 1 @ItemId = Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id;

IF NOT EXISTS (SELECT 1 FROM Oee.ShiftSchedule WHERE Name = N'CS-FIXTURE-SCHED')
    INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
    VALUES (N'CS-FIXTURE-SCHED', '07:00:00', '15:00:00', 127, CAST(@Now AS DATE), @Usr);
DECLARE @SchedId BIGINT = (SELECT Id FROM Oee.ShiftSchedule WHERE Name = N'CS-FIXTURE-SCHED');

INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
VALUES (@SchedId, DATEADD(HOUR, -4, @Now), DATEADD(MINUTE, -5, @Now), N'CS-FIXTURE');
SET @ShiftId = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CS-FIXTURE' ORDER BY Id DESC);

INSERT INTO Tools.Tool (Code, Name, ToolTypeId, StatusCodeId, CreatedByUserId)
SELECT N'CS-DIE', N'Cavity scrap test die',
       (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id),
       (SELECT TOP 1 Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), @Usr;
SET @ToolId = SCOPE_IDENTITY();

INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, Description, ItemId, CreatedByUserId)
SELECT @ToolId, N'a', (SELECT TOP 1 Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active'),
       N'CS cavity a', @ItemId, @Usr;
SET @CavId = SCOPE_IDENTITY();
GO

-- Test 1 -- NEUTRALITY. No basketless rows exist, so v3.0 must agree with v2.0
-- on every existing fixture. Asserted against the recorded MAX directly.
DECLARE @CavId BIGINT = (SELECT tc.Id FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId
                         WHERE t.Code = N'CS-DIE' AND tc.CavityCode = N'a');
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CS-FIXTURE' ORDER BY Id DESC);
DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
  JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
  WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @v NVARCHAR(20);

SET @v = CAST(Workorder.ufn_CavityShotWatermark(@CavId, @ShiftId, @CellId) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Watermark] no contributions -> 0',
    @Expected = N'0', @Actual = @v;
GO

-- =============================================
-- Full fixture chain: basket 1 opens on the cavity, is contributed to at
-- reading 1900 via a shift-output entry (full amount -- the cavity is fresh,
-- watermark 0), then formally RELEASED at that SAME reading -- zero further
-- production, but the release still writes an anchoring contribution row
-- (100_CounterAnchor test 6 pins that a zero-delta release still writes the
-- row; without it the next basket on this cavity would be credited from a
-- stale watermark and over-counted).
--
-- Then a GAP: 116 shots run at the press with NO basket open on this cavity.
-- Nothing is written for the gap -- there is no row to write, because
-- Workorder.DieCastContribution.LotId is NOT NULL (spec 3.6) and no basket
-- exists to carry one. The press counter is physically climbing toward 3000
-- the whole time; the MES record simply lags until the next basket opens.
--
-- Basket 2 then opens on the SAME cavity and is contributed to at reading
-- 3000. The pieceDelta submitted mirrors exactly what the real screen does
-- (Workorder.DieCast_GetShiftOutputBreakdown reads the cavity's watermark and
-- proposes reading-minus-watermark): read the watermark via the function
-- under test, subtract from 3000, submit that as pieceDelta. The arithmetic
-- that must hold: watermark after the gap is still 1900 (unmoved by the 116
-- gap shots, because nothing wrote a row for them), so the credit to basket 2
-- is 3000 - 1900 = 1100 -- the full span INCLUDING the 116 gap shots, because
-- those castings are physically inside basket 2. A timing gap on the
-- operator's part must not cost them production.
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'CS-DIE');
DECLARE @CavId BIGINT = (SELECT tc.Id FROM Tools.ToolCavity tc JOIN Tools.Tool t ON t.Id = tc.ToolId
                         WHERE t.Code = N'CS-DIE' AND tc.CavityCode = N'a');
DECLARE @CellId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
  JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
  WHERE d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @ShiftId BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE Remarks = N'CS-FIXTURE' ORDER BY Id DESC);
DECLARE @ItemId BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Usr BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @OriginId BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @OpenId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

-- basket 1 opens on cavity a
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'CS-B1', @ItemId, @OriginId, @OpenId, 0, 0, @CellId, @ToolId, @CavId, SYSUTCDATETIME(), @Usr);
DECLARE @LotB1 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CS-B1');

-- contribute at reading 1900 (fresh cavity, watermark 0 -> full amount)
DECLARE @Json1 NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotB1 AS NVARCHAR(20)) + N',"pieceDelta":1900,"scrapLines":[]}]';
CREATE TABLE #CS1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CS1 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json1,
    @AppUserId = @Usr, @CounterReading = 1900, @CellLocationId = @CellId;
DECLARE @S1 NVARCHAR(1) = CAST((SELECT Status FROM #CS1) AS NVARCHAR(1));
DECLARE @M1 NVARCHAR(500) = (SELECT Message FROM #CS1);
DROP TABLE #CS1;
EXEC test.Assert_IsEqual @TestName = N'[Watermark] fixture contribution at 1900 succeeds',
    @Expected = N'1', @Actual = @S1;

-- release it at the SAME reading -- zero further production, but the release
-- still anchors the watermark
CREATE TABLE #CS2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CS2 EXEC Lots.DieCastLot_Release
    @LotId = @LotB1, @CounterReading = 1900, @ShiftId = @ShiftId,
    @AppUserId = @Usr, @CellLocationId = @CellId;
DECLARE @S2 NVARCHAR(1) = CAST((SELECT Status FROM #CS2) AS NVARCHAR(1));
DECLARE @M2 NVARCHAR(500) = (SELECT Message FROM #CS2);
DROP TABLE #CS2;
EXEC test.Assert_IsEqual @TestName = N'[Watermark] fixture release at 1900 succeeds',
    @Expected = N'1', @Actual = @S2;

-- ---- the gap: 116 shots run with NO basket open on this cavity. Nothing is
-- recorded for it. ----

-- basket 2 opens on the SAME cavity
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, ToolId, ToolCavityId, CreatedAt, CreatedByUserId)
VALUES (N'CS-B2', @ItemId, @OriginId, @OpenId, 0, 0, @CellId, @ToolId, @CavId, SYSUTCDATETIME(), @Usr);
DECLARE @LotB2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'CS-B2');

-- the watermark this cavity carries after the gap -- pinned directly, because
-- this is the number the rule depends on
DECLARE @WmAfterGap INT = Workorder.ufn_CavityShotWatermark(@CavId, @ShiftId, @CellId);
DECLARE @WmAfterGapStr NVARCHAR(20) = CAST(@WmAfterGap AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Watermark] cavity watermark unchanged by the gap (still 1900)',
    @Expected = N'1900', @Actual = @WmAfterGapStr;

-- contribute at reading 3000: mirrors what the real screen submits
-- (reading - watermark)
DECLARE @Delta2 INT = 3000 - @WmAfterGap;
DECLARE @Json2 NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotB2 AS NVARCHAR(20)) + N',"pieceDelta":' + CAST(@Delta2 AS NVARCHAR(20)) + N',"scrapLines":[]}]';
CREATE TABLE #CS3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #CS3 EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @ShiftId, @ToolId = @ToolId, @LinesJson = @Json2,
    @AppUserId = @Usr, @CounterReading = 3000, @CellLocationId = @CellId;
DECLARE @S3 NVARCHAR(1) = CAST((SELECT Status FROM #CS3) AS NVARCHAR(1));
DECLARE @M3 NVARCHAR(500) = (SELECT Message FROM #CS3);
DROP TABLE #CS3;
EXEC test.Assert_IsEqual @TestName = N'[Watermark] fixture contribution at 3000 succeeds',
    @Expected = N'1', @Actual = @S3;

DECLARE @creditedToSecondBasket NVARCHAR(20) = (SELECT CAST(PieceCount AS NVARCHAR(20)) FROM Lots.Lot WHERE Id = @LotB2);

-- Test 2 -- THE RULE JACQUES CORRECTED (spec 3.6). After a basket is released
-- at reading 1900 and 116 shots run with NO basket, the NEXT basket must be
-- credited THROUGH the gap -- because the castings are physically in it.
-- A timing gap must not cost the operator production.
EXEC test.Assert_IsEqual @TestName = N'[Watermark] gap shots credit to the next basket',
    @Expected = N'1100', @Actual = @creditedToSecondBasket;

-- Test 3 -- a basketless cavity writes NO contribution row.
DECLARE @contributionsWithoutLot NVARCHAR(20) = CAST(
    (SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE LotId IS NULL) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Watermark] basketless cavity writes no contribution',
    @Expected = N'0', @Actual = @contributionsWithoutLot;
GO

-- ---- teardown ----
DECLARE @CsLots TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @CsLots (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'CS-%';

DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Workorder.RejectEvent          WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Workorder.ProductionEvent      WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @CsLots)
                                        OR DescendantLotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @CsLots)
                                 OR ChildLotId  IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotEventLog        WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotLabel           WHERE LotId IN (SELECT Id FROM @CsLots) OR ParentLotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotMovement        WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.LotStatusHistory   WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.PauseEvent         WHERE LotId IN (SELECT Id FROM @CsLots);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @CsLots);
DELETE FROM Tools.ToolCavity WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CS-DIE');
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'CS-DIE');
DELETE FROM Tools.Tool WHERE Code = N'CS-DIE';
DELETE FROM Oee.Shift WHERE Remarks = N'CS-FIXTURE';
DELETE FROM Oee.ShiftSchedule WHERE Name = N'CS-FIXTURE-SCHED';
GO
