-- =============================================
-- Repeatable:  R__Lots_Container_ListShipped.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-011 Shipping History -- shipped containers over a date
--              range, for Honda ASN reconciliation.
--
--              RANGED ON Lots.Container.CompletedAt (container CLOSE time), NOT
--              a ship timestamp. There is no ship timestamp in the schema and
--              -- per Jacques, 2026-08-25 -- there is no integration with MPP's
--              actual shipping information and no future phase that adds one.
--              Closure time is therefore not a degraded proxy: it is the
--              ceiling of what this system can ever know. The column is named
--              CompletedAt and the report labels it "Completed" so no reader
--              infers truck-departure time.
--
--              SCOPE IS CLOSED CONTAINERS (status 2 Complete or 3 Shipped),
--              NOT status 3 alone. Corrected 2026-08-26.
--
--              The original scope assumed "status still distinguishes shipped
--              from merely complete." It does not, and never will. Per Jacques
--              (2026-08-26) there will never be a Shipped flag in practice --
--              MPP ships through their own infrastructure and MES is never told.
--              Nothing outside the Shipping Dock's Ship button sets status 3,
--              and that step is itself under review for removal. Scoping on it
--              made this report return ZERO ROWS FOREVER: not empty because
--              nothing shipped, but empty because the gate can never open. Dev
--              held 5 closed containers, every one carrying a live AIM shipper
--              ID, and the report showed none of them.
--
--              The same reasoning the header already applied to the TIMESTAMP
--              applies to the SCOPE: closure is the ceiling of what this system
--              can ever know, so closure is what the report is built on. A
--              container that is closed is as far as MES can follow it.
--
--              The AIM shipper ID comes from an OUTER APPLY, so a container that
--              closed WITHOUT a label still appears, with a blank shipper ID.
--              That is deliberate: a closed container with no AIM ID is a
--              reconciliation gap, and hiding it would hide the problem the
--              report exists to surface.
--
--              Status 3 stays in scope so that if the Ship step survives, those
--              containers keep appearing rather than silently dropping out.
--
--              One result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Lots.Container_ListShipped
    @FromEt         DATE          = NULL,
    @ToEt           DATE          = NULL,
    @PartNumberLike NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @P NVARCHAR(120) = CASE
        WHEN @PartNumberLike IS NULL OR LTRIM(RTRIM(@PartNumberLike)) = N'' THEN NULL
        ELSE N'%' + LTRIM(RTRIM(@PartNumberLike)) + N'%' END;

    DECLARE @FromUtc DATETIME2(3) = NULL, @ToUtc DATETIME2(3) = NULL;
    IF @FromEt IS NOT NULL
        SET @FromUtc = CAST(CAST(@FromEt AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @ToEt IS NOT NULL
        SET @ToUtc = CAST(CAST(DATEADD(DAY, 1, @ToEt) AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    SELECT
        c.Id                 AS ContainerId,
        i.PartNumber         AS ItemPartNumber,
        lbl.AimShipperId,
        ISNULL(tray.PieceCount, 0)    AS PieceCount,
        ISNULL(src.SourceLotCount, 0) AS SourceLotCount,
        CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt,
        loc.Name             AS CurrentLocationName
    FROM Lots.Container c
    INNER JOIN Parts.Item i ON i.Id = c.ItemId
    LEFT  JOIN Location.Location loc ON loc.Id = c.CurrentLocationId
    OUTER APPLY (
        SELECT SUM(ct.PartsClosedCount) AS PieceCount
        FROM Lots.ContainerTray ct WHERE ct.ContainerId = c.Id
    ) tray
    OUTER APPLY (
        SELECT COUNT(*) AS SourceLotCount FROM (
            SELECT ct.FinishedGoodLotId AS LotId
            FROM Lots.ContainerTray ct
            WHERE ct.ContainerId = c.Id AND ct.FinishedGoodLotId IS NOT NULL
            UNION
            SELECT sp.ProducingLotId
            FROM Lots.ContainerSerial cs
            INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
            WHERE cs.ContainerId = c.Id
        ) u
    ) src
    OUTER APPLY (
        SELECT TOP (1) sl.AimShipperId
        FROM Lots.ShippingLabel sl
        WHERE sl.ContainerId = c.Id AND sl.IsVoid = 0
        ORDER BY sl.CreatedAt DESC, sl.Id DESC
    ) lbl
    WHERE c.ContainerStatusCodeId IN (2, 3)    -- 2 Complete, 3 Shipped: see header
      AND c.CompletedAt IS NOT NULL            -- closed is the observable end state
      AND (@FromUtc IS NULL OR c.CompletedAt >= @FromUtc)
      AND (@ToUtc   IS NULL OR c.CompletedAt <  @ToUtc)
      AND (@P       IS NULL OR i.PartNumber LIKE @P)
    ORDER BY c.CompletedAt DESC, c.Id DESC;
END
GO
