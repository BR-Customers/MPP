-- ============================================================
-- 2026-10-04_recon_scenarios_seed.sql
--
-- Seeds THREE die cast shift reconciliation scenarios onto MPP_MES_Dev so the
-- screen at /shop-floor/die-cast/reconcile can be driven by hand end to end.
-- Companion teardown: 2026-10-04_recon_scenarios_teardown.sql
-- Walkthrough:        notes/2026-10-04_diecast-reconciliation-scenario-walkthrough.md
--
--   1  WRONG NUMBERS      Machine 11  / DMO125 / Weekend First 10-04
--                         Three operator errors in ONE recorded entry: the
--                         counter reading typed with an extra digit (9910 for
--                         991), one basket typed with an extra digit (9530 for
--                         953), and 36 test parts recorded with no QAS approver.
--                         One basket has already been counted at Trim Out, so
--                         its count must stand while its production is still
--                         corrected.
--
--   2  SHIFT-END MISSED   Machine 202 / DM0144 / Weekend First 10-04
--      (caught mid-next-  Baskets released during the shift WITH counts and NO
--       shift)            counter reading -- the ReleasedNoShiftEnd shape that
--                         Machine 202 produced every shift of the week this
--                         feature was designed against. One basket was opened
--                         during the shift and is still open, so the shift's
--                         remaining production has somewhere to be credited.
--
--   3  CAUGHT DAYS LATER  3a Machine 305 / DMO126 / First 10-01  (4 days back)
--                            Nothing recorded at all -- NoEntry. Seeds NOTHING;
--                            every basket is created from paper at save time.
--                         3b Machine 304 / DMO145 / Third 09-24  (10 days back)
--                            ReleasedNoShiftEnd, deliberately OUTSIDE the
--                            landing list's seven-day window.
--
-- WHAT THIS WRITES, AND WHY IT IS RAW INSERTS AND NOT THE LIVE PROCS.
-- The live writers stamp the shift from "now" and refuse a die that is not
-- mounted now, so they cannot put recorded production into a past shift -- which
-- is the whole premise of all three scenarios. Every INSERT below therefore
-- mirrors a specific live writer, named in the comment above it, column for
-- column. The same approach, and the same mirroring rule, as
-- sql/tests/helpers/0097_fixture_diecast_reconciliation.sql.
--
-- Workorder.DieCastShiftReconciliation_ListEntries and _ListLots read ONLY
-- Workorder.DieCastContribution, Workorder.RejectEvent and Lots.Lot, so the
-- screen behaves exactly as it would against live-written rows.
--
-- REVERSIBILITY. Every LOT created here is named 777000xx. Nothing that already
-- exists on Dev is modified EXCEPT Tools.Tool.ShotCount on DMO125, which moves
-- because a recorded counter reading advances die life exactly as the live path
-- does. The before-values are captured in dbo.ReconScenarioSeedState, which the
-- teardown reads and then drops.
--
-- USAGE
--   @Commit = 0 (the committed default) runs every statement inside a
--   transaction and ROLLS BACK. It is a real execution, not a skip: a constraint
--   or a resolution failure surfaces here rather than on the run that lands.
--   Read the output, then set @Commit = 1 below and re-run. Leave it at 0 in the
--   repo -- never commit this script armed.
--
--   sqlcmd -S localhost -d MPP_MES_Dev -E -C -i sql\scratch\2026-10-04_recon_scenarios_seed.sql
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
-- sqlcmd defaults QUOTED_IDENTIFIER OFF, and Lots.Lot carries filtered indexes:
-- without this every INSERT fails with Msg 1934.
SET QUOTED_IDENTIFIER ON;

DECLARE @Commit BIT = 0;    -- 0 = preview + ROLLBACK, 1 = COMMIT

-- ------------------------------------------------------------
-- 0. resolve everything by code, never by hardcoded id
-- ------------------------------------------------------------
DECLARE @M11   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M11'   AND DeprecatedAt IS NULL);
DECLARE @M202  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC2-M202'  AND DeprecatedAt IS NULL);
DECLARE @M304  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC3-M304'  AND DeprecatedAt IS NULL);
DECLARE @M305  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC3-M305'  AND DeprecatedAt IS NULL);
DECLARE @Whse  BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE Code = N'WHSE' AND DeprecatedAt IS NULL ORDER BY Id);

