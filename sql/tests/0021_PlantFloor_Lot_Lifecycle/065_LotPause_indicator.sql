-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/065_LotPause_indicator.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for the Phase 2 Task 7 / G5 Paused-LOT indicator READ procs
--               (spec section 4.5):
--                 * Lots.LotPause_GetCountsByLocation(@LocationId) -> single row
--                   OpenPauseCount INT (the indicator badge value).
--                 * Lots.LotPause_GetByLocation(@LocationId) -> open pauses at a
--                   Cell, ordered by PausedAt (the indicator detail list).
--               Both are READ procs: no @Status/@Message, no status row, empty set
--               = no open pauses.
--
--               Two LOTs are paused at one Cell; one is resumed so the open count
--               is 1. A separate two-LOT case with deterministically-staggered
--               PausedAt verifies oldest-first ordering of the detail list.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/065_LotPause_indicator.sql';
GO

-- ---- shared fixtures: two LOTs + a dedicated indicator Cell ----
IF OBJECT_ID(N'tempdb..#IndFix') IS NOT NULL DROP TABLE #IndFix;
CREATE TABLE #IndFix (Tag NVARCHAR(20) PRIMARY KEY, LotId BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 30, @AppUserId = 1;
INSERT INTO #IndFix (Tag, LotId) SELECT N'A', NewId FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 30, @AppUserId = 1;
INSERT INTO #IndFix (Tag, LotId) SELECT N'B', NewId FROM @cr;
GO

-- =============================================
-- Test 1: open-count reflects open pauses (place 2, resume 1 -> count 1)
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #IndFix WHERE Tag = N'A');
DECLARE @LotB BIGINT = (SELECT LotId FROM #IndFix WHERE Tag = N'B');
DECLARE @Cell BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotA);

DECLARE @pa TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @pa EXEC Lots.LotPause_Place @LotId = @LotA, @LocationId = @Cell, @AppUserId = 1;
DECLARE @pauseAId BIGINT = (SELECT NewId FROM @pa);

DECLARE @pb TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @pb EXEC Lots.LotPause_Place @LotId = @LotB, @LocationId = @Cell, @AppUserId = 1;

-- resume LOT A's pause -> one open remains (LOT B)
DECLARE @rr TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @rr EXEC Lots.LotPause_Resume @PauseEventId = @pauseAId, @AppUserId = 1;

CREATE TABLE #cnt (OpenPauseCount INT);
INSERT INTO #cnt EXEC Lots.LotPause_GetCountsByLocation @LocationId = @Cell;
DECLARE @cnt INT = (SELECT OpenPauseCount FROM #cnt);
DROP TABLE #cnt;
DECLARE @cntStr NVARCHAR(10) = CAST(@cnt AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Indicator] open-count = 1 after place 2 / resume 1',
    @Expected = N'1', @Actual = @cntStr;
GO

-- =============================================
-- Test 2: detail list returns open pauses oldest-first
--   LOT B is still open from Test 1. Re-open LOT A and stagger PausedAt so the
--   ordering is deterministic: force LOT B's open pause to be the OLDER one.
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #IndFix WHERE Tag = N'A');
DECLARE @LotB BIGINT = (SELECT LotId FROM #IndFix WHERE Tag = N'B');
DECLARE @Cell BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotA);

-- Make LOT B's existing open pause clearly the oldest.
UPDATE Lots.PauseEvent SET PausedAt = DATEADD(SECOND, -30, SYSUTCDATETIME())
    WHERE LotId = @LotB AND LocationId = @Cell AND ResumedAt IS NULL;

-- Re-open LOT A (its prior pause was resumed) -> newer PausedAt (now).
DECLARE @pa2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @pa2 EXEC Lots.LotPause_Place @LotId = @LotA, @LocationId = @Cell, @AppUserId = 1;

CREATE TABLE #list (PauseEventId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT,
                    ItemCode NVARCHAR(50), PausedAt DATETIME2(3), PausedByUserId BIGINT,
                    PausedReason NVARCHAR(500));
INSERT INTO #list EXEC Lots.LotPause_GetByLocation @LocationId = @Cell;

-- exactly two open pauses at the Cell now (LOT A re-opened + LOT B)
DECLARE @listN INT = (SELECT COUNT(*) FROM #list);
EXEC test.Assert_RowCount @TestName = N'[Indicator] detail list has the two open pauses',
    @ExpectedCount = 2, @ActualCount = @listN;

-- oldest-first: the first row (min PausedAt) is LOT B
DECLARE @firstLot BIGINT = (SELECT TOP 1 LotId FROM #list ORDER BY PausedAt ASC);
DECLARE @lotBStr NVARCHAR(20) = CAST(@LotB AS NVARCHAR(20));
DECLARE @firstLotStr NVARCHAR(20) = CAST(@firstLot AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Indicator] detail list ordered oldest-first (LOT B leads)',
    @Expected = @lotBStr, @Actual = @firstLotStr;
DROP TABLE #list;
GO

-- =============================================
-- Test 3: a Cell with no open pauses returns empty set / zero count
-- =============================================
DECLARE @LotA BIGINT = (SELECT LotId FROM #IndFix WHERE Tag = N'A');
DECLARE @Cell BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotA);
-- pick a different active location with no pauses
DECLARE @EmptyCell BIGINT = (SELECT TOP 1 Id FROM Location.Location
                             WHERE Id <> @Cell AND DeprecatedAt IS NULL
                               AND NOT EXISTS (SELECT 1 FROM Lots.PauseEvent pe
                                               WHERE pe.LocationId = Location.Location.Id AND pe.ResumedAt IS NULL)
                             ORDER BY Id);
CREATE TABLE #cnt0 (OpenPauseCount INT);
INSERT INTO #cnt0 EXEC Lots.LotPause_GetCountsByLocation @LocationId = @EmptyCell;
DECLARE @cnt0 INT = (SELECT OpenPauseCount FROM #cnt0);
DROP TABLE #cnt0;
DECLARE @cnt0Str NVARCHAR(10) = CAST(@cnt0 AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Indicator] empty Cell open-count = 0',
    @Expected = N'0', @Actual = @cnt0Str;

CREATE TABLE #list0 (PauseEventId BIGINT, LotId BIGINT, LotName NVARCHAR(50), ItemId BIGINT,
                     ItemCode NVARCHAR(50), PausedAt DATETIME2(3), PausedByUserId BIGINT,
                     PausedReason NVARCHAR(500));
INSERT INTO #list0 EXEC Lots.LotPause_GetByLocation @LocationId = @EmptyCell;
DECLARE @n0 INT = (SELECT COUNT(*) FROM #list0);
DROP TABLE #list0;
EXEC test.Assert_RowCount @TestName = N'[Indicator] empty Cell detail list is empty',
    @ExpectedCount = 0, @ActualCount = @n0;
GO

-- ---- cleanup (FK-safe) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #IndFix WHERE LotId IS NOT NULL;

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

IF OBJECT_ID(N'tempdb..#IndFix') IS NOT NULL DROP TABLE #IndFix;
GO
