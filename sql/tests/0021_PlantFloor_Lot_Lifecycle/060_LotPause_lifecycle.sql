-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/060_LotPause_lifecycle.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for the Phase 2 Task 7 / G5 LOT-pause lifecycle procs
--               (OI-21 / FDS-05-038, spec section 4.5):
--                 * Lots.LotPause_Place(@LotId, @LocationId, @PausedReason,
--                   @AppUserId, @TerminalLocationId) -> Status, Message, NewId.
--                 * Lots.LotPause_Resume(@PauseEventId, @ResumedRemarks,
--                   @AppUserId, @TerminalLocationId) -> Status, Message.
--
--               Asserts: place opens a row (ResumedAt NULL); double-place of the
--               same (LotId, LocationId) is rejected (B3 open-event invariant);
--               the same LOT MAY be paused at two different Cells at once; resume
--               closes the pause (ResumedAt + resumer set); the resumer MAY differ
--               from the pauser; resume of an already-resumed pause is rejected; a
--               blocked (Hold) LOT cannot be paused.
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair. A second distinct Cell location (any active
--               Location row) exercises cross-Cell concurrency. The 'PauseEvent'
--               entity audits to Audit.OperationLog (only 'Lot' routes to
--               LotEventLog) -- teardown sweeps those rows.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/060_LotPause_lifecycle.sql';
GO

-- ---- shared fixtures ----
IF OBJECT_ID(N'tempdb..#PauFix') IS NOT NULL DROP TABLE #PauFix;
CREATE TABLE #PauFix (Tag NVARCHAR(20) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50));
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId IN (SELECT Id FROM Parts.Item WHERE MaxLotSize IS NULL)   -- uncapped: fixture PieceCounts exceed the 24-30 seed basket caps
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 60, @AppUserId = 1;
INSERT INTO #PauFix (Tag, LotId, LotName) SELECT N'LOT', NewId, MintedLotName FROM @cr;

-- A blocked (Hold) LOT for the not-blocked guard test.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 60, @AppUserId = 1;
INSERT INTO #PauFix (Tag, LotId, LotName) SELECT N'HELD', NewId, MintedLotName FROM @cr;
-- Direct UPDATE to Hold: Good->Hold is Phase 7 scope; this is a test-fixture
-- expedient to exercise the not-blocked guard.
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold')
    WHERE Id = (SELECT LotId FROM #PauFix WHERE Tag = N'HELD');
GO

-- =============================================
-- Test 1: place opens a pause (Status=1, open row exists)
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #PauFix WHERE Tag = N'LOT');
DECLARE @LocA  BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
DECLARE @p1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p1 EXEC Lots.LotPause_Place
    @LotId = @LotId, @LocationId = @LocA, @PausedReason = N'Operator break', @AppUserId = 1;
DECLARE @ok1 BIT = (SELECT Status FROM @p1);
DECLARE @pid1 BIGINT = (SELECT NewId FROM @p1);
EXEC test.Assert_IsTrue @TestName = N'[Pause] place succeeds (Status=1)', @Condition = @ok1;
EXEC test.Assert_IsNotNull @TestName = N'[Pause] place returns a NewId', @Value = @pid1;
DECLARE @open1 INT = (SELECT COUNT(*) FROM Lots.PauseEvent
                      WHERE Id = @pid1 AND ResumedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Pause] the pause row is open (ResumedAt NULL)',
    @ExpectedCount = 1, @ActualCount = @open1;
GO

-- =============================================
-- Test 2: double-place of the same (LotId, LocationId) rejected (B3)
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #PauFix WHERE Tag = N'LOT');
DECLARE @LocA  BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
DECLARE @p2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p2 EXEC Lots.LotPause_Place
    @LotId = @LotId, @LocationId = @LocA, @AppUserId = 1;
DECLARE @s2 BIT = (SELECT Status FROM @p2);
DECLARE @s2cond BIT = CASE WHEN @s2 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Pause] double-place same (Lot,Location) rejected', @Condition = @s2cond;
-- still exactly one open pause for this (Lot, LocA)
DECLARE @openCnt INT = (SELECT COUNT(*) FROM Lots.PauseEvent
                        WHERE LotId = @LotId AND LocationId = @LocA AND ResumedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Pause] still exactly one open pause after double-place',
    @ExpectedCount = 1, @ActualCount = @openCnt;
GO