DECLARE @T125  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DMO125');
DECLARE @T126  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DMO126');
DECLARE @T145  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DMO145');
DECLARE @T144  BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'DM0144');

DECLARE @Warm  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE Code = N'999' AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Test  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE Code = N'008' AND DeprecatedAt IS NULL ORDER BY Id);

-- The operator who made the entries, and the supervisor who will reconcile.
-- Deliberately different people: the "entered by" on each card must not be the
-- person signing in to fix it.
DECLARE @Op    BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'JD'  AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Sup   BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'JGP' AND DeprecatedAt IS NULL ORDER BY Id);

DECLARE @Origin   BIGINT = (SELECT Id FROM Lots.LotOriginType  WHERE Code = N'Manufactured');
DECLARE @StOpen   BIGINT = (SELECT Id FROM Lots.LotStatusCode  WHERE Code = N'Open');
DECLARE @StGood   BIGINT = (SELECT Id FROM Lots.LotStatusCode  WHERE Code = N'Good');
DECLARE @TrimOut  BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
                            INNER JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
                            WHERE oty.Code = N'TrimOut' AND ot.DeprecatedAt IS NULL AND ot.PublishedAt IS NOT NULL
                            ORDER BY ot.VersionNumber DESC, ot.Id DESC);

-- Shifts, resolved by Eastern date + schedule name so the script does not carry
-- an id that a Dev rebuild would renumber.
DECLARE @S1 BIGINT, @S1Next BIGINT, @S3a BIGINT, @S3b BIGINT;
SELECT @S1 = s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
 WHERE CAST(s.ActualStart AS DATE) = '2026-10-04' AND ss.Name = N'Weekend First';
SELECT @S1Next = s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
 WHERE CAST(s.ActualStart AS DATE) = '2026-10-04' AND ss.Name = N'Weekend Second';
-- Scenario 3a sits 4 days back ON PURPOSE. The landing list's window is seven
-- days (see 3b), so a shift chosen at 5-6 days back silently leaves the screen
-- after a day or two of slippage and the scenario then looks like the ceiling
-- bug instead of the case it is meant to show. 10-01 stays reachable until 10-08.
SELECT @S3a = s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
 WHERE CAST(s.ActualStart AS DATE) = '2026-10-01' AND ss.Name = N'First Shift';
SELECT @S3b = s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
 WHERE CAST(s.ActualStart AS DATE) = '2026-09-24' AND ss.Name = N'Third Shift';

-- Cavities on DMO125, in the press sheet's order (part, then letter).
DECLARE @Cav TABLE (Seq INT, CavId BIGINT, ItemId BIGINT, Ltt NVARCHAR(50), Pieces INT);
INSERT INTO @Cav (Seq, CavId, ItemId, Ltt, Pieces)
SELECT ROW_NUMBER() OVER (ORDER BY i.PartNumber, tc.CavityCode), tc.Id, tc.ItemId, NULL, 953
FROM Tools.ToolCavity tc
INNER JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
INNER JOIN Parts.Item i ON i.Id = tc.ItemId
WHERE tc.ToolId = @T125 AND tc.DeprecatedAt IS NULL AND cs.Code = N'Active';
UPDATE @Cav SET Ltt = N'777000' + RIGHT(N'0' + CAST(Seq AS NVARCHAR(2)), 2);
-- the two errors (see header): basket 02 is short AND already trimmed; basket 12
-- was typed with an extra digit.
UPDATE @Cav SET Pieces =  900 WHERE Seq = 2;
UPDATE @Cav SET Pieces = 9530 WHERE Seq = 12;

