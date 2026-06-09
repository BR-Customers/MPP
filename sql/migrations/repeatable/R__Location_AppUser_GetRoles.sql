-- =============================================
-- Procedure:   Location.AppUser_GetRoles
-- Author:      Blue Ridge Automation
-- Created:     2026-06-09
-- Version:     1.0
--
-- Description:
--   Returns the Ignition role(s) for a given AppUser, used by Perspective to
--   gate elevated-screen visibility after an elevation succeeds. The AppUser
--   model carries a single IgnitionRole column, so this returns at most one
--   row, one column (IgnitionRole). Returns an EMPTY result set when:
--     - the user does not exist or is deprecated, OR
--     - the user is operator-class (IgnitionRole IS NULL).
--   Read-only proc — empty result means "no role" (not an error). NO authorization
--   is performed here; the UI consumes the role and decides.
--
-- Parameters:
--   @AppUserId BIGINT - PK of the AppUser whose role(s) to return. Required.
--
-- Result set:
--   Zero or one row: IgnitionRole (NVARCHAR(100)).
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-06-09 - 1.0 - Initial version (Arc 2 Phase 1 Task D).
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_GetRoles
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT IgnitionRole
    FROM Location.AppUser
    WHERE Id = @AppUserId
      AND DeprecatedAt IS NULL
      AND IgnitionRole IS NOT NULL;
END;
GO
