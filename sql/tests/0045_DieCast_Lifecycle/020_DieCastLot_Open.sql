-- =============================================
-- File:         0045_DieCast_Lifecycle/020_DieCastLot_Open.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-28
-- Description:  Tests for Lots.DieCastLot_Open (Die-Cast Per-Cavity Lifecycle
--               plan, Task 2 / Phase 1): mints ONE accumulator LOT per
--               (Tool, ToolCavity) in status 'Open', PieceCount 0.
--
--               FIXTURE NOTE (deviates from the task-2 brief's literal
--               fixture): a clean MPP_MES_Test reset (Run-Tests -> Reset-
--               DevDatabase -SkipDemoSeed) runs every sql/seeds/*.sql file, so
--               die-cast-routed, cell-eligible ITEMS exist -- but NO
--               Tools.ToolAssignment rows exist (mounts live only in
--               seed_demo/seed_jp, which is skipped). The brief's fixture
--               ("SELECT TOP 1 ... FROM Tools.ToolAssignment WHERE
--               ReleasedAt IS NULL") therefore resolves to NULL on a clean
--               reset. Recipe used instead (mirrors 0022_PlantFloor_DieCast/
--               030 + 050): (1) resolve a (Cell, ItemId) pair via the
--               ANCESTOR-CASCADE eligibility rule (Parts.v_EffectiveItemLocation
--               joined through Location.ufn_AncestorLocationIds -- seed
--               eligibility is configured at Area/WorkCenter tier only, "no
--               cells" per sql/seeds/020_seed_items.sql's own header comment,
--               so a literal Source='Direct' match AT the Cell never exists)
--               where the Item has a published route with a DieCast step and
--               the Cell has no active ToolAssignment; (2) build a Tool +
--               Active ToolCavity + ToolAssignment inline on that Cell
--               (mirrors 0022/050 lines 55-72). DieCastLot_Open does not
--               check tool<->item compatibility, so an inline tool + the
--               seeded routed item on the same cell is valid. Fixture
--               resolution and all four tests run in ONE batch (no GO
--               in-between) so the resolved @Cell/@Item/@Tool/@Cavity
--               variables stay in scope throughout (mirrors the brief's own
--               structure).
--
--               LTTs must be 9-digit strings (Lots.ufn_IsValidExternalLtt);
--               'DCO-020-*' from the brief's draft is NOT a valid format, so
--               numeric LTTs are used instead (200000201 / 200000202).
--
--               Test 4 ("Open LOT not on Trim queue") empirically requires
--               Lots.Lot_GetWipQueueByLocation to exclude 'Open' status --
--               confirmed against this DB that a plain 'Good'-status LOT with
--               no ProductionEvent DOES surface in the TrimIn queue today
--               (only 'Closed' is excluded). The per-cavity-lifecycle PLAN
--               already assigns this exact change to Task 5 (see
--               docs/superpowers/plans/2026-07-28-diecast-per-cavity-
--               lifecycle.md "Task 5: Lots.Lot_GetWipQueueByLocation excludes
--               Open", which explicitly says "Test: covered by Task 2 Test
--               4") and the design spec's "sc.Code NOT IN ('Closed', 'Open')"
--               rule. Since Task 2's own GREEN gate requires Test 4 to pass,
--               Task 5's one-line change is pulled forward here (see
--               R__Lots_Lot_GetWipQueueByLocation.sql) rather than leaving
--               Task 2 unable to reach GREEN on its own scope.
-- =============================================
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/020_DieCastLot_Open.sql';
GO
-- cleanup (FK-safe, reverse order)
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName IN (N'200000201', N'200000202');
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName IN (N'200000201', N'200000202');
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName IN (N'200000201', N'200000202');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName IN (N'200000201', N'200000202');
DELETE FROM Lots.Lot WHERE LotName IN (N'200000201', N'200000202');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCO-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCO-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCO-TOOL';
GO

-- ---- fixture: resolve (Cell, ItemId) via ancestor-cascade eligibility + a
-- published DieCast-route step, with NO active ToolAssignment on the Cell;
-- build Tool + Active ToolCavity + ToolAssignment inline on that Cell.
DECLARE @Cell BIGINT, @Item BIGINT;
SELECT TOP 1 @Cell = x.CellId, @Item = x.ItemId
FROM (
    SELECT c.Id AS CellId, rt.ItemId AS ItemId
    FROM Location.Location c
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = c.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    CROSS APPLY Location.ufn_AncestorLocationIds(c.Id) anc
    INNER JOIN Parts.v_EffectiveItemLocation eil ON eil.LocationId = anc.LocationId
    INNER JOIN Parts.RouteTemplate rt ON rt.ItemId = eil.ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
    INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE lt.Code = N'Cell' AND oty.Code = N'DieCast' AND c.DeprecatedAt IS NULL
      AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = c.Id AND ta.ReleasedAt IS NULL)
) x
ORDER BY x.CellId, x.ItemId;

IF @Cell IS NULL OR @Item IS NULL
    RAISERROR(N'0045/020 fixture: no (Cell, ItemId) pair found with a published DieCast route and no active ToolAssignment -- BLOCKED.', 16, 1);

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DCO-TOOL', N'DieCastLot_Open test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, 1, @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@Tool, @Cell, SYSUTCDATETIME(), 1);

-- =============================================
-- Test 1: happy open
-- =============================================
DECLARE @R1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R1 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'200000201', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @s1 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @R1);
EXEC test.Assert_IsEqual @TestName=N'[Open] happy path Status 1', @Expected=N'1', @Actual=@s1;
DECLARE @newId BIGINT = (SELECT NewId FROM @R1);
DECLARE @openState NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@newId);
EXEC test.Assert_IsEqual @TestName=N'[Open] LOT status Open', @Expected=N'Open', @Actual=@openState;
DECLARE @pc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@newId);
EXEC test.Assert_IsEqual @TestName=N'[Open] PieceCount 0', @Expected=N'0', @Actual=@pc;
DECLARE @cav NVARCHAR(20) = (SELECT CAST(ToolCavityId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id=@newId);
DECLARE @cavExp NVARCHAR(20) = CAST(@Cavity AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[Open] cavity FK stamped', @Expected=@cavExp, @Actual=@cav;

-- Test 2: one-open-per-(tool,cavity) guard
DECLARE @R2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R2 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'200000202', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @s2 BIT = (SELECT Status FROM @R2); DECLARE @s2c BIT = CASE WHEN @s2=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Open] second open on same cavity rejected', @Condition=@s2c;
DECLARE @m2 NVARCHAR(500) = (SELECT Message FROM @R2);
EXEC test.Assert_Contains @TestName=N'[Open] guard message mentions open', @HaystackStr=@m2, @NeedleStr=N'open';

-- Test 3: invalid/duplicate LTT rejected (reuse 200000201: same LotName as
-- Test 1 AND same cavity -> rejects for either/both reasons)
DECLARE @R3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R3 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'200000201', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @s3 BIT = (SELECT Status FROM @R3); DECLARE @s3c BIT = CASE WHEN @s3=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Open] invalid/duplicate LTT rejected', @Condition=@s3c;

-- Test 4: opened LOT is NOT on the Trim WIP queue (excluded while Open)
DECLARE @Q TABLE (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50),
    ItemDescription NVARCHAR(1000), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(40),
    LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId=@Cell, @OperationTypeCode=N'TrimIn', @IncludeDescendants=1;
DECLARE @inQ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id=@newId);
EXEC test.Assert_IsEqual @TestName=N'[Open] Open LOT not on Trim queue', @Expected=N'0', @Actual=@inQ;
GO
-- cleanup (repeat block from top)
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName IN (N'200000201', N'200000202');
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName IN (N'200000201', N'200000202');
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName IN (N'200000201', N'200000202');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName IN (N'200000201', N'200000202');
DELETE FROM Lots.Lot WHERE LotName IN (N'200000201', N'200000202');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCO-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCO-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCO-TOOL';
GO
EXEC test.EndTestFile;
GO
