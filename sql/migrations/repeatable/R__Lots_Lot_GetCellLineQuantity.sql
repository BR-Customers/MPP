-- ============================================================
-- Repeatable:  R__Lots_Lot_GetCellLineQuantity.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-11-16
-- Version:     1.1
-- Description: Arc 2 Phase 4 (spec sec 4.1). Sums PieceCount across OPEN LOTs
--              (LotStatusCode <> 'Closed') of @ItemId whose CurrentLocationId =
--              @LocationId. Generic location id (sums at whatever tier the
--              destination is, despite the 'CellLine' name). One row:
--              ExistingPieceCount INT (0 when none). Read proc; no status row.
--              Drives the "N of M capacity" hint in the Movement Scan UI; the
--              authoritative MaxParts cap is enforced in Lot_MoveToValidated.
--
-- Change Log:
--   1.1 (2026-11-16, stored-procedure review) - filtered open LOTs only through
--       the LotStatusCode join, so it could not use the filtered indexes of
--       migration 0118 and read every LOT of the item ever at the location,
--       closed history included. Now also carries the literal
--       l.LotStatusId <> 4 (Closed), which repeats IX_Lot_NotClosed_Location /
--       IX_Lot_NotClosed_Item's filter so the optimiser can seek them; the
--       code-table test beside it still decides. Same row, same value.
--   1.0 (2026-06-16) - initial.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetCellLineQuantity
    @LocationId BIGINT,
    @ItemId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ISNULL(SUM(l.PieceCount), 0) AS ExistingPieceCount
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.CurrentLocationId = @LocationId
      AND l.ItemId = @ItemId
      AND l.LotStatusId <> 4          -- v1.1: 0118 filtered-index literal (Closed)
      AND sc.Code <> N'Closed';
END;
GO
