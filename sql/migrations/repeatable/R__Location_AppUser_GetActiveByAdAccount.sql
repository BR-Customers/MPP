-- =============================================
-- Procedure:   Location.AppUser_GetActiveByAdAccount
-- Author:      Blue Ridge Automation
-- Created:     2026-09-18
-- Version:     1.0
--
-- Description:
--   Resolves an AppUser by Active Directory account name -- ACTIVE users
--   only (DeprecatedAt IS NULL). This is the attribution gate for an
--   AD-authenticated Perspective session (the Configuration Tool): the
--   signed-in account name (session.props.auth.user.userName) resolves to
--   the AppUser.Id every mutation stamps as @AppUserId. An unknown account
--   and a deprecated person's account must both fail to resolve, so a
--   retired user can never stamp a new change.
--
--   Contrast with the sibling Location.AppUser_GetByAdAccount, which
--   INTENTIONALLY returns deprecated rows (history lookup). Same
--   active/history split as AppUser_GetActiveByPin / AppUser_GetByPin.
--   Read-only proc -- empty result means the account may not attribute.
--
-- Parameters:
--   @AdAccount NVARCHAR(100) - AD account name to look up. Required.
--
-- Result set:
--   Zero or one row from Location.AppUser matching the AdAccount with
--   DeprecatedAt IS NULL.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-09-18 - 1.0 - Initial version (Config Tool AD attribution)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetActiveByAdAccount
    @AdAccount NVARCHAR(100)
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
    WHERE AdAccount = @AdAccount
      AND DeprecatedAt IS NULL;
END;
GO
