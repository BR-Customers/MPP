-- =============================================
-- File:         0011_Quality_Spec/050_QualitySpecVersion_SaveDraft.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-29
-- Description:
--   Tests for Quality.QualitySpecVersion_SaveDraft (bundled attribute
--   reconciliation for a Draft version).
--
--   Covers:
--     - Insert path: SaveDraft with 2 new attrs (Id NULL) -> Status 1,
--       2 attributes, first attr SortOrder=1 with UomId set.
--     - Reconcile path: keep one by Id, drop one, add one -> still
--       2 attributes, the dropped attr is gone.
--     - Audit: latest Audit.ConfigLog Description for the version
--       contains "Quality Spec" and "Saved".
--
--   Pre-conditions:
--     - Migrations applied; Location.AppUser populated.
--     - An active Parts.Item and a Parts.Uom exist.
--     - Quality.QualitySpec_Create, Quality.QualitySpecVersion_Create,
--       Quality.QualitySpecVersion_SaveDraft deployed.
-- =============================================

EXEC test.BeginTestFile @FileName = N'0011_Quality_Spec/050_QualitySpecVersion_SaveDraft.sql';
GO

-- =============================================
-- Setup: spec + v1 draft
-- =============================================
DECLARE @User BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @Item BIGINT = (SELECT TOP 1 Id FROM Parts.Item WHERE DeprecatedAt IS NULL ORDER BY Id);

DECLARE @SpecRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @SpecRes EXEC Quality.QualitySpec_Create
    @Name      = N'Draft Reconcile Test Spec',
    @ItemId    = @Item,
    @AppUserId = @User;
DECLARE @SpecId BIGINT = (SELECT NewId FROM @SpecRes);

DECLARE @VerRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @VerRes EXEC Quality.QualitySpecVersion_Create
    @QualitySpecId = @SpecId,
    @EffectiveFrom = NULL,
    @AppUserId     = @User;
DECLARE @VerId BIGINT = (SELECT NewId FROM @VerRes);

-- Stash ids for later batches in a temp marker table
IF OBJECT_ID('tempdb..#Ctx') IS NOT NULL DROP TABLE #Ctx;
CREATE TABLE #Ctx (VerId BIGINT, UserId BIGINT, Ea BIGINT);
INSERT INTO #Ctx (VerId, UserId, Ea)
VALUES (@VerId, @User, (SELECT TOP 1 Id FROM Parts.Uom ORDER BY Id));
GO

-- =============================================
-- Test 1: SaveDraft with 2 new attributes (Id NULL = INSERT)
-- =============================================
DECLARE @VerId BIGINT = (SELECT VerId FROM #Ctx);
DECLARE @User  BIGINT = (SELECT UserId FROM #Ctx);
DECLARE @Ea    BIGINT = (SELECT Ea FROM #Ctx);

DECLARE @Json NVARCHAR(MAX) = N'[
  {"Id":null,"AttributeName":"Bore Dia","DataType":"Numeric","UomId":' + CAST(@Ea AS NVARCHAR(20)) + ',"TargetValue":25.40,"LowerLimit":25.38,"UpperLimit":25.42,"IsRequired":1},
  {"Id":null,"AttributeName":"Porosity","DataType":"Boolean","UomId":null,"TargetValue":null,"LowerLimit":null,"UpperLimit":null,"IsRequired":1}
]';

DECLARE @SaveRes TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @SaveRes EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId,
    @EffectiveFrom        = NULL,
    @AttributesJson       = @Json,
    @AppUserId            = @User;

DECLARE @S NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @SaveRes);
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftInsert] Status is 1',
    @Expected = N'1',
    @Actual   = @S;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @VerId);
EXEC test.Assert_RowCount
    @TestName     = N'[QSVSaveDraftInsert] 2 attributes after insert',
    @ExpectedCount = 2,
    @ActualCount   = @Cnt;

