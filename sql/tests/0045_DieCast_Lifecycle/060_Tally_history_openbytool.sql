-- =============================================
-- File:         0045_DieCast_Lifecycle/060_Tally_history_openbytool.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-29
-- Description:  Die-Cast Per-Cavity Lifecycle plan, Task 7. Covers the three
--               read-side changes in one file (shares the proven fixture
--               recipe from 020/030 -- ancestor-cascade Cell/Item resolution +
--               inline Tool/ToolCavity/ToolAssignment + Lots.DieCastLot_Open +
--               resolve-or-mint Oee.Shift):
--                 * Lots.Lot_GetOpenByTool (new read) -- one row per open
--                   basket for the tool; running PieceCount + ContributorCount.
--                 * Lots.Lot_GetShiftCavityTally rework -- PieceSum is now the
--                   plain good-piece SUM(Lot.PieceCount) with NO reject
--                   add-back (die-cast scrap is additive per 0042, so
--                   PieceCount already holds the true good count); RejectSum
--                   stays the separate scrap metric.
--                 * Lots.Lot_GetAttributeHistory Stream 10 -- a 'Contribution'
--                   EventKind row per Workorder.DieCastContribution.
--
--               Fixture: open basket '606060601' via Lots.DieCastLot_Open, then
--               contribute 40 good + 5 additive scrap in the SAME (open) shift
--               via Workorder.DieCastShiftOutput_Record (its per-line
--               scrapLines[] insert Workorder.RejectEvent rows directly --
--               record-only, no PieceCount decrement -- so the scrap here is
--               additive by construction; no @OperationTypeCode is needed on
--               this proc, unlike the raw Workorder.RejectEvent_Record path).
--
--               LTT '606060601' is a distinct 9-digit external LTT (per
--               Lots.ufn_IsValidExternalLtt) from 020's 200000201/200000202 and
--               030's 303030301/302/303.
-- =============================================
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/060_Tally_history_openbytool.sql';
GO
-- ---- cleanup (idempotent, FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'606060601');
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName = N'606060601');
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName = N'606060601';
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName = N'606060601';
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName = N'606060601';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName = N'606060601';
DELETE FROM Lots.Lot WHERE LotName = N'606060601';
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCT-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCT-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCT-TOOL';
GO

-- ---- fixture: resolve (Cell, ItemId) via ancestor-cascade eligibility + a
-- published DieCast-route step, with NO active ToolAssignment on the Cell;
-- build Tool + Active ToolCavity + ToolAssignment inline on that Cell; open
-- an accumulator basket via Lots.DieCastLot_Open; resolve/mint an open Shift;
-- contribute 40 good + 5 additive scrap. One batch (no GO) so the resolved
-- locals stay in scope through fixture + assertions + cleanup.
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
    RAISERROR(N'0045/060 fixture: no (Cell, ItemId) pair found with a published DieCast route and no active ToolAssignment -- BLOCKED.', 16, 1);

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DCT-TOOL', N'Tally/History/OpenByTool test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
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
    @ToolCavityId=@Cavity, @LotName=N'606060601', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot BIGINT = (SELECT NewId FROM @O);
IF @Lot IS NULL
    RAISERROR(N'0045/060 fixture: Lots.DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

-- resolve or mint an open shift (mirrors 030's recipe -- Oee.Shift's B3
-- single-open constraint means resolve-or-create, never always-insert).
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0045/060 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

-- contribute 40 good + 5 additive scrap in this shift
DECLARE @DefectCode BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Lines NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20))
    + N',"pieceDelta":40,"scrapLines":[{"defectCodeId":' + CAST(@DefectCode AS NVARCHAR(20)) + N',"quantity":5}]}]';
DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@Lines,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @ws NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Fixture] shift output recorded, Status 1', @Expected=N'1', @Actual=@ws;

-- =============================================
-- Test 1: Lots.Lot_GetOpenByTool returns the open basket with running
-- PieceCount 40 + ContributorCount 1
-- =============================================
DECLARE @OB TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), LotId BIGINT, LotName NVARCHAR(50), PieceCount INT, OpenedAt DATETIME2(3), ContributorCount INT);
INSERT INTO @OB EXEC Lots.Lot_GetOpenByTool @ToolId=@Tool;
DECLARE @obpc NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM @OB WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[OpenByTool] running PieceCount 40', @Expected=N'40', @Actual=@obpc;
DECLARE @obcc NVARCHAR(10) = (SELECT CAST(ContributorCount AS NVARCHAR(10)) FROM @OB WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[OpenByTool] ContributorCount 1', @Expected=N'1', @Actual=@obcc;
DECLARE @obcav NVARCHAR(20) = (SELECT CAST(ToolCavityId AS NVARCHAR(20)) FROM @OB WHERE LotId=@Lot);
DECLARE @cavExp NVARCHAR(20) = CAST(@Cavity AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[OpenByTool] ToolCavityId matches', @Expected=@cavExp, @Actual=@obcav;

-- =============================================
-- Test 2: Lots.Lot_GetShiftCavityTally counts good WITHOUT double-counting
-- the additive scrap (PieceSum=40, RejectSum=5 -- separate metrics)
-- =============================================
DECLARE @T TABLE (ToolCavityId BIGINT, CavityNumber INT, CavityLabel NVARCHAR(100), PieceSum INT, RejectSum INT, ShiftShots INT, ShiftGoodTotal INT, ShiftScrapTotal INT);
INSERT INTO @T EXEC Lots.Lot_GetShiftCavityTally @ToolId=@Tool;
DECLARE @good NVARCHAR(10) = (SELECT CAST(PieceSum AS NVARCHAR(10)) FROM @T WHERE ToolCavityId=@Cavity);
EXEC test.Assert_IsEqual @TestName=N'[Tally] good = 40 (additive scrap NOT double-counted)', @Expected=N'40', @Actual=@good;
DECLARE @scr NVARCHAR(10) = (SELECT CAST(RejectSum AS NVARCHAR(10)) FROM @T WHERE ToolCavityId=@Cavity);
EXEC test.Assert_IsEqual @TestName=N'[Tally] scrap tallied separately = 5', @Expected=N'5', @Actual=@scr;

-- =============================================
-- Test 3: Lots.Lot_GetAttributeHistory shows a Contribution row
-- =============================================
DECLARE @H TABLE (EventAt DATETIME2(3), EventKind NVARCHAR(20), Detail NVARCHAR(500), ByUserId BIGINT, ByUserName NVARCHAR(200));
INSERT INTO @H EXEC Lots.Lot_GetAttributeHistory @LotId=@Lot;
DECLARE @hc NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @H WHERE EventKind=N'Contribution');
EXEC test.Assert_IsEqual @TestName=N'[History] Contribution stream present', @Expected=N'1', @Actual=@hc;
DECLARE @hdetail NVARCHAR(500) = (SELECT TOP 1 Detail FROM @H WHERE EventKind=N'Contribution');
EXEC test.Assert_Contains @TestName=N'[History] Contribution detail mentions the piece delta', @HaystackStr=@hdetail, @NeedleStr=N'40 pc';

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
