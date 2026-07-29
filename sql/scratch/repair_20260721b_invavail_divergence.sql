-- ============================================================
-- One-off repair:  repair_20260721b_invavail_divergence.sql
-- Target DB:       MPP_MES_Dev  (surgical row edit only; NOT reset/rebuilt)
-- Author:          Blue Ridge Automation
-- Purpose:         Clean up the InventoryAvailable > PieceCount divergence created by
--                  the pre-fix TrimOut_Record (scrap decremented PieceCount but not
--                  InventoryAvailable). Two lots affected (2026-07-21):
--                    * 000000008 (Id 197, 5G0-c): PieceCount -4 / InvAvail 0 -- already
--                      over-consumed by MachiningOut. Depleted -> PieceCount 0 + Close.
--                    * 000000011 (Id 212, 12232-59B): PieceCount 32 / InvAvail 36 -- still
--                      has 32 real pieces; only InvAvail is inflated. Clamp InvAvail = 32,
--                      keep it Good/open.
--                  General form (idempotent, catches any other affected row):
--                    (1) any PieceCount < 0  -> PieceCount = 0
--                    (2) any InventoryAvailable > PieceCount -> InventoryAvailable = PieceCount
--                    (3) any casting driven to 0 by (1) that is still Good -> Close it.
--                  Re-running is a no-op once every row satisfies 0 <= InvAvail <= PieceCount.
--                  FK-safe: no DELETEs. Writes a LotStatusHistory row for each Close.
-- ============================================================
USE MPP_MES_Dev;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Reason NVARCHAR(200) = N'Data repair 2026-07-21b: depleted casting closed after InvAvail>PieceCount over-consumption (pre-fix TrimOut divergence).';

PRINT '=== BEFORE (rows violating 0 <= InvAvail <= PieceCount) ===';
SELECT l.Id, l.LotName, i.PartNumber, l.PieceCount, l.InventoryAvailable, sc.Code AS Status
FROM Lots.Lot l JOIN Parts.Item i ON i.Id = l.ItemId JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.PieceCount < 0 OR l.InventoryAvailable < 0 OR l.InventoryAvailable > l.PieceCount
ORDER BY l.Id;

BEGIN TRANSACTION;

    -- Snapshot the lots we will drive to PieceCount 0 from a negative, still open (for the Close step).
    DECLARE @ToClose TABLE (LotId BIGINT PRIMARY KEY, OldStatusId BIGINT);
    INSERT INTO @ToClose (LotId, OldStatusId)
    SELECT l.Id, l.LotStatusId
    FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.PieceCount < 0 AND sc.Code <> N'Closed';

    -- (1) Floor negative PieceCount at 0.
    UPDATE Lots.Lot
    SET PieceCount = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @Dev
    WHERE PieceCount < 0;

    -- (2) Clamp InventoryAvailable into [0, PieceCount] (fixes the 212 inflation + any negatives).
    UPDATE Lots.Lot
    SET InventoryAvailable = CASE WHEN InventoryAvailable < 0 THEN 0
                                  WHEN InventoryAvailable > PieceCount THEN PieceCount
                                  ELSE InventoryAvailable END,
        UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @Dev
    WHERE InventoryAvailable < 0 OR InventoryAvailable > PieceCount;

    -- (3) Close the castings that were negative and are now depleted at 0.
    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    SELECT c.LotId, c.OldStatusId, @Closed, @Reason, @Dev, NULL, SYSUTCDATETIME()
    FROM @ToClose c;

    UPDATE l
    SET l.LotStatusId = @Closed
    FROM Lots.Lot l JOIN @ToClose c ON c.LotId = l.Id;

COMMIT TRANSACTION;

PRINT '=== AFTER (the affected lots) ===';
SELECT l.Id, l.LotName, i.PartNumber, l.PieceCount, l.InventoryAvailable, sc.Code AS Status
FROM Lots.Lot l JOIN Parts.Item i ON i.Id = l.ItemId JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.Id IN (SELECT LotId FROM @ToClose) OR l.Id IN (197, 212)
ORDER BY l.Id;

DECLARE @Remaining INT = (SELECT COUNT(*) FROM Lots.Lot WHERE PieceCount < 0 OR InventoryAvailable < 0 OR InventoryAvailable > PieceCount);
PRINT '=== Remaining lots violating 0 <= InvAvail <= PieceCount: ' + CAST(@Remaining AS NVARCHAR(10)) + ' (expect 0) ===';
GO
