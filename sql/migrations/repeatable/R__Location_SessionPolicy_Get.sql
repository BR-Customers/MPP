-- =============================================
-- Procedure: Location.SessionPolicy_Get
-- Author:    Blue Ridge Automation
-- Version:   1.1
-- Description: Returns the single global session-policy row (operator-presence
--              idle timeout, the rolling elevation idle timeout, and the
--              absolute elevation ceiling -- all seconds). No OUTPUT params
--              (FDS-11-011).
--
--              ElevationTimeoutSeconds is the ROLLING window that activity
--              pushes forward (Common.Session.touchElevation);
--              ElevationMaxSeconds (0100) is the ceiling it can never pass.
--              Equal values reproduce the pre-0100 behaviour: one fixed window.
--
-- Change log:
--   1.1  2026-09-29  ElevationMaxSeconds added to the projection (0100).
--   1.0               Initial.
-- =============================================
CREATE OR ALTER PROCEDURE Location.SessionPolicy_Get
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 Id, OperatorPresenceTimeoutSeconds, ElevationTimeoutSeconds,
                 ElevationMaxSeconds, UpdatedAt
    FROM Location.SessionPolicy ORDER BY Id;
END
GO
