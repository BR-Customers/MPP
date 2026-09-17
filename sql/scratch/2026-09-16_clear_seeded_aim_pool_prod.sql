-- =============================================================================
-- Clear the dev placeholder AIM shipper IDs (sql/seeds/028_seed_aim_pool_dev.sql)
-- out of a database where they don't belong -- e.g. if that dev seed was ever
-- run against MPP_MES_Prod by mistake.
--
-- SAFE BY CONSTRUCTION: the seed's own range (999000001-999000500) was chosen
-- specifically so it can never collide with a real AIM serial from either
-- company (test company 01 was ~31, production company 99 was ~13.8 million,
-- both far below this floor, per the seed's own comment). This WHERE clause
-- can only ever match that exact placeholder batch -- it cannot accidentally
-- catch a genuinely-fetched real serial no matter how the pool grew since.
--
-- Only touches ConsumedAt IS NULL rows. A CONSUMED placeholder (one that
-- somehow got claimed by a real container) is left alone -- Lots.ShippingLabel
-- stores its own independent copy of AimShipperId (plain NVARCHAR, not an FK
-- to this table), so nothing downstream references this row by Id; there's
-- just no reason to touch anything tied to real history.
--
-- RUN SECTION 1 FIRST. Confirm the count and sample rows look like the seed
-- (all in-range, FetchedAt clustered around one moment, not spread out like
-- real incremental AIM fetches) before running Section 2.
-- =============================================================================

-- ---- 1. PREVIEW -- read-only, run this first ----------------------------------
SELECT COUNT(*) AS ToBeDeleted,
       MIN(FetchedAt) AS OldestFetchedAtUtc, MAX(FetchedAt) AS NewestFetchedAtUtc
FROM Lots.AimShipperIdPool
WHERE ConsumedAt IS NULL
  AND TRY_CAST(AimShipperId AS BIGINT) BETWEEN 999000001 AND 999000500;

SELECT TOP 20 Id, AimShipperId, FetchedAt
FROM Lots.AimShipperIdPool
WHERE ConsumedAt IS NULL
  AND TRY_CAST(AimShipperId AS BIGINT) BETWEEN 999000001 AND 999000500
ORDER BY Id;

-- Anything else unconsumed OUTSIDE the known seed range -- review these
-- separately before deciding what to do with them; this script does not
-- touch them.
SELECT COUNT(*) AS UnconsumedOutsideSeedRange
FROM Lots.AimShipperIdPool
WHERE ConsumedAt IS NULL
  AND NOT (TRY_CAST(AimShipperId AS BIGINT) BETWEEN 999000001 AND 999000500);

-- ---- 2. DELETE -- only after Section 1's preview looks right -------------------
-- DELETE FROM Lots.AimShipperIdPool
-- WHERE ConsumedAt IS NULL
--   AND TRY_CAST(AimShipperId AS BIGINT) BETWEEN 999000001 AND 999000500;
