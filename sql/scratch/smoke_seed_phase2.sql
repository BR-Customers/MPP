-- ============================================================
-- smoke_seed_phase2.sql  (DEV SMOKE AID — not a migration, not a test)
--
-- Builds a small, deterministic LOT dataset that exercises every code path
-- in the four Phase 2 LOT views (LOT Detail, LOT Search, Genealogy Viewer,
-- Paused-LOT Indicator). Idempotent: wipes ALL Lots.* rows first (the dev DB
-- normally holds zero persistent LOTs — the test suite tears down after itself).
--
-- Run:  sqlcmd -S localhost -d MPP_MES_Dev -i sql/scratch/smoke_seed_phase2.sql -b -I -C
-- Undo: sql/scratch/smoke_cleanup_phase2.sql  (the wipe block below, standalone)
--
-- What it creates:
--   A  -- Received LOT, VendorLotNumber 'SMOKE-VND-77'  -> Search + NO Tool/Cavity cards + Paused-at (2 cells)
--   B  -- Manufactured "die-cast" LOT (ToolId/Cavity set) -> Tool/Cavity cards + Genealogy + History (attr+move)
--   B split into 2 sublots                                -> Genealogy tree (parents/children, depth)
--   sublot #1 closed (Good->Closed)                       -> status-transition history stream
--   A paused at Cell 4 + Cell 5; sublot #2 paused at Cell 4 -> indicator count 2 at Cell 4, resume loop
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

-------------------------------------------------------------------------------
-- 0. FK-safe wipe (teardown order: OperationLog -> PauseEvent -> closure ->
--    genealogy -> attrchange -> label -> eventlog -> movement -> statushistory -> Lot)
-------------------------------------------------------------------------------
DELETE FROM Audit.OperationLog
    WHERE LogEntityTypeId IN (SELECT Id FROM Audit.LogEntityType WHERE Code IN (N'PauseEvent', N'LotLabel'));
DELETE FROM Lots.PauseEvent;
DELETE FROM Lots.LotGenealogyClosure;
DELETE FROM Lots.LotGenealogy;
DELETE FROM Lots.LotAttributeChange;
IF OBJECT_ID(N'Lots.LotLabel') IS NOT NULL DELETE FROM Lots.LotLabel;
DELETE FROM Lots.LotEventLog;
DELETE FROM Lots.LotMovement;
DELETE FROM Lots.LotStatusHistory;
DELETE FROM Lots.Lot;

-------------------------------------------------------------------------------
-- 1. Resolve reference ids (verified present in MPP_MES_Dev)
-------------------------------------------------------------------------------
DECLARE @U            BIGINT = 1;                                                       -- AppUser
DECLARE @OriginRcv    BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @OriginMfg    BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @ClosedStatus BIGINT = (SELECT Id FROM Lots.LotStatusCode  WHERE Code = N'Closed');
DECLARE @ItemA BIGINT = 58, @LocA BIGINT = 4;            -- received LOT: item @ Machine 01
DECLARE @ItemB BIGINT = 1,  @LocB BIGINT = 8;           -- die-cast LOT: 5G0 @ Machine 05
DECLARE @ToolB BIGINT = 2,  @CavB BIGINT = 1;           -- Tool CAV-TEST-DIE, cavity 1
DECLARE @LocMove BIGINT = 5;                            -- Machine 02 (move target for B)
DECLARE @LocPauseB BIGINT = 5;                          -- second pause cell for A

-------------------------------------------------------------------------------
-- 2. LOT A -- Received, with vendor LOT number
-------------------------------------------------------------------------------
DECLARE @rA TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @rA EXEC Lots.Lot_Create
    @ItemId = @ItemA, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @LocA,
    @PieceCount = 120, @VendorLotNumber = N'SMOKE-VND-77', @AppUserId = @U;
DECLARE @AId BIGINT = (SELECT NewId FROM @rA), @AName NVARCHAR(50) = (SELECT MintedLotName FROM @rA);

-------------------------------------------------------------------------------
-- 3. LOT B -- "die-cast" (Manufactured + Tool/Cavity). No active mount on the
--    cell, so Lot_Create stores the Tool/Cavity without the mount check.
-------------------------------------------------------------------------------
DECLARE @rB TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @rB EXEC Lots.Lot_Create
    @ItemId = @ItemB, @LotOriginTypeId = @OriginMfg, @CurrentLocationId = @LocB,
    @PieceCount = 500, @ToolId = @ToolB, @ToolCavityId = @CavB, @AppUserId = @U;
