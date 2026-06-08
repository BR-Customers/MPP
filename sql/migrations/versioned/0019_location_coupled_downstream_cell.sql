-- =============================================
-- Migration: 0019_location_coupled_downstream_cell
-- Adds Location.Location.CoupledDownstreamCellLocationId -- a nullable, self-
-- referential FK to Location.Location(Id). This promotes the FDS-06-008
-- Machining-OUT auto-move pairing from a CNCMachine LocationAttribute (EAV,
-- NVARCHAR(255)) to a typed column.
--
-- Why promote out of the EAV LocationAttribute table:
--   * It is a Location -> Location relationship (an FK), not free-text. As an
--     AttributeValue NVARCHAR(255) it carried no referential integrity -- it
--     could dangle to a deprecated / non-Cell row or hold a typo'd Id.
--   * It is read on the hot path of every coupled Machining-OUT completion
--     (Arc 2). A typed column is read straight off the already-fetched
--     Location row; the EAV form forced a string->Id pivot per event.
--   * It was spec'd (DM v1.9k) but never seeded -- so there is nothing to
--     remove from 0002 and no value backfill. Pure-forward.
--
-- Semantics:
--   * NON-NULL -> on a Machining Cell, the Location.Id of the Cell that
--                 machined LOTs auto-move to on Machining OUT (typically the
--                 paired Assembly Cell in the same WorkCenter). Arc 2's
--                 PLC-signalled completion writes the ProductionEvent +
--                 LotMovement and updates CurrentLocationId -- no operator scan.
--   * NULL     -> uncoupled / legacy path: completion writes the
--                 ProductionEvent only; the LOT stays put awaiting an
--                 operator-driven movement.
--
-- The self-FK gives referential integrity. The business rule "the target must
-- be a Cell-tier (Assembly) Location" is enforced by the Arc 2 write /
-- config-save proc, not a CHECK constraint -- mirrors
-- Tools.ToolType.CompatibleLocationTypeDefinitionId (migration 0018), where the
-- column carries the data and the proc enforces the filter.
--
-- No index: the hot-path read is a column of an already-fetched Location row
-- (by PK). A reverse lookup ("which Cells couple to X") is rare/admin-only.
--
-- Migration-number note: this takes the next free versioned number 0019. The
-- Arc 2 Phase 5 OperationTemplate sub-LOT-split ALTER previously earmarked for
-- 0019 re-numbers to 0020+ when Arc 2 builds (Arc 2 is OI-35-gated, unbuilt).
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID(N'Location.Location')
                AND name = N'CoupledDownstreamCellLocationId')
BEGIN
    ALTER TABLE Location.Location ADD CoupledDownstreamCellLocationId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
              WHERE name = N'FK_Location_CoupledDownstreamCell')
BEGIN
    ALTER TABLE Location.Location
        ADD CONSTRAINT FK_Location_CoupledDownstreamCell
        FOREIGN KEY (CoupledDownstreamCellLocationId)
        REFERENCES Location.Location(Id);
END
GO
