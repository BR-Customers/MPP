-- =============================================
-- File:         0009_Parts_Process/050_GoldenThread_mint_patterns.sql
-- Description:  Validates the two legacy golden-thread route/BOM patterns that
--               sql/scratch/seed_jp_validation.sql relies on (design:
--               docs/superpowers/specs/2026-07-08-legacy-master-data-mapping-
--               and-golden-thread-seed-design.md). Self-contained: builds
--               synthetic GTHREAD-% fixtures via the production procs, asserts
--               publish success + role-sequence, then cleans up. Reset-safe.
--
--   Thread A (machining = Advance): Component route DieCast -> MachiningIn ->
--     AssemblyOut  (OriginMint>Advance>ConsumeMint); FinishedGood fan-in BOM;
--     FG unrouted.
--   Thread B (machining = ConsumeMint): Component route DieCast -> MachiningIn ->
--     MachiningOut (OriginMint>Advance>ConsumeMint); SubAssembly route
--     AssemblyOut (single ConsumeMint); FG unrouted.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/050_GoldenThread_mint_patterns.sql';
GO

DECLARE @U    BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom  BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @Eff  DATETIME2(3) = CAST('2026-01-01' AS DATETIME2(3));
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @TSub  BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'SubAssembly');
DECLARE @TFg   BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @TplDC   BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE oty.Code=N'DieCast'      AND ot.DeprecatedAt IS NULL);
DECLARE @TplMIn  BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE oty.Code=N'MachiningIn'  AND ot.DeprecatedAt IS NULL);
DECLARE @TplMOut BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE oty.Code=N'MachiningOut' AND ot.DeprecatedAt IS NULL);
DECLARE @TplAOut BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE oty.Code=N'AssemblyOut'  AND ot.DeprecatedAt IS NULL);

-- ---- clean any prior fixtures ----
DELETE bl FROM Parts.BomLine bl JOIN Parts.Bom b ON b.Id=bl.BomId JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE b  FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE rs FROM Parts.RouteStep rs JOIN Parts.RouteTemplate rt ON rt.Id=rs.RouteTemplateId JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE rt FROM Parts.RouteTemplate rt JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'GTHREAD-%';

-- ---- fixtures: 6 items mirroring both threads ----
INSERT INTO Parts.Item (ItemTypeId, PartNumber, UomId, CreatedByUserId, CreatedAt) VALUES
    (@TComp, N'GTHREAD-HOLD', @Uom, @U, SYSUTCDATETIME()),   -- A: holder casting
    (@TFg,   N'GTHREAD-SET',  @Uom, @U, SYSUTCDATETIME()),   -- A: cam-holder set (fan-in FG)
    (@TComp, N'GTHREAD-CAST', @Uom, @U, SYSUTCDATETIME()),   -- B: fuel-pump casting
    (@TSub,  N'GTHREAD-SA',   @Uom, @U, SYSUTCDATETIME()),   -- B: machined SubAssembly
    (@TFg,   N'GTHREAD-FG',   @Uom, @U, SYSUTCDATETIME()),   -- B: fuel-pump FG
    (@TComp, N'GTHREAD-FAST', @Uom, @U, SYSUTCDATETIME());   -- shared fastener

DECLARE @I_HOLD BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'GTHREAD-HOLD');
DECLARE @I_SET  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'GTHREAD-SET');
DECLARE @I_CAST BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'GTHREAD-CAST');
DECLARE @I_SA   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'GTHREAD-SA');
DECLARE @I_FG   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'GTHREAD-FG');
DECLARE @I_FAST BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'GTHREAD-FAST');

DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rs TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rp TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @bc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @bp TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Rt BIGINT, @Json NVARCHAR(MAX), @st NVARCHAR(10), @seq NVARCHAR(200), @Bom BIGINT, @cnt INT;

-- =========================================================
-- Thread A route: HOLD = DieCast -> MachiningIn -> AssemblyOut
-- =========================================================
DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_HOLD, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U;
SET @Rt=(SELECT NewId FROM @rc);
SET @Json=(SELECT * FROM (
    SELECT 1 AS s, CAST(NULL AS BIGINT) AS Id, @TplDC   AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
    UNION ALL SELECT 2, NULL, @TplMIn,  1, NULL
    UNION ALL SELECT 3, NULL, @TplAOut, 1, NULL) x ORDER BY x.s FOR JSON PATH, INCLUDE_NULL_VALUES);
DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@Rt, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@Json;
DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@Rt, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @rp);
EXEC test.Assert_IsEqual @TestName=N'[Thread A] holder route (DieCast->MachiningIn->AssemblyOut) publishes', @Expected=N'1', @Actual=@st;

SET @seq=(SELECT STRING_AGG(ork.Code, N'>') WITHIN GROUP (ORDER BY rs.SequenceNumber)
    FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id
     JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId
     JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
     JOIN Parts.OperationRoleKind ork ON ork.Id=oty.OperationRoleKindId
    WHERE rt.ItemId=@I_HOLD AND rt.PublishedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName=N'[Thread A] holder role sequence = OriginMint>Advance>ConsumeMint', @Expected=N'OriginMint>Advance>ConsumeMint', @Actual=@seq;

-- =========================================================
-- Thread B route: CAST = DieCast -> MachiningIn -> MachiningOut (machining mint)
-- =========================================================
DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_CAST, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U;
SET @Rt=(SELECT NewId FROM @rc);
SET @Json=(SELECT * FROM (
    SELECT 1 AS s, CAST(NULL AS BIGINT) AS Id, @TplDC   AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
    UNION ALL SELECT 2, NULL, @TplMIn,  1, NULL
    UNION ALL SELECT 3, NULL, @TplMOut, 1, NULL) x ORDER BY x.s FOR JSON PATH, INCLUDE_NULL_VALUES);
DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@Rt, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@Json;
DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@Rt, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @rp);
EXEC test.Assert_IsEqual @TestName=N'[Thread B] casting route (DieCast->MachiningIn->MachiningOut) publishes', @Expected=N'1', @Actual=@st;

