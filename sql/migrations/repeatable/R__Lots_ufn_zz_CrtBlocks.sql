-- ============================================================
-- Repeatable:  R__Lots_ufn_zz_CrtBlocks.sql
-- Objects:     Lots.ufn_CrtBlocksAdvance, Lots.ufn_CrtBlocksMoveTo
-- Author:      Blue Ridge Automation
-- Created:     2026-08-20
-- Version:     1.0
-- Description: The CRT enforcement guards (design D4, D5). Task 3 of the
--              part-scoped CRT feature. Nothing calls these functions yet --
--              Task 5 wires them into the actual procs.
--
--              ufn_CrtBlocksAdvance -- a CRT LOT cannot be consumed or
--                advanced. Trivial today (just Lots.Lot.CrtActive), but it
--                is the SEAM: if the rule ever considers hold state,
--                inspection status or a grace period, it changes here and
--                every caller inherits it.
--
--              ufn_CrtBlocksMoveTo -- a CRT LOT cannot move to a PRODUCTION
--                destination (Location.LocationTypeDefinition.
--                IsProductionDestination = 1, Task 1), but CAN move to
--                inspection, inventory, receiving or a support area, so
--                suspect material can still be taken to quarantine.
--
--              Both are inline TVFs (single RETURN (SELECT ...), no
--              BEGIN/END body) so they INLINE into the caller's query plan.
--              Callers use them as (SELECT Blocked FROM
--              Lots.ufn_CrtBlocks...(...)) = 1 in a boolean position, never
--              as a scalar UDF row-by-row call. Each returns exactly one
--              row with one BIT column named Blocked -- built as a single
--              SELECT with no FROM, using EXISTS(...) subqueries, so a
--              nonexistent @LotId (or, for ufn_CrtBlocksMoveTo, a
--              nonexistent @ToLocationId) still yields exactly one row
--              with Blocked = 0, never NULL and never zero rows.
--
--              FILE NAME IS ORDER-SENSITIVE -- see R__Lots_ufn_zz_CrtForMint.sql
--              for the full rationale. The 'zz_' is a DEPLOY-ORDER MARKER,
--              not part of the object name (the objects are plain
--              Lots.ufn_CrtBlocksAdvance / Lots.ufn_CrtBlocksMoveTo).
--              Reset-DevDatabase deploys repeatables in filename
--              (Sort-Object Name) order, and a FUNCTION gets no deferred
--              name resolution (Msg 4121) -- unlike a procedure, which
--              does. These functions read Lots.Lot and Location.Location /
--              Location.LocationTypeDefinition, all created by versioned
--              migrations that run before ANY repeatable script, so the
--              'zz_' here is belt-and-suspenders against a future
--              same-schema dependency rather than a currently-required
--              ordering. Do not "tidy" the filename. Same constraint that
--              named R__Lots_ufn_zz_CrtForMint /
--              R__Oee_ufn_zz_ShiftIdForInstant /
--              R__Oee_ufn_zz_ShiftOverrideConflicts.
--
-- Parameters:
--   ufn_CrtBlocksAdvance(@LotId BIGINT)
--   ufn_CrtBlocksMoveTo(@LotId BIGINT, @ToLocationId BIGINT)
--
-- Result set (exactly one row each):
--   Blocked BIT
--
-- Dependencies:
--   Tables: Lots.Lot, Location.Location, Location.LocationTypeDefinition
--
-- Change Log:
--   2026-08-20 - 1.0 - Initial version (part-scoped CRT, Task 3).
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_CrtBlocksAdvance (@LotId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CONVERT(BIT, CASE WHEN EXISTS (
        SELECT 1 FROM Lots.Lot l WHERE l.Id = @LotId AND l.CrtActive = 1
    ) THEN 1 ELSE 0 END) AS Blocked
);
GO

CREATE OR ALTER FUNCTION Lots.ufn_CrtBlocksMoveTo (@LotId BIGINT, @ToLocationId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT CONVERT(BIT, CASE WHEN EXISTS (
        SELECT 1
          FROM Lots.Lot l
          JOIN Location.Location dst ON dst.Id = @ToLocationId
          JOIN Location.LocationTypeDefinition d ON d.Id = dst.LocationTypeDefinitionId
         WHERE l.Id = @LotId
           AND l.CrtActive = 1
           AND d.IsProductionDestination = 1
    ) THEN 1 ELSE 0 END) AS Blocked
);
GO
