-- ============================================================
-- Seed:        020_seed_items.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-06 (rewritten -- Continuous Demo Seed Dataset, Task 1)
-- Description: Clean, minimal Honda parts matrix for the Config Tool +
--              Plant Floor demo. Replaces the old ad-hoc 5G0/RPY/6MA-HSG
--              mockup data with a purpose-built 8-item matrix spanning two
--              finished-good chains (6MA cam holder, non-serialized; 5G0
--              front cover, serialized) plus a pass-through bracket.
--              Idempotent (IF NOT EXISTS guards on natural keys -- PartNumber,
--              Code -- never a hardcoded Id, per project convention). ASCII-only.
--
--              Seeds:
--                - AppUser Id 2 (dev user, matches Common.Util
--                  ._currentAppUserId fallback)
--                - 8 Items: 6MA-C, 6MA-M, 6MA, PIN-A, 5G0-C, 5G0-M, 5G0, RD-BRKT
--                - ContainerConfig for the 2 finished goods (6MA, 5G0)
--                - Published Boms: 6MA <- 6MA-M x1 + PIN-A x2;
--                                  5G0 <- 5G0-M x1
--                - 1 QualitySpec (2 numeric attributes) on 6MA
--                - Parts.ItemLocation eligibility resolved by Location.Code
--
--              Item Id=1 note: 6MA-C is inserted FIRST so it lands on Id=1 on
--              a fresh Reset (Parts.Item has no other seed writer -- see
--              011/022/024/026/027/028/030 -- so IDENTITY starts clean).
--              This preserves an existing Arc 2 Phase 4 / Label-Dispatch test
--              fixture contract: 8 test files hard-code "@ItemId = 1" with
--              eligibility expected at DC1-M05 / DC1-M06 / DC1-M07
--              (sql/tests/0024_PlantFloor_Movement_Trim/020,030,040,050,060,070
--              and sql/tests/0025_PlantFloor_Label_Dispatch/010,020). None of
--              those tests assert the PartNumber -- only that Item Id=1 exists
--              and is eligible (Parts.v_EffectiveItemLocation) at those 3
--              die-cast cells. Satisfied below by giving 6MA-C eligibility at
--              DC1-M05/06/07 in addition to its "real" DC1-M01 + trim-cell
--              eligibility from the matrix -- a die-cast casting qualified to
--              run on several presses is realistic for this plant.
--
--              Dependencies:
--                - 011_seed_locations_mpp_plant.sql (Location.Location seeded
--                  by Code: DC1-M01/M02/M05/M06/M07, MA1-FPRPY-MIN/MOUT/AFIN,
--                  MA1-5GOF-MIN/MOUT/ASER, TRIM1, SHIPIN, SHIPOUT)
--
--              Route wiring (RouteTemplate/RouteStep) for these items is NOT
--              done in this file -- it lives in 029_seed_item_routes.sql.
--              Reason: RouteStep resolves Parts.OperationTemplate by Code,
--              and those Codes are seeded by 022 (DieCastShot), 024
--              (TrimIn/TrimOut), 026 (MachiningIn/MachiningOut) and 027
--              (AssemblyIn/AssemblyOut) -- all of which sort AFTER 020 in
--              filename order. A RouteStep insert attempted from this file
--              would resolve against zero OperationTemplate rows on a fresh
--              Reset and silently insert nothing. 029 is numbered after all
--              of 020/022/024/026/027 so every OperationTemplate Code it
--              needs already exists.
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
GO

-- ============================================================
-- Parts.Item -- 8-item Honda parts matrix.
--   ItemType (Code, migration 0004): RawMaterial/Component/SubAssembly/
--     FinishedGood/PassThrough
--   Uom (Code, migration 0004): EA/LB/KG/IN/MM
--   6MA-C inserted first -- see Item Id=1 note in the file header.
-- ============================================================

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @DevUserId BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @TypeComponent    BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TypeSubAssembly  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TypeFinishedGood BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @TypePassThrough  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough');
DECLARE @UomEA BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @UomLB BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'LB');

