-- =============================================
-- Procedure:   Location.Terminal_ListDefaultMachines
-- Author:      Blue Ridge Automation
-- Created:     2026-10-23
-- Version:     1.0
--
-- Description:
--   The equipment cells a Terminal shows as buttons by default: the ids in its
--   'DefaultMachines' attribute (migration 0115, comma-separated Location.Id)
--   that are ALSO in Location.Terminal_ListContextCells' set -- active
--   equipment cells under the terminal's parent. The intersection is the
--   point: a stale id (a press deprecated, moved to another room, or typed by
--   hand) is dropped here rather than shown, so the default buttons can never
--   offer a press outside the terminal's own room.
--
--   The descendant walk mirrors Terminal_ListContextCells v1.0 inline rather
--   than INSERT-EXEC it, so this proc stays capturable by INSERT-EXEC itself.
--   Keep the two in step.
--
--   Empty result set when: the terminal is unknown / deprecated / unparented,
--   the attribute is absent or blank, or none of its ids qualify. The caller
--   treats empty as "no defaults configured" and shows every press.
--   Non-numeric list entries are ignored (TRY_CAST).
--
--   No OUTPUT params (Ignition JDBC). One result set.
--
-- Parameters:
--   @TerminalId BIGINT - Location.Id of the Terminal.
--
-- Result set (zero or more rows, ordered by Code):
--   LocationId, Code
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition,
--           Location.LocationType, Location.LocationAttribute,
--           Location.LocationAttributeDefinition
--
-- Change Log:
--   2026-10-23 - 1.0 - Initial version (die cast press buttons).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_ListDefaultMachines
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

    DECLARE @List NVARCHAR(MAX) = (
        SELECT la.AttributeValue
        FROM Location.LocationAttribute la
        INNER JOIN Location.LocationAttributeDefinition lad
            ON lad.Id = la.LocationAttributeDefinitionId
           AND lad.LocationTypeDefinitionId = 7
           AND lad.AttributeName = N'DefaultMachines'
           AND lad.DeprecatedAt IS NULL
        WHERE la.LocationId = @TerminalId
    );

    IF @ParentId IS NULL OR NULLIF(LTRIM(RTRIM(@List)), N'') IS NULL
    BEGIN
        SELECT
            CAST(NULL AS BIGINT)       AS LocationId,
            CAST(NULL AS NVARCHAR(50)) AS Code
        WHERE 1 = 0;
        RETURN;
    END

    ;WITH Descendants AS (
        SELECT l.Id, l.Code, l.LocationTypeDefinitionId
        FROM Location.Location l
        WHERE l.ParentLocationId = @ParentId
          AND l.DeprecatedAt IS NULL
        UNION ALL
        SELECT c.Id, c.Code, c.LocationTypeDefinitionId
        FROM Location.Location c
        INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        WHERE c.DeprecatedAt IS NULL
    ),
    Picked AS (
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(s.value)) AS BIGINT) AS Id
        FROM STRING_SPLIT(@List, N',') s
    )
    SELECT
        d.Id   AS LocationId,
        d.Code AS Code
    FROM Descendants d
    INNER JOIN Picked p
        ON p.Id = d.Id
    INNER JOIN Location.LocationTypeDefinition ltd
        ON ltd.Id = d.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt
        ON lt.Id = ltd.LocationTypeId
    WHERE lt.Code = N'Cell'
      AND ltd.Code NOT IN (N'Terminal', N'Printer')
    ORDER BY d.Code
    OPTION (MAXRECURSION 8);  -- same ceiling as Terminal_ListContextCells
END;
GO
