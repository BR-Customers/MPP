-- =============================================
-- File:         0022_PlantFloor_DieCast/050_Lot_GetShiftCavityTally.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Updated:      2026-07-29 (Task 7 / Die-Cast Per-Cavity Lifecycle plan)
-- Description:  Tests for Lots.Lot_GetShiftCavityTally (die-cast right-rail
--               shift tally).
--
--               2026-07-29 REWORK (v1.1 -> v1.2 double-count fix): this file
--               originally exercised RejectEvent_Record WITHOUT
--               @OperationTypeCode, which defaults to SUBTRACTIVE (@Additive=0)
--               -- pre-0042 behavior. The proc's v1.1 "PieceSum = PieceCount +
--               RejectedQty" add-back existed ONLY to recover the true as-cast
--               count from a subtractive decrement. Migration 0042 made
--               DIE-CAST scrap ADDITIVE (OperationType.ScrapIsAdditive=1 for
--               Code='DieCast') -- production callers (Workorder.
--               DieCastShiftOutput_Record) never decrement PieceCount for
--               die-cast scrap. The fixture below now passes
--               @OperationTypeCode=N'DieCast' to RejectEvent_Record so the
--               reject is recorded the way real die-cast scrap is (additive,
--               LOT PieceCount UNCHANGED at 10) -- matching v1.2 of the proc,
--               which drops the add-back entirely (PieceSum = plain
--               SUM(Lot.PieceCount)).
--
--               BEFORE (subtractive fixture + v1.1 add-back): LotA1.PieceCount
--               10 -3 (subtractive reject) = 7; tally added the 3 back ->
--               PieceSum 7+3+8(LotA2) = 18.
--               AFTER (additive fixture + v1.2 no-add-back): LotA1.PieceCount
--               stays 10 (additive reject never decrements); tally sums plain
--               PieceCount -> PieceSum 10+8(LotA2) = 18.
--               The numeric assertions are UNCHANGED (18/3/5/0/18) because the
--               two eras' arithmetic coincidentally lands on the same totals
--               here -- what changed is WHICH mechanism produces them (additive
--               fixture + no add-back, not subtractive fixture + add-back) and
--               why: die-cast scrap is additive today, so PieceCount alone is
--               already the true good count.
--
--               Also fixes a LATENT column-count bug: the #T temp table only
--               declared 6 columns (ToolCavityId..ShiftShots), but the proc has
--               returned 8 columns (+ShiftGoodTotal, +ShiftScrapTotal) since
--               2026-07-21 -- INSERT ... EXEC requires an exact column-count
--               match, so this file's tally assertions batch was silently
--               throwing Msg 213 and NONE of its 6 asserts were ever recorded
--               (confirmed empirically: test.TestResults had zero '%Tally%'
--               rows before this fix, despite an apparently-clean full-suite
--               run). The temp table now matches the proc's real 8-column
--               shape, and two new assertions cover the previously-untested
--               press-total columns.
--                 - one row per ACTIVE cavity (Closed excluded)
--                 - PieceSum = good pieces (die-cast scrap is additive; no add-back)
--                 - RejectSum = per-cavity scrapped quantity
--                 - ShiftShots = MAX(PieceSum) across cavities, same on every row
--                 - ShiftGoodTotal / ShiftScrapTotal = press-totals across ALL cavities
--               TEST-TLY-* fixture codes avoid the walkthrough's TEST-DC-*.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0022_PlantFloor_DieCast/050_Lot_GetShiftCavityTally.sql';
GO

-- ---- cleanup any prior fixtures (reverse FK order) ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%' OR l.LotName LIKE N'90000%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-TLY-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-TLY';
GO

-- ---- fixture: DefectCode + die cell + tool with cavities 1,2 Active / 3 Closed ----
DECLARE @DefAreaId BIGINT = (
    SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE l.DeprecatedAt IS NULL AND lt.Code = N'Area' ORDER BY l.Id);
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt)
VALUES (N'TEST-DEF-TLY', N'Tally test defect', NULL, 0, SYSUTCDATETIME());  -- OperationCategoryId NULL = plant-wide (AreaLocationId dropped in 0048)

DECLARE @DieCellId BIGINT;
SELECT TOP 1 @DieCellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Location.Location l ON l.Id = eil.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE lt.Code = N'Cell' AND eil.Source = N'Direct'
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-TLY-TOOL', N'Tally test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
DECLARE @CavClosed BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Closed');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 1, @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 2, @CavActive, SYSUTCDATETIME(), 1);
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolId, 3, @CavClosed, SYSUTCDATETIME(), 1);

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolId, @DieCellId, SYSUTCDATETIME(), 1);
GO

-- ---- fixture: 2 lots on cavity 1 (10 + 8 pc), 1 lot on cavity 2 (5 pc), reject 3 from the 10-pc lot ----
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
DECLARE @Cav1 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 1);
DECLARE @Cav2 BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @ToolId AND CavityNumber = 2);
DECLARE @DieCellId BIGINT = (SELECT CellLocationId FROM Tools.ToolAssignment WHERE ToolId = @ToolId AND ReleasedAt IS NULL);
DECLARE @DieItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.v_EffectiveItemLocation WHERE LocationId = @DieCellId AND Source = N'Direct');
DECLARE @OriginMfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @LotA1 BIGINT;
CREATE TABLE #L1 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L1 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 10, @ToolId = @ToolId, @ToolCavityId = @Cav1, @AppUserId = 1, @LotName = N'900000020';
SELECT @LotA1 = NewId FROM #L1; DROP TABLE #L1;

