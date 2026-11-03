-- =============================================
-- Procedure:   Oee.Dashboard_GetDowntimeByReason
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.1
--
-- Description:
--   Downtime by reason, Pareto order, for a period and scope (OEE dashboard
--   spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec
--   5.3, 5.4). Read from the SOURCE entries (Oee.ufn_ShiftDowntimeEntries, the
--   same definition the stored minutes use), not from the summary: detail
--   panels read source rows (6.7).
--     @LocationId  the location's own entries plus everything placed on it
--                  (a line includes its stations' entries)
--     @AreaFamily  entries placed in the family
--     neither      every entry placed in a family (the plant)
--   Entries with no reason are one row, IsNoReason = 1, counted unplanned.
--
--   The period's entries are read ONE SHIFT AT A TIME (a loop over the
--   period's shift ids, each a scalar argument to Oee.ufn_ShiftDowntimeEntries)
--   into a table variable, then filtered and grouped. Any set-based form --
--   CROSS APPLY over ufn_ShiftsForPeriod, or over a staged shift-id table, with
--   or without LOOP JOIN / FORCE ORDER / RECOMPILE -- let the optimizer expand
--   the entry functions over the whole DowntimeEvent table: ~3 s a call at a
--   month of plant data whatever the zoom, against ~75 ms for a Week looped
--   (2026-11-03 benchmark). Do not "simplify" the loop back into a join.
--
-- Result set: ReasonCodeId NULL, ReasonCode, ReasonDescription,
--   ReasonTypeName, IsPlanned, IsNoReason, Minutes, EventCount.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
--   2026-11-03 - 1.1 - Read the period's entries one shift at a time
--                      (performance; result unchanged).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.Dashboard_GetDowntimeByReason
    @Zoom          NVARCHAR(5),
    @AnchorShiftId BIGINT,
    @AreaFamily    NVARCHAR(10) = NULL,
    @LocationId    BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @E TABLE (
        LocationId           BIGINT,
        PlacementLocationId  BIGINT,
        AreaFamily           NVARCHAR(10),
        DowntimeReasonCodeId BIGINT,
        Minutes              DECIMAL(14,4),
        IsPlanned            BIT,
        IsNoReason           BIT
    );
    DECLARE @P TABLE (ShiftId BIGINT PRIMARY KEY);
    INSERT INTO @P (ShiftId)
    SELECT ShiftId FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId);

    DECLARE @ShiftId BIGINT = (SELECT MIN(ShiftId) FROM @P);
    WHILE @ShiftId IS NOT NULL
    BEGIN
        INSERT INTO @E
        SELECT e.LocationId, e.PlacementLocationId, e.AreaFamily, e.DowntimeReasonCodeId,
               e.Minutes, e.IsPlanned, e.IsNoReason
        FROM Oee.ufn_ShiftDowntimeEntries(@ShiftId) e;
        SET @ShiftId = (SELECT MIN(ShiftId) FROM @P WHERE ShiftId > @ShiftId);
    END

    SELECT e.DowntimeReasonCodeId                         AS ReasonCodeId,
           ISNULL(rc.Code, N'(no reason)')                 AS ReasonCode,
           ISNULL(rc.Description, N'Downtime with no reason') AS ReasonDescription,
           rt.Name                                         AS ReasonTypeName,
           CAST(MAX(CAST(e.IsPlanned AS INT)) AS BIT)       AS IsPlanned,
           CAST(MAX(CAST(e.IsNoReason AS INT)) AS BIT)      AS IsNoReason,
           CAST(SUM(e.Minutes) AS DECIMAL(12,2))           AS Minutes,
           COUNT(*)                                        AS EventCount
    FROM @E e
    LEFT JOIN Oee.DowntimeReasonCode rc ON rc.Id = e.DowntimeReasonCodeId
    LEFT JOIN Oee.DowntimeReasonType rt ON rt.Id = rc.DowntimeReasonTypeId
    WHERE (@LocationId IS NOT NULL AND (e.LocationId = @LocationId OR e.PlacementLocationId = @LocationId))
       OR (@LocationId IS NULL AND @AreaFamily IS NOT NULL AND e.AreaFamily = @AreaFamily)
       OR (@LocationId IS NULL AND @AreaFamily IS NULL AND e.AreaFamily IS NOT NULL)
    GROUP BY e.DowntimeReasonCodeId, rc.Code, rc.Description, rt.Name
    ORDER BY SUM(e.Minutes) DESC, ISNULL(rc.Code, N'');
END
GO
