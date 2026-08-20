-- =============================================
-- File:         0063_Crt_PartScoped/050_mint_procs.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-20
-- Description:  End-to-end CrtActive assertions THROUGH the five mint procs that
--               commit 5b2b4e97 wired to Lots.ufn_CrtForMint. 040_propagation.sql
--               covers the resolver + Lot_Create's part arm; this file covers the
--               four call sites nothing asserted, plus Lot_Create's TERMINAL arm:
--
--                 A. Lots.Lot_Split            - CRT parent -> every child CRT;
--                                                clean parent -> every child clean.
--                 B. Lots.Lot_Merge            - one CRT source among N taints the
--                                                blend (the laundering guard);
--                                                all-clean sources stay clean.
--                 C. Workorder.MachiningOut_Mint - a CRT casting SECOND in FIFO
--                                                order still taints the minted
--                                                sub-assembly. This is the exact
--                                                containment escape the post-consume
--                                                re-resolve exists to close, so the
--                                                file first asserts the walk really
--                                                DID roll into the second casting
--                                                (2 Consumption parents) -- otherwise
--                                                a CrtActive=1 could pass vacuously.
--                 D. Workorder.Assembly_CompleteTray step B4b - a CRT sub-assembly
--                                                consumed into an UNFLAGGED FG at an
--                                                UNFLAGGED terminal still yields a
--                                                CRT finished good. 0056/030 covers
--                                                only the terminal arm at this proc.
--                 E. Lots.Lot_Create terminal arm - every Lot_Create call in
--                                                040_propagation.sql omits
--                                                @TerminalLocationId, so arm 2 is
--                                                never exercised through the proc.
--
--               Fixture notes:
--                 * A and B reuse the 020_Lot_Split / 030_Lot_Merge selector: an
--                   uncapped (MaxLotSize NULL) NON-CrtEnabled item at a cell with no
--                   active Tools.ToolAssignment, created with the 'Received' origin
--                   so Lot_Create needs no Tool/Cavity scan. @TerminalLocationId is
--                   left NULL throughout so arm 2 stays inert and the only thing
--                   that can raise the stamp is propagation from the inputs.
--                 * C reuses 0027/070's fixture (casting 12270-6NA -> sub-assembly
--                   12270-6NA-M at MA1-FP6NA-MOUT, BOM auto-created if absent) and
--                   CLOSES any casting the earlier machining suites left open at
--                   that line first, so this file's two castings are the whole FIFO
--                   queue and their order is deterministic (LotMovement.MovedAt is
--                   back-dated to pin it).
--                 * D reuses 0056/030's fixture (FG '12270-6NA -0001' at MA1-FP6NA)
--                   including its FK-safe FG teardown -- that cell's open Container
--                   accumulates trays across runs and would otherwise reject this
--                   file's tray as "container is full".
--                 * Every temp/table variable matches its proc's result shape
--                   EXACTLY (Lot_Create 4 cols, Lot_Split 5, Lot_Merge 3,
--                   MachiningOut_Mint 4, Assembly_CompleteTray 6,
--                   Terminal_SetCrtEnabled 2). A mismatched INSERT-EXEC aborts the
--                   whole file with Msg 213 as a runner ERROR, not as a FAIL.
--
--               Teardown restores every flag this file sets: the section-C castings
--               and sub-assembly, the section-D component stock, the section-E LOT,
--               and the MA1-FP6NA-AOUT terminal switch.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/050_mint_procs.sql';
GO

-- =============================================
-- A. Lots.Lot_Split -- CRT parent taints every child; clean parent does not.
-- =============================================
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Parts.Item i ON i.Id = eil.ItemId
WHERE i.MaxLotSize IS NULL          -- uncapped: the 20-pc fixtures exceed the seed basket caps
  AND i.CrtEnabled = 0              -- arm 1 must stay inert; propagation is what is under test
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @sp TABLE (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT,
                   ChildLotName NVARCHAR(50), PieceCount INT);
DECLARE @ChildJson NVARCHAR(MAX) =
    N'[{"pieceCount":10,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'},'
  + N' {"pieceCount":10,"currentLocationId":' + CAST(@CellId AS NVARCHAR(20)) + N'}]';

-- A1. CRT parent -> both children CRT.
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 20, @AppUserId = 1;
DECLARE @CrtParent BIGINT = (SELECT TOP 1 NewId FROM @cr);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @CrtParent;

INSERT INTO @sp EXEC Lots.Lot_Split @ParentLotId = @CrtParent,
    @ChildrenJson = @ChildJson, @AppUserId = 1;
