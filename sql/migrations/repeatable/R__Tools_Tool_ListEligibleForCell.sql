-- ============================================================
-- Repeatable:  R__Tools_Tool_ListEligibleForCell.sql
-- Procedure:   Tools.Tool_ListEligibleForCell
-- Author:      Blue Ridge Automation
-- Created:     2026-09-14
-- Version:     1.0
-- Description: Which dies the PLANT-FLOOR Die Mount popup offers for a press.
--
--              WHY THIS EXISTS BESIDE Tool_ListMountableForCell. That proc
--              qualifies a tool on three tests: active, not mounted anywhere,
--              and ToolType.CompatibleLocationTypeDefinitionId matching the
--              cell's definition. Migration 0018 seeds exactly ONE such
--              mapping -- Die -> DieCastMachine -- so on a press the filter
--              reduces to "every active die not already mounted", identical on
--              all 22 presses. In Dev, with a handful of dies, that reads like
--              a shortlist. Against the real MPP tooling list it is a flat
--              alphabetical roll of every die in the building, on a touch
--              screen, mid-changeover.
--
--              THE SIGNAL. Parts.ItemLocation records which parts run on which
--              machines and Tools.ToolCavity is keyed (ToolId, ItemId,
--              CavityCode), so a die reaches a press through the parts it cuts.
--              This is the exact inverse of
--              Location.Location_ListDieCastMachinesForItem and inherits its
--              two hard-won rules:
--
--                * EXACT MATCH AT THE MACHINE TIER, never the FDS-03-014
--                  ancestor cascade. Eligibility is recorded overwhelmingly at
--                  Area and Line; a cascade returns the same eleven machines
--                  for every part in the plant. The machine-tier rows are the
--                  deliberate signal.
--                * FALLBACK, NEVER A GATE. A press with no machine-tier
--                  mapping gets EVERY compatible unmounted die, flagged
--                  IsEligible = 0. A die setter must always be able to mount
--                  the die that is physically in their hands. Eligibility
--                  shortens a list; it never refuses one.
--
--              The fallback is decided ONCE with a COUNT(*), not per row, so a
--              press returns either its mapped dies (all IsEligible = 1) or
--              every compatible die (all IsEligible = 0) -- never a confusing
--              mix. Tool_ListMountableForCell is deliberately LEFT UNTOUCHED:
--              the Config Tool's CellMountCard is a supervisor-at-a-desk
--              surface where "every unmounted die" is a defensible list, and
--              changing a shared read proc to serve one new caller is how a
--              filter acquires a second meaning. Two purpose-named read procs,
--              one caller each.
--
--              This LAYERS ON TOP of the type-compatibility and
--              not-already-mounted predicates -- it does not replace them. A
--              die mounted on another press stays out of the list in BOTH
--              branches, which is what keeps ToolAssignment_Assign's 1:1
--              invariant from ever being the thing that rejects.
--
--              Read proc: no @Status/@Message, no OUTPUT params, one result
--              set (FDS-11-011). Unknown / deprecated cell -> empty rowset.
--
--              Result set: Id, Code, Name, IsEligible BIT -- shape feeds
--              BlueRidge.Parts.Tool.getEligibleToolPicker -> {options:
--              [{label, value}], isFallback, count}.
--
--              Spec: docs/superpowers/specs/
--                    2026-09-14-plant-floor-die-mount-popup-design.md (4.3)
-- ============================================================
CREATE OR ALTER PROCEDURE Tools.Tool_ListEligibleForCell
    @CellLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DefId BIGINT;
    SELECT @DefId = l.LocationTypeDefinitionId
    FROM Location.Location l
    WHERE l.Id = @CellLocationId
      AND l.DeprecatedAt IS NULL;

    IF @DefId IS NULL
        RETURN;  -- unknown / deprecated cell -> nothing eligible

    -- Decide the fallback ONCE. The predicate below is repeated verbatim in
    -- the SELECT; they must stay in step or a press could report a count it
    -- then fails to return.
    DECLARE @EligibleCount INT = (
        SELECT COUNT(*)
        FROM Tools.Tool t
        INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.DeprecatedAt IS NULL
          AND (tt.CompatibleLocationTypeDefinitionId = @DefId
               OR tt.CompatibleLocationTypeDefinitionId IS NULL)
          AND NOT EXISTS (
              SELECT 1 FROM Tools.ToolAssignment ta
              WHERE ta.ToolId = t.Id
                AND ta.ReleasedAt IS NULL)
          AND EXISTS (
              SELECT 1
              FROM Tools.ToolCavity tc
              INNER JOIN Parts.ItemLocation il ON il.ItemId = tc.ItemId
              WHERE tc.ToolId = t.Id
                AND tc.DeprecatedAt IS NULL
                AND il.LocationId = @CellLocationId
                AND il.DeprecatedAt IS NULL));

    SELECT
        t.Id,
        t.Code,
        t.Name,
        CAST(CASE WHEN @EligibleCount = 0 THEN 0 ELSE 1 END AS BIT) AS IsEligible
    FROM Tools.Tool t
    INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
    WHERE t.DeprecatedAt IS NULL
      AND (tt.CompatibleLocationTypeDefinitionId = @DefId
           OR tt.CompatibleLocationTypeDefinitionId IS NULL)
      AND NOT EXISTS (
          SELECT 1 FROM Tools.ToolAssignment ta
          WHERE ta.ToolId = t.Id
            AND ta.ReleasedAt IS NULL)
      AND (@EligibleCount = 0
           OR EXISTS (
               SELECT 1
               FROM Tools.ToolCavity tc
               INNER JOIN Parts.ItemLocation il ON il.ItemId = tc.ItemId
               WHERE tc.ToolId = t.Id
                 AND tc.DeprecatedAt IS NULL
                 AND il.LocationId = @CellLocationId
                 AND il.DeprecatedAt IS NULL))
    ORDER BY IsEligible DESC, t.Code;
END;
GO
