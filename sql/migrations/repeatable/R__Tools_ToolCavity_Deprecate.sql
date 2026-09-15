-- =============================================
-- Procedure:   Tools.ToolCavity_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-22
-- Version:     1.1
-- Changelog:   1.1 (2026-09-14) OPEN-BASKET GUARD. Rejects while the cavity
--              still holds an Open LOT.
--
--              WHY A CONFIG-TOOL PROC GREW A PLANT-FLOOR RULE.
--              Lots.Lot_GetOpenByTool -- the Die Cast screen's basket list --
--              is cavity-driven and filters tc.DeprecatedAt IS NULL. So
--              deprecating a cavity that holds an open basket made that basket
--              INVISIBLE on the floor while it stayed Open on the die: live
--              production with no surface to close it from, and shots the
--              die's life never gets credited. That was latent while nothing
--              read the count, and Tools.ToolAssignment_Release v1.1 now does
--              -- an invisible basket would have blocked a changeover the
--              operator had no way to clear. Closing the hole here stops it
--              being re-opened from the Config Tool rather than papering over
--              it at the press.
--
-- Description:
--   Soft-deletes a ToolCavity row. Row-lifecycle deprecation (distinct
--   from business state transitions like Closed / Scrapped handled by
--   ToolCavity_UpdateStatus). Rejects if the cavity holds an open basket.
--
--   Spec: docs/superpowers/specs/
--         2026-09-14-plant-floor-die-mount-popup-design.md (5.4.1)
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Tools.ToolCavity_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Tools.ToolCavity
                       WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'ToolCavity not found or already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ---- v1.1: open-basket guard (see header) ----
        IF EXISTS (SELECT 1
                   FROM Lots.Lot l
                   INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                   WHERE l.ToolCavityId = @Id
                     AND sc.Code = N'Open')
        BEGIN
            SET @Message = N'This cavity still has an open basket. Release or void it before deprecating the cavity.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE Tools.ToolCavity
        SET DeprecatedAt    = SYSUTCDATETIME(),
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ToolCavity',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = N'ToolCavity deprecated.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'ToolCavity deprecated successfully.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ToolCavity',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
