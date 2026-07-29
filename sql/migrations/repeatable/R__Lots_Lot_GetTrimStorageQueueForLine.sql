-- ============================================================
-- Repeatable:  R__Lots_Lot_GetTrimStorageQueueForLine.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Machining IN queue read under the Trim-Storage model (2026-07-23). Trim OUT
--              deposits every trimmed LOT into a neutral per-shop Trim Storage
--              (InventoryLocation def 14 under a TRIM* ProductionArea); the machining line
--              is no longer chosen at Trim. This proc returns, for ONE machining line, the
--              open LOTs sitting in ANY trim storage whose next-pending route step is
--              MachiningIn AND whose Item is ELIGIBLE at that line (ancestor cascade). A part
--              eligible at two lines appears in both lines' reads; the first claim moves it
--              onto its line (MachiningIn_RecordPick) and it drops off the others.
--
--              Same column shape as Lots.Lot_GetWipQueueByLocation v3.0 so the view row
--              transform is unchanged. Read proc: no OUTPUT params, single result set,
--              empty set = nothing to show (FDS-11-011). Pending logic mirrors the WIP
--              queue (Advance pending until a matching ProductionEvent; ConsumeMint always
--              pending while open; OriginMint never pending). FIFO by arrival.
--
--              @StorageLocationId NULL => all trim-storage locations (both shops); pass an
--              explicit id to restrict to one shop's storage.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetTrimStorageQueueForLine
    @LineLocationId    BIGINT,
    @StorageLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH TrimStores AS (
        SELECT s.Id
        FROM Location.Location s
        WHERE s.DeprecatedAt IS NULL
          AND ( (@StorageLocationId IS NOT NULL AND s.Id = @StorageLocationId)
                OR (@StorageLocationId IS NULL
                    AND s.LocationTypeDefinitionId = 14   -- InventoryLocation
                    AND EXISTS (SELECT 1 FROM Location.Location a
                                WHERE a.Id = s.ParentLocationId AND a.Code LIKE N'TRIM%')) )
    ),
    LineAncestors AS (
        SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LineLocationId)
    ),
    LastMove AS (
        SELECT m.LotId, MAX(m.MovedAt) AS LastMovementAt FROM Lots.LotMovement m GROUP BY m.LotId
    ),
    NextStep AS (
        SELECT l.Id AS LotId, rs.SequenceNumber, rs.OperationTemplateId,
               ROW_NUMBER() OVER (PARTITION BY l.Id ORDER BY rs.SequenceNumber ASC) AS rn
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
        INNER JOIN Parts.RouteTemplate rt ON rt.ItemId = l.ItemId AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
        INNER JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
        INNER JOIN Parts.OperationTemplate ot2 ON ot2.Id = rs.OperationTemplateId
        INNER JOIN Parts.OperationType oty2    ON oty2.Id = ot2.OperationTypeId
        INNER JOIN Parts.OperationRoleKind rk  ON rk.Id  = oty2.OperationRoleKindId
        WHERE l.CurrentLocationId IN (SELECT Id FROM TrimStores)
          AND ( rk.Code = N'ConsumeMint'
             OR (rk.Code = N'Advance' AND NOT EXISTS (
                    SELECT 1 FROM Workorder.ProductionEvent pe
                    WHERE pe.LotId = l.Id AND pe.OperationTemplateId = rs.OperationTemplateId)) )
    )
    SELECT
        l.Id, l.LotName, l.ItemId,
        i.PartNumber  AS ItemPartNumber,
        i.Description AS ItemDescription,
        l.PieceCount, l.LotStatusId, sc.Code AS LotStatusCode,
        CAST(lm.LastMovementAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS LastMovementAt,
        oty.Code AS NextOperationTypeCode,
        ns.SequenceNumber AS NextSequenceNumber
    FROM NextStep ns
    INNER JOIN Lots.Lot l               ON l.Id = ns.LotId AND ns.rn = 1
    INNER JOIN Lots.LotStatusCode sc    ON sc.Id = l.LotStatusId
    INNER JOIN Parts.Item i             ON i.Id  = l.ItemId
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = ns.OperationTemplateId
    INNER JOIN Parts.OperationType oty  ON oty.Id = ot.OperationTypeId
    LEFT  JOIN LastMove lm              ON lm.LotId = l.Id
    WHERE oty.Code = N'MachiningIn'
      AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation eil
                  WHERE eil.ItemId = l.ItemId AND eil.LocationId IN (SELECT LocationId FROM LineAncestors))
    ORDER BY lm.LastMovementAt ASC, l.Id ASC;
END;
GO
