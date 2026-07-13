-- ============================================================
-- clear_demo.sql
-- Companion teardown for seed_demo.sql. Removes ALL LOT/transactional data
-- AND ALL "parts content" (Items, BOMs, eligibility, ContainerConfig, routes,
-- operation templates, quality specs) -- leaving a clean slate.
--
-- KEEPS (matches the seed design's "keep" set):
--   * Location.*            (plant location model)
--   * Tools.*               (tools / dies / cavities / mounts)
--   * all code / reference tables (Parts.ItemType/Uom/OperationType/
--     OperationCategory/DataCollection*, Quality.*Code, Lots.*Type, etc.)
--   * Lots.AimShipperIdPool  (released, not deleted -- it is a pool seed)
--
-- After this runs the DB has 0 LOTs and 0 Items. NOTE: a full
-- Reset-DevDatabase.ps1 RESTORES the parts config (sql/seeds) + threads
-- (seed_demo) -- this only clears the LIVE dev DB. To make the empty state
-- survive a reset, the sql/seeds parts config would have to be gutted too.
--
-- Usage:  sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/clear_demo.sql
-- Idempotent / re-runnable. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
USE MPP_MES_Dev;
GO

PRINT N'Before:';
SELECT (SELECT COUNT(*) FROM Lots.Lot) AS Lots, (SELECT COUNT(*) FROM Parts.Item) AS Items;
GO

BEGIN TRANSACTION;

-- ---- 1. Transactional / LOT content (mirrors seed_demo.sql Step 1 order) ----
DELETE FROM Workorder.ConsumptionEvent;
DELETE FROM Workorder.ProductionEventValue;
DELETE FROM Workorder.ProductionEvent;
DELETE FROM Workorder.RejectEvent;
DELETE FROM Oee.DowntimeEvent;
DELETE FROM Quality.HoldEvent;
DELETE FROM Lots.PauseEvent;

-- Release AIM pool claims BEFORE deleting Containers (FK order).
UPDATE Lots.AimShipperIdPool
SET ConsumedAt = NULL, ConsumedByContainerId = NULL, ConsumedByUserId = NULL
WHERE ConsumedByContainerId IS NOT NULL;

DELETE FROM Lots.ShippingLabel;
DELETE FROM Lots.ContainerSerialHistory;
DELETE FROM Lots.ContainerSerial;
DELETE FROM Lots.ContainerTray;
DELETE FROM Lots.Container;
DELETE FROM Lots.SerializedPart;
DELETE FROM Lots.LotLabel;
DELETE FROM Lots.LotAttributeChange;
DELETE FROM Lots.LotMovement;
DELETE FROM Lots.LotStatusHistory;
DELETE FROM Lots.LotGenealogy;
DELETE FROM Lots.LotGenealogyClosure;
DELETE FROM Lots.LotEventLog;
DELETE FROM Workorder.WorkOrderOperation;
DELETE FROM Workorder.WorkOrder;
DELETE FROM Lots.Lot;

-- ---- 2. Parts content (FK-safe: children before parents; every transactional
--          referencer of Item/OperationTemplate is already gone above) ----
DELETE FROM Quality.QualitySpecAttribute;
DELETE FROM Quality.QualitySpecVersion;
DELETE FROM Quality.QualitySpec;

DELETE FROM Parts.OperationTemplateField;
DELETE FROM Parts.RouteStep;
DELETE FROM Parts.RouteTemplate;
DELETE FROM Parts.BomLine;
DELETE FROM Parts.Bom;
DELETE FROM Parts.ContainerConfig;
DELETE FROM Parts.ItemLocation;
DELETE FROM Parts.OperationTemplate;
DELETE FROM Parts.Item;

COMMIT TRANSACTION;
GO

PRINT N'After:';
SELECT (SELECT COUNT(*) FROM Lots.Lot) AS Lots, (SELECT COUNT(*) FROM Parts.Item) AS Items,
       (SELECT COUNT(*) FROM Parts.Bom) AS Boms, (SELECT COUNT(*) FROM Parts.RouteTemplate) AS Routes,
       (SELECT COUNT(*) FROM Parts.OperationTemplate) AS OpTemplates, (SELECT COUNT(*) FROM Parts.ItemLocation) AS Eligibility,
       (SELECT COUNT(*) FROM Parts.ContainerConfig) AS ContainerConfigs, (SELECT COUNT(*) FROM Quality.QualitySpec) AS QualitySpecs,
       (SELECT COUNT(*) FROM Location.Location) AS LocationsKept, (SELECT COUNT(*) FROM Tools.Tool) AS ToolsKept;
GO