-- =============================================
-- Test 3: the same LOT MAY be paused at a SECOND Cell concurrently
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #PauFix WHERE Tag = N'LOT');
DECLARE @LocA  BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
-- pick any other active location as Cell B
DECLARE @LocB  BIGINT = (SELECT TOP 1 Id FROM Location.Location
                         WHERE Id <> @LocA AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @p3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p3 EXEC Lots.LotPause_Place
    @LotId = @LotId, @LocationId = @LocB, @AppUserId = 1;
DECLARE @s3 BIT = (SELECT Status FROM @p3);
EXEC test.Assert_IsTrue @TestName = N'[Pause] same LOT paused at a second Cell allowed', @Condition = @s3;
DECLARE @openBoth INT = (SELECT COUNT(*) FROM Lots.PauseEvent
                         WHERE LotId = @LotId AND ResumedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Pause] LOT now has two open pauses (two Cells)',
    @ExpectedCount = 2, @ActualCount = @openBoth;
GO

-- =============================================
-- Test 4: resume closes the pause; resumer MAY differ from pauser
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #PauFix WHERE Tag = N'LOT');
DECLARE @LocA  BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
DECLARE @pauseAId BIGINT = (SELECT Id FROM Lots.PauseEvent
                            WHERE LotId = @LotId AND LocationId = @LocA AND ResumedAt IS NULL);
-- a different app user resumes
DECLARE @U2 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Id <> 1 ORDER BY Id);
EXEC test.Assert_IsNotNull @TestName = N'[Pause] a second AppUser exists for the resumer-differs case', @Value = @U2;
DECLARE @r4 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r4 EXEC Lots.LotPause_Resume
    @PauseEventId = @pauseAId, @ResumedRemarks = N'Back on the job', @AppUserId = @U2;
DECLARE @s4 BIT = (SELECT Status FROM @r4);
EXEC test.Assert_IsTrue @TestName = N'[Pause] resume succeeds (Status=1)', @Condition = @s4;
DECLARE @resumedAt DATETIME2(3) = (SELECT ResumedAt FROM Lots.PauseEvent WHERE Id = @pauseAId);
DECLARE @resumedAtStr NVARCHAR(30) = CONVERT(NVARCHAR(30), @resumedAt, 121);
EXEC test.Assert_IsNotNull @TestName = N'[Pause] resume sets ResumedAt', @Value = @resumedAtStr;
DECLARE @resumer BIGINT = (SELECT ResumedByUserId FROM Lots.PauseEvent WHERE Id = @pauseAId);
DECLARE @u2Str NVARCHAR(20) = CAST(@U2 AS NVARCHAR(20));
DECLARE @resumerStr NVARCHAR(20) = CAST(@resumer AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Pause] resumer (different user) recorded',
    @Expected = @u2Str, @Actual = @resumerStr;
GO

-- =============================================
-- Test 5: resume of an already-resumed pause is rejected
-- =============================================
DECLARE @LotId BIGINT = (SELECT LotId FROM #PauFix WHERE Tag = N'LOT');
DECLARE @LocA  BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotId);
-- the Cell-A pause was resumed in Test 4; grab it (now closed)
DECLARE @closedId BIGINT = (SELECT TOP 1 Id FROM Lots.PauseEvent
                            WHERE LotId = @LotId AND LocationId = @LocA AND ResumedAt IS NOT NULL
                            ORDER BY Id DESC);
DECLARE @r5 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r5 EXEC Lots.LotPause_Resume @PauseEventId = @closedId, @AppUserId = 1;
DECLARE @s5 BIT = (SELECT Status FROM @r5);
DECLARE @s5cond BIT = CASE WHEN @s5 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Pause] resume of an already-resumed pause rejected', @Condition = @s5cond;
GO

-- =============================================
-- Test 6: a blocked (Hold) LOT cannot be paused
-- =============================================
DECLARE @HeldId BIGINT = (SELECT LotId FROM #PauFix WHERE Tag = N'HELD');
DECLARE @LocA   BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @HeldId);
DECLARE @p6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p6 EXEC Lots.LotPause_Place @LotId = @HeldId, @LocationId = @LocA, @AppUserId = 1;
DECLARE @s6 BIT = (SELECT Status FROM @p6);
DECLARE @s6cond BIT = CASE WHEN @s6 = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Pause] blocked (Hold) LOT cannot be paused', @Condition = @s6cond;
DECLARE @heldOpen INT = (SELECT COUNT(*) FROM Lots.PauseEvent WHERE LotId = @HeldId);
EXEC test.Assert_RowCount @TestName = N'[Pause] no pause row written for blocked LOT',
    @ExpectedCount = 0, @ActualCount = @heldOpen;
GO

-- ---- cleanup (FK-safe) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #PauFix WHERE LotId IS NOT NULL;

DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Lots.PauseEvent pe ON pe.Id = ol.EntityId
    INNER JOIN @ids x ON x.Id = pe.LotId
    WHERE ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'PauseEvent');
DELETE FROM Lots.PauseEvent WHERE LotId IN (SELECT Id FROM @ids);
-- Lot_Create writes a LotGenealogyClosure self-row (Depth=0) -> clear before the LOTs.
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogy WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

IF OBJECT_ID(N'tempdb..#PauFix') IS NOT NULL DROP TABLE #PauFix;
GO
