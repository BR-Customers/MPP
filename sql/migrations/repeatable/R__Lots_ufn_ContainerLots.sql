-- ============================================================
-- Repeatable: R__Lots_ufn_ContainerLots.sql
-- Author:     Blue Ridge Automation
-- Version:    1.0 (2026-11-04, container-as-LOT spec sec 6, D8)
-- Description: The finished-good LOT(s) of a container, in BOTH shapes.
--   OLD (before migration 0119): one LOT per tray, ContainerTray.FinishedGoodLotId.
--   NEW: one LOT per container, Container.LotId (minted on the first tray).
--   MIXED: a container open when 0119 landed -- its old trays' LOTs plus the
--   container LOT minted on its first new tray. UNION ALL returns both.
--
--   SortKey gives the REPRESENTATIVE LOT with TOP 1 ... ORDER BY SortKey:
--   tray LOTs sort by TrayPosition, the container LOT sorts last
--   (2147483647). So old and mixed containers keep today's "first tray's
--   LOT" (AIM LotNumber, label MfgLotNumber) and a new container gives its
--   own LOT.
--
--   Pieces in a container are SUM(ContainerTray.PartsClosedCount), never a
--   sum over these LOTs. Inline TVF so the optimizer sees through it.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_ContainerLots (@ContainerId BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT t.FinishedGoodLotId AS LotId, t.TrayPosition AS SortKey, CAST(N'Tray' AS NVARCHAR(10)) AS Shape
    FROM Lots.ContainerTray t
    WHERE t.ContainerId = @ContainerId
      AND t.FinishedGoodLotId IS NOT NULL
    UNION ALL
    SELECT c.LotId, 2147483647, CAST(N'Container' AS NVARCHAR(10))
    FROM Lots.Container c
    WHERE c.Id = @ContainerId
      AND c.LotId IS NOT NULL
);
GO
