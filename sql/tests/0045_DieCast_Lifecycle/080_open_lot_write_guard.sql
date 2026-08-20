-- =============================================
-- File:         0045_DieCast_Lifecycle/080_open_lot_write_guard.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-20
-- Description:  An 'Open' LOT -- a die-cast per-cavity accumulator basket still
--               being filled at the press -- must be REJECTED by every ordinary
--               write path, and must remain fully usable by the die-cast
--               lifecycle procs that own it.
--
--               Regression for the MPP_MES_Prod incident of 2026-08-19
--               (spec docs/superpowers/specs/2026-08-20-open-lot-write-guard-design.md):
--               LOT 000000003 was born Open at DC1-M11, never released, then
--               accepted by Trim IN -- which moved it to TRIM1 and recorded a
--               TrimIn ProductionEvent. Because Lot_GetWipQueueByLocation
--               excludes Open, the LOT then existed but was invisible on every
--               screen, with no operator path to recover it.
--
--               Root cause: Lots.Lot_AssertNotBlocked (and its 15 inlined
--               mirrors) rejected on "BlocksProduction = 1 OR status = Closed",
--               and Open carries BlocksProduction = 0. The read side knew about
--               Open; the write side did not.
--
--               THE REGRESSION HALF OF THIS FILE MATTERS MOST. The risk in the
--               fix is over-blocking -- if the guard leaks into the die-cast
--               lifecycle, operators cannot accumulate or release baskets at
--               all, which is far worse than the bug being fixed.
--
--               FIXTURE: same proven recipe as 020/030/040 in this directory --
--               a clean MPP_MES_Test reset runs every sql/seeds/*.sql so
--               die-cast-routed, cell-eligible ITEMS exist, but NO
--               Tools.ToolAssignment rows do (mounts live only in seed_demo /
--               seed_jp, skipped on reset). So: resolve a (Cell, ItemId) pair
--               via ancestor-cascade eligibility where the Item has a published
--               DieCast route step and the Cell has no active ToolAssignment,
--               then build Tool + Active ToolCavities + ToolAssignment inline.
--               Tool code 'TEST-DCG-TOOL' is distinct from 020's TEST-DCO- /
--               030's TEST-DCB- / 040's TEST-DCR-.
--
--               LTTs '808080801' (guard subject) and '808080802' (release
--               regression) -- distinct 9-digit externals per
--               Lots.ufn_IsValidExternalLtt.
-- =============================================
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/080_open_lot_write_guard.sql';
GO

-- ---- cleanup (idempotent, FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802'));
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802'));
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802'));
DELETE p  FROM Lots.PauseEvent p INNER JOIN Lots.Lot l ON l.Id = p.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName IN (N'808080801', N'808080802');
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCG-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCG-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCG-TOOL';
GO

-- Fixture + all tests + cleanup share ONE batch (no GO) so locals stay in scope.
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
    RAISERROR(N'0045/080 fixture: no (Cell, ItemId) pair with a published DieCast route and no active ToolAssignment -- BLOCKED.', 16, 1);

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DCG-TOOL', N'Open-LOT write-guard test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
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

DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0045/080 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

DECLARE @WhseId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');
IF @WhseId IS NULL
    RAISERROR(N'0045/080 fixture: no Location with Code=WHSE -- BLOCKED.', 16, 1);

DECLARE @r TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
-- Move/Update-family procs drop @NewId (FDS-11-011), so they need a 2-column sink;
-- an INSERT-EXEC column mismatch throws INSIDE the proc, whose CATCH then hits
-- Msg 3915 (ROLLBACK inside INSERT-EXEC) and masks the real assertion.
DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Status NVARCHAR(10), @Msg NVARCHAR(500);

-- ---- open the subject basket (stays Open throughout the reject tests) ----
DELETE FROM @r;
INSERT INTO @r EXEC Lots.DieCastLot_Open
    @ItemId = @Item, @CurrentLocationId = @Cell, @ToolId = @Tool,
    @ToolCavityId = @Cavity1, @LotName = N'808080801', @AppUserId = 1;
DECLARE @OpenLot BIGINT = (SELECT NewId FROM @r);
IF @OpenLot IS NULL
    RAISERROR(N'0045/080 fixture: DieCastLot_Open did not return a LOT -- BLOCKED.', 16, 1);

SET @Status = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] fixture: basket opened', @Expected = N'1', @Actual = @Status;

SET @Status = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @OpenLot);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] fixture: basket status is Open', @Expected = N'Open', @Actual = @Status;

-- ============================================================
-- REGRESSION FIRST: the die-cast lifecycle must still work on an Open basket.
-- ============================================================
-- LinesJson is keyed by lotId/pieceDelta (see OPENJSON in the proc); the proc
-- REQUIRES sc.Code = 'Open', which is precisely the behaviour this regression protects.
DECLARE @Lines NVARCHAR(MAX) = N'[{"lotId":' + CAST(@OpenLot AS NVARCHAR(20)) + N',"pieceDelta":50}]';
DELETE FROM @r;
INSERT INTO @r EXEC Workorder.DieCastShiftOutput_Record
    @ShiftId = @Shift, @ToolId = @Tool, @LinesJson = @Lines, @AppUserId = 1, @CellLocationId = @Cell;
SET @Status = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard][REGRESSION] DieCastShiftOutput_Record still accumulates onto an Open basket',
     @Expected = N'1', @Actual = @Status;

-- ============================================================
-- The guard: ordinary write paths must REJECT an Open LOT.
-- ============================================================

-- canonical guard
DECLARE @ab TABLE (IsBlocked BIT, Message NVARCHAR(500));
INSERT INTO @ab EXEC Lots.Lot_AssertNotBlocked @LotId = @OpenLot;
SET @Status = (SELECT CAST(IsBlocked AS NVARCHAR(10)) FROM @ab);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] Lot_AssertNotBlocked reports an Open LOT as blocked',
     @Expected = N'1', @Actual = @Status;

SET @Msg = (SELECT Message FROM @ab);
SET @Status = CASE WHEN @Msg LIKE N'%release%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] blocked message tells the operator to release the basket',
     @Expected = N'1', @Actual = @Status;

-- the proc that caused the incident: ProductionEvent_Record (Trim IN checkpoint)
DECLARE @TrimInTemplate BIGINT = (
    SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    WHERE oty.Code = N'TrimIn' AND ot.DeprecatedAt IS NULL ORDER BY ot.Id);
IF @TrimInTemplate IS NOT NULL
BEGIN
    DELETE FROM @r;
    INSERT INTO @r EXEC Workorder.ProductionEvent_Record
        @LotId = @OpenLot, @OperationTemplateId = @TrimInTemplate, @AppUserId = 1;
    SET @Status = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r);
    EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] ProductionEvent_Record rejects an Open LOT (the prod incident)',
         @Expected = N'0', @Actual = @Status;
END

-- move path
DELETE FROM @r2;
INSERT INTO @r2 EXEC Lots.Lot_MoveToValidated
    @LotId = @OpenLot, @ToLocationId = @WhseId, @AppUserId = 1;
SET @Status = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r2);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] Lot_MoveToValidated rejects an Open LOT',
     @Expected = N'0', @Actual = @Status;

-- pause path
DELETE FROM @r;
INSERT INTO @r EXEC Lots.LotPause_Place
    @LotId = @OpenLot, @LocationId = @Cell, @PausedReason = N'0045/080 guard test', @AppUserId = 1;
SET @Status = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] LotPause_Place rejects an Open LOT',
     @Expected = N'0', @Actual = @Status;

-- the basket must be untouched by every rejection above
SET @Status = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @OpenLot);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] basket still Open after the rejected writes',
     @Expected = N'Open', @Actual = @Status;

SET @Status = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.ProductionEvent WHERE LotId = @OpenLot);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] no ProductionEvent was written for the Open LOT',
     @Expected = N'0', @Actual = @Status;

SET @Status = (SELECT loc.Code FROM Lots.Lot l INNER JOIN Location.Location loc ON loc.Id = l.CurrentLocationId WHERE l.Id = @OpenLot);
SET @Status = CASE WHEN @Status = (SELECT Code FROM Location.Location WHERE Id = @Cell) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard] Open LOT was not moved off its cell',
     @Expected = N'1', @Actual = @Status;

-- ============================================================
-- REGRESSION: release still works, and the released LOT becomes usable.
-- ============================================================
DELETE FROM @r;
INSERT INTO @r EXEC Lots.DieCastLot_Release
    @LotId = @OpenLot, @StorageLocationId = @WhseId, @AppUserId = 1;
SET @Status = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard][REGRESSION] DieCastLot_Release still releases an Open basket',
     @Expected = N'1', @Actual = @Status;

SET @Status = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @OpenLot);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard][REGRESSION] released basket is Good',
     @Expected = N'Good', @Actual = @Status;

DELETE FROM @ab;
INSERT INTO @ab EXEC Lots.Lot_AssertNotBlocked @LotId = @OpenLot;
SET @Status = (SELECT CAST(IsBlocked AS NVARCHAR(10)) FROM @ab);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard][REGRESSION] a released (Good) LOT is not blocked',
     @Expected = N'0', @Actual = @Status;

-- and the write path that rejected it before now accepts it
DELETE FROM @r;
INSERT INTO @r EXEC Lots.LotPause_Place
    @LotId = @OpenLot, @LocationId = @WhseId, @PausedReason = N'0045/080 post-release', @AppUserId = 1;
SET @Status = (SELECT CAST(Status AS NVARCHAR(10)) FROM @r);
EXEC test.Assert_IsEqual @TestName = N'[OpenGuard][REGRESSION] LotPause_Place accepts the same LOT once released',
     @Expected = N'1', @Actual = @Status;

-- ---- teardown ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802'));
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802'));
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802'));
DELETE p  FROM Lots.PauseEvent p INNER JOIN Lots.Lot l ON l.Id = p.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName IN (N'808080801', N'808080802');
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName IN (N'808080801', N'808080802');
DELETE FROM Lots.Lot WHERE LotName IN (N'808080801', N'808080802');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCG-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCG-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCG-TOOL';
IF @ShiftCreatedByTest = 1 DELETE FROM Oee.Shift WHERE Id = @Shift;
GO

EXEC test.EndTestFile;
GO