-- Bore Dia: SortOrder 1 and UomId set as supplied
DECLARE @BoreSort NVARCHAR(10) = (
    SELECT CAST(SortOrder AS NVARCHAR(10))
    FROM Quality.QualitySpecAttribute
    WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Bore Dia');
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftInsert] Bore Dia SortOrder is 1',
    @Expected = N'1',
    @Actual   = @BoreSort;

DECLARE @BoreUom NVARCHAR(20) = (
    SELECT CAST(UomId AS NVARCHAR(20))
    FROM Quality.QualitySpecAttribute
    WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Bore Dia');
DECLARE @EaStr NVARCHAR(20) = CAST(@Ea AS NVARCHAR(20));
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftInsert] Bore Dia UomId matches supplied',
    @Expected = @EaStr,
    @Actual   = @BoreUom;
GO

-- =============================================
-- Test 2: SaveDraft reconcile — keep Bore Dia (by Id), drop Porosity, add Surface
-- =============================================
DECLARE @VerId BIGINT = (SELECT VerId FROM #Ctx);
DECLARE @User  BIGINT = (SELECT UserId FROM #Ctx);
DECLARE @Ea    BIGINT = (SELECT Ea FROM #Ctx);

DECLARE @BoreId BIGINT = (
    SELECT Id FROM Quality.QualitySpecAttribute
    WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Bore Dia');

DECLARE @Json2 NVARCHAR(MAX) = N'[
  {"Id":' + CAST(@BoreId AS NVARCHAR(20)) + ',"AttributeName":"Bore Dia","DataType":"Numeric","UomId":' + CAST(@Ea AS NVARCHAR(20)) + ',"TargetValue":25.40,"LowerLimit":25.38,"UpperLimit":25.42,"IsRequired":1},
  {"Id":null,"AttributeName":"Surface","DataType":"Text","UomId":null,"TargetValue":null,"LowerLimit":null,"UpperLimit":null,"IsRequired":0}
]';

DECLARE @SaveRes2 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @SaveRes2 EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId,
    @EffectiveFrom        = NULL,
    @AttributesJson       = @Json2,
    @AppUserId            = @User;

DECLARE @S2 NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @SaveRes2);
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftReconcile] Status is 1',
    @Expected = N'1',
    @Actual   = @S2;

DECLARE @Cnt2 INT = (SELECT COUNT(*) FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = @VerId);
EXEC test.Assert_RowCount
    @TestName     = N'[QSVSaveDraftReconcile] still 2 attributes after reconcile',
    @ExpectedCount = 2,
    @ActualCount   = @Cnt2;

DECLARE @PorosityGone INT = (
    SELECT COUNT(*) FROM Quality.QualitySpecAttribute
    WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Porosity');
EXEC test.Assert_RowCount
    @TestName     = N'[QSVSaveDraftReconcile] Porosity deleted',
    @ExpectedCount = 0,
    @ActualCount   = @PorosityGone;

DECLARE @SurfaceThere INT = (
    SELECT COUNT(*) FROM Quality.QualitySpecAttribute
    WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Surface');
EXEC test.Assert_RowCount
    @TestName     = N'[QSVSaveDraftReconcile] Surface added',
    @ExpectedCount = 1,
    @ActualCount   = @SurfaceThere;

DECLARE @BoreSurvives INT = (
    SELECT COUNT(*) FROM Quality.QualitySpecAttribute
    WHERE QualitySpecVersionId = @VerId AND AttributeName = N'Bore Dia');
EXEC test.Assert_RowCount
    @TestName     = N'[QSVSaveDraftReconcile] Bore Dia survives reconcile',
    @ExpectedCount = 1,
    @ActualCount   = @BoreSurvives;
GO

-- =============================================
-- Test 3: Audit ConfigLog Description narrative
-- =============================================
DECLARE @VerId BIGINT = (SELECT VerId FROM #Ctx);

DECLARE @Desc NVARCHAR(500) = (
    SELECT TOP 1 cl.Description
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
    WHERE et.Code = N'QualitySpecVersion'
      AND cl.EntityId = @VerId
    ORDER BY cl.Id DESC);

EXEC test.Assert_Contains
    @TestName    = N'[QSVSaveDraftAudit] Description mentions Quality Spec',
    @HaystackStr = @Desc,
    @NeedleStr   = N'Quality Spec';

EXEC test.Assert_Contains
    @TestName    = N'[QSVSaveDraftAudit] Description mentions Saved',
    @HaystackStr = @Desc,
    @NeedleStr   = N'Saved';
GO

-- =============================================
-- Test 4: Within-bounds validation (Lower <= Target <= Upper, Lower <= Upper)
-- =============================================
DECLARE @VerId BIGINT = (SELECT VerId FROM #Ctx);
DECLARE @User  BIGINT = (SELECT UserId FROM #Ctx);

-- 4a: Target above Upper -> rejected
DECLARE @JsonHigh NVARCHAR(MAX) = N'[
  {"Id":null,"AttributeName":"OverTarget","DataType":"Numeric","UomId":null,"TargetValue":99,"LowerLimit":1,"UpperLimit":10,"IsRequired":1}
]';
DECLARE @R4a TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R4a EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId, @EffectiveFrom = NULL, @AttributesJson = @JsonHigh, @AppUserId = @User;
DECLARE @S4a NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R4a);
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftBounds] Target above Upper rejected (Status 0)',
    @Expected = N'0', @Actual = @S4a;

-- 4b: Target below Lower -> rejected
DECLARE @JsonLow NVARCHAR(MAX) = N'[
  {"Id":null,"AttributeName":"UnderTarget","DataType":"Numeric","UomId":null,"TargetValue":0,"LowerLimit":1,"UpperLimit":10,"IsRequired":1}
]';
DECLARE @R4b TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R4b EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId, @EffectiveFrom = NULL, @AttributesJson = @JsonLow, @AppUserId = @User;
DECLARE @S4b NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R4b);
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftBounds] Target below Lower rejected (Status 0)',
    @Expected = N'0', @Actual = @S4b;

