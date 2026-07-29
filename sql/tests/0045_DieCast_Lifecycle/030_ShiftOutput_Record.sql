-- =============================================
-- File:         0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-29
-- Description:  Die-Cast Per-Cavity Lifecycle plan, Phase 2. SHARED file:
--               Task 3 (this pass) covers the READ half --
--               Workorder.DieCast_GetShiftOutputBreakdown, a pure-computation
--               proc that proposes a per-cavity-lot good-piece split for a
--               shift's gross shot count. Task 4 (a later pass) will APPEND
--               its write-half assertions -- Workorder.DieCastShiftOutput_Record
--               -- below the "PART B" marker, BEFORE EXEC test.EndTestFile, and
--               will reuse this same fixture (the @Lot/@Shift/@Tool/@Cavity/
--               @Item/@Cell locals are kept alive in ONE batch -- no GO --
--               spanning fixture + Part A + Part B + cleanup, since a GO would
--               scope out the local variables before Part B could reuse them).
--
--               FIXTURE NOTE (mirrors 020_DieCastLot_Open.sql, which itself
--               deviates from its own brief for the identical reason): a clean
--               MPP_MES_Test reset runs every sql/seeds/*.sql file, so
--               die-cast-routed, cell-eligible ITEMS exist -- but NO
--               Tools.ToolAssignment rows exist (mounts live only in
--               seed_demo/seed_jp, which is skipped on reset). This task's own
--               brief draft assumes a pre-existing ToolAssignment/ToolCavity,
--               which resolves to NULL on a clean reset. Recipe used instead,
--               copied verbatim from 020's proven fixture: (1) resolve a
--               (Cell, ItemId) pair via the ANCESTOR-CASCADE eligibility rule
--               (Parts.v_EffectiveItemLocation joined through
--               Location.ufn_AncestorLocationIds) where the Item has a
--               published route with a DieCast step and the Cell has no active
--               ToolAssignment; (2) build a Tool + Active ToolCavity +
--               ToolAssignment inline on that Cell (distinct Tool code
--               'TEST-DCB-TOOL' to avoid colliding with 020's 'TEST-DCO-TOOL');
--               (3) open the basket via Lots.DieCastLot_Open (never a hand
--               INSERT) so LotStatus/PieceCount/MaxPieceCount/ToolCavityId are
--               stamped exactly as production code would; (4) resolve or mint
--               an Oee.Shift, tracking @ShiftCreatedByTest so cleanup never
--               deletes a shift this test did not create.
--
--               LTT '303030301' is a distinct 9-digit external LTT (per
--               Lots.ufn_IsValidExternalLtt) from 020's 200000201/200000202.
-- =============================================
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql';
GO
-- ---- cleanup (idempotent, FK-safe, reverse order) ----
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'303030301');
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName = N'303030301';
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'303030301';
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'303030301';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName = N'303030301';
DELETE FROM Lots.Lot WHERE LotName = N'303030301';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCB-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCB-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCB-TOOL';
GO

-- ---- fixture: resolve (Cell, ItemId) via ancestor-cascade eligibility + a
-- published DieCast-route step, with NO active ToolAssignment on the Cell;
-- build Tool + Active ToolCavity + ToolAssignment inline on that Cell; open
-- an accumulator basket via Lots.DieCastLot_Open; resolve/mint an open Shift.
-- Fixture + Part A + Part B (appended later) + cleanup all share ONE batch
-- (no GO) so the resolved locals stay in scope end to end.
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
    RAISERROR(N'0045/030 fixture: no (Cell, ItemId) pair found with a published DieCast route and no active ToolAssignment -- BLOCKED.', 16, 1);

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DCB-TOOL', N'ShiftOutputBreakdown test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, 1, @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@Tool, @Cell, SYSUTCDATETIME(), 1);

-- open the accumulator basket through the proc under production behavior (not a hand INSERT)
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'303030301', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot BIGINT = (SELECT NewId FROM @O);
IF @Lot IS NULL
    RAISERROR(N'0045/030 fixture: Lots.DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

-- resolve or mint an open shift; track whether WE created it so cleanup never
-- deletes a shift this test did not create. Oee.Shift carries a singleton
-- constraint (UIX_Shift_SingleOpen: unique on ActualEnd WHERE ActualEnd IS
-- NULL) -- at most one open shift may exist DB-wide -- which is exactly why
-- the recipe resolves-or-creates rather than always inserting.
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    -- a clean reset seeds zero Oee.ShiftSchedule rows (mirrors 0026's own
    -- test fixtures, which always mint their own schedule for the same
    -- reason) -- resolve one or mint a throwaway if none exists yet.
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0045/030 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

-- =============================================
-- Part A: Workorder.DieCast_GetShiftOutputBreakdown (read)
-- =============================================
DECLARE @B TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT);
INSERT INTO @B EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId=@Tool, @ShiftId=@Shift, @GrossShots=100;

DECLARE @rowCount NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @B);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] one row for the tool''s single cavity', @Expected=N'1', @Actual=@rowCount;

DECLARE @row NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot AND IsOpen=1);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] open basket row present', @Expected=N'1', @Actual=@row;

DECLARE @prop NVARCHAR(10) = (SELECT CAST(ProposedGood AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] proposed good = gross (no prior, no scrap yet)', @Expected=N'100', @Actual=@prop;

DECLARE @prior NVARCHAR(10) = (SELECT CAST(PriorGoodThisShift AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] prior good = 0 (nothing recorded yet)', @Expected=N'0', @Actual=@prior;

-- ===== PART B (Task 4: DieCastShiftOutput_Record) APPENDS BELOW, BEFORE EndTestFile =====

-- ---- cleanup (FK-safe, reverse order) ----
DELETE FROM Workorder.DieCastContribution WHERE LotId = @Lot OR (@ShiftCreatedByTest = 1 AND ShiftId = @Shift);
DELETE cl FROM Lots.LotGenealogyClosure cl WHERE cl.AncestorLotId = @Lot OR cl.DescendantLotId = @Lot;
DELETE m  FROM Lots.LotMovement m WHERE m.LotId = @Lot;
DELETE h  FROM Lots.LotStatusHistory h WHERE h.LotId = @Lot;
DELETE le FROM Lots.LotEventLog le WHERE le.LotId = @Lot;
DELETE FROM Lots.Lot WHERE Id = @Lot;
DELETE FROM Tools.ToolCavity WHERE Id = @Cavity;
DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
IF @ShiftCreatedByTest = 1
    DELETE FROM Oee.Shift WHERE Id = @Shift;
GO
EXEC test.EndTestFile;
GO
