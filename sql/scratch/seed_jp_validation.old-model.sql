-- ============================================================
-- seed_jp_validation.sql (scratch backup, run on demand -- NOT auto-run by Reset-DevDatabase)
-- Jacques's validation fixture (spec 2026-07-07 terminal-mint §5.5):
-- a faithful capture of the 5G0 family CONFIG as currently worked with,
-- so a DB rebuild does not lose it. Reproduces exactly what is configured:
--
--   Items:  5G0-c (Component), 5G0-SA (SubAssembly), 5G0-FG (FinishedGood),
--           '21001 pin' (Component)      [Uom PCS]
--   Op templates: DC-A/T-IN-A/T-Out-A/M-In-A/M-Out-A/A-Out-A
--   Routes: 5G0-c  = DieCast -> TrimIn -> TrimOut -> MachiningIn
--           5G0-FG = AssemblyOut
--           5G0-SA = (none)
--   BOM:    5G0-FG = 5G0-c x1 + '21001 pin' x6
--   Elig:   5G0-c @DC1/TRIM1/MA1-5GOF ; 5G0-SA,5G0-FG @MA1-5GOF ;
--           '21001 pin' @MA1/MA2
--
-- Idempotent + natural-key resolved (survives identity reseeds). ASCII only.
-- Routes/BOMs built via the production procs. Data-collection FIELDS on the
-- templates are not reproduced (orthogonal to this fixture). No USE statement:
-- runs against the sqlcmd session -d target. Distinct from seed_demo.sql.
--   sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_jp_validation.sql
-- ============================================================
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON;
GO

DECLARE @U    BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom  BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'PCS');
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TSub  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TFg   BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
IF @U IS NULL OR @Uom IS NULL RAISERROR(N'Prereq missing: DEV user or PCS uom.', 16, 1);

-- ---- 1. Items (guarded by PartNumber) ----
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-c')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId, CreatedAt)
    VALUES (@TComp, N'5G0-c', N'5G0 Front Cover Casting', @Uom, @U, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-SA')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId, CreatedAt)
    VALUES (@TSub, N'5G0-SA', N'5G0 Front Cover Sub-Assembly', @Uom, @U, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'5G0-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId, CreatedAt)
    VALUES (@TFg, N'5G0-FG', N'5G0 Front Cover Finished Good', @Uom, @U, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'21001 pin')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId, CreatedAt)
    VALUES (@TComp, N'21001 pin', N'Pin 21001', @Uom, @U, SYSUTCDATETIME());
GO

-- ---- 2. Operation templates (guarded by Code; OperationType by role Code) ----
DECLARE @mk TABLE (Code NVARCHAR(20), Name NVARCHAR(100), OpType NVARCHAR(20));
INSERT INTO @mk VALUES
    (N'DC-A',    N'Die Cast Standard',     N'DieCast'),
    (N'T-IN-A',  N'Trim IN Standard',      N'TrimIn'),
    (N'T-Out-A', N'Trim OUT Standard',     N'TrimOut'),
    (N'M-In-A',  N'Machining In Standard', N'MachiningIn'),
    (N'M-Out-A', N'Machining Out Standard',N'MachiningOut'),
    (N'A-Out-A', N'Assembly Out Standard', N'AssemblyOut');
INSERT INTO Parts.OperationTemplate (Code, VersionNumber, Name, OperationTypeId, RequiresSubLotSplit, CreatedAt)
SELECT m.Code, 1, m.Name, oty.Id, 0, SYSUTCDATETIME()
FROM @mk m JOIN Parts.OperationType oty ON oty.Code = m.OpType
WHERE NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate ot WHERE ot.Code = m.Code);
GO

-- ---- 3. Routes via procs (Draft -> SaveAll -> Publish), guarded per Item ----
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Eff DATETIME2(3) = CAST('2026-01-01' AS DATETIME2(3));
DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rs TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rp TABLE (Status BIT, Message NVARCHAR(500));

