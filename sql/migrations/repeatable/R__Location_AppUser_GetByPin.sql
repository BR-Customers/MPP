-- =============================================
-- Procedure:   Location.AppUser_GetByPin
-- Author:      Blue Ridge Automation
-- Created:     2026-09-02
-- Version:     1.0
--
-- Description:
--   Looks up an AppUser by Pin INCLUDING deprecated rows. PINs are unique
--   across the full lifecycle (plain UNIQUE, not filtered on DeprecatedAt),
--   so a retired person's PIN still resolves here. The login screen uses
--   this ONLY to tell a deactivated operator apart from an unknown PIN
--   after the presence gate (Location.AppUser_GetActiveByPin) has already
--   refused; it must never be used to establish presence.
--
--   Direct analogue of Location.AppUser_GetByInitials. Read-only proc —
--   empty result means not found.
--
--   @Pin is NVARCHAR, never numeric: full-time employees' codes carry a
--   leading zero (04218) and temps' do not (40218).
--
-- Parameters:
--   @Pin NVARCHAR(5) - PIN to look up. Required.
--
-- Result set:
--   Zero or one row from Location.AppUser matching the Pin.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-09-02 - 1.0 - Initial version (operator PIN sign-in)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetByPin
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
    WHERE Pin = @Pin;
END;
GO
