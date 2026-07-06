-- ============================================================
-- Repeatable:  R__Location_Location_ListMachiningDestinations.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     1.1
-- Description: The Machining destinations the Trim OUT screen offers as 1:1
--              whole-LOT move targets.
--
--              v1.1 (Jacques 2026-07-06, line-resident): destinations are now the
--              PRODUCTION LINES themselves -- WorkCenter-tier (HierarchyLevel 3)
--              Locations that have a 'Machining In%' Cell child -- NOT the
--              Machining-In terminal Cells. Trim checkout moves the LOT to the
--              LINE (Lot.CurrentLocationId = the WorkCenter), which also aligns
--              with Machining IN's queue read: the dedicated Machining-In
--              terminal binds session cell context to its parent LINE
--              (zoneLocationId), so Lot_GetWipQueueByLocation(line) now finds
--              what Trim deposited. (v1.0 deposited at the MIN Cell while the
--              screen read the queue at the line -- a latent mismatch.)
--
--              Same column shape as v1.0 (Id, Code, Name, AreaCode, AreaName);
--              AreaCode/AreaName resolve from the line's parent Area. Printers,
--              terminals, machines are structurally excluded (wrong tier).
--
--              Read proc: NO @Status/@Message, NO OUTPUT params; empty rowset =
--              no machining lines configured (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListMachiningDestinations
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        wc.Id,
        wc.Code,
        wc.Name,
        area.Code AS AreaCode,
        area.Name AS AreaName
    FROM Location.Location wc
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = wc.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    LEFT JOIN Location.Location area ON area.Id = wc.ParentLocationId
    WHERE lt.HierarchyLevel = 3                 -- WorkCenter tier (the production LINE)
      AND wc.DeprecatedAt IS NULL
      -- a machining line is one with a Machining-In receiving Cell child
      AND EXISTS (SELECT 1 FROM Location.Location c
                  WHERE c.ParentLocationId = wc.Id
                    AND c.DeprecatedAt IS NULL
                    AND c.Name LIKE N'Machining In%')
    ORDER BY wc.Code;
END;
GO
