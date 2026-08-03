-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_ListUnposted.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Rows owed to AIM - consumed but not yet reported. Serves BOTH the
--              retry sweep (BlueRidge.Lots.AimPost.retryTick) and the supervisor
--              list on /aim-pool. Oldest-first; order is a fairness choice only,
--              NOT a requirement - AIM accepts serials in any order (verified
--              2026-07-31). Timestamps returned in ET for display. Read proc:
--              empty rowset when nothing is owed.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_ListUnposted
    @Top INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top < 1
        SET @Top = 50;

    SELECT TOP (@Top)
        p.Id                    AS Id,
        p.AimShipperId          AS AimShipperId,
        p.ConsumedByContainerId AS ContainerId,
        p.CustomerPartNumber    AS CustomerPartNumber,
        p.Quantity              AS Quantity,
        p.LotNumber             AS LotNumber,
        p.PostAttempts          AS PostAttempts,
        p.LastPostError         AS LastPostError,
        CAST(p.ConsumedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS ConsumedAtEt,
        CAST(p.LastPostAttemptAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS LastPostAttemptAtEt,
        DATEDIFF(MINUTE, p.ConsumedAt, SYSUTCDATETIME()) AS AgeMinutes
    FROM Lots.AimShipperIdPool p
    WHERE p.ConsumedAt IS NOT NULL AND p.PostedAt IS NULL
    ORDER BY p.ConsumedAt, p.Id;
END;
GO
