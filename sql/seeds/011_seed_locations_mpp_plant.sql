-- ============================================================
-- Seed:        011_seed_locations_mpp_plant.sql   (GENERATED — edit gen_locations_mpp.js)
-- Description: Full MPP plant Location tree (reconciled from the two
--              plant-layout-mapper exports). Supersedes the 10-row sample
--              010_seed_locations.sql for real-plant work. Idempotent by Code.
-- ============================================================
SET NOCOUNT ON;

-- === NEW LocationTypeDefinition: Printer (Cell-kind, DefId 16) =====
IF NOT EXISTS (SELECT 1 FROM Location.LocationTypeDefinition WHERE Code = N'Printer')
BEGIN
    SET IDENTITY_INSERT Location.LocationTypeDefinition ON;
    INSERT INTO Location.LocationTypeDefinition (Id, LocationTypeId, Code, Name) VALUES (16, 5, N'Printer', N'Printer');
    SET IDENTITY_INSERT Location.LocationTypeDefinition OFF;
END
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint')
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES (16, N'Endpoint', N'NVARCHAR', 1, NULL, NULL, 1, N'Zebra print target — IP:port or print-queue name');
IF NOT EXISTS (SELECT 1 FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Model')
    INSERT INTO Location.LocationAttributeDefinition (LocationTypeDefinitionId, AttributeName, DataType, IsRequired, DefaultValue, Uom, SortOrder, Description)
    VALUES (16, N'Model', N'NVARCHAR', 0, NULL, NULL, 2, N'Printer model (informs label-template selection)');


-- === Enterprise + Site =======================================
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MPP-ENT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 1, NULL, N'Madison Precision Products', N'MPP-ENT', N'Enterprise root', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MPP-MAD')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 2, (SELECT Id FROM Location.Location WHERE Code = N'MPP-ENT'), N'Madison Facility', N'MPP-MAD', N'Main manufacturing facility, Madison IN', 1;

-- === Die Cast 1 (11 machines, pair terminals) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 1', N'DC1', N'Die casting area — 11 machines', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 01', N'DC1-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 02', N'DC1-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 03', N'DC1-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M04')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 04', N'DC1-M04', N'Die cast machine', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M05')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 05', N'DC1-M05', N'Die cast machine', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M06')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 06', N'DC1-M06', N'Die cast machine', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M07')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 07', N'DC1-M07', N'Die cast machine', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M08')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 08', N'DC1-M08', N'Die cast machine', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M09')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 09', N'DC1-M09', N'Die cast machine', 9;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M10')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 10', N'DC1-M10', N'Die cast machine', 10;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M11')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Machine 11', N'DC1-M11', N'Die cast machine', 11;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Terminal 01', N'DC1-T01', N'Shared terminal — serves M01, M02', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T01-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC1-T01'), N'Die Cast 1 Terminal 01 — Printer', N'DC1-T01-P1', N'Label printer for DC1-T01', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Terminal 02', N'DC1-T02', N'Shared terminal — serves M03, M04', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T02-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC1-T02'), N'Die Cast 1 Terminal 02 — Printer', N'DC1-T02-P1', N'Label printer for DC1-T02', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Terminal 03', N'DC1-T03', N'Shared terminal — serves M05, M06', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T03-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC1-T03'), N'Die Cast 1 Terminal 03 — Printer', N'DC1-T03-P1', N'Label printer for DC1-T03', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T04')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Terminal 04', N'DC1-T04', N'Shared terminal — serves M07, M08', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T04-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC1-T04'), N'Die Cast 1 Terminal 04 — Printer', N'DC1-T04-P1', N'Label printer for DC1-T04', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T05')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Terminal 05', N'DC1-T05', N'Shared terminal — serves M09, M10', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T05-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC1-T05'), N'Die Cast 1 Terminal 05 — Printer', N'DC1-T05-P1', N'Label printer for DC1-T05', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T06')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die Cast 1 Terminal 06', N'DC1-T06', N'Shared terminal — serves M11', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T06-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC1-T06'), N'Die Cast 1 Terminal 06 — Printer', N'DC1-T06-P1', N'Label printer for DC1-T06', 1;

