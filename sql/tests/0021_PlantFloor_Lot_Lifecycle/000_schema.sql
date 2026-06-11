-- =============================================
-- File:         0021_PlantFloor_Lot_Lifecycle/000_schema.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-06-11
-- Description:  Schema-assertion tests for Arc 2 Phase 2 migration 0021.
--               Asserts the 5 new Lots tables exist, the PauseEvent open-pause
--               filtered unique index exists, the 7 operational LogEventType
--               codes are present, and at least one active LabelTemplate seeded.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0021_PlantFloor_Lot_Lifecycle/000_schema.sql';
GO

-- Each new table exists
DECLARE @n INT;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LotGenealogy' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LotGenealogy exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LotAttributeChange' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LotAttributeChange exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LotLabel' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LotLabel exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'PauseEvent' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.PauseEvent exists', @ExpectedCount = 1, @ActualCount = @n;
SET @n = (SELECT COUNT(*) FROM sys.tables WHERE name = N'LabelTemplate' AND SCHEMA_NAME(schema_id) = N'Lots');
EXEC test.Assert_RowCount @TestName = N'[Schema] Lots.LabelTemplate exists', @ExpectedCount = 1, @ActualCount = @n;
GO

-- PauseEvent open-pause filtered unique index exists
DECLARE @ix INT = (SELECT COUNT(*) FROM sys.indexes WHERE name = N'UQ_PauseEvent_OpenLotLocation'
                   AND object_id = OBJECT_ID(N'Lots.PauseEvent'));
EXEC test.Assert_RowCount @TestName = N'[Schema] PauseEvent open-pause unique index', @ExpectedCount = 1, @ActualCount = @ix;
GO

-- New LogEventType codes seeded
DECLARE @ev INT = (SELECT COUNT(*) FROM Audit.LogEventType
                   WHERE Code IN (N'LotUpdated', N'LotSplit', N'LotMerged', N'LotConsumed', N'LotPaused', N'LotResumed', N'LabelPrinted'));
EXEC test.Assert_RowCount @TestName = N'[Schema] 7 new LogEventType codes seeded', @ExpectedCount = 7, @ActualCount = @ev;
GO

-- One active LabelTemplate per active LabelTypeCode (>=1)
DECLARE @lt INT = (SELECT COUNT(*) FROM Lots.LabelTemplate WHERE DeprecatedAt IS NULL);
DECLARE @ltOk BIT = CASE WHEN @lt >= 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] >=1 active LabelTemplate seeded',
    @Condition = @ltOk;
GO