-- 5G0-c: DieCast -> TrimIn -> TrimOut -> MachiningIn
DECLARE @I_C BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @I_C AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_C, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U;
    DECLARE @RC_C BIGINT = (SELECT NewId FROM @rc);
    DECLARE @StepsC NVARCHAR(MAX) = (
        SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
        FROM (VALUES (1,N'DC-A'),(2,N'T-IN-A'),(3,N'T-Out-A'),(4,N'M-In-A')) v(Seq,Code)
        JOIN Parts.OperationTemplate ot ON ot.Code = v.Code
        ORDER BY v.Seq FOR JSON PATH, INCLUDE_NULL_VALUES);
    DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@RC_C, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@StepsC;
    IF (SELECT Status FROM @rs) <> 1 RAISERROR(N'5G0-c route SaveAll failed.', 16, 1);
    DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@RC_C, @AppUserId=@U;
    IF (SELECT Status FROM @rp) <> 1 RAISERROR(N'5G0-c route Publish failed.', 16, 1);
END

-- 5G0-FG: AssemblyOut
DECLARE @I_FG2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-FG');
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @I_FG2 AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_FG2, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U;
    DECLARE @RC_FG BIGINT = (SELECT NewId FROM @rc);
    DECLARE @StepsFG NVARCHAR(MAX) = (
        SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
        FROM Parts.OperationTemplate ot WHERE ot.Code = N'A-Out-A' FOR JSON PATH, INCLUDE_NULL_VALUES);
    DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@RC_FG, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@StepsFG;
    IF (SELECT Status FROM @rs) <> 1 RAISERROR(N'5G0-FG route SaveAll failed.', 16, 1);
    DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@RC_FG, @AppUserId=@U;
    IF (SELECT Status FROM @rp) <> 1 RAISERROR(N'5G0-FG route Publish failed.', 16, 1);
END
-- 5G0-SA: (no route configured)
GO

-- ---- 4. BOM via procs: 5G0-FG = 5G0-c x1 + '21001 pin' x6 ----
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'PCS');
DECLARE @I_C BIGINT  = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @I_FG BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-FG');
DECLARE @I_PIN BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'21001 pin');
DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_FG AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_FG, @AppUserId=@U;
    DECLARE @Bom_FG BIGINT = (SELECT NewId FROM @bc);
    DELETE FROM @bl; INSERT INTO @bl EXEC Parts.BomLine_Add @BomId=@Bom_FG, @ChildItemId=@I_C, @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
    DELETE FROM @bl; INSERT INTO @bl EXEC Parts.BomLine_Add @BomId=@Bom_FG, @ChildItemId=@I_PIN, @QtyPer=6, @UomId=@Uom, @AppUserId=@U;
    DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom_FG, @AppUserId=@U;
    IF (SELECT Status FROM @bp) <> 1 RAISERROR(N'5G0-FG BOM publish failed.', 16, 1);
END
GO

-- ---- 5. Eligibility (ItemLocation), guarded by (Item, Location) ----
DECLARE @el TABLE (PartNumber NVARCHAR(50), LocCode NVARCHAR(50), IsConsumptionPoint BIT);
INSERT INTO @el VALUES
    (N'5G0-c',     N'DC1',      0),
    (N'5G0-c',     N'TRIM1',    0),
    (N'5G0-c',     N'MA1-5GOF', 0),
    (N'5G0-SA',    N'MA1-5GOF', 0),
    (N'5G0-FG',    N'MA1-5GOF', 0),
    (N'21001 pin', N'MA1',      0),
    (N'21001 pin', N'MA2',      0);
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT i.Id, loc.Id, e.IsConsumptionPoint, SYSUTCDATETIME()
FROM @el e
JOIN Parts.Item i          ON i.PartNumber = e.PartNumber
JOIN Location.Location loc ON loc.Code = e.LocCode
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = i.Id AND il.LocationId = loc.Id);
GO

PRINT N'031_seed_jp_validation: 5G0 family config captured.';
GO
