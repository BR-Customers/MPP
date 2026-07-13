-- ============================================================
-- Repeatable:  R__Quality_QualityAttachment_Add.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-08-013). Records the METADATA of a file
--              attached to an inspection sample (CSV/XLSX/PDF/PNG/JPG stored on
--              the filesystem; the gateway file-path decision + upload UI are a
--              Designer follow-up -- this API surface is complete now).
--
--              @QualitySampleId is NULLable at the table level (an attachment
--              may be staged before its sample exists); when provided it must
--              resolve. No dedicated success-audit event type exists for
--              attachments in the Phase 9 seed set (LogEventType 63-66), so this
--              proc emits NO success audit row -- failures still log to
--              Audit.FailureLog. The attachment row itself (UploadedByUserId +
--              UploadedAt) is the attribution record.
--
--              FDS-11-011: all rejecting validations before BEGIN TRANSACTION;
--              CATCH is the only ROLLBACK site. Single terminal row:
--              Status, Message, NewId.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.QualityAttachment_Add
    @QualitySampleId BIGINT        = NULL,
    @FileName        NVARCHAR(260),
    @FileType        NVARCHAR(20),
    @FilePath        NVARCHAR(500),
    @AppUserId       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualityAttachment_Add';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @QualitySampleId AS QualitySampleId, @FileName AS FileName,
               @FileType AS FileType, @FilePath AS FilePath, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @FileName IS NULL OR LTRIM(RTRIM(@FileName)) = N''
           OR @FileType IS NULL OR LTRIM(RTRIM(@FileType)) = N''
           OR @FilePath IS NULL OR LTRIM(RTRIM(@FilePath)) = N''
           OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (FileName, FileType, FilePath, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                    @EntityId = @QualitySampleId, @LogEventTypeCode = N'InspectionRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. Sample must resolve when provided ----
        IF @QualitySampleId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Quality.QualitySample WHERE Id = @QualitySampleId)
        BEGIN
            SET @Message = N'QualitySample not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = @QualitySampleId, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        INSERT INTO Quality.QualityAttachment (
            QualitySampleId, FileName, FileType, FilePath, UploadedAt, UploadedByUserId
        )
        VALUES (
            @QualitySampleId, @FileName, @FileType, @FilePath, SYSUTCDATETIME(), @AppUserId
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Attachment metadata recorded.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = @QualitySampleId, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
