-- ============================================================
-- Migration:   0081_location_is_stock_location.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-13
-- Description: Location.LocationTypeDefinition.IsStockLocation -- "can physical
--              stock rest here?" -- and the Lot_Create eligibility gate keys off
--              it.
--
--              WHY. Lots.Lot_Create gates @CurrentLocationId on
--              Parts.v_EffectiveItemLocation: the item must be eligible at the
--              location or an ancestor. Eligibility answers "may this part be
--              WORKED here", which is meaningless for a storage location --
--              the warehouse and the trim stores carry no eligibility rows at
--              all, and neither does the Site tier, so EVERY part reads as
--              "not eligible at the specified location" at WHSE. Die cast
--              already had to dodge that: its @DepositToStorage move is
--              explicitly non-eligibility-gated, commented "warehouse is
--              storage, not a production location". That is this same rule,
--              stated once, locally, for one caller.
--
--              The inventory cutover scan counts stock in where it physically
--              sits -- warehouse (awaiting trim), the trim shop floor
--              (mid-trim), the trim stores (awaiting machining), the M&A lines
--              -- so it needs the rule stated properly instead.
--
--              WHY NOT IsProductionDestination (0064). It looks like the same
--              question and is not. 0064 added that column DEFAULT 0 and set 1
--              for only seven definitions, so "not a production destination"
--              also covers Organization, Facility, Printer, Scale and Terminal.
--              Gating Lot_Create on it would let a LOT be created at the
--              ENTERPRISE ROOT, or on a printer, with no eligibility check --
--              caught by 0020_PlantFloor_Foundation/040_Lot_Create.sql
--              [LcIneligible], which picks the lowest-Id ineligible location
--              (MPP-ENT, an Organization). Lots.Lot_MoveTo can use that flag
--              because its question is "may a CRT LOT move to quarantine",
--              where permissive toward inspection/inventory/support IS the
--              intent. Same flag, different question.
--
--              WHAT. BIT NOT NULL DEFAULT 0 on Location.LocationTypeDefinition,
--              set 1 for the four definitions where material genuinely rests:
--                InventoryLocation  -- the trim stores
--                SupportArea        -- the warehouse
--                InspectionStation  -- material held for inspection
--                InspectionLine     -- ditto
--              Everything else stays 0, so a production location keeps the
--              eligibility gate and a printer / scale / terminal / hierarchy
--              root is not a place stock can be created at all.
--
--              Production-vs-not is DATA (0064 D5a): a new definition declares
--              itself rather than requiring a proc edit. Same principle here.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only. The Lot_Create change itself lives in the
--              repeatable R__Lots_Lot_Create.sql (v1.5).
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0081_location_is_stock_location')
BEGIN PRINT 'Migration 0081 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. The column ----
IF COL_LENGTH('Location.LocationTypeDefinition', 'IsStockLocation') IS NULL
    ALTER TABLE Location.LocationTypeDefinition
        ADD IsStockLocation BIT NOT NULL
            CONSTRAINT DF_LTD_IsStockLocation DEFAULT 0;
GO

-- ---- 2. Which definitions hold stock ----
-- Idempotent -- re-running re-asserts the same set.
UPDATE Location.LocationTypeDefinition
   SET IsStockLocation = 1
 WHERE Code IN (N'InventoryLocation', N'SupportArea',
                N'InspectionStation', N'InspectionLine')
   AND IsStockLocation <> 1;

UPDATE Location.LocationTypeDefinition
   SET IsStockLocation = 0
 WHERE Code IN (N'Organization', N'Facility', N'Printer', N'Scale', N'Terminal',
                N'ProductionArea', N'ProductionLine', N'DieCastMachine',
                N'TrimPress', N'CNCMachine', N'AssemblyStation',
                N'SerializedAssemblyLine')
   AND IsStockLocation <> 0;
GO

-- ---- 3. Report what the flag now says, so a bad seed is visible at deploy ----
DECLARE @Stock NVARCHAR(500) = (
    SELECT STUFF((SELECT N', ' + Code FROM Location.LocationTypeDefinition
                  WHERE IsStockLocation = 1 AND DeprecatedAt IS NULL
                  ORDER BY Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''));
PRINT 'Stock locations: ' + ISNULL(@Stock, N'(none)');
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0081_location_is_stock_location')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0081_location_is_stock_location',
            N'Location.LocationTypeDefinition.IsStockLocation (BIT, default 0), set 1 for InventoryLocation / SupportArea / InspectionStation / InspectionLine. Lots.Lot_Create v1.5 skips the item-eligibility gate when the destination is a stock location, so cutover can count stock in at the warehouse and the trim stores.');
GO
PRINT 'Migration 0081 (location_is_stock_location) applied.';
GO
