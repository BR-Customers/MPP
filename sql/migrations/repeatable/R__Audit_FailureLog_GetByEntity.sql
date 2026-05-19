-- =============================================
-- Procedure:   Audit.FailureLog_GetByEntity
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Returns all FailureLog rows for a specific entity type and entity ID,
--   joined to lookup tables and AppUser. Ordered by AttemptedAt DESC.
--   Read-only proc — empty result means no matching rows.
--
-- Parameters:
--   @LogEntityTypeCode NVARCHAR(50) - Entity type code to filter by. Required.
--   @EntityId BIGINT                - Entity ID to filter by. Required.
--
-- Result set:
--   All FailureLog rows matching the entity type and ID, with joined lookup names.
--
-- Dependencies:
--   Tables: Audit.FailureLog, Audit.LogEntityType, Audit.LogEventType,
--           Location.AppUser
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_GetByEntity
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
        fl.Id,
        CAST(fl.AttemptedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS AttemptedAt,
        fl.AppUserId,
        au.DisplayName          AS UserDisplayName,
        fl.LogEntityTypeId,
        lent.Name               AS LogEntityTypeName,
        fl.EntityId,
        fl.LogEventTypeId,
        let.Name                AS LogEventTypeName,
        fl.FailureReason,
        fl.ProcedureName,
        fl.AttemptedParameters
    FROM Audit.FailureLog           fl
    INNER JOIN Location.AppUser     au   ON au.Id   = fl.AppUserId
    INNER JOIN Audit.LogEntityType  lent ON lent.Id = fl.LogEntityTypeId
    INNER JOIN Audit.LogEventType   let  ON let.Id  = fl.LogEventTypeId
    WHERE fl.LogEntityTypeId = @LogEntityTypeId
      AND fl.EntityId = @EntityId
    ORDER BY fl.AttemptedAt DESC;
END;
GO
