-- ============================================================
-- Repeatable:  R__Oee_ufn_ResolveDowntimeScope.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-21
-- Version:     1.0
-- Description: Resolves a cell/terminal location to its downtime "unit" location:
--                - Machining/Assembly: the NEAREST WorkCenter ancestor (the
--                  production line). Downtime is logged against the line; any
--                  terminal/sub-cell on the line acts on the same events.
--                - Die cast: a press is a Cell directly under an Area with NO
--                  WorkCenter ancestor -> returns the press itself.
--              Walk-UP (not immediate-parent): the hierarchy nests cells
--              (e.g. MA1-5GOR-MIN-P1 -> MA1-5GOR-MIN -> MA1-5GOR[WorkCenter]),
--              so we find the closest WorkCenter above the cell. Default
--              MAXRECURSION (100) is ample for the 5-6 tier tree.
--              NULL in -> NULL out (caller handles the fallback-terminal case).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ResolveDowntimeScope (@CellLocationId BIGINT)
RETURNS BIGINT
AS
BEGIN
    IF @CellLocationId IS NULL RETURN NULL;

    DECLARE @Line BIGINT;

    ;WITH Anc AS (
        SELECT l.Id, l.ParentLocationId, l.LocationTypeDefinitionId, 0 AS Lvl
        FROM Location.Location l
        WHERE l.Id = @CellLocationId
        UNION ALL
        SELECT p.Id, p.ParentLocationId, p.LocationTypeDefinitionId, a.Lvl + 1
        FROM Location.Location p
        INNER JOIN Anc a ON p.Id = a.ParentLocationId
    )
    SELECT TOP 1 @Line = a.Id
    FROM Anc a
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = a.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    WHERE lt.Code = N'WorkCenter'
    ORDER BY a.Lvl ASC;   -- nearest WorkCenter ancestor (Lvl 0 = the cell itself)

    RETURN COALESCE(@Line, @CellLocationId);
END
GO
