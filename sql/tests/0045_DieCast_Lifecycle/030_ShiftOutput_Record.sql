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
-- LotNames: 303030301 = Part A/B primary fixture basket; 303030302/303 =
-- the multi-lot-per-cavity coverage's lot A / lot B (Part B, added Task 4).
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'303030301', N'303030302', N'303030303'));
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'303030301', N'303030302', N'303030303'));
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName IN (N'303030301', N'303030302', N'303030303');
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName IN (N'303030301', N'303030302', N'303030303');
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName IN (N'303030301', N'303030302', N'303030303');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName IN (N'303030301', N'303030302', N'303030303');
DELETE FROM Lots.Lot WHERE LotName IN (N'303030301', N'303030302', N'303030303');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCB-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCB-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCB-TOOL';
DELETE FROM Quality.DefectCode WHERE Code = N'TEST-DCB-DEP';
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
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT);
INSERT INTO @B EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId=@Tool, @ShiftId=@Shift, @GrossShots=100;

DECLARE @rowCount NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @B);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] one row for the tool''s single cavity', @Expected=N'1', @Actual=@rowCount;

DECLARE @row NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot AND IsOpen=1);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] open basket row present', @Expected=N'1', @Actual=@row;

DECLARE @prop NVARCHAR(10) = (SELECT CAST(ProposedGood AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] proposed good = gross (no prior, no scrap yet)', @Expected=N'100', @Actual=@prop;

DECLARE @prior NVARCHAR(10) = (SELECT CAST(PriorGoodThisShift AS NVARCHAR(10)) FROM @B WHERE LotId=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] prior good = 0 (nothing recorded yet)', @Expected=N'0', @Actual=@prior;

DECLARE @bItem NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM @B WHERE LotId=@Lot);
DECLARE @bItemExpected NVARCHAR(20) = (SELECT CAST(ItemId AS NVARCHAR(20)) FROM Lots.Lot WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Breakdown] ItemId returned matches the lot''s item', @Expected=@bItemExpected, @Actual=@bItem;

-- ===== PART B (Task 4: DieCastShiftOutput_Record) APPENDS BELOW, BEFORE EndTestFile =====

-- ---------------------------------------------------------------
-- Part B: Workorder.DieCastShiftOutput_Record (write). Uses @Lot / @Shift /
-- @Tool / @Cavity from Part A (same file, same batch scope -- no GO between
-- fixture / Part A / Part B / the multi-lot scenario / cleanup, since a GO
-- would scope out the locals before later sections could reuse them).
-- ---------------------------------------------------------------
DECLARE @DefectCode BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Lines NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20))
    + N',"pieceDelta":95,"scrapLines":[{"defectCodeId":' + CAST(@DefectCode AS NVARCHAR(20)) + N',"quantity":5}]}]';
DECLARE @W TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@Lines,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL, @CellLocationId=@Cell;
DECLARE @ws NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W);
EXEC test.Assert_IsEqual @TestName=N'[Record] Status 1', @Expected=N'1', @Actual=@ws;
-- basket got the NET good (95), not decremented by the additive scrap
DECLARE @pcAfter NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Record] basket PieceCount += net good (95)', @Expected=N'95', @Actual=@pcAfter;
-- contribution row recorded with operator + shift
DECLARE @contrib NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.DieCastContribution
    WHERE LotId=@Lot AND ShiftId=@Shift AND PieceDelta=95 AND AppUserId=1);
EXEC test.Assert_IsEqual @TestName=N'[Record] contribution row present', @Expected=N'1', @Actual=@contrib;
-- additive reject recorded, LOT not decremented, not closed
DECLARE @rej NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId=@Lot AND Quantity=5);
EXEC test.Assert_IsEqual @TestName=N'[Record] additive scrap RejectEvent present', @Expected=N'1', @Actual=@rej;
DECLARE @stillOpen NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Record] basket still Open (additive scrap never closes)', @Expected=N'Open', @Actual=@stillOpen;

-- FAT #19: the DieCastPieceContributed audit op must capture the selected
-- die-cast MACHINE (cell) LocationId (was hard-coded NULL). 'Lot' entity ops
-- with a non-NULL EntityId route to Lots.LotEventLog (Audit_LogOperation B7);
-- @CellLocationId=@Cell was passed on the record call above.
DECLARE @evtLoc NVARCHAR(20) = (SELECT CAST(le.LocationId AS NVARCHAR(20))
    FROM Lots.LotEventLog le INNER JOIN Audit.LogEventType et ON et.Id = le.LogEventTypeId
    WHERE le.LotId=@Lot AND et.Code=N'DieCastPieceContributed');
DECLARE @cellExpected NVARCHAR(20) = CAST(@Cell AS NVARCHAR(20));
EXEC test.Assert_IsEqual @TestName=N'[Record #19] DieCastPieceContributed LocationId = selected machine (cell)', @Expected=@cellExpected, @Actual=@evtLoc;