-- === Die Cast 2 (3 machines, pair terminals) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 2', N'DC2', N'Die casting area — 3 machines', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Die Cast 2 Machine 01', N'DC2-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Die Cast 2 Machine 02', N'DC2-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Die Cast 2 Machine 03', N'DC2-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-T01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Die Cast 2 Terminal 01', N'DC2-T01', N'Shared terminal — serves M01, M02', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-T01-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC2-T01'), N'Die Cast 2 Terminal 01 — Printer', N'DC2-T01-P1', N'Label printer for DC2-T01', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-T02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Die Cast 2 Terminal 02', N'DC2-T02', N'Shared terminal — serves M03', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-T02-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC2-T02'), N'Die Cast 2 Terminal 02 — Printer', N'DC2-T02-P1', N'Label printer for DC2-T02', 1;

-- === Die Cast 3 (5 machines, pair terminals) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 3', N'DC3', N'Die casting area — 5 machines', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Machine 01', N'DC3-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Machine 02', N'DC3-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Machine 03', N'DC3-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M04')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Machine 04', N'DC3-M04', N'Die cast machine', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M05')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Machine 05', N'DC3-M05', N'Die cast machine', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Terminal 01', N'DC3-T01', N'Shared terminal — serves M01, M02', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T01-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC3-T01'), N'Die Cast 3 Terminal 01 — Printer', N'DC3-T01-P1', N'Label printer for DC3-T01', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Terminal 02', N'DC3-T02', N'Shared terminal — serves M03, M04', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T02-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC3-T02'), N'Die Cast 3 Terminal 02 — Printer', N'DC3-T02-P1', N'Label printer for DC3-T02', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Die Cast 3 Terminal 03', N'DC3-T03', N'Shared terminal — serves M05', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T03-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC3-T03'), N'Die Cast 3 Terminal 03 — Printer', N'DC3-T03-P1', N'Label printer for DC3-T03', 1;

-- === Die Cast 4 (3 machines, pair terminals) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 4', N'DC4', N'Die casting area — 3 machines', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Die Cast 4 Machine 01', N'DC4-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Die Cast 4 Machine 02', N'DC4-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Die Cast 4 Machine 03', N'DC4-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-T01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Die Cast 4 Terminal 01', N'DC4-T01', N'Shared terminal — serves M01, M02', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-T01-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC4-T01'), N'Die Cast 4 Terminal 01 — Printer', N'DC4-T01-P1', N'Label printer for DC4-T01', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-T02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Die Cast 4 Terminal 02', N'DC4-T02', N'Shared terminal — serves M03', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-T02-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC4-T02'), N'Die Cast 4 Terminal 02 — Printer', N'DC4-T02-P1', N'Label printer for DC4-T02', 1;

-- === Trim Shop 1 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Trim Shop 1', N'TRIM1', N'Trim shop — area-level processing, no sublot split', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'), N'Trim Shop 1 Terminal', N'TRIM1-T1', N'Area-level trim terminal', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-T1'), N'Trim Shop 1 Terminal — Printer', N'TRIM1-T1-P1', N'Label printer for TRIM1-T1', 1;

-- === Trim Shop 2 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Trim Shop 2', N'TRIM2', N'Trim shop — area-level processing, no sublot split', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'TRIM2'), N'Trim Shop 2 Terminal', N'TRIM2-T1', N'Area-level trim terminal', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'TRIM2-T1'), N'Trim Shop 2 Terminal — Printer', N'TRIM2-T1-P1', N'Label printer for TRIM2-T1', 1;

