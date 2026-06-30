-- ============================================================
-- Repeatable:  R__Parts_Item_GetMaxParts.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 4 (spec sec 4.1). Dedicated thin read of the OI-12
--              per-Item lineside cap (Parts.Item.MaxParts, added in migration
--              0013). Returns one row: MaxParts INT NULL (NULL = uncapped). The
--              cap is enforced server-side in Lots.Lot_MoveToValidated; this read
--              shows remaining capacity in the Movement Scan UI. Read proc:
--              no status row, no OUTPUT params.
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.Item_GetMaxParts
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT MaxParts AS MaxParts FROM Parts.Item WHERE Id = @ItemId;
END;
GO
