-- ============================================================
-- smoke_seed_phase3_diecast.sql  (DEV AID - NOT a migration, NOT a test)
-- Stands up a COHERENT, connected die-cast scenario for the Phase 3 front-end
-- smoke and prints an exact "do this" checklist (URL + operator + cell + items).
--
-- It deliberately mounts the test tool on a Cell that ALREADY HAS eligible items,
-- so the Item dropdown is populated (the earlier version mounted on DC1-M01, which
-- has zero eligible items -> empty dropdown -> hard to test).
--
-- Idempotent: re-running wipes the SMOKE-* fixtures + any MESL%/SMOKE-LTT% LOTs
-- and rebuilds. The dev DB holds zero persistent LOTs (tests tear down).
--
-- Usage:  sqlcmd -S localhost -d MPP_MES_Dev -E -b -C -I -i sql/scratch/smoke_seed_phase3_diecast.sql
--         (the -I flag matters: Lots.* carry filtered indexes -> Msg 1934 without it)
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

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

-- ---- resolve the Die Cast 1 area + the first machine under it that HAS eligible items ----
DECLARE @AreaId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1' AND DeprecatedAt IS NULL);
IF @AreaId IS NULL
BEGIN
    RAISERROR(N'Area DC1 not found - load the location seed (011_seed_locations_mpp_plant.sql) first.', 16, 1);
    RETURN;
END

DECLARE @CellId BIGINT, @CellCode NVARCHAR(50);
SELECT TOP 1 @CellId = l.Id, @CellCode = l.Code
FROM Location.Location l
INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
WHERE l.ParentLocationId = @AreaId AND d.Code = N'DieCastMachine' AND l.DeprecatedAt IS NULL
  AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil
              INNER JOIN Parts.Item i ON i.Id = eil.ItemId AND i.DeprecatedAt IS NULL
              WHERE eil.LocationId = l.Id)
ORDER BY l.Code;

IF @CellId IS NULL
BEGIN
    RAISERROR(N'No DieCastMachine cell under DC1 has eligible items - load the item + eligibility seeds first.', 16, 1);
    RETURN;
END

-- ---- create the Tool + 2 Active cavities + mount it on the chosen Cell ----
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

-- ---- gather the printable facts ----
DECLARE @Items NVARCHAR(MAX) = N'';
SELECT @Items = @Items + i.PartNumber + N' (' + i.Description + N'),  '
FROM (SELECT DISTINCT eil.ItemId FROM Parts.v_EffectiveItemLocation eil WHERE eil.LocationId = @CellId) e
INNER JOIN Parts.Item i ON i.Id = e.ItemId AND i.DeprecatedAt IS NULL
ORDER BY i.PartNumber;
SET @Items = NULLIF(LEFT(@Items, NULLIF(LEN(@Items), 0) - 3), N'');

DECLARE @Ops NVARCHAR(MAX) = N'';
SELECT @Ops = @Ops + Initials + N' (' + DisplayName + N'),  '
FROM Location.AppUser WHERE Initials IS NOT NULL ORDER BY Id;
SET @Ops = NULLIF(LEFT(@Ops, NULLIF(LEN(@Ops), 0) - 3), N'');

-- ---- the checklist ----
PRINT N'';
PRINT N'==================================================================';
PRINT N'  PHASE 3 DIE-CAST SMOKE - READY';
PRINT N'==================================================================';
PRINT N'';
PRINT N'1) OPEN THIS URL (area-parameterized; the cell dropdown filters to DC1):';
PRINT N'     /shop-floor/die-cast/area/' + CAST(@AreaId AS NVARCHAR(20));
PRINT N'     full: localhost:8088/data/perspective/client/MPP/shop-floor/die-cast/area/' + CAST(@AreaId AS NVARCHAR(20));
PRINT N'';
PRINT N'2) LOGIN: the startup gate sends you to the initials keypad. Type one of:';
PRINT N'     ' + ISNULL(@Ops, N'(no operators seeded!)');
PRINT N'';
PRINT N'3) PICK CELL from the dropdown:  ' + @CellCode + N'   (Id ' + CAST(@CellId AS NVARCHAR(20)) + N')';
PRINT N'     ^ this is the ONLY pre-mounted machine; other DC1 machines have no';
PRINT N'       tool/eligible items, so their Item dropdown will be empty (expected).';
PRINT N'';
PRINT N'4) PICK ITEM (eligible at ' + @CellCode + N'):';
PRINT N'     ' + ISNULL(@Items, N'(none!)');
PRINT N'     (5G0-C is the casting - the natural die-cast part)';
PRINT N'';
PRINT N'5) PICK CAVITY: Cavity 1 or Cavity 2 (both Active on tool SMOKE-DC).';
PRINT N'     Or type a number for the manual-cavity (D2) path.';
PRINT N'';
PRINT N'6) Piece Count e.g. 48 -> Submit. Then try "Create LOT from another cavity"';
PRINT N'   (cavity-peer, D3), the right-rail Reject panel, and the checkpoint surface.';
PRINT N'';
PRINT N'   Tool: SMOKE-DC (Id ' + CAST(@ToolId AS NVARCHAR(20)) + N'), 2 active cavities.';
PRINT N'==================================================================';
GO
