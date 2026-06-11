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

-- All 7 Phase 2 LogEventType codes present (3 new in 0021 + 4 pre-existing from 0001)
DECLARE @ev INT = (SELECT COUNT(*) FROM Audit.LogEventType
                   WHERE Code IN (N'LotUpdated', N'LotSplit', N'LotMerged', N'LotConsumed', N'LotPaused', N'LotResumed', N'LabelPrinted'));
EXEC test.Assert_RowCount @TestName = N'[Schema] all 7 Phase 2 LogEventType codes present', @ExpectedCount = 7, @ActualCount = @ev;

-- Exactly the 3 codes newly seeded by 0021
DECLARE @evNew INT = (SELECT COUNT(*) FROM Audit.LogEventType
                      WHERE Code IN (N'LotUpdated', N'LotPaused', N'LotResumed'));
EXEC test.Assert_RowCount @TestName = N'[Schema] 3 new LogEventType codes seeded by 0021', @ExpectedCount = 3, @ActualCount = @evNew;
GO

-- One active LabelTemplate per LabelTypeCode (LabelTypeCode has no DeprecatedAt)
DECLARE @ltExpected INT = (SELECT COUNT(*) FROM Lots.LabelTypeCode);
DECLARE @ltActual INT = (SELECT COUNT(*) FROM Lots.LabelTemplate WHERE DeprecatedAt IS NULL);
EXEC test.Assert_RowCount @TestName = N'[Schema] active LabelTemplate count matches LabelTypeCode count',
    @ExpectedCount = @ltExpected, @ActualCount = @ltActual;
GO
