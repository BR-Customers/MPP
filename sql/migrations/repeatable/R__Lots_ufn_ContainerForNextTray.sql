-- =============================================
-- Function:    Lots.ufn_ContainerForNextTray
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Version:     1.0
--
-- Description:
--   The open box the next tray of @ItemId at @CellLocationId would go into --
--   Workorder.Assembly_CompleteTray's box rule (0078), factored out so the
--   pack-out readers and Location.Terminal_SetPackOut use the SAME box:
--     - with a station: its own open box, else an unowned open box at the cell
--       (the one CompleteTray would claim);
--     - with no station (caller is not a terminal): the oldest open box at the
--       cell.
--   By part only, not closure method (as CompleteTray). No lock hints: this is
--   the read. CompleteTray's B2 keeps its own UPDLOCK/HOLDLOCK lookup for the
--   claim itself.
--
--   Inline TVF; seeks IX_Container_OpenByCellItemStation (filtered Open = 1).
--   Spec: docs/superpowers/specs/2026-11-20-named-pack-outs-design.md 7.1a.
--
-- Parameters:
--   @CellLocationId    BIGINT - the line the box lives at.
--   @ItemId            BIGINT - finished good.
--   @StationLocationId BIGINT - the terminal (LTD 7) filling it, or NULL.
--
-- Returns: 0..1 row -- ContainerId, ContainerConfigId.
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version (named pack-outs).
-- =============================================
CREATE OR ALTER FUNCTION Lots.ufn_ContainerForNextTray
(
    @CellLocationId    BIGINT,
    @ItemId            BIGINT,
    @StationLocationId BIGINT
)
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) c.Id AS ContainerId, c.ContainerConfigId
    FROM Lots.Container c
    WHERE c.CurrentLocationId = @CellLocationId
      AND c.ItemId = @ItemId
      AND c.ContainerStatusCodeId = 1
      AND (@StationLocationId IS NULL
           OR c.StationLocationId = @StationLocationId
           OR c.StationLocationId IS NULL)
    ORDER BY CASE WHEN @StationLocationId IS NOT NULL AND c.StationLocationId = @StationLocationId THEN 0 ELSE 1 END,
             c.OpenedAt, c.Id;
GO
