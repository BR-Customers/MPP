-- ============================================================
-- Seed:        seed_items.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-05-20
-- Description: Dummy Parts data for the Item Master Configuration
--              Tool screen. Idempotent (IF NOT EXISTS guards).
--
--              Seeds:
--                - AppUser Id 2 (dev user, matches Common.Util
--                  ._currentAppUserId fallback)
--                - 4 OperationTemplates (Die Cast, Trim, CNC, Assembly)
--                - 6 Items: 5G0, 5G0-C, PNA, 6MA-HSG, RPY, 5G0-MACH
--                - ContainerConfig per Item (5G0-MACH is an intermediate, no config)
--                - Published RouteTemplate + 4 RouteSteps for 5G0
--                - Published Boms: 5G0 <- 5G0-MACH + 2x PNA (assembly);
--                  5G0-MACH <- 5G0-C (machining rename, FDS-05-033)
--                - 2 QualitySpecs linked to 5G0
--
--              Dependencies:
--                - 011_seed_locations_mpp_plant.sql (areas resolved by
--                  Code: DC1, TRIM1, MA1)
-- ============================================================

SET NOCOUNT ON;

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- ============================================================
-- AppUser Id 2 (dev user)
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = 2)
BEGIN
    SET IDENTITY_INSERT Location.AppUser ON;
    INSERT INTO Location.AppUser (Id, AdAccount, DisplayName, IgnitionRole, Initials, CreatedAt)
    VALUES (2, N'dev.user', N'Dev User', N'Admin', N'DEV', @Now);
    SET IDENTITY_INSERT Location.AppUser OFF;
END

-- ============================================================
-- OperationTemplates (need AreaLocationId)
--   Areas resolved by Code from 011_seed_locations_mpp_plant.sql: DC1, TRIM1, MA1
-- ============================================================

