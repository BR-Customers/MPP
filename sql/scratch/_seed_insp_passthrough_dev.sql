-- ============================================================
-- _seed_insp_passthrough_dev.sql   (DEV SCRATCH -- not a migration, not a seed)
-- Author:      Blue Ridge Automation
-- Created:     2026-08-10
-- Target:      MPP_MES_Dev ONLY. Idempotent; safe to re-run.
--
-- Purpose: build a REAL pass-through station in Dev so the pass-through parts
--          screen can be smoked against the topology it will actually deploy
--          into. Pass-through stations are their OWN terminals -- they are not
--          part of any production line (confirmed with MPP 2026-08-10).
--
--          Dev's location map predates the 2026-07-24 reconcile and has no
--          INSP anything, so nothing pointed at /shop-floor/third-party-inspection.
--          This mirrors sql/seeds/011_seed_locations_mpp_plant.sql exactly:
--
--            MPP-MAD (Madison Facility)
--              INSP           def 3  Production Area    "Inspection"
--                INSP-SORT    def 6  Inspection Line    "Sort Cage Inspection"   <- the CELL
--                  INSP-SORT-T1 def 7 Terminal          "Inspection"             <- the TERMINAL
--
--          The terminal's ZONE is its parent (INSP-SORT), and that zone is what
--          both embeds write to session.custom.cell -- so it is the location
--          Lot_Create mints into and Assembly_CompleteTray consumes from.
--
-- Part config: Assembly_CompleteTray consumes from @CellLocationId with NO
--          descendant cascade, so the finished good needs Direct ItemLocation
--          eligibility AT INSP-SORT. Its BOM children then inherit eligibility
--          automatically via Parts.v_EffectiveItemLocation's BomDerived leg, so
--          they are deliberately NOT enumerated here.
--          BOM and ContainerConfig are item-level and already exist for item 23.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() NOT LIKE N'%_Dev'
BEGIN
    RAISERROR(N'Refusing to run: this script is Dev-only.', 16, 1);
    RETURN;
END

DECLARE @Fac BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');
IF @Fac IS NULL BEGIN RAISERROR(N'MPP-MAD not found.', 16, 1); RETURN; END

-- ---- 1. Locations (mirrors 011_seed_locations_mpp_plant.sql "Exception 2") ----
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'INSP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, @Fac, N'Inspection', N'INSP', N'INSP', 98;

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'INSP-SORT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 6, (SELECT Id FROM Location.Location WHERE Code = N'INSP'), N'Sort Cage Inspection', N'INSP-SORT', N'INSP-SORT', 1;

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'INSP-SORT-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT'), N'Inspection', N'INSP-SORT-T1', N'INSP-SORT-T1', 1;

DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT');
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');

-- ---- 2. Terminal attributes ----
-- DefaultScreen: the whole point -- makes the station reachable the way it deploys.
-- CurrentClosureMethod: Assembly resolves ContainerConfig by (ItemId, ClosureMethod)
--   with NO fallback, so a terminal with no closure method cannot close a tray.
-- HasBarcodeScanner: matches how the seed configures a scan-capable terminal.
DECLARE @AttrScreen  BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'DefaultScreen'         AND LocationTypeDefinitionId = 7 ORDER BY Id);
DECLARE @AttrClosure BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'CurrentClosureMethod' AND LocationTypeDefinitionId = 7 ORDER BY Id);
DECLARE @AttrScan    BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'HasBarcodeScanner'    AND LocationTypeDefinitionId = 7 ORDER BY Id);

IF @AttrScreen IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.LocationAttribute WHERE LocationId = @Term AND LocationAttributeDefinitionId = @AttrScreen)
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    VALUES (@Term, @AttrScreen, N'/shop-floor/third-party-inspection', SYSUTCDATETIME());

IF @AttrClosure IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.LocationAttribute WHERE LocationId = @Term AND LocationAttributeDefinitionId = @AttrClosure)
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    VALUES (@Term, @AttrClosure, N'ByCount', SYSUTCDATETIME());

IF @AttrScan IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.LocationAttribute WHERE LocationId = @Term AND LocationAttributeDefinitionId = @AttrScan)
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    VALUES (@Term, @AttrScan, N'true', SYSUTCDATETIME());

