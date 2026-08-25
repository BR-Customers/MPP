-- ============================================================
-- Repeatable:  R__Lots_LotPause_GetCountsByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: READ proc backing the Paused-LOT indicator badge (OI-21 /
--              FDS-05-038). Returns a single row with the open-pause count for a
--              Cell. Hits the filtered index IX_PauseEvent_OpenByLocation. READ
--              proc: no @Status/@Message, no status row. Always returns exactly
--              one row (COUNT(*) is 0 for a Cell with no open pauses).
--
-- Result column: OpenPauseCount INT
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotPause_GetCountsByLocation
    @LocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS OpenPauseCount
    FROM Lots.PauseEvent
    WHERE LocationId = @LocationId
      AND ResumedAt IS NULL;
END;
GO
