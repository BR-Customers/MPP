-- =============================================
-- Procedure:   Oee.ShiftSummary_ComputeCore
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   Replaces one shift's rows in Oee.ShiftSummary with Oee.ufn_ShiftSummaryRows,
--   stamped with ComputedAt and Oee.ufn_ShiftInputFingerprint (OEE dashboard
--   spec docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.1 sec
--   6.7, 6.8). The ONE place the summary is written: ShiftSummary_Compute,
--   ShiftSummary_RecomputeRange and ShiftSummary_RefreshChanged all EXEC it.
--
--   SILENT (no result set) and opens NO transaction of its own, like the
--   Audit.Audit_Log* writers: the calling status-row proc owns the transaction
--   and the reply, so this can be EXEC'd from a proc that is itself captured by
--   INSERT-EXEC. It does not check that the shift is closed -- callers do (the
--   shift in progress is never stored).
--
--   No audit row: the summary is derived data, recomputable at any time from
--   the audited source rows.
--
-- Parameters:
--   @ShiftId BIGINT - the shift to (re)compute.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftSummary_ComputeCore
    @ShiftId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fp VARBINARY(32) = (SELECT Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@ShiftId));
    DECLARE @At DATETIME2(3)  = SYSUTCDATETIME();

    DELETE FROM Oee.ShiftSummary WHERE ShiftId = @ShiftId;

    INSERT INTO Oee.ShiftSummary (
        ShiftId, LocationId, RowKind, AreaFamily, ProductionAreaId, ParentUnitLocationId,
        PlannedMinutes, PlannedDowntimeMinutes, UnplannedDowntimeMinutes, BaseMinutes,
        EffectiveUnplannedMinutes, DowntimeEventCount, NoReasonCount, NoReasonMinutes,
        Good, Scrap, NonRejectScrap, FoundDownstreamScrap, UnplacedScrap,
        LastToolId, IsActive, ComputedAt, InputFingerprint)
    SELECT r.ShiftId, r.LocationId, r.RowKind, r.AreaFamily, r.ProductionAreaId, r.ParentUnitLocationId,
           r.PlannedMinutes, r.PlannedDowntimeMinutes, r.UnplannedDowntimeMinutes, r.BaseMinutes,
           r.EffectiveUnplannedMinutes, r.DowntimeEventCount, r.NoReasonCount, r.NoReasonMinutes,
           r.Good, r.Scrap, r.NonRejectScrap, r.FoundDownstreamScrap, r.UnplacedScrap,
           r.LastToolId, r.IsActive, @At, ISNULL(@Fp, 0x)
    FROM Oee.ufn_ShiftSummaryRows(@ShiftId) r;
END;
GO
