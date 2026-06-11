-- =============================================
-- Procedure:   Location.Terminal_ListContextCells
-- Author:      Blue Ridge Automation
-- Created:     2026-06-10
-- Version:     1.0
--
-- Description:
--   The eligible location-context options for a shared-flavor operator view
--   at the given Terminal (view-policy model; FDS-02-009 v1.4 + spec
--   docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md):
--   the ACTIVE descendant EQUIPMENT cells of the Terminal's parent Location -
--   Cell-tier Locations excluding the Terminal and Printer infrastructure
--   kinds (terminals/printers are themselves Cell-tier but are never a
--   production context). Recursive: equipment cells any depth below the
--   parent qualify.
--
--   NOTE: a deprecated INTERMEDIATE Location prunes its entire subtree -
--   active equipment cells beneath a deprecated container are NOT returned
--   (a deprecated branch is considered decommissioned).
--
--   Empty result set when: the Terminal id is unknown / deprecated / has no
--   parent, or the parent has no active equipment cells beneath it (e.g., a
--   machining line tracked at line resolution - dedicated-flavor views bind
--   the parent itself and never call this proc). Never raises under normal
--   plant hierarchy data; a corrupt parent-cycle or depth > 8 terminates
--   with Msg 530.
--
--   No OUTPUT params (Ignition JDBC). One result set.
--
-- Parameters:
--   @TerminalId BIGINT - Location.Id of the Terminal (DefId resolves kind
--                        Terminal; not validated - unknown id -> empty set).
--
-- Result set (zero or more rows, ordered by Code):
--   LocationId, Code, Name, Kind
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition,
--           Location.LocationType
--
-- Change Log:
--   2026-06-10 - 1.0 - Initial version (view-policy model).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_ListContextCells
    @TerminalId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ParentId BIGINT = (
        SELECT ParentLocationId
        FROM Location.Location
        WHERE Id = @TerminalId
          AND DeprecatedAt IS NULL
    );

    IF @ParentId IS NULL
    BEGIN
        SELECT
            CAST(NULL AS BIGINT)        AS LocationId,
            CAST(NULL AS NVARCHAR(50))  AS Code,
            CAST(NULL AS NVARCHAR(200)) AS Name,
            CAST(NULL AS NVARCHAR(100)) AS Kind
        WHERE 1 = 0;
        RETURN;
    END

    ;WITH Descendants AS (
        SELECT l.Id, l.Code, l.Name, l.LocationTypeDefinitionId
        FROM Location.Location l
        WHERE l.ParentLocationId = @ParentId
          AND l.DeprecatedAt IS NULL
        UNION ALL
        SELECT c.Id, c.Code, c.Name, c.LocationTypeDefinitionId
        FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        WHERE c.DeprecatedAt IS NULL
    )
    SELECT
        d.Id        AS LocationId,
        d.Code      AS Code,
        d.Name      AS Name,
        ltd.Name    AS Kind
    FROM Descendants d
    INNER JOIN Location.LocationTypeDefinition ltd
        ON ltd.Id = d.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt
        ON lt.Id = ltd.LocationTypeId
    WHERE lt.Code = N'Cell'
      AND ltd.Code NOT IN (N'Terminal', N'Printer')
    ORDER BY d.Code
    OPTION (MAXRECURSION 8);  -- ISA-95 depth below the terminal-parent anchor is <= 4 in any real plant; 8 is a generous ceiling
END;
GO
