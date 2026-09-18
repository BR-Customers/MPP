-- =============================================
-- Procedure:   Location.LocationTypeDefinition_GetOeeEligibility
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
--
-- Description:
--   May a location of this type be OEE / downtime enabled? Drives the
--   enabled-state of the "OEE / downtime enabled" checkbox on the Plant
--   Hierarchy editor, so the screen asks SQL the same question
--   Location.Location_SaveAll enforces instead of restating the rule in
--   Python.
--
--   Read proc: one result set, no status row, no OUTPUT params (FDS-11-011).
--   Empty result set = definition not found.
--
-- Parameters (input):
--   @LocationTypeDefinitionId BIGINT - the definition to test. Required.
--
-- Result set (zero or one row):
--   LocationTypeDefinitionId, CanBeOeeEnabled (BIT)
--
-- Dependencies:
--   Tables: Location.LocationTypeDefinition
--   Funcs:  Location.ufn_CanBeOeeEnabled
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version (OEE-enabled locations spec).
-- =============================================
CREATE OR ALTER PROCEDURE Location.LocationTypeDefinition_GetOeeEligibility
    @LocationTypeDefinitionId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ltd.Id                                          AS LocationTypeDefinitionId,
           Location.ufn_CanBeOeeEnabled(ltd.Id)            AS CanBeOeeEnabled
    FROM Location.LocationTypeDefinition ltd
    WHERE ltd.Id = @LocationTypeDefinitionId;
END;
GO
