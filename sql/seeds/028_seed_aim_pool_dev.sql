-- =============================================================
-- Seed 028: DEV AIM Shipper-ID pool placeholder
-- The real pool is filled by the Honda AIM HTTP GetNextNumber topup loop
-- (FDS-07-010), which is NOT available in dev. This seeds a batch of un-consumed
-- dummy shipper IDs so Lots.Container_Complete can claim during dev/smoke.
-- Migration 0049: the pool is part-agnostic (AIM's nextserial.csv accepts no part
-- parameter), so this is a flat global batch, not one set per part.
--
-- HONEST NOTE: these are LOCAL PLACEHOLDERS ONLY. AIM's postserial.csv requires a
-- 9-digit zero-padded numeric serial; these fabricated IDs will NEVER post
-- successfully to AIM even once AimPostTimer is enabled -- they exist only so
-- Lots.Container_Complete has something to claim during offline dev/smoke runs.
--
-- DO NOT simply clear this pool and expect topupTick to fetch real IDs. Real AIM
-- traffic is gated TWICE, deliberately, because a fetched or posted AIM serial can
-- never be handed back:
--   1. Lots.AimPoolConfig.AimPostingEnabled (Migration 0050) -- read by
--      BlueRidge.Lots.AimHttp._config() before EVERY nextSerial()/postSerial() call.
--      Defaults to 0 (off); this seed does NOT set it.
--   2. The AimPoolTopupTimer and AimPostTimer gateway timers -- both ship with
--      "enabled": false in their resource.json.
-- A realistic Dev exercise of the post path requires DELIBERATELY turning ON both
-- AimPostingEnabled (via the AIM Pool Config admin screen) AND the relevant timer(s)
-- first, THEN clearing this pool (TRUNCATE / DELETE Lots.AimShipperIdPool WHERE
-- ConsumedAt IS NULL) so Lots.AimShipperIdPool_Topup / the topupTick loop fetches
-- real IDs from AIM company 01 (MPP's TEST company) instead. Doing this out of order
-- -- e.g. clearing the pool while the gate is still off -- is harmless (the loop
-- simply returns the disabled error and fetches nothing); doing it with the gate ON
-- against the wrong company code is not.
--
-- Range: 999000001-999000500 (9 digits, all-numeric). Chosen to be unreachable by
-- any real AIM counter: company 01 (test) is running near 000000031 as of this
-- writing, and production (company 99) is around 13.8 million -- both are far
-- below the 999,000,000 floor, so this dev range can never collide with a real
-- consumed serial from either company.
-- Idempotent (NOT EXISTS on AimShipperId). ASCII-only. Remove / replace once
-- the AIM interface is live.
-- =============================================================
SET NOCOUNT ON;

;WITH n AS (
    SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects
)
INSERT INTO Lots.AimShipperIdPool (AimShipperId, FetchedAt)
SELECT RIGHT(N'000000000' + CAST(999000000 + n.rn AS NVARCHAR(9)), 9),
       SYSUTCDATETIME()
FROM n
WHERE NOT EXISTS (
        SELECT 1 FROM Lots.AimShipperIdPool p
        WHERE p.AimShipperId = RIGHT(N'000000000' + CAST(999000000 + n.rn AS NVARCHAR(9)), 9));

-- Dev AIM connection settings (Migration 0049). Company 01 is MPP's TEST company.
-- Production runs on company 99 from the legacy MES box - MES traffic must never
-- target 99.
UPDATE Lots.AimPoolConfig
   SET AimBaseUrl     = N'http://172.17.10.86:8080',
       AimCompanyCode = N'01',
       AimPathToken   = N'636652666553236784'
 WHERE Id = 1;
GO

PRINT 'Seed 028 (dev AIM shipper-ID pool placeholder) loaded.';
