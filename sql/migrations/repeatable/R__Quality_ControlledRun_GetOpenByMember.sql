-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_GetOpenByMember.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: READ. The OPEN super-lot a LOT or container belongs to, if any
--              (a unit has at most one open membership -- D4). What a scanned
--              LTT or container label resolves through on the Quality view.
--
--              A finished-good tray LOT is represented by its container (D3),
--              so a tray LOT's LTT finds the super-lot its container is in.
--
--              No status row, no OUTPUT params (FDS-11-011).
--              Empty set = not in an open super-lot.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_GetOpenByMember
    @LotId       BIGINT = NULL,
    @ContainerId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @ContainerId IS NULL AND @LotId IS NOT NULL
        SET @ContainerId = (SELECT TOP 1 ContainerId FROM Lots.ContainerTray WHERE FinishedGoodLotId = @LotId);

    SELECT TOP 1 r.Id, r.RunNumber
    FROM Quality.ControlledRunMember m
    INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
    WHERE m.EndedAt IS NULL
      AND ((@ContainerId IS NOT NULL AND m.ContainerId = @ContainerId)
        OR (@ContainerId IS NULL AND m.LotId = @LotId));
END;
GO
