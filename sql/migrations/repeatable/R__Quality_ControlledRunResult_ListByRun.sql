-- ============================================================
-- Repeatable:  R__Quality_ControlledRunResult_ListByRun.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-19
-- Version:     1.1
-- Change Log:  2026-10-19 - 1.1 - IsApplied also when a Lots.VendorReturn (not cancelled) points
--                                 at the entry: a ReturnToSupplier result on a LOT member took
--                                 its pieces off the LOT (piece 5). CanVoid follows.
-- Description: READ. The inspection result entries of one super-lot, newest
--              first. @IncludeVoided = 0 (default) returns live entries only.
--
--              IsApplied = the entry took pieces off a LOT: a Scrap entry on a
--              LOT member (RejectEventId), or a ReturnToSupplier entry a
--              Lots.VendorReturn points at (cancel the return to undo it). A
--              Scrap entry with IsApplied = 0 was recorded against a container
--              and is not yet applied.
--              CanVoid   = Quality.ControlledRunResult_Void would accept it now.
--              It is a column so the screen never works that out for itself;
--              the proc remains the judge.
--
--              Timestamps Eastern. No status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRunResult_ListByRun
    @Id            BIGINT,
    @IncludeVoided BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 500
        rr.Id AS ResultId,
        ms.MemberId,
        ms.DisplayName,
        dc.Code AS DispositionCode,
        dc.Name AS DispositionName,
        rr.Quantity,
        df.Code AS DefectCode,
        df.Description AS DefectDescription,
        rr.Remarks,
        u.Initials AS RecordedByInitials,
        CAST(rr.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RecordedAt,
        CONVERT(BIT, CASE WHEN rr.RejectEventId IS NOT NULL OR ret.Applied = 1 THEN 1 ELSE 0 END) AS IsApplied,
        CONVERT(BIT, CASE WHEN rr.VoidedAt IS NOT NULL THEN 1 ELSE 0 END)      AS IsVoided,
        CONVERT(BIT, CASE WHEN rr.VoidedAt IS NULL AND rr.RejectEventId IS NULL AND ret.Applied = 0
                           AND ms.EndedAt IS NULL AND r.ControlledRunStatusId = 1 THEN 1 ELSE 0 END) AS CanVoid
    FROM Quality.ufn_ControlledRunMemberState(@Id) ms
    INNER JOIN Quality.ControlledRun r         ON r.Id = ms.ControlledRunId
    INNER JOIN Quality.ControlledRunResult rr  ON rr.ControlledRunMemberId = ms.MemberId
    INNER JOIN Quality.DispositionCode dc      ON dc.Id = rr.DispositionCodeId
    LEFT JOIN Quality.DefectCode df            ON df.Id = rr.DefectCodeId
    LEFT JOIN Location.AppUser u               ON u.Id = rr.RecordedByUserId
    CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM Lots.VendorReturn vr
                                          WHERE vr.ControlledRunResultId = rr.Id AND vr.CancelledAt IS NULL)
                             THEN 1 ELSE 0 END AS Applied) ret
    WHERE ISNULL(@IncludeVoided, 0) = 1 OR rr.VoidedAt IS NULL
    ORDER BY rr.RecordedAt DESC, rr.Id DESC;
END;
GO
