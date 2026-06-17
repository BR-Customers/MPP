-- ============================================================
-- Repeatable:  R__Oee_Lot_GetInProcessByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-16
-- Version:     1.0
-- Description: READ proc for the Shift-end Summary's "in-process LOTs at this
--              Cell" list (Arc 2 Phase 8, FDS-09-015). LOTs currently at the
--              Location and still in process (status Good or Hold; not Closed /
--              Scrap), with in-process piece count from v_LotDerivedQuantities and
--              the latest arrival time into this Location from LotMovement (uses
--              the (ToLocationId, MovedAt DESC) index). READ proc: one result set;
--              empty set = none. Arrival time converted to Eastern (OI-36).
-- ============================================================

CREATE OR ALTER PROCEDURE Oee.Lot_GetInProcessByLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT l.Id                    AS LotId,
           l.LotName               AS LotName,
           i.PartNumber            AS ItemCode,
           dq.TotalInProcess       AS InProcessPieceCount,
           sc.Code                 AS LotStatus,
           CAST(m.MovedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ArrivedAtEt
    FROM Lots.Lot l
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    LEFT  JOIN Lots.v_LotDerivedQuantities dq ON dq.LotId = l.Id
    OUTER APPLY (SELECT TOP 1 lm.MovedAt FROM Lots.LotMovement lm
                 WHERE lm.LotId = l.Id AND lm.ToLocationId = @LocationId
                 ORDER BY lm.MovedAt DESC) m
    WHERE l.CurrentLocationId = @LocationId
      AND sc.Code IN (N'Good', N'Hold')
    ORDER BY m.MovedAt DESC, l.Id ASC;
END;
GO
