-- ============================================================
-- Repeatable:  R__Workorder_ufn_TrimPassPreviousCount.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-19
-- Version:     1.0
-- Description: Super-lot piece 5. The LOT's previous trim count FOR THE CURRENT
--              PASS: the newest TrimIn/TrimOut checkpoint with a non-null ShotCount,
--              restricted to checkpoints at/after the open rework's StartedAt when a
--              rework is open. A rework pass therefore starts its own cumulative
--              count (it is not compared against the first pass), while a LOT with
--              no open rework sees every trim checkpoint exactly as before.
--              0 or 1 row (ShotCount, ProductionEventId). INLINE TVF.
--              Comparison is >= to match Lots.ufn_NextPendingRouteStep v1.2.
--              Used by Workorder.TrimOut_Record (guard 7), Workorder.TrimPartial_Record
--              (guard 8) and Workorder.TrimCheckpoint_GetLatestForLot.
-- ============================================================
CREATE OR ALTER FUNCTION Workorder.ufn_TrimPassPreviousCount (@LotId BIGINT)
RETURNS TABLE
AS RETURN
    SELECT TOP 1 pe.ShotCount, pe.Id AS ProductionEventId
    FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    OUTER APPLY Lots.ufn_OpenLotRework(@LotId) rw
    WHERE pe.LotId = @LotId AND pe.ShotCount IS NOT NULL
      AND oty.Code IN (N'TrimIn', N'TrimOut')
      AND (rw.StartedAt IS NULL OR pe.EventAt >= rw.StartedAt)
    ORDER BY pe.EventAt DESC, pe.Id DESC;
GO