DECLARE @crtKids NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Lots.Lot l INNER JOIN @sp s ON s.ChildLotId = l.Id WHERE l.CrtActive = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] Lot_Split: both children of a CRT parent are CrtActive=1',
    @Expected = N'2', @Actual = @crtKids;

-- A2. Clean parent at a plain terminal -> both children clean.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 20, @AppUserId = 1;
DECLARE @CleanParent BIGINT = (SELECT TOP 1 NewId FROM @cr);

DELETE FROM @sp;
INSERT INTO @sp EXEC Lots.Lot_Split @ParentLotId = @CleanParent,
    @ChildrenJson = @ChildJson, @AppUserId = 1;
DECLARE @cleanKids NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Lots.Lot l INNER JOIN @sp s ON s.ChildLotId = l.Id WHERE l.CrtActive = 0);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] Lot_Split: both children of a clean parent are CrtActive=0',
    @Expected = N'2', @Actual = @cleanKids;
GO

-- =============================================
-- B. Lots.Lot_Merge -- ONE CRT source among N taints the blend. This is the
--    laundering guard: without it, merging a tagged LOT with clean stock would
--    produce a clean output LOT and lose containment.
-- =============================================
DECLARE @ItemId BIGINT, @CellId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
INNER JOIN Parts.Item i ON i.Id = eil.ItemId
WHERE i.MaxLotSize IS NULL AND i.CrtEnabled = 0
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @mg TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);

-- B1. Three sources; the MIDDLE one is CRT (so a first-row-only bug cannot pass).
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 15, @AppUserId = 1;
DECLARE @S1 BIGINT = (SELECT TOP 1 NewId FROM @cr);
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 15, @AppUserId = 1;
DECLARE @S2 BIGINT = (SELECT TOP 1 NewId FROM @cr);
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 15, @AppUserId = 1;
DECLARE @S3 BIGINT = (SELECT TOP 1 NewId FROM @cr);

UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @S2;

DECLARE @JsonTainted NVARCHAR(MAX) = N'[' + CAST(@S1 AS NVARCHAR(20)) + N','
    + CAST(@S2 AS NVARCHAR(20)) + N',' + CAST(@S3 AS NVARCHAR(20)) + N']';
INSERT INTO @mg EXEC Lots.Lot_Merge @SourceLotIdsJson = @JsonTainted,
    @OutputItemId = @ItemId, @OutputLocationId = @CellId, @AppUserId = 1;
DECLARE @MergedTainted BIGINT = (SELECT TOP 1 NewId FROM @mg);
DECLARE @mergedCrt NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10))
    FROM Lots.Lot WHERE Id = @MergedTainted);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] Lot_Merge: one CRT source among three taints the output LOT',
    @Expected = N'1', @Actual = @mergedCrt;

-- B2. All-clean sources -> clean output.
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 15, @AppUserId = 1;
DECLARE @C1 BIGINT = (SELECT TOP 1 NewId FROM @cr);
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemId, @LotOriginTypeId = @OriginRcv,
    @CurrentLocationId = @CellId, @PieceCount = 15, @AppUserId = 1;
DECLARE @C2 BIGINT = (SELECT TOP 1 NewId FROM @cr);

DECLARE @JsonClean NVARCHAR(MAX) = N'[' + CAST(@C1 AS NVARCHAR(20)) + N','
    + CAST(@C2 AS NVARCHAR(20)) + N']';
DELETE FROM @mg;
INSERT INTO @mg EXEC Lots.Lot_Merge @SourceLotIdsJson = @JsonClean,
    @OutputItemId = @ItemId, @OutputLocationId = @CellId, @AppUserId = 1;
DECLARE @MergedClean BIGINT = (SELECT TOP 1 NewId FROM @mg);
DECLARE @mergedCleanCrt NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10))
    FROM Lots.Lot WHERE Id = @MergedClean);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] Lot_Merge: all-clean sources yield CrtActive=0',
    @Expected = N'0', @Actual = @mergedCleanCrt;
GO

-- =============================================
-- C. Workorder.MachiningOut_Mint -- a CRT casting SECOND in FIFO order.
--    The scanned handle is the CLEAN casting; the walk rolls into the CRT one to
--    finish the order. Nothing at the mint site can see that second casting, so
--    only the post-consume re-resolve can produce the right answer here.
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

-- Neither part carries the flag: arm 1 inert. The line terminal carries no
-- CrtEnabled attribute: arm 2 inert. Propagation is the only live arm.
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

