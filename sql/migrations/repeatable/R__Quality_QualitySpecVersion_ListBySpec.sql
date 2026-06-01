-- =============================================
-- Procedure:   Quality.QualitySpecVersion_ListBySpec
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     1.1
--
-- Description:
--   Returns all versions for a given QualitySpec, ordered by
--   VersionNumber descending (newest first).
--
-- Parameters (input):
--   @QualitySpecId BIGINT - Required.
--
-- Returns (result set):
--   All versions with state indicators and attribute counts.
--
-- Dependencies:
--   Tables: Quality.QualitySpecVersion, Quality.QualitySpecAttribute
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-05-29 - 1.1 - Date-resolved per-version State: Active / Scheduled /
--                       Superseded in addition to Draft / Deprecated. The
--                       single live published version (max EffectiveFrom <= now,
--                       non-deprecated) is Active; future-effective published
--                       versions are Scheduled; other published versions are
--                       Superseded.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_ListBySpec
    @QualitySpecId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ActiveId BIGINT = (
        SELECT TOP 1 Id FROM Quality.QualitySpecVersion
        WHERE QualitySpecId = @QualitySpecId AND PublishedAt IS NOT NULL
          AND DeprecatedAt IS NULL AND EffectiveFrom <= SYSUTCDATETIME()
        ORDER BY EffectiveFrom DESC, VersionNumber DESC);

    SELECT
        qsv.Id,
        qsv.QualitySpecId,
        qsv.VersionNumber,
        qsv.EffectiveFrom,
        qsv.PublishedAt,
        qsv.DeprecatedAt,
        CASE
            WHEN qsv.DeprecatedAt IS NOT NULL THEN N'Deprecated'
            WHEN qsv.PublishedAt IS NULL THEN N'Draft'
            WHEN qsv.Id = @ActiveId THEN N'Active'
            WHEN qsv.EffectiveFrom > SYSUTCDATETIME() THEN N'Scheduled'
            ELSE N'Superseded'
        END                   AS State,
        qsv.CreatedByUserId,
        au.DisplayName        AS CreatedByDisplayName,
        qsv.CreatedAt,
        (SELECT COUNT(*) FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = qsv.Id) AS AttributeCount
    FROM Quality.QualitySpecVersion qsv
    LEFT JOIN Location.AppUser au ON qsv.CreatedByUserId = au.Id
    WHERE qsv.QualitySpecId = @QualitySpecId
    ORDER BY qsv.VersionNumber DESC;
END
GO
