-- ============================================================
-- Repeatable:  R__Lots_LotPause_GetByLot.sql
-- Description: READ proc for the LOT Detail "Paused-at" tab. OPEN pauses for one
--              LOT across ALL Locations, oldest-first. No status row; empty = none.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.LotPause_GetByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pe.Id AS PauseEventId, pe.LotId, pe.LocationId, loc.Name AS LocationName,
           pe.PausedAt, pe.PausedByUserId, pe.PausedReason
    FROM Lots.PauseEvent pe
    INNER JOIN Location.Location loc ON loc.Id = pe.LocationId
    WHERE pe.LotId = @LotId AND pe.ResumedAt IS NULL
    ORDER BY pe.PausedAt ASC, pe.Id ASC;
END;
GO
