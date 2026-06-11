-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/030_Lot_Merge.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Tests for Lots.Lot_Merge (Phase 2 Task 3 / G2; spec section 4.2).
--               Asserts the single-row Status/Message/NewId return; that >=2
--               same-Item Good sources merge into a fresh-MESL output LOT with
--               NULL Tool/Cavity; both sources Closed; output PieceCount = SUM of
--               sources; the die-rank-compat gate (CanMix=1 succeeds, CanMix=0 /
--               no-row rejects, @SupervisorOverride=1 bypasses); and the B4 closure
--               ancestor-dedup (a shared ancestor across two sources collapses to
--               ONE (ancestor, output) closure row at MIN(depth)+1).
--
--               Fixtures use a NON-DieCast 'Received' origin on an eligible
--               (Item, Cell) pair with NO active ToolAssignment, so Lot_Create
--               needs no Tool/Cavity. The rank-compat tests need source LOTs that
--               carry a ToolId whose Tool.DieRankId differs; since the 'Received'
--               creation path leaves ToolId NULL, the test sets ToolId via a direct
--               UPDATE Lots.Lot after create (the rank rule keys off the source
--               LOT's ToolId only, not the origin-creation Tool validation). Test
--               Tools + DieRanks + DieRankCompatibility rows are created here and
--               removed in the FK-safe teardown. Unique 'P2-MERGE-' nothing in the
--               LotName (Lot_Create auto-mints MESL%), so DieRank/Tool fixtures use
--               a 'P2MRG' Code prefix to avoid colliding with other suites.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/030_Lot_Merge.sql';
GO

-- ---- shared fixtures ----
-- Track every LOT id + Tool/DieRank fixture id this suite touches so the FK-safe
-- cleanup at the end can sweep them all.
IF OBJECT_ID(N'tempdb..#MrgFix') IS NOT NULL DROP TABLE #MrgFix;
CREATE TABLE #MrgFix (Tag NVARCHAR(20) PRIMARY KEY, LotId BIGINT, LotName NVARCHAR(50));
IF OBJECT_ID(N'tempdb..#MrgTool') IS NOT NULL DROP TABLE #MrgTool;
CREATE TABLE #MrgTool (Tag NVARCHAR(20) PRIMARY KEY, ToolId BIGINT);
IF OBJECT_ID(N'tempdb..#MrgRank') IS NOT NULL DROP TABLE #MrgRank;
CREATE TABLE #MrgRank (Tag NVARCHAR(20) PRIMARY KEY, RankId BIGINT);
IF OBJECT_ID(N'tempdb..#MrgRankCompat') IS NOT NULL DROP TABLE #MrgRankCompat;
CREATE TABLE #MrgRankCompat (Id BIGINT);
GO

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- --- Die-rank + Tool fixtures (for the cross-Tool rank-compat tests) ---
-- Two ranks (RANKX, RANKY). One compatible pair (CanMix=1) and -- separately --
-- we test the no-row case by NOT seeding a compat row for a third rank pairing.
DECLARE @ToolType BIGINT = (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id);
DECLARE @ToolStatus BIGINT = (SELECT TOP 1 Id FROM Tools.ToolStatusCode ORDER BY Id);

INSERT INTO Tools.DieRank (Code, Name) VALUES (N'P2MRGX', N'P2 Merge Rank X');
INSERT INTO #MrgRank (Tag, RankId) VALUES (N'RANKX', SCOPE_IDENTITY());
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'P2MRGY', N'P2 Merge Rank Y');
INSERT INTO #MrgRank (Tag, RankId) VALUES (N'RANKY', SCOPE_IDENTITY());

