-- =============================================
-- File:         0045_DieCast_Lifecycle/040_Release_and_queue.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-29
-- Description:  Tests for Lots.DieCastLot_Release (Die-Cast Per-Cavity
--               Lifecycle plan, Task 6 / Phase 3): closes an open accumulator
--               basket (Open -> Good) at the well-known 'WHSE' storage
--               location, and confirms the released LOT surfaces in the
--               route-driven Trim IN WIP queue at storage.
--
--               FIXTURE NOTE (mirrors 020_DieCastLot_Open.sql /
--               030_ShiftOutput_Record.sql, which themselves deviate from
--               their own briefs for the identical reason): a clean
--               MPP_MES_Test reset runs every sql/seeds/*.sql file, so
--               die-cast-routed, cell-eligible ITEMS exist -- but NO
--               Tools.ToolAssignment rows exist (mounts live only in
--               seed_demo/seed_jp, which is skipped on reset). Recipe used,
--               copied verbatim from 020/030's proven fixture: (1) resolve a
--               (Cell, ItemId) pair via the ANCESTOR-CASCADE eligibility rule
--               where the Item has a published route with a DieCast step and
--               the Cell has no active ToolAssignment; (2) build a Tool + TWO
--               Active ToolCavities + a ToolAssignment inline on that Cell
--               (distinct tool code 'TEST-DCR-TOOL' to avoid colliding with
--               020's 'TEST-DCO-TOOL' / 030's 'TEST-DCB-TOOL'); (3) open
--               baskets via Lots.DieCastLot_Open (never a hand INSERT); (4)
--               resolve or mint an Oee.Shift exactly as 030 does, to credit
--               pieces via Workorder.DieCastShiftOutput_Record before release.
--
--               Two cavities are used because the one-open-per-(Tool,Cavity)
--               guard (Task 2) only re-admits a NEW open basket on a cavity
--               once the PRIOR one has left 'Open' status. Test 1's basket is
--               released (leaves Open) so its cavity (@Cavity1) is free again
--               for Test 3's basket; Test 2's basket is REJECTED (stays Open)
--               so it needs its OWN cavity (@Cavity2) to avoid colliding with
--               Test 3's open() call.
--
--               Test 3 (nonexistent @StorageLocationId) uses an EMPTY basket
--               (no contribution) -- per the proc's validation ORDER (storage
--               resolution/existence is checked BEFORE the projected-
--               PieceCount-must-be->0 check), the bad-storage-location reject
--               fires first regardless of piece count, so an empty basket is
--               fine for isolating that specific rejection path.
--
--               Test 4 (negative @FinalPieceDelta rejected) uses a THIRD
--               cavity (@Cavity3): after Test 3, both @Cavity1 (Lot3, still
--               Open -- its release was rejected for bad storage) and
--               @Cavity2 (Lot2, still Open -- its release was rejected as
--               empty) are occupied, so a fresh cavity is needed. Covers the
--               code-review finding that the pre-txn projected-PieceCount
--               gate (current + ISNULL(@FinalPieceDelta,0) > 0) let a
--               negative @FinalPieceDelta pass validation while the
--               mutation only applies it when > 0 -- silently no-op'ing the
--               delta and returning Status=1 with PieceCount unchanged,
--               contradicting the validation. Fixed by rejecting any
--               negative @FinalPieceDelta pre-transaction.
--
--               LTTs: '404040401' (Test 1, happy release), '404040402'
--               (Test 2, empty-basket release reject), '404040403' (Test 3,
--               nonexistent storage reject), '404040404' (Test 4, negative
--               FinalPieceDelta reject), '404040405' (Test 5, nonexistent
--               @ScrapLinesJson defectCodeId reject -- pre-transaction
--               defect-code validation robustness fix), '404040406' (Test 6,
--               a valid ACTIVE scrapLines[].approvedByUserId releases and
--               lands), '404040407' (Test 7, an OMITTED approver still
--               releases), '404040408' (Test 8, a DEPRECATED approver refused
--               pre-transaction -- proc v2.4) -- distinct 9-digit
--               externals (Lots.ufn_IsValidExternalLtt) from 020's 2000002xx
--               / 030's 3030303xx.
-- =============================================
SET NOCOUNT ON; SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0045_DieCast_Lifecycle/040_Release_and_queue.sql';
GO
-- ---- cleanup (idempotent, FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'404040401', N'404040402', N'404040403', N'404040404', N'404040405', N'404040406', N'404040407', N'404040408'));
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName IN (N'404040401', N'404040402', N'404040403', N'404040404', N'404040405', N'404040406', N'404040407', N'404040408'));
DELETE cl FROM Lots.LotGenealogyClosure cl INNER JOIN Lots.Lot l ON l.Id IN (cl.AncestorLotId, cl.DescendantLotId) WHERE l.LotName IN (N'404040401', N'404040402', N'404040403', N'404040404', N'404040405', N'404040406', N'404040407', N'404040408');
DELETE m  FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.LotName IN (N'404040401', N'404040402', N'404040403', N'404040404', N'404040405', N'404040406', N'404040407', N'404040408');
DELETE h  FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.LotName IN (N'404040401', N'404040402', N'404040403', N'404040404', N'404040405', N'404040406', N'404040407', N'404040408');
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.LotName IN (N'404040401', N'404040402', N'404040403', N'404040404', N'404040405', N'404040406', N'404040407', N'404040408');
DELETE FROM Lots.Lot WHERE LotName IN (N'404040401', N'404040402', N'404040403', N'404040404', N'404040405', N'404040406', N'404040407', N'404040408');
DELETE tc FROM Tools.ToolCavity tc INNER JOIN Tools.Tool t ON t.Id = tc.ToolId WHERE t.Code = N'TEST-DCR-TOOL';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'TEST-DCR-TOOL');
DELETE FROM Tools.Tool WHERE Code = N'TEST-DCR-TOOL';
-- the Tests 6-8 approvers, after every RejectEvent that could reference them
DELETE FROM Location.AppUser WHERE Initials IN (N'ZRCA', N'ZRCD');
GO

-- ---- fixture: resolve (Cell, ItemId) via ancestor-cascade eligibility + a
-- published DieCast-route step, with NO active ToolAssignment on the Cell;
-- build Tool + TWO Active ToolCavities + a ToolAssignment inline on that Cell;
-- resolve/mint an open Shift. Fixture + all tests + cleanup share ONE batch
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
    RAISERROR(N'0045/040 fixture: no (Cell, ItemId) pair found with a published DieCast route and no active ToolAssignment -- BLOCKED.', 16, 1);

DECLARE @ToolTypeId BIGINT = (SELECT Id FROM Tools.ToolType WHERE Code = N'Die');
DECLARE @ToolStatusActive BIGINT = (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@ToolTypeId, N'TEST-DCR-TOOL', N'DieCastLot_Release test die', @ToolStatusActive, SYSUTCDATETIME(), 1);
DECLARE @Tool BIGINT = SCOPE_IDENTITY();

DECLARE @CavActive BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'a', @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'b', @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'c', @CavActive, SYSUTCDATETIME(), 1);
DECLARE @Cavity3 BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@Tool, @Cell, SYSUTCDATETIME(), 1);

-- resolve or mint an open shift (mirrors 030's identical recipe)
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC);
DECLARE @ShiftCreatedByTest BIT = 0;
IF @Shift IS NULL
BEGIN
    DECLARE @ScheduleId BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule ORDER BY Id);
    IF @ScheduleId IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'0045/040 Test Schedule', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @ScheduleId = SCOPE_IDENTITY();
    END
    INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart) VALUES (@ScheduleId, DATEADD(HOUR,-2,SYSUTCDATETIME()));
    SET @Shift = SCOPE_IDENTITY();
    SET @ShiftCreatedByTest = 1;
END

DECLARE @WhseId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');
IF @WhseId IS NULL
    RAISERROR(N'0045/040 fixture: no Location with Code=WHSE -- BLOCKED.', 16, 1);

-- =============================================
-- Test 1: happy release (open, contribute 50, release with @StorageLocationId=NULL)
-- =============================================
DECLARE @O1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O1 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity1, @LotName=N'404040401', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot BIGINT = (SELECT NewId FROM @O1);
IF @Lot IS NULL
    RAISERROR(N'0045/040 Test 1 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @Lines1 NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot AS NVARCHAR(20)) + N',"pieceDelta":50,"scrapLines":null}]';
DECLARE @W1 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W1 EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@Lines1,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @w1s NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W1);
EXEC test.Assert_IsEqual @TestName=N'[Release] fixture: 50pc contributed, Status 1', @Expected=N'1', @Actual=@w1s;

DECLARE @Rel TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel EXEC Lots.DieCastLot_Release @LotId=@Lot, @StorageLocationId=NULL, @ShiftId=@Shift, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Rel);
EXEC test.Assert_IsEqual @TestName=N'[Release] Status 1', @Expected=N'1', @Actual=@rs;

DECLARE @afterState NVARCHAR(20) = (SELECT sc.Code FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id=l.LotStatusId WHERE l.Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Release] Open->Good', @Expected=N'Good', @Actual=@afterState;

DECLARE @atWhse NVARCHAR(10) = (SELECT CASE WHEN CurrentLocationId = @WhseId THEN N'1' ELSE N'0' END FROM Lots.Lot WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Release] moved to WHSE', @Expected=N'1', @Actual=@atWhse;

-- released lot now appears in the Trim IN queue at storage (column shape
-- mirrors 020's Test 4 INSERT-EXEC: 11 columns from Lots.Lot_GetWipQueueByLocation)
DECLARE @Q TABLE (
    Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50),
    ItemDescription NVARCHAR(1000), PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(40),
    LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);
INSERT INTO @Q EXEC Lots.Lot_GetWipQueueByLocation @LocationId=@WhseId, @OperationTypeCode=N'TrimIn', @IncludeDescendants=1;
DECLARE @inQ NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id=@Lot);
EXEC test.Assert_IsEqual @TestName=N'[Release] released lot visible in Trim IN queue', @Expected=N'1', @Actual=@inQ;

-- =============================================
-- Test 2: empty-basket release rejected (own cavity: this basket stays Open)
-- =============================================
DECLARE @O2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O2 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity2, @LotName=N'404040402', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot2 BIGINT = (SELECT NewId FROM @O2);
IF @Lot2 IS NULL
    RAISERROR(N'0045/040 Test 2 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @Rel2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel2 EXEC Lots.DieCastLot_Release @LotId=@Lot2, @StorageLocationId=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs2 BIT = (SELECT Status FROM @Rel2); DECLARE @rs2c BIT = CASE WHEN @rs2=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Release] empty-basket release rejected', @Condition=@rs2c;

-- =============================================
-- Test 3: nonexistent @StorageLocationId rejected (reuses @Cavity1, freed by Test 1's release)
-- =============================================
DECLARE @O3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O3 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity1, @LotName=N'404040403', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot3 BIGINT = (SELECT NewId FROM @O3);
IF @Lot3 IS NULL
    RAISERROR(N'0045/040 Test 3 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @Rel3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel3 EXEC Lots.DieCastLot_Release @LotId=@Lot3, @StorageLocationId=999999999, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs3 BIT = (SELECT Status FROM @Rel3); DECLARE @rs3c BIT = CASE WHEN @rs3=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Release] nonexistent storage location rejected', @Condition=@rs3c;

-- =============================================
-- Test 4: negative @FinalPieceDelta rejected (code-review finding -- the
-- pre-txn projected-PieceCount gate let a negative delta pass validation
-- while the mutation silently no-op'd it, returning Status=1 with
-- PieceCount unchanged; own cavity since this basket stays Open)
-- =============================================
DECLARE @O4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O4 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity3, @LotName=N'404040404', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot4 BIGINT = (SELECT NewId FROM @O4);
IF @Lot4 IS NULL
    RAISERROR(N'0045/040 Test 4 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @Lines4 NVARCHAR(MAX) = N'[{"lotId":' + CAST(@Lot4 AS NVARCHAR(20)) + N',"pieceDelta":20,"scrapLines":null}]';
DECLARE @W4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @W4 EXEC Workorder.DieCastShiftOutput_Record @ShiftId=@Shift, @ToolId=@Tool, @LinesJson=@Lines4,
    @ShotLossJson=NULL, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @w4s NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @W4);
EXEC test.Assert_IsEqual @TestName=N'[Release] Test 4 fixture: 20pc contributed, Status 1', @Expected=N'1', @Actual=@w4s;

DECLARE @Rel4 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel4 EXEC Lots.DieCastLot_Release @LotId=@Lot4, @StorageLocationId=NULL, @FinalPieceDelta=-5, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs4 BIT = (SELECT Status FROM @Rel4); DECLARE @rs4c BIT = CASE WHEN @rs4=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Release] negative FinalPieceDelta rejected', @Condition=@rs4c;

-- =============================================
-- Test 5: nonexistent @ScrapLinesJson defectCodeId rejected (robustness fix
-- -- mirrors Test 4's pattern; own cavity since this basket stays Open).
-- Uses a 4th cavity because @Cavity1/@Cavity2/@Cavity3 are all occupied by
-- Tests 3/2/4's still-Open rejected baskets.
-- =============================================
DECLARE @CavActive5 BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'd', @CavActive5, SYSUTCDATETIME(), 1);
DECLARE @Cavity4 BIGINT = SCOPE_IDENTITY();

DECLARE @O5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O5 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity4, @LotName=N'404040405', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot5 BIGINT = (SELECT NewId FROM @O5);
IF @Lot5 IS NULL
    RAISERROR(N'0045/040 Test 5 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @ScrapLines5 NVARCHAR(MAX) = N'[{"defectCodeId":999999999,"quantity":1}]';
DECLARE @Rel5 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel5 EXEC Lots.DieCastLot_Release @LotId=@Lot5, @StorageLocationId=NULL, @FinalPieceDelta=10,
    @ScrapLinesJson=@ScrapLines5, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs5 BIT = (SELECT Status FROM @Rel5); DECLARE @rs5c BIT = CASE WHEN @rs5=0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName=N'[Release] nonexistent scrap defectCodeId rejected', @Condition=@rs5c;
DECLARE @rs5Msg NVARCHAR(500) = (SELECT Message FROM @Rel5);
DECLARE @rs5Graceful NVARCHAR(10) = CASE WHEN @rs5Msg LIKE N'Unexpected error%' THEN N'0' ELSE N'1' END;
EXEC test.Assert_IsEqual @TestName=N'[Release] rejection message is graceful (not an unexpected-error)', @Expected=N'1', @Actual=@rs5Graceful;
-- rejected pre-transaction: PieceCount unchanged (FinalPieceDelta never applied)
DECLARE @pc5 NVARCHAR(10) = (SELECT CAST(PieceCount AS NVARCHAR(10)) FROM Lots.Lot WHERE Id=@Lot5);
EXEC test.Assert_IsEqual @TestName=N'[Release] Test 5: PieceCount unchanged (rejected pre-transaction)', @Expected=N'0', @Actual=@pc5;

-- =============================================
-- Tests 6-8: scrapLines[].approvedByUserId (proc v2.4).
--
-- This proc wraps caller-supplied @ScrapLinesJson VERBATIM into
-- Workorder.DieCastScrap_Write's @LinesJson, and that worker reads
-- s.approvedByUserId and writes it to Workorder.RejectEvent.ApprovedByUserId.
-- Before v2.4 the ONLY scrap validation here was the defect-code check
-- (Test 5), so an approver id travelled straight to that FK inside the
-- transaction and came back as a generic 'Unexpected error'. It now rejects
-- pre-transaction with the same rule and the same words as
-- Workorder.DieCastShiftOutput_Record 3.2 -- 'active' is DeprecatedAt IS NULL.
--
-- Cavity budget: @Cavity1..@Cavity4 are all occupied by Tests 2/3/4/5's still-
-- Open rejected baskets, so Tests 6, 7 and 8 get THREE fresh cavities, one
-- each. They could have shared one -- 6 and 7 release, which frees it -- but
-- then a regression in 6 or 7 leaves its basket Open and the next test's
-- DieCastLot_Open hits the one-open-per-(Tool,Cavity) guard, so a single
-- broken assertion reports as three. One cavity each keeps each failure
-- attributable to the thing it tests. (Found by sabotaging the optionality
-- guard: Test 7's refusal took Test 8 down with it.)
-- =============================================
DECLARE @CavActive6 BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'e', @CavActive6, SYSUTCDATETIME(), 1);
DECLARE @Cavity5 BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'f', @CavActive6, SYSUTCDATETIME(), 1);
DECLARE @Cavity6 BIGINT = SCOPE_IDENTITY();
INSERT INTO Tools.ToolCavity (ToolId, CavityCode, StatusCodeId, CreatedAt, CreatedByUserId)
VALUES (@Tool, N'g', @CavActive6, SYSUTCDATETIME(), 1);
DECLARE @Cavity7 BIGINT = SCOPE_IDENTITY();

DECLARE @DefectCode6 BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);

INSERT INTO Location.AppUser (DisplayName, Initials, Pin, CreatedAt)
VALUES (N'0045/040 release scrap approver', N'ZRCA', N'93811', SYSUTCDATETIME());
DECLARE @RelApprover BIGINT = SCOPE_IDENTITY();
INSERT INTO Location.AppUser (DisplayName, Initials, Pin, CreatedAt, DeprecatedAt)
VALUES (N'0045/040 deprecated release approver', N'ZRCD', N'93812', SYSUTCDATETIME(), SYSUTCDATETIME());
DECLARE @RelDepApprover BIGINT = SCOPE_IDENTITY();

-- ---- Test 6: a valid ACTIVE approver still releases, and the value lands ----
DECLARE @O6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O6 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity5, @LotName=N'404040406', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot6 BIGINT = (SELECT NewId FROM @O6);
IF @Lot6 IS NULL
    RAISERROR(N'0045/040 Test 6 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @ScrapLines6 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@DefectCode6 AS NVARCHAR(20))
    + N',"quantity":21,"approvedByUserId":' + CAST(@RelApprover AS NVARCHAR(20)) + N'}]';
DECLARE @Rel6 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel6 EXEC Lots.DieCastLot_Release @LotId=@Lot6, @StorageLocationId=NULL, @FinalPieceDelta=10,
    @ScrapLinesJson=@ScrapLines6, @ShiftId=@Shift, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs6 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Rel6);
EXEC test.Assert_IsEqual @TestName=N'[Approver] a valid approvedByUserId still releases, Status 1', @Expected=N'1', @Actual=@rs6;

DECLARE @relApprExpected NVARCHAR(20) = CAST(@RelApprover AS NVARCHAR(20));
DECLARE @relApprLanded NVARCHAR(20) = (SELECT ISNULL(CAST(ApprovedByUserId AS NVARCHAR(20)), N'NULL')
    FROM Workorder.RejectEvent WHERE LotId = @Lot6 AND Quantity = 21);
EXEC test.Assert_IsEqual @TestName=N'[Approver] the approver landed on the released LOT''s RejectEvent row',
    @Expected=@relApprExpected, @Actual=@relApprLanded;

-- ---- Test 7: an OMITTED approver still releases, and the column stays NULL ----
DECLARE @O7 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O7 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity6, @LotName=N'404040407', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot7 BIGINT = (SELECT NewId FROM @O7);
IF @Lot7 IS NULL
    RAISERROR(N'0045/040 Test 7 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @ScrapLines7 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@DefectCode6 AS NVARCHAR(20)) + N',"quantity":22}]';
DECLARE @Rel7 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel7 EXEC Lots.DieCastLot_Release @LotId=@Lot7, @StorageLocationId=NULL, @FinalPieceDelta=10,
    @ScrapLinesJson=@ScrapLines7, @ShiftId=@Shift, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs7 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Rel7);
EXEC test.Assert_IsEqual @TestName=N'[Approver] a scrap line with no approver still releases, Status 1', @Expected=N'1', @Actual=@rs7;
-- counted, not just read: a bare "is it NULL" would also pass if the row were
-- never written at all, which is the very failure an over-eager approver check
-- would cause. '1|0' is one row, none of them approved.
DECLARE @relNoApprLanded NVARCHAR(20) = (SELECT CONCAT(COUNT(*), N'|', COUNT(ApprovedByUserId))
    FROM Workorder.RejectEvent WHERE LotId = @Lot7 AND Quantity = 22);
EXEC test.Assert_IsEqual @TestName=N'[Approver] an omitted approver leaves ApprovedByUserId NULL', @Expected=N'1|0', @Actual=@relNoApprLanded;

-- ---- Test 8: a DEPRECATED approver is refused, pre-transaction ----
DECLARE @O8 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O8 EXEC Lots.DieCastLot_Open @ItemId=@Item, @CurrentLocationId=@Cell, @ToolId=@Tool,
    @ToolCavityId=@Cavity7, @LotName=N'404040408', @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @Lot8 BIGINT = (SELECT NewId FROM @O8);
IF @Lot8 IS NULL
    RAISERROR(N'0045/040 Test 8 fixture: DieCastLot_Open failed to mint the basket -- BLOCKED.', 16, 1);

DECLARE @ScrapLines8 NVARCHAR(MAX) = N'[{"defectCodeId":' + CAST(@DefectCode6 AS NVARCHAR(20))
    + N',"quantity":23,"approvedByUserId":' + CAST(@RelDepApprover AS NVARCHAR(20)) + N'}]';
DECLARE @Rel8 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @Rel8 EXEC Lots.DieCastLot_Release @LotId=@Lot8, @StorageLocationId=NULL, @FinalPieceDelta=10,
    @ScrapLinesJson=@ScrapLines8, @ShiftId=@Shift, @AppUserId=1, @TerminalLocationId=NULL;
DECLARE @rs8 NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @Rel8);
EXEC test.Assert_IsEqual @TestName=N'[Approver] a deprecated approvedByUserId is rejected, Status 0', @Expected=N'0', @Actual=@rs8;
DECLARE @rs8Msg NVARCHAR(500) = (SELECT Message FROM @Rel8);
EXEC test.Assert_IsEqual @TestName=N'[Approver] rejection carries the actionable message, not an unexpected-error',
    @Expected=N'A scrap line''s approver is not an active user; pick the approver again.', @Actual=@rs8Msg;
-- pre-transaction: no scrap row, and the basket is untouched (still Open, count 0)
DECLARE @rs8Rows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Workorder.RejectEvent WHERE LotId = @Lot8);
EXEC test.Assert_IsEqual @TestName=N'[Approver] the refused release wrote no RejectEvent row', @Expected=N'0', @Actual=@rs8Rows;
DECLARE @rs8State NVARCHAR(30) = (SELECT CONCAT(sc.Code, N'|', l.PieceCount) FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @Lot8);
EXEC test.Assert_IsEqual @TestName=N'[Approver] ...and the basket is untouched (rejected pre-transaction)',
    @Expected=N'Open|0', @Actual=@rs8State;

-- ---- cleanup (FK-safe, reverse order) ----
DELETE FROM Workorder.RejectEvent WHERE LotId IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8);
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8) OR (@ShiftCreatedByTest = 1 AND ShiftId = @Shift);
DELETE cl FROM Lots.LotGenealogyClosure cl WHERE cl.AncestorLotId IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8) OR cl.DescendantLotId IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8);
DELETE m  FROM Lots.LotMovement m WHERE m.LotId IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8);
DELETE h  FROM Lots.LotStatusHistory h WHERE h.LotId IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8);
DELETE le FROM Lots.LotEventLog le WHERE le.LotId IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8);
DELETE FROM Lots.Lot WHERE Id IN (@Lot, @Lot2, @Lot3, @Lot4, @Lot5, @Lot6, @Lot7, @Lot8);
-- the two approvers, only once every RejectEvent that referenced them is gone
DELETE FROM Location.AppUser WHERE Id IN (@RelApprover, @RelDepApprover);
DELETE FROM Tools.ToolCavity WHERE ToolId = @Tool;
DELETE FROM Tools.ToolAssignment WHERE ToolId = @Tool;
DELETE FROM Tools.Tool WHERE Id = @Tool;
IF @ShiftCreatedByTest = 1
    DELETE FROM Oee.Shift WHERE Id = @Shift;
GO
EXEC test.EndTestFile;
GO
