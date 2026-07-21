-- ============================================================
-- One-off repair:  repair_20260721_negative_castings.sql
-- Target DB:       MPP_MES_Dev  (NOT reset/rebuilt -- surgical row edit only)
-- Author:          Blue Ridge Automation
-- Purpose:         Zero out castings driven NEGATIVE by the old un-bounded
--                  Machining-OUT decrement (pre multi-source FIFO fix, commit
--                  6b27a619). Confirmed target state (Jacques, 2026-07-21):
--                    * NO sublots are phantom -- nothing is deleted/voided.
--                    * The negative castings are simply DEPLETED: set
--                      PieceCount = 0 and InventoryAvailable = 0 (a casting's
--                      InventoryAvailable must equal PieceCount; 000000007 had
--                      a stray InvAvail=5 against PieceCount=-2), and Close them.
--                    * Ensure NO Lot in the DB has a negative PieceCount or
--                      InventoryAvailable (general sweep, not just the two known).
--
--                  Idempotent: re-running is a no-op once every count is >= 0.
--                  FK-safe: no DELETEs (nothing phantom). Writes a LotStatusHistory
--                  row for each Good->Closed transition. Prints before/after.
-- ============================================================
USE MPP_MES_Dev;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Dev BIGINT = (SELECT TOP 1 Id FROM Location.AppUser WHERE Initials = N'DEV' ORDER BY Id);
DECLARE @Closed BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');
DECLARE @Reason NVARCHAR(200) = N'Data repair 2026-07-21: zeroed negative count from pre-FIFO-fix over-consumption.';

PRINT '=== BEFORE ===';
SELECT l.Id, l.LotName, i.PartNumber, l.PieceCount, l.InventoryAvailable, sc.Code AS Status
FROM Lots.Lot l
JOIN Parts.Item i ON i.Id = l.ItemId
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.PieceCount < 0 OR l.InventoryAvailable < 0
ORDER BY l.Id;

BEGIN TRANSACTION;

    -- Capture the lots that are being zeroed AND are still open (for the status-history + close step),
    -- BEFORE we mutate their counts.
    DECLARE @Zeroed TABLE (LotId BIGINT PRIMARY KEY, OldStatusId BIGINT, WasOpen BIT);
    INSERT INTO @Zeroed (LotId, OldStatusId, WasOpen)
    SELECT l.Id, l.LotStatusId,
           CASE WHEN sc.Code <> N'Closed' THEN 1 ELSE 0 END
    FROM Lots.Lot l
    JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.PieceCount < 0 OR l.InventoryAvailable < 0;

    -- 1) Zero out any negative counts (general sweep). InventoryAvailable is floored at 0
    --    for every affected casting so PieceCount == InventoryAvailable (casting invariant).
    UPDATE l
    SET l.PieceCount = 0,
        l.InventoryAvailable = 0,
        l.UpdatedAt = SYSUTCDATETIME(),
        l.UpdatedByUserId = @Dev
    FROM Lots.Lot l
    WHERE l.Id IN (SELECT LotId FROM @Zeroed);

    -- 2) Close the now-depleted castings that were still open, with an audit-trail history row.
    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    SELECT z.LotId, z.OldStatusId, @Closed, @Reason, @Dev, NULL, SYSUTCDATETIME()
    FROM @Zeroed z
    WHERE z.WasOpen = 1;

    UPDATE l
    SET l.LotStatusId = @Closed
    FROM Lots.Lot l
    JOIN @Zeroed z ON z.LotId = l.Id
    WHERE z.WasOpen = 1;

COMMIT TRANSACTION;

PRINT '=== AFTER (previously-negative lots) ===';
SELECT l.Id, l.LotName, i.PartNumber, l.PieceCount, l.InventoryAvailable, sc.Code AS Status
FROM Lots.Lot l
JOIN Parts.Item i ON i.Id = l.ItemId
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
WHERE l.Id IN (SELECT LotId FROM @Zeroed)
ORDER BY l.Id;

DECLARE @RemainingNeg INT = (SELECT COUNT(*) FROM Lots.Lot WHERE PieceCount < 0 OR InventoryAvailable < 0);
PRINT '=== Remaining lots with negative PieceCount or InventoryAvailable: ' + CAST(@RemainingNeg AS NVARCHAR(10)) + ' (expect 0) ===';
GO
