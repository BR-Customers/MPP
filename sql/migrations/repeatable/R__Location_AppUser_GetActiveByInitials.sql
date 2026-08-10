-- =============================================
-- Procedure:   Location.AppUser_GetActiveByInitials
-- Author:      Blue Ridge Automation
-- Created:     2026-08-07
-- Version:     1.0
--
-- Description:
--   Resolves an AppUser by Initials for PRESENCE sign-in — ACTIVE users
--   only (DeprecatedAt IS NULL). This is the presence-eligibility gate
--   for FAT-USR-090: unknown AND deprecated initials must both fail to
--   resolve at shift-start sign-in and at every per-mutation initials
--   field, so a retired operator can never stamp new production.
--
--   Contrast with the sibling Location.AppUser_GetByInitials, which
--   INTENTIONALLY returns deprecated rows so historical events stamped
--   with a retired operator's initials still resolve (attribution
--   history). Presence callers MUST use this proc; history callers use
--   AppUser_GetByInitials. Read-only proc — empty result means the
--   initials are not eligible (unknown or deprecated).
--
-- Parameters:
--   @Initials NVARCHAR(10) - Initials to look up. Required.
--
-- Result set:
--   Zero or one row from Location.AppUser matching the Initials with
--   DeprecatedAt IS NULL.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-08-07 - 1.0 - Initial version (FAT-USR-090 presence-eligibility gate)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetActiveByInitials
    @Initials NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        Initials,
        DisplayName,
        AdAccount,
        IgnitionRole,
        CreatedAt,
        DeprecatedAt
    FROM Location.AppUser
    WHERE Initials = @Initials
      AND DeprecatedAt IS NULL;
END;
GO
