-- ============================================================
-- smoke_seed_phase3_diecast.sql  (DEV AID - NOT a migration, NOT a test)
-- Sets up a deterministic die-cast scenario for the Phase 3 front-end smoke:
--   * a Tool 'SMOKE-DC' mounted on an eligible Cell, with 2 Active cavities
--   * prints the Cell / Item / Tool ids + ready-to-click URLs
-- Idempotent: re-running wipes the SMOKE-* fixtures + any MESL%/SMOKE-LTT% LOTs
-- and rebuilds. The dev DB holds zero persistent LOTs (tests tear down), so this is
-- how you get clickable die-cast data into a Perspective session.
--
-- Usage:  sqlcmd -S localhost -d MPP_MES_Dev -E -b -C -i sql/scratch/smoke_seed_phase3_diecast.sql
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ---- wipe prior smoke fixtures (FK-safe: LOTs before Tool/Cavity) ----
DELETE FROM Workorder.ProductionEventValue WHERE ProductionEventId IN
    (SELECT pe.Id FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId
     WHERE l.LotName LIKE N'MESL%' OR l.LotName LIKE N'SMOKE-LTT%');
DELETE FROM Workorder.RejectEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'SMOKE-LTT%');
DELETE FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'SMOKE-LTT%');
DELETE FROM Lots.LotEventLog       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'SMOKE-LTT%');
DELETE FROM Lots.LotMovement       WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'SMOKE-LTT%');
DELETE FROM Lots.LotStatusHistory  WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'SMOKE-LTT%');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'SMOKE-LTT%');
DELETE FROM Lots.Lot WHERE LotName LIKE N'MESL%' OR LotName LIKE N'SMOKE-LTT%';
DELETE FROM Tools.ToolAssignment WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'SMOKE-DC');
DELETE FROM Tools.ToolCavity     WHERE ToolId IN (SELECT Id FROM Tools.Tool WHERE Code = N'SMOKE-DC');
DELETE FROM Tools.Tool WHERE Code = N'SMOKE-DC';

-- ---- pick an eligible (Item, Cell) pair on a Cell with no current mount ----
DECLARE @CellId BIGINT, @ItemId BIGINT;
SELECT TOP 1 @ItemId = eil.ItemId, @CellId = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

IF @CellId IS NULL
BEGIN
    RAISERROR(N'No eligible Item/Cell pair found - load the location + item seeds first.', 16, 1);
    RETURN;
END

-- ---- create the Tool + 2 Active cavities + mount it on the Cell ----
DECLARE @ToolTypeId BIGINT = (SELECT TOP 1 Id FROM Tools.ToolType ORDER BY Id);
DECLARE @ToolStatusId BIGINT = (SELECT TOP 1 Id FROM Tools.ToolStatusCode ORDER BY Id);
DECLARE @CavActiveId BIGINT = (SELECT Id FROM Tools.ToolCavityStatusCode WHERE Code = N'Active');

INSERT INTO Tools.Tool (ToolTypeId, Code, Name, StatusCodeId, CreatedByUserId, CreatedAt)
VALUES (@ToolTypeId, N'SMOKE-DC', N'Phase 3 smoke die', @ToolStatusId, 1, SYSUTCDATETIME());
DECLARE @ToolId BIGINT = SCOPE_IDENTITY();

INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, CreatedByUserId, CreatedAt)
VALUES (@ToolId, 1, @CavActiveId, 1, SYSUTCDATETIME()),
       (@ToolId, 2, @CavActiveId, 1, SYSUTCDATETIME());

INSERT INTO Tools.ToolAssignment (ToolId, CellLocationId, AssignedAt, AssignedByUserId)
VALUES (@ToolId, @CellId, SYSUTCDATETIME(), 1);

-- ---- report ----
DECLARE @CellCode NVARCHAR(50) = (SELECT Code FROM Location.Location WHERE Id = @CellId);
PRINT N'=== Phase 3 die-cast smoke scenario ready ===';
PRINT N'Cell   : Id=' + CAST(@CellId AS NVARCHAR(20)) + N'  Code=' + ISNULL(@CellCode, N'?');
PRINT N'Item   : Id=' + CAST(@ItemId AS NVARCHAR(20)) + N'  (type this into the Item Id field)';
PRINT N'Tool   : Id=' + CAST(@ToolId AS NVARCHAR(20)) + N'  Code=SMOKE-DC  (2 active cavities)';
PRINT N'';
PRINT N'NOTE: the operator session must have session.custom.cell.locationId = ' + CAST(@CellId AS NVARCHAR(20));
PRINT N'      (set via the terminal context / CellContextSelector) and a logged-in';
PRINT N'      session.custom.appUserId for Lot_Create attribution.';
PRINT N'';
PRINT N'URL    : /shop-floor/die-cast';
PRINT N'(after creating a LOT, the right-rail cumulative card + Reject panel target it;';
PRINT N' /shop-floor/die-cast/checkpoint/<lotId> and /reject/<lotId> deep-link the same view)';
GO
