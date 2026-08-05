-- ============================================================
-- Repeatable:  R__Tools_ufn_ShotStatus.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-04
-- Version:     1.0
-- Description: Inline TVF deriving a die's shot-limit indicators from its
--              materialized ShotCount + nullable ShotLimit. Single source of
--              the near/over rule (threshold 90%); reused by Tools.Tool_Get,
--              Tools.Tool_List, and Tools.Tool_GetShotStatusForCell via
--              CROSS APPLY. Always returns exactly one row.
--                ShotsRemaining : ShotLimit - ShotCount (NULL when no limit; negative when over)
--                PercentOfLimit : ShotCount * 100 / ShotLimit (NULL when no/zero limit)
--                IsNearLimit    : 1 when limit set and 90% <= ShotCount < limit
--                IsOverLimit    : 1 when limit set and ShotCount >= limit
--              IsNearLimit and IsOverLimit are mutually exclusive.
-- ============================================================
CREATE OR ALTER FUNCTION Tools.ufn_ShotStatus (@ShotCount INT, @ShotLimit INT)
RETURNS TABLE
AS RETURN
    SELECT
        CASE WHEN @ShotLimit IS NULL THEN NULL
             ELSE @ShotLimit - @ShotCount END AS ShotsRemaining,
        CASE WHEN @ShotLimit IS NULL OR @ShotLimit = 0 THEN NULL
             ELSE CAST(CAST(@ShotCount AS DECIMAL(18,4)) * 100.0 / @ShotLimit AS DECIMAL(11,2)) END AS PercentOfLimit,
        CAST(CASE WHEN @ShotLimit IS NOT NULL AND @ShotLimit > 0
                   AND @ShotCount >= 0.9 * @ShotLimit AND @ShotCount < @ShotLimit
                  THEN 1 ELSE 0 END AS BIT) AS IsNearLimit,
        CAST(CASE WHEN @ShotLimit IS NOT NULL AND @ShotCount >= @ShotLimit
                  THEN 1 ELSE 0 END AS BIT) AS IsOverLimit;
GO
