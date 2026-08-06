-- ============================================================
-- Repeatable:  R__Lots_AimPoolConfig_Get.sql
-- Author:      Blue Ridge Automation
-- Version:     1.2
-- Description: Returns the single-row AIM pool config (Arc 2 Phase 7 read). UpdatedAt
--              CAST to ET DATETIME2(3). Read proc, no OUTPUT params.
--              v1.1 (Migration 0052): adds AIM connection settings (AimBaseUrl,
--              AimCompanyCode, AimPathToken) and post-backlog escalation ages
--              (PostWarningAgeMinutes, PostCriticalAgeMinutes).
--              v1.2 (Migration 0053): adds AimPostingEnabled -- the transport-layer
--              gate BlueRidge.Lots.AimHttp._config() reads before making any AIM
--              network call. Defaults to 0 (off).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimPoolConfig_Get
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Id                     AS Id,
        c.TargetBufferDepth      AS TargetBufferDepth,
        c.TopupThreshold         AS TopupThreshold,
        c.AlarmWarningDepth      AS AlarmWarningDepth,
        c.AlarmCriticalDepth     AS AlarmCriticalDepth,
        c.AimBaseUrl             AS AimBaseUrl,
        c.AimCompanyCode         AS AimCompanyCode,
        c.AimPathToken           AS AimPathToken,
        c.PostWarningAgeMinutes  AS PostWarningAgeMinutes,
        c.PostCriticalAgeMinutes AS PostCriticalAgeMinutes,
        c.AimPostingEnabled      AS AimPostingEnabled,
        CAST(c.UpdatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'
             AS DATETIME2(3))    AS UpdatedAtEt,
        c.UpdatedByUserId        AS UpdatedByUserId
    FROM Lots.AimPoolConfig c
    WHERE c.Id = 1;
END;
GO
