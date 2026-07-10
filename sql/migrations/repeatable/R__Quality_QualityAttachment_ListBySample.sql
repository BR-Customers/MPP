-- ============================================================
-- Repeatable:  R__Quality_QualityAttachment_ListBySample.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-08-013). Attachment metadata rows for one
--              inspection sample, newest first. UploadedAt is ET-converted at
--              the read boundary (UTC storage, Eastern display).
--
--              READ proc: no status row, no OUTPUT params (FDS-11-011).
--              Empty result set = no attachments.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.QualityAttachment_ListBySample
    @QualitySampleId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        qa.Id,
        qa.QualitySampleId,
        qa.FileName,
        qa.FileType,
        qa.FilePath,
        CAST(qa.UploadedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS UploadedAt,
        qa.UploadedByUserId,
        au.DisplayName AS UploadedByName
    FROM Quality.QualityAttachment qa
    INNER JOIN Location.AppUser au ON au.Id = qa.UploadedByUserId
    WHERE qa.QualitySampleId = @QualitySampleId
    ORDER BY qa.UploadedAt DESC, qa.Id DESC;
END;
GO
