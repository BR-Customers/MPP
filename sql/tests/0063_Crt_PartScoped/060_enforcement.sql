-- =============================================
-- File:         0063_Crt_PartScoped/060_enforcement.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-20
-- Description:  CRT ENFORCEMENT (design D4 + D5, part-scoped CRT Task 5). The
--               guards from Task 3 (Lots.ufn_CrtBlocksAdvance /
--               Lots.ufn_CrtBlocksMoveTo) finally bite inside the procs:
--
--                 A. Lots.Lot_MoveTo          - a CRT LOT cannot move to a
--                                               PRODUCTION destination, CAN move to
--                                               inspection/inventory (D5), a CLEAN
--                                               LOT moves to production freely, and
--                                               the pre-existing Hold/Scrap/Closed
--                                               rejection still takes PRECEDENCE.
--                 B. Lots.Lot_MoveToValidated - the same D5 rule on the validated
--                                               sibling, both directions, with a
--                                               clean-LOT control proving the
--                                               fixture actually reaches the guard
--                                               (otherwise a rejection could be the
--                                               eligibility or MaxParts guard
--                                               firing and the test would pass
--                                               vacuously).
--                 C. Workorder.MachiningIn_RecordPick - a CRT LOT cannot be picked
--                                               into a machining line, and the
--                                               rejection writes NOTHING (no claim
--                                               move off Trim Storage, no
--                                               ProductionEvent). A clean twin of
--                                               the same fixture is picked as the
--                                               control.
--                 D. Workorder.MachiningOut_Mint - a CRT casting cannot be scanned
--                                               as the consume-mint handle. A clean
--                                               casting mints first as the control.
--
--               THE MOST IMPORTANT ASSERTIONS HERE ARE THE NEGATIVE ONES. A guard
--               that blocked everything would satisfy every "is it blocked" check;
--               the "quarantine allowed" / "clean LOT proceeds" cases are what
--               prove the guard is destination-aware and CRT-scoped rather than a
--               blanket refusal.
--
--               Fixture notes:
--                 * Run-Tests.ps1 resets with -SkipDemoSeed, so Lots.Lot starts
--                   EMPTY and holds only what earlier test files created. This file
--                   INSERTs / mints its own LOTs under names unique to it
--                   (CRT060-*) and never borrows an existing LOT, whose status,
--                   hold state and location are another file's business.
--                 * Deliberately no 'Receiving' location: that definition exists in
--                   the hand-built dev database but no migration or seed creates
--                   it, so a rebuilt test database has none.
--                 * Section C mirrors 0027/010's Trim-Storage fixture (casting
--                   5G0-c, line MA1-5GOF, store TRIM1-STORE, terminal
--                   MA1-5GOF-MIN) with the pre-machining route steps pre-stamped so
--                   the next pending step is MachiningIn.
--                 * Section D mirrors 0027/070 + 0063/050 section C (casting
--                   12270-6NA -> sub-assembly 12270-6NA-M at MA1-FP6NA-MOUT, BOM
--                   auto-created if absent) and CLOSES whatever earlier files left
--                   open at that line so the FIFO queue holds exactly this file's
--                   castings.
--                 * Every temp table matches its proc's result shape EXACTLY
--                   (Lot_MoveTo 2 cols, Lot_MoveToValidated 2, Hold_Place 3,
--                   Lot_Create 4, MachiningIn_RecordPick 3, MachiningOut_Mint 4).
--                   A mismatched INSERT-EXEC aborts the whole file with Msg 213 as
--                   a runner ERROR, not as a FAIL.
--                 * EXEC arguments are variables only (never an inline CAST / CASE),
--                   so every asserted value is materialised into an NVARCHAR local
--                   first.
--
--               Teardown untags and closes every LOT this file created.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/060_enforcement.sql';
GO

-- =============================================
-- A. Lots.Lot_MoveTo -- destination-aware block (D5) + hold precedence.
-- =============================================
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

DECLARE @ProdLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);
DECLARE @StartLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 1 AND l.DeprecatedAt IS NULL AND l.Id <> @ProdLoc
    ORDER BY l.Id DESC);
DECLARE @SafeLoc BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    WHERE d.IsProductionDestination = 0
      AND d.Code IN (N'InventoryLocation', N'InspectionStation')
      AND l.DeprecatedAt IS NULL ORDER BY l.Id);