CREATE TABLE #L2 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L2 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 8, @ToolId = @ToolId, @ToolCavityId = @Cav1, @AppUserId = 1, @LotName = N'900000021';
DROP TABLE #L2;

CREATE TABLE #L3 (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO #L3 EXEC Lots.Lot_Create
    @ItemId = @DieItemId, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @DieCellId,
    @PieceCount = 5, @ToolId = @ToolId, @ToolCavityId = @Cav2, @AppUserId = 1, @LotName = N'900000022';
DROP TABLE #L3;

DECLARE @DefId BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'TEST-DEF-TLY');
DECLARE @RS BIT;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
-- @OperationTypeCode=N'DieCast' -> additive scrap (0042): LotA1.PieceCount stays
-- 10 (not decremented). Real die-cast reject recording always carries this
-- operation context (Workorder.DieCastShiftOutput_Record's scrap lines are
-- additive by construction; a raw RejectEvent_Record call in a die-cast
-- context must pass it explicitly to get the same behavior).
INSERT INTO #R EXEC Workorder.RejectEvent_Record @LotId = @LotA1, @DefectCodeId = @DefId, @Quantity = 3, @AppUserId = 1, @OperationTypeCode = N'DieCast';
SELECT @RS = Status FROM #R; DROP TABLE #R;
DECLARE @RSStr NVARCHAR(10) = CAST(@RS AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Tally] fixture reject accepted (control)', @Expected = N'1', @Actual = @RSStr;
GO

-- =============================================
-- Assertions on the tally
-- =============================================
DECLARE @ToolId BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
-- 8 columns matching the proc's real result shape (ShiftGoodTotal/ShiftScrapTotal
-- added 2026-07-21) -- INSERT ... EXEC requires an exact column-count match;
-- a 6-column temp table here silently threw Msg 213 and skipped every assert
-- in this batch (see file header).
CREATE TABLE #T (ToolCavityId BIGINT, CavityNumber INT, CavityLabel NVARCHAR(60), PieceSum INT, RejectSum INT, ShiftShots INT, ShiftGoodTotal INT, ShiftScrapTotal INT);
INSERT INTO #T EXEC Lots.Lot_GetShiftCavityTally @ToolId = @ToolId;

DECLARE @RowCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] one row per ACTIVE cavity (Closed excluded)', @Expected = N'2', @Actual = @RowCnt;

DECLARE @P1 NVARCHAR(10) = (SELECT CAST(PieceSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 1);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 1 PieceSum is good pieces 18 (10+8, additive scrap not double-counted)', @Expected = N'18', @Actual = @P1;

DECLARE @R1 NVARCHAR(10) = (SELECT CAST(RejectSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 1);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 1 RejectSum is 3', @Expected = N'3', @Actual = @R1;

DECLARE @P2 NVARCHAR(10) = (SELECT CAST(PieceSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 2);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 2 PieceSum is 5', @Expected = N'5', @Actual = @P2;

DECLARE @R2 NVARCHAR(10) = (SELECT CAST(RejectSum AS NVARCHAR(10)) FROM #T WHERE CavityNumber = 2);
EXEC test.Assert_IsEqual @TestName = N'[Tally] cavity 2 RejectSum is 0', @Expected = N'0', @Actual = @R2;

DECLARE @ShotsDistinct NVARCHAR(10) = (SELECT CAST(COUNT(DISTINCT ShiftShots) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftShots identical on every row', @Expected = N'1', @Actual = @ShotsDistinct;

DECLARE @Shots NVARCHAR(10) = (SELECT TOP 1 CAST(ShiftShots AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftShots is the busiest cavity good total (18)', @Expected = N'18', @Actual = @Shots;

-- press-totals across ALL cavities (identical on every row): good 18+5=23, scrap 3+0=3
DECLARE @GoodTotalDistinct NVARCHAR(10) = (SELECT CAST(COUNT(DISTINCT ShiftGoodTotal) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftGoodTotal identical on every row', @Expected = N'1', @Actual = @GoodTotalDistinct;
DECLARE @GoodTotal NVARCHAR(10) = (SELECT TOP 1 CAST(ShiftGoodTotal AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftGoodTotal is 23 (18+5 across both cavities)', @Expected = N'23', @Actual = @GoodTotal;
DECLARE @ScrapTotalDistinct NVARCHAR(10) = (SELECT CAST(COUNT(DISTINCT ShiftScrapTotal) AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftScrapTotal identical on every row', @Expected = N'1', @Actual = @ScrapTotalDistinct;
DECLARE @ScrapTotal NVARCHAR(10) = (SELECT TOP 1 CAST(ShiftScrapTotal AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Tally] ShiftScrapTotal is 3 (cavity 1 only)', @Expected = N'3', @Actual = @ScrapTotal;
DROP TABLE #T;
GO

-- ---- cleanup ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN (
    SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'MESL%' OR l.LotName LIKE N'90000%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'90000%';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-TLY-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-TLY-TOOL';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DEF-TLY';
GO

EXEC test.EndTestFile;
GO