-- 6MA-C: 6MA Cam Holder Casting (Component) -- lands on Id=1, see header note.
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'6MA-C')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypeComponent, N'6MA-C', N'6MA Cam Holder Casting', N'6MA-CST-001', 50, NULL, @UomEA, 1.05, @UomLB, N'US', NULL, @Now, @DevUserId);

-- 6MA-M: 6MA Machined Cam Holder (SubAssembly)
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'6MA-M')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypeSubAssembly, N'6MA-M', N'6MA Machined Cam Holder', N'6MA-MCH-001', 50, NULL, @UomEA, 1.00, @UomLB, N'US', NULL, @Now, @DevUserId);

-- 6MA: 6MA Cam Holder Assembly (FinishedGood, non-serialized)
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'6MA')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypeFinishedGood, N'6MA', N'6MA Cam Holder Assembly', N'6MA-ASM-001', 24, NULL, @UomEA, 1.15, @UomLB, N'US', 500, @Now, @DevUserId);

-- PIN-A: Mounting Pin (purchased Component; 6MA BOM 2nd line)
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'PIN-A')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypeComponent, N'PIN-A', N'Mounting Pin (purchased)', N'PIN-A-002', 100, NULL, @UomEA, 0.05, @UomLB, N'US', NULL, @Now, @DevUserId);

-- 5G0-C: 5G0 Front Cover Casting (Component)
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-C')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypeComponent, N'5G0-C', N'5G0 Front Cover Casting', N'5G0-CST-001', 48, NULL, @UomEA, 2.80, @UomLB, N'US', NULL, @Now, @DevUserId);

-- 5G0-M: 5G0 Machined Front Cover (SubAssembly)
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-M')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypeSubAssembly, N'5G0-M', N'5G0 Machined Front Cover', N'5G0-MCH-001', 24, NULL, @UomEA, 2.90, @UomLB, N'US', NULL, @Now, @DevUserId);

-- 5G0: 5G0 Front Cover Assembly (FinishedGood, serialized)
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypeFinishedGood, N'5G0', N'5G0 Front Cover Assembly', N'5G0-FC-001', 24, NULL, @UomEA, 3.25, @UomLB, N'US', 500, @Now, @DevUserId);

-- RD-BRKT: RD Mounting Bracket (PassThrough)
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'RD-BRKT')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, MacolaPartNumber, DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId, CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
    VALUES (@TypePassThrough, N'RD-BRKT', N'RD Mounting Bracket', N'RD-BRKT-001', NULL, NULL, @UomEA, NULL, NULL, N'JP', NULL, @Now, @DevUserId);
GO

-- ============================================================
-- Parts.ContainerConfig -- one per finished good (6MA, 5G0)
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'6MA' AND cc.DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    SELECT Id, 2, 12, 0, N'RD-6MA', N'HONDA-6MA', N'ByCount', NULL, SYSUTCDATETIME() FROM Parts.Item WHERE PartNumber = N'6MA';

IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig cc INNER JOIN Parts.Item i ON i.Id = cc.ItemId WHERE i.PartNumber = N'5G0' AND cc.DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, DunnageCode, CustomerCode, ClosureMethod, TargetWeight, CreatedAt)
    SELECT Id, 2, 8, 1, N'RD-5G0F', N'HONDA-5G0', N'ByVision', NULL, SYSUTCDATETIME() FROM Parts.Item WHERE PartNumber = N'5G0';
GO

-- ============================================================
-- Parts.Bom + Parts.BomLine (published)
--   6MA <- 6MA-M x1, PIN-A x2
--   5G0 <- 5G0-M x1
-- ============================================================

DECLARE @BomId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'6MA' AND b.VersionNumber = 1)
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'6MA' AND u.Initials = N'DEV';

SET @BomId = (SELECT b.Id FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'6MA' AND b.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl INNER JOIN Parts.Item ci ON ci.Id = bl.ChildItemId WHERE bl.BomId = @BomId AND ci.PartNumber = N'6MA-M')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
    SELECT @BomId, ci.Id, 1.0, u.Id, 1 FROM Parts.Item ci, Parts.Uom u WHERE ci.PartNumber = N'6MA-M' AND u.Code = N'EA';

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl INNER JOIN Parts.Item ci ON ci.Id = bl.ChildItemId WHERE bl.BomId = @BomId AND ci.PartNumber = N'PIN-A')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
    SELECT @BomId, ci.Id, 2.0, u.Id, 2 FROM Parts.Item ci, Parts.Uom u WHERE ci.PartNumber = N'PIN-A' AND u.Code = N'EA';