-- ---------------------------------------------------------------
-- Defect-code validation (robustness fix): a scrap/shot-loss defectCodeId
-- that is nonexistent or deprecated must reject PRE-TRANSACTION with a clean
-- Status=0 (not an in-transaction FK RAISERROR), mirroring
-- RejectEvent_Record's DeprecatedAt check (R__Workorder_RejectEvent_Record.sql
-- ~line 121). Reuses @Lot (already Open on @Tool) -- the rejection fires
-- before any mutation, so it's safe to probe against the live fixture lot.
-- ---------------------------------------------------------------
DECLARE @BadLines NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20))
    + N',"pieceDelta":0,"scrapLines":[{"defectCodeId":999999999,"quantity":1}]}]';
DECLARE @WBad TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @WBad EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@BadLines,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @wBadStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @WBad);
EXEC test.Assert_IsEqual @TestName=N'[DefectCode] nonexistent scrap defectCodeId rejected, Status 0', @Expected=N'0', @Actual=@wBadStatus;
DECLARE @wBadMsg NVARCHAR(500) = (SELECT Message FROM @WBad);
DECLARE @wBadGraceful NVARCHAR(10) = CASE WHEN @wBadMsg LIKE N'Unexpected error%' THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName=N'[DefectCode] rejection message is graceful (not an unexpected-error)', @Expected=N'1', @Actual=@wBadGraceful;

-- deprecated defect code also rejected (parity with RejectEvent_Record).
-- Migration 0048 (FAT #1) replaced Quality.DefectCode.AreaLocationId with the
-- nullable OperationCategoryId (NULL = plant-wide); this test only needs a
-- valid-then-deprecated code, so a plant-wide (NULL category) row suffices.
INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused, CreatedAt)
VALUES (N'TEST-DCB-DEP', N'0045/030 deprecated defect code test', NULL, 0, SYSUTCDATETIME());
DECLARE @DepDefectCode BIGINT = SCOPE_IDENTITY();
UPDATE Quality.DefectCode SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @DepDefectCode;

DECLARE @DepLines NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20))
    + N',"pieceDelta":0,"scrapLines":[{"defectCodeId":' + CAST(@DepDefectCode AS NVARCHAR(20)) + N',"quantity":1}]}]';
DECLARE @WDep TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @WDep EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@DepLines,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @wDepStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @WDep);
EXEC test.Assert_IsEqual @TestName=N'[DefectCode] deprecated scrap defectCodeId rejected, Status 0', @Expected=N'0', @Actual=@wDepStatus;

DELETE FROM Quality.DefectCode WHERE Id = @DepDefectCode;

-- ---------------------------------------------------------------
-- Multi-lot-per-cavity breakdown coverage (closes the Task 3 review gap: the
-- read proc's core purpose -- splitting a shift's gross shots across MORE
-- THAN ONE lot that occupied the same cavity during the shift window -- had
-- no automated coverage). A SECOND cavity (@Cavity2) is minted on the SAME
-- @Tool -- reusing @Cavity would entangle the numbers with @Lot's own 95-piece
-- contribution recorded on @Cavity THIS SAME SHIFT just above (the read
-- proc's ProposedGood subquery sums every OTHER lot's contribution on the
-- SAME ToolCavityId this shift, so @Lot's 95 would bleed into lot B's
-- remainder math if they shared a cavity). Recipe: open lot A on @Cavity2,
-- credit it 40 good via the write proc under test, hand-simulate a mid-shift
-- Release (Release itself is Task 6 / not yet built -- flip LotStatusId
-- Open->Good directly, exactly as the task brief prescribes) so the cavity is
-- free, open lot B on the SAME cavity, then assert
-- DieCast_GetShiftOutputBreakdown reports lot A closed-out-with-its-shift-
-- credit and lot B getting the remainder of gross shots (floored at 0, never
-- negative).
-- ---------------------------------------------------------------
DECLARE @LotAName NVARCHAR(50) = N'303030302', @LotBName NVARCHAR(50) = N'303030303';
DECLARE @GoodStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');

DECLARE @Cav2Active BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, 2, @Cav2Active, SYSUTCDATETIME(), 1);
DECLARE @Cavity2 BIGINT = SCOPE_IDENTITY();

DECLARE @OA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @OA EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity2, @LotName=@LotAName, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @LotA BIGINT = (SELECT NewId FROM @OA);
IF @LotA IS NULL
    RAISERROR(N'0045/030 Part B multi-lot fixture: DieCastLot_Open failed to mint lot A -- BLOCKED.', 16, 1);

-- credit lot A 40 good this shift
DECLARE @LinesA NVARCHAR(MAX) = N'[{"lotId":' + CAST(@LotA AS NVARCHAR(20)) + N',"pieceDelta":40,"scrapLines":null}]';
DECLARE @WA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @WA EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@LinesA,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @wsA NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @WA);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] lot A credited 40 good, Status 1', @Expected=N'1', @Actual=@wsA;

