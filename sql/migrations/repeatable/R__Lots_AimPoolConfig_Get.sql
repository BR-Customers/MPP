-- ============================================================
-- Repeatable:  R__Lots_AimPoolConfig_Get.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Returns the single-row AIM pool config (Arc 2 Phase 7 read). UpdatedAt
--              CAST to ET DATETIME2(3). Read proc, no OUTPUT params.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimPoolConfig_Get
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        Id,
        TargetBufferDepth,
        TopupThreshold,
        AlarmWarningDepth,
        AlarmCriticalDepth,
        CAST(UpdatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS UpdatedAt,
        UpdatedByUserId
    FROM Lots.AimPoolConfig
    WHERE Id = 1;
END;
GO
