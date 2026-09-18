-- ============================================================
-- Repeatable:  R__Oee_ufn_ResolveOeeEquipment.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     2.0
-- Description: THE definition of "a piece of equipment" for OEE purposes --
--              the set of Location.Location rows that downtime is logged
--              against and that an OEE figure can be computed for.
--
--              v2.0 (OEE-enabled locations spec, 2026-09-16): one condition --
--              Location.IsOeeEnabled = 1, active. The old self-scoping test
--              (ufn_ResolveDowntimeScope(Id) = Id) plus the tier and
--              device/store exclusions are gone: they are now enforced once,
--              at the write path, by Location.ufn_CanBeOeeEnabled, so the set
--              is data an engineer can see and change in the Config Tool
--              rather than a rule buried in a function.
--
--              Migration 0090 backfilled the flag from the old rule, so this
--              returns the same set it did before the change until someone
--              flags something new.
--
--              Single source of truth: Oee.ShiftOverride_ListEquipment (the
--              picker), Oee.ShiftOverride_Create (the validation) and
--              Oee.Shift_GetAvailability all read this function.
--
--              Read-only inline TVF: no OUTPUT params, no audit, no status row.
--              No longer calls ufn_ResolveDowntimeScope, so the filename
--              ordering constraint that used to apply here is gone.
--
-- Result set:
--   LocationId, Code, Name, TierCode, DefinitionCode, ParentName, SortOrder
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationTypeDefinition, Location.LocationType
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
--   2026-09-17 - 2.0 - Flag-driven (Location.IsOeeEnabled).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ResolveOeeEquipment ()
RETURNS TABLE
AS
RETURN
(
    SELECT
        l.Id        AS LocationId,
        l.Code,
        l.Name,
        lt.Code     AS TierCode,
        ltd.Code    AS DefinitionCode,
        p.Name      AS ParentName,
        l.SortOrder
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType           lt  ON lt.Id  = ltd.LocationTypeId
    LEFT  JOIN Location.Location               p   ON p.Id   = l.ParentLocationId
    WHERE l.DeprecatedAt IS NULL
      AND l.IsOeeEnabled = 1
);
GO
