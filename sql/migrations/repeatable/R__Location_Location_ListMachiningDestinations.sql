-- ============================================================
-- Repeatable:  R__Location_Location_ListMachiningDestinations.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-19
-- Version:     1.0
-- Description: Arc 2 Phase 4 tail. The Machining-line destinations the Trim OUT
--              screen offers as 1:1 whole-LOT move targets (the FIFO-queue
--              receiving points read by Phase 5 Machining IN).
--
--              Taxonomy note (verified against 011_seed_locations_mpp_plant.sql +
--              0002 LocationTypeDefinition seeds): a Machining LINE is modeled as a
--              WorkCenter-tier (HierarchyLevel 3) 'ProductionLine' Location (e.g.
--              MA1-COMPBR), and its FIFO-queue receiving point is a Cell-tier
--              (HierarchyLevel 4) 'Terminal' child named 'Machining In' (e.g.
--              MA1-COMPBR-MIN). Trim OUT deposits the whole LOT at that Machining-In
--              Cell; Machining IN (Phase 5) reads it from there via
--              Lots.Lot_GetWipQueueByLocation.
--
--              Filter: Cell-tier (HierarchyLevel 4) non-deprecated Locations whose
--              Name starts with 'Machining In' (covers 'Machining In',
--              'Machining In - Side A', 'Machining In 1', ...). This deliberately
--              EXCLUDES label Printers (DefId 16), Assembly/Machining-Out terminals,
--              Die Cast terminals, and machines -- only the Machining-IN FIFO
--              receiving Cells are valid Trim-OUT destinations. Ordered by Code.
--
--              Read proc: NO @Status/@Message, NO OUTPUT params; empty rowset =
--              no machining destinations configured (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListMachiningDestinations
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.Id,
        l.Code,
        l.Name,
        area.Code AS AreaCode,
        area.Name AS AreaName
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    -- WorkCenter parent (the Machining LINE) -> Area grandparent (for the label).
    LEFT JOIN Location.Location wc   ON wc.Id   = l.ParentLocationId
    LEFT JOIN Location.Location area ON area.Id = wc.ParentLocationId
    WHERE lt.HierarchyLevel = 4                 -- Cell tier
      AND l.DeprecatedAt IS NULL
      AND l.Name LIKE N'Machining In%'          -- the Machining-IN FIFO receiving Cells only
    ORDER BY l.Code;
END;
GO
