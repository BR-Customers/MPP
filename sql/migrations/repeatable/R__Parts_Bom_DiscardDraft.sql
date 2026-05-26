-- =============================================
-- Procedure:   Parts.Bom_DiscardDraft
-- Author:      Blue Ridge Automation
-- Created:     2026-05-26
-- Version:     1.0
--
-- Description:
--   Physically deletes a Draft BOM and all of its BomLine children.
--   Target must be Draft (PublishedAt IS NULL AND DeprecatedAt IS NULL).
--   Captures full pre-delete state as OldValue in Audit.ConfigLog so the
--   draft is forensically reconstructable if needed.
--
--   Rejects published or deprecated BOMs (those are immutable; use
--   Bom_Deprecate for published ones).
--
-- Parameters (input):
--   @Id        BIGINT - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Status (BIT), Message (NVARCHAR).
--
-- Change Log:
--   2026-05-26 - 1.0 - Initial.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Bom_DiscardDraft
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Bom_DiscardDraft';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @VersionNumber       INT          = NULL;
    DECLARE @ExistingPublishedAt DATETIME2(3) = NULL;
    DECLARE @ExistingDeprecatedAt DATETIME2(3) = NULL;
    DECLARE @OldValue            NVARCHAR(MAX);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @VersionNumber        = VersionNumber,
               @ExistingPublishedAt  = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt
        FROM Parts.Bom WHERE Id = @Id;

        IF @VersionNumber IS NULL
        BEGIN
            SET @Message = N'BOM not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL OR @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot discard a published or deprecated BOM.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Capture full pre-delete state for audit
        SET @OldValue = (
            SELECT
                (SELECT Id, ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt
                 FROM Parts.Bom WHERE Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Bom,
                JSON_QUERY((
                    SELECT Id, ChildItemId, QtyPer, UomId, SortOrder
                    FROM Parts.BomLine
                    WHERE BomId = @Id
                    ORDER BY SortOrder
                    FOR JSON PATH
                )) AS Lines
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        BEGIN TRANSACTION;

        DELETE FROM Parts.BomLine WHERE BomId = @Id;
        DELETE FROM Parts.Bom WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Bom',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deleted',
            @LogSeverityCode   = N'Info',
            @Description       = N'Draft BOM discarded (physically deleted).',
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Draft discarded.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Deleted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