GO

DECLARE @BomId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'5G0' AND b.VersionNumber = 1)
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT i.Id, 1, '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Parts.Item i, Location.AppUser u WHERE i.PartNumber = N'5G0' AND u.Initials = N'DEV';

SET @BomId = (SELECT b.Id FROM Parts.Bom b INNER JOIN Parts.Item i ON i.Id = b.ParentItemId WHERE i.PartNumber = N'5G0' AND b.VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Parts.BomLine bl INNER JOIN Parts.Item ci ON ci.Id = bl.ChildItemId WHERE bl.BomId = @BomId AND ci.PartNumber = N'5G0-M')
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
    SELECT @BomId, ci.Id, 1.0, u.Id, 1 FROM Parts.Item ci, Parts.Uom u WHERE ci.PartNumber = N'5G0-M' AND u.Code = N'EA';
GO

-- ============================================================
-- Quality.QualitySpec + QualitySpecVersion + QualitySpecAttribute -- 6MA
-- ============================================================

DECLARE @QsId  BIGINT;
DECLARE @QsvId BIGINT;

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpec qs INNER JOIN Parts.Item i ON i.Id = qs.ItemId WHERE i.PartNumber = N'6MA' AND qs.Name = N'6MA Dimensional Spec')
    INSERT INTO Quality.QualitySpec (Name, ItemId, OperationTemplateId, Description, CreatedAt)
    SELECT N'6MA Dimensional Spec', i.Id, NULL, N'Dimensional tolerances for the 6MA cam holder assembly.', SYSUTCDATETIME()
    FROM Parts.Item i WHERE i.PartNumber = N'6MA';

SET @QsId = (SELECT qs.Id FROM Quality.QualitySpec qs INNER JOIN Parts.Item i ON i.Id = qs.ItemId WHERE i.PartNumber = N'6MA' AND qs.Name = N'6MA Dimensional Spec');

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE QualitySpecId = @QsId AND VersionNumber = 1)
    INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    SELECT @QsId, 1, '2026-01-15', '2026-01-14', NULL, u.Id, SYSUTCDATETIME()
    FROM Location.AppUser u WHERE u.Initials = N'DEV';

