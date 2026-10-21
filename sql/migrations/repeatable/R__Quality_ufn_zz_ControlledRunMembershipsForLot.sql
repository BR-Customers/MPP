-- ============================================================
-- Repeatable:  R__Quality_ufn_zz_ControlledRunMembershipsForLot.sql
-- Object:      Quality.ufn_ControlledRunMembershipsForLot
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: Super-lot piece 6. Every super-lot membership a LOT has had, as
--              one row per membership: as a LOT member itself, or as a tray LOT
--              of a container that was a member (ViaContainerId set).
--
--              A tray counts through its container only if it was in the container
--              WHILE the membership was open: the tray's ClosedAt (or, when it has
--              none, the membership's AddedAt) must not be later than the
--              membership's EndedAt. A tray repacked into the container after the
--              membership ended is not listed. A tray moved in during the
--              membership is listed, with no back-dated join.
--
--              Times are UTC; readers convert to Eastern.
--              FILE NAME IS ORDER-SENSITIVE ('zz_' deploy-order marker; functions
--              get no deferred name resolution). Do not "tidy" it.
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunMembershipsForLot (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT m.Id AS ControlledRunMemberId, m.ControlledRunId, r.RunNumber,
           CAST(NULL AS BIGINT) AS ViaContainerId, m.AddedAt, m.EndedAt
    FROM Quality.ControlledRunMember m
    INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
    WHERE m.LotId = @LotId
    UNION ALL
    SELECT m.Id, m.ControlledRunId, r.RunNumber, m.ContainerId, m.AddedAt, m.EndedAt
    FROM Quality.ControlledRunMember m
    INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
    INNER JOIN Lots.ContainerTray t ON t.ContainerId = m.ContainerId
    WHERE t.FinishedGoodLotId = @LotId
      AND COALESCE(t.ClosedAt, m.AddedAt) <= COALESCE(m.EndedAt, CAST('9999-12-31' AS DATETIME2(3)));
GO
