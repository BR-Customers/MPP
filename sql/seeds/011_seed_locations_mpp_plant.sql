-- ============================================================
-- Seed:        011_seed_locations_mpp_plant.sql   (GENERATED - edit gen_locations_mpp.js)
-- Description: Full MPP plant Location tree, reconciled from the two plant-layout-mapper
--              exports. ASCII-only Names/Descriptions. Idempotent by Code.
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
    VALUES (16, N'Endpoint', N'NVARCHAR', 1, NULL, NULL, 1, N'Zebra print target - IP:port or print-queue name');
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

-- === Die Cast 1 (11 machines, one terminal) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 1', N'DC1', N'Die casting area - 11 machines', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 01', N'DC1-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 02', N'DC1-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 03', N'DC1-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M04')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 04', N'DC1-M04', N'Die cast machine', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M05')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 05', N'DC1-M05', N'Die cast machine', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M06')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 06', N'DC1-M06', N'Die cast machine', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M07')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 07', N'DC1-M07', N'Die cast machine', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M08')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 08', N'DC1-M08', N'Die cast machine', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M09')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 09', N'DC1-M09', N'Die cast machine', 9;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M10')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 10', N'DC1-M10', N'Die cast machine', 10;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-M11')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Machine 11', N'DC1-M11', N'Die cast machine', 11;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Terminal', N'DC1-T1', N'Die cast area terminal', 12;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC1-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC1-T1'), N'P - 001', N'DC1-T1-P1', N'Label printer for DC1-T1', 1;

-- === Die Cast 2 (3 machines, one terminal) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 2', N'DC2', N'Die casting area - 3 machines', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Machine 01', N'DC2-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Machine 02', N'DC2-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Machine 03', N'DC2-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC2'), N'Terminal', N'DC2-T1', N'Die cast area terminal', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC2-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC2-T1'), N'P - 002', N'DC2-T1-P1', N'Label printer for DC2-T1', 1;

-- === Die Cast 3 (5 machines, one terminal) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 3', N'DC3', N'Die casting area - 5 machines', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Machine 01', N'DC3-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Machine 02', N'DC3-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Machine 03', N'DC3-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M04')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Machine 04', N'DC3-M04', N'Die cast machine', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-M05')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Machine 05', N'DC3-M05', N'Die cast machine', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC3'), N'Terminal', N'DC3-T1', N'Die cast area terminal', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC3-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC3-T1'), N'P - 003', N'DC3-T1-P1', N'Label printer for DC3-T1', 1;

-- === Die Cast 4 (3 machines, one terminal) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Die Cast 4', N'DC4', N'Die casting area - 3 machines', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-M01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Machine 01', N'DC4-M01', N'Die cast machine', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-M02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Machine 02', N'DC4-M02', N'Die cast machine', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-M03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 8, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Machine 03', N'DC4-M03', N'Die cast machine', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'DC4'), N'Terminal', N'DC4-T1', N'Die cast area terminal', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'DC4-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'DC4-T1'), N'P - 004', N'DC4-T1-P1', N'Label printer for DC4-T1', 1;

-- === Trim Shop 1 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Trim Shop 1', N'TRIM1', N'Trim shop - trim press cells, no sublot split', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'), N'Terminal', N'TRIM1-T1', N'Shared trim terminal', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1-T1'), N'P - 005', N'TRIM1-T1-P1', N'Label printer for TRIM1-T1', 1;
-- trim press cells (TrimPress) the shared trim terminal serves
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1-P01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 10, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'), N'Press 01', N'TRIM1-P01', N'Trim press', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1-P02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 10, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'), N'Press 02', N'TRIM1-P02', N'Trim press', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM1-P03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 10, (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'), N'Press 03', N'TRIM1-P03', N'Trim press', 3;

-- === Trim Shop 2 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Trim Shop 2', N'TRIM2', N'Trim shop - trim press cells, no sublot split', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'TRIM2'), N'Terminal', N'TRIM2-T1', N'Shared trim terminal', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2-T1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'TRIM2-T1'), N'P - 006', N'TRIM2-T1-P1', N'Label printer for TRIM2-T1', 1;
-- trim press cells (TrimPress) the shared trim terminal serves
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2-P01')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 10, (SELECT Id FROM Location.Location WHERE Code = N'TRIM2'), N'Press 01', N'TRIM2-P01', N'Trim press', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2-P02')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 10, (SELECT Id FROM Location.Location WHERE Code = N'TRIM2'), N'Press 02', N'TRIM2-P02', N'Trim press', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TRIM2-P03')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 10, (SELECT Id FROM Location.Location WHERE Code = N'TRIM2'), N'Press 03', N'TRIM2-P03', N'Trim press', 3;