DECLARE @BId BIGINT = (SELECT NewId FROM @rB), @BName NVARCHAR(50) = (SELECT MintedLotName FROM @rB);

-------------------------------------------------------------------------------
-- 4. Split B -> two sublots (parent reduced to 150)
-------------------------------------------------------------------------------
DECLARE @json NVARCHAR(MAX) =
    N'[{"pieceCount":200,"currentLocationId":' + CAST(@LocB AS NVARCHAR(20)) + N'},'
  + N' {"pieceCount":150,"currentLocationId":' + CAST(@LocB AS NVARCHAR(20)) + N'}]';
DECLARE @rS TABLE (Status BIT, Message NVARCHAR(500), ChildLotId BIGINT, ChildLotName NVARCHAR(50), PieceCount INT);
INSERT INTO @rS EXEC Lots.Lot_Split @ParentLotId = @BId, @ChildrenJson = @json, @AppUserId = @U;
DECLARE @Child1 BIGINT = (SELECT MIN(ChildLotId) FROM @rS);
DECLARE @Child2 BIGINT = (SELECT MAX(ChildLotId) FROM @rS);
DECLARE @Child1Name NVARCHAR(50) = (SELECT ChildLotName FROM @rS WHERE ChildLotId = @Child1);

-------------------------------------------------------------------------------
-- 5. History streams on B: attribute change (Weight) + movement
-------------------------------------------------------------------------------
DECLARE @rU TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @rU EXEC Lots.Lot_Update @LotId = @BId, @Weight = 125.5000, @AppUserId = @U;
DELETE FROM @rU;
INSERT INTO @rU EXEC Lots.Lot_MoveTo @LotId = @BId, @ToLocationId = @LocMove, @AppUserId = @U;

-------------------------------------------------------------------------------
-- 6. Status-transition stream: close sublot #1 (Good -> Closed)
-------------------------------------------------------------------------------
DECLARE @rT TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @rT EXEC Lots.Lot_UpdateStatus
    @LotId = @Child1, @NewLotStatusId = @ClosedStatus, @Reason = N'Smoke: sublot consumed', @AppUserId = @U;

-------------------------------------------------------------------------------
-- 7. Pauses: A at Cell 4 + Cell 5; sublot #2 at Cell 4 (=> Cell 4 has 2 open)
-------------------------------------------------------------------------------
DECLARE @rP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @rP EXEC Lots.LotPause_Place @LotId = @AId,     @LocationId = @LocA,      @PausedReason = N'Awaiting QA',          @AppUserId = @U;
DELETE FROM @rP;
INSERT INTO @rP EXEC Lots.LotPause_Place @LotId = @AId,     @LocationId = @LocPauseB, @PausedReason = N'Material check',       @AppUserId = @U;
DELETE FROM @rP;
INSERT INTO @rP EXEC Lots.LotPause_Place @LotId = @Child2,  @LocationId = @LocA,      @PausedReason = N'Hold for inspection', @AppUserId = @U;

-------------------------------------------------------------------------------
-- 8. Report: ids + ready-to-click URLs
-------------------------------------------------------------------------------
PRINT '=== Phase 2 smoke seed complete ===';
SELECT 'A (Received, vendor SMOKE-VND-77)' AS Lot, @AId AS Id, @AName AS LotName
UNION ALL SELECT 'B (die-cast, Tool CAV-TEST-DIE)',          @BId, @BName
UNION ALL SELECT 'B sublot #1 (Closed)',                     @Child1, @Child1Name
UNION ALL SELECT 'B sublot #2 (paused @ Cell 4)',            @Child2, (SELECT ChildLotName FROM @rS WHERE ChildLotId=@Child2);

SELECT 'LOT Search'        AS [View], 'http://localhost:8088/data/perspective/client/MPP/shop-floor/lot-search' AS Url
UNION ALL SELECT 'LOT Detail (B, tool cards)',  'http://localhost:8088/data/perspective/client/MPP/shop-floor/lot-detail/' + CAST(@BId AS NVARCHAR(20))
UNION ALL SELECT 'LOT Detail (A, no cards)',    'http://localhost:8088/data/perspective/client/MPP/shop-floor/lot-detail/' + CAST(@AId AS NVARCHAR(20))
UNION ALL SELECT 'Genealogy (type B name)',     'http://localhost:8088/data/perspective/client/MPP/shop-floor/genealogy';
GO
