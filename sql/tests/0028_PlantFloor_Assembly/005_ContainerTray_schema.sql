-- =============================================
-- File:         0028_PlantFloor_Assembly/005_ContainerTray_schema.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-06
-- Description:  Schema guard for Spec 2 Task A1 (migration 0034): ContainerTray gains
--               FinishedGoodLotId (BIGINT NULL FK -> Lots.Lot) with a filtered UNIQUE
--               index enforcing the 1:1 tray<->finished-good-LOT link.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/005_ContainerTray_schema.sql';
GO

-- column exists
DECLARE @HasCol BIT = CASE WHEN EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'FinishedGoodLotId') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[TraySchema] ContainerTray.FinishedGoodLotId column exists', @Condition = @HasCol;

-- FK to Lots.Lot exists
DECLARE @HasFk BIT = CASE WHEN EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ContainerTray_FinishedGoodLot') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[TraySchema] FK_ContainerTray_FinishedGoodLot exists', @Condition = @HasFk;

-- filtered UNIQUE index exists (1:1 tray<->LOT)
DECLARE @HasUq BIT = CASE WHEN EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'UQ_ContainerTray_FinishedGoodLot' AND is_unique = 1 AND has_filter = 1) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[TraySchema] UQ_ContainerTray_FinishedGoodLot filtered-unique index exists', @Condition = @HasUq;
GO

EXEC test.EndTestFile;
GO