SET @QsvId = (SELECT Id FROM Quality.QualitySpecVersion WHERE QualitySpecId = @QsId AND VersionNumber = 1);

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @QsvId AND AttributeName = N'Flatness')
    INSERT INTO Quality.QualitySpecAttribute (QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    SELECT @QsvId, N'Flatness', N'Numeric', u.Id, 0.05, 0.0, 0.10, 1, 1 FROM Parts.Uom u WHERE u.Code = N'MM';

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @QsvId AND AttributeName = N'Diameter')
    INSERT INTO Quality.QualitySpecAttribute (QualitySpecVersionId, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
    SELECT @QsvId, N'Diameter', N'Numeric', u.Id, 25.0, 24.9, 25.1, 1, 2 FROM Parts.Uom u WHERE u.Code = N'MM';
GO

-- ============================================================
-- Parts.ItemLocation -- eligibility, resolved by Location.Code.
--   6MA-C carries 4 die-cast cells (DC1-M01 + M05/M06/M07 back-compat, see
--   file header) + 1 trim cell. Codes that resolve to no row are skipped
--   (SELECT yields zero rows -- e.g. if a plant-seed cell code ever changes).
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M01' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M01';

-- Back-compat: Arc 2 Phase 4 / Label-Dispatch tests hard-code Item Id=1
-- eligible at DC1-M05/M06/M07 (see file header note).
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M05' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M05';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M06' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M06';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M07' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA-C' AND l.Code = N'DC1-M07';

-- 6MA-C also eligible at a trim cell (post die-cast trim step).
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA-C' AND l.Code = N'TRIM1' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA-C' AND l.Code = N'TRIM1';

-- 6MA-M eligible at the FPRPY-line machining cells. This line is a full-flow
-- line (MIN -> MOUT -> AFIN), so the primary 6MA thread can machine-in, do the
-- extract-one machining-OUT split, then assemble -- all on one line. (The 6MD
-- line has MIN + AOUT but no MOUT, so it cannot host the machining-out demo.)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA-M' AND l.Code = N'MA1-FPRPY-MIN' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA-M' AND l.Code = N'MA1-FPRPY-MIN';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA-M' AND l.Code = N'MA1-FPRPY-MOUT' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA-M' AND l.Code = N'MA1-FPRPY-MOUT';

-- 6MA + PIN-A eligible at the FPRPY-line assembly cell (AFIN -- the machining-out
-- split routes sublots here, then non-serialized assembly consumes them). PIN-A is
-- also a consumption point there (BOM component staged at the assembly cell).
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'6MA' AND l.Code = N'MA1-FPRPY-AFIN' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'6MA' AND l.Code = N'MA1-FPRPY-AFIN';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'PIN-A' AND l.Code = N'MA1-FPRPY-AFIN' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 1, 20, 1000, 200, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'PIN-A' AND l.Code = N'MA1-FPRPY-AFIN';

-- 5G0-C eligible at its die-cast machine.
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'5G0-C' AND l.Code = N'DC1-M02' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'5G0-C' AND l.Code = N'DC1-M02';

-- 5G0-M eligible at the 5GOF-line machining cells (MIN + MOUT both exist).
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'5G0-M' AND l.Code = N'MA1-5GOF-MIN' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'5G0-M' AND l.Code = N'MA1-5GOF-MIN';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'5G0-M' AND l.Code = N'MA1-5GOF-MOUT' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'5G0-M' AND l.Code = N'MA1-5GOF-MOUT';

-- 5G0 eligible at the 5GOF-line serialized-assembly cell (ASER -- this line's
-- assembly cell is named for serialized output; 5G0 is the serialized FG).
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'5G0' AND l.Code = N'MA1-5GOF-ASER' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'5G0' AND l.Code = N'MA1-5GOF-ASER';

-- 5G0 line-resident eligibility (line-deposit model, 2026-07-06).
-- The 5G0 Front terminals (Machining In / Machining Out / Assembly Serialized)
-- all bind their session cell context to the parent LINE (MA1-5GOF, zoneLocationId),
-- and Trim OUT now deposits the whole LOT at the LINE. Eligibility is checked
-- against the destination's ancestor chain, which walks UP from the line -- it
-- never reaches the child cells -- so the flow needs the 5G0 items eligible at
-- the LINE itself, not only at the MIN/MOUT/ASER cells above. Additive: the
-- cell rows remain for any cell-scoped read.
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'5G0-C' AND l.Code = N'MA1-5GOF' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'5G0-C' AND l.Code = N'MA1-5GOF';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'5G0-M' AND l.Code = N'MA1-5GOF' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'5G0-M' AND l.Code = N'MA1-5GOF';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'5G0' AND l.Code = N'MA1-5GOF' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'5G0' AND l.Code = N'MA1-5GOF';

-- RD-BRKT (pass-through) eligible at the receiving + shipping docks.
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'RD-BRKT' AND l.Code = N'SHIPIN' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'RD-BRKT' AND l.Code = N'SHIPIN';

IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il INNER JOIN Parts.Item i ON i.Id = il.ItemId INNER JOIN Location.Location l ON l.Id = il.LocationId WHERE i.PartNumber = N'RD-BRKT' AND l.Code = N'SHIPOUT' AND il.DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, MinQuantity, MaxQuantity, DefaultQuantity, CreatedAt)
    SELECT i.Id, l.Id, 0, NULL, NULL, NULL, SYSUTCDATETIME() FROM Parts.Item i, Location.Location l WHERE i.PartNumber = N'RD-BRKT' AND l.Code = N'SHIPOUT';
GO

PRINT 'seed_items: 8 items (6MA-C/6MA-M/6MA/PIN-A/5G0-C/5G0-M/5G0/RD-BRKT), 2 container configs, 2 BOMs (3 lines), 1 quality spec (2 attributes), 17 eligibility rows loaded incl. 5G0-C/5G0-M/5G0 at the MA1-5GOF line (routes seeded separately in 029_seed_item_routes.sql).';
GO