DECLARE @RankX BIGINT = (SELECT RankId FROM #MrgRank WHERE Tag = N'RANKX');
DECLARE @RankY BIGINT = (SELECT RankId FROM #MrgRank WHERE Tag = N'RANKY');

-- Compatible pair (X,Y) canonical (smaller id first), CanMix=1.
DECLARE @LoR BIGINT = CASE WHEN @RankX <= @RankY THEN @RankX ELSE @RankY END;
DECLARE @HiR BIGINT = CASE WHEN @RankX <= @RankY THEN @RankY ELSE @RankX END;
INSERT INTO Tools.DieRankCompatibility (RankAId, RankBId, CanMix) VALUES (@LoR, @HiR, 1);
INSERT INTO #MrgRankCompat (Id) VALUES (SCOPE_IDENTITY());

-- Tools: TOOL_X (rank X), TOOL_Y (rank Y, compatible w/ X), TOOL_Z (rank X too --
-- same rank as TOOL_X so same-Tool/same-rank merges pass trivially), and an
-- INCOMPAT pair we drive by making a tool with rank Y vs a tool with rank X but
-- REMOVING the compat row at test time isn't possible mid-suite, so instead the
-- incompat case uses TOOL_X (rankX) vs TOOL_NR (rank with NO compat row).
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'P2MRGN', N'P2 Merge Rank NoRow');
INSERT INTO #MrgRank (Tag, RankId) VALUES (N'RANKN', SCOPE_IDENTITY());
DECLARE @RankN BIGINT = (SELECT RankId FROM #MrgRank WHERE Tag = N'RANKN');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES (@ToolType, N'P2MRG_TX', N'P2 Merge Tool X', @RankX, @ToolStatus, 1);
INSERT INTO #MrgTool (Tag, ToolId) VALUES (N'TOOL_X', SCOPE_IDENTITY());
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES (@ToolType, N'P2MRG_TX2', N'P2 Merge Tool X2', @RankX, @ToolStatus, 1);
INSERT INTO #MrgTool (Tag, ToolId) VALUES (N'TOOL_X2', SCOPE_IDENTITY());
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES (@ToolType, N'P2MRG_TY', N'P2 Merge Tool Y', @RankY, @ToolStatus, 1);
INSERT INTO #MrgTool (Tag, ToolId) VALUES (N'TOOL_Y', SCOPE_IDENTITY());
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES (@ToolType, N'P2MRG_TN', N'P2 Merge Tool NoRow', @RankN, @ToolStatus, 1);
INSERT INTO #MrgTool (Tag, ToolId) VALUES (N'TOOL_N', SCOPE_IDENTITY());

-- Helper to create a Good 'Received' source LOT and tag it.
-- (Inline below per fixture; no UDF in the test harness.)

-- A1, A2: same Item, same Tool (TOOL_X) -> simple success.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 30, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'A1', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 40, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'A2', NewId, MintedLotName FROM @cr;

-- C1 (TOOL_X / rankX), C2 (TOOL_Y / rankY) -> cross-Tool, compatible pair.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 20, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'C1', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 25, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'C2', NewId, MintedLotName FROM @cr;

-- I1 (TOOL_X / rankX), I2 (TOOL_N / rankN, no compat row) -> incompatible.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 15, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'I1', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 18, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'I2', NewId, MintedLotName FROM @cr;

-- O1 (TOOL_X / rankX), O2 (TOOL_N / rankN) -> incompatible, but override path.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 11, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'O1', NewId, MintedLotName FROM @cr;
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @CellId,
    @PieceCount = 12, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'O2', NewId, MintedLotName FROM @cr;

-- Wire ToolIds onto the source LOTs (rank rule keys off Lots.Lot.ToolId).
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_X')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'A1');
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_X')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'A2');
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_X')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'C1');
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_Y')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'C2');
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_X')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'I1');
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_N')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'I2');
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_X')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'O1');
UPDATE Lots.Lot SET ToolId = (SELECT ToolId FROM #MrgTool WHERE Tag = N'TOOL_N')  WHERE Id = (SELECT LotId FROM #MrgFix WHERE Tag = N'O2');
GO

-- =============================================
-- Test 1: same-Item same-Tool merge succeeds. Status=1; output exists with NULL
--         ToolId/ToolCavityId + fresh MESL name; both sources Closed; output
--         PieceCount = 30 + 40 = 70.
-- =============================================
DECLARE @A1 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'A1');
DECLARE @A2 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'A2');
DECLARE @ItemId BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @A1);
DECLARE @OutLoc BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @A1);

DECLARE @jsonA NVARCHAR(MAX) = N'[' + CAST(@A1 AS NVARCHAR(20)) + N',' + CAST(@A2 AS NVARCHAR(20)) + N']';

DECLARE @rA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rA EXEC Lots.Lot_Merge
    @SourceLotIdsJson = @jsonA, @OutputItemId = @ItemId, @OutputLocationId = @OutLoc, @AppUserId = 1;