-- === Machining & Assembly 1 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Machining & Assembly 1', N'MA1', N'Machining and Assembly room', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'Comp bracket', N'MA1-COMPBR', N'Line - Comp bracket', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR'), N'Machining In', N'MA1-COMPBR-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-MIN'), N'P - 007', N'MA1-COMPBR-MIN-P1', N'Label printer for MA1-COMPBR-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR'), N'Assembly Out', N'MA1-COMPBR-AOUT', N'Assembly Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT'), N'P - 008', N'MA1-COMPBR-AOUT-P1', N'Label printer for MA1-COMPBR-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'6MD', N'MA1-6MD', N'Line - 6MD', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD'), N'Machining In', N'MA1-6MD-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-MIN'), N'P - 009', N'MA1-6MD-MIN-P1', N'Label printer for MA1-6MD-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD'), N'Assembly Out', N'MA1-6MD-AOUT', N'Assembly Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-6MD-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD-AOUT'), N'P - 010', N'MA1-6MD-AOUT-P1', N'Label printer for MA1-6MD-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'Fuel Pump (RPY 66v)', N'MA1-FPRPY', N'Line - Fuel Pump (RPY 66v)', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY'), N'Machining In', N'MA1-FPRPY-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MIN'), N'P - 011', N'MA1-FPRPY-MIN-P1', N'Label printer for MA1-FPRPY-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY'), N'Machining Out', N'MA1-FPRPY-MOUT', N'Machining Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-MOUT'), N'P - 012', N'MA1-FPRPY-MOUT-P1', N'Label printer for MA1-FPRPY-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY'), N'Assembly Finished', N'MA1-FPRPY-AFIN', N'Assembly Finished', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FPRPY-AFIN'), N'P - 013', N'MA1-FPRPY-AFIN-P1', N'Label printer for MA1-FPRPY-AFIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'Fuel Pump (6na 6vj)', N'MA1-FP6NA', N'Line - Fuel Pump (6na 6vj)', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA'), N'Machining In', N'MA1-FP6NA-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MIN'), N'P - 014', N'MA1-FP6NA-MIN-P1', N'Label printer for MA1-FP6NA-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA'), N'Machining Out', N'MA1-FP6NA-MOUT', N'Machining Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-MOUT'), N'P - 015', N'MA1-FP6NA-MOUT-P1', N'Label printer for MA1-FP6NA-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA'), N'Assembly Finished', N'MA1-FP6NA-AFIN', N'Assembly Finished', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-FP6NA-AFIN'), N'P - 016', N'MA1-FP6NA-AFIN-P1', N'Label printer for MA1-FP6NA-AFIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'5G0 Rear', N'MA1-5GOR', N'Line - 5G0 Rear', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR'), N'Machining In', N'MA1-5GOR-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-MIN'), N'P - 017', N'MA1-5GOR-MIN-P1', N'Label printer for MA1-5GOR-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR'), N'Machining Out', N'MA1-5GOR-MOUT', N'Machining Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-MOUT'), N'P - 018', N'MA1-5GOR-MOUT-P1', N'Label printer for MA1-5GOR-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-ASER')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR'), N'Assembly (Serialized)', N'MA1-5GOR-ASER', N'Assembly (Serialized)', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOR-ASER-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOR-ASER'), N'P - 019', N'MA1-5GOR-ASER-P1', N'Label printer for MA1-5GOR-ASER', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'5G0 Front', N'MA1-5GOF', N'Line - 5G0 Front', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF'), N'Machining In', N'MA1-5GOF-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MIN'), N'P - 020', N'MA1-5GOF-MIN-P1', N'Label printer for MA1-5GOF-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF'), N'Machining Out', N'MA1-5GOF-MOUT', N'Machining Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-MOUT'), N'P - 021', N'MA1-5GOF-MOUT-P1', N'Label printer for MA1-5GOF-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-ASER')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF'), N'Assembly (Serialized)', N'MA1-5GOF-ASER', N'Assembly (Serialized)', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA1-5GOF-ASER-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF-ASER'), N'P - 022', N'MA1-5GOF-ASER-P1', N'Label printer for MA1-5GOF-ASER', 1;

