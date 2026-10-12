-- ============================================================
-- Repeatable:  R__Quality_ufn_zz_ControlledRunResolveMembers.sql
-- Object:      Quality.ufn_ControlledRunResolveMembers
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: THE single place a candidate super-lot member is resolved,
--              described and judged. Used by the preview
--              (Quality.ControlledRun_PreviewSelection) and by every writer
--              (Quality.ControlledRun_ApplyMembersInternal and the procs that
--              call it), so "what the preview showed" and "what the writer
--              accepts" cannot drift apart.
--
--              Input: [{"lotId":n} | {"containerId":n}, ...]. NULL, invalid
--              JSON and junk entries yield no rows -- never an error.
--
--              D3 FOLD: a finished-good tray LOT (Lots.ContainerTray.
--              FinishedGoodLotId) is represented by its CONTAINER, so a tray
--              LOT is never returned as a LOT and a container named by two of
--              its trays (or by itself as well) comes back exactly once.
--
--              IneligibleReason IS NULL means the unit may join a super-lot.
--              A completed, unshipped container IS eligible (spec 9.2): its
--              Closed tray LOTs are not tagged by this piece, but it is listed.
--              A Closed LOT that is not a tray is not eligible.
--
--              FILE NAME IS ORDER-SENSITIVE. The 'zz_' is a DEPLOY-ORDER
--              MARKER, not part of the object name. Reset-DevDatabase deploys
--              repeatables in filename order and a FUNCTION gets no deferred
--              name resolution (Msg 4121). Every object read here is created
--              by a versioned migration, which runs before any repeatable, so
--              the marker is belt-and-suspenders. Do not "tidy" the filename.
--              Same convention as R__Lots_ufn_zz_CrtBlocks.sql.
--
-- Result set:  LotId, ContainerId, Kind ('Lot'|'Container'), DisplayName,
--              ItemId, CurrentLocationId, StatusCode, PieceCount,
--              ProducedAt (UTC), CrtActive, IneligibleReason
-- ============================================================
CREATE OR ALTER FUNCTION Quality.ufn_ControlledRunResolveMembers (@MembersJson NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    WITH Raw AS (
        SELECT TRY_CAST(JSON_VALUE(j.value, N'$.lotId')       AS BIGINT) AS LotId,
               TRY_CAST(JSON_VALUE(j.value, N'$.containerId') AS BIGINT) AS ContainerId
        FROM OPENJSON(CASE WHEN ISJSON(@MembersJson) = 1 THEN @MembersJson ELSE N'[]' END) j
    ),
    Folded AS (   -- D3: a finished-good tray LOT is represented by its container
        SELECT DISTINCT
               CASE WHEN r.ContainerId IS NULL AND t.ContainerId IS NULL THEN r.LotId END AS LotId,
               COALESCE(r.ContainerId, t.ContainerId)                                     AS ContainerId
        FROM Raw r
        LEFT JOIN Lots.ContainerTray t ON r.ContainerId IS NULL AND t.FinishedGoodLotId = r.LotId
        WHERE r.LotId IS NOT NULL OR r.ContainerId IS NOT NULL
    )
    SELECT
        f.LotId,
        f.ContainerId,
        CASE WHEN f.ContainerId IS NOT NULL THEN N'Container' ELSE N'Lot' END AS Kind,
        CAST(CASE WHEN f.ContainerId IS NOT NULL THEN N'Container ' + CAST(f.ContainerId AS NVARCHAR(20))
                  ELSE ISNULL(l.LotName, N'LOT ' + CAST(f.LotId AS NVARCHAR(20))) END AS NVARCHAR(60)) AS DisplayName,
        COALESCE(c.ItemId, l.ItemId)                       AS ItemId,
        COALESCE(c.CurrentLocationId, l.CurrentLocationId) AS CurrentLocationId,
        COALESCE(cs.Code, ls.Code)                         AS StatusCode,
        CASE WHEN f.ContainerId IS NOT NULL THEN ISNULL(ct.Pieces, 0) ELSE l.PieceCount END AS PieceCount,
        COALESCE(c.OpenedAt, l.CreatedAt)                  AS ProducedAt,
        CONVERT(BIT, CASE WHEN f.ContainerId IS NOT NULL THEN ISNULL(ct.AnyCrt, 0) ELSE ISNULL(l.CrtActive, 0) END) AS CrtActive,
        CAST(CASE
            WHEN f.ContainerId IS NOT NULL AND c.Id IS NULL THEN N'Container not found'
            WHEN f.ContainerId IS NULL     AND l.Id IS NULL THEN N'LOT not found'
            WHEN om.RunNumber IS NOT NULL THEN N'Already in ' + om.RunNumber
            WHEN cs.Code = N'Shipped' THEN N'Already shipped'
            WHEN cs.Code = N'Void'    THEN N'Voided'
            WHEN ls.Code = N'Scrap'   THEN N'Scrapped'
            WHEN ls.Code = N'Closed'  THEN N'Closed'
        END AS NVARCHAR(100)) AS IneligibleReason
    FROM Folded f
    LEFT JOIN Lots.Lot l                  ON f.ContainerId IS NULL AND l.Id = f.LotId
    LEFT JOIN Lots.LotStatusCode ls       ON ls.Id = l.LotStatusId
    LEFT JOIN Lots.Container c            ON c.Id = f.ContainerId
    LEFT JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    OUTER APPLY (
        SELECT SUM(tl.PieceCount) AS Pieces, MAX(CAST(tl.CrtActive AS INT)) AS AnyCrt
        FROM Lots.ContainerTray t2 JOIN Lots.Lot tl ON tl.Id = t2.FinishedGoodLotId
        WHERE t2.ContainerId = f.ContainerId
    ) ct
    OUTER APPLY (
        SELECT TOP 1 r.RunNumber
        FROM Quality.ControlledRunMember m JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
        WHERE m.EndedAt IS NULL
          AND ((f.ContainerId IS NOT NULL AND m.ContainerId = f.ContainerId)
            OR (f.ContainerId IS NULL     AND m.LotId = f.LotId))
    ) om
);
GO
