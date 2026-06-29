-- =============================================
-- Procedure:   Tools.DieRank_GetByCode
-- Author:      Blue Ridge Automation
-- Created:     2026-06-29
-- Version:     1.0
--
-- Description:
--   Returns a single DieRank row by its (unique) Code. Empty result = not found.
--   Sibling of DieRank_Get (by Id); used by the Die Rank compatibility matrix
--   to resolve a rank Code back to its Id when building the save payload.
--
-- Parameters:
--   @Code NVARCHAR(20) - DieRank.Code (UNIQUE). Required.
--
-- Result set:
--   Zero or one DieRank row.
--
-- Dependencies:
--   Tables: Tools.DieRank
-- =============================================
CREATE OR ALTER PROCEDURE Tools.DieRank_GetByCode
    @Code NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, Code, Name, Description, SortOrder, CreatedAt, DeprecatedAt
    FROM Tools.DieRank
    WHERE Code = @Code;
END;
GO
