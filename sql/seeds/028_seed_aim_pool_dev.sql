-- =============================================================
-- Seed 028: DEV AIM Shipper-ID pool placeholder
-- The real pool is filled by the Honda AIM HTTP GetNextNumber topup loop
-- (FDS-07-010), which is NOT available in dev. This seeds un-consumed dummy
-- shipper IDs per "packable" part number (items with a non-deprecated
-- ContainerConfig) so Lots.Container_Complete can claim during dev/smoke.
-- Idempotent (NOT EXISTS on AimShipperId). ASCII-only. Remove / replace once
-- the AIM interface is live.
-- =============================================================
SET NOCOUNT ON;

;WITH n AS (
    SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects
)
INSERT INTO Lots.AimShipperIdPool (AimShipperId, PartNumber, FetchedAt)
SELECT N'DEVAIM-' + LEFT(i.PartNumber, 35) + N'-' + RIGHT(N'000' + CAST(n.rn AS NVARCHAR(3)), 3),
       i.PartNumber,
       SYSUTCDATETIME()
FROM Parts.Item i
CROSS JOIN n
WHERE EXISTS (SELECT 1 FROM Parts.ContainerConfig cc WHERE cc.ItemId = i.Id AND cc.DeprecatedAt IS NULL)
  AND NOT EXISTS (
        SELECT 1 FROM Lots.AimShipperIdPool p
        WHERE p.AimShipperId = N'DEVAIM-' + LEFT(i.PartNumber, 35) + N'-' + RIGHT(N'000' + CAST(n.rn AS NVARCHAR(3)), 3));

PRINT 'Seed 028 (dev AIM shipper-ID pool placeholder) loaded.';
