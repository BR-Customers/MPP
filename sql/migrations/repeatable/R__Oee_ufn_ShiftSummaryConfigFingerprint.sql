-- =============================================
-- Repeatable:  R__Oee_ufn_ShiftSummaryConfigFingerprint.sql
-- Object:      Oee.ufn_ShiftSummaryConfigFingerprint
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   A fingerprint of the configuration that changes how EXISTING rows are read
--   into the stored OEE figures (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 6.8,
--   D22). Oee.ShiftSummary_RefreshChanged compares it with
--   Oee.ShiftSummaryConfig.ConfigFingerprint; when it differs, every stored
--   shift is stale and is recomputed newest first, a bounded number per run.
--   No configuration proc has to call anything, and a configuration writer
--   added later is covered.
--
--   Over:
--     Oee.ShiftSchedule        times, days, effective dates, DeprecatedAt
--     Oee.DowntimeReasonCode   IsExcused, DeprecatedAt     (planned vs unplanned)
--     Quality.DefectCode       ChargeToPartyId, IsNonRejectScrap, DeprecatedAt
--     Location.Location        IsOeeEnabled, ParentLocationId,
--                              LocationTypeDefinitionId, DeprecatedAt
--     Location.LocationTypeDefinition  Code                (area family)
--   Shift overrides and tool assignments are per day / per press and live in
--   the per-shift Oee.ufn_ShiftInputFingerprint instead.
--
--   Inline TVF: one row, (Fingerprint VARBINARY(32)).
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftSummaryConfigFingerprint ()
RETURNS TABLE
AS
RETURN
(
    SELECT HASHBYTES('SHA2_256', CONCAT(
        N'SS', (SELECT COUNT(*) FROM Oee.ShiftSchedule), N':',
               ISNULL((SELECT CHECKSUM_AGG(CHECKSUM(Id, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, DeprecatedAt))
                       FROM Oee.ShiftSchedule), 0),
        N'|RC', (SELECT COUNT(*) FROM Oee.DowntimeReasonCode), N':',
               ISNULL((SELECT CHECKSUM_AGG(CHECKSUM(Id, IsExcused, DeprecatedAt)) FROM Oee.DowntimeReasonCode), 0),
        N'|DC', (SELECT COUNT(*) FROM Quality.DefectCode), N':',
               ISNULL((SELECT CHECKSUM_AGG(CHECKSUM(Id, ChargeToPartyId, IsNonRejectScrap, DeprecatedAt)) FROM Quality.DefectCode), 0),
        N'|L', (SELECT COUNT(*) FROM Location.Location), N':',
               ISNULL((SELECT CHECKSUM_AGG(CHECKSUM(Id, IsOeeEnabled, ParentLocationId, LocationTypeDefinitionId, DeprecatedAt))
                       FROM Location.Location), 0),
        N'|LT', (SELECT COUNT(*) FROM Location.LocationTypeDefinition), N':',
               ISNULL((SELECT CHECKSUM_AGG(CHECKSUM(Id, Code)) FROM Location.LocationTypeDefinition), 0)
    )) AS Fingerprint
);
GO
