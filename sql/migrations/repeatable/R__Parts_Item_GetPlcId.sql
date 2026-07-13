-- =============================================
-- Procedure:   Parts.Item_GetPlcId
-- Description: Read an Item's stable PLC/vision recipe integer. The watcher
--   resolves the expected LOT from the assembly-out FIFO queue
--   (Lots.Lot_GetWipQueueByLocation), then reads that LOT's Item PlcId via this
--   proc. Read proc - empty result = unset / not found.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_GetPlcId
    @ItemId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT PlcId
    FROM Parts.Item
    WHERE Id = @ItemId
      AND DeprecatedAt IS NULL
      AND PlcId IS NOT NULL;
END;
GO
