-- =============================================
-- Procedure:   Audit.FailureLog_DistinctProcedures
-- Author:      Blue Ridge Automation
-- Created:     2026-05-19
-- Description:
--   Returns the distinct list of ProcedureName values ever logged to
--   Audit.FailureLog (excluding NULLs), sorted ascending. Drives the
--   Procedure dropdown on the FailureLog Browser. No date param --
--   the dropdown shows every proc ever logged so operators can filter
--   without first having to narrow by date.
-- =============================================
CREATE OR ALTER PROCEDURE Audit.FailureLog_DistinctProcedures
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT ProcedureName
    FROM Audit.FailureLog
    WHERE ProcedureName IS NOT NULL
    ORDER BY ProcedureName;
END;
GO