DECLARE @okA BIT = (SELECT Status FROM @rA);
EXEC test.Assert_IsTrue @TestName = N'[Merge] same-Item same-Tool succeeds', @Condition = @okA;

DECLARE @OutId BIGINT = (SELECT NewId FROM @rA);
INSERT INTO #MrgFix (Tag, LotId, LotName)
    SELECT N'OUT_A', @OutId, (SELECT LotName FROM Lots.Lot WHERE Id = @OutId);

DECLARE @outIdStr NVARCHAR(20) = CAST(@OutId AS NVARCHAR(20));
EXEC test.Assert_IsNotNull @TestName = N'[Merge] output NewId returned', @Value = @outIdStr;

DECLARE @outTool NVARCHAR(20) = CAST((SELECT ToolId FROM Lots.Lot WHERE Id = @OutId) AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[Merge] output ToolId is NULL', @Value = @outTool;
DECLARE @outCav NVARCHAR(20) = CAST((SELECT ToolCavityId FROM Lots.Lot WHERE Id = @OutId) AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[Merge] output ToolCavityId is NULL', @Value = @outCav;

DECLARE @outName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @OutId);
EXEC test.Assert_Contains @TestName = N'[Merge] output carries a fresh MESL name',
    @HaystackStr = @outName, @NeedleStr = N'MESL';

DECLARE @outPc NVARCHAR(20) = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @OutId) AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Merge] output PieceCount = sum of sources (70)',
    @Expected = N'70', @Actual = @outPc;

DECLARE @s1 NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @A1);
EXEC test.Assert_IsEqual @TestName = N'[Merge] source 1 Closed', @Expected = N'Closed', @Actual = @s1;
DECLARE @s2 NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @A2);
EXEC test.Assert_IsEqual @TestName = N'[Merge] source 2 Closed', @Expected = N'Closed', @Actual = @s2;

-- Merge genealogy edges: one per source, RelationshipTypeId=2.
DECLARE @medges INT = (SELECT COUNT(*) FROM Lots.LotGenealogy WHERE ChildLotId = @OutId AND RelationshipTypeId = 2);
EXEC test.Assert_RowCount @TestName = N'[Merge] two Merge genealogy edges recorded',
    @ExpectedCount = 2, @ActualCount = @medges;

-- Closure: each source is an ancestor of the output at depth 1 (their self-rows).
DECLARE @cd1 INT = (SELECT Depth FROM Lots.LotGenealogyClosure WHERE AncestorLotId = @A1 AND DescendantLotId = @OutId);
DECLARE @cd1Str NVARCHAR(20) = CAST(@cd1 AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Merge] source->output closure depth 1',
    @Expected = N'1', @Actual = @cd1Str;
GO

-- =============================================
-- Test 2: cross-Tool rank-compat=1 succeeds (C1 rankX, C2 rankY; (X,Y) CanMix=1).
-- =============================================
DECLARE @C1 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'C1');
DECLARE @C2 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'C2');
DECLARE @ItemC BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @C1);
DECLARE @LocC BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @C1);
DECLARE @jsonC NVARCHAR(MAX) = N'[' + CAST(@C1 AS NVARCHAR(20)) + N',' + CAST(@C2 AS NVARCHAR(20)) + N']';

DECLARE @rC TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rC EXEC Lots.Lot_Merge
    @SourceLotIdsJson = @jsonC, @OutputItemId = @ItemC, @OutputLocationId = @LocC, @AppUserId = 1;

DECLARE @okC BIT = (SELECT Status FROM @rC);
EXEC test.Assert_IsTrue @TestName = N'[Merge] cross-Tool rank-compat=1 succeeds', @Condition = @okC;
INSERT INTO #MrgFix (Tag, LotId, LotName)
    SELECT N'OUT_C', NewId, (SELECT LotName FROM Lots.Lot WHERE Id = (SELECT NewId FROM @rC)) FROM @rC;
GO

-- =============================================
-- Test 3: cross-Tool rank-compat=0 (no compat row) rejects with @SupervisorOverride=0.
-- =============================================
DECLARE @I1 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'I1');
DECLARE @I2 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'I2');
DECLARE @ItemI BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @I1);
DECLARE @LocI BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @I1);
DECLARE @jsonI NVARCHAR(MAX) = N'[' + CAST(@I1 AS NVARCHAR(20)) + N',' + CAST(@I2 AS NVARCHAR(20)) + N']';