DECLARE @Cav126 BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @T126 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Cav145 BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @T145 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Cav144 BIGINT = (SELECT TOP 1 Id FROM Tools.ToolCavity WHERE ToolId = @T144 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Item144 BIGINT = (SELECT ItemId FROM Tools.ToolCavity WHERE Id = @Cav144);
DECLARE @Item145 BIGINT = (SELECT ItemId FROM Tools.ToolCavity WHERE Id = @Cav145);

-- ------------------------------------------------------------
-- 1. refuse to run on anything unresolved or already seeded
-- ------------------------------------------------------------
IF @M11 IS NULL OR @M202 IS NULL OR @M304 IS NULL OR @M305 IS NULL OR @Whse IS NULL
    OR @T125 IS NULL OR @T126 IS NULL OR @T145 IS NULL OR @T144 IS NULL
    OR @Warm IS NULL OR @Test IS NULL OR @Op IS NULL OR @Sup IS NULL
    OR @Origin IS NULL OR @StOpen IS NULL OR @StGood IS NULL OR @TrimOut IS NULL
    OR @S1 IS NULL OR @S1Next IS NULL OR @S3a IS NULL OR @S3b IS NULL
    OR @Cav126 IS NULL OR @Cav145 IS NULL OR @Cav144 IS NULL
BEGIN
    RAISERROR (N'Could not resolve a prerequisite. Presses DC1-M11/DC2-M202/DC3-M304/DC3-M305, dies DMO125/DMO126/DMO145/DM0144, WHSE, defect codes 999/008, users JD/JGP, a published TrimOut template, and the five shifts must all exist.', 16, 1);
    RETURN;
END
IF (SELECT COUNT(*) FROM @Cav) <> 12
BEGIN
    RAISERROR (N'Expected 12 active cavities on DMO125; the scenario 1 arithmetic (good shots x cavities) is built on that. Re-check the die.', 16, 1);
    RETURN;
END
IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName LIKE N'777000%')
BEGIN
    RAISERROR (N'777000xx LOTs already exist -- a previous seed is still in place. Run 2026-10-04_recon_scenarios_teardown.sql first.', 16, 1);
    RETURN;
END

-- shift windows, in UTC, derived from the Eastern wall clock Oee.Shift stores (OI-38)
DECLARE @S1StartUtc DATETIME2(3), @S1EndUtc DATETIME2(3), @S3bStartUtc DATETIME2(3);
SELECT @S1StartUtc = CAST(ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)),
       @S1EndUtc   = CAST(ActualEnd   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))
FROM Oee.Shift WHERE Id = @S1;
SELECT @S3bStartUtc    = CAST(ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) FROM Oee.Shift WHERE Id = @S3b;

BEGIN TRANSACTION;

-- ------------------------------------------------------------
-- 2. bookkeeping for the teardown
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.ReconScenarioSeedState') IS NOT NULL DROP TABLE dbo.ReconScenarioSeedState;
CREATE TABLE dbo.ReconScenarioSeedState (
    ToolId          BIGINT      NOT NULL PRIMARY KEY,
    ToolCode        NVARCHAR(50) NOT NULL,
    ShotCountBefore INT         NOT NULL,
    SeededAt        DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME());
INSERT INTO dbo.ReconScenarioSeedState (ToolId, ToolCode, ShotCountBefore)
SELECT Id, Code, ShotCount FROM Tools.Tool WHERE Id IN (@T125, @T126, @T145, @T144);

-- ============================================================
-- SCENARIO 1 -- Machine 11 / DMO125 / Weekend First 10-04
-- ============================================================
-- Twelve baskets, one per cavity, all released to the warehouse during the
-- shift. Mirrors Lots.DieCastLot_Mint (the Lot row, its opening status history,
-- the closure self-row and the opening movement) followed by
-- Lots.DieCastLot_ReleaseMove (Open -> Good, moved to storage, movement row).
DECLARE @Seq INT = 1, @CavId BIGINT, @ItemId BIGINT, @Ltt NVARCHAR(50), @Pieces INT, @LotId BIGINT;
DECLARE @OpenAt DATETIME2(3), @RelAt DATETIME2(3);

WHILE @Seq <= 12
BEGIN
    SELECT @CavId = CavId, @ItemId = ItemId, @Ltt = Ltt, @Pieces = Pieces FROM @Cav WHERE Seq = @Seq;
    -- opened early in the shift, released near the end of it
    SET @OpenAt = DATEADD(MINUTE, 20 + @Seq, @S1StartUtc);
    SET @RelAt  = DATEADD(MINUTE, -40 + @Seq, @S1EndUtc);

    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                          ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
                          CreatedByUserId, CreatedAt, CrtActive, CastDate, ProducedAtLocationId)
    SELECT @Ltt, @ItemId, @Origin, @StGood, @Pieces, i.MaxLotSize,
           @T125, @CavId, @Whse, 0, @Pieces,
           @Op, @OpenAt, 0,
           CAST(CAST(@OpenAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE), @M11
    FROM Parts.Item i WHERE i.Id = @ItemId;
    SET @LotId = SCOPE_IDENTITY();

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, ChangedAt)
    VALUES (@LotId, NULL, @StOpen, N'Die-cast basket opened.', @Op, @OpenAt),
           (@LotId, @StOpen, @StGood, N'Die-cast basket released to storage.', @Op, @RelAt);
    INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotId, @LotId, 0);
    INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt)
    VALUES (@LotId, NULL, @M11, @Op, @OpenAt), (@LotId, @M11, @Whse, @Op, @RelAt);

    SET @Seq += 1;
