-- =============================================
-- Procedure:   Quality.QualitySpecVersion_GetActiveForSpec
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     1.1
--
-- Description:
--   Returns the currently active (published, non-deprecated) version
--   for a given QualitySpec. Returns the most recent published
--   version by EffectiveFrom where EffectiveFrom <= now and
--   DeprecatedAt IS NULL.
--
--   Optionally accepts @AsOfDate to query historical versions.
--
-- Parameters (input):
--   @QualitySpecId BIGINT - Required.
--   @AsOfDate DATETIME2(3) NULL - Point-in-time. NULL → SYSUTCDATETIME().
--
-- Returns (result set):
--   Single row (or zero if no active version).
--
-- Dependencies:
--   Tables: Quality.QualitySpecVersion, Quality.QualitySpecAttribute
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-05-29 - 1.1 - Added deterministic tiebreaker (VersionNumber DESC) so
--                       equal-EffectiveFrom publishes resolve consistently.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_GetActiveForSpec
    @QualitySpecId BIGINT,
    @AsOfDate      DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AsOf DATETIME2(3) = ISNULL(@AsOfDate, SYSUTCDATETIME());

    SELECT TOP 1
        qsv.Id,
        qsv.QualitySpecId,
        qsv.VersionNumber,
        qsv.EffectiveFrom,
        qsv.PublishedAt,
        qsv.DeprecatedAt,
        N'Published'          AS State,
        qsv.CreatedByUserId,
        au.DisplayName        AS CreatedByDisplayName,
        qsv.CreatedAt,
        (SELECT COUNT(*) FROM Quality.QualitySpecAttribute WHERE QualitySpecVersionId = qsv.Id) AS AttributeCount
    FROM Quality.QualitySpecVersion qsv
    LEFT JOIN Location.AppUser au ON qsv.CreatedByUserId = au.Id
    WHERE qsv.QualitySpecId = @QualitySpecId
      AND qsv.PublishedAt IS NOT NULL
      AND qsv.DeprecatedAt IS NULL
      AND qsv.EffectiveFrom <= @AsOf
    ORDER BY qsv.EffectiveFrom DESC, qsv.VersionNumber DESC;
END
GO