DECLARE @rI TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rI EXEC Lots.Lot_Merge
    @SourceLotIdsJson = @jsonI, @OutputItemId = @ItemI, @OutputLocationId = @LocI, @AppUserId = 1, @SupervisorOverride = 0;

DECLARE @sI BIT = (SELECT Status FROM @rI);
DECLARE @sICond BIT = CASE WHEN @sI = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Merge] cross-Tool rank-compat=0 rejected (Status=0)', @Condition = @sICond;

DECLARE @niI NVARCHAR(20) = CAST((SELECT NewId FROM @rI) AS NVARCHAR(20));
EXEC test.Assert_IsNull @TestName = N'[Merge] rejected merge returns NULL NewId', @Value = @niI;

-- Sources stay Good (not closed) on rejection.
DECLARE @sIStat NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @I1);
EXEC test.Assert_IsEqual @TestName = N'[Merge] source stays Good on rejection', @Expected = N'Good', @Actual = @sIStat;
GO

-- =============================================
-- Test 4: supervisor override bypasses the rank check (same incompatible pair).
-- =============================================
DECLARE @O1 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'O1');
DECLARE @O2 BIGINT = (SELECT LotId FROM #MrgFix WHERE Tag = N'O2');
DECLARE @ItemO BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @O1);
DECLARE @LocO BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @O1);
DECLARE @jsonO NVARCHAR(MAX) = N'[' + CAST(@O1 AS NVARCHAR(20)) + N',' + CAST(@O2 AS NVARCHAR(20)) + N']';

DECLARE @rO TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rO EXEC Lots.Lot_Merge
    @SourceLotIdsJson = @jsonO, @OutputItemId = @ItemO, @OutputLocationId = @LocO, @AppUserId = 1, @SupervisorOverride = 1;

DECLARE @okO BIT = (SELECT Status FROM @rO);
EXEC test.Assert_IsTrue @TestName = N'[Merge] supervisor override bypasses rank check', @Condition = @okO;
INSERT INTO #MrgFix (Tag, LotId, LotName)
    SELECT N'OUT_O', NewId, (SELECT LotName FROM Lots.Lot WHERE Id = (SELECT NewId FROM @rO)) FROM @rO;
GO

-- =============================================
-- Test 5: shared-ancestor dedup. Split a grandparent into two LOTs (S1, S2),
--         then merge S1+S2. The grandparent is a common ancestor of both sources;
--         the dedup INSERT must produce exactly ONE (grandparent, output) closure
--         row at MIN(depth)+1. S1/S2 are direct children of GP (depth 1 from GP),
--         so MIN(1)+1 = 2.
-- =============================================
DECLARE @OriginRcv2 BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId2 BIGINT, @CellId2 BIGINT;
SELECT TOP 1 @ItemId2 = eil.ItemId, @CellId2 = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr2 EXEC Lots.Lot_Create
    @ItemId = @ItemId2, @LotOriginTypeId = @OriginRcv2, @CurrentLocationId = @CellId2,
    @PieceCount = 60, @AppUserId = 1;
DECLARE @GpId BIGINT = (SELECT NewId FROM @cr2);
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'GP', NewId, MintedLotName FROM @cr2;

-- Split GP into 2 children of 30 each (residual 0 -> GP Closed). These are the
-- merge sources, both sharing GP as ancestor.
DECLARE @jsonSplit NVARCHAR(MAX) =
    N'[{"pieceCount":30,"currentLocationId":' + CAST(@CellId2 AS NVARCHAR(20)) + N'},'
  + N'{"pieceCount":30,"currentLocationId":' + CAST(@CellId2 AS NVARCHAR(20)) + N'}]';
CREATE TABLE #sp (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO #sp EXEC Lots.Lot_Split
    @ParentLotId = @GpId, @ChildrenJson = @jsonSplit, @AppUserId = 1;
INSERT INTO #MrgFix (Tag, LotId, LotName)
    SELECT N'S' + CAST(ROW_NUMBER() OVER (ORDER BY ChildLotId) AS NVARCHAR(4)),
           ChildLotId, ChildLotName
    FROM #sp WHERE ChildLotId IS NOT NULL;

