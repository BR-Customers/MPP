-- ============================================================
-- Seed:        033_seed_cutover_destinations.sql
-- Description: Location.IsCutoverDestination (column added by migration 0083):
--              WHSE, TRIM1-STORE, TRIM2-STORE -- where the inventory cutover
--              scan may count stock in.
--
--              WHY A SEED AS WELL AS THE MIGRATION. Migration 0083 carries the
--              same UPDATE, and that is what patches the ALREADY-SEEDED live
--              databases. It cannot serve a rebuild-from-scratch: versioned
--              migrations run BEFORE the seed scripts, so on a fresh database
--              0083's UPDATE hits a Location table that 011 has not filled yet
--              and sets nothing. Same split as 0071's DefaultScreen retarget --
--              the seed is the source of truth for new databases, the migration
--              is the patch for existing ones.
--
--              Kept OUT of 011_seed_locations_mpp_plant.sql on purpose: that
--              file is GENERATED from gen_locations_mpp.js, and this flag is
--              not part of the Site-authoritative plant tree.
--
--              Idempotent: re-running re-asserts the exact set (and clears the
--              flag from anything else).
-- ============================================================
SET NOCOUNT ON;

UPDATE Location.Location
   SET IsCutoverDestination = 1
 WHERE Code IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE')
   AND IsCutoverDestination <> 1;

UPDATE Location.Location
   SET IsCutoverDestination = 0
 WHERE Code NOT IN (N'WHSE', N'TRIM1-STORE', N'TRIM2-STORE')
   AND IsCutoverDestination <> 0;
GO

DECLARE @Dests NVARCHAR(500) = (
    SELECT STUFF((SELECT N', ' + Code FROM Location.Location
                  WHERE IsCutoverDestination = 1 AND DeprecatedAt IS NULL
                  ORDER BY Code FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''));
PRINT 'Cutover destinations: ' + ISNULL(@Dests, N'(none)');
GO
