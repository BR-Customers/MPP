-- =============================================
-- Procedure:   Audit.FailureLog_List
-- Author:      Blue Ridge Automation
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
-- Parameters:
--   @StartDate         DATETIME2(3)  - inclusive lower bound
--   @EndDate           DATETIME2(3)  - inclusive upper bound (treated as
--                                      "end of day" via < DATEADD(day, 1, @EndDate))
--   @LogEntityTypeCode NVARCHAR(50)  NULL - exact match
--   @AppUserId         BIGINT        NULL - exact match
--   @ProcedureName     NVARCHAR(200) NULL - exact match
--   @FailureReasonLike NVARCHAR(500) NULL - substring match via LIKE '%X%'
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
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_List
    @StartDate           DATETIME2(3),
    @EndDate             DATETIME2(3),
    @LogEntityTypeCode   NVARCHAR(50)  = NULL,
    @AppUserId           BIGINT        = NULL,
    @ProcedureName       NVARCHAR(200) = NULL,
    @FailureReasonLike   NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1000
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
        COUNT(*) OVER()              AS TotalCount
    FROM Audit.FailureLog fl
    INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
    LEFT JOIN  Audit.LogEventType  lev ON lev.Id = fl.LogEventTypeId
    LEFT JOIN  Location.AppUser    au  ON au.Id  = fl.AppUserId
    WHERE fl.AttemptedAt >= @StartDate
      AND fl.AttemptedAt <  DATEADD(day, 1, @EndDate)
      AND (@LogEntityTypeCode IS NULL OR let.Code = @LogEntityTypeCode)
      AND (@AppUserId         IS NULL OR fl.AppUserId = @AppUserId)
      AND (@ProcedureName     IS NULL OR fl.ProcedureName = @ProcedureName)
      AND (@FailureReasonLike IS NULL OR fl.FailureReason LIKE N'%' + @FailureReasonLike + N'%')
    ORDER BY fl.AttemptedAt DESC;
END;
GO
