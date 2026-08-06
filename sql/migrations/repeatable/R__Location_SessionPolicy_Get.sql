-- =============================================
-- Procedure: Location.SessionPolicy_Get
-- Author:    Blue Ridge Automation
-- Description: Returns the single global session-policy row (operator-presence +
--              elevation idle timeouts, seconds). No OUTPUT params (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Location.SessionPolicy_Get
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 Id, OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds, UpdatedAt
    FROM Location.SessionPolicy ORDER BY Id;
END
GO
