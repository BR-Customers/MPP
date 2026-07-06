-- =============================================================
-- smoke_seed_phase4.sql  (DEV AID, one-shot; wiped by Reset-DevDatabase)
-- Seeds data so the Phase 4 plant-floor screens show something on open:
--   * a die-cast LOT created at a Die Cast Cell,
--   * moved to the Trim Shop Area (so Trim Station IN shows it),
--   * a TrimIn checkpoint ProductionEvent written,
--   * TrimOut_Record'd as a 1:1 WHOLE-LOT move into a Machining-line FIFO queue
--     (so Machining IN's queue shows it; Phase 5 picks it).
-- Ends with a SELECT reporting the LOT, its current location, and the Machining
-- queue count.
--
-- Self-contained + idempotent: it seeds its own smoke Item (SMOKE-P4) eligible at
-- a Die Cast Cell (origin point) AND at the Machining-In destination Cell (Direct
-- eligibility, so TrimOut's destination-eligibility check passes), then flows ONE
-- LOT through. Re-runnable: clears the prior SMOKE-P4 LOT first.
-- =============================================================
SET NOCOUNT ON;

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

-- ---- locations ----
DECLARE @DieCastCell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');   -- a Die Cast Cell (machine)
DECLARE @TrimArea    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM1');     -- Trim Shop Area
DECLARE @MachCell    BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR'); -- Machining LINE (line-resident, 2026-07-06)

-- ---- smoke Item + eligibility (origin Cell + Trim Area + Machining destination) ----
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'SMOKE-P4')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (2, N'SMOKE-P4', N'Phase4 smoke cast/trim part', 48, NULL, 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'SMOKE-P4');

INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
SELECT @Item, v.LocId, 0, @Now
FROM (VALUES (@DieCastCell), (@TrimArea), (@MachCell)) v(LocId)
WHERE NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il WHERE il.ItemId = @Item AND il.LocationId = v.LocId AND il.DeprecatedAt IS NULL);

-- ---- clear a prior smoke LOT (re-run safety) ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'SMOKEP4%';
DELETE m  FROM Lots.LotMovement m         INNER JOIN Lots.Lot l ON l.Id = m.LotId  WHERE l.LotName LIKE N'SMOKEP4%';
DELETE h  FROM Lots.LotStatusHistory h    INNER JOIN Lots.Lot l ON l.Id = h.LotId  WHERE l.LotName LIKE N'SMOKEP4%';
DELETE c  FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'SMOKEP4%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'SMOKEP4%';

-- ---- 1. create the die-cast LOT at the Die Cast Cell ----
DECLARE @OriginRcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');  -- non-Manufactured -> no Tool/Cavity required
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create
    @ItemId = @Item, @LotOriginTypeId = @OriginRcv, @CurrentLocationId = @DieCastCell,
    @PieceCount = 48, @AppUserId = 1, @LotName = N'SMOKEP4-001';
DECLARE @Lot BIGINT = (SELECT NewId FROM @cr);

-- ---- 2. move it to the Trim Shop Area (Trim Station IN shows it) ----
DECLARE @mv TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @mv EXEC Lots.Lot_MoveTo @LotId = @Lot, @ToLocationId = @TrimArea, @AppUserId = 1;

-- ---- 3. TrimIn checkpoint ProductionEvent ----
DECLARE @TrimInOt BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimIn');
DECLARE @pe TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @pe EXEC Workorder.ProductionEvent_Record @LotId = @Lot, @OperationTemplateId = @TrimInOt, @ShotCount = 48, @AppUserId = 1;

-- ---- 4. TrimOut: 1:1 whole-LOT move into the Machining-line FIFO queue ----
DECLARE @TrimOutOt BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @to TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @to EXEC Workorder.TrimOut_Record
    @ParentLotId = @Lot, @OperationTemplateId = @TrimOutOt, @ShotCount = 48,
    @DestinationCellLocationId = @MachCell, @SourceLocationId = @TrimArea, @AppUserId = 1;

-- ---- report ----
SELECT
    l.LotName,
    loc.Code  AS CurrentLocationCode,
    loc.Name  AS CurrentLocationName,
    (SELECT COUNT(*) FROM Lots.Lot q
       INNER JOIN Lots.LotStatusCode sc ON sc.Id = q.LotStatusId
       WHERE q.CurrentLocationId = @MachCell AND sc.Code <> N'Closed') AS MachiningQueueCount,
    (SELECT TOP 1 Status FROM @to) AS TrimOutStatus
FROM Lots.Lot l
INNER JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
WHERE l.Id = @Lot;
