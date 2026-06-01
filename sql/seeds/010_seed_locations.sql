-- ============================================================
-- Seed:        seed_locations.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-04-13
-- Description: Seeds 10 Location rows representing the MPP plant
--              hierarchy from Enterprise root down to sample
--              machines. Covers all 5 ISA-95 tiers. Idempotent
--              via Code uniqueness checks.
--
--              Hierarchy:
--                MPP-ENT (Enterprise/Organization)
--                  └─ MPP-MAD (Site/Facility)
--                      ├─ DIECAST (Area/ProductionArea)
--                      │   ├─ DC-LINE-01 (WorkCenter/ProductionLine)
--                      │   │   ├─ DC-401 (Cell/DieCastMachine)
--                      │   │   └─ DC-402 (Cell/DieCastMachine)
--                      │   └─ DC-LINE-02 (WorkCenter/ProductionLine)
--                      │       └─ DC-501 (Cell/DieCastMachine)
--                      ├─ MACHSHOP (Area/ProductionArea)
--                      │   └─ MS-LINE-01 (WorkCenter/ProductionLine)
--                      │       └─ MS-101 (Cell/CNCMachine)
--                      └─ QC (Area/SupportArea)
-- ============================================================

-- Use explicit IDENTITY_INSERT so Ids are deterministic for FK references.
-- This makes the seed idempotent and self-contained.

SET IDENTITY_INSERT Location.Location ON;

-- === TIER 0: Enterprise =======================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MPP-ENT')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (1, 1, NULL, N'Madison Precision Products', N'MPP-ENT', N'Enterprise root — Madison Precision Products, Inc.', 1);

-- === TIER 1: Site =============================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MPP-MAD')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (2, 2, 1, N'Madison Facility', N'MPP-MAD', N'Main manufacturing facility, Madison IN', 1);

-- === TIER 2: Areas ============================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DIECAST')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (3, 3, 2, N'Die Cast', N'DIECAST', N'Die casting production area', 1);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MACHSHOP')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (4, 3, 2, N'Machine Shop', N'MACHSHOP', N'CNC machining production area', 2);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'QC')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (5, 4, 2, N'Quality Control', N'QC', N'Quality control support area', 3);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (13, 3, 2, N'Trim Shop', N'TRIM', N'Trim / deflash production area', 4);

-- === TIER 3: WorkCenters ======================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC-LINE-01')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (6, 5, 3, N'Die Cast Line 1', N'DC-LINE-01', N'Primary die cast production line', 1);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC-LINE-02')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (7, 5, 3, N'Die Cast Line 2', N'DC-LINE-02', N'Secondary die cast production line', 2);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MS-LINE-01')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (8, 5, 4, N'Machine Shop Line 1', N'MS-LINE-01', N'CNC machining line', 1);

-- === TIER 4: Cells ============================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC-401')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (9, 8, 6, N'Die Cast 401', N'DC-401', N'800-ton die cast machine', 1);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC-402')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (10, 8, 6, N'Die Cast 402', N'DC-402', N'800-ton die cast machine', 2);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC-501')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (11, 8, 7, N'Die Cast 501', N'DC-501', N'1000-ton die cast machine', 1);

IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MS-101')
    INSERT INTO Location.Location (Id, LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    VALUES (12, 9, 8, N'CNC Machine 101', N'MS-101', N'4-axis CNC machining center', 1);

SET IDENTITY_INSERT Location.Location OFF;

PRINT 'Seed: Location rows loaded (13 rows across 5 tiers).';
