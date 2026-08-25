-- ============================================================
-- Repeatable:  R__Lots_ContainerSerial_GetSourceSummary.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: READ proc backing the Sort Cage screen's "Source Container" panel
--              (Arc 2 Phase 7, UJ-05). Given the ContainerSerial the operator
--              scanned, returns the one-row summary the panel's KPIs need:
--              which container the serial sits in, the part, the AIM Shipper ID
--              the container was allocated, and how many serials it currently
--              holds.
--
--              Before this proc the panel had no backing read and rendered the
--              placeholder "Source container summary - no read proc in dev".
--              Lots.ContainerSerial_Get exists but returns bare FK ids only, so it
--              cannot fill the KPI strip.
--
--              AimShipperId is read from Lots.AimShipperIdPool via
--              ConsumedByContainerId -- the pool claim is the authoritative link
--              between a container and its AIM serial. Lots.ShippingLabel also
--              carries an AimShipperId, but a container can have several labels
--              (reprints, voids), so the pool row is the single-valued source.
--
--              READ proc: no @Status/@Message, no status row, one result set.
--              An empty result set means the ContainerSerialId does not exist --
--              no invented 404 (FDS-11-011).
--
-- Result columns:
--   ContainerSerialId, ContainerId, ContainerTrayId, TrayPosition, SerialNumber,
--   ItemId, PartNumber, ItemDescription, AimShipperId, SerialCount, TrayCount,
--   ContainerStatusCode, CurrentLocationId, CurrentLocationName, OpenedAt (ET),
--   CompletedAt (ET)
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.ContainerSerial_GetSourceSummary
    @ContainerSerialId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        cs.Id                AS ContainerSerialId,
        cs.ContainerId       AS ContainerId,
        cs.ContainerTrayId   AS ContainerTrayId,
        cs.TrayPosition      AS TrayPosition,
        sp.SerialNumber      AS SerialNumber,
        c.ItemId             AS ItemId,
        i.PartNumber         AS PartNumber,
        i.Description        AS ItemDescription,
        pool.AimShipperId    AS AimShipperId,
        (SELECT COUNT(*) FROM Lots.ContainerSerial x WHERE x.ContainerId = c.Id) AS SerialCount,
        (SELECT COUNT(*) FROM Lots.ContainerTray   t WHERE t.ContainerId = c.Id) AS TrayCount,
        csc.Code             AS ContainerStatusCode,
        c.CurrentLocationId  AS CurrentLocationId,
        loc.Name             AS CurrentLocationName,
        -- Timestamps are stored UTC and displayed Eastern; convert at the boundary.
        CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt
    FROM Lots.ContainerSerial cs
    INNER JOIN Lots.Container            c   ON c.Id   = cs.ContainerId
    LEFT  JOIN Lots.SerializedPart       sp  ON sp.Id  = cs.SerializedPartId
    LEFT  JOIN Parts.Item                i   ON i.Id   = c.ItemId
    LEFT  JOIN Lots.ContainerStatusCode  csc ON csc.Id = c.ContainerStatusCodeId
    LEFT  JOIN Location.Location         loc ON loc.Id = c.CurrentLocationId
    -- A container claims at most one pool row; TOP 1 guards a historical double-claim
    -- rather than fanning the summary out into duplicate rows.
    OUTER APPLY (SELECT TOP 1 p.AimShipperId
                 FROM Lots.AimShipperIdPool p
                 WHERE p.ConsumedByContainerId = c.Id
                 ORDER BY p.ConsumedAt DESC, p.Id DESC) pool
    WHERE cs.Id = @ContainerSerialId;
END;
GO
