-- =============================================
-- Procedure:   Audit.ConfigLog_GetByEntity
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Returns all ConfigLog rows for a specific entity type and entity ID,
--   joined to lookup tables and AppUser. Ordered by LoggedAt DESC.
--   Read-only proc — empty result means no matching rows.
--
-- Parameters:
--   @LogEntityTypeCode NVARCHAR(50) - Entity type code to filter by. Required.
--   @EntityId BIGINT                - Entity ID to filter by. Required.
--
-- Result set:
--   All ConfigLog rows matching the entity type and ID, with joined lookup names.
--
-- Dependencies:
--   Tables: Audit.ConfigLog, Audit.LogEntityType, Audit.LogEventType,
--           Audit.LogSeverity, Location.AppUser
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
-- =============================================
CREATE OR ALTER PROCEDURE Audit.ConfigLog_GetByEntity
    @LogEntityTypeCode  NVARCHAR(50),
    @EntityId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve entity type code
    DECLARE @LogEntityTypeId BIGINT;

    SELECT @LogEntityTypeId = Id
    FROM Audit.LogEntityType
    WHERE Code = @LogEntityTypeCode;

    -- If code is invalid, query returns 0 rows (LogEntityTypeId will be NULL)
    SELECT
        cl.Id,
        CAST(cl.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LoggedAt,
        cl.UserId,
        au.DisplayName          AS UserDisplayName,
        cl.LogSeverityId,
        ls.Code                 AS LogSeverityCode,
        cl.LogEventTypeId,
        let.Name                AS LogEventTypeName,
        cl.LogEntityTypeId,
        lent.Name               AS LogEntityTypeName,
        cl.EntityId,
        cl.Description,
        cl.OldValue,
        cl.NewValue
    FROM Audit.ConfigLog            cl
    LEFT JOIN Location.AppUser      au   ON au.Id   = cl.UserId
    INNER JOIN Audit.LogSeverity    ls   ON ls.Id   = cl.LogSeverityId
    INNER JOIN Audit.LogEventType   let  ON let.Id  = cl.LogEventTypeId
    INNER JOIN Audit.LogEntityType  lent ON lent.Id = cl.LogEntityTypeId
    WHERE cl.LogEntityTypeId = @LogEntityTypeId
      AND cl.EntityId = @EntityId
    ORDER BY cl.LoggedAt DESC;
END;
GO
