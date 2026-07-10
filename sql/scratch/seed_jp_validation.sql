-- ============================================================
-- seed_jp_validation.sql (scratch backup, run on demand -- NOT auto-run by Reset-DevDatabase)
-- Jacques's validation fixture -- RE-AUTHORED 2026-07-07 to the terminal-mint
-- model (spec 2026-07-07 §5.5; matches the canonical demo routes in
-- sql/seeds/029_seed_item_routes.sql). Old-model backup:
-- sql/scratch/seed_jp_validation.old-model.sql.
--
--   Items:  5G0-c (Component), 5G0-SA (SubAssembly), 5G0-FG (FinishedGood),
--           '21001 pin' (Component)      [Uom PCS]
--   Op templates: DC-A/T-IN-A/T-Out-A/M-In-A/M-Out-A/A-Out-A
--   Routes (mint = LAST step of the CONSUMED part; produced part is born there):
--     5G0-c  = DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut
--              (MachiningOut consumes the casting -> MINTS 5G0-SA)
--     5G0-SA = AssemblyOut         (born at 5G0-c's MachiningOut; no Assembly-In
--              terminal on this line -> AssemblyOut consumes SA+pins -> MINTS 5G0-FG)
--     5G0-FG = (unrouted -- it is the OUTPUT of Assembly OUT; packaged/shipped)
--   BOMs (drive the consume-mint child->parent derivation):
--     5G0-SA = 5G0-c x1
--     5G0-FG = 5G0-SA x1 + '21001 pin' x6
--   Elig:   5G0-c @DC1/TRIM1/MA1-5GOF ; 5G0-SA,5G0-FG @MA1-5GOF ;
--           '21001 pin' @MA1/MA2
--
-- Idempotent + natural-key resolved (survives identity reseeds). ASCII only.
-- Routes/BOMs built via the production procs (route-legality enforced at Publish).
-- No USE statement: runs against the sqlcmd session -d target.
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

-- 5G0-c (casting): DieCast -> TrimIn -> TrimOut -> MachiningIn -> MachiningOut
--   (MachiningOut is the casting's final step -> mints 5G0-SA by Consumption)
DECLARE @I_C BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @I_C AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_C, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U;
    DECLARE @RC_C BIGINT = (SELECT NewId FROM @rc);
    DECLARE @StepsC NVARCHAR(MAX) = (
        SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
        FROM (VALUES (1,N'DC-A'),(2,N'T-IN-A'),(3,N'T-Out-A'),(4,N'M-In-A'),(5,N'M-Out-A')) v(Seq,Code)
        JOIN Parts.OperationTemplate ot ON ot.Code = v.Code
        ORDER BY v.Seq FOR JSON PATH, INCLUDE_NULL_VALUES);
    DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@RC_C, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@StepsC;
    IF (SELECT Status FROM @rs) <> 1 RAISERROR(N'5G0-c route SaveAll failed.', 16, 1);
    DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@RC_C, @AppUserId=@U;
    IF (SELECT Status FROM @rp) <> 1 RAISERROR(N'5G0-c route Publish failed.', 16, 1);
END

-- 5G0-SA (sub-assembly): AssemblyOut
--   (born at 5G0-c's MachiningOut; AssemblyOut consumes SA+pins -> mints 5G0-FG)
DECLARE @I_SA BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-SA');
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @I_SA AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_SA, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U;
    DECLARE @RC_SA BIGINT = (SELECT NewId FROM @rc);
    DECLARE @StepsSA NVARCHAR(MAX) = (
        SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
        FROM Parts.OperationTemplate ot WHERE ot.Code = N'A-Out-A' FOR JSON PATH, INCLUDE_NULL_VALUES);
    DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@RC_SA, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@StepsSA;
    IF (SELECT Status FROM @rs) <> 1 RAISERROR(N'5G0-SA route SaveAll failed.', 16, 1);
    DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@RC_SA, @AppUserId=@U;
    IF (SELECT Status FROM @rp) <> 1 RAISERROR(N'5G0-SA route Publish failed.', 16, 1);
END

-- 5G0-FG (finished good): NO route -- it is the OUTPUT of Assembly OUT.
GO

-- ---- 4. BOMs via procs (child->parent drives the consume-mint derivation) ----
--   5G0-SA = 5G0-c x1                 (MachiningOut mints the SA from the casting)
--   5G0-FG = 5G0-SA x1 + '21001 pin' x6 (AssemblyOut mints the FG from SA + pins)
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'PCS');
DECLARE @I_C BIGINT   = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-c');
DECLARE @I_SA BIGINT  = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-SA');
DECLARE @I_FG BIGINT  = (SELECT Id FROM Parts.Item WHERE PartNumber = N'5G0-FG');
DECLARE @I_PIN BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'21001 pin');
DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bl TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));

