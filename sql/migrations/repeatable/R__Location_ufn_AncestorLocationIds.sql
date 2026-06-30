-- =============================================
-- Function:    Location.ufn_AncestorLocationIds
-- Author:      Blue Ridge Automation
-- Created:     2026-06-30
-- Version:     1.0
--
-- Description:
--   Inline table-valued function returning the given Location PLUS every
--   ancestor up the hierarchy (Cell -> WorkCenter -> Area -> Site) by walking
--   ParentLocationId to the root. Encapsulates the FDS-03-014 / FDS-02-012
--   eligibility "hierarchy cascade" walk in ONE place so every eligibility
--   resolution point (the dropdown list proc + the Lot_Create / Lot_MoveToValidated
--   gates + the advisory CheckEligibility proc) stays consistent.
--
--   Usage:  WHERE eil.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LocationId))
--
-- Parameters:
--   @LocationId BIGINT - the resolution location (typically the scanned Cell).
--
-- Returns:
--   TABLE (LocationId BIGINT) - @LocationId and all ancestor LocationIds.
--   Empty when @LocationId is NULL or not found.
--
-- Notes:
--   Inline TVF (RETURNS TABLE) so it inlines into the caller's plan. The
--   adjacency-list hierarchy is a tree (no cycles); default MAXRECURSION (100)
--   is a safety net far above the ~5-tier depth.
--
-- Dependencies:
--   Tables: Location.Location
-- =============================================
CREATE OR ALTER FUNCTION Location.ufn_AncestorLocationIds(@LocationId BIGINT)
RETURNS TABLE
AS
RETURN
    WITH Chain AS (
        SELECT l.Id, l.ParentLocationId
        FROM Location.Location l
        WHERE l.Id = @LocationId
        UNION ALL
        SELECT p.Id, p.ParentLocationId
        FROM Location.Location p
        INNER JOIN Chain c ON c.ParentLocationId = p.Id
    )
    SELECT Id AS LocationId FROM Chain;
GO
