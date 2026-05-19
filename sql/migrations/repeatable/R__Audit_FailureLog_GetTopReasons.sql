-- =============================================
-- Procedure:   Audit.FailureLog_GetTopReasons
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     2.0
--
-- Description:
--   Returns the top 5 failure reasons by frequency within a date range.
--   Supports optional filtering by entity type and/or originating
--   procedure name. Useful for identifying recurring validation or
--   business-rule failures, either globally or scoped to a single proc.
--   Read-only proc — empty result means no failures in the date range.
--
-- Parameters:
--   @StartDate DATETIME2(3)                 - Start of date range (inclusive). Required.
--   @EndDate DATETIME2(3)                   - End of date range (inclusive). Required.
--   @LogEntityTypeCode NVARCHAR(50) = NULL  - Optional entity type filter.
--   @ProcedureName NVARCHAR(200) = NULL     - Optional exact-match filter on originating proc.
--
-- Result set:
--   Top 5 rows: FailureReason, FailureCount — ordered by FailureCount DESC.
--
-- Dependencies:
--   Tables: Audit.FailureLog, Audit.LogEntityType
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 1.1 - Added optional @ProcedureName filter
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-05-19 - 2.1 - End-date semantics aligned with FailureLog_List
--                       (`< DATEADD(day, 1, @EndDate)` instead of BETWEEN inclusive)
--                       so tile aggregates capture the full day of @EndDate
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_GetTopReasons
    @StartDate          DATETIME2(3),
    @EndDate            DATETIME2(3),
    @LogEntityTypeCode  NVARCHAR(50)    = NULL,
    @ProcedureName      NVARCHAR(200)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve optional entity type filter
    DECLARE @LogEntityTypeId BIGINT = NULL;

    IF @LogEntityTypeCode IS NOT NULL
    BEGIN
        SELECT @LogEntityTypeId = Id
        FROM Audit.LogEntityType
        WHERE Code = @LogEntityTypeCode;

        -- Filter specified but not found → empty result
        IF @LogEntityTypeId IS NULL
            RETURN;
    END

    SELECT TOP (5)
        fl.FailureReason,
        COUNT(*) AS FailureCount
    FROM Audit.FailureLog fl
    WHERE fl.AttemptedAt >= @StartDate
      AND fl.AttemptedAt <  DATEADD(day, 1, @EndDate)
      AND (@LogEntityTypeId IS NULL OR fl.LogEntityTypeId = @LogEntityTypeId)
      AND (@ProcedureName   IS NULL OR fl.ProcedureName   = @ProcedureName)
    GROUP BY fl.FailureReason
    ORDER BY FailureCount DESC;
END;
GO