-- Fail loudly if the fixture did not resolve, rather than passing vacuously later.
DECLARE @fixtureOk NVARCHAR(10) = CASE WHEN @ProdLoc IS NOT NULL AND @StartLoc IS NOT NULL
                                        AND @SafeLoc IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] fixture: production + non-production destinations resolved',
    @Expected = N'1', @Actual = @fixtureOk;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT060-MV-CRT', @Item, @Mfg, @Good, 10, 10, @StartLoc, 1, SYSUTCDATETIME(), 1);
DECLARE @LotCrt BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotCrt, @LotCrt, 0);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT060-MV-OK', @Item, @Mfg, @Good, 10, 10, @StartLoc, 1, SYSUTCDATETIME(), 0);
DECLARE @LotOk BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotOk, @LotOk, 0);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT060-MV-HELD', @Item, @Mfg, @Good, 10, 10, @StartLoc, 1, SYSUTCDATETIME(), 1);
DECLARE @LotHeld BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotHeld, @LotHeld, 0);

CREATE TABLE #m (Status BIT, Message NVARCHAR(500));
DECLARE @message NVARCHAR(500);
DECLARE @actual  NVARCHAR(50);
DECLARE @expect  NVARCHAR(50);
DECLARE @before  INT = (SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @LotCrt);

-- A1. CRT LOT -> PRODUCTION destination is rejected, and writes nothing.
INSERT INTO #m EXEC Lots.Lot_MoveTo @LotId = @LotCrt, @ToLocationId = @ProdLoc, @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #m;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveTo: CRT LOT to a production destination is rejected',
    @Expected = N'0', @Actual = @actual;
EXEC test.Assert_Contains @TestName = N'[Enforce] Lot_MoveTo: the rejection names CRT',
    @HaystackStr = @message, @NeedleStr = N'CRT';

SET @actual = CAST((SELECT COUNT(*) FROM Lots.LotMovement WHERE LotId = @LotCrt) - @before AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveTo: the rejection wrote no LotMovement row',
    @Expected = N'0', @Actual = @actual;

SET @actual = CAST((SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotCrt) AS NVARCHAR(50));
SET @expect = CAST(@StartLoc AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveTo: the rejected LOT did not move',
    @Expected = @expect, @Actual = @actual;

-- A2. THE KEY NEGATIVE CASE. The same CRT LOT CAN still be taken to inspection /
--     inventory -- quarantine has to stay reachable, or the guard is just a wall.
DELETE FROM #m;
INSERT INTO #m EXEC Lots.Lot_MoveTo @LotId = @LotCrt, @ToLocationId = @SafeLoc, @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #m;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveTo: CRT LOT to inspection/inventory is ALLOWED',
    @Expected = N'1', @Actual = @actual;

SET @actual = CAST((SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @LotCrt) AS NVARCHAR(50));
SET @expect = CAST(@SafeLoc AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveTo: the allowed move actually landed',
    @Expected = @expect, @Actual = @actual;

-- A3. A CLEAN LOT moves to production freely (the guard is CRT-scoped).
DELETE FROM #m;
INSERT INTO #m EXEC Lots.Lot_MoveTo @LotId = @LotOk, @ToLocationId = @ProdLoc, @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)) FROM #m;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveTo: a clean LOT still moves to production',
    @Expected = N'1', @Actual = @actual;

-- A4. PRECEDENCE. A LOT that is BOTH held and CRT is rejected for the HOLD -- the
--     pre-existing B2 guard runs first and its message is what the operator sees.
CREATE TABLE #h (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #h EXEC Quality.Hold_Place @LotId = @LotHeld, @HoldTypeCodeId = 1,
    @Reason = N'CRT enforcement precedence fixture', @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)) FROM #h;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] fixture: hold placed on the held+CRT LOT',
    @Expected = N'1', @Actual = @actual;

DELETE FROM #m;
INSERT INTO #m EXEC Lots.Lot_MoveTo @LotId = @LotHeld, @ToLocationId = @ProdLoc, @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #m;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveTo: a held+CRT LOT is rejected',
    @Expected = N'0', @Actual = @actual;
EXEC test.Assert_Contains @TestName = N'[Enforce] Lot_MoveTo: held+CRT is rejected for the HOLD, not CRT',
    @HaystackStr = @message, @NeedleStr = N'Hold';

DROP TABLE #m;
DROP TABLE #h;
GO

-- =============================================
-- B. Lots.Lot_MoveToValidated -- the same D5 rule on the validated sibling.
--    Item selection demands BOTH a reachable production destination and a
--    reachable inspection/inventory one, and MaxParts NULL (uncapped), so the
--    only guard that can fire is the CRT one.
-- =============================================
DECLARE @ItemV BIGINT, @VProd BIGINT, @VSafe BIGINT;

;WITH Reach AS (
    SELECT eil.ItemId, l.Id AS LocationId, d.IsProductionDestination, d.Code AS DefCode
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
    CROSS APPLY Location.ufn_AncestorLocationIds(l.Id) a
    INNER JOIN Parts.v_EffectiveItemLocation eil ON eil.LocationId = a.LocationId
    WHERE l.DeprecatedAt IS NULL
)
SELECT TOP 1 @ItemV = p.ItemId, @VProd = p.LocationId, @VSafe = s.LocationId
FROM Reach p
INNER JOIN Reach s ON s.ItemId = p.ItemId
INNER JOIN Parts.Item i ON i.Id = p.ItemId
WHERE p.IsProductionDestination = 1
  AND s.IsProductionDestination = 0
  AND s.DefCode IN (N'InventoryLocation', N'InspectionStation')
  AND i.MaxParts IS NULL
ORDER BY p.ItemId, p.LocationId, s.LocationId;

DECLARE @fixtureOk NVARCHAR(10) = CASE WHEN @ItemV IS NOT NULL AND @VProd IS NOT NULL
                                        AND @VSafe IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] fixture: MoveToValidated item reaches both destination kinds',
    @Expected = N'1', @Actual = @fixtureOk;

DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- The CRT LOT starts AT the production destination, so the allowed direction
-- (production -> inventory/inspection) can be exercised first with no setup move.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT060-MVV-CRT', @ItemV, @Mfg, @Good, 5, 5, @VProd, 1, SYSUTCDATETIME(), 1);
DECLARE @LotV1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotV1, @LotV1, 0);

CREATE TABLE #v (Status BIT, Message NVARCHAR(500));
DECLARE @message NVARCHAR(500);
DECLARE @actual  NVARCHAR(50);

-- B1. THE KEY NEGATIVE CASE on this proc: CRT LOT -> inspection/inventory succeeds.
INSERT INTO #v EXEC Lots.Lot_MoveToValidated @LotId = @LotV1, @ToLocationId = @VSafe, @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #v;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveToValidated: CRT LOT to inspection/inventory is ALLOWED',
    @Expected = N'1', @Actual = @actual;

-- B2. The same LOT, now at the safe location, cannot go back to production.
DELETE FROM #v;
INSERT INTO #v EXEC Lots.Lot_MoveToValidated @LotId = @LotV1, @ToLocationId = @VProd, @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #v;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveToValidated: CRT LOT to a production destination is rejected',
    @Expected = N'0', @Actual = @actual;
EXEC test.Assert_Contains @TestName = N'[Enforce] Lot_MoveToValidated: the rejection names CRT',
    @HaystackStr = @message, @NeedleStr = N'CRT';

-- B3. CONTROL: an identical CLEAN LOT makes the very same move. Without this the
--     B2 rejection could just as well be the eligibility or MaxParts guard firing.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT060-MVV-OK', @ItemV, @Mfg, @Good, 5, 5, @VSafe, 1, SYSUTCDATETIME(), 0);
DECLARE @LotV2 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotV2, @LotV2, 0);

DELETE FROM #v;
INSERT INTO #v EXEC Lots.Lot_MoveToValidated @LotId = @LotV2, @ToLocationId = @VProd, @AppUserId = 1;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #v;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] Lot_MoveToValidated: a clean LOT makes the same move',
    @Expected = N'1', @Actual = @actual;

DROP TABLE #v;
GO

-- =============================================
-- C. Workorder.MachiningIn_RecordPick -- a CRT LOT cannot be picked onto a line.
--    Fixture mirrors 0027/010 (Trim-Storage claim model).
-- =============================================
DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @Line   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @Store  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-STORE');
DECLARE @Term   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT060-MIN-CRT', @Item, @Origin, @Good, 40, 40, @Store, 1, SYSUTCDATETIME(), 1);
DECLARE @PickCrt BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@PickCrt, @PickCrt, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt)
VALUES (@PickCrt, NULL, @Store, 1, SYSUTCDATETIME());

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable,
                      CurrentLocationId, CreatedByUserId, CreatedAt, CrtActive)