SET IDENTITY_INSERT Parts.OperationTemplate ON;

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 1)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (1, N'DC-5G0', 1, N'Die Cast 5G0 Front Cover', (SELECT Id FROM Location.Location WHERE Code = N'DC1'), N'Die cast operation for the 5G0 front cover assembly.', @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 2)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (2, N'TRIM-5G0', 1, N'Trim 5G0 Front Cover', (SELECT Id FROM Location.Location WHERE Code = N'TRIM1'), N'Trim/deflash operation for the 5G0 front cover.', @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 3)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (3, N'CNC-5G0', 1, N'CNC Machining 5G0', (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'CNC machining operation for the 5G0 front cover.', @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = 4)
    INSERT INTO Parts.OperationTemplate (Id, Code, VersionNumber, Name, AreaLocationId, Description, CreatedAt)
    VALUES (4, N'ASSY-FRONT', 1, N'Assembly Front Cover', (SELECT Id FROM Location.Location WHERE Code = N'MA1'), N'Final assembly of the 5G0 front cover.', @Now);

SET IDENTITY_INSERT Parts.OperationTemplate OFF;

-- ============================================================
-- Parts.Item (6 items: 5 mockup items + 5G0-MACH machining intermediate)
--   ItemType:  1=RawMaterial 2=Component 3=SubAssembly 4=FinishedGood 5=PassThrough
--   Uom:       1=EA 2=LB 3=KG
-- ============================================================

SET IDENTITY_INSERT Parts.Item ON;

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 1)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (1, 4, N'5G0',     N'5G0 Front Cover Assembly',    N'5G0-FC-001', 24, NULL, 1, 3.25, 2, N'US', 500, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 2)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (2, 2, N'5G0-C',   N'5G0 Front Cover Casting',     N'5G0-CST-001', 48, NULL, 1, 2.80, 2, N'US', NULL, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 3)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (3, 2, N'PNA',     N'Mounting Pin',                N'PIN-A-002',   100, NULL, 1, 0.05, 2, N'US', NULL, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 4)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (4, 5, N'6MA-HSG', N'Cam Holder Housing',          N'HSG-6MA-001', 50, NULL, 1, 1.10, 2, N'JP', NULL, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 5)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (5, 4, N'RPY',     N'Assembly Set',                N'RPY-SET-001', 12, NULL, 1, 5.50, 2, N'US', 300, @Now, 2);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = 6)
    INSERT INTO Parts.Item (Id, ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (6, 3, N'5G0-MACH', N'5G0 Machined Front Cover',    N'5G0-MCH-001', 24, NULL, 1, 2.90, 2, N'US', NULL, @Now, 2);

SET IDENTITY_INSERT Parts.Item OFF;

-- ============================================================
-- Parts.ContainerConfig (one per Item)
-- ============================================================

SET IDENTITY_INSERT Parts.ContainerConfig ON;

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 1)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (1, 1, 4,  12,  1, N'RD-5G0F',  N'HONDA-5G0',  N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 2)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (2, 2, 6,  24,  0, N'RD-5G0C',  NULL,           N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 3)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (3, 3, 10, 100, 0, N'BAG-PIN',  NULL,           N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 4)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (4, 4, 4,  25,  0, N'RD-6MA',   N'HONDA-6MA',   N'ByCount',  NULL,  @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE Id = 5)
    INSERT INTO Parts.ContainerConfig (Id, ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    VALUES (5, 5, 2,  6,   1, N'RD-RPY',   N'HONDA-RPY',   N'ByCount',  NULL,  @Now);

SET IDENTITY_INSERT Parts.ContainerConfig OFF;

-- ============================================================
-- Parts.RouteTemplate (published) for Item 1 (5G0) and 5 (RPY)
-- ============================================================

SET IDENTITY_INSERT Parts.RouteTemplate ON;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE Id = 1)
    INSERT INTO Parts.RouteTemplate (Id, ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (1, 1, 2, N'5G0 Production Route v2', '2026-01-15', '2026-01-14', NULL, 2, @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE Id = 2)
    INSERT INTO Parts.RouteTemplate (Id, ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (2, 5, 1, N'RPY Assembly Route v1', '2026-02-01', '2026-01-30', NULL, 2, @Now);

SET IDENTITY_INSERT Parts.RouteTemplate OFF;

-- ============================================================
-- Parts.RouteStep (steps for Route Id 1 and Route Id 2)
-- ============================================================

SET IDENTITY_INSERT Parts.RouteStep ON;

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 1)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (1, 1, 1, 1, 1, N'DieInfo, CavityInfo, Weight, GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 2)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (2, 1, 2, 2, 1, N'Weight, GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 3)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (3, 1, 3, 3, 1, N'GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 4)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (4, 1, 4, 4, 1, N'SerialNumber, MaterialVerification, GoodCount, BadCount');

IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE Id = 5)
    INSERT INTO Parts.RouteStep (Id, RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
    VALUES (5, 2, 4, 1, 1, N'SerialNumber, GoodCount, BadCount');

SET IDENTITY_INSERT Parts.RouteStep OFF;

-- ============================================================
-- Parts.Bom (published): Item 1 (5G0 assembly) + Item 6 (5G0-MACH machining rename)
-- ============================================================

SET IDENTITY_INSERT Parts.Bom ON;

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE Id = 1)
    INSERT INTO Parts.Bom (Id, ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (1, 1, 1, '2026-01-15', '2026-01-14', NULL, 2, @Now);

IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE Id = 2)
    INSERT INTO Parts.Bom (Id, ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (2, 6, 1, '2026-01-15', '2026-01-14', NULL, 2, @Now);   -- machining rename BOM: 5G0-MACH <- 5G0-C (FDS-05-033)

SET IDENTITY_INSERT Parts.Bom OFF;

-- ============================================================
-- Parts.BomLine
-- ============================================================

SET IDENTITY_INSERT Parts.BomLine ON;

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine WHERE Id = 1)
    INSERT INTO Parts.BomLine (Id, BomId, ChildItemId, QtyPer, UomId, SortOrder)
    VALUES (1, 1, 6, 1.0, 1, 1);   -- 5G0 needs 1x 5G0-MACH (machined front cover, per cast->machine->assemble chain)

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine WHERE Id = 2)
    INSERT INTO Parts.BomLine (Id, BomId, ChildItemId, QtyPer, UomId, SortOrder)
    VALUES (2, 1, 3, 2.0, 1, 2);   -- 5G0 needs 2x PNA (Mounting Pin)

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine WHERE Id = 3)
    INSERT INTO Parts.BomLine (Id, BomId, ChildItemId, QtyPer, UomId, SortOrder)
    VALUES (3, 2, 2, 1.0, 1, 1);   -- 5G0-MACH (rename) <- 1x 5G0-C (FDS-05-033 single-child rename)