-- Close whatever the earlier machining suites left open at this line so the FIFO
-- queue contains exactly this file's two castings, in a known order.
UPDATE Lots.Lot SET LotStatusId = @ClosedSt
WHERE ItemId = @Casting AND CurrentLocationId = @Line AND LotStatusId = @GoodSt;

DECLARE @cc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));

-- Casting 1: CLEAN, 4 pcs -- first in FIFO, drained by the mint.
INSERT INTO @cc EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 4, @AppUserId = 1;
DECLARE @CleanCast BIGINT = (SELECT TOP 1 NewId FROM @cc);

-- Casting 2: CRT, 8 pcs -- second in FIFO, the walk rolls into it.
DELETE FROM @cc;
INSERT INTO @cc EXEC Lots.Lot_Create @ItemId = @Casting, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Line, @PieceCount = 8, @AppUserId = 1;
DECLARE @CrtCast BIGINT = (SELECT TOP 1 NewId FROM @cc);
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id = @CrtCast;

-- Pin FIFO order (the queue is ORDER BY MAX(LotMovement.MovedAt), Id) so the CLEAN
-- casting is unambiguously first even if both creations land on the same tick.
UPDATE Lots.LotMovement SET MovedAt = DATEADD(MINUTE, -30, SYSUTCDATETIME()) WHERE LotId = @CleanCast;
UPDATE Lots.LotMovement SET MovedAt = DATEADD(MINUTE, -20, SYSUTCDATETIME()) WHERE LotId = @CrtCast;

-- Every route step before MachiningOut must be checkpointed or the castings are
-- not queue-eligible (mirrors 0027/070).
INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId)
SELECT l.LotId, rs.OperationTemplateId, SYSUTCDATETIME(), 12, 1
FROM (SELECT @CleanCast AS LotId UNION ALL SELECT @CrtCast) l
CROSS JOIN Parts.RouteTemplate rt
INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
WHERE rt.ItemId = @Casting AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
  AND rs.OperationTemplateId <> @MoTpl;

-- Mint 6: 4 from the clean casting, then 2 from the CRT one.
DECLARE @mo TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
INSERT INTO @mo EXEC Workorder.MachiningOut_Mint @SourceLotId = @CleanCast,
    @OperationTemplateId = @MoTpl, @PieceCount = 6, @AppUserId = 1, @TerminalLocationId = @Line;
DECLARE @moStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @mo);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] MachiningOut_Mint: two-casting mint succeeds',
    @Expected = N'1', @Actual = @moStatus;
DECLARE @MintedLot BIGINT = (SELECT TOP 1 NewId FROM @mo);

-- Guard: the walk really DID roll into the second casting. Without this a
-- CrtActive=1 could pass vacuously (e.g. if FIFO had picked the CRT casting alone).
DECLARE @parents NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM Lots.LotGenealogy WHERE ChildLotId = @MintedLot AND RelationshipTypeId = 3);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] MachiningOut_Mint: FIFO walk consumed BOTH castings',
    @Expected = N'2', @Actual = @parents;

DECLARE @mintedCrt NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10))
    FROM Lots.Lot WHERE Id = @MintedLot);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] MachiningOut_Mint: a CRT casting second in FIFO taints the sub-assembly',
    @Expected = N'1', @Actual = @mintedCrt;

-- Leave nothing tagged behind at this line.
UPDATE Lots.Lot SET CrtActive = 0 WHERE Id IN (@MintedLot, @CrtCast, @CleanCast);
GO

-- =============================================
-- D. Workorder.Assembly_CompleteTray step B4b -- a CRT sub-assembly consumed into
--    an UNFLAGGED finished good at an UNFLAGGED terminal must still mint CRT.
--    0056/030 only ever drives the terminal arm at this proc.
-- =============================================

-- ---- FK-safe teardown of this cell's FG containers/LOTs (verbatim shape from
--      0056/030): the shared 6NA container accumulates trays across runs and a
--      near-full container would reject this file's tray as "container is full". ----
DECLARE @TdFg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @TdCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');

DELETE FROM Quality.HoldEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Quality.HoldEvent WHERE ContainerId IN (SELECT Id FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId = @TdCell;
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId = @TdFg;
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotGenealogy WHERE ChildLotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container c ON c.Id = tr.ContainerId WHERE c.ItemId = @TdFg AND c.CurrentLocationId = @TdCell;
DELETE FROM Lots.LotEventLog WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.LotMovement WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell);
DELETE FROM Lots.Container WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
DELETE FROM Lots.Lot WHERE ItemId = @TdFg AND CurrentLocationId = @TdCell;
GO

