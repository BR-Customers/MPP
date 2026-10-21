-- =============================================
-- Repeatable:  R__Lots_Container_ListSerials.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.3
-- Description: Sibling read to Lots.Container_GetTraceDetail -- the container's
--              serialized parts, in tray-position order. A SEPARATE proc
--              because one proc returns one result set (FDS-11-011); the
--              detail proc surfaces the count, this returns the rows.
--              Empty set when the container is unknown or carries no serials.
--
--              v1.1 (super-lot piece 6): @IncludeRemoved BIT = 0. At 0 (default)
--              behaviour is unchanged: a serial scrapped out of the container in a
--              repack (0111) is hidden. At 1 the trace panel also gets the removed
--              ones -- scrapped serials still on the container row, and serials
--              moved OUT to another container -- marked, never silently dropped.
--              New columns LAST (always present, NULL when packed): RemovedAt (ET),
--              RemovedReason ('Scrapped (<defect>)' / 'Moved to container <Id>'),
--              MovedInFromContainerName (source container Id of the latest
--              move of this serial INTO this container), MovedInAt (ET, when that move
--              happened; NULL when not moved in). v1.2 added MovedInAt. Moves are any
--              Lots.ContainerSerialHistory row: a repack OR a Sort Cage migration.
--
--              v1.3 (final review): the rows are drawn from a candidate set -- the
--              container's own ContainerSerial rows UNION (at @IncludeRemoved = 1) the
--              serials whose history shows a move OUT of it (ContainerSerialHistory
--              WHERE OldContainerId = @ContainerId, a seek on IX_CSH_OldContainer,
--              migration 0114) -- instead of an OR over every ContainerSerial row.
--              The outer WHERE is unchanged, so the result is identical.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Container_ListSerials
    @ContainerId    BIGINT,
    @IncludeRemoved BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sp.Id AS SerializedPartId,
        sp.SerialNumber,
        cs.TrayPosition,
        sp.ProducingLotId,
        l.LotName AS ProducingLotName,
        CAST(x.RemovedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RemovedAt,
        x.RemovedReason,
        CAST(mv.OldContainerId AS NVARCHAR(50)) AS MovedInFromContainerName,
        CAST(mv.MigratedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS MovedInAt
    FROM (
        SELECT c.Id
        FROM Lots.ContainerSerial c
        WHERE c.ContainerId = @ContainerId AND (c.RemovedAt IS NULL OR @IncludeRemoved = 1)
        UNION
        SELECT h.ContainerSerialId
        FROM Lots.ContainerSerialHistory h
        WHERE @IncludeRemoved = 1 AND h.OldContainerId = @ContainerId AND h.NewContainerId <> @ContainerId
    ) cand
    INNER JOIN Lots.ContainerSerial cs ON cs.Id = cand.Id
    INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
    INNER JOIN Lots.Lot            l  ON l.Id  = sp.ProducingLotId
    LEFT JOIN Workorder.RejectEvent re ON re.Id = cs.RemovedRejectEventId
    LEFT JOIN Quality.DefectCode    dc ON dc.Id = re.DefectCodeId
    OUTER APPLY (
        SELECT TOP (1) h.NewContainerId, h.MigratedAt
        FROM Lots.ContainerSerialHistory h
        WHERE h.ContainerSerialId = cs.Id AND h.OldContainerId = @ContainerId AND h.NewContainerId <> @ContainerId
        ORDER BY h.MigratedAt DESC, h.Id DESC
    ) mo
    OUTER APPLY (
        SELECT TOP (1) h.OldContainerId, h.MigratedAt
        FROM Lots.ContainerSerialHistory h
        WHERE h.ContainerSerialId = cs.Id AND h.NewContainerId = @ContainerId AND h.OldContainerId <> @ContainerId
        ORDER BY h.MigratedAt DESC, h.Id DESC
    ) mv
    CROSS APPLY (
        SELECT CASE WHEN cs.ContainerId = @ContainerId THEN cs.RemovedAt ELSE mo.MigratedAt END AS RemovedAt,
               CASE WHEN cs.ContainerId = @ContainerId AND cs.RemovedAt IS NOT NULL
                         THEN CAST(N'Scrapped (' + ISNULL(dc.Description, N'no defect') + N')' AS NVARCHAR(500))
                    WHEN cs.ContainerId <> @ContainerId AND mo.NewContainerId IS NOT NULL
                         THEN CAST(N'Moved to container ' + CAST(mo.NewContainerId AS NVARCHAR(20)) AS NVARCHAR(500)) END AS RemovedReason
    ) x
    WHERE ( (cs.ContainerId = @ContainerId AND (cs.RemovedAt IS NULL OR @IncludeRemoved = 1))   -- 0111: scrapped out in a repack
         OR (@IncludeRemoved = 1 AND cs.ContainerId <> @ContainerId AND mo.NewContainerId IS NOT NULL) )
    ORDER BY cs.TrayPosition, sp.SerialNumber;
END
GO
