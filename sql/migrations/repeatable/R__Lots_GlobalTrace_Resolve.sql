-- ============================================================
-- Repeatable:  R__Lots_GlobalTrace_Resolve.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-12-001/012/013). Global Trace entry point:
--              maps ONE scanned/typed identifier to candidate LOT rows. The
--              Global Trace view then composes the full read-only trace from
--              the existing per-stream reads (Lot_Get, Lot_GetAttributeHistory,
--              Lot_GetGenealogyTree, ProductionEvent_ListByLot,
--              Lot_GetScrapSummary) -- recon spec delta 2 dropped the
--              multi-result-set GetFullTrace (FDS-11-011: one result set).
--
--              Match logic (exact matches first, then LIKE prefix on LotName):
--                1. Lots.Lot by LotName (exact)         -> MatchType 'Lot'
--                2. Lots.SerializedPart by SerialNumber -> 'Serial'
--                   (LotId = ProducingLotId)
--                3. Lots.Container by Id (all-numeric input) -> 'Container';
--                   expands to the container's source LOTs: DISTINCT of
--                   ContainerTray.FinishedGoodLotId (tray=LOT, 0034) UNION
--                   ContainerSerial -> SerializedPart.ProducingLotId
--                4. Lots.ShippingLabel by AimShipperId  -> 'Shipper';
--                   same source-LOT expansion on its container
--                5. Lots.Lot by LotName LIKE prefix (excluding the exact hit)
--              Multiple rows = the FDS-12-013 disambiguation list. Capped at
--              50 rows.
--
--              Result set: MatchType, MatchedEntityId, LotId, LotName,
--              ItemPartNumber, Detail.
--
--              READ proc: no status row, no OUTPUT params (FDS-11-011).
--              Empty/blank input or no match = empty result set.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.GlobalTrace_Resolve
    @SearchText NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Search NVARCHAR(100) = LTRIM(RTRIM(@SearchText));

    IF @Search IS NULL OR @Search = N''
    BEGIN
        SELECT CAST(NULL AS NVARCHAR(20))  AS MatchType,
               CAST(NULL AS BIGINT)        AS MatchedEntityId,
               CAST(NULL AS BIGINT)        AS LotId,
               CAST(NULL AS NVARCHAR(50))  AS LotName,
               CAST(NULL AS NVARCHAR(50))  AS ItemPartNumber,
               CAST(NULL AS NVARCHAR(200)) AS Detail
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @ContainerId BIGINT = TRY_CONVERT(BIGINT, @Search);

    SELECT TOP (50)
        x.MatchType, x.MatchedEntityId, x.LotId, x.LotName, x.ItemPartNumber, x.Detail
    FROM (
        -- 1. Exact LOT name
        SELECT 1 AS MatchRank, N'Lot' AS MatchType, l.Id AS MatchedEntityId,
               l.Id AS LotId, l.LotName, i.PartNumber AS ItemPartNumber,
               CAST(sc.Code + N' at ' + loc.Name AS NVARCHAR(200)) AS Detail
        FROM Lots.Lot l
        INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
        INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
        INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
        WHERE l.LotName = @Search

        UNION ALL

        -- 2. Serial number -> producing LOT
        SELECT 2, N'Serial', sp.Id,
               l.Id, l.LotName, i.PartNumber,
               CAST(N'Serial ' + sp.SerialNumber + N' -> producing LOT' AS NVARCHAR(200))
        FROM Lots.SerializedPart sp
        INNER JOIN Lots.Lot   l ON l.Id = sp.ProducingLotId
        INNER JOIN Parts.Item i ON i.Id = l.ItemId
        WHERE sp.SerialNumber = @Search

        UNION ALL

        -- 3. Container id (numeric input) -> DISTINCT source LOTs
        --    (ContainerTray.FinishedGoodLotId UNION ContainerSerial->ProducingLotId)
        SELECT DISTINCT 3, N'Container', c.Id,
               l.Id, l.LotName, i.PartNumber,
               CAST(N'Container ' + CAST(c.Id AS NVARCHAR(20)) + N' source LOT' AS NVARCHAR(200))
        FROM Lots.Container c
        CROSS APPLY (
            SELECT ct.FinishedGoodLotId AS SrcLotId
            FROM Lots.ContainerTray ct
            WHERE ct.ContainerId = c.Id AND ct.FinishedGoodLotId IS NOT NULL
            UNION
            SELECT sp.ProducingLotId
            FROM Lots.ContainerSerial cs
            INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
            WHERE cs.ContainerId = c.Id
        ) src
        INNER JOIN Lots.Lot   l ON l.Id = src.SrcLotId
        INNER JOIN Parts.Item i ON i.Id = l.ItemId
        WHERE @ContainerId IS NOT NULL AND c.Id = @ContainerId

        UNION ALL

        -- 4. AIM shipper id -> its container's source LOTs (same expansion)
        SELECT DISTINCT 4, N'Shipper', sl.Id,
               l.Id, l.LotName, i.PartNumber,
               CAST(N'Shipper ' + sl.AimShipperId + N' container ' + CAST(sl.ContainerId AS NVARCHAR(20)) AS NVARCHAR(200))
        FROM Lots.ShippingLabel sl
        CROSS APPLY (
            SELECT ct.FinishedGoodLotId AS SrcLotId
            FROM Lots.ContainerTray ct
            WHERE ct.ContainerId = sl.ContainerId AND ct.FinishedGoodLotId IS NOT NULL
            UNION
            SELECT sp.ProducingLotId
            FROM Lots.ContainerSerial cs
            INNER JOIN Lots.SerializedPart sp ON sp.Id = cs.SerializedPartId
            WHERE cs.ContainerId = sl.ContainerId
        ) src
        INNER JOIN Lots.Lot   l ON l.Id = src.SrcLotId
        INNER JOIN Parts.Item i ON i.Id = l.ItemId
        WHERE sl.AimShipperId = @Search

        UNION ALL

        -- 5. LOT name prefix (disambiguation list; exact hit excluded)
        SELECT 5, N'Lot', l.Id,
               l.Id, l.LotName, i.PartNumber,
               CAST(sc.Code + N' at ' + loc.Name AS NVARCHAR(200))
        FROM Lots.Lot l
        INNER JOIN Parts.Item         i   ON i.Id   = l.ItemId
        INNER JOIN Lots.LotStatusCode sc  ON sc.Id  = l.LotStatusId
        INNER JOIN Location.Location  loc ON loc.Id = l.CurrentLocationId
        WHERE l.LotName LIKE @Search + N'%' AND l.LotName <> @Search
    ) x
    ORDER BY x.MatchRank, x.LotName, x.LotId;
END;
GO