-- === Machining & Assembly 1 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Machining & Assembly 1', N'MA1', N'Machining & Assembly room', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'Comp bracket', N'MA1-COMPBR', N'Line — Comp bracket', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR'), N'Comp bracket — Machining IN', N'MA1-COMPBR-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN'), N'Comp bracket — Machining IN — Printer', N'MA1-COMPBR-MIN-P1', N'Label printer for MA1-COMPBR-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR'), N'Comp bracket — Assembly OUT', N'MA1-COMPBR-AOUT', N'Assembly OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT'), N'Comp bracket — Assembly OUT — Printer', N'MA1-COMPBR-AOUT-P1', N'Label printer for MA1-COMPBR-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'6MD', N'MA1-6MD', N'Line — 6MD', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD'), N'6MD — Machining IN', N'MA1-6MD-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-MIN'), N'6MD — Machining IN — Printer', N'MA1-6MD-MIN-P1', N'Label printer for MA1-6MD-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD'), N'6MD — Assembly OUT', N'MA1-6MD-AOUT', N'Assembly OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-AOUT'), N'6MD — Assembly OUT — Printer', N'MA1-6MD-AOUT-P1', N'Label printer for MA1-6MD-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'Fuel Pump (RPY 66v)', N'MA1-FPRPY', N'Line — Fuel Pump (RPY 66v)', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY'), N'Fuel Pump (RPY 66v) — Machining IN', N'MA1-FPRPY-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MIN'), N'Fuel Pump (RPY 66v) — Machining IN — Printer', N'MA1-FPRPY-MIN-P1', N'Label printer for MA1-FPRPY-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY'), N'Fuel Pump (RPY 66v) — Machining OUT', N'MA1-FPRPY-MOUT', N'Machining OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT'), N'Fuel Pump (RPY 66v) — Machining OUT — Printer', N'MA1-FPRPY-MOUT-P1', N'Label printer for MA1-FPRPY-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY'), N'Fuel Pump (RPY 66v) — Assembly Finished', N'MA1-FPRPY-AFIN', N'Assembly Finished', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN'), N'Fuel Pump (RPY 66v) — Assembly Finished — Printer', N'MA1-FPRPY-AFIN-P1', N'Label printer for MA1-FPRPY-AFIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'Fuel Pump (6na 6vj)', N'MA1-FP6NA', N'Line — Fuel Pump (6na 6vj)', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA'), N'Fuel Pump (6na 6vj) — Machining IN', N'MA1-FP6NA-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN'), N'Fuel Pump (6na 6vj) — Machining IN — Printer', N'MA1-FP6NA-MIN-P1', N'Label printer for MA1-FP6NA-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA'), N'Fuel Pump (6na 6vj) — Machining OUT', N'MA1-FP6NA-MOUT', N'Machining OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT'), N'Fuel Pump (6na 6vj) — Machining OUT — Printer', N'MA1-FP6NA-MOUT-P1', N'Label printer for MA1-FP6NA-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA'), N'Fuel Pump (6na 6vj) — Assembly Finished', N'MA1-FP6NA-AFIN', N'Assembly Finished', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN'), N'Fuel Pump (6na 6vj) — Assembly Finished — Printer', N'MA1-FP6NA-AFIN-P1', N'Label printer for MA1-FP6NA-AFIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'5GO Rear', N'MA1-5GOR', N'Line — 5GO Rear', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR'), N'5GO Rear — Machining IN', N'MA1-5GOR-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-MIN'), N'5GO Rear — Machining IN — Printer', N'MA1-5GOR-MIN-P1', N'Label printer for MA1-5GOR-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR'), N'5GO Rear — Machining OUT', N'MA1-5GOR-MOUT', N'Machining OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-MOUT'), N'5GO Rear — Machining OUT — Printer', N'MA1-5GOR-MOUT-P1', N'Label printer for MA1-5GOR-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-ASER')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR'), N'5GO Rear — Assembly (Serialized)', N'MA1-5GOR-ASER', N'Assembly (Serialized)', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-ASER-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-ASER'), N'5GO Rear — Assembly (Serialized) — Printer', N'MA1-5GOR-ASER-P1', N'Label printer for MA1-5GOR-ASER', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'5GO Front', N'MA1-5GOF', N'Line — 5GO Front', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF'), N'5GO Front — Machining IN', N'MA1-5GOF-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN'), N'5GO Front — Machining IN — Printer', N'MA1-5GOF-MIN-P1', N'Label printer for MA1-5GOF-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF'), N'5GO Front — Machining OUT', N'MA1-5GOF-MOUT', N'Machining OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT'), N'5GO Front — Machining OUT — Printer', N'MA1-5GOF-MOUT-P1', N'Label printer for MA1-5GOF-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-ASER')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF'), N'5GO Front — Assembly (Serialized)', N'MA1-5GOF-ASER', N'Assembly (Serialized)', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-ASER-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-ASER'), N'5GO Front — Assembly (Serialized) — Printer', N'MA1-5GOF-ASER-P1', N'Label printer for MA1-5GOF-ASER', 1;

