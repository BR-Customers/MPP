-- ============================================================
-- Repeatable:  R__Lots_AimPoolConfig_Update.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1
-- Description: Updates the single-row AIM pool config thresholds (Arc 2 Phase 7 admin;
--              AD-elevated). Upserts the Id=1 row. Attribution via UpdatedAt /
--              UpdatedByUserId. No OUTPUT params; single terminal SELECT @Status,@Message.
--              (Full ConfigLog before/after diff is a noted refinement.)
--              v1.1 (Migration 0049): adds AIM connection settings (AimBaseUrl,
--              AimCompanyCode, AimPathToken) and post-backlog escalation ages
--              (PostWarningAgeMinutes, PostCriticalAgeMinutes). New params carry
--              defaults so existing callers passing only the original four still
--              compile.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimPoolConfig_Update
    @TargetBufferDepth      INT,
    @TopupThreshold         INT,
    @AlarmWarningDepth      INT,
    @AlarmCriticalDepth     INT,
    @AimBaseUrl             NVARCHAR(200) = NULL,
    @AimCompanyCode         NVARCHAR(10)  = NULL,
    @AimPathToken           NVARCHAR(50)  = NULL,
    @PostWarningAgeMinutes  INT           = 30,
    @PostCriticalAgeMinutes INT           = 120,
    @AppUserId              BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    BEGIN TRY
        IF @TargetBufferDepth IS NULL OR @TopupThreshold IS NULL OR @AlarmWarningDepth IS NULL OR @AlarmCriticalDepth IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END
        IF @TargetBufferDepth < 0 OR @TopupThreshold < 0 OR @AlarmWarningDepth < 0 OR @AlarmCriticalDepth < 0
        BEGIN
            SET @Message = N'Thresholds must be non-negative.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;
        UPDATE Lots.AimPoolConfig
           SET TargetBufferDepth      = @TargetBufferDepth,
               TopupThreshold         = @TopupThreshold,
               AlarmWarningDepth      = @AlarmWarningDepth,
               AlarmCriticalDepth     = @AlarmCriticalDepth,
               AimBaseUrl             = @AimBaseUrl,
               AimCompanyCode         = @AimCompanyCode,
               AimPathToken           = @AimPathToken,
               PostWarningAgeMinutes  = @PostWarningAgeMinutes,
               PostCriticalAgeMinutes = @PostCriticalAgeMinutes,
               UpdatedAt              = SYSUTCDATETIME(),
               UpdatedByUserId        = @AppUserId
         WHERE Id = 1;
        IF @@ROWCOUNT = 0
            INSERT INTO Lots.AimPoolConfig (
                Id, TargetBufferDepth, TopupThreshold, AlarmWarningDepth, AlarmCriticalDepth,
                AimBaseUrl, AimCompanyCode, AimPathToken, PostWarningAgeMinutes, PostCriticalAgeMinutes,
                UpdatedAt, UpdatedByUserId)
            VALUES (
                1, @TargetBufferDepth, @TopupThreshold, @AlarmWarningDepth, @AlarmCriticalDepth,
                @AimBaseUrl, @AimCompanyCode, @AimPathToken, @PostWarningAgeMinutes, @PostCriticalAgeMinutes,
                SYSUTCDATETIME(), @AppUserId);
        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'AIM pool config updated.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