SET @seq=(SELECT STRING_AGG(ork.Code, N'>') WITHIN GROUP (ORDER BY rs.SequenceNumber)
    FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id
     JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId
     JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
     JOIN Parts.OperationRoleKind ork ON ork.Id=oty.OperationRoleKindId
    WHERE rt.ItemId=@I_CAST AND rt.PublishedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName=N'[Thread B] casting role sequence = OriginMint>Advance>ConsumeMint', @Expected=N'OriginMint>Advance>ConsumeMint', @Actual=@seq;

-- =========================================================
-- Thread B route: SA = AssemblyOut (single ConsumeMint)
-- =========================================================
DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I_SA, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U;
SET @Rt=(SELECT NewId FROM @rc);
SET @Json=(SELECT CAST(NULL AS BIGINT) AS Id, @TplAOut AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description FOR JSON PATH, INCLUDE_NULL_VALUES);
DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@Rt, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@Json;
DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@Rt, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @rp);
EXEC test.Assert_IsEqual @TestName=N'[Thread B] SubAssembly route (AssemblyOut) publishes', @Expected=N'1', @Actual=@st;

SET @seq=(SELECT STRING_AGG(ork.Code, N'>') WITHIN GROUP (ORDER BY rs.SequenceNumber)
    FROM Parts.RouteTemplate rt JOIN Parts.RouteStep rs ON rs.RouteTemplateId=rt.Id
     JOIN Parts.OperationTemplate ot ON ot.Id=rs.OperationTemplateId
     JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId
     JOIN Parts.OperationRoleKind ork ON ork.Id=oty.OperationRoleKindId
    WHERE rt.ItemId=@I_SA AND rt.PublishedAt IS NOT NULL);
EXEC test.Assert_IsEqual @TestName=N'[Thread B] SubAssembly role sequence = ConsumeMint', @Expected=N'ConsumeMint', @Actual=@seq;

-- =========================================================
-- BOMs: A set (fan-in), B SA, B FG
-- =========================================================
-- A: SET = HOLD x2 + FAST x1  (fan-in ConsumeMint at AssemblyOut)
DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_SET, @AppUserId=@U;
SET @Bom=(SELECT NewId FROM @bc);
INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom, @ChildItemId=@I_HOLD, @QtyPer=2, @UomId=@Uom, @AppUserId=@U;
INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom, @ChildItemId=@I_FAST, @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @bp);
EXEC test.Assert_IsEqual @TestName=N'[Thread A] set fan-in BOM publishes', @Expected=N'1', @Actual=@st;
SET @cnt=(SELECT COUNT(*) FROM Parts.BomLine bl JOIN Parts.Bom b ON b.Id=bl.BomId WHERE b.ParentItemId=@I_SET AND b.PublishedAt IS NOT NULL);
EXEC test.Assert_RowCount @TestName=N'[Thread A] set BOM has 2 lines', @ExpectedCount=2, @ActualCount=@cnt;

-- B: SA = CAST x1
DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_SA, @AppUserId=@U;
SET @Bom=(SELECT NewId FROM @bc);
INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom, @ChildItemId=@I_CAST, @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @bp);
EXEC test.Assert_IsEqual @TestName=N'[Thread B] SubAssembly BOM (SA<-casting) publishes', @Expected=N'1', @Actual=@st;

-- B: FG = SA x1 + FAST x2
DELETE FROM @bc; INSERT INTO @bc EXEC Parts.Bom_Create @ParentItemId=@I_FG, @AppUserId=@U;
SET @Bom=(SELECT NewId FROM @bc);
INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom, @ChildItemId=@I_SA,   @QtyPer=1, @UomId=@Uom, @AppUserId=@U;
INSERT INTO @bc EXEC Parts.BomLine_Add @BomId=@Bom, @ChildItemId=@I_FAST, @QtyPer=2, @UomId=@Uom, @AppUserId=@U;
DELETE FROM @bp; INSERT INTO @bp EXEC Parts.Bom_Publish @Id=@Bom, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @bp);
EXEC test.Assert_IsEqual @TestName=N'[Thread B] FG BOM (FG<-SA+fastener) publishes', @Expected=N'1', @Actual=@st;

-- =========================================================
-- Finished goods are unrouted (born at their consumed part's Assembly-OUT mint)
-- =========================================================
SET @cnt=(SELECT COUNT(*) FROM Parts.RouteTemplate WHERE ItemId IN (@I_SET, @I_FG));
EXEC test.Assert_RowCount @TestName=N'[Both threads] finished goods are unrouted', @ExpectedCount=0, @ActualCount=@cnt;

-- ---- cleanup ----
DELETE bl FROM Parts.BomLine bl JOIN Parts.Bom b ON b.Id=bl.BomId JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE b  FROM Parts.Bom b JOIN Parts.Item i ON i.Id=b.ParentItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE rs FROM Parts.RouteStep rs JOIN Parts.RouteTemplate rt ON rt.Id=rs.RouteTemplateId JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE rt FROM Parts.RouteTemplate rt JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'GTHREAD-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'GTHREAD-%';
GO

EXEC test.EndTestFile;
GO
