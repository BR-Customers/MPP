-- ============================================================
-- Repeatable:  R__Lots_ufn_OpenLotRework.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-19
-- Version:     1.0
-- Description: Super-lot piece 5. The LOT's OPEN trim rework, if any: zero or one
--              row. The filtered unique index UQ_LotRework_OpenPerLot guarantees
--              at most one open row per LOT, so callers can test existence with
--              EXISTS (SELECT 1 FROM Lots.ufn_OpenLotRework(@LotId)).
--              INLINE TVF so it folds into the caller's plan.
-- ============================================================
CREATE OR ALTER FUNCTION Lots.ufn_OpenLotRework (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT lr.Id, lr.LotId, lr.ReEntrySequenceNumber, lr.StartedAt
    FROM Lots.LotRework lr
    WHERE lr.LotId = @LotId AND lr.CompletedAt IS NULL;
GO
