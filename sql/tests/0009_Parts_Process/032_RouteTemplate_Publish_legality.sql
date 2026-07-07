-- =============================================
-- File:         0009_Parts_Process/032_RouteTemplate_Publish_legality.sql
-- Description:  Route-legality validation at publish (terminal-mint §4.2 option C):
--               V1 a non-FinishedGood route must end at a ConsumeMint step;
--               V2 at most one ConsumeMint, and it is the last step.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0009_Parts_Process/032_RouteTemplate_Publish_legality.sql';
GO

DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @Uom BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @Eff DATETIME2(3) = CAST('2026-01-01' AS DATETIME2(3));
DECLARE @TplIn BIGINT  = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE oty.Code=N'MachiningIn'  AND ot.DeprecatedAt IS NULL);
DECLARE @TplOut BIGINT = (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot JOIN Parts.OperationType oty ON oty.Id=ot.OperationTypeId WHERE oty.Code=N'MachiningOut' AND ot.DeprecatedAt IS NULL);

-- clean any prior fixtures
DELETE rs FROM Parts.RouteStep rs JOIN Parts.RouteTemplate rt ON rt.Id=rs.RouteTemplateId JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'JPLEG-%';
DELETE rt FROM Parts.RouteTemplate rt JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'JPLEG-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'JPLEG-%';

INSERT INTO Parts.Item (ItemTypeId, PartNumber, UomId, CreatedByUserId, CreatedAt) VALUES
    (@TComp, N'JPLEG-1', @Uom, @U, SYSUTCDATETIME()),
    (@TComp, N'JPLEG-2', @Uom, @U, SYSUTCDATETIME()),
    (@TComp, N'JPLEG-3', @Uom, @U, SYSUTCDATETIME());

DECLARE @rc TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rs TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rp TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @Rt BIGINT, @Json NVARCHAR(MAX), @st NVARCHAR(10);
DECLARE @I1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'JPLEG-1');
DECLARE @I2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'JPLEG-2');
DECLARE @I3 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'JPLEG-3');

-- V1 REJECT: Component route ending in MachiningIn (Advance).
DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I1, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U;
SET @Rt=(SELECT NewId FROM @rc);
SET @Json=(SELECT CAST(NULL AS BIGINT) AS Id, @TplIn AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description FOR JSON PATH, INCLUDE_NULL_VALUES);
DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@Rt, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@Json;
DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@Rt, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @rp);
EXEC test.Assert_IsEqual @TestName=N'[RouteLegality] non-FG ending on Advance rejected', @Expected=N'0', @Actual=@st;

-- V1 ACCEPT: Component route MachiningIn -> MachiningOut (ends ConsumeMint).
DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I2, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U;
SET @Rt=(SELECT NewId FROM @rc);
SET @Json=(SELECT * FROM (
    SELECT 1 AS s, CAST(NULL AS BIGINT) AS Id, @TplIn AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
    UNION ALL SELECT 2, NULL, @TplOut, 1, NULL) x ORDER BY x.s FOR JSON PATH, INCLUDE_NULL_VALUES);
DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@Rt, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@Json;
DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@Rt, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @rp);
EXEC test.Assert_IsEqual @TestName=N'[RouteLegality] non-FG ending on ConsumeMint accepted', @Expected=N'1', @Actual=@st;

-- V2 REJECT: two ConsumeMint steps.
DELETE FROM @rc; INSERT INTO @rc EXEC Parts.RouteTemplate_Create @ItemId=@I3, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U;
SET @Rt=(SELECT NewId FROM @rc);
SET @Json=(SELECT * FROM (
    SELECT 1 AS s, CAST(NULL AS BIGINT) AS Id, @TplOut AS OperationTemplateId, 1 AS IsRequired, CAST(NULL AS NVARCHAR(500)) AS Description
    UNION ALL SELECT 2, NULL, @TplOut, 1, NULL) x ORDER BY x.s FOR JSON PATH, INCLUDE_NULL_VALUES);
DELETE FROM @rs; INSERT INTO @rs EXEC Parts.RouteTemplate_SaveAll @Id=@Rt, @Name=N'r', @EffectiveFrom=@Eff, @AppUserId=@U, @StepsJson=@Json;
DELETE FROM @rp; INSERT INTO @rp EXEC Parts.RouteTemplate_Publish @Id=@Rt, @AppUserId=@U;
SET @st=(SELECT CAST(Status AS NVARCHAR(10)) FROM @rp);
EXEC test.Assert_IsEqual @TestName=N'[RouteLegality] two consume-mint steps rejected', @Expected=N'0', @Actual=@st;

-- cleanup
DELETE rs FROM Parts.RouteStep rs JOIN Parts.RouteTemplate rt ON rt.Id=rs.RouteTemplateId JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'JPLEG-%';
DELETE rt FROM Parts.RouteTemplate rt JOIN Parts.Item i ON i.Id=rt.ItemId WHERE i.PartNumber LIKE N'JPLEG-%';
DELETE FROM Parts.Item WHERE PartNumber LIKE N'JPLEG-%';
GO
