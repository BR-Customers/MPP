-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_GetDepth.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Returns the un-consumed AIM shipper-ID pool depth (Arc 2 Phase 6/7 read;
--              drives the topup loop + supervisor AIM tile + empty-pool diagnostics).
--              Migration 0049: the pool is part-agnostic (AIM's nextserial.csv accepts
--              no part parameter), so this is now a single global row, not a per-part
--              breakdown. Read proc: no parameters, no OUTPUT params, one row always
--              returned (Depth 0 when the pool is empty). OldestAvailableAt converted
--              to ET at the boundary (FDS-11-011 JDBC datetimeoffset hazard).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_GetDepth
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*) AS Depth,
        CAST(MIN(FetchedAt) AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS OldestAvailableAt
    FROM Lots.AimShipperIdPool
    WHERE ConsumedAt IS NULL;
END;
GO
