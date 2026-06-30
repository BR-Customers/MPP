-- ============================================================
-- Repeatable:  R__Quality_Hold_GetOpenByLot.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Returns the open hold for a LOT (Arc 2 Phase 7 read), or empty when
--              none. PlacedAt CAST to ET DATETIME2(3). Read proc, no OUTPUT params.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.Hold_GetOpenByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        he.Id,
        he.LotId,
        he.ContainerId,
        he.HoldTypeCodeId,
        htc.Code AS HoldTypeCode,
        he.Reason,
        he.PlacedByUserId,
        CAST(he.PlacedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS PlacedAt
    FROM Quality.HoldEvent he
    INNER JOIN Quality.HoldTypeCode htc ON htc.Id = he.HoldTypeCodeId
    WHERE he.LotId = @LotId AND he.ReleasedAt IS NULL;
END;
GO