END

-- The shift-end entry: ONE entry, twelve contribution rows written within a few
-- seconds of each other so _ListEntries groups them onto one card. Mirrors
-- Workorder.DieCastCredit_Write. THE ERROR: the reading was typed 9910 for 991.
-- Every row carries it, which is what Workorder.DieCastShiftOutput_Record does.
DECLARE @EntryAt DATETIME2(3) = DATEADD(MINUTE, -5, @S1EndUtc);
INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId)
SELECT l.Id, @S1, c.Pieces, @Op, DATEADD(SECOND, c.Seq, @EntryAt), @M11, 9910, c.CavId
FROM @Cav c INNER JOIN Lots.Lot l ON l.LotName = c.Ltt;

-- Warm-up, 35 shots on each of the twelve cavities. Mirrors
-- Workorder.DieCastScrap_Write's die-wide fan-out: one row per cavity, its own
-- ToolId / ItemId / CellLocationId stamped (0084), LotId NULL.
INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                   DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt, ApprovedByUserId)
SELECT NULL, NULL, c.ItemId, @T125, c.CavId, @S1, @M11, @Warm, 35, N'Warm-up', @Op,
       DATEADD(SECOND, 20 + c.Seq, @EntryAt), NULL
FROM @Cav c;

-- 36 test parts, "All" -- 3 on each of the twelve cavities (A7: an All line must
-- divide evenly across the cavities it covers).
-- THE ERROR: the QAS signed the paper and nobody keyed it. ApprovedByUserId NULL.
INSERT INTO Workorder.RejectEvent (ProductionEventId, LotId, ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId,
                                   DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt, ApprovedByUserId)
SELECT NULL, NULL, c.ItemId, @T125, c.CavId, @S1, @M11, @Test, 3, N'Test parts', @Op,
       DATEADD(SECOND, 40 + c.Seq, @EntryAt), NULL
FROM @Cav c;

-- Die life as the live path advanced it: the reading, minus a watermark of zero.
UPDATE Tools.Tool SET ShotCount = ShotCount + 9910, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @Op
WHERE Id = @T125;

-- Basket 02 went to trim and was counted there, so its count must STAND while
-- its production is still corrected (spec 3.3, D3 firm lock). One
-- Workorder.ProductionEvent at a non-DieCast operation is what
-- Lots.ufn_DieCastLotCountLock reads.
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, AppUserId, Remarks, ShiftId)
SELECT l.Id, @TrimOut, DATEADD(HOUR, 3, @S1EndUtc), @Op, N'Counted at trim (scenario seed)', @S1Next
FROM Lots.Lot l WHERE l.LotName = N'77700002';

-- ============================================================
-- SCENARIO 2 -- Machine 202 / DM0144 / Weekend First 10-04
-- ============================================================
-- Three baskets released DURING the shift with a count and NO counter reading.
-- Mirrors Lots.DieCastLot_Release called with @FinalPieceDelta and
-- @CounterReading = NULL: the contribution row carries a NULL reading, so
-- neither watermark moves and die life does not advance (spec sec 9). That is
-- what makes the shift ReleasedNoShiftEnd.
DECLARE @S2 TABLE (Ltt NVARCHAR(50), Pieces INT, OpenMin INT, RelMin INT);
INSERT INTO @S2 VALUES (N'77700021', 500, 15, 150), (N'77700022', 500, 155, 300), (N'77700023', 450, 305, 450);

