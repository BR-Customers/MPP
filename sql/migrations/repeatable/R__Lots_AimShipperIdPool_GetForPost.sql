-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_GetForPost.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1
-- Description: Reads one pool row's AIM post-back payload by shipper ID, for
--              BlueRidge.Lots.AimPost.postOne. Re-read on EVERY attempt (not
--              cached by the caller) so a config-gap row self-heals the moment
--              Parts.Item.AimCustomerPartNumber is filled in. Read proc: empty
--              rowset = not found, no invented 404. No OUTPUT params.
--              v1.1: CustomerPartNumber is COALESCE(p.CustomerPartNumber,
--              i.AimCustomerPartNumber) via a LEFT JOIN to Lots.Container and
--              Parts.Item -- the actual self-heal. The snapshot Container_Complete
--              writes at completion is frozen once set (never overwritten by a
--              later item edit), but a row snapshotted NULL (item had no AIM
--              customer part configured yet) now rejoins to the live item value
--              on every read instead of staying NULL forever. LEFT JOIN so a row
--              with an unexpectedly missing container link is still returned.
--              Also returns ContainerId + ItemPartNumber so postOne can render the
--              config-gap modal (spec S6.2) from this one read, including on the
--              retry-sweep path where no container context exists.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_GetForPost
    @AimShipperId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @AimShipperId IS NULL
        RETURN;

    SELECT
        p.Id                                                     AS Id,
        p.AimShipperId                                           AS AimShipperId,
        COALESCE(p.CustomerPartNumber, i.AimCustomerPartNumber)  AS CustomerPartNumber,
        p.Quantity                                                AS Quantity,
        p.LotNumber                                               AS LotNumber,
        p.PostedAt                                                AS PostedAt,
        p.PostAttempts                                            AS PostAttempts,
        p.ConsumedByContainerId                                   AS ContainerId,
        i.PartNumber                                              AS ItemPartNumber
    FROM Lots.AimShipperIdPool p
    LEFT JOIN Lots.Container c ON c.Id = p.ConsumedByContainerId
    LEFT JOIN Parts.Item i ON i.Id = c.ItemId
    WHERE p.AimShipperId = @AimShipperId;
END;
GO