SET IDENTITY_INSERT Parts.BomLine OFF;

-- ============================================================
-- Quality.QualitySpec for Item 1 (5G0)
-- ============================================================

SET IDENTITY_INSERT Quality.QualitySpec ON;

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpec WHERE Id = 1)
    INSERT INTO Quality.QualitySpec (Id, Name, ItemId, OperationTemplateId, Description, CreatedAt)
    VALUES (1, N'5G0 Dimensional Spec', 1, NULL, N'Dimensional tolerances for the 5G0 front cover assembly.', @Now);

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpec WHERE Id = 2)
    INSERT INTO Quality.QualitySpec (Id, Name, ItemId, OperationTemplateId, Description, CreatedAt)
    VALUES (2, N'5G0 Visual Inspection', 1, NULL, N'Visual inspection criteria for the 5G0 front cover.', @Now);

SET IDENTITY_INSERT Quality.QualitySpec OFF;

-- ============================================================
-- Quality.QualitySpecVersion (one published version each)
-- ============================================================

SET IDENTITY_INSERT Quality.QualitySpecVersion ON;

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE Id = 1)
    INSERT INTO Quality.QualitySpecVersion (Id, QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (1, 1, 2, '2026-01-15', '2026-01-14', NULL, 2, @Now);

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE Id = 2)
    INSERT INTO Quality.QualitySpecVersion (Id, QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (2, 2, 1, '2026-01-15', '2026-01-14', NULL, 2, @Now);

SET IDENTITY_INSERT Quality.QualitySpecVersion OFF;

-- ============================================================
-- Parts.OperationTemplateField -- data-collection fields per OT
--   Fully configures the 4 OperationTemplates the 5G0 route uses, so the
--   Routes tab steps map onto real data-collection field sets.
--   DataCollectionField: 1=MaterialVerification 2=SerialNumber 3=DieInfo
--     4=CavityInfo 5=Weight 6=GoodCount 7=BadCount
-- ============================================================

SET IDENTITY_INSERT Parts.OperationTemplateField ON;

-- OT 1 (DC-5G0, Die Cast): DieInfo, CavityInfo, Weight, GoodCount, BadCount
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 1)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (1, 1, 3, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 2)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (2, 1, 4, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 3)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (3, 1, 5, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 4)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (4, 1, 6, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 5)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (5, 1, 7, 1, @Now);

-- OT 2 (TRIM-5G0, Trim): Weight, GoodCount, BadCount
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 6)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (6, 2, 5, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 7)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (7, 2, 6, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 8)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (8, 2, 7, 1, @Now);

-- OT 3 (CNC-5G0, CNC): GoodCount, BadCount
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 9)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (9, 3, 6, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 10)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (10, 3, 7, 1, @Now);

-- OT 4 (ASSY-FRONT, Assembly): SerialNumber, MaterialVerification, GoodCount, BadCount
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 11)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (11, 4, 2, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 12)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (12, 4, 1, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 13)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (13, 4, 6, 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField WHERE Id = 14)
    INSERT INTO Parts.OperationTemplateField (Id, OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt) VALUES (14, 4, 7, 1, @Now);

SET IDENTITY_INSERT Parts.OperationTemplateField OFF;

-- ============================================================
-- Quality.QualitySpecAttribute -- measurement attributes for 5G0's specs
--   Version 1 (Id=1) = Dimensional (Numeric attrs w/ UOM + target/limits)
--   Version 2 (Id=2) = Visual (Text / Boolean attrs, no numeric limits)
--   Uom: 3=KG 4=IN 5=MM   DataType: Numeric / Text / Boolean
-- ============================================================