-- 5G0-SA BOM = 5G0-c x1
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_SA AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_SA, @AppUserId=@U;
    DECLARE @Bom_SA BIGINT = (SELECT NewId FROM @bc);
    DELETE FROM @bl; INSERT INTO @bl EXEC Parts.BomLine_Add @BomId=@Bom_SA, @ChildItemId=@I_C, @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
    DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom_SA, @AppUserId=@U;
    IF (SELECT Status FROM @bp) <> 1 RAISERROR(N'5G0-SA BOM publish failed.', 16, 1);
END

-- 5G0-FG BOM = 5G0-SA x1 + '21001 pin' x6
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_FG AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_FG, @AppUserId=@U;
    DECLARE @Bom_FG BIGINT = (SELECT NewId FROM @bc);
    DELETE FROM @bl; INSERT INTO @bl EXEC Parts.BomLine_Add @BomId=@Bom_FG, @ChildItemId=@I_SA,  @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
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

PRINT N'seed_jp_validation: 5G0 family config (terminal-mint model) captured.';
GO

-- ============================================================
-- LEGACY GOLDEN THREADS (added 2026-07-08) -- real MPP master data mapped from
-- the legacy MES extract. Design: docs/superpowers/specs/2026-07-08-legacy-
-- master-data-mapping-and-golden-thread-seed-design.md.
-- Coexists with the synthetic 5G0 fixture above (that stays the minimal smoke
-- fixture). Reuses the DC-A/M-In-A/M-Out-A/A-Out-A op templates created above,
-- and existing 011 plant locations (no new locations).
--
-- Thread A -- 59B Cam-Rocker Holder Set  (machining = ADVANCE; fan-in assembly mint)
--   Line MA2-59B (MIN + AOUT, no Machining Out) -> holders consumed as castings.
--     3 holder castings (Component): DieCast -> MachiningIn(Advance) -> AssemblyOut(mint set)
--     Set FG '1223A-59B -A0002' = 3 holders + dowel x19  (fan-in ConsumeMint at AssemblyOut)
-- Thread B -- 6NA Fuel Pump  (machining = ConsumeMint)
--   Line MA1-FP6NA (MIN -> MOUT -> AFIN, has Machining Out) -> machined SA minted at MOUT.
--     Casting '12270-6NA' (Component): DieCast -> MachiningIn -> MachiningOut(mint SA)
--     Synth SA '12270-6NA-M' (SubAssembly): AssemblyOut(mint FG)   [legacy had no machined PN]
--     FG '12270-6NA -0001' (FinishedGood, unrouted) = SA + stud bolt + dowel x2
-- ASCII only; idempotent by PartNumber/Code; run via the same sqlcmd line above.
-- ============================================================

-- ---- A.1 Items (guarded by PartNumber; Uom EA) ----
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TSub  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TFg   BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
IF @U IS NULL OR @Uom IS NULL RAISERROR(N'Prereq missing: DEV user or EA uom.', 16, 1);

DECLARE @items TABLE (PN NVARCHAR(50), Descr NVARCHAR(500), TypeId BIGINT);
INSERT INTO @items VALUES
    -- Thread A
    (N'12231-59B-0000', N'59B Cam Holder IN #1 Casting',  NULL),
    (N'12232-59B-0000', N'59B Cam Holder IN #2 Casting',  NULL),
    (N'12241-59B-0000', N'59B Cam Holder EX #1 Casting',  NULL),
    (N'1223A-59B -A0002', N'59B Cam-Rocker Holder Set',   NULL),
    (N'90701-5R0-3000', N'Dowel Pin 9x10 (purchased)',    NULL),
    -- Thread B
    (N'12270-6NA',       N'6NA Fuel Pump Base Casting (raw)', NULL),
    (N'12270-6NA-M',     N'6NA Fuel Pump Base Machined (synth SA)', NULL),
    (N'12270-6NA -0001', N'6NA Fuel Pump',                 NULL),
    (N'92900-06014-1B',  N'Stud Bolt 6x14 (purchased)',    NULL),
    (N'94301-08100',     N'Dowel Pin 8x10 (purchased)',    NULL);
-- assign ItemType per part
UPDATE @items SET TypeId = @TFg   WHERE PN IN (N'1223A-59B -A0002', N'12270-6NA -0001');
UPDATE @items SET TypeId = @TSub  WHERE PN = N'12270-6NA-M';
UPDATE @items SET TypeId = @TComp WHERE TypeId IS NULL;

INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId, CreatedAt)
SELECT i.TypeId, i.PN, i.Descr, @Uom, @U, SYSUTCDATETIME()
FROM @items i
WHERE NOT EXISTS (SELECT 1 FROM Parts.Item p WHERE p.PartNumber = i.PN);
GO

-- ---- A.2 Thread A routes: each holder casting DieCast->MachiningIn->AssemblyOut ----
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Eff DATETIME2(3) = CAST('2026-01-01' AS DATETIME2(3));
DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rs TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rp TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @holders TABLE (Seq INT IDENTITY(1,1), PN NVARCHAR(50));
INSERT INTO @holders (PN) VALUES (N'12231-59B-0000'), (N'12232-59B-0000'), (N'12241-59B-0000');

DECLARE @pn NVARCHAR(50), @iid BIGINT, @rcid BIGINT, @steps NVARCHAR(MAX);
DECLARE @i INT = 1, @n INT = (SELECT MAX(Seq) FROM @holders);
WHILE @i <= @n
BEGIN
    SELECT @pn = PN FROM @holders WHERE Seq = @i;
    SET @iid = (SELECT Id FROM Parts.Item WHERE PartNumber = @pn);
    IF @iid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @iid AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
    BEGIN
        DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@iid, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U;
        SET @rcid = (SELECT NewId FROM @rc);
        SET @steps = (
            SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
            FROM (VALUES (1,N'DC-A'),(2,N'M-In-A'),(3,N'A-Out-A')) v(Seq,Code)
            JOIN Parts.OperationTemplate ot ON ot.Code = v.Code
            ORDER BY v.Seq FOR JSON PATH, INCLUDE_NULL_VALUES);
        DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@rcid, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@steps;
        IF (SELECT Status FROM @rs) <> 1 RAISERROR(N'Thread A holder route SaveAll failed (%s).', 16, 1, @pn);
        DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@rcid, @AppUserId=@U;
        IF (SELECT Status FROM @rp) <> 1 RAISERROR(N'Thread A holder route Publish failed (%s).', 16, 1, @pn);
    END
    SET @i += 1;
END
GO

-- ---- A.3 Thread A BOM: set = 3 holders + dowel x19 ----
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @I_SET BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'1223A-59B -A0002');
DECLARE @I_H1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12231-59B-0000');
DECLARE @I_H2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12232-59B-0000');
DECLARE @I_H3 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12241-59B-0000');
DECLARE @I_DWL BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'90701-5R0-3000');
DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
IF @I_SET IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_SET AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_SET, @AppUserId=@U;
    DECLARE @Bom_SET BIGINT = (SELECT NewId FROM @bc);
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_SET, @ChildItemId=@I_H1,  @QtyPer=1,  @UomId=@Uom, @AppUserId=@U;
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_SET, @ChildItemId=@I_H2,  @QtyPer=1,  @UomId=@Uom, @AppUserId=@U;
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_SET, @ChildItemId=@I_H3,  @QtyPer=1,  @UomId=@Uom, @AppUserId=@U;
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_SET, @ChildItemId=@I_DWL, @QtyPer=19, @UomId=@Uom, @AppUserId=@U;
    DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom_SET, @AppUserId=@U;
    IF (SELECT Status FROM @bp) <> 1 RAISERROR(N'Thread A set BOM publish failed.', 16, 1);
END
GO

-- ---- B.2 Thread B routes ----
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Eff DATETIME2(3) = CAST('2026-01-01' AS DATETIME2(3));
DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rs TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rp TABLE (Status BIT, Message NVARCHAR(500));

-- 12270-6NA (casting): DieCast -> MachiningIn -> MachiningOut (mints 12270-6NA-M)
DECLARE @I_CAST BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
IF @I_CAST IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @I_CAST AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_CAST, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U;
    DECLARE @RC_CAST BIGINT = (SELECT NewId FROM @rc);
    DECLARE @StepsB1 NVARCHAR(MAX) = (
        SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
        FROM (VALUES (1,N'DC-A'),(2,N'M-In-A'),(3,N'M-Out-A')) v(Seq,Code)
        JOIN Parts.OperationTemplate ot ON ot.Code = v.Code
        ORDER BY v.Seq FOR JSON PATH, INCLUDE_NULL_VALUES);
    DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@RC_CAST, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@StepsB1;
    IF (SELECT Status FROM @rs) <> 1 RAISERROR(N'Thread B casting route SaveAll failed.', 16, 1);
    DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@RC_CAST, @AppUserId=@U;
    IF (SELECT Status FROM @rp) <> 1 RAISERROR(N'Thread B casting route Publish failed.', 16, 1);
