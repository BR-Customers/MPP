-- ============================================================
-- Repeatable: R__Lots_ufn_LotContainers.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0 (2026-11-04, container-as-LOT spec sec 6, D8)
-- Description: The container a finished-good LOT is packed in, in BOTH shapes.
--   OLD: the tray whose FinishedGoodLotId = @LotId (ContainerTrayId = that tray).
--   NEW: the container whose LotId = @LotId (ContainerTrayId NULL -- a
--        container LOT spans all of the container's trays).
--   Zero rows = not a packed finished-good LOT. Inline TVF.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_LotContainers (@LotId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT t.ContainerId, CAST(t.Id AS BIGINT) AS ContainerTrayId
    FROM Lots.ContainerTray t
    WHERE t.FinishedGoodLotId = @LotId
    UNION ALL
    SELECT c.Id, CAST(NULL AS BIGINT)
    FROM Lots.Container c
    WHERE c.LotId = @LotId
);
GO