SET IDENTITY_INSERT Quality.QualitySpecAttribute ON;

-- Spec version 1: Dimensional
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE Id = 1)
    INSERT INTO Quality.QualitySpecAttribute (Id, QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    VALUES (1, 1, N'Overall Length', N'Numeric', 5, 120.0, 119.5, 120.5, 1, 1);
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE Id = 2)
    INSERT INTO Quality.QualitySpecAttribute (Id, QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    VALUES (2, 1, N'Bore Diameter', N'Numeric', 5, 25.0, 24.9, 25.1, 1, 2);
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE Id = 3)
    INSERT INTO Quality.QualitySpecAttribute (Id, QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    VALUES (3, 1, N'Flatness', N'Numeric', 5, 0.0, 0.0, 0.05, 0, 3);
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE Id = 4)
    INSERT INTO Quality.QualitySpecAttribute (Id, QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    VALUES (4, 1, N'Net Weight', N'Numeric', 3, 3.25, 3.10, 3.40, 1, 4);

-- Spec version 2: Visual
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE Id = 5)
    INSERT INTO Quality.QualitySpecAttribute (Id, QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    VALUES (5, 2, N'Surface Finish', N'Text', NULL, NULL, NULL, NULL, 1, 1);
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE Id = 6)
    INSERT INTO Quality.QualitySpecAttribute (Id, QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    VALUES (6, 2, N'Visible Porosity', N'Boolean', NULL, NULL, NULL, NULL, 1, 2);
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE Id = 7)
    INSERT INTO Quality.QualitySpecAttribute (Id, QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    VALUES (7, 2, N'Label Legible', N'Boolean', NULL, NULL, NULL, NULL, 1, 3);

SET IDENTITY_INSERT Quality.QualitySpecAttribute OFF;

-- ============================================================
-- Parts.ItemLocation -- eligibility for Item 1 (5G0)
--   Locations resolved by Code from 011_seed_locations_mpp_plant.sql so the
--   Eligibility tab shows real plant cells. Codes that resolve to no row are
--   skipped (SELECT yields zero rows). The consumption-point row carries
--   Min/Max/Default qty metadata; production rows leave it NULL.
-- ============================================================

SET IDENTITY_INSERT Parts.ItemLocation ON;

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE Id = 1)
    INSERT INTO Parts.ItemLocation (Id, ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT 1, 1, Id, 0, NULL, NULL, NULL, @Now FROM Location.Location WHERE Code = N'DC1-M05';
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE Id = 2)
    INSERT INTO Parts.ItemLocation (Id, ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT 2, 1, Id, 0, NULL, NULL, NULL, @Now FROM Location.Location WHERE Code = N'DC1-M06';
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE Id = 3)
    INSERT INTO Parts.ItemLocation (Id, ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT 3, 1, Id, 0, NULL, NULL, NULL, @Now FROM Location.Location WHERE Code = N'DC1-M07';
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE Id = 4)
    INSERT INTO Parts.ItemLocation (Id, ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT 4, 1, Id, 1, 10, 500, 100, @Now FROM Location.Location WHERE Code = N'DC1-M08';

-- Ancestor-tier (Area) eligibility: 5G0 eligible across all of the DC1 Area.
-- FDS-03-014 hierarchy-cascade example -- engineering configures at the coarsest
-- appropriate tier (one Area row) and a Cell-level resolution surfaces it. Required
-- fixture for 0009_Parts_Process/060_Eligibility_hierarchy_cascade.sql.
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE Id = 5)
    INSERT INTO Parts.ItemLocation (Id, ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT 5, 1, Id, 0, NULL, NULL, NULL, @Now FROM Location.Location WHERE Code = N'DC1';

SET IDENTITY_INSERT Parts.ItemLocation OFF;

PRINT 'seed_items: 5 items, 5 container configs, 2 routes (5 steps), 1 BOM (2 lines), 2 quality specs loaded.';
PRINT 'seed_items: Item 1 (5G0) fully configured -- 14 OperationTemplateFields, 7 QualitySpecAttributes, 5 eligibility locations (4 cells + DC1 area).';
GO
