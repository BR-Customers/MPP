-- ============================================================
-- Repeatable:  R__Lots_LotPause_GetCountsByLocation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.1
-- Description: READ proc backing the Paused-LOT indicator badge (OI-21 /
--              FDS-05-038) and the Supervisor Dashboard's plant-wide Paused-LOTs
--              tile. Returns a single row with the open-pause count. Hits the
--              filtered index IX_PauseEvent_OpenByLocation. READ proc: no
--              @Status/@Message, no status row. Always returns exactly one row
--              (COUNT(*) is 0 when nothing is paused).
--
--              v1.1 (2026-08-25): @LocationId is now OPTIONAL. NULL means
--              PLANT-WIDE - every open pause regardless of location - which is
--              what the Supervisor Dashboard tile needs; there was previously no
--              way to get an unscoped count, so that tile read "aggregate read
--              pending". A non-NULL @LocationId keeps the exact-match Cell
--              behaviour the indicator badge has always had, unchanged, so every
--              existing caller is unaffected.
--
--              Deliberately an exact match, NOT a hierarchy cascade: PauseEvent
--              rows are always written at the Cell a LOT was paused at, so
--              summing descendants would be a no-op at Cell level and would
--              double-count nothing at higher tiers. Plant-wide is therefore just
--              "no filter", not a rollup walk.
--
-- Result column: OpenPauseCount INT
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotPause_GetCountsByLocation
    @LocationId BIGINT = NULL      -- NULL = plant-wide
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS OpenPauseCount
    FROM Lots.PauseEvent
    WHERE ResumedAt IS NULL
      AND (@LocationId IS NULL OR LocationId = @LocationId);
END;
GO