-- 4c: Lower > Upper -> rejected
DECLARE @JsonInv NVARCHAR(MAX) = N'[
  {"Id":null,"AttributeName":"Inverted","DataType":"Numeric","UomId":null,"TargetValue":5,"LowerLimit":10,"UpperLimit":1,"IsRequired":1}
]';
DECLARE @R4c TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R4c EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId, @EffectiveFrom = NULL, @AttributesJson = @JsonInv, @AppUserId = @User;
DECLARE @S4c NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R4c);
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftBounds] Lower above Upper rejected (Status 0)',
    @Expected = N'0', @Actual = @S4c;

-- 4d: boundary-inclusive valid (Target == Lower, Target == Upper) -> accepted
DECLARE @JsonOk NVARCHAR(MAX) = N'[
  {"Id":null,"AttributeName":"AtLower","DataType":"Numeric","UomId":null,"TargetValue":5,"LowerLimit":5,"UpperLimit":10,"IsRequired":1},
  {"Id":null,"AttributeName":"AtUpper","DataType":"Numeric","UomId":null,"TargetValue":10,"LowerLimit":5,"UpperLimit":10,"IsRequired":1}
]';
DECLARE @R4d TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R4d EXEC Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId = @VerId, @EffectiveFrom = NULL, @AttributesJson = @JsonOk, @AppUserId = @User;
DECLARE @S4d NVARCHAR(1) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @R4d);
EXEC test.Assert_IsEqual
    @TestName = N'[QSVSaveDraftBounds] boundary-inclusive target accepted (Status 1)',
    @Expected = N'1', @Actual = @S4d;
GO

IF OBJECT_ID('tempdb..#Ctx') IS NOT NULL DROP TABLE #Ctx;
GO

EXEC test.EndTestFile;
GO
