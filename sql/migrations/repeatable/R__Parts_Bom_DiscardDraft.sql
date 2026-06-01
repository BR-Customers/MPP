-- =============================================
-- Procedure:   Parts.Bom_DiscardDraft
-- Author:      Blue Ridge Automation
-- Created:     2026-05-26
-- Version:     1.1
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
--   2026-05-29 - 1.1 - Audit-readability convention (Slice 3 BOMs):
--                       SUBJECT . CATEGORY . ACTION narrative Description
--                       (<PartNumber> . BOM v<N> (Draft) . Discarded; <K> lines
--                       discarded) + resolved-FK OldValue (full pre-delete
--                       snapshot, parent Item + ChildItem + Uom resolved);
--                       NewValue NULL.
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

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject resolution (convention SUBJECT): parent Item PartNumber [- Description]
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        SELECT @PartNumber = i.PartNumber, @ItemDesc = i.Description
        FROM Parts.Bom b
        INNER JOIN Parts.Item i ON i.Id = b.ParentItemId
        WHERE b.Id = @Id;

        DECLARE @Subject NVARCHAR(600) =
            @PartNumber + CASE WHEN @ItemDesc IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END;

        DECLARE @DiscardLineCount INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @Id);

        -- Activity: <PartNumber> . BOM v<N> (Draft) . Discarded; <K> lines discarded
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N' ' + Audit.ufn_MidDot() + N' BOM v' + CAST(@VersionNumber AS NVARCHAR(10)) +
            N' (Draft) ' + Audit.ufn_MidDot() + N' Discarded; ' +
            CAST(@DiscardLineCount AS NVARCHAR(10)) + N' lines discarded';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Capture full pre-delete state for audit (parent Item + ChildItem + Uom resolved)
        SET @OldValue = (
            SELECT
                JSON_QUERY((SELECT b.Id, b.VersionNumber, b.EffectiveFrom, b.PublishedAt, b.DeprecatedAt,
                    JSON_QUERY((SELECT pi.Id, pi.PartNumber, pi.Description
                     FROM Parts.Item pi WHERE pi.Id = b.ParentItemId
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ParentItem
                 FROM Parts.Bom b WHERE b.Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Bom,
                JSON_QUERY((
                    SELECT
                        bl.Id, bl.QtyPer, bl.SortOrder,
                        JSON_QUERY((SELECT ci.Id, ci.PartNumber, ci.Description
                         FROM Parts.Item ci WHERE ci.Id = bl.ChildItemId
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ChildItem,
                        JSON_QUERY((SELECT u.Id, u.Code, u.Name
                         FROM Parts.Uom u WHERE u.Id = bl.UomId
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Uom
                    FROM Parts.BomLine bl
                    WHERE bl.BomId = @Id
                    ORDER BY bl.SortOrder
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
            @Description       = @Activity,
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
