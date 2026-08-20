-- ============================================================
-- Repeatable:  R__Oee_Shift_GetForInstant.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
-- Description: Thin read wrapper over Oee.ufn_ShiftIdForInstant so the Ignition
--              layer can ask the SAME attribution question the stamping procs
--              ask (spec sec 4.2: the die-cast screen's shift PRESELECTION
--              becomes equipment-aware).
--
--              Exists because a Named Query cannot CROSS APPLY a TVF and still
--              read as a thin EXEC wrapper, and because routing the UI through
--              a proc keeps ONE definition of "which shift is this press on"
--              shared by the screen and the writes behind it.
--
--              The operator's shift PICKER stays authoritative -- this only
--              seeds it. Preselection is a UX nicety; attribution correctness
--              comes from the resolver + Oee.ShiftOverride_Restamp.
--
--              TIME BASIS (OI-38): @InstantUtc is UTC, defaulting to
--              SYSUTCDATETIME(). Everything local happens inside
--              Oee.ufn_ShiftIdForInstant. StartLocal / EndLocal / InstantLocal
--              come back as LOCAL Eastern DATETIME2(3) -- already display-ready,
--              no further conversion at the Ignition boundary, and NOT
--              datetimeoffset (a raw datetimeoffset breaks the JDBC result read).
--
--              Read proc: ONE result set, AT MOST one row. Empty = no shift runs
--              on this equipment at that instant, which is a real answer, not a
--              404. ShiftId may be NULL in a returned row -- a shift is scheduled
--              but has no runtime Oee.Shift instance. No OUTPUT params, no audit
--              (FDS-11-011).
--
-- Parameters:
--   @LocationId BIGINT       - OEE equipment (the terminal's cell). NULL = the
--                              plant-global answer, no override lookup.
--   @InstantUtc DATETIME2(3) - defaults to now (UTC).
--
-- Result set (0 or 1 row):
--   ShiftId, ShiftScheduleId, ScheduleName, BusinessDate, InstantLocal,
--   StartLocal, EndLocal, IsOverridden, ShiftOverrideId
--
-- Dependencies:
--   Funcs: Oee.ufn_ShiftIdForInstant
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (shift-override attribution, sec 4.2).
-- ============================================================
CREATE OR ALTER PROCEDURE Oee.Shift_GetForInstant
    @LocationId BIGINT       = NULL,
    @InstantUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Instant DATETIME2(3) = ISNULL(@InstantUtc, SYSUTCDATETIME());

    SELECT
        r.ShiftId,
        r.ShiftScheduleId,
        r.ScheduleName,
        r.BusinessDate,
        r.InstantLocal,
        r.StartLocal,
        r.EndLocal,
        r.IsOverridden,
        r.ShiftOverrideId
    FROM Oee.ufn_ShiftIdForInstant(@LocationId, @Instant) r;
END;
GO
