-- =============================================
-- Procedure:   Audit.FailureLog_List
-- Author:      Blue Ridge Automation
-- Version:     3.2
-- Description:
--   Paged, filterable list of rejected mutation attempts. Drives the
--   FailureLog Browser in the Configuration Tool (FDS-11-004).
--
--   Returns TOP 1000 rows ordered by AttemptedAt DESC so the
--   ia.display.table component handles client-side paging within a
--   bounded result. A COUNT(*) OVER() column on every row reports the
--   full unbounded count so the UI can render
--   "Showing 1000 of 24,317 -- narrow your filter".
--
--   Shape (v3.2): the filter, the window count and the TOP 1000 run over
--   (Id, AttemptedAt) only; the wide columns (AttemptedParameters is
--   NVARCHAR(MAX)) and the display joins are fetched for the 1000 page
--   rows alone. Before v3.2 every matching row, MAX column included, was
--   spooled for COUNT(*) OVER() and sorted before the TOP. Same filters,
--   same columns, same order.
--
-- Parameters:
--   @StartDate         DATETIME2(3)  - inclusive lower bound
--   @EndDate           DATETIME2(3)  - inclusive upper bound (treated as
--                                      "end of day" via < DATEADD(day, 1, @EndDate))
--   @LogEntityTypeCode NVARCHAR(50)  NULL - exact match
--   @AppUserId         BIGINT        NULL - exact match
--   @ProcedureName     NVARCHAR(200) NULL - exact match
--   @FailureReasonLike NVARCHAR(500) NULL - substring match via LIKE '%X%'
--   @LocationId        BIGINT        NULL - exact match on FailureLog.LocationId
--   @LotNameLike       NVARCHAR(50)  NULL - substring match on the LOT's name
--
-- Result set: top 1000 rows + TotalCount window aggregate.
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-05-19 - 3.0 - Added @FailureReasonLike filter; COUNT(*) OVER() TotalCount;
--                       renamed @FilterAppUserId -> @AppUserId; added LogEntityTypeCode
--                       and LogEventTypeCode columns; switched @EndDate to exclusive
--                       upper bound (< DATEADD(day,1,@EndDate))
--   2026-10-29 - 3.1 - Migration 0116: + @LocationId / @LotNameLike filters;
--                       + trailing LocationId, LocationName, LotId, LotName columns
--                       (AFTER TotalCount, so existing positional captures widen only)
--   2026-11-16 - 3.2 - Stored-procedure review: filter + count + TOP 1000 over
--                       (Id, AttemptedAt) first, then fetch the wide columns and
--                       display joins for the page rows only. Result set unchanged
--                       (columns, order, rows). 150k-row log, 600-day window:
--                       ~1.3 s -> ~0.34 s warm (CPU 3.0 s -> 0.6 s); 7-day default 61 -> 48 ms.
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_List
    @StartDate           DATETIME2(3),
    @EndDate             DATETIME2(3),
    @LogEntityTypeCode   NVARCHAR(50)  = NULL,
    @AppUserId           BIGINT        = NULL,
    @ProcedureName       NVARCHAR(200) = NULL,
    @FailureReasonLike   NVARCHAR(500) = NULL,
    @LocationId          BIGINT        = NULL,
    @LotNameLike         NVARCHAR(50)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Hits: the matching rows, narrow (key + count only).
    -- Page: the newest 1000 of them.
    WITH Hits AS (
        SELECT
            fl.Id,
            fl.AttemptedAt,
            COUNT(*) OVER()          AS TotalCount
        FROM Audit.FailureLog fl
        INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
        WHERE fl.AttemptedAt >= @StartDate
          AND fl.AttemptedAt <  DATEADD(day, 1, @EndDate)
          AND (@LogEntityTypeCode IS NULL OR let.Code = @LogEntityTypeCode)
          AND (@AppUserId         IS NULL OR fl.AppUserId = @AppUserId)
          AND (@ProcedureName     IS NULL OR fl.ProcedureName = @ProcedureName)
          AND (@FailureReasonLike IS NULL OR fl.FailureReason LIKE N'%' + @FailureReasonLike + N'%')
          AND (@LocationId        IS NULL OR fl.LocationId = @LocationId)
          -- EXISTS on the PK is the old LEFT JOIN + WHERE (one LOT per row at
          -- most), but the LOT is only probed when @LotNameLike is supplied.
          AND (@LotNameLike       IS NULL OR EXISTS (
                   SELECT 1 FROM Lots.Lot lot
                   WHERE lot.Id = fl.LotId
                     AND lot.LotName LIKE N'%' + @LotNameLike + N'%'))
    ),
    Page AS (
        SELECT TOP 1000 Id, AttemptedAt, TotalCount
        FROM Hits
        ORDER BY AttemptedAt DESC
    )
    SELECT
        fl.Id,
        CAST(fl.AttemptedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS AttemptedAt,
        fl.AppUserId,
        au.DisplayName               AS UserDisplayName,
        let.Code                     AS LogEntityTypeCode,
        let.Name                     AS LogEntityTypeName,
        fl.EntityId,
        fl.LogEventTypeId,
        lev.Code                     AS LogEventTypeCode,
        fl.FailureReason,
        fl.ProcedureName,
        fl.AttemptedParameters,
        p.TotalCount,
        fl.LocationId,
        loc.Name                     AS LocationName,
        fl.LotId,
        lot.LotName                  AS LotName
    FROM Page p
    -- (Id, AttemptedAt) is PK_FailureLog: exactly one row per page key.
    INNER JOIN Audit.FailureLog    fl  ON fl.Id = p.Id AND fl.AttemptedAt = p.AttemptedAt
    INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
    LEFT JOIN  Audit.LogEventType  lev ON lev.Id = fl.LogEventTypeId
    LEFT JOIN  Location.AppUser    au  ON au.Id  = fl.AppUserId
    LEFT JOIN  Location.Location   loc ON loc.Id = fl.LocationId
    LEFT JOIN  Lots.Lot            lot ON lot.Id = fl.LotId
    ORDER BY p.AttemptedAt DESC;
END;
GO
