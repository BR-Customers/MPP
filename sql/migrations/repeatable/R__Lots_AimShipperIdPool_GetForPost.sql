-- ============================================================
-- Repeatable:  R__Lots_AimShipperIdPool_GetForPost.sql
-- Author:      Blue Ridge Automation
-- Version:     1.2
-- Description: Reads one pool row's AIM post-back payload by shipper ID, for
--              BlueRidge.Lots.AimPost.postOne. Re-read on EVERY attempt (not
--              cached by the caller). Read proc: empty rowset = not found, no
--              invented 404. No OUTPUT params.
--              v1.2 (2026-08-04, Migration 0051): CustomerPartNumber is
--              COALESCE(p.CustomerPartNumber, Parts.ufn_AimCustomerPartNumber(
--              i.PartNumber)) via a LEFT JOIN to Lots.Container and Parts.Item.
--              The snapshot Container_Complete writes at completion is frozen
--              once set (never overwritten by a later item edit), but a row
--              snapshotted NULL now rejoins to the DERIVED value on every read
--              instead of staying NULL forever -- and because the derivation is a
--              pure function of the NOT NULL PartNumber, this can never actually
--              stay NULL for a real item (unlike the old stored-column self-heal,
--              which depended on someone filling in Item.AimCustomerPartNumber).
--              LEFT JOIN so a row with an unexpectedly missing container link is
--              still returned. Also returns ContainerId + ItemPartNumber so
--              postOne can render diagnostics from this one read, including on
--              the retry-sweep path where no container context exists.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.AimShipperIdPool_GetForPost
    @AimShipperId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @AimShipperId IS NULL
        RETURN;

    SELECT
        p.Id                                                                          AS Id,
        p.AimShipperId                                                                AS AimShipperId,
        COALESCE(p.CustomerPartNumber, Parts.ufn_AimCustomerPartNumber(i.PartNumber))  AS CustomerPartNumber,
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
