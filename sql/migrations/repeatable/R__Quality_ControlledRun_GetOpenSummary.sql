-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_GetOpenSummary.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.0
-- Description: READ. Super-lot piece 6 (spec 3.5) -- the Supervisor Dashboard's
--              Open super-lots tile. ALWAYS one row (a tile, not a list):
--                OpenCount          INT       open super-lots
--                OldestOpenedAt     DATETIME2 the oldest one's OpenedAt, Eastern;
--                                             NULL when none are open
--                OldestAgeDays      INT       whole days since then (elapsed
--                                             24-hour periods); NULL when none
--                MembersStillTagged INT       current members across the open
--                                             super-lots that are still CRT-tagged
--                                             (Quality.ufn_ControlledRunMemberState,
--                                             the count Close refuses on)
--              No status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_GetOpenSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Oldest DATETIME2(3), @OpenCount INT;
    SELECT @OpenCount = COUNT(*), @Oldest = MIN(OpenedAt)
    FROM Quality.ControlledRun
    WHERE ControlledRunStatusId = 1;

    SELECT
        @OpenCount AS OpenCount,
        CAST(@Oldest AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OldestOpenedAt,
        CASE WHEN @Oldest IS NOT NULL THEN DATEDIFF(MINUTE, @Oldest, SYSUTCDATETIME()) / 1440 END AS OldestAgeDays,
        ISNULL((
            SELECT SUM(CASE WHEN ms.CrtActive = 1 THEN 1 ELSE 0 END)
            FROM Quality.ControlledRun r
            CROSS APPLY Quality.ufn_ControlledRunMemberState(r.Id) ms
            WHERE r.ControlledRunStatusId = 1 AND ms.EndedAt IS NULL
        ), 0) AS MembersStillTagged;
END;
GO
