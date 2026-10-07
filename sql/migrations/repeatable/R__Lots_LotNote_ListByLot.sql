-- ============================================================
-- Repeatable:  R__Lots_LotNote_ListByLot.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-06
-- Version:     1.0
-- Description: READ proc for the LOT Detail "Notes" tab. Every note on one
--              LOT, newest first, with the author, the terminal it was typed
--              at (and that terminal's parent zone), and the LOT snapshot
--              stamped when it was written. No status row; empty = no notes.
--
--              CreatedAt is converted to Eastern at the boundary (stored UTC).
--
--              ContextJson is deliberately NOT returned: it is evidence for an
--              investigation, read in SQL, and would bloat every tab load.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.LotNote_ListByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        n.Id,
        n.LotId,
        n.NoteText,
        CAST(n.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedAt,
        n.AppUserId,
        u.Initials           AS ByInitials,
        u.DisplayName        AS ByDisplayName,
        n.WasElevated,
        n.TerminalLocationId,
        term.Name            AS TerminalName,
        zone.Name            AS TerminalZoneName,
        sc.Code              AS LotStatusCode,
        lotloc.Name          AS LotLocationName,
        n.LotPieceCount
    FROM Lots.LotNote n
    INNER JOIN Location.AppUser    u      ON u.Id      = n.AppUserId
    INNER JOIN Lots.LotStatusCode  sc     ON sc.Id     = n.LotStatusId
    INNER JOIN Location.Location   lotloc ON lotloc.Id = n.LotLocationId
    LEFT  JOIN Location.Location   term   ON term.Id   = n.TerminalLocationId
    LEFT  JOIN Location.Location   zone   ON zone.Id   = term.ParentLocationId
    WHERE n.LotId = @LotId
    ORDER BY n.CreatedAt DESC, n.Id DESC;
END;
GO
