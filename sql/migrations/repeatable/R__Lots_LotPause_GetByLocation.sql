-- ============================================================
-- Repeatable:  R__Lots_LotPause_GetByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: READ proc backing the Paused-LOT indicator detail list (OI-21 /
--              FDS-05-038). Returns the OPEN pauses at a Cell, oldest-first, so
--              an operator can pick one to resume. READ proc: no @Status/@Message,
--              no status row, one result set; an empty set means no open pauses.
--
-- Result columns:
--   PauseEventId, LotId, LotName, ItemId, ItemCode (Parts.Item.PartNumber),
--   PausedAt, PausedByUserId, PausedReason
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotPause_GetByLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT pe.Id          AS PauseEventId,
           pe.LotId       AS LotId,
           l.LotName      AS LotName,
           l.ItemId       AS ItemId,
           i.PartNumber   AS ItemCode,
           pe.PausedAt    AS PausedAt,
           pe.PausedByUserId AS PausedByUserId,
           pe.PausedReason   AS PausedReason
    FROM Lots.PauseEvent pe
    INNER JOIN Lots.Lot l ON l.Id = pe.LotId
    INNER JOIN Parts.Item i ON i.Id = l.ItemId
    WHERE pe.LocationId = @LocationId
      AND pe.ResumedAt IS NULL
    ORDER BY pe.PausedAt ASC, pe.Id ASC;
END;
GO