DECLARE @S1 BIGINT = (SELECT MIN(ChildLotId) FROM #sp);
DECLARE @S2 BIGINT = (SELECT MAX(ChildLotId) FROM #sp);
DROP TABLE #sp;

-- Merge S1 + S2.
DECLARE @ItemS BIGINT = (SELECT ItemId FROM Lots.Lot WHERE Id = @S1);
DECLARE @LocS BIGINT = (SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @S1);
DECLARE @jsonS NVARCHAR(MAX) = N'[' + CAST(@S1 AS NVARCHAR(20)) + N',' + CAST(@S2 AS NVARCHAR(20)) + N']';

DECLARE @rS TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rS EXEC Lots.Lot_Merge
    @SourceLotIdsJson = @jsonS, @OutputItemId = @ItemS, @OutputLocationId = @LocS, @AppUserId = 1;

DECLARE @okS BIT = (SELECT Status FROM @rS);
EXEC test.Assert_IsTrue @TestName = N'[Merge] shared-ancestor merge succeeds', @Condition = @okS;
DECLARE @OutS BIGINT = (SELECT NewId FROM @rS);
INSERT INTO #MrgFix (Tag, LotId, LotName)
    SELECT N'OUT_S', @OutS, (SELECT LotName FROM Lots.Lot WHERE Id = @OutS);

-- Exactly ONE closure row (GP, output).
DECLARE @gpRows INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure
                       WHERE AncestorLotId = @GpId AND DescendantLotId = @OutS);
EXEC test.Assert_RowCount @TestName = N'[Merge] shared ancestor deduped to one closure row',
    @ExpectedCount = 1, @ActualCount = @gpRows;

-- That single row is at MIN(depth from GP to source)+1 = 1+1 = 2.
DECLARE @gpDepth INT = (SELECT Depth FROM Lots.LotGenealogyClosure
                        WHERE AncestorLotId = @GpId AND DescendantLotId = @OutS);
DECLARE @gpDepthStr NVARCHAR(20) = CAST(@gpDepth AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName = N'[Merge] deduped closure row at MIN depth (2)',
    @Expected = N'2', @Actual = @gpDepthStr;
GO

-- =============================================
-- Test 6: <2 sources rejected; mixed-Item rejected; non-Good source rejected.
-- =============================================
-- 6a: single source rejected.
DECLARE @OriginRcv3 BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @ItemId3 BIGINT, @CellId3 BIGINT;
SELECT TOP 1 @ItemId3 = eil.ItemId, @CellId3 = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cr3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr3 EXEC Lots.Lot_Create
    @ItemId = @ItemId3, @LotOriginTypeId = @OriginRcv3, @CurrentLocationId = @CellId3,
    @PieceCount = 5, @AppUserId = 1;
DECLARE @Solo BIGINT = (SELECT NewId FROM @cr3);
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'SOLO', NewId, MintedLotName FROM @cr3;

DECLARE @jsonSolo NVARCHAR(MAX) = N'[' + CAST(@Solo AS NVARCHAR(20)) + N']';
DECLARE @rSolo TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rSolo EXEC Lots.Lot_Merge
    @SourceLotIdsJson = @jsonSolo, @OutputItemId = @ItemId3, @OutputLocationId = @CellId3, @AppUserId = 1;
DECLARE @sSolo BIT = (SELECT Status FROM @rSolo);
DECLARE @sSoloCond BIT = CASE WHEN @sSolo = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Merge] <2 sources rejected (Status=0)', @Condition = @sSoloCond;

-- 6b: mixed Item rejected. Create a source on a DIFFERENT eligible item.
DECLARE @ItemB BIGINT, @CellB BIGINT;
SELECT TOP 1 @ItemB = eil.ItemId, @CellB = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE eil.ItemId <> @ItemId3
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

IF @ItemB IS NOT NULL
BEGIN
    DECLARE @crB TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
    INSERT INTO @crB EXEC Lots.Lot_Create
        @ItemId = @ItemB, @LotOriginTypeId = @OriginRcv3, @CurrentLocationId = @CellB,
        @PieceCount = 7, @AppUserId = 1;
    DECLARE @MixB BIGINT = (SELECT NewId FROM @crB);
    INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'MIXB', NewId, MintedLotName FROM @crB;

    -- Re-use SOLO (Item @ItemId3) + MIXB (Item @ItemB): different items.
    DECLARE @jsonMix NVARCHAR(MAX) = N'[' + CAST(@Solo AS NVARCHAR(20)) + N',' + CAST(@MixB AS NVARCHAR(20)) + N']';
    DECLARE @rMix TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @rMix EXEC Lots.Lot_Merge
        @SourceLotIdsJson = @jsonMix, @OutputItemId = @ItemId3, @OutputLocationId = @CellId3, @AppUserId = 1;
    DECLARE @sMix BIT = (SELECT Status FROM @rMix);
    DECLARE @sMixCond BIT = CASE WHEN @sMix = 0 THEN 1 ELSE 0 END;
    EXEC test.Assert_IsTrue @TestName = N'[Merge] mixed-Item sources rejected (Status=0)', @Condition = @sMixCond;
END

-- 6c: non-Good source rejected. Create two sources, force one to Hold.
DECLARE @crN1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @crN1 EXEC Lots.Lot_Create
    @ItemId = @ItemId3, @LotOriginTypeId = @OriginRcv3, @CurrentLocationId = @CellId3,
    @PieceCount = 8, @AppUserId = 1;
DECLARE @N1 BIGINT = (SELECT NewId FROM @crN1);
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'N1', NewId, MintedLotName FROM @crN1;

DECLARE @crN2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @crN2 EXEC Lots.Lot_Create
    @ItemId = @ItemId3, @LotOriginTypeId = @OriginRcv3, @CurrentLocationId = @CellId3,
    @PieceCount = 9, @AppUserId = 1;
DECLARE @N2 BIGINT = (SELECT NewId FROM @crN2);
INSERT INTO #MrgFix (Tag, LotId, LotName) SELECT N'N2', NewId, MintedLotName FROM @crN2;

-- Force N2 to Hold (BlocksProduction=1) directly.
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold') WHERE Id = @N2;

DECLARE @jsonN NVARCHAR(MAX) = N'[' + CAST(@N1 AS NVARCHAR(20)) + N',' + CAST(@N2 AS NVARCHAR(20)) + N']';
DECLARE @rN TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rN EXEC Lots.Lot_Merge
    @SourceLotIdsJson = @jsonN, @OutputItemId = @ItemId3, @OutputLocationId = @CellId3, @AppUserId = 1;
DECLARE @sN BIT = (SELECT Status FROM @rN);
DECLARE @sNCond BIT = CASE WHEN @sN = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Merge] non-Good source rejected (Status=0)', @Condition = @sNCond;
GO

