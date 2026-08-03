-- =============================================
-- File:         0045_DieCast_Lifecycle/050_Void.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-29
-- Description:  Tests for Lots.DieCastLot_Void (Die-Cast Per-Cavity Lifecycle
--               plan, Task 6 / Phase 3): voids an EMPTY open accumulator
--               basket (Open -> Scrap); a non-empty basket must be rejected
--               (release it instead).
--
--               FIXTURE NOTE (mirrors 020/030/040's identical deviation): a
--               clean MPP_MES_Test reset runs every sql/seeds/*.sql file, so
--               die-cast-routed, cell-eligible ITEMS exist -- but NO
--               Tools.ToolAssignment rows exist. Recipe: resolve a
--               (Cell, ItemId) pair via the ancestor-cascade eligibility rule
--               + a published DieCast-route step, with no active
--               ToolAssignment on the Cell; build a Tool + TWO Active
--               ToolCavities + a ToolAssignment inline (distinct tool code
--               'TEST-DCV-TOOL'); open baskets via Lots.DieCastLot_Open.
--
--               LTTs: '505050501' (Test 1, empty basket voided),
--               '505050502' (Test 2, non-empty basket rejected -- credited 10
--               good via Workorder.DieCastShiftOutput_Record before the void
--               attempt) -- distinct 9-digit externals
--               (Lots.ufn_IsValidExternalLtt) from 020/030/040's ranges.
-- =============================================
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/050_Void.sql';
GO
-- ---- cleanup (idempotent, FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'505050501', N'505050502'));
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'505050501', N'505050502'));
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName IN (N'505050501', N'505050502');
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName IN (N'505050501', N'505050502');
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName IN (N'505050501', N'505050502');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName IN (N'505050501', N'505050502');
DELETE FROM Lots.Lot WHERE LotName IN (N'505050501', N'505050502');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCV-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCV-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCV-TOOL';
GO

-- ---- fixture: resolve (Cell, ItemId) via ancestor-cascade eligibility + a
-- published DieCast-route step, with NO active ToolAssignment on the Cell;
-- build Tool + TWO Active ToolCavities + a ToolAssignment inline on that Cell;
-- resolve/mint an open Shift (needed for Test 2's contribution). Fixture +
-- all tests + cleanup share ONE batch (no GO) so the resolved locals stay in
-- scope end to end.
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
    RAISERROR(N'0045/050 fixture: no (Cell, ItemId) pair found with a published DieCast route and no active ToolAssignment -- BLOCKED.', 16, 1);

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DCV-TOOL', N'DieCastLot_Void test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, 1, @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, 2, @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity2 BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@Tool, @Cell, SYSUTCDATETIME(), 1);

-- resolve or mint an open shift (mirrors 030/040's identical recipe)
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0045/050 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

-- =============================================
-- Test 1: void an EMPTY open basket -> Status 1, Open->Scrap
-- =============================================
DECLARE @O1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O1 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity1, @LotName=N'505050501', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot BIGINT = (SELECT NewId FROM @O1);
IF @Lot IS NULL
    RAISERROR(N'0045/050 Test 1 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @V TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @V EXEC Lots.DieCastLot_Void @LotId=@Lot, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @vs NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @V);
EXEC test.Assert_IsEqual @TestName=N'[Void] empty basket voided Status 1', @Expected=N'1', @Actual=@vs;
DECLARE @vstate NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Void] Open->Scrap', @Expected=N'Scrap', @Actual=@vstate;

-- =============================================
-- Test 2: void a NON-empty basket rejected (must release instead)
-- =============================================
DECLARE @O2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O2 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity2, @LotName=N'505050502', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot2 BIGINT = (SELECT NewId FROM @O2);
IF @Lot2 IS NULL
    RAISERROR(N'0045/050 Test 2 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @Lines2 NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot2 AS NVARCHAR(20)) + N',"pieceDelta":10,"scrapLines":null}]';
DECLARE @W2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W2 EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@Lines2,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @w2s NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W2);
EXEC test.Assert_IsEqual @TestName=N'[Void] fixture: 10pc contributed, Status 1', @Expected=N'1', @Actual=@w2s;

DECLARE @VoidResult2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @VoidResult2 EXEC Lots.DieCastLot_Void @LotId=@Lot2, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @v2Status BIT = (SELECT Status FROM @VoidResult2); DECLARE @v2Cond BIT = CASE WHEN @v2Status=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Void] non-empty basket cannot be voided', @Condition=@v2Cond;

-- ---- cleanup (FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (@Lot, @Lot2);
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (@Lot, @Lot2) OR (@ShiftCreatedByTest = 1 AND ShiftId = @Shift);
DELETE cl FROM Lots.LotGenealogyClosure cl WHERE cl.AncestorLotId IN (@Lot, @Lot2) OR cl.DescendantLotId IN (@Lot, @Lot2);
DELETE m  FROM Lots.LotMovement m WHERE m.LotId IN (@Lot, @Lot2);
DELETE h  FROM Lots.LotStatusHistory h WHERE h.LotId IN (@Lot, @Lot2);
DELETE le FROM Lots.LotEventLog le WHERE le.LotId IN (@Lot, @Lot2);
DELETE FROM Lots.Lot WHERE Id IN (@Lot, @Lot2);
DELETE FROM Tools.ToolCavity WHERE ToolId = @Tool;
DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
IF @ShiftCreatedByTest = 1
    DELETE FROM Oee.Shift WHERE Id = @Shift;
GO
EXEC test.EndTestFile;
GO
