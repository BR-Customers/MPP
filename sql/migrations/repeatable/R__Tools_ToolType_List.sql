-- =============================================
-- Procedure:   Tools.ToolType_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.0
--
-- Description:
--   Returns ToolType rows ordered by SortOrder. Read-only code table
--   seeded in migration 0010. `HasCavities` flag gates ToolCavity
--   children (currently Die only).
--
-- Parameters:
--   @IncludeDeprecated BIT = 0 - When 1, includes deprecated rows.
--
-- Result set:
--   Id, Code, Name, Description, Icon, HasCavities,
--   CompatibleLocationTypeDefinitionId, SortOrder, CreatedAt, DeprecatedAt.
--
-- Dependencies:
--   Tables: Tools.ToolType
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolType_List
    @IncludeDeprecated BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, Code, Name, Description, Icon, HasCavities,
           CompatibleLocationTypeDefinitionId,
           SortOrder, CreatedAt, DeprecatedAt
    FROM Tools.ToolType
    WHERE (@IncludeDeprecated = 1 OR DeprecatedAt IS NULL)
    ORDER BY SortOrder, Code;
END;
GO