-- ---- cleanup (FK-safe: child rows -> LOTs; descendants before ancestors) ----
DECLARE @ids TABLE (Id BIGINT);
INSERT INTO @ids SELECT LotId FROM #MrgFix WHERE LotId IS NOT NULL;

DELETE FROM Lots.LotGenealogy
    WHERE ParentLotId IN (SELECT Id FROM @ids) OR ChildLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotGenealogyClosure
    WHERE AncestorLotId IN (SELECT Id FROM @ids) OR DescendantLotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM @ids);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM @ids);

-- Clear ToolId pointers (FK to Tools.Tool fixtures) before deleting the LOTs/Tools.
UPDATE Lots.Lot SET ToolId = NULL WHERE Id IN (SELECT Id FROM @ids);
-- Break self-referencing ParentLotId FK before deleting LOT rows.
UPDATE Lots.Lot SET ParentLotId = NULL WHERE Id IN (SELECT Id FROM @ids);
DELETE FROM Lots.Lot WHERE Id IN (SELECT Id FROM @ids);

-- Tool / DieRank fixtures.
DELETE FROM Tools.DieRankCompatibility WHERE Id IN (SELECT Id FROM #MrgRankCompat);
DELETE FROM Tools.Tool WHERE Id IN (SELECT ToolId FROM #MrgTool);
DELETE FROM Tools.DieRank WHERE Id IN (SELECT RankId FROM #MrgRank);

IF OBJECT_ID(N'tempdb..#MrgFix') IS NOT NULL DROP TABLE #MrgFix;
IF OBJECT_ID(N'tempdb..#MrgTool') IS NOT NULL DROP TABLE #MrgTool;
IF OBJECT_ID(N'tempdb..#MrgRank') IS NOT NULL DROP TABLE #MrgRank;
IF OBJECT_ID(N'tempdb..#MrgRankCompat') IS NOT NULL DROP TABLE #MrgRankCompat;
GO

EXEC test.EndTestFile;
GO
