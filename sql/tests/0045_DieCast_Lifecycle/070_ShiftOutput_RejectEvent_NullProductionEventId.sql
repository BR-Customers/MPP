-- =============================================
-- File:         0045_DieCast_Lifecycle/070_ShiftOutput_RejectEvent_NullProductionEventId.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-05
-- FAT item:     #20 -- "Workorder.RejectEvent.ProductionEventId is all NULL --
--               should it be?"  DECISION (Jacques, 2026-08-05): NULL-BY-DESIGN
--               for die-cast additive scrap.
--
-- Description:  Pins the NULL-by-design contract for die-cast scrap. Migration
--               0045 (per-cavity lifecycle) removed die-cast's use of
--               Workorder.ProductionEvent entirely -- a "Record Shift Output"
--               event writes Workorder.DieCastContribution + additive
--               Workorder.RejectEvent rows, NOT a ProductionEvent. There is
--               therefore NO shift-output ProductionEventId to tie the scrap to,
--               so both the per-cavity additive scrap rows and the shot-loss
--               fan-out rows carry ProductionEventId = NULL (hardcoded in
--               R__Workorder_DieCastShiftOutput_Record.sql). RejectEvent's
--               ProductionEventId column is meaningful ONLY for the subtractive
--               downstream reject path (Workorder.RejectEvent_Record with a real
--               @ProductionEventId). This test is the regression guard for that
--               decision: if a future change starts stamping a non-NULL
--               ProductionEventId on die-cast additive scrap, these assertions
--               fail loudly. See notes/2026-08-05_diecast-rejectevent-
--               productioneventid-null-by-design.md for the full rationale.
--
--               FIXTURE: mirrors 030_ShiftOutput_Record.sql's proven recipe (a
--               clean MPP_MES_* reset seeds die-cast-routed, cell-eligible ITEMS
--               but NO Tools.ToolAssignment rows). (1) resolve a (Cell, ItemId)
--               pair via the ancestor-cascade eligibility rule where the Item has
--               a published route with a DieCast step and the Cell has no active
--               ToolAssignment; (2) build a Tool + Active ToolCavity +
--               ToolAssignment inline (distinct Tool code 'TEST-DCN-TOOL' so it
--               never collides with 030's 'TEST-DCB-TOOL' / 020's 'TEST-DCO-
--               TOOL'); (3) open the basket via Lots.DieCastLot_Open (never a
--               hand INSERT); (4) resolve or mint an open Oee.Shift, tracking
--               @ShiftCreatedByTest so cleanup never deletes a shift this test
--               did not create. LTT '303030401' is a distinct 9-digit external
--               LTT from 030's 303030301/302/303. Fixture + assertions + cleanup
--               share ONE batch (no GO) so the resolved locals stay in scope.
-- =============================================
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/070_ShiftOutput_RejectEvent_NullProductionEventId.sql';
GO
-- ---- cleanup (idempotent, FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'303030401');
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'303030401');
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName = N'303030401';
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'303030401';
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'303030401';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName = N'303030401';
DELETE FROM Lots.Lot WHERE LotName = N'303030401';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCN-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCN-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCN-TOOL';
GO

-- ---- fixture (mirror of 030): resolve (Cell, ItemId), build Tool + Active
-- ToolCavity + ToolAssignment inline, open an accumulator basket, resolve/mint
-- an open Shift. One batch (no GO) through cleanup so the locals stay in scope.
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
    RAISERROR(N'0045/070 fixture: no (Cell, ItemId) pair found with a published DieCast route and no active ToolAssignment -- BLOCKED.', 16, 1);

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DCN-TOOL', N'NullProductionEventId test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, 1, @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@Tool, @Cell, SYSUTCDATETIME(), 1);

DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity, @LotName=N'303030401', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot BIGINT = (SELECT NewId FROM @O);
IF @Lot IS NULL
    RAISERROR(N'0045/070 fixture: Lots.DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

-- resolve or mint an open shift (Oee.Shift singleton: at most one open DB-wide)
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0045/070 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

-- =============================================
-- Record a shift output that produces BOTH additive-scrap RejectEvent rows
-- (per-cavity scrapLines[]) AND a shot-loss fan-out RejectEvent row. Neither
-- path has a ProductionEvent, so both MUST land ProductionEventId = NULL.
-- =============================================
DECLARE @DefectCode BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
IF @DefectCode IS NULL
    RAISERROR(N'0045/070 fixture: no active Quality.DefectCode found -- BLOCKED.', 16, 1);

-- @Lines: 10 good + 3 additive scrap on the cavity's basket.
DECLARE @Lines NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20))
    + N',"pieceDelta":10,"scrapLines":[{"defectCodeId":' + CAST(@DefectCode AS NVARCHAR(20)) + N',"quantity":3}]}]';
-- @ShotLoss: 2 shot-loss rejects fanned across every open lot on the tool (just @Lot here).
DECLARE @ShotLoss NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@DefectCode AS NVARCHAR(20)) + N',"quantity":2}]';

DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@Lines,
    @ShotLossJson=@ShotLoss, @AppUserId=1, @TerminalLocationId=NULL;

DECLARE @ws NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[NullPE] shift output recorded, Status 1', @Expected=N'1', @Actual=@ws;

-- both reject rows exist (sanity: fixture actually produced the rows we assert about)
DECLARE @scrapCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId=@Lot AND Quantity=3);
EXEC test.Assert_IsEqual @TestName=N'[NullPE] per-cavity additive scrap RejectEvent present', @Expected=N'1', @Actual=@scrapCnt;
DECLARE @shotCnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId=@Lot AND Quantity=2);
EXEC test.Assert_IsEqual @TestName=N'[NullPE] shot-loss fan-out RejectEvent present', @Expected=N'1', @Actual=@shotCnt;

-- CORE ASSERTIONS (#20 NULL-by-design): every die-cast RejectEvent row carries
-- ProductionEventId = NULL.
DECLARE @scrapNull NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Workorder.RejectEvent WHERE LotId=@Lot AND Quantity=3 AND ProductionEventId IS NULL);
EXEC test.Assert_IsEqual @TestName=N'[NullPE] additive scrap RejectEvent has NULL ProductionEventId', @Expected=N'1', @Actual=@scrapNull;

DECLARE @shotNull NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Workorder.RejectEvent WHERE LotId=@Lot AND Quantity=2 AND ProductionEventId IS NULL);
EXEC test.Assert_IsEqual @TestName=N'[NullPE] shot-loss RejectEvent has NULL ProductionEventId', @Expected=N'1', @Actual=@shotNull;

DECLARE @nonNull NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Workorder.RejectEvent WHERE LotId=@Lot AND ProductionEventId IS NOT NULL);
EXEC test.Assert_IsEqual @TestName=N'[NullPE] no die-cast RejectEvent carries a ProductionEventId', @Expected=N'0', @Actual=@nonNull;

-- ---- cleanup (FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId = @Lot;
DELETE FROM Workorder.DieCastContribution WHERE LotId = @Lot OR (@ShiftCreatedByTest = 1 AND ShiftId = @Shift);
DELETE cl FROM Lots.LotGenealogyClosure cl WHERE cl.AncestorLotId = @Lot OR cl.DescendantLotId = @Lot;
DELETE m  FROM Lots.LotMovement m WHERE m.LotId = @Lot;
DELETE h  FROM Lots.LotStatusHistory h WHERE h.LotId = @Lot;
DELETE le FROM Lots.LotEventLog le WHERE le.LotId = @Lot;
DELETE FROM Lots.Lot WHERE Id = @Lot;
DELETE FROM Tools.ToolCavity WHERE ToolId = @Tool;
DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
IF @ShiftCreatedByTest = 1
    DELETE FROM Oee.Shift WHERE Id = @Shift;
GO
EXEC test.EndTestFile;
GO
