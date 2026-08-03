-- =============================================================
-- Seed 028: DEV AIM Shipper-ID pool placeholder
-- The real pool is filled by the Honda AIM HTTP GetNextNumber topup loop
-- (FDS-07-010), which is NOT available in dev. This seeds a batch of un-consumed
-- dummy shipper IDs so Lots.Container_Complete can claim during dev/smoke.
-- Migration 0049: the pool is part-agnostic (AIM's nextserial.csv accepts no part
-- parameter), so this is a flat global batch, not one set per part.
-- Idempotent (NOT EXISTS on AimShipperId). ASCII-only. Remove / replace once
-- the AIM interface is live.
-- =============================================================
SET NOCOUNT ON;

;WITH n AS (
    SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects
)
INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt)
SELECT N'DEVAIM-' + RIGHT(N'000000' + CAST(n.rn AS NVARCHAR(6)), 6),
       SYSUTCDATETIME()
FROM n
WHERE NOT EXISTS (
        SELECT 1 FROM Lots.AimShipperIdPool p
        WHERE p.AimShipperId = N'DEVAIM-' + RIGHT(N'000000' + CAST(n.rn AS NVARCHAR(6)), 6));

PRINT 'Seed 028 (dev AIM shipper-ID pool placeholder) loaded.';
