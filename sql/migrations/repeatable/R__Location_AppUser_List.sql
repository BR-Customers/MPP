-- =============================================
-- Procedure:   Location.AppUser_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Returns all AppUser rows, optionally including deprecated records.
--   Orders results by DisplayName ascending.
--   Read-only proc — empty result means no matching rows.
--
-- Parameters:
--   @IncludeDeprecated BIT = 0       - When 1, includes deprecated users in results.
--   @Filter NVARCHAR(200) = NULL     - When provided, restricts to rows whose
--                                      Initials / DisplayName / AdAccount contain
--                                      the text (case-insensitive LIKE). NULL/'' = no filter.
--
-- Result set:
--   All columns from Location.AppUser matching the filter criteria.
--
-- Dependencies:
--   Tables: Location.AppUser
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.4: dropped ClockNumber + PinHash (legacy auth)
--   2026-04-23 - 2.2 - Initials realignment: Initials exposed in SELECT
--   2026-06-29 - 2.3 - Added @Filter text search (Users management screen)
-- =============================================
CREATE OR ALTER PROCEDURE Location.AppUser_List
    @IncludeDeprecated BIT = 0,
    @Filter            NVARCHAR(200) = NULL
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
    WHERE (@IncludeDeprecated = 1 OR DeprecatedAt IS NULL)
      AND (@Filter IS NULL OR @Filter = ''
           OR Initials    LIKE '%' + @Filter + '%'
           OR DisplayName LIKE '%' + @Filter + '%'
           OR AdAccount   LIKE '%' + @Filter + '%')
    ORDER BY DisplayName;
END;
GO
