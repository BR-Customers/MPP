-- =============================================
-- Procedure:   Audit.ConfigLog_List
-- Author:      Blue Ridge Automation
-- Description:
--   Paged, filterable list of successful configuration mutations. Drives the
--   ConfigLog Browser in the Configuration Tool (FDS-11-003).
--
--   Returns TOP 1000 rows ordered by LoggedAt DESC so the
--   ia.display.table component handles client-side paging within a
--   bounded result. A COUNT(*) OVER() column on every row reports the
--   full unbounded count so the UI can render
--   "Showing 1000 of 24,317 -- narrow your filter".
--
-- Parameters:
--   @StartDate           DATETIME2(3)  - inclusive lower bound
--   @EndDate             DATETIME2(3)  - inclusive upper bound (treated as
--                                        "end of day" via < DATEADD(day, 1, @EndDate))
--   @LogEntityTypeCode   NVARCHAR(50)  NULL - exact match
--   @AppUserId           BIGINT        NULL - exact match (maps to ConfigLog.UserId)
--   @LogSeverityCode     NVARCHAR(50)  NULL - exact match
--   @DescriptionLike     NVARCHAR(500) NULL - substring match via LIKE '%X%'
--
-- Result set: top 1000 rows + TotalCount window aggregate.
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-05-19 - 3.0 - Added @LogSeverityCode and @DescriptionLike filters;
--                       COUNT(*) OVER() TotalCount; renamed @FilterAppUserId -> @AppUserId;
--                       added LogEntityTypeCode and LogEventTypeCode columns;
--                       switched @EndDate to exclusive upper bound (< DATEADD(day,1,@EndDate))
-- =============================================
CREATE OR ALTER PROCEDURE Audit.ConfigLog_List
    @StartDate           DATETIME2(3),
    @EndDate             DATETIME2(3),
    @LogEntityTypeCode   NVARCHAR(50)  = NULL,
    @AppUserId           BIGINT        = NULL,
    @LogSeverityCode     NVARCHAR(50)  = NULL,
    @DescriptionLike     NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1000
        cl.Id,
        cl.LoggedAt,
        cl.UserId,
        au.DisplayName               AS UserDisplayName,
        let.Code                     AS LogEntityTypeCode,
        let.Name                     AS LogEntityTypeName,
        cl.EntityId,
        cl.LogEventTypeId,
        lev.Code                     AS LogEventTypeCode,
        cl.LogSeverityId,
        ls.Code                      AS LogSeverityCode,
        cl.Description,
        cl.OldValue,
        cl.NewValue,
        COUNT(*) OVER()              AS TotalCount
    FROM Audit.ConfigLog cl
    INNER JOIN Audit.LogEntityType let ON let.Id = cl.LogEntityTypeId
    LEFT JOIN  Audit.LogEventType  lev ON lev.Id = cl.LogEventTypeId
    LEFT JOIN  Audit.LogSeverity   ls  ON ls.Id  = cl.LogSeverityId
    LEFT JOIN  Location.AppUser    au  ON au.Id  = cl.UserId
    WHERE cl.LoggedAt >= @StartDate
      AND cl.LoggedAt <  DATEADD(day, 1, @EndDate)
      AND (@LogEntityTypeCode IS NULL OR let.Code = @LogEntityTypeCode)
      AND (@AppUserId         IS NULL OR cl.UserId = @AppUserId)
      AND (@LogSeverityCode   IS NULL OR ls.Code = @LogSeverityCode)
      AND (@DescriptionLike   IS NULL OR cl.Description LIKE N'%' + @DescriptionLike + N'%')
    ORDER BY cl.LoggedAt DESC;
END;
GO
