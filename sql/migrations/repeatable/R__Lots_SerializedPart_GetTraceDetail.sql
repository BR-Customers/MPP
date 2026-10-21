-- =============================================
-- Repeatable:  R__Lots_SerializedPart_GetTraceDetail.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.1
-- Description: FDS-12-002 Serialized Item Search payload, rendered as a detail
--              panel on Global Trace. One result set (FDS-11-011); empty set
--              means the serial is unknown -- no invented 404.
--
--              CompletedAt is Lots.Container.CompletedAt -- container CLOSE
--              time. The schema has NO ship timestamp (design spec 2.5); the
--              view labels this column "Completed", never "Ship date".
--              Do not rename it to anything containing "Ship".
--
--              Sibling read: Lots.SerializedPart_GetBySerial is retained
--              unchanged for its existing callers (narrower contract).
--
--              v1.1 (super-lot piece 6): RemovedAt (ET) / RemovedReason ('Scrapped (<defect>)')
--              from ContainerSerial.RemovedAt / RemovedRejectEventId -- the row is KEPT, never
--              filtered; MovedInFromContainerName = source container of the latest repack move
--              into the current container. New columns LAST; NULL when untouched.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.SerializedPart_GetTraceDetail
    @SerialNumber NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sp.SerialNumber,
        sp.ItemId,
        i.PartNumber AS ItemPartNumber,
        sp.ProducingLotId,
        l.LotName    AS ProducingLotName,
        CAST(sp.EtchedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EtchedAt,
        CAST(pe.EventAt  AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ProducedAt,
        op.DisplayName   AS OperatorName,
        term.Name        AS MachineName,
        cs.ContainerId,
        csc.Code         AS ContainerStatusCode,
        lbl.AimShipperId,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt,
        CAST(cs.RemovedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RemovedAt,
        CASE WHEN cs.RemovedAt IS NULL THEN NULL
             ELSE N'Scrapped (' + ISNULL(dc.Description, N'no defect') + N')' END AS RemovedReason,
        CAST(mv.OldContainerId AS NVARCHAR(50)) AS MovedInFromContainerName
    FROM Lots.SerializedPart sp
    INNER JOIN Parts.Item i ON i.Id = sp.ItemId
    INNER JOIN Lots.Lot   l ON l.Id = sp.ProducingLotId
    OUTER APPLY (
        SELECT TOP (1) pe2.EventAt, pe2.AppUserId, pe2.TerminalLocationId
        FROM Workorder.ProductionEvent pe2
        WHERE pe2.LotId = sp.ProducingLotId
        ORDER BY pe2.EventAt DESC, pe2.Id DESC
    ) pe
    LEFT JOIN Location.AppUser  op   ON op.Id   = pe.AppUserId
    LEFT JOIN Location.Location term ON term.Id = pe.TerminalLocationId
    LEFT JOIN Lots.ContainerSerial cs ON cs.SerializedPartId = sp.Id
    LEFT JOIN Workorder.RejectEvent re ON re.Id = cs.RemovedRejectEventId
    LEFT JOIN Quality.DefectCode    dc ON dc.Id = re.DefectCodeId
    OUTER APPLY (
        SELECT TOP (1) h.OldContainerId
        FROM Lots.ContainerSerialHistory h
        WHERE h.ContainerSerialId = cs.Id AND h.NewContainerId = cs.ContainerId AND h.OldContainerId <> cs.ContainerId
        ORDER BY h.MigratedAt DESC, h.Id DESC
    ) mv
    LEFT JOIN Lots.Container       c  ON c.Id  = cs.ContainerId
    LEFT JOIN Lots.ContainerStatusCode csc ON csc.Id = c.ContainerStatusCodeId
    OUTER APPLY (
        SELECT TOP (1) sl.AimShipperId
        FROM Lots.ShippingLabel sl
        WHERE sl.ContainerId = cs.ContainerId AND sl.IsVoid = 0
        ORDER BY sl.CreatedAt DESC, sl.Id DESC
    ) lbl
    WHERE sp.SerialNumber = @SerialNumber;
END
GO
