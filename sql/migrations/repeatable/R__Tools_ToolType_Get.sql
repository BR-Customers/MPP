-- =============================================
-- Procedure:   Tools.ToolType_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.0
--
-- Description:
--   Returns a single ToolType row by Id. Empty result = not found.
--
-- Parameters:
--   @Id BIGINT - PK. Required.
--
-- Result set:
--   Zero or one ToolType row.
--
-- Dependencies:
--   Tables: Tools.ToolType
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolType_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, Code, Name, Description, Icon, HasCavities,
           CompatibleLocationTypeDefinitionId,
           SortOrder, CreatedAt, DeprecatedAt
    FROM Tools.ToolType
    WHERE Id = @Id;
END;
GO
