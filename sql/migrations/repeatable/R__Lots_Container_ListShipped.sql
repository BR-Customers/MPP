-- =============================================
-- Repeatable:  R__Lots_Container_ListShipped.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.3 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - LOT volume: the window's containers first (seek IX_Container_CompletedAt), serial counts aggregated once over that set instead of per-row correlated counts. Same rows, columns, order.
-- Version:     1.2 (2026-11-04, container-as-LOT spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md) - D8: reads the container's finished-good LOT(s) in BOTH shapes through Lots.ufn_ContainerLots / ufn_LotContainers.
-- Version:     1.1
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
--
--              v1.1 (super-lot piece 6): repack columns LAST, same meaning as
--              Lots.Container_GetTraceDetail v1.1 (ReplacedSerial .. ReworkOpenedByInitials, then
--              ScrappedSerialCount / MovedOutSerialCount / MovedInSerialCount). NULL / 0 when untouched.
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

    -- LOT volume (2026-11-04): the window's containers first (seek IX_Container_CompletedAt),
    -- then the serial counts aggregated once over that set. The old per-row correlated
    -- counts spooled into worktables (22M page reads for a 30-day list at a year of
    -- volume). Same rows, same columns, same order.
    DECLARE @C TABLE (Id BIGINT NOT NULL PRIMARY KEY);
    INSERT INTO @C (Id)
    SELECT c.Id
    FROM Lots.Container c
    INNER JOIN Parts.Item i ON i.Id = c.ItemId
    WHERE c.ContainerStatusCodeId IN (2, 3)    -- 2 Complete, 3 Shipped: see header
      AND c.CompletedAt IS NOT NULL            -- closed is the observable end state
      AND (@FromUtc IS NULL OR c.CompletedAt >= @FromUtc)
      AND (@ToUtc   IS NULL OR c.CompletedAt <  @ToUtc)
      AND (@P       IS NULL OR i.PartNumber LIKE @P)
    OPTION (RECOMPILE);

    DECLARE @Agg TABLE (ContainerId BIGINT NOT NULL PRIMARY KEY, Pieces INT NULL, SourceLots INT NOT NULL);
    INSERT INTO @Agg (ContainerId, Pieces, SourceLots)
    SELECT x.Id,
           (SELECT SUM(ct.PartsClosedCount) FROM Lots.ContainerTray ct WHERE ct.ContainerId = x.Id),
           (SELECT COUNT(*) FROM (
                SELECT ct.FinishedGoodLotId AS LotId FROM Lots.ContainerTray ct
                WHERE ct.ContainerId = x.Id AND ct.FinishedGoodLotId IS NOT NULL      -- 0119 old shape
                UNION
                SELECT c2.LotId FROM Lots.Container c2 WHERE c2.Id = x.Id AND c2.LotId IS NOT NULL   -- new shape
                UNION
                SELECT sp.ProducingLotId FROM Lots.ContainerSerial cs
                INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
                WHERE cs.ContainerId = x.Id) u)
    FROM @C x
    OPTION (RECOMPILE);

    DECLARE @Scrapped TABLE (ContainerId BIGINT NOT NULL PRIMARY KEY, N INT NOT NULL);
    INSERT INTO @Scrapped (ContainerId, N)
    SELECT cs.ContainerId, COUNT(*) FROM @C x INNER JOIN Lots.ContainerSerial cs ON cs.ContainerId = x.Id
    WHERE cs.RemovedAt IS NOT NULL GROUP BY cs.ContainerId;

    DECLARE @MovedOut TABLE (ContainerId BIGINT NOT NULL PRIMARY KEY, N INT NOT NULL);
    INSERT INTO @MovedOut (ContainerId, N)
    SELECT h.OldContainerId, COUNT(DISTINCT h.ContainerSerialId)
    FROM @C x
    INNER JOIN Lots.ContainerSerialHistory h ON h.OldContainerId = x.Id
    INNER JOIN Lots.ContainerSerial cs ON cs.Id = h.ContainerSerialId
    WHERE h.NewContainerId <> x.Id AND cs.ContainerId <> x.Id
    GROUP BY h.OldContainerId;

    DECLARE @MovedIn TABLE (ContainerId BIGINT NOT NULL PRIMARY KEY, N INT NOT NULL);
    INSERT INTO @MovedIn (ContainerId, N)
    SELECT h.NewContainerId, COUNT(DISTINCT h.ContainerSerialId)
    FROM @C x
    INNER JOIN Lots.ContainerSerialHistory h ON h.NewContainerId = x.Id
    INNER JOIN Lots.ContainerSerial cs ON cs.Id = h.ContainerSerialId
    WHERE h.OldContainerId <> x.Id AND cs.ContainerId = x.Id
    GROUP BY h.NewContainerId;

    SELECT
        c.Id                 AS ContainerId,
        i.PartNumber         AS ItemPartNumber,
        lbl.AimShipperId,
        ISNULL(ag.Pieces, 0)          AS PieceCount,
        ISNULL(ag.SourceLots, 0)      AS SourceLotCount,
        CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CompletedAt,
        loc.Name             AS CurrentLocationName,
        rwk.OriginalAimShipperId AS ReplacedSerial,
        CAST(rwk.VoidedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReplacedSerialVoidedAt,
        CAST(rwk.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReworkOpenedAt,
        rwk.Initials AS ReworkOpenedByInitials,
        ISNULL(sx.N, 0) AS ScrappedSerialCount,
        ISNULL(mo.N, 0) AS MovedOutSerialCount,
        ISNULL(mi.N, 0) AS MovedInSerialCount
    FROM @C x
    INNER JOIN Lots.Container c ON c.Id = x.Id
    INNER JOIN Parts.Item i ON i.Id = c.ItemId
    LEFT  JOIN Location.Location loc ON loc.Id = c.CurrentLocationId
    LEFT  JOIN @Scrapped sx ON sx.ContainerId = c.Id
    LEFT  JOIN @MovedOut mo ON mo.ContainerId = c.Id
    LEFT  JOIN @MovedIn  mi ON mi.ContainerId = c.Id
    LEFT  JOIN @Agg ag ON ag.ContainerId = c.Id
    OUTER APPLY (
        SELECT TOP (1) sl.AimShipperId
        FROM Lots.ShippingLabel sl
        WHERE sl.ContainerId = c.Id AND sl.IsVoid = 0
        ORDER BY sl.CreatedAt DESC, sl.Id DESC
    ) lbl
    OUTER APPLY (
        SELECT TOP (1) rw.OpenedAt, rw.OriginalAimShipperId, ap.VoidedAt, u.Initials
        FROM Lots.ContainerRework rw
        LEFT JOIN Lots.AimShipperIdPool ap ON ap.AimShipperId = rw.OriginalAimShipperId
        LEFT JOIN Location.AppUser      u  ON u.Id = rw.OpenedByUserId
        WHERE rw.ContainerId = c.Id
        ORDER BY rw.OpenedAt DESC, rw.Id DESC
    ) rwk
    ORDER BY c.CompletedAt DESC, c.Id DESC
    OPTION (RECOMPILE);   -- the window's real size, so per-container seeks beat scan + spool
END
GO