DECLARE @Cell  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @Fg    BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @CompA BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @CompB BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'92900-06014-1B');
DECLARE @CompC BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'94301-08100');

-- Arms 1 and 2 both OFF: the FG part is unflagged and the terminal switch is clear.
UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id IN (@Fg, @CompA, @CompB, @CompC);
DECLARE @tt TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @tt EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term,
    @Enabled = 0, @AppUserId = 1;

-- Component stock for one 6-piece tray (BOM per FG piece: CompA x1, CompB x1,
-- CompC x2). CompA's MaxLotSize is 12.
DECLARE @st TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @st EXEC Lots.Lot_Create @ItemId = @CompA, @LotOriginTypeId = 1, @CurrentLocationId = @Cell, @PieceCount = 12, @AppUserId = 1;
INSERT INTO @st EXEC Lots.Lot_Create @ItemId = @CompB, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 30, @AppUserId = 1;
INSERT INTO @st EXEC Lots.Lot_Create @ItemId = @CompC, @LotOriginTypeId = 2, @CurrentLocationId = @Cell, @PieceCount = 60, @AppUserId = 1;

-- Tag EVERY open sub-assembly LOT at the cell, not just this file's: earlier files
-- leave older CompA stock there and the BOM consume walk is strict FIFO, so
-- whichever LOT it picks must be the CRT one for the assertion to mean anything.
UPDATE l SET l.CrtActive = 1
FROM Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.ItemId = @CompA AND l.CurrentLocationId = @Cell AND sc.Code <> N'Closed';

DECLARE @tray TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT,
                     ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT);
INSERT INTO @tray EXEC Workorder.Assembly_CompleteTray
    @FinishedGoodItemId = @Fg, @PieceCount = 6, @CellLocationId = @Cell,
    @ClosureMethod = N'ByVision', @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @trayStatus NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @tray);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] Assembly_CompleteTray: tray closes with CRT component stock',
    @Expected = N'1', @Actual = @trayStatus;

DECLARE @FgLot BIGINT = (SELECT TOP 1 FinishedGoodLotId FROM @tray);
DECLARE @fgCrt NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @FgLot);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] Assembly_CompleteTray B4b: a CRT sub-assembly taints an unflagged FG',
    @Expected = N'1', @Actual = @fgCrt;

-- Untag the component stock this file tagged so no later file inherits it.
UPDATE Lots.Lot SET CrtActive = 0 WHERE ItemId = @CompA AND CurrentLocationId = @Cell;
GO

-- =============================================
-- E. Lots.Lot_Create terminal arm. 040_propagation.sql omits @TerminalLocationId on
--    every call, so arm 2 has never been exercised THROUGH the proc -- only through
--    the resolver. An unflagged part at a CrtEnabled terminal must mint CRT.
-- =============================================
DECLARE @Cell   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA');
DECLARE @Term   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AOUT');
DECLARE @SubIt  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

UPDATE Parts.Item SET CrtEnabled = 0 WHERE Id = @SubIt;   -- arm 1 inert

DECLARE @tg TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @tg EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term,
    @Enabled = 1, @AppUserId = 1;

DECLARE @lc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @lc EXEC Lots.Lot_Create @ItemId = @SubIt, @LotOriginTypeId = @Origin,
    @CurrentLocationId = @Cell, @PieceCount = 10, @AppUserId = 1, @TerminalLocationId = @Term;
DECLARE @TermLot BIGINT = (SELECT TOP 1 NewId FROM @lc);
DECLARE @termCrt NVARCHAR(10) = (SELECT CAST(CrtActive AS NVARCHAR(10)) FROM Lots.Lot WHERE Id = @TermLot);
EXEC test.Assert_IsEqual
    @TestName = N'[MintCrt] Lot_Create: unflagged part at a CrtEnabled terminal mints CrtActive=1',
    @Expected = N'1', @Actual = @termCrt;

-- ---- Teardown: clear the terminal switch and every LOT this section tagged ----
DELETE FROM @tg;
INSERT INTO @tg EXEC Location.Terminal_SetCrtEnabled @TerminalLocationId = @Term,
    @Enabled = 0, @AppUserId = 1;
UPDATE Lots.Lot SET CrtActive = 0 WHERE ItemId = @SubIt AND CurrentLocationId = @Cell;
GO

EXEC test.EndTestFile;
GO
