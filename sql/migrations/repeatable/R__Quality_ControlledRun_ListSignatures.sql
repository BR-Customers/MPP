-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ListSignatures.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. Every signature on one super-lot, newest first: who signed,
--              when, with what meaning, the exact statement they signed, and a
--              one-line Summary of what it covered (built here so no view
--              assembles prose).
--
--              A signature reaches a super-lot through the thing it signed: a
--              release (Quality.ControlledRunRelease) or a deviation
--              (Quality.ControlledRunDeviation).
--
--              Timestamps Eastern. No status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ListSignatures
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        s.Id AS SignatureId,
        CAST(s.SignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS SignedAt,
        u.Initials    AS SignedByInitials,
        u.DisplayName AS SignedByName,
        sm.Code       AS MeaningCode,
        sm.Name       AS MeaningName,
        s.Statement,
        CAST(x.Summary AS NVARCHAR(300)) AS Summary
    FROM (
        SELECT rl.SignatureId,
               N'Release of ' + CAST(rl.MemberCount AS NVARCHAR(10)) + N' member'
               + CASE WHEN rl.MemberCount = 1 THEN N'' ELSE N's' END
               + CASE WHEN rl.Remarks IS NOT NULL THEN N' - ' + LEFT(rl.Remarks, 200) ELSE N'' END AS Summary
        FROM Quality.ControlledRunRelease rl
        WHERE rl.ControlledRunId = @Id
        UNION ALL
        SELECT d.SignatureId,
               N'Deviation ' + d.DeviationNumber + N' - ' + LEFT(d.Description, 200)
        FROM Quality.ControlledRunDeviation d
        WHERE d.ControlledRunId = @Id
    ) x
    INNER JOIN Quality.Signature s         ON s.Id = x.SignatureId
    INNER JOIN Quality.SignatureMeaning sm ON sm.Id = s.SignatureMeaningId
    LEFT JOIN Location.AppUser u           ON u.Id = s.AppUserId
    ORDER BY s.SignedAt DESC, s.Id DESC;
END;
GO
