-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_GetDepth.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Returns the un-consumed AIM shipper-ID pool depth per part number
--              (Arc 2 Phase 6/7 read; drives the topup loop + supervisor AIM tile +
--              empty-pool diagnostics). @PartNumber NULL => all parts. Read proc: no
--              OUTPUT params, empty set = no available IDs.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_GetDepth
    @PartNumber NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PartNumber, COUNT(*) AS Depth
    FROM Lots.AimShipperIdPool
    WHERE ConsumedAt IS NULL
      AND (@PartNumber IS NULL OR PartNumber = @PartNumber)
    GROUP BY PartNumber
    ORDER BY PartNumber;
END;
GO
