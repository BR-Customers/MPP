-- =============================================
-- Repeatable:  R__Oee_ufn_zzz_ShiftScrap.sql
-- Object:      Oee.ufn_ShiftScrap
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.0
-- Description: Every reject in one runtime shift, placed for the OEE dashboard
--              (spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.4, decisions D11/D12). One row per Workorder.RejectEvent.
--
--              Shift membership: RejectEvent.ShiftId = @ShiftId, or ShiftId
--              NULL and Oee.ufn_ShiftIdForInstant(<where found>, RecordedAt) is
--              this shift -- the plant shift when there is no cell. That covers
--              rows written before the writers stamped a shift, with no backfill.
--
--              Charge: scrap is charged by defect code (Oee.ufn_RejectChargeFamily)
--              -- the same ownership rule as Quality.Reject_GetPlantSummary.
--                FoundAtLocationId / FoundFamily  where it was recorded
--                                   (Oee.ufn_AreaFamily of CellLocationId)
--                UnitLocationId     the placement, ONLY when the charge family
--                                   is the family it was found in; else NULL
--                IsFoundDownstream  1 when it is charged to a family but cannot
--                                   be placed on one of that family's units:
--                                   found in another family, found outside any
--                                   unit, or recorded with no cell. It counts
--                                   at that family's AREA and site level only.
--                ChargeFamily NULL  a Non-Specific reject with no cell: no
--                                   area owns it; it is left out of dashboard
--                                   quality (footnoted).
--                IsNonReject        the defect is IsNonRejectScrap -- shown,
--                                   never counted in quality.
--              No rows for an unknown shift.
--              FILE NAME IS ORDER-SENSITIVE -- 'zzz_' sorts after the 'zz_'
--              functions it calls.
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftScrap (@ShiftId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH Win AS (
        SELECT DATEADD(HOUR, -12, CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))) AS FromUtc,
               DATEADD(HOUR,  36, CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))) AS ToUtc
        FROM Oee.Shift s
        WHERE s.Id = @ShiftId
    ),
    Hit AS (
        SELECT re.Id
        FROM Workorder.RejectEvent re
        WHERE re.ShiftId = @ShiftId
        UNION ALL
        SELECT re.Id
        FROM Win w
        INNER JOIN Workorder.RejectEvent re
                ON re.ShiftId IS NULL
               AND re.RecordedAt >= w.FromUtc
               AND re.RecordedAt <  w.ToUtc
        CROSS APPLY Oee.ufn_AreaFamily(re.CellLocationId) af
        CROSS APPLY (SELECT TOP 1 si.ShiftId
                     FROM Oee.ufn_ShiftIdForInstant(af.PlacementLocationId, re.RecordedAt) si) sh
        WHERE sh.ShiftId = @ShiftId
    )
    SELECT
        re.Id                                   AS RejectEventId,
        cf.ChargeFamily,
        CASE WHEN cf.ChargeFamily = af.AreaFamily THEN af.PlacementLocationId END AS UnitLocationId,
        CAST(CASE WHEN cf.ChargeFamily = af.AreaFamily THEN af.PlacementIsArea ELSE 0 END AS BIT) AS PlacementIsArea,
        af.PlacementLocationId                  AS FoundAtLocationId,
        af.AreaFamily                           AS FoundFamily,
        re.ItemId,
        re.DefectCodeId,
        CAST(re.Quantity AS BIGINT)             AS Quantity,
        dc.IsNonRejectScrap                     AS IsNonReject,
        CAST(CASE WHEN cf.ChargeFamily IS NOT NULL
                   AND (af.AreaFamily IS NULL OR cf.ChargeFamily <> af.AreaFamily)
                  THEN 1 ELSE 0 END AS BIT)     AS IsFoundDownstream,
        re.RecordedAt
    FROM Hit h
    INNER JOIN Workorder.RejectEvent re ON re.Id = h.Id
    INNER JOIN Quality.DefectCode    dc ON dc.Id = re.DefectCodeId
    CROSS APPLY Oee.ufn_AreaFamily(re.CellLocationId) af
    OUTER APPLY Oee.ufn_RejectChargeFamily(re.DefectCodeId, af.AreaFamily) cf
);
GO
