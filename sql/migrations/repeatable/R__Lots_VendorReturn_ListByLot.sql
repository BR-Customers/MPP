-- ============================================================
-- Repeatable:  R__Lots_VendorReturn_ListByLot.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-10-19
-- Version:     1.0
-- Description: Super-lot piece 5. Every vendor return ever marked against one
--              LOT, newest first, with its state and whether it can still be
--              cancelled (open AND the LOT is not Closed / Scrap / Open --
--              the same rule Lots.VendorReturn_Cancel enforces).
--              Times displayed Eastern (stored UTC).
--              FDS-11-011: no OUTPUT params; single result set, always emitted.
-- Change Log:
--   2026-10-19 - 1.0 - Initial version.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.VendorReturn_ListByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        vr.Id                                   AS VendorReturnId,
        vr.Quantity                             AS Quantity,
        vr.Remarks                              AS Remarks,
        mu.Initials                             AS MarkedByInitials,
        CAST(vr.MarkedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS MarkedAt,
        cu.Initials                             AS ConfirmedByInitials,
        CAST(vr.ConfirmedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ConfirmedAt,
        xu.Initials                             AS CancelledByInitials,
        CAST(vr.CancelledAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CancelledAt,
        vr.CancelRemarks                        AS CancelRemarks,
        CASE WHEN vr.ConfirmedAt IS NOT NULL THEN N'Confirmed'
             WHEN vr.CancelledAt IS NOT NULL THEN N'Cancelled'
             ELSE N'Open' END                   AS StateCode,
        CAST(CASE WHEN vr.ConfirmedAt IS NULL AND vr.CancelledAt IS NULL
                   AND sc.Code NOT IN (N'Closed', N'Scrap', N'Open')
                  THEN 1 ELSE 0 END AS BIT)     AS CanCancel
    FROM Lots.VendorReturn vr
    INNER JOIN Lots.Lot l            ON l.Id  = vr.LotId
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    INNER JOIN Location.AppUser mu   ON mu.Id = vr.MarkedByUserId
    LEFT  JOIN Location.AppUser cu   ON cu.Id = vr.ConfirmedByUserId
    LEFT  JOIN Location.AppUser xu   ON xu.Id = vr.CancelledByUserId
    WHERE vr.LotId = @LotId
    ORDER BY vr.MarkedAt DESC, vr.Id DESC;
END;
GO
