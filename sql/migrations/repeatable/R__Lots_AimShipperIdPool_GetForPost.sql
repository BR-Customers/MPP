-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_GetForPost.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Reads one pool row's AIM post-back payload by shipper ID, for
--              BlueRidge.Lots.AimPost.postOne. Re-read on EVERY attempt (not
--              cached by the caller) so a config-gap row self-heals the moment
--              Parts.Item.AimCustomerPartNumber is filled in. Read proc: empty
--              rowset = not found, no invented 404. No OUTPUT params.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_GetForPost
    @AimShipperId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @AimShipperId IS NULL
        RETURN;

    SELECT
        p.Id                 AS Id,
        p.AimShipperId       AS AimShipperId,
        p.CustomerPartNumber AS CustomerPartNumber,
        p.Quantity           AS Quantity,
        p.LotNumber          AS LotNumber,
        p.PostedAt           AS PostedAt,
        p.PostAttempts       AS PostAttempts
    FROM Lots.AimShipperIdPool p
    WHERE p.AimShipperId = @AimShipperId;
END;
GO
