-- =============================================
-- Procedure:   Oee.ShiftOverride_ListEquipment
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   The equipment picker for the Shift Overrides screen: every location an OEE
--   shift override may be authored against, grouped for display.
--
--   Backed by Oee.ufn_ResolveOeeEquipment, the SAME function Oee.ShiftOverride_Create
--   validates with -- so the picker can never offer something the proc will
--   reject, and can never omit something it would accept.
--
--   Read proc: ONE result set; empty = no equipment configured. No OUTPUT
--   params, no audit (FDS-11-011).
--
-- Parameters (input):
--   @SearchText NVARCHAR(100) = NULL - Case-insensitive contains over Code / Name.
--
-- Result set:
--   LocationId, Code, Name, TierCode, DefinitionCode, ParentName, DisplayLabel
--
-- Dependencies:
--   Funcs: Oee.ufn_ResolveOeeEquipment
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_ListEquipment
    @SearchText NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        e.LocationId,
        e.Code,
        e.Name,
        e.TierCode,
        e.DefinitionCode,
        e.ParentName,
        -- "Die Cast 1 / Machine 07" -- the press name alone is ambiguous
        -- (every area has a "Machine 01"), so the parent is part of the label.
        CASE WHEN e.ParentName IS NULL THEN e.Name
             ELSE e.ParentName + N' / ' + e.Name END AS DisplayLabel
    FROM Oee.ufn_ResolveOeeEquipment() e
    WHERE @SearchText IS NULL
       OR LTRIM(RTRIM(@SearchText)) = N''
       OR e.Code LIKE N'%' + @SearchText + N'%'
       OR e.Name LIKE N'%' + @SearchText + N'%'
    ORDER BY e.ParentName, e.SortOrder, e.Name;
END
GO