END

-- 12270-6NA-M (machined SA): AssemblyOut (mints 12270-6NA -0001)
DECLARE @I_SA BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
IF @I_SA IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @I_SA AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_SA, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U;
    DECLARE @RC_SA BIGINT = (SELECT NewId FROM @rc);
    DECLARE @StepsB2 NVARCHAR(MAX) = (
        SELECT CAST(NULL AS BIGINT) AS Id, ot.Id AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
        FROM Parts.OperationTemplate ot WHERE ot.Code = N'A-Out-A' FOR JSON PATH, INCLUDE_NULL_VALUES);
    DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@RC_SA, @Name=N'Route v1', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@StepsB2;
    IF (SELECT Status FROM @rs) <> 1 RAISERROR(N'Thread B SA route SaveAll failed.', 16, 1);
    DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@RC_SA, @AppUserId=@U;
    IF (SELECT Status FROM @rp) <> 1 RAISERROR(N'Thread B SA route Publish failed.', 16, 1);
END
-- 12270-6NA -0001 (FG): NO route (born at the SA's AssemblyOut).
GO

-- ---- B.3 Thread B BOMs: SA = casting x1 ; FG = SA x1 + stud bolt x1 + dowel x2 ----
DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @I_CAST BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA');
DECLARE @I_SA   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA-M');
DECLARE @I_FG   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'12270-6NA -0001');
DECLARE @I_BOLT BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'92900-06014-1B');
DECLARE @I_DWL8 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'94301-08100');
DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));

IF @I_SA IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_SA AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_SA, @AppUserId=@U;
    DECLARE @Bom_SA BIGINT = (SELECT NewId FROM @bc);
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_SA, @ChildItemId=@I_CAST, @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
    DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom_SA, @AppUserId=@U;
    IF (SELECT Status FROM @bp) <> 1 RAISERROR(N'Thread B SA BOM publish failed.', 16, 1);
END

IF @I_FG IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @I_FG AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_FG, @AppUserId=@U;
    DECLARE @Bom_FG BIGINT = (SELECT NewId FROM @bc);
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_FG, @ChildItemId=@I_SA,   @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_FG, @ChildItemId=@I_BOLT, @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
    INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom_FG, @ChildItemId=@I_DWL8, @QtyPer=2, @UomId=@Uom, @AppUserId=@U;
    DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom_FG, @AppUserId=@U;
    IF (SELECT Status FROM @bp) <> 1 RAISERROR(N'Thread B FG BOM publish failed.', 16, 1);
END
GO

-- ---- C. Eligibility (ItemLocation), guarded by (Item, Location). Codes resolve
--        against existing 011 plant locations; unresolved codes are skipped. ----
DECLARE @el TABLE (PartNumber NVARCHAR(50), LocCode NVARCHAR(50), IsConsumptionPoint BIT);
INSERT INTO @el VALUES
    -- Thread A: holder castings origin-mint at a die-cast machine, then line-resident at MA2-59B
    (N'12231-59B-0000', N'DC3-M01', 0), (N'12231-59B-0000', N'MA2-59B', 0),
    (N'12232-59B-0000', N'DC3-M01', 0), (N'12232-59B-0000', N'MA2-59B', 0),
    (N'12241-59B-0000', N'DC3-M01', 0), (N'12241-59B-0000', N'MA2-59B', 0),
    (N'1223A-59B -A0002', N'MA2-59B', 0),
    (N'90701-5R0-3000',   N'MA2-59B', 1),   -- dowel consumed at the set assembly
    -- Thread B: 6NA fuel pump on MA1-FP6NA
    (N'12270-6NA',       N'DC2-M01',    0), (N'12270-6NA',      N'MA1-FP6NA', 0),
    (N'12270-6NA-M',     N'MA1-FP6NA',  0),
    (N'12270-6NA -0001', N'MA1-FP6NA',  0),
    (N'92900-06014-1B',  N'MA1-FP6NA',  1),  -- stud bolt consumed at assembly
    (N'94301-08100',     N'MA1-FP6NA',  1);  -- dowel consumed at assembly
INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT i.Id, loc.Id, e.IsConsumptionPoint, SYSUTCDATETIME()
FROM @el e
JOIN Parts.Item i          ON i.PartNumber = e.PartNumber
JOIN Location.Location loc ON loc.Code = e.LocCode
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = i.Id AND il.LocationId = loc.Id);
GO

PRINT N'seed_jp_validation: legacy golden threads (59B set on MA2-59B, 6NA fuel pump on MA1-FP6NA) captured.';
GO
