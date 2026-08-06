-- ============================================================
-- Repeatable:  R__Lots_AimPoolConfig_Update.sql
-- Author:      Blue Ridge Automation
-- Version:     1.3
-- Description: Updates the single-row AIM pool config thresholds (Arc 2 Phase 7 admin;
--              AD-elevated). Upserts the Id=1 row. Attribution via UpdatedAt /
--              UpdatedByUserId. No OUTPUT params; single terminal SELECT @Status,@Message.
--              (Full ConfigLog before/after diff is a noted refinement.)
--              v1.1 (Migration 0052): adds AIM connection settings (AimBaseUrl,
--              AimCompanyCode, AimPathToken) and post-backlog escalation ages
--              (PostWarningAgeMinutes, PostCriticalAgeMinutes). New params carry
--              defaults so existing callers passing only the original four still
--              compile.
--              v1.2: all five new params now default to NULL and are COALESCEd
--              against the existing row in the UPDATE (preserve-on-omit) -- the
--              threshold-admin screen (AimPoolConfig view -> code.py update() ->
--              AimPoolConfig_Update NQ) legitimately calls this proc with only the
--              original four threshold arguments, and SQL Server applies proc
--              defaults for every omitted parameter. With literal defaults (30/120,
--              NULL/NULL/NULL) that unconditionally overwrote the columns, every
--              threshold-only save was silently NULLing the AIM connection settings
--              and resetting the escalation ages. See sql/tests/0029.../040_AimPoolConfig.sql.
--              v1.3 (Migration 0053): adds @AimPostingEnabled, same preserve-on-omit
--              pattern (NULL = leave unchanged) as the v1.2 columns. This is the
--              transport-layer gate AimHttp._config() reads before any AIM network
--              call -- a four-arg threshold-only save must never silently flip it.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.AimPoolConfig_Update
    @TargetBufferDepth      INT,
    @TopupThreshold         INT,
    @AlarmWarningDepth      INT,
    @AlarmCriticalDepth     INT,
    @AimBaseUrl             NVARCHAR(200) = NULL,
    @AimCompanyCode         NVARCHAR(10)  = NULL,
    @AimPathToken           NVARCHAR(50)  = NULL,
    @PostWarningAgeMinutes  INT           = NULL,
    @PostCriticalAgeMinutes INT           = NULL,
    @AimPostingEnabled      BIT           = NULL,
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
        -- Preserve-on-omit: the threshold-admin screen calls this proc with only the
        -- original four threshold args, so @AimBaseUrl/@AimCompanyCode/@AimPathToken/
        -- @PostWarningAgeMinutes/@PostCriticalAgeMinutes arrive as NULL (their proc
        -- defaults) on that path. COALESCE against the existing column so an omitted
        -- parameter keeps the stored value instead of being blanked. Deliberate
        -- consequence: this proc can never CLEAR a connection setting to NULL/empty --
        -- only set it to a new value -- since NULL-in reads as "leave unchanged."
        -- Same rule for @AimPostingEnabled: omitted (NULL) means "leave the gate as
        -- it was," never "turn it off" or "turn it on" -- a four-arg threshold-only
        -- save must not be able to silently flip the AIM transport gate either way.
        UPDATE Lots.AimPoolConfig
           SET TargetBufferDepth      = @TargetBufferDepth,
               TopupThreshold         = @TopupThreshold,
               AlarmWarningDepth      = @AlarmWarningDepth,
               AlarmCriticalDepth     = @AlarmCriticalDepth,
               AimBaseUrl             = COALESCE(@AimBaseUrl, AimBaseUrl),
               AimCompanyCode         = COALESCE(@AimCompanyCode, AimCompanyCode),
               AimPathToken           = COALESCE(@AimPathToken, AimPathToken),
               PostWarningAgeMinutes  = COALESCE(@PostWarningAgeMinutes, PostWarningAgeMinutes),
               PostCriticalAgeMinutes = COALESCE(@PostCriticalAgeMinutes, PostCriticalAgeMinutes),
               AimPostingEnabled      = COALESCE(@AimPostingEnabled, AimPostingEnabled),
               UpdatedAt              = SYSUTCDATETIME(),
               UpdatedByUserId        = @AppUserId
         WHERE Id = 1;
        IF @@ROWCOUNT = 0
            -- No existing row to preserve values from: connection settings land as
            -- whatever was passed (NULL if omitted); age columns fall back to their
            -- historical literal defaults (30/120) since ISNULL has no "unchanged" to
            -- reach for. AimPostingEnabled falls back to 0 (off) for the same reason --
            -- the fail-safe default, never fail-open.
            INSERT INTO Lots.AimPoolConfig (
                Id, TargetBufferDepth, TopupThreshold, AlarmWarningDepth, AlarmCriticalDepth,
                AimBaseUrl, AimCompanyCode, AimPathToken, PostWarningAgeMinutes, PostCriticalAgeMinutes,
                AimPostingEnabled, UpdatedAt, UpdatedByUserId)
            VALUES (
                1, @TargetBufferDepth, @TopupThreshold, @AlarmWarningDepth, @AlarmCriticalDepth,
                @AimBaseUrl, @AimCompanyCode, @AimPathToken,
                ISNULL(@PostWarningAgeMinutes, 30), ISNULL(@PostCriticalAgeMinutes, 120),
                ISNULL(@AimPostingEnabled, 0),
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
