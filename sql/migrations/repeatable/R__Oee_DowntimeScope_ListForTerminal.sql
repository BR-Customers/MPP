-- =============================================
-- Procedure:   Oee.DowntimeScope_ListForTerminal
-- Author:      Blue Ridge Automation
-- Created:     2026-09-09
-- Version:     1.0
--
-- Description:
--   The downtime "units" an operator standing at @TerminalLocationId may log
--   against, and which one the Downtime Manager should preselect. Day-one
--   deployment feedback item 3 (Jacques, 2026-09-09): "at die cast the downtime
--   popup needs a drop down for machine, at trim shop it needs to be scoped to
--   the Trim shop".
--
--   The rule is driven entirely by the terminal's ZONE (its immediate parent
--   Location) -- the same anchor Location.Terminal_GetByIpAddress reports as
--   ZoneLocationId -- so no screen name / process string is consulted:
--
--     Zone tier    Shape                          Rows returned
--     ---------    ---------------------------    -----------------------------
--     WorkCenter   M&A line (MA1-5GOR)            the line itself (1 row)
--     Cell         dedicated machine terminal     that cell (1 row)
--                  (DC1-M01-T1 -> DC1-M01)
--     Area         SHARED terminal serving an     every active EQUIPMENT cell
--                  area (DC1-T1, TRIM1-T1)        beneath the area; if the area
--                                                 has none, the AREA itself
--     Site / other fallback / unregistered        (empty set)
--
--   Consequences of the Area branch, which is the whole point of this proc:
--     * Die cast. DC1 owns 11 Die Cast Machine cells, so the operator gets an
--       11-entry machine dropdown and downtime lands on the PRESS.
--     * Trim. TRIM1 owns no equipment cells at all (only a Terminal and an
--       Inventory Location, both infrastructure), so the single row is the trim
--       shop itself -- "scoped to the Trim shop". If MPP ever models trim
--       presses as Cells, they appear here automatically with no code change.
--     * Fallback terminal. Its zone is the FACILITY; returning the facility
--       would scope downtime plant-wide, so the Site tier deliberately returns
--       NOTHING and the UI makes the operator pick a real terminal first.
--
--   EQUIPMENT cell = a Cell-tier Location whose LocationTypeDefinition is not
--   one of the infrastructure kinds Terminal / Printer / InventoryLocation /
--   Scale. (Terminal + Printer mirrors Location.Terminal_ListContextCells; a
--   storage bin and a bench scale are not things a line "goes down" on.)
--
--   @ActiveCellLocationId is the operator's current location context
--   (session.custom.cell.locationId), passed straight through
--   Oee.ufn_ResolveDowntimeScope. When it resolves to one of the returned
--   rows, THAT row is flagged IsDefault -- so a die cast operator who already
--   picked DC1-M10 on the Die Cast screen opens the popup on DC1-M10. When it
--   does not (or is NULL) a single-row result still defaults to itself; a
--   multi-row result comes back with NO default and the operator must choose,
--   which is the safe outcome -- guessing a press would file downtime against
--   the wrong machine.
--
--   Read proc: one result set, no status row, no OUTPUT params (FDS-11-011).
--   Empty result set = no downtime scope resolvable for this terminal.
--
-- Parameters:
--   @TerminalLocationId   BIGINT      - Location.Id of the Terminal. Unknown /
--                                       deprecated / parentless -> empty set.
--   @ActiveCellLocationId BIGINT NULL - the operator's current cell context;
--                                       only influences IsDefault.
--
-- Result set (zero or more rows, ordered by Code):
--   ScopeLocationId, Code, Name, Kind, IsDefault
--
-- Dependencies:
--   Tables:    Location.Location, Location.LocationTypeDefinition,
--              Location.LocationType
--   Functions: Oee.ufn_ResolveDowntimeScope
--
-- Change Log:
--   2026-09-09 - 1.0 - Initial version (day-one feedback item 3: die cast
--                      machine dropdown + trim-shop scoping).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeScope_ListForTerminal
    @TerminalLocationId   BIGINT,
    @ActiveCellLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Options TABLE (
        ScopeLocationId BIGINT        NOT NULL PRIMARY KEY,
        Code            NVARCHAR(50)  NULL,
        Name            NVARCHAR(200) NULL,
        Kind            NVARCHAR(100) NULL
    );

    -- ---- the terminal's zone (immediate parent) + that zone's tier ----
    DECLARE @ZoneId   BIGINT,
            @ZoneTier NVARCHAR(50);

    SELECT @ZoneId   = p.Id,
           @ZoneTier = plt.Code
    FROM Location.Location t
    INNER JOIN Location.Location p                    ON p.Id   = t.ParentLocationId
    INNER JOIN Location.LocationTypeDefinition pltd   ON pltd.Id = p.LocationTypeDefinitionId
    INNER JOIN Location.LocationType plt              ON plt.Id  = pltd.LocationTypeId
    WHERE t.Id = @TerminalLocationId
      AND t.DeprecatedAt IS NULL
      AND p.DeprecatedAt IS NULL;

    IF @ZoneId IS NOT NULL AND @ZoneTier = N'Area'
    BEGIN
        -- Shared terminal serving a whole area: the equipment cells beneath it.
        ;WITH Descendants AS (
            SELECT l.Id, l.Code, l.Name, l.LocationTypeDefinitionId
            FROM Location.Location l
            WHERE l.ParentLocationId = @ZoneId
              AND l.DeprecatedAt IS NULL
            UNION ALL
            SELECT c.Id, c.Code, c.Name, c.LocationTypeDefinitionId
            FROM Location.Location c
            INNER JOIN Descendants d ON c.ParentLocationId = d.Id
            WHERE c.DeprecatedAt IS NULL
        )
        INSERT INTO @Options (ScopeLocationId, Code, Name, Kind)
        SELECT d.Id, d.Code, d.Name, ltd.Name
        FROM Descendants d
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = d.LocationTypeDefinitionId
        INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
        WHERE lt.Code = N'Cell'
          AND ltd.Code NOT IN (N'Terminal', N'Printer', N'InventoryLocation', N'Scale')
        OPTION (MAXRECURSION 8);  -- ISA-95 depth below an Area is <= 4 in any real plant; fail fast on a corrupt parent cycle
    END

    -- The area with no equipment cells (Trim), the M&A line, and the dedicated
    -- machine terminal all collapse to "the zone itself is the unit".
    IF @ZoneId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM @Options)
       AND @ZoneTier IN (N'Area', N'WorkCenter', N'Cell')
    BEGIN
        INSERT INTO @Options (ScopeLocationId, Code, Name, Kind)
        SELECT z.Id, z.Code, z.Name, ltd.Name
        FROM Location.Location z
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = z.LocationTypeDefinitionId
        WHERE z.Id = @ZoneId;
    END

    -- ---- default selection ----
    DECLARE @ActiveScope BIGINT = Oee.ufn_ResolveDowntimeScope(@ActiveCellLocationId);
    DECLARE @DefaultId   BIGINT = NULL;

    IF @ActiveScope IS NOT NULL
       AND EXISTS (SELECT 1 FROM @Options WHERE ScopeLocationId = @ActiveScope)
        SET @DefaultId = @ActiveScope;
    ELSE IF (SELECT COUNT(*) FROM @Options) = 1
        SET @DefaultId = (SELECT ScopeLocationId FROM @Options);

    SELECT o.ScopeLocationId,
           o.Code,
           o.Name,
           o.Kind,
           CAST(CASE WHEN o.ScopeLocationId = @DefaultId THEN 1 ELSE 0 END AS BIT) AS IsDefault
    FROM @Options o
    ORDER BY o.Code;
END;
GO
