-- ============================================================
-- Repeatable:  R__Location_Location_GetStockDestination.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: Where inventory scanned for a Line is deposited. Resolves
--              ISNULL(Location.DefaultStockLocationId, Id) and returns the
--              destination with its Code and Name, so the cutover scan header
--              can show the operator where stock is actually landing rather than
--              leaving it implicit.
--
--              NULL DefaultStockLocationId means the line itself, which is how
--              M&A inventory works today -- LOTs are line-resident. The column
--              (migration 0080) exists so warehouse-held stock for a line becomes
--              expressible without reworking the scan surface; nothing else in
--              the cutover flow changes when it is set.
--
--              Read proc: no OUTPUT params, empty result set = unknown or
--              deprecated line (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_GetStockDestination
    @LineLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.Id   AS DestinationLocationId,
           d.Code AS DestinationCode,
           d.Name AS DestinationName
    FROM Location.Location l
    INNER JOIN Location.Location d ON d.Id = ISNULL(l.DefaultStockLocationId, l.Id)
    WHERE l.Id = @LineLocationId
      AND l.DeprecatedAt IS NULL;
END;
GO
