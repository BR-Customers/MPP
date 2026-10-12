-- ============================================================
-- Repeatable:  R__Lots_ufn_zz_CrtForMint.sql
-- Object:      Lots.ufn_CrtForMint
-- Author:      Blue Ridge Automation
-- Created:     2026-08-20
-- Version:     1.1
-- Description: THE single place the CRT-at-mint decision is made (design D1).
--              A newly minted LOT is CRT-active if ANY of:
--                1. its part carries Parts.Item.CrtEnabled = 1, OR
--                2. the minting terminal carries the CrtEnabled location
--                   attribute added by migration 0058 (Location.Location ->
--                   Location.LocationAttribute joined through
--                   Location.LocationAttributeDefinition; an absent row
--                   reads as '0', same convention as HasBarcodeScanner), OR
--                3. any consumed input LOT is already Lots.Lot.CrtActive = 1
--                   (D2 propagation -- CRT is sticky once assigned upstream), OR
--                4. an OPEN super-lot (Quality.ControlledRun, migration 0109)
--                   with "keep adding new production" on covers this part,
--                   and either names no line or names a location at/above
--                   the minting terminal. This is the super-lot's rolling
--                   window: it tags the LOT here, in the mint transaction;
--                   Quality.ControlledRun_SyncInternal records the
--                   membership afterwards. A window that names a line
--                   cannot match a mint with no @TerminalLocationId.
--
--              Evaluated at MINT TIME ONLY (D3) -- nothing re-derives this
--              later; callers persist the result onto the new LOT's
--              Lots.Lot.CrtActive column (that column predates this feature,
--              added by an earlier, separate CRT container-validation effort).
--
--              Task 2 of the part-scoped CRT feature. Nothing calls this
--              function yet -- later tasks wire it into every mint point
--              (Die Cast open, Machining OUT mint, Assembly complete-tray)
--              and add the movement/advance guards + UI.
--
--              FILE NAME IS ORDER-SENSITIVE. The 'zz_' is a DEPLOY-ORDER
--              MARKER, not part of the object name (the object is plain
--              Lots.ufn_CrtForMint). Reset-DevDatabase deploys repeatables
--              in filename (Sort-Object Name) order, and a FUNCTION gets no
--              deferred name resolution (Msg 4121) -- unlike a procedure,
--              which does. This function reads Parts.Item, Location.Location,
--              Location.LocationAttribute/LocationAttributeDefinition, and
--              Lots.Lot, all of which are created by versioned migrations
--              that run before ANY repeatable script, so the 'zz_' here is
--              belt-and-suspenders against a future same-schema dependency
--              rather than a currently-required ordering. Do not "tidy" the
--              filename. Same constraint that named
--              R__Oee_ufn_zz_ShiftIdForInstant / R__Oee_ufn_zz_ShiftOverrideConflicts.
--
--              Inline TVF (single RETURN (SELECT ...), no BEGIN/END body) so
--              it INLINES into the caller's query plan -- callers use it as
--              (SELECT CrtActive FROM Lots.ufn_CrtForMint(...)) inside a
--              mint proc's INSERT ... SELECT, not as a scalar UDF row-by-row
--              call.
--
-- Parameters:
--   @ItemId             BIGINT        - the part being minted. Required.
--   @TerminalLocationId BIGINT        - the minting terminal, or NULL when
--                                        the mint point has no terminal
--                                        concept (or the terminal doesn't
--                                        carry the CrtEnabled attribute).
--   @InputLotIdsCsv     NVARCHAR(MAX) - comma-separated Lots.Lot.Id values
--                                        for every LOT consumed by this
--                                        mint, or NULL / '' when there are
--                                        none (e.g. Die Cast, which mints
--                                        from raw material with no LOT
--                                        inputs). A malformed or empty CSV
--                                        is NOT an error -- it simply
--                                        contributes no propagation hits.
--
-- Result set (exactly one row):
--   CrtActive BIT - 1 if any of the three conditions above holds, else 0.
--
-- Dependencies:
--   Tables: Parts.Item, Location.Location, Location.LocationAttribute,
--           Location.LocationAttributeDefinition, Lots.Lot,
--           Quality.ControlledRun (index IX_ControlledRun_AutoJoin)
--
-- Change Log:
--   2026-08-20 - 1.0 - Initial version (part-scoped CRT, Task 2).
--   2026-10-12 - 1.1 - Arm 4: an open super-lot window tags new production
--                      of its part (and line). Arms 1-3 are unchanged; with
--                      no open window the result is identical to v1.0.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_CrtForMint
(
    @ItemId             BIGINT,
    @TerminalLocationId BIGINT        = NULL,
    @InputLotIdsCsv     NVARCHAR(MAX) = NULL
)
RETURNS TABLE
AS
RETURN
(
    WITH Anc AS (   -- @TerminalLocationId and every location above it (<= ~6 rows)
        SELECT l.Id, l.ParentLocationId FROM Location.Location l WHERE l.Id = @TerminalLocationId
        UNION ALL
        SELECT p.Id, p.ParentLocationId FROM Location.Location p INNER JOIN Anc a ON p.Id = a.ParentLocationId
    )
    SELECT CONVERT(BIT, CASE WHEN
        -- (1) Part flag.
        EXISTS (SELECT 1 FROM Parts.Item i
                 WHERE i.Id = @ItemId AND i.CrtEnabled = 1)
        -- (2) Terminal switch (migration 0058; absent row reads as '0').
     OR EXISTS (SELECT 1
                  FROM Location.LocationAttribute la
                  JOIN Location.LocationAttributeDefinition ad
                    ON ad.Id = la.LocationAttributeDefinitionId
                 WHERE la.LocationId = @TerminalLocationId
                   AND ad.AttributeName = N'CrtEnabled'
                   AND ad.DeprecatedAt IS NULL
                   AND la.AttributeValue = N'1')
        -- (3) D2 propagation: any consumed input LOT already CRT-active.
     OR EXISTS (SELECT 1
                  FROM STRING_SPLIT(ISNULL(@InputLotIdsCsv, N''), N',') s
                  JOIN Lots.Lot l ON l.Id = TRY_CAST(s.value AS BIGINT)
                 WHERE l.CrtActive = 1)
        -- (4) Super-lot rolling window (Quality.ControlledRun, migration 0109):
        --     an OPEN run with "keep adding new production" on covers this part,
        --     and either names no line or names one at/above the minting terminal.
        --     Seeks IX_ControlledRun_AutoJoin, which is normally empty.
     OR EXISTS (SELECT 1
                  FROM Quality.ControlledRun r
                 WHERE r.ControlledRunStatusId = 1
                   AND r.AutoJoinEnabled = 1
                   AND r.SelectionItemId = @ItemId
                   AND (r.SelectionLocationId IS NULL
                        OR r.SelectionLocationId IN (SELECT a.Id FROM Anc a)))
        THEN 1 ELSE 0 END) AS CrtActive
);
GO
