-- ============================================================
-- Repeatable:  R__Oee_ufn_ResolveDowntimeScope.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-17
-- Version:     2.0
-- Description: Resolves a location to the downtime "unit" it belongs to: the
--              nearest OEE-ENABLED location at or above it.
--
--              v2.0 (OEE-enabled locations spec, 2026-09-16): the rule is now
--              the Location.IsOeeEnabled flag, not "walk up to the nearest
--              WorkCenter". The old rule made it impossible for a cell under a
--              production line to be a downtime unit, because it always
--              resolved up to the line -- which is exactly what 6MA Cam Holder
--              Line 1 needs (Machining / Assembly A / Assembly B under the
--              line). Behaviour is unchanged wherever the backfill flagged
--              what the old rule admitted: a terminal still resolves to its
--              line, a press still resolves to itself.
--
--              Nothing flagged at or above -> the location itself (preserves
--              the old fallback, which the Downtime Manager relies on for an
--              unregistered terminal). NULL in -> NULL out.
--
--              This function no longer DEFINES equipment -- the flag does (see
--              Oee.ufn_ResolveOeeEquipment). Its remaining job is the Downtime
--              Manager's default selection.
--
-- Parameters:
--   @CellLocationId BIGINT - any location (terminal, cell, line).
--
-- Returns:
--   BIGINT - the resolved downtime unit's Location.Id, or NULL for NULL input.
--
-- Dependencies:
--   Tables: Location.Location
--   Funcs:  Oee.ufn_OeeAncestors  (deploys first -- see that file's header)
--
-- Change Log:
--   2026-07-21 - 1.0 - Initial version (nearest WorkCenter ancestor).
--   2026-09-17 - 2.0 - Nearest OEE-enabled location at or above.
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_ResolveDowntimeScope (@CellLocationId BIGINT)
RETURNS BIGINT
AS
BEGIN
    IF @CellLocationId IS NULL RETURN NULL;

    -- A flagged location is its own unit.
    IF EXISTS (SELECT 1 FROM Location.Location
               WHERE Id = @CellLocationId AND IsOeeEnabled = 1 AND DeprecatedAt IS NULL)
        RETURN @CellLocationId;

    DECLARE @Anc BIGINT =
        (SELECT TOP 1 a.AncestorLocationId
         FROM Oee.ufn_OeeAncestors(@CellLocationId) a
         ORDER BY a.Distance);

    RETURN COALESCE(@Anc, @CellLocationId);
END
GO
