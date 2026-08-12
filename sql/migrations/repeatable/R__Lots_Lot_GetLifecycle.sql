-- ============================================================
-- Repeatable:  R__Lots_Lot_GetLifecycle.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Per-LOT lifecycle timeline for the traceability report. Projects the
--              append-only audit event stream Lots.LotEventLog for @LotId with a
--              DISCRETE Location column (COALESCE of the event's LocationId and the
--              recording TerminalLocationId), the event-type name, acting operator,
--              and description -- created / acted-on / closed, one row per event.
--
--              Chosen over Lots.Lot_GetAttributeHistory: that curated timeline bakes
--              location into its Detail string, whereas the report wants a Location
--              column and LotEventLog carries LocationId on every row.
--
--              READ proc (FDS-11-011): no status row, ONE result set, empty = not
--              found, no OUTPUT params. Timestamp converted UTC->Eastern at the read
--              boundary; ORDER BY on raw UTC LoggedAt (stable chronological).
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.Lot_GetLifecycle
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        CAST(el.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventAtEt,
        et.Name              AS EventTypeName,
        loc.Name             AS LocationName,
        au.DisplayName       AS OperatorName,
        el.Description        AS Description
    FROM Lots.LotEventLog el
    INNER JOIN Audit.LogEventType et  ON et.Id  = el.LogEventTypeId
    LEFT  JOIN Location.Location   loc ON loc.Id = COALESCE(el.LocationId, el.TerminalLocationId)
    LEFT  JOIN Location.AppUser    au  ON au.Id  = el.UserId
    WHERE el.LotId = @LotId
    ORDER BY el.LoggedAt ASC;
END;
GO