-- hand-simulate a mid-shift Release (real release = Task 6; the breakdown
-- considers any lot with a DieCastContribution this shift regardless of
-- current status, per the read proc's Prior/Lots CTEs).
UPDATE Lots.Lot SET LotStatusId = @GoodStatusId WHERE Id = @LotA;

-- lot A is no longer Open -> lot B can now open on the SAME cavity
DECLARE @OB TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @OB EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity2, @LotName=@LotBName, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @LotB BIGINT = (SELECT NewId FROM @OB);
IF @LotB IS NULL
    RAISERROR(N'0045/030 Part B multi-lot fixture: DieCastLot_Open failed to mint lot B (cavity should be free after A''s release) -- BLOCKED.', 16, 1);

DECLARE @B2 TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT);
INSERT INTO @B2 EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId=@Tool, @ShiftId=@Shift, @GrossShots=100;

-- scoped to @Cavity2 -- the tool-wide result also includes @Lot's own
-- closed-out row on @Cavity (that lot/cavity pair is asserted separately in
-- Part A/B above); the multi-lot claim is specifically "two rows sharing ONE
-- cavity", so count within @Cavity2 only.
DECLARE @rowCount2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @B2 WHERE ToolCavityId = @Cavity2);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] two rows for the shared cavity (lot A closed-out + lot B open)', @Expected=N'2', @Actual=@rowCount2;

DECLARE @aIsOpen NVARCHAR(10)  = (SELECT CAST(IsOpen AS NVARCHAR(10)) FROM @B2 WHERE LotId=@LotA);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] lot A row IsOpen=0 (released)', @Expected=N'0', @Actual=@aIsOpen;
DECLARE @aPrior NVARCHAR(10)   = (SELECT CAST(PriorGoodThisShift AS NVARCHAR(10)) FROM @B2 WHERE LotId=@LotA);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] lot A PriorGoodThisShift=40', @Expected=N'40', @Actual=@aPrior;
DECLARE @aProp NVARCHAR(10)    = (SELECT CAST(ProposedGood AS NVARCHAR(10)) FROM @B2 WHERE LotId=@LotA);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] lot A ProposedGood=40 (keeps its shift credit)', @Expected=N'40', @Actual=@aProp;

DECLARE @bIsOpen NVARCHAR(10)  = (SELECT CAST(IsOpen AS NVARCHAR(10)) FROM @B2 WHERE LotId=@LotB);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] lot B row IsOpen=1 (still open)', @Expected=N'1', @Actual=@bIsOpen;
DECLARE @bProp NVARCHAR(10)    = (SELECT CAST(ProposedGood AS NVARCHAR(10)) FROM @B2 WHERE LotId=@LotB);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] lot B ProposedGood=60 (100 gross - lot A''s 40)', @Expected=N'60', @Actual=@bProp;

-- at a lower gross-shot count than lot A already claimed, lot B floors at 0 (not negative)
DECLARE @B3 TABLE (ToolCavityId BIGINT, CavityNumber NVARCHAR(50), LotId BIGINT, LotName NVARCHAR(50),
    IsOpen BIT, PriorGoodThisShift INT, ProposedGood INT, MaxHeadroom INT, ItemId BIGINT);
INSERT INTO @B3 EXEC Workorder.DieCast_GetShiftOutputBreakdown @ToolId=@Tool, @ShiftId=@Shift, @GrossShots=30;
DECLARE @bPropFloor NVARCHAR(10) = (SELECT CAST(ProposedGood AS NVARCHAR(10)) FROM @B3 WHERE LotId=@LotB);
EXEC test.Assert_IsEqual @TestName=N'[MultiLot] lot B ProposedGood floors at 0 (GrossShots=30 < lot A''s 40)', @Expected=N'0', @Actual=@bPropFloor;

-- ---- cleanup (FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (@Lot, @LotA, @LotB);
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (@Lot, @LotA, @LotB) OR (@ShiftCreatedByTest = 1 AND ShiftId = @Shift);
DELETE cl FROM Lots.LotGenealogyClosure cl WHERE cl.AncestorLotId IN (@Lot, @LotA, @LotB) OR cl.DescendantLotId IN (@Lot, @LotA, @LotB);
DELETE m  FROM Lots.LotMovement m WHERE m.LotId IN (@Lot, @LotA, @LotB);
DELETE h  FROM Lots.LotStatusHistory h WHERE h.LotId IN (@Lot, @LotA, @LotB);
DELETE le FROM Lots.LotEventLog le WHERE le.LotId IN (@Lot, @LotA, @LotB);
DELETE FROM Lots.Lot WHERE Id IN (@Lot, @LotA, @LotB);
DELETE FROM Tools.ToolCavity WHERE ToolId = @Tool;
DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
IF @ShiftCreatedByTest = 1
    DELETE FROM Oee.Shift WHERE Id = @Shift;
GO
EXEC test.EndTestFile;
GO
