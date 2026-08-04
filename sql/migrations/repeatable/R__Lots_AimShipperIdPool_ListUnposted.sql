-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_ListUnposted.sql
-- Author:      Blue Ridge Automation
-- Version:     1.2
-- Description: Rows owed to AIM - consumed but not yet reported. Serves BOTH the
--              retry sweep (BlueRidge.Lots.AimPost.retryTick) and the supervisor
--              list on /aim-pool. Oldest-first; order is a fairness choice only,
--              NOT a requirement - AIM accepts serials in any order (verified
--              2026-07-31). Timestamps returned in ET for display. Read proc:
--              empty rowset when nothing is owed.
--              v1.2 (2026-08-04, Migration 0051): CustomerPartNumber is
--              COALESCE(p.CustomerPartNumber, Parts.ufn_AimCustomerPartNumber(
--              i.PartNumber)) via the same LEFT JOIN self-heal as _GetForPost --
--              the supervisor /aim-pool list always shows a derived customer part
--              for a row whose snapshot came back NULL, since the derivation is a
--              pure function of the NOT NULL Item.PartNumber.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_ListUnposted
    @Top INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top < 1
        SET @Top = 50;

    SELECT TOP (@Top)
        p.Id                                                                          AS Id,
        p.AimShipperId                                                                AS AimShipperId,
        p.ConsumedByContainerId                                                       AS ContainerId,
        COALESCE(p.CustomerPartNumber, Parts.ufn_AimCustomerPartNumber(i.PartNumber))  AS CustomerPartNumber,
        p.Quantity                                                AS Quantity,
        p.LotNumber                                               AS LotNumber,
        p.PostAttempts                                            AS PostAttempts,
        p.LastPostError                                           AS LastPostError,
        CAST(p.ConsumedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS ConsumedAtEt,
        CAST(p.LastPostAttemptAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3)) AS LastPostAttemptAtEt,
        DATEDIFF(MINUTE, p.ConsumedAt, SYSUTCDATETIME()) AS AgeMinutes
    FROM Lots.AimShipperIdPool p
    LEFT JOIN Lots.Container c ON c.Id = p.ConsumedByContainerId
    LEFT JOIN Parts.Item i ON i.Id = c.ItemId
    WHERE p.ConsumedAt IS NOT NULL AND p.PostedAt IS NULL
    ORDER BY p.ConsumedAt, p.Id;
END;
GO
