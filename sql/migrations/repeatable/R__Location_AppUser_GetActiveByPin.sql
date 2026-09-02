-- =============================================
-- Procedure:   Location.AppUser_GetActiveByPin
-- Author:      Blue Ridge Automation
-- Created:     2026-09-02
-- Version:     1.0
--
-- Description:
--   Resolves an AppUser by Pin for terminal sign-in — ACTIVE users only
--   (DeprecatedAt IS NULL). This is the presence-eligibility gate for PIN
--   login: an unknown PIN and a deprecated person's PIN must both fail to
--   resolve, so a retired operator can never establish presence or stamp
--   new production.
--
--   Contrast with the sibling Location.AppUser_GetByPin, which
--   INTENTIONALLY returns deprecated rows so the login screen can
--   distinguish "deactivated — see a supervisor" from "unknown PIN —
--   register?". Read-only proc — empty result means the PIN is not
--   eligible for sign-in.
--
--   Direct analogue of Location.AppUser_GetActiveByInitials, which
--   remains in place for attribution lookups by initials.
--
--   @Pin is NVARCHAR, never numeric: full-time employees' codes carry a
--   leading zero (04218) and temps' do not (40218). Any numeric coercion
--   on the way in eats the zero and locks out every full-time employee.
--
-- Parameters:
--   @Pin NVARCHAR(5) - PIN to look up. Required.
--
-- Result set:
--   Zero or one row from Location.AppUser matching the Pin with
--   DeprecatedAt IS NULL.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-09-02 - 1.0 - Initial version (operator PIN sign-in)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetActiveByPin
    @Pin NVARCHAR(5)
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
    WHERE Pin = @Pin
      AND DeprecatedAt IS NULL;
END;
GO