-- === Machining & Assembly 2 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Machining & Assembly 2', N'MA2', N'Machining & Assembly room', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'RPY 6b2 line2', N'MA2-RPY6B2', N'Line — RPY 6b2 line2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'RPY 6b2 line2 — Machining IN', N'MA2-RPY6B2-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-MIN'), N'RPY 6b2 line2 — Machining IN — Printer', N'MA2-RPY6B2-MIN-P1', N'Label printer for MA2-RPY6B2-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'RPY 6b2 line2 — Machining OUT', N'MA2-RPY6B2-MOUT', N'Machining OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-MOUT'), N'RPY 6b2 line2 — Machining OUT — Printer', N'MA2-RPY6B2-MOUT-P1', N'Label printer for MA2-RPY6B2-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'RPY 6b2 line2 — Assembly IN', N'MA2-RPY6B2-AIN', N'Assembly IN', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-AIN'), N'RPY 6b2 line2 — Assembly IN — Printer', N'MA2-RPY6B2-AIN-P1', N'Label printer for MA2-RPY6B2-AIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AFIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'RPY 6b2 line2 — Assembly Finished', N'MA2-RPY6B2-AFIN', N'Assembly Finished', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AFIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-AFIN'), N'RPY 6b2 line2 — Assembly Finished — Printer', N'MA2-RPY6B2-AFIN-P1', N'Label printer for MA2-RPY6B2-AFIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'RPY Line 2 Cam holders', N'MA2-RPYCAM2', N'Line — RPY Line 2 Cam holders', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Machining IN — Side A', N'MA2-RPYCAM2-MIN-A', N'Machining IN — Side A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-A'), N'RPY Line 2 Cam holders — Machining IN — Side A — Printer', N'MA2-RPYCAM2-MIN-A-P1', N'Label printer for MA2-RPYCAM2-MIN-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Machining IN — Side B', N'MA2-RPYCAM2-MIN-B', N'Machining IN — Side B', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-B'), N'RPY Line 2 Cam holders — Machining IN — Side B — Printer', N'MA2-RPYCAM2-MIN-B-P1', N'Label printer for MA2-RPYCAM2-MIN-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Machining OUT — Side A', N'MA2-RPYCAM2-MOUT-A', N'Machining OUT — Side A', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-A'), N'RPY Line 2 Cam holders — Machining OUT — Side A — Printer', N'MA2-RPYCAM2-MOUT-A-P1', N'Label printer for MA2-RPYCAM2-MOUT-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Machining OUT — Side B', N'MA2-RPYCAM2-MOUT-B', N'Machining OUT — Side B', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-B'), N'RPY Line 2 Cam holders — Machining OUT — Side B — Printer', N'MA2-RPYCAM2-MOUT-B-P1', N'Label printer for MA2-RPYCAM2-MOUT-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Assembly IN', N'MA2-RPYCAM2-AIN', N'Assembly IN', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AIN'), N'RPY Line 2 Cam holders — Assembly IN — Printer', N'MA2-RPYCAM2-AIN-P1', N'Label printer for MA2-RPYCAM2-AIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Assembly OUT 1', N'MA2-RPYCAM2-AOUT1', N'Assembly OUT 1', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT1'), N'RPY Line 2 Cam holders — Assembly OUT 1 — Printer', N'MA2-RPYCAM2-AOUT1-P1', N'Label printer for MA2-RPYCAM2-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Assembly OUT 2', N'MA2-RPYCAM2-AOUT2', N'Assembly OUT 2', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT2'), N'RPY Line 2 Cam holders — Assembly OUT 2 — Printer', N'MA2-RPYCAM2-AOUT2-P1', N'Label printer for MA2-RPYCAM2-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'RPY Line 2 Cam holders — Assembly OUT 3', N'MA2-RPYCAM2-AOUT3', N'Assembly OUT 3', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT3'), N'RPY Line 2 Cam holders — Assembly OUT 3 — Printer', N'MA2-RPYCAM2-AOUT3-P1', N'Label printer for MA2-RPYCAM2-AOUT3', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'RPY Line 1 CH', N'MA2-RPYCAM1', N'Line — RPY Line 1 CH', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Machining IN — Side A', N'MA2-RPYCAM1-MIN-A', N'Machining IN — Side A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-A'), N'RPY Line 1 CH — Machining IN — Side A — Printer', N'MA2-RPYCAM1-MIN-A-P1', N'Label printer for MA2-RPYCAM1-MIN-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Machining IN — Side B', N'MA2-RPYCAM1-MIN-B', N'Machining IN — Side B', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-B'), N'RPY Line 1 CH — Machining IN — Side B — Printer', N'MA2-RPYCAM1-MIN-B-P1', N'Label printer for MA2-RPYCAM1-MIN-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Machining OUT — Side A', N'MA2-RPYCAM1-MOUT-A', N'Machining OUT — Side A', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-A'), N'RPY Line 1 CH — Machining OUT — Side A — Printer', N'MA2-RPYCAM1-MOUT-A-P1', N'Label printer for MA2-RPYCAM1-MOUT-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Machining OUT — Side B', N'MA2-RPYCAM1-MOUT-B', N'Machining OUT — Side B', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-B'), N'RPY Line 1 CH — Machining OUT — Side B — Printer', N'MA2-RPYCAM1-MOUT-B-P1', N'Label printer for MA2-RPYCAM1-MOUT-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Assembly IN', N'MA2-RPYCAM1-AIN', N'Assembly IN', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AIN'), N'RPY Line 1 CH — Assembly IN — Printer', N'MA2-RPYCAM1-AIN-P1', N'Label printer for MA2-RPYCAM1-AIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Assembly OUT 1', N'MA2-RPYCAM1-AOUT1', N'Assembly OUT 1', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT1'), N'RPY Line 1 CH — Assembly OUT 1 — Printer', N'MA2-RPYCAM1-AOUT1-P1', N'Label printer for MA2-RPYCAM1-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Assembly OUT 2', N'MA2-RPYCAM1-AOUT2', N'Assembly OUT 2', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT2'), N'RPY Line 1 CH — Assembly OUT 2 — Printer', N'MA2-RPYCAM1-AOUT2-P1', N'Label printer for MA2-RPYCAM1-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'RPY Line 1 CH — Assembly OUT 3', N'MA2-RPYCAM1-AOUT3', N'Assembly OUT 3', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT3'), N'RPY Line 1 CH — Assembly OUT 3 — Printer', N'MA2-RPYCAM1-AOUT3-P1', N'Label printer for MA2-RPYCAM1-AOUT3', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'5PA Fuel Pump', N'MA2-5PA', N'Line — 5PA Fuel Pump', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA'), N'5PA Fuel Pump — Machining IN 1', N'MA2-5PA-MIN1', N'Machining IN 1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA-MIN1'), N'5PA Fuel Pump — Machining IN 1 — Printer', N'MA2-5PA-MIN1-P1', N'Label printer for MA2-5PA-MIN1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA'), N'5PA Fuel Pump — Machining IN 2', N'MA2-5PA-MIN2', N'Machining IN 2', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA-MIN2'), N'5PA Fuel Pump — Machining IN 2 — Printer', N'MA2-5PA-MIN2-P1', N'Label printer for MA2-5PA-MIN2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA'), N'5PA Fuel Pump — Machining IN 3', N'MA2-5PA-MIN3', N'Machining IN 3', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA-MIN3'), N'5PA Fuel Pump — Machining IN 3 — Printer', N'MA2-5PA-MIN3-P1', N'Label printer for MA2-5PA-MIN3', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6ma oil pan', N'MA2-6MAOP', N'Line — 6ma oil pan', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP'), N'6ma oil pan — Machining IN', N'MA2-6MAOP-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP-MIN'), N'6ma oil pan — Machining IN — Printer', N'MA2-6MAOP-MIN-P1', N'Label printer for MA2-6MAOP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP'), N'6ma oil pan — Assembly OUT', N'MA2-6MAOP-AOUT', N'Assembly OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP-AOUT'), N'6ma oil pan — Assembly OUT — Printer', N'MA2-6MAOP-AOUT-P1', N'Label printer for MA2-6MAOP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'v6 oil pan', N'MA2-V6OP', N'Line — v6 oil pan', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP'), N'v6 oil pan — Machining IN', N'MA2-V6OP-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP-MIN'), N'v6 oil pan — Machining IN — Printer', N'MA2-V6OP-MIN-P1', N'Label printer for MA2-V6OP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP'), N'v6 oil pan — Assembly OUT', N'MA2-V6OP-AOUT', N'Assembly OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP-AOUT'), N'v6 oil pan — Assembly OUT — Printer', N'MA2-V6OP-AOUT-P1', N'Label printer for MA2-V6OP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-COS')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'COS (offsite-origin)', N'MA2-COS', N'Line — COS (offsite-origin)', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-COS-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-COS'), N'COS (offsite-origin) — Machining OUT', N'MA2-COS-MOUT', N'Machining OUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-COS-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-COS-MOUT'), N'COS (offsite-origin) — Machining OUT — Printer', N'MA2-COS-MOUT-P1', N'Label printer for MA2-COS-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6F9TC')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6F9-TC (offsite-origin)', N'MA2-6F9TC', N'Line — 6F9-TC (offsite-origin)', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6F9TC-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6F9TC'), N'6F9-TC (offsite-origin) — Machining OUT', N'MA2-6F9TC-MOUT', N'Machining OUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6F9TC-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6F9TC-MOUT'), N'6F9-TC (offsite-origin) — Machining OUT — Printer', N'MA2-6F9TC-MOUT-P1', N'Label printer for MA2-6F9TC-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'59b Cam holder', N'MA2-59B', N'Line — 59b Cam holder', 9;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B'), N'59b Cam holder — Machining IN', N'MA2-59B-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B-MIN'), N'59b Cam holder — Machining IN — Printer', N'MA2-59B-MIN-P1', N'Label printer for MA2-59B-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B'), N'59b Cam holder — Assembly OUT 1', N'MA2-59B-AOUT1', N'Assembly OUT 1', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B-AOUT1'), N'59b Cam holder — Assembly OUT 1 — Printer', N'MA2-59B-AOUT1-P1', N'Label printer for MA2-59B-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B'), N'59b Cam holder — Assembly OUT 2', N'MA2-59B-AOUT2', N'Assembly OUT 2', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B-AOUT2'), N'59b Cam holder — Assembly OUT 2 — Printer', N'MA2-59B-AOUT2-P1', N'Label printer for MA2-59B-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6FB CH/OP', N'MA2-6FBCHOP', N'Line — 6FB CH/OP', 10;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP'), N'6FB CH/OP — Machining IN', N'MA2-6FBCHOP-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP-MIN'), N'6FB CH/OP — Machining IN — Printer', N'MA2-6FBCHOP-MIN-P1', N'Label printer for MA2-6FBCHOP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP'), N'6FB CH/OP — Assembly OUT', N'MA2-6FBCHOP-AOUT', N'Assembly OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP-AOUT'), N'6FB CH/OP — Assembly OUT — Printer', N'MA2-6FBCHOP-AOUT-P1', N'Label printer for MA2-6FBCHOP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'64A Oil Pan', N'MA2-64AOP', N'Line — 64A Oil Pan', 11;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP'), N'64A Oil Pan — Machining IN', N'MA2-64AOP-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP-MIN'), N'64A Oil Pan — Machining IN — Printer', N'MA2-64AOP-MIN-P1', N'Label printer for MA2-64AOP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP'), N'64A Oil Pan — Assembly OUT', N'MA2-64AOP-AOUT', N'Assembly OUT', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP-AOUT'), N'64A Oil Pan — Assembly OUT — Printer', N'MA2-64AOP-AOUT-P1', N'Label printer for MA2-64AOP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6MA CH', N'MA2-6MACH', N'Line — 6MA CH', 12;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'6MA CH — Machining IN', N'MA2-6MACH-MIN', N'Machining IN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-MIN'), N'6MA CH — Machining IN — Printer', N'MA2-6MACH-MIN-P1', N'Label printer for MA2-6MACH-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'6MA CH — Assembly OUT 1', N'MA2-6MACH-AOUT1', N'Assembly OUT 1', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1'), N'6MA CH — Assembly OUT 1 — Printer', N'MA2-6MACH-AOUT1-P1', N'Label printer for MA2-6MACH-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'6MA CH — Assembly OUT 2', N'MA2-6MACH-AOUT2', N'Assembly OUT 2', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT2'), N'6MA CH — Assembly OUT 2 — Printer', N'MA2-6MACH-AOUT2-P1', N'Label printer for MA2-6MACH-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'6MA CH — Assembly OUT 3', N'MA2-6MACH-AOUT3', N'Assembly OUT 3', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT3'), N'6MA CH — Assembly OUT 3 — Printer', N'MA2-6MACH-AOUT3-P1', N'Label printer for MA2-6MACH-AOUT3', 1;

-- === Storage ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'WHSE')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 4, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Warehouse', N'WHSE', N'WIP / cast storage — all die cast goes here prior to Trim', 9;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'SHIPIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 4, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Shipping IN', N'SHIPIN', N'Receiving dock — pass-through parts', 10;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'SHIPOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 4, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Shipping OUT', N'SHIPOUT', N'Finished-goods staging', 11;
