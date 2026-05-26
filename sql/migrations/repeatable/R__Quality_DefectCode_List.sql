-- =============================================
-- Procedure:   Quality.DefectCode_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     1.1
--
-- Description:
--   Returns all defect codes, optionally filtered by active
--   status and/or Area. Orders by AreaName, Code.
--
-- Parameters (input):
--   @IncludeDeprecated BIT - If 0 (default), excludes deprecated.
--   @AreaLocationId BIGINT NULL - Filter by Area.
--
-- Returns (result set):
--   All matching defect codes with Area name.
--
-- Dependencies:
--   Tables: Quality.DefectCode, Location.Location
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-05-19 - 1.1 - ORDER BY changed from (Code) to (AreaName, Code) so the
--                       list view groups codes by area without client-side sorting
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_List
    @IncludeDeprecated BIT    = 0,
    @AreaLocationId    BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        dc.Id,
        dc.Code,
        dc.Description,
        dc.AreaLocationId,
        loc.Name               AS AreaName,
        dc.IsExcused,
        dc.CreatedAt,
        dc.DeprecatedAt
    FROM Quality.DefectCode dc
    LEFT JOIN Location.Location loc ON dc.AreaLocationId = loc.Id
    WHERE (@IncludeDeprecated = 1 OR dc.DeprecatedAt IS NULL)
      AND (@AreaLocationId IS NULL OR dc.AreaLocationId = @AreaLocationId)
    ORDER BY loc.Name, dc.Code;
END
GO
