-- ============================================================
-- Repeatable:  R__Oee_ufn_OeeAncestors.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-17
-- Version:     1.0
-- Description: The OEE-enabled STRICT ancestors of a location, nearest first
--              (Distance 1 = parent). Two callers:
--                * Oee.ufn_ResolveDowntimeScope -- nearest flagged ancestor.
--                * Oee.Shift_GetAvailability -- downtime logged against a
--                  flagged ancestor counts against every station under it
--                  ("if the line is down, all stations are impacted").
--              Deprecated ancestors are skipped but do NOT stop the walk, so a
--              station under a deprecated intermediate still finds its line.
--
--              NAME IS ORDER-SENSITIVE. Repeatables deploy in filename order
--              and a FUNCTION gets no deferred name resolution (Msg 4121), so
--              this file must sort BEFORE R__Oee_ufn_ResolveDowntimeScope.sql,
--              which calls it ("OeeAncestors" < "ResolveDowntimeScope").
--
--              Read-only inline TVF: no OUTPUT params, no audit, no status row.
--
-- Parameters:
--   @LocationId BIGINT - the location to walk up from. NULL -> empty set.
--
-- Result set:
--   AncestorLocationId BIGINT, Distance INT
--
-- Dependencies:
--   Tables: Location.Location
--
-- Change Log:
--   2026-09-17 - 1.0 - Initial version (OEE-enabled locations spec).
-- ============================================================
CREATE OR ALTER FUNCTION Oee.ufn_OeeAncestors (@LocationId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH Up AS (
        SELECT l.ParentLocationId AS AncestorId, 1 AS Distance
        FROM Location.Location l
        WHERE l.Id = @LocationId
          AND l.ParentLocationId IS NOT NULL
        UNION ALL
        SELECT p.ParentLocationId, u.Distance + 1
        FROM Up u
        INNER JOIN Location.Location p ON p.Id = u.AncestorId
        WHERE p.ParentLocationId IS NOT NULL
    )
    SELECT u.AncestorId AS AncestorLocationId,
           u.Distance
    FROM Up u
    INNER JOIN Location.Location a ON a.Id = u.AncestorId
    WHERE a.IsOeeEnabled = 1
      AND a.DeprecatedAt IS NULL
);
GO