DECLARE @L NVARCHAR(50), @P INT, @OM INT, @RM INT;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Ltt, Pieces, OpenMin, RelMin FROM @S2;
OPEN cur; FETCH NEXT FROM cur INTO @L, @P, @OM, @RM;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OpenAt = DATEADD(MINUTE, @OM, @S1StartUtc);
    SET @RelAt  = DATEADD(MINUTE, @RM, @S1StartUtc);

    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                          ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
                          CreatedByUserId, CreatedAt, CrtActive, CastDate, ProducedAtLocationId)
    SELECT @L, @Item144, @Origin, @StGood, @P, i.MaxLotSize, @T144, @Cav144, @Whse, 0, @P, @Op, @OpenAt, 0,
           CAST(CAST(@OpenAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE), @M202
    FROM Parts.Item i WHERE i.Id = @Item144;
    SET @LotId = SCOPE_IDENTITY();

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, ChangedAt)
    VALUES (@LotId, NULL, @StOpen, N'Die-cast basket opened.', @Op, @OpenAt),
           (@LotId, @StOpen, @StGood, N'Die-cast basket released to storage.', @Op, @RelAt);
    INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotId, @LotId, 0);
    INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt)
    VALUES (@LotId, NULL, @M202, @Op, @OpenAt), (@LotId, @M202, @Whse, @Op, @RelAt);

    -- the credit, with NO reading -- this is the whole point of scenario 2
    INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId)
    VALUES (@LotId, @S1, @P, @Op, @RelAt, @M202, NULL, @Cav144);

    FETCH NEXT FROM cur INTO @L, @P, @OM, @RM;
END
CLOSE cur; DEALLOCATE cur;

-- A basket opened late in the shift and STILL OPEN. No contribution: it has not
-- been credited yet. _ListLots reaches it through its CreatedAt-inside-the-shift
-- branch and shows it at Recorded 0.
SET @OpenAt = DATEADD(MINUTE, 460, @S1StartUtc);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                      ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
                      CreatedByUserId, CreatedAt, CrtActive, CastDate, ProducedAtLocationId)
SELECT N'77700024', @Item144, @Origin, @StOpen, 0, i.MaxLotSize, @T144, @Cav144, @M202, 0, 0, @Op, @OpenAt, 0,
       CAST(CAST(@OpenAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE), @M202
FROM Parts.Item i WHERE i.Id = @Item144;
SET @LotId = SCOPE_IDENTITY();
INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, ChangedAt)
VALUES (@LotId, NULL, @StOpen, N'Die-cast basket opened.', @Op, @OpenAt);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotId, @LotId, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt)
VALUES (@LotId, NULL, @M202, @Op, @OpenAt);

-- NO SPANNING-BASKET PROBE HERE, and the reason is a plant fact, not an
-- oversight. An earlier draft seeded one: a basket opened in the previous shift
-- and released in the next, spanning the shift being reconciled with no event
-- inside it, to show that Workorder.DieCastShiftReconciliation_ListLots offers
-- neither branch for it (no contribution IN the shift, CreatedAt before it).
--
-- It is PHYSICALLY IMPOSSIBLE on this press. DM0144 has ONE cavity, and
-- Lots.DieCastLot_Open enforces one open basket per (Tool, ToolCavity), so a
-- basket that spans the whole shift IS the only basket on that cavity -- it
-- cannot coexist with the three releases above. (The guard is in the proc, not
-- a unique index, so a raw INSERT like this one slips past it and produces a
-- state the plant cannot reach. That is exactly what the earlier draft did.)
--
-- Spanning is real -- Jacques, 2026-10-04: a basket can span an entire shift or
-- even two -- but the shift-end entry credits the open basket on every cavity
-- (Workorder.DieCast_GetShiftOutputBreakdown proposes reading minus the cavity
-- watermark; Workorder.DieCastShiftOutput_Record writes it), so a spanning
-- basket normally HAS a contribution in each shift it spans and _ListLots finds
-- it. The hole only opens where a MULTI-CAVITY die had its shift-end missed:
-- that needs its own scenario on its own press, not a row smuggled in here.

-- ============================================================
-- SCENARIO 3a -- Machine 305 / DMO126 / First 10-01
-- ============================================================
-- Nothing is seeded, deliberately. The shift must read NoEntry: no production,
-- no scrap, no anchor, no header. Every basket is created from paper at save
-- time, which is the case this scenario exists to exercise.

-- ============================================================
-- SCENARIO 3b -- Machine 304 / DMO145 / Third 09-24 (10 days back)
-- ============================================================
-- The same ReleasedNoShiftEnd shape as scenario 2, placed OUTSIDE the landing
-- list's seven-day window on purpose. Two baskets released with counts and no
-- reading; the shift is a genuine finding that the screen cannot reach.
DECLARE @S3bLtt TABLE (Ltt NVARCHAR(50), Pieces INT, OpenMin INT, RelMin INT);
INSERT INTO @S3bLtt VALUES (N'77700041', 300, 20, 220), (N'77700042', 300, 225, 430);