-- ---- 2b. Printer (a Printer is a CHILD Location of the terminal, not an attribute) ----
-- Location.Terminal_GetPrinter resolves `WHERE p.ParentLocationId = @TerminalLocationId
-- AND def.Name = 'Printer'`, so the printer must be a child location, def 16.
--
-- Endpoint grammar (BlueRidge.Lots.LabelTransport, design 2026-07-28):
--   'host:port'        -> raw TCP, port MANDATORY
--   '\\HOST\Queue' or a bare name -> Windows print queue via javax.print
-- A bare name is used here so the LTT goes to the real Zebra over USB. The other
-- Dev printers use 127.0.0.1:9100, which only works if something is listening.
--
-- LabelTypes = 'Primary' is the LTT label type (LotLabel.printLabel default-resolves
-- to Primary/Initial). With a single printer the proc's SortOrder fallback would cover
-- it anyway, but setting it explicitly is what the v2.0 routing design intends.
DECLARE @Printer BIGINT;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'INSP-SORT-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, @Term, N'Inspection LTT Printer', N'INSP-SORT-T1-P1', N'INSP-SORT-T1-P1', 1;
SET @Printer = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1-P1');

DECLARE @AttrEndpoint BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'Endpoint'   AND LocationTypeDefinitionId = 16 ORDER BY Id);
DECLARE @AttrModel    BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'Model'      AND LocationTypeDefinitionId = 16 ORDER BY Id);
DECLARE @AttrLabels   BIGINT = (SELECT TOP 1 Id FROM Location.LocationAttributeDefinition WHERE AttributeName = N'LabelTypes' AND LocationTypeDefinitionId = 16 ORDER BY Id);

IF @AttrEndpoint IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.LocationAttribute WHERE LocationId = @Printer AND LocationAttributeDefinitionId = @AttrEndpoint)
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    VALUES (@Printer, @AttrEndpoint, N'Zebra GX420d (RAW)', SYSUTCDATETIME());

IF @AttrModel IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.LocationAttribute WHERE LocationId = @Printer AND LocationAttributeDefinitionId = @AttrModel)
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    VALUES (@Printer, @AttrModel, N'GX420d', SYSUTCDATETIME());

IF @AttrLabels IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.LocationAttribute WHERE LocationId = @Printer AND LocationAttributeDefinitionId = @AttrLabels)
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    VALUES (@Printer, @AttrLabels, N'Primary', SYSUTCDATETIME());

-- ---- 3. Part eligibility AT THE PASS-THROUGH CELL ----
-- Direct eligibility for the finished good only. Its BOM children reach the same
-- cell through v_EffectiveItemLocation's BomDerived leg -- enumerating them here
-- would be the configuration explosion FDS-02-012 exists to avoid.
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'11200-6FB -A000');
IF @Fg IS NULL BEGIN RAISERROR(N'Finished good 11200-6FB -A000 not found.', 16, 1); RETURN; END

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Fg AND LocationId = @Cell AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, CreatedAt, IsConsumptionPoint)
    VALUES (@Fg, @Cell, SYSUTCDATETIME(), 1);

-- ---- 4. Verify ----
PRINT '=== hierarchy ===';
SELECT l.Id, l.Code, l.Name, p.Code AS Parent, d.Name AS DefType
FROM Location.Location l
LEFT JOIN Location.Location p ON p.Id = l.ParentLocationId
JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
WHERE l.Code IN (N'INSP', N'INSP-SORT', N'INSP-SORT-T1') ORDER BY l.Id;

PRINT '=== terminal attributes ===';
SELECT ad.AttributeName, la.AttributeValue
FROM Location.LocationAttribute la
JOIN Location.LocationAttributeDefinition ad ON ad.Id = la.LocationAttributeDefinitionId
WHERE la.LocationId = @Term ORDER BY ad.AttributeName;

PRINT '=== what is eligible at the pass-through cell (Direct + BomDerived) ===';
SELECT i.PartNumber, v.Source
FROM Parts.v_EffectiveItemLocation v JOIN Parts.Item i ON i.Id = v.ItemId
WHERE v.LocationId = @Cell ORDER BY i.PartNumber, v.Source;

PRINT '=== container configs for the finished good (needs a ByCount row) ===';
SELECT ClosureMethod, PartsPerTray, TraysPerContainer, IsSerialized
FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL;

PRINT '=== printer as the dispatch path actually resolves it ===';
EXEC Location.Terminal_GetPrinter @TerminalLocationId = @Term, @LabelTypeCode = N'Primary';
GO
