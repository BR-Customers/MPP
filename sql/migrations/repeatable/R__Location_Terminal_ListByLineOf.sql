-- ============================================================
-- Repeatable:  R__Location_Terminal_ListByLineOf.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-20
-- Version:     1.0
-- Description: Backlog - "when an inventory is low, all terminals on the line
--              should get a warning." Resolves every active Terminal Location
--              sharing the same ancestor WorkCenter ("line") as @LocationId
--              (typically the Cell where the low-stock condition was detected).
--
--              Walks UP from @LocationId to its nearest WorkCenter-tier ancestor
--              (Location.ufn_AncestorLocationIds), then walks back DOWN: every
--              Terminal-type Location whose own ancestor chain includes that
--              WorkCenter. A strict ISA-95 tree has exactly one WorkCenter
--              ancestor per Cell, so no depth tie-break is needed.
--
--              Read proc: empty result set = @LocationId has no WorkCenter
--              ancestor (e.g. already above the WorkCenter tier) or the line has
--              no terminals. No OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_ListByLineOf
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @LocationId IS NULL
        RETURN;

    DECLARE @WorkCenterId BIGINT = (
        SELECT TOP 1 l.Id
        FROM Location.ufn_AncestorLocationIds(@LocationId) a
        INNER JOIN Location.Location l ON l.Id = a.LocationId
        INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
        WHERE ltd.LocationTypeId = 4);   -- WorkCenter tier

    IF @WorkCenterId IS NULL
        RETURN;

    SELECT t.Id AS TerminalLocationId, t.Code, t.Name
    FROM Location.Location t
    INNER JOIN Location.LocationTypeDefinition tltd ON tltd.Id = t.LocationTypeDefinitionId
    WHERE tltd.Code = N'Terminal'
      AND t.DeprecatedAt IS NULL
      AND EXISTS (
          SELECT 1 FROM Location.ufn_AncestorLocationIds(t.Id) ta
          WHERE ta.LocationId = @WorkCenterId);
END;
GO
