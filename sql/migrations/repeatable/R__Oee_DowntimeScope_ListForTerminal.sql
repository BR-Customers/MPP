-- =============================================
-- Procedure:   Oee.DowntimeScope_ListForTerminal
-- Author:      Blue Ridge Automation
-- Created:     2026-09-09
-- Modified:    2026-09-17
-- Version:     2.0
--
-- Description:
--   The downtime "units" an operator standing at @TerminalLocationId may log
--   against, and which one the Downtime Manager should preselect.
--
--   v2.0 (OEE-enabled locations spec, 2026-09-16): one rule, no tier
--   branching -- the OEE-ENABLED locations in the terminal's ZONE subtree,
--   the zone itself included, in tree order. What each terminal sees is now
--   a consequence of the data:
--
--     Shared die cast / trim terminal (Area zone) -> the flagged machines.
--     Dedicated machine terminal (Cell zone)      -> that machine.
--     Unsplit M&A line terminal (WorkCenter zone) -> the line.
--     SPLIT line terminal                         -> the line AND its flagged
--                                                    stations (6MA: Machining,
--                                                    Assembly A, Assembly B).
--     Fallback / unregistered terminal (Site)     -> nothing, deliberately.
--
--   An Area with no flagged equipment now returns NOTHING, where v1.0 returned
--   the Area itself. Both prod trim shops carry active flagged machines
--   (2026-09-17 extract), so this does not arise in prod; an Area cannot be
--   flagged, by design.
--
--   Read proc: one result set, no status row, no OUTPUT params (FDS-11-011).
--
-- Parameters:
--   @TerminalLocationId   BIGINT      - Location.Id of the Terminal. Unknown /
--                                       deprecated / parentless -> empty set.
--   @ActiveCellLocationId BIGINT NULL - the operator's current cell context;
--                                       only influences IsDefault.
--
-- Result set (zero or more rows, in tree order):
--   ScopeLocationId, Code, Name, Kind, IsDefault
--
-- Dependencies:
--   Tables:    Location.Location, Location.LocationTypeDefinition,
--              Location.LocationType
--   Functions: Oee.ufn_OeeAncestors, Oee.ufn_ResolveDowntimeScope
--
-- Change Log:
--   2026-09-09 - 1.0 - Initial version (day-one feedback item 3: die cast
--                      machine dropdown + trim-shop scoping).
--   2026-09-17 - 2.0 - Flag-driven subtree + leaf-only preselection.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeScope_ListForTerminal
    @TerminalLocationId   BIGINT,
    @ActiveCellLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Options TABLE (
        ScopeLocationId      BIGINT        NOT NULL PRIMARY KEY,
        Code                 NVARCHAR(50)  NULL,
        Name                 NVARCHAR(200) NULL,
        Kind                 NVARCHAR(100) NULL,
        SortPath             NVARCHAR(400) NULL,
        HasFlaggedDescendant BIT           NOT NULL DEFAULT 0
    );

    -- ---- the terminal's zone (immediate parent) + that zone's tier ----
    DECLARE @ZoneId   BIGINT,
            @ZoneTier NVARCHAR(50);

    SELECT @ZoneId   = p.Id,
           @ZoneTier = plt.Code
    FROM Location.Location t
    INNER JOIN Location.Location p                  ON p.Id    = t.ParentLocationId
    INNER JOIN Location.LocationTypeDefinition pltd ON pltd.Id = p.LocationTypeDefinitionId
    INNER JOIN Location.LocationType plt            ON plt.Id  = pltd.LocationTypeId
    WHERE t.Id = @TerminalLocationId
      AND t.DeprecatedAt IS NULL
      AND p.DeprecatedAt IS NULL;

    -- Site / Enterprise zones (the fallback terminal) deliberately return
    -- NOTHING: the subtree is the whole plant, and scoping downtime plant-wide
    -- is never what the operator meant. The UI asks them to pick a terminal.
    IF @ZoneId IS NOT NULL AND @ZoneTier IN (N'Area', N'WorkCenter', N'Cell')
    BEGIN
        ;WITH Sub AS (
            SELECT l.Id,
                   CAST(RIGHT(N'0000' + CAST(l.SortOrder AS NVARCHAR(10)), 4) AS NVARCHAR(400)) AS SortPath
            FROM Location.Location l
            WHERE l.Id = @ZoneId
            UNION ALL
            SELECT c.Id,
                   CAST(s.SortPath + N'.' + RIGHT(N'0000' + CAST(c.SortOrder AS NVARCHAR(10)), 4) AS NVARCHAR(400))
            FROM Location.Location c
            INNER JOIN Sub s ON c.ParentLocationId = s.Id
            WHERE c.DeprecatedAt IS NULL
        )
        INSERT INTO @Options (ScopeLocationId, Code, Name, Kind, SortPath)
        SELECT l.Id, l.Code, l.Name, ltd.Name, s.SortPath
        FROM Sub s
        INNER JOIN Location.Location l                 ON l.Id    = s.Id
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id  = l.LocationTypeDefinitionId
        WHERE l.IsOeeEnabled = 1
          AND l.DeprecatedAt IS NULL
        OPTION (MAXRECURSION 8);  -- ISA-95 depth below an Area is <= 4 in any real plant; fail fast on a corrupt parent cycle
    END

    -- ---- which options are roll-ups (something flagged sits under them) ----
    UPDATE o
       SET HasFlaggedDescendant = 1
    FROM @Options o
    WHERE EXISTS (
        SELECT 1
        FROM @Options d
        CROSS APPLY Oee.ufn_OeeAncestors(d.ScopeLocationId) a
        WHERE a.AncestorLocationId = o.ScopeLocationId);

    -- ---- default selection ----
    -- 1. exactly one option -> that one.
    -- 2. the operator's active location, but ONLY when it is a leaf unit.
    --    On a split line the session cell IS the line, and preselecting the
    --    line would turn a side-A jam into a whole-line stop charged to every
    --    station (spec sec 3.4).
    -- 3. otherwise nothing -- the operator chooses.
    DECLARE @ActiveScope BIGINT = Oee.ufn_ResolveDowntimeScope(@ActiveCellLocationId);
    DECLARE @DefaultId   BIGINT = NULL;

    IF (SELECT COUNT(*) FROM @Options) = 1
        SET @DefaultId = (SELECT ScopeLocationId FROM @Options);
    ELSE IF @ActiveScope IS NOT NULL
         AND EXISTS (SELECT 1 FROM @Options
                     WHERE ScopeLocationId = @ActiveScope AND HasFlaggedDescendant = 0)
        SET @DefaultId = @ActiveScope;

    SELECT o.ScopeLocationId,
           o.Code,
           o.Name,
           o.Kind,
           CAST(CASE WHEN o.ScopeLocationId = @DefaultId THEN 1 ELSE 0 END AS BIT) AS IsDefault
    FROM @Options o
    ORDER BY o.SortPath, o.Code;
END;
GO