VALUES (N'CRT060-MIN-OK', @Item, @Origin, @Good, 40, 40, @Store, 1, SYSUTCDATETIME(), 0);
DECLARE @PickOk BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@PickOk, @PickOk, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt)
VALUES (@PickOk, NULL, @Store, 1, SYSUTCDATETIME());

-- Pre-advance past DieCast/TrimIn/TrimOut so the next pending step is MachiningIn.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT x.LotId, rs.OperationTemplateId, SYSUTCDATETIME(), 40, 1
FROM (SELECT @PickCrt AS LotId UNION ALL SELECT @PickOk) x
CROSS JOIN Parts.RouteTemplate rt
INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = @Item AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND oty.Code IN (N'DieCast', N'TrimIn', N'TrimOut');

CREATE TABLE #p (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @message NVARCHAR(500);
DECLARE @actual  NVARCHAR(50);
DECLARE @expect  NVARCHAR(50);
DECLARE @peBefore INT = (SELECT COUNT(*) FROM Workorder.ProductionEvent WHERE LotId = @PickCrt);

-- C1. The CRT LOT is refused...
INSERT INTO #p EXEC Workorder.MachiningIn_RecordPick @LotId = @PickCrt,
    @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #p;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningIn_RecordPick: a CRT LOT is rejected',
    @Expected = N'0', @Actual = @actual;
EXEC test.Assert_Contains @TestName = N'[Enforce] MachiningIn_RecordPick: the rejection names CRT',
    @HaystackStr = @message, @NeedleStr = N'CRT';

