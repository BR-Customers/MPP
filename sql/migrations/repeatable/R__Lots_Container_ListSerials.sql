-- =============================================
-- Repeatable:  R__Lots_Container_ListSerials.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: Sibling read to Lots.Container_GetTraceDetail -- the container's
--              serialized parts, in tray-position order. A SEPARATE proc
--              because one proc returns one result set (FDS-11-011); the
--              detail proc surfaces the count, this returns the rows.
--              Empty set when the container is unknown or carries no serials.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Container_ListSerials
    @ContainerId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sp.Id AS SerializedPartId,
        sp.SerialNumber,
        cs.TrayPosition,
        sp.ProducingLotId,
        l.LotName AS ProducingLotName
    FROM Lots.ContainerSerial cs
    INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
    INNER JOIN Lots.Lot            l  ON l.Id  = sp.ProducingLotId
    WHERE cs.ContainerId = @ContainerId
    ORDER BY cs.TrayPosition, sp.SerialNumber;
END
GO