DECLARE cur2 CURSOR LOCAL FAST_FORWARD FOR SELECT Ltt, Pieces, OpenMin, RelMin FROM @S3bLtt;
OPEN cur2; FETCH NEXT FROM cur2 INTO @L, @P, @OM, @RM;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OpenAt = DATEADD(MINUTE, @OM, @S3bStartUtc);
    SET @RelAt  = DATEADD(MINUTE, @RM, @S3bStartUtc);

    INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, MaxPieceCount,
                          ToolId, ToolCavityId, CurrentLocationId, TotalInProcess, InventoryAvailable,
                          CreatedByUserId, CreatedAt, CrtActive, CastDate, ProducedAtLocationId)
    SELECT @L, @Item145, @Origin, @StGood, @P, i.MaxLotSize, @T145, @Cav145, @Whse, 0, @P, @Op, @OpenAt, 0,
           CAST(CAST(@OpenAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS DATE), @M304
    FROM Parts.Item i WHERE i.Id = @Item145;
    SET @LotId = SCOPE_IDENTITY();

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, ChangedAt)
    VALUES (@LotId, NULL, @StOpen, N'Die-cast basket opened.', @Op, @OpenAt),
           (@LotId, @StOpen, @StGood, N'Die-cast basket released to storage.', @Op, @RelAt);
    INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotId, @LotId, 0);
    INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt)
    VALUES (@LotId, NULL, @M304, @Op, @OpenAt), (@LotId, @M304, @Whse, @Op, @RelAt);

    INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShotCounterReading, ToolCavityId)
    VALUES (@LotId, @S3b, @P, @Op, @RelAt, @M304, NULL, @Cav145);

    FETCH NEXT FROM cur2 INTO @L, @P, @OM, @RM;
END
CLOSE cur2; DEALLOCATE cur2;

-- ------------------------------------------------------------
-- 3. what landed
-- ------------------------------------------------------------
PRINT N'--- seeded -------------------------------------------';
PRINT N'scenario 1  Machine 11  shift ' + CAST(@S1 AS NVARCHAR(20)) + N'  12 baskets, reading 9910 (actual 991)';
PRINT N'scenario 2  Machine 202 shift ' + CAST(@S1 AS NVARCHAR(20)) + N'  3 released no-reading + 1 open + 1 probe';
PRINT N'scenario 3a Machine 305 shift ' + CAST(@S3a AS NVARCHAR(20)) + N'  nothing seeded (NoEntry)';
PRINT N'scenario 3b Machine 304 shift ' + CAST(@S3b AS NVARCHAR(20)) + N'  2 released no-reading, outside the 7-day window';

SELECT l.LotName, t.Code AS Die, loc.Code AS Press, sc.Code AS Status, l.PieceCount, l.InventoryAvailable,
       (SELECT COUNT(*) FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id) AS ContribRows,
       (SELECT ISNULL(SUM(c.PieceDelta),0) FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id) AS Credited,
       (SELECT MAX(c.ShotCounterReading) FROM Workorder.DieCastContribution c WHERE c.LotId = l.Id) AS Reading,
       lk.IsLocked, lk.LockReason
FROM Lots.Lot l
INNER JOIN Tools.Tool t ON t.Id = l.ToolId
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
LEFT JOIN Location.Location loc ON loc.Id = l.ProducedAtLocationId
OUTER APPLY Lots.ufn_DieCastLotCountLock(l.Id) lk
WHERE l.LotName LIKE N'777000%'
ORDER BY l.LotName;

SELECT t.Code AS Die, st.ShotCountBefore, t.ShotCount AS ShotCountNow,
       Workorder.ufn_DieShotWatermark(t.Id, @S1, CASE t.Code WHEN N'DMO125' THEN @M11 ELSE @M202 END) AS WatermarkShift1
FROM dbo.ReconScenarioSeedState st INNER JOIN Tools.Tool t ON t.Id = st.ToolId
ORDER BY t.Code;

IF @Commit = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT N'COMMITTED. Teardown: sql\scratch\2026-10-04_recon_scenarios_teardown.sql';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'ROLLED BACK (preview). Everything above executed and was undone. Set @Commit = 1 at the top and re-run to land it.';
END
GO
