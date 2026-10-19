-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_ListOpen.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
-- Description: Super-lot piece 5 (spec 5.2). Vendor returns marked but not yet
--              confirmed or cancelled -- the "still to ship back" list.
--              Oldest first. MarkedAt is displayed Eastern (stored UTC).
--              FDS-11-011: no OUTPUT params; single result set, always
--              emitted; empty set = nothing open.
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.VendorReturn_ListOpen
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        vr.Id                                   AS VendorReturnId,
        vr.LotId                                AS LotId,
        l.LotName                               AS LotName,
        i.PartNumber                            AS ItemPartNumber,
        l.VendorLotNumber                       AS VendorLotNumber,
        vr.Quantity                             AS Quantity,
        vr.Remarks                              AS Remarks,
        u.Initials                              AS MarkedByInitials,
        CAST(vr.MarkedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS MarkedAt,
        cl.Name                                 AS CurrentLocationName
    FROM Lots.VendorReturn vr
    INNER JOIN Lots.Lot l            ON l.Id  = vr.LotId
    INNER JOIN Parts.Item i          ON i.Id  = l.ItemId
    INNER JOIN Location.Location cl  ON cl.Id = l.CurrentLocationId
    INNER JOIN Location.AppUser u    ON u.Id  = vr.MarkedByUserId
    WHERE vr.ConfirmedAt IS NULL AND vr.CancelledAt IS NULL
    ORDER BY vr.MarkedAt ASC, vr.Id ASC;
END;
GO