-- ...and the rejection wrote nothing: no claim move off Trim Storage, no checkpoint.
SET @actual = CAST((SELECT COUNT(*) FROM Workorder.ProductionEvent WHERE LotId = @PickCrt) - @peBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningIn_RecordPick: the rejection wrote no ProductionEvent',
    @Expected = N'0', @Actual = @actual;

SET @actual = CAST((SELECT CurrentLocationId FROM Lots.Lot WHERE Id = @PickCrt) AS NVARCHAR(50));
SET @expect = CAST(@Store AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningIn_RecordPick: the rejected LOT stayed in Trim Storage',
    @Expected = @expect, @Actual = @actual;

-- C2. CONTROL: the clean twin is picked, proving the fixture really reaches the guard.
DELETE FROM #p;
INSERT INTO #p EXEC Workorder.MachiningIn_RecordPick @LotId = @PickOk,
    @LineLocationId = @Line, @AppUserId = 1, @TerminalLocationId = @Term;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM #p;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningIn_RecordPick: the clean twin is picked',
    @Expected = N'1', @Actual = @actual;

DROP TABLE #p;
GO

-- =============================================
-- D. Workorder.MachiningOut_Mint -- a CRT casting cannot be scanned as the
--    consume-mint handle. Fixture mirrors 0027/070 + 0063/050 section C.
-- =============================================
DECLARE @Casting  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @Machined BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @Line     BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT');
DECLARE @Origin   BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Uom      BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @GoodSt   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @ClosedSt BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @MoTpl BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
    INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
    INNER JOIN Parts.OperationRoleKind rk ON rk.Id = oty.OperationRoleKindId
    WHERE oty.Code = N'MachiningOut' AND rk.Code = N'ConsumeMint' AND ot.DeprecatedAt IS NULL);

-- Neither part carries the part flag: only the explicit CrtActive stamp below is live.
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id IN (@Casting, @Machined);

-- Fixture BOM 12270-6NA-M <- 12270-6NA x1 (0027/070 creates it; guard for a
-- filtered run of this directory alone).
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Machined
               AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
    INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId = @Machined, @AppUserId = 1;
    DECLARE @Bom BIGINT = (SELECT NewId FROM @bc);
    INSERT INTO @bl EXEC Parts.BomLine_Add @BomId = @Bom, @ChildItemId = @Casting,
        @QtyPer = 1, @UomId = @Uom, @AppUserId = 1;
    INSERT INTO @bp EXEC Parts.Bom_Publish @Id = @Bom, @AppUserId = 1;
END

-- Close whatever earlier files left open at this line so the FIFO queue is exactly
-- this file's castings.
UPDATE Lots.Lot SET LotStatusId = @ClosedSt
WHERE ItemId = @Casting AND CurrentLocationId = @Line AND LotStatusId = @GoodSt;

DECLARE @cc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @mo TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
DECLARE @message NVARCHAR(500);
DECLARE @actual  NVARCHAR(50);

-- D1. CONTROL FIRST: a CLEAN casting mints normally, proving the fixture is sound.
INSERT INTO @cc EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 4, @AppUserId = 1;
DECLARE @CleanCast BIGINT = (SELECT TOP 1 NewId FROM @cc);

INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @CleanCast, rs.OperationTemplateId, SYSUTCDATETIME(), 4, 1
FROM Parts.RouteTemplate rt
INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND rs.OperationTemplateId <> @MoTpl;

INSERT INTO @mo EXEC Workorder.MachiningOut_Mint @SourceLotId = @CleanCast,
    @OperationTemplateId = @MoTpl, @PieceCount = 4, @AppUserId = 1, @TerminalLocationId = @Line;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM @mo;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningOut_Mint: a clean casting still mints',
    @Expected = N'1', @Actual = @actual;
DECLARE @CleanMinted BIGINT = (SELECT TOP 1 NewId FROM @mo);

-- Close everything again so the CRT casting below is the whole queue.
UPDATE Lots.Lot SET LotStatusId = @ClosedSt
WHERE ItemId = @Casting AND CurrentLocationId = @Line AND LotStatusId = @GoodSt;

-- D2. A CRT casting scanned as the consume-mint handle is refused.
DELETE FROM @cc;
INSERT INTO @cc EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 4, @AppUserId = 1;
DECLARE @CrtCast BIGINT = (SELECT TOP 1 NewId FROM @cc);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @CrtCast;

INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT @CrtCast, rs.OperationTemplateId, SYSUTCDATETIME(), 4, 1
FROM Parts.RouteTemplate rt
INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND rs.OperationTemplateId <> @MoTpl;

DECLARE @ceBefore INT = (SELECT COUNT(*) FROM Workorder.ConsumptionEvent WHERE SourceLotId = @CrtCast);

DELETE FROM @mo;
INSERT INTO @mo EXEC Workorder.MachiningOut_Mint @SourceLotId = @CrtCast,
    @OperationTemplateId = @MoTpl, @PieceCount = 4, @AppUserId = 1, @TerminalLocationId = @Line;
SELECT TOP 1 @actual = CAST(Status AS NVARCHAR(10)), @message = Message FROM @mo;
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningOut_Mint: a CRT casting is rejected',
    @Expected = N'0', @Actual = @actual;
EXEC test.Assert_Contains @TestName = N'[Enforce] MachiningOut_Mint: the rejection names CRT',
    @HaystackStr = @message, @NeedleStr = N'CRT';

SET @actual = CAST((SELECT COUNT(*) FROM Workorder.ConsumptionEvent WHERE SourceLotId = @CrtCast) - @ceBefore AS NVARCHAR(10));
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningOut_Mint: the rejection consumed nothing',
    @Expected = N'0', @Actual = @actual;

SET @actual = CAST((SELECT PieceCount FROM Lots.Lot WHERE Id = @CrtCast) AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Enforce] MachiningOut_Mint: the CRT casting is untouched',
    @Expected = N'4', @Actual = @actual;

-- ---- Teardown: close and untag everything this section created so no later file
--      inherits a tagged or open LOT at this line. ----
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id IN (@CleanCast, @CrtCast, @CleanMinted);
UPDATE Lots.Lot SET LotStatusId = @ClosedSt
WHERE ItemId = @Casting AND CurrentLocationId = @Line AND LotStatusId = @GoodSt;
GO

-- ---- File teardown: untag and close every LOT this file created. ----
UPDATE Lots.Lot SET CrtActive = 0 WHERE LotName LIKE N'CRT060-%';
UPDATE Lots.Lot SET LotStatusId = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed')
WHERE LotName LIKE N'CRT060-%';
GO

EXEC test.EndTestFile;
GO