-- === Machining & Assembly 2 ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 3, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Machining & Assembly 2', N'MA2', N'Machining and Assembly room', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'RPY 6b2 line2', N'MA2-RPY6B2', N'Line - RPY 6b2 line2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'Machining In', N'MA2-RPY6B2-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-MIN'), N'P - 023', N'MA2-RPY6B2-MIN-P1', N'Label printer for MA2-RPY6B2-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'Machining Out', N'MA2-RPY6B2-MOUT', N'Machining Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-MOUT'), N'P - 024', N'MA2-RPY6B2-MOUT-P1', N'Label printer for MA2-RPY6B2-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'Assembly In', N'MA2-RPY6B2-AIN', N'Assembly In', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-AIN'), N'P - 025', N'MA2-RPY6B2-AIN-P1', N'Label printer for MA2-RPY6B2-AIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AFIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2'), N'Assembly Finished', N'MA2-RPY6B2-AFIN', N'Assembly Finished', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPY6B2-AFIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPY6B2-AFIN'), N'P - 026', N'MA2-RPY6B2-AFIN-P1', N'Label printer for MA2-RPY6B2-AFIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'RPY Line 2 Cam holders', N'MA2-RPYCAM2', N'Line - RPY Line 2 Cam holders', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Machining In - Side A', N'MA2-RPYCAM2-MIN-A', N'Machining In - Side A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-A'), N'P - 027', N'MA2-RPYCAM2-MIN-A-P1', N'Label printer for MA2-RPYCAM2-MIN-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Machining In - Side B', N'MA2-RPYCAM2-MIN-B', N'Machining In - Side B', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MIN-B'), N'P - 028', N'MA2-RPYCAM2-MIN-B-P1', N'Label printer for MA2-RPYCAM2-MIN-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Machining Out - Side A', N'MA2-RPYCAM2-MOUT-A', N'Machining Out - Side A', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-A'), N'P - 029', N'MA2-RPYCAM2-MOUT-A-P1', N'Label printer for MA2-RPYCAM2-MOUT-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Machining Out - Side B', N'MA2-RPYCAM2-MOUT-B', N'Machining Out - Side B', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-MOUT-B'), N'P - 030', N'MA2-RPYCAM2-MOUT-B-P1', N'Label printer for MA2-RPYCAM2-MOUT-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Assembly In', N'MA2-RPYCAM2-AIN', N'Assembly In', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AIN'), N'P - 031', N'MA2-RPYCAM2-AIN-P1', N'Label printer for MA2-RPYCAM2-AIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Assembly Out 1', N'MA2-RPYCAM2-AOUT1', N'Assembly Out 1', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT1'), N'P - 032', N'MA2-RPYCAM2-AOUT1-P1', N'Label printer for MA2-RPYCAM2-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Assembly Out 2', N'MA2-RPYCAM2-AOUT2', N'Assembly Out 2', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT2'), N'P - 033', N'MA2-RPYCAM2-AOUT2-P1', N'Label printer for MA2-RPYCAM2-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2'), N'Assembly Out 3', N'MA2-RPYCAM2-AOUT3', N'Assembly Out 3', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM2-AOUT3'), N'P - 034', N'MA2-RPYCAM2-AOUT3-P1', N'Label printer for MA2-RPYCAM2-AOUT3', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'RPY Line 1 CH', N'MA2-RPYCAM1', N'Line - RPY Line 1 CH', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Machining In - Side A', N'MA2-RPYCAM1-MIN-A', N'Machining In - Side A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-A'), N'P - 035', N'MA2-RPYCAM1-MIN-A-P1', N'Label printer for MA2-RPYCAM1-MIN-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Machining In - Side B', N'MA2-RPYCAM1-MIN-B', N'Machining In - Side B', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MIN-B'), N'P - 036', N'MA2-RPYCAM1-MIN-B-P1', N'Label printer for MA2-RPYCAM1-MIN-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-A')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Machining Out - Side A', N'MA2-RPYCAM1-MOUT-A', N'Machining Out - Side A', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-A-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-A'), N'P - 037', N'MA2-RPYCAM1-MOUT-A-P1', N'Label printer for MA2-RPYCAM1-MOUT-A', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Machining Out - Side B', N'MA2-RPYCAM1-MOUT-B', N'Machining Out - Side B', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-B-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-MOUT-B'), N'P - 038', N'MA2-RPYCAM1-MOUT-B-P1', N'Label printer for MA2-RPYCAM1-MOUT-B', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Assembly In', N'MA2-RPYCAM1-AIN', N'Assembly In', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AIN'), N'P - 039', N'MA2-RPYCAM1-AIN-P1', N'Label printer for MA2-RPYCAM1-AIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Assembly Out 1', N'MA2-RPYCAM1-AOUT1', N'Assembly Out 1', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT1'), N'P - 040', N'MA2-RPYCAM1-AOUT1-P1', N'Label printer for MA2-RPYCAM1-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Assembly Out 2', N'MA2-RPYCAM1-AOUT2', N'Assembly Out 2', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT2'), N'P - 041', N'MA2-RPYCAM1-AOUT2-P1', N'Label printer for MA2-RPYCAM1-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1'), N'Assembly Out 3', N'MA2-RPYCAM1-AOUT3', N'Assembly Out 3', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-RPYCAM1-AOUT3'), N'P - 042', N'MA2-RPYCAM1-AOUT3-P1', N'Label printer for MA2-RPYCAM1-AOUT3', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'5PA Fuel Pump', N'MA2-5PA', N'Line - 5PA Fuel Pump', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA'), N'Machining In 1', N'MA2-5PA-MIN1', N'Machining In 1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA-MIN1'), N'P - 043', N'MA2-5PA-MIN1-P1', N'Label printer for MA2-5PA-MIN1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA'), N'Machining In 2', N'MA2-5PA-MIN2', N'Machining In 2', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA-MIN2'), N'P - 044', N'MA2-5PA-MIN2-P1', N'Label printer for MA2-5PA-MIN2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA'), N'Machining In 3', N'MA2-5PA-MIN3', N'Machining In 3', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-5PA-MIN3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-5PA-MIN3'), N'P - 045', N'MA2-5PA-MIN3-P1', N'Label printer for MA2-5PA-MIN3', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6ma oil pan', N'MA2-6MAOP', N'Line - 6ma oil pan', 5;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP'), N'Machining In', N'MA2-6MAOP-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP-MIN'), N'P - 046', N'MA2-6MAOP-MIN-P1', N'Label printer for MA2-6MAOP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP'), N'Assembly Out', N'MA2-6MAOP-AOUT', N'Assembly Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MAOP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MAOP-AOUT'), N'P - 047', N'MA2-6MAOP-AOUT-P1', N'Label printer for MA2-6MAOP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'v6 oil pan', N'MA2-V6OP', N'Line - v6 oil pan', 6;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP'), N'Machining In', N'MA2-V6OP-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP-MIN'), N'P - 048', N'MA2-V6OP-MIN-P1', N'Label printer for MA2-V6OP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP'), N'Assembly Out', N'MA2-V6OP-AOUT', N'Assembly Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-V6OP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-V6OP-AOUT'), N'P - 049', N'MA2-V6OP-AOUT-P1', N'Label printer for MA2-V6OP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-COS')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'COS (offsite-origin)', N'MA2-COS', N'Line - COS (offsite-origin)', 7;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-COS-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-COS'), N'Machining Out', N'MA2-COS-MOUT', N'Machining Out', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-COS-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-COS-MOUT'), N'P - 050', N'MA2-COS-MOUT-P1', N'Label printer for MA2-COS-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6F9TC')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6F9-TC (offsite-origin)', N'MA2-6F9TC', N'Line - 6F9-TC (offsite-origin)', 8;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6F9TC-MOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6F9TC'), N'Machining Out', N'MA2-6F9TC-MOUT', N'Machining Out', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6F9TC-MOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6F9TC-MOUT'), N'P - 051', N'MA2-6F9TC-MOUT-P1', N'Label printer for MA2-6F9TC-MOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'59b Cam holder', N'MA2-59B', N'Line - 59b Cam holder', 9;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B'), N'Machining In', N'MA2-59B-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B-MIN'), N'P - 052', N'MA2-59B-MIN-P1', N'Label printer for MA2-59B-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B'), N'Assembly Out 1', N'MA2-59B-AOUT1', N'Assembly Out 1', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B-AOUT1'), N'P - 053', N'MA2-59B-AOUT1-P1', N'Label printer for MA2-59B-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B'), N'Assembly Out 2', N'MA2-59B-AOUT2', N'Assembly Out 2', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-59B-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-59B-AOUT2'), N'P - 054', N'MA2-59B-AOUT2-P1', N'Label printer for MA2-59B-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6FB CH/OP', N'MA2-6FBCHOP', N'Line - 6FB CH/OP', 10;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP'), N'Machining In', N'MA2-6FBCHOP-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP-MIN'), N'P - 055', N'MA2-6FBCHOP-MIN-P1', N'Label printer for MA2-6FBCHOP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP'), N'Assembly Out', N'MA2-6FBCHOP-AOUT', N'Assembly Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6FBCHOP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6FBCHOP-AOUT'), N'P - 056', N'MA2-6FBCHOP-AOUT-P1', N'Label printer for MA2-6FBCHOP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'64A Oil Pan', N'MA2-64AOP', N'Line - 64A Oil Pan', 11;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP'), N'Machining In', N'MA2-64AOP-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP-MIN'), N'P - 057', N'MA2-64AOP-MIN-P1', N'Label printer for MA2-64AOP-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-AOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP'), N'Assembly Out', N'MA2-64AOP-AOUT', N'Assembly Out', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-64AOP-AOUT-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-64AOP-AOUT'), N'P - 058', N'MA2-64AOP-AOUT-P1', N'Label printer for MA2-64AOP-AOUT', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 5, (SELECT Id FROM Location.Location WHERE Code = N'MA2'), N'6MA CH', N'MA2-6MACH', N'Line - 6MA CH', 12;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-MIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'Machining In', N'MA2-6MACH-MIN', N'Machining In', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-MIN-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-MIN'), N'P - 059', N'MA2-6MACH-MIN-P1', N'Label printer for MA2-6MACH-MIN', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'Assembly Out 1', N'MA2-6MACH-AOUT1', N'Assembly Out 1', 2;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1'), N'P - 060', N'MA2-6MACH-AOUT1-P1', N'Label printer for MA2-6MACH-AOUT1', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'Assembly Out 2', N'MA2-6MACH-AOUT2', N'Assembly Out 2', 3;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT2-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT2'), N'P - 061', N'MA2-6MACH-AOUT2-P1', N'Label printer for MA2-6MACH-AOUT2', 1;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT3')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH'), N'Assembly Out 3', N'MA2-6MACH-AOUT3', N'Assembly Out 3', 4;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT3-P1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 16, (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT3'), N'P - 062', N'MA2-6MACH-AOUT3-P1', N'Label printer for MA2-6MACH-AOUT3', 1;

-- === Storage ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'WHSE')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 4, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Warehouse', N'WHSE', N'WIP / cast storage - all die cast goes here prior to Trim', 9;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'SHIPIN')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 4, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Shipping IN', N'SHIPIN', N'Receiving dock - pass-through parts', 10;
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'SHIPOUT')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 4, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Shipping OUT', N'SHIPOUT', N'Finished-goods staging', 11;

-- === Fallback Terminal (Arc 2 Phase 1 Task C) ===
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'FALLBACK-TERMINAL')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
    SELECT 7, (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD'), N'Fallback Terminal', N'FALLBACK-TERMINAL', N'Global default terminal returned when an unregistered IP address connects.', 12;
