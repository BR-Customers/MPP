-- =============================================
-- Procedure:   Location.AppUser_GetByInitials
-- Author:      Blue Ridge Automation
-- Created:     2026-04-23
-- Version:     1.0
--
-- Description:
--   Looks up an AppUser by Initials — the primary accountability
--   identifier under the Phase C security model. Used by the plant-
--   floor initials-stamp flow to resolve an event stamp to a
--   Location.AppUser row. Returns zero or one row. Read-only proc —
--   empty result means not found.
--
--   Initials are unique across the full row set (active + deprecated),
--   so this returns deprecated rows as well. Callers that want active-
--   only should filter by DeprecatedAt IS NULL on the result.
--
-- Parameters:
--   @Initials NVARCHAR(10) - Initials to look up. Required.
--
-- Result set:
--   Zero or one row from Location.AppUser matching the Initials.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-04-23 - 1.0 - Initial version (replaces legacy _GetByClockNumber)
--   2026-09-02 - 1.1 - Pin exposed in SELECT (terminal PIN sign-in)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetByInitials
    @Initials NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        Initials,
        DisplayName,
        Pin,
        AdAccount,
        IgnitionRole,
        CreatedAt,
        DeprecatedAt
    FROM Location.AppUser
    WHERE Initials = @Initials;
END;
GO
