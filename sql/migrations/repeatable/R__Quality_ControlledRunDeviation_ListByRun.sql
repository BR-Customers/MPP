-- ============================================================
-- Repeatable:  R__Quality_ControlledRunDeviation_ListByRun.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. The signed deviations on one super-lot, newest first.
--              Timestamps Eastern. No status row, no OUTPUT params (FDS-11-011).
--              Empty set = none.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRunDeviation_ListByRun
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        d.Id,
        d.DeviationNumber,
        d.ExternalReference,
        d.Description,
        d.Justification,
        df.Code AS DefectCode,
        df.Description AS DefectDescription,
        d.AffectedQuantity,
        u.Initials AS SignedByInitials,
        u.DisplayName AS SignedByName,
        CAST(d.RaisedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RaisedAt
    FROM Quality.ControlledRunDeviation d
    LEFT JOIN Quality.DefectCode df ON df.Id = d.DefectCodeId
    LEFT JOIN Location.AppUser u    ON u.Id = d.RaisedByUserId
    WHERE d.ControlledRunId = @Id
    ORDER BY d.RaisedAt DESC, d.Id DESC;
END;
GO
