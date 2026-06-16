-- ============================================================
-- Repeatable:  R__Lots_Lot_GetCellLineQuantity.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: Arc 2 Phase 4 (spec sec 4.1). Sums PieceCount across OPEN LOTs
--              (LotStatusCode <> 'Closed') of @ItemId whose CurrentLocationId =
--              @LocationId. Generic location id (sums at whatever tier the
--              destination is, despite the 'CellLine' name). One row:
--              ExistingPieceCount INT (0 when none). Read proc; no status row.
--              Drives the "N of M capacity" hint in the Movement Scan UI; the
--              authoritative MaxParts cap is enforced in Lot_MoveToValidated.
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
      AND sc.Code <> N'Closed';
END;
GO
