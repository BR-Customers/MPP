-- =============================================
-- File:         0063_Crt_PartScoped/010_schema.sql
-- Author:       Blue Ridge Automation
-- Description:  Schema for part-scoped CRT (design 2026-08-19, section 4).
--               Parts.Item.CrtEnabled and
--               Location.LocationTypeDefinition.IsProductionDestination,
--               plus the production-vs-not seed that D5 depends on.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0063_Crt_PartScoped/010_schema.sql';
GO

DECLARE @n INT;

SET @n = CASE WHEN COL_LENGTH('Parts.Item','CrtEnabled') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] Parts.Item.CrtEnabled exists',
    @Expected = N'1', @Actual = @n;

SET @n = CASE WHEN COL_LENGTH('Location.LocationTypeDefinition','IsProductionDestination') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[Schema] LocationTypeDefinition.IsProductionDestination exists',
    @Expected = N'1', @Actual = @n;

SELECT @n = COUNT(*) FROM Parts.Item WHERE CrtEnabled <> 0;
EXEC test.Assert_IsEqual @TestName = N'[Schema] CrtEnabled defaults to 0 for every existing item',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM Location.LocationTypeDefinition
WHERE Code IN (N'DieCastMachine', N'TrimPress', N'CNCMachine', N'AssemblyStation',
               N'SerializedAssemblyLine', N'ProductionLine', N'ProductionArea')
  AND IsProductionDestination = 1;
EXEC test.Assert_IsEqual @TestName = N'[Schema] all 7 production definitions seeded to 1',
    @Expected = N'7', @Actual = @n;

SELECT @n = COUNT(*) FROM Location.LocationTypeDefinition
WHERE Code IN (N'InspectionStation', N'InspectionLine', N'InventoryLocation',
               N'Receiving', N'SupportArea', N'Printer', N'Scale', N'Terminal')
  AND IsProductionDestination = 1;
EXEC test.Assert_IsEqual @TestName = N'[Schema] no non-production definition is flagged',
    @Expected = N'0', @Actual = @n;
GO

EXEC test.EndTestFile;
GO
