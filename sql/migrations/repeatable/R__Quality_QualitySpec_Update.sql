-- =============================================
-- Procedure:   Quality.QualitySpec_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Updates the header fields of an existing QualitySpec.
--   Only Name, Description, ItemId, and OperationTemplateId
--   can be modified. Existing versions remain unchanged.
--
-- Parameters (input):
--   @Id BIGINT - Required.
--   @Name NVARCHAR(200) - Required.
--   @ItemId BIGINT NULL - Optional. Must be active if provided.
--   @OperationTemplateId BIGINT NULL - Optional. Must be active if provided.
--   @Description NVARCHAR(500) NULL - Optional.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Quality.QualitySpec, Parts.Item, Parts.OperationTemplate
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention: SUBJECT . CATEGORY
--                       . ACTION narrative Description with field-diffs
--                       (<PN> . Quality Spec "<Name>" . Updated
--                       Name "old"->"new"; Description "old"->"new") +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpec_Update
    @Id                  BIGINT,
    @Name                NVARCHAR(200),
    @ItemId              BIGINT         = NULL,
    @OperationTemplateId BIGINT         = NULL,
    @Description         NVARCHAR(500)  = NULL,
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpec_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @Name AS Name, @ItemId AS ItemId,
                @OperationTemplateId AS OperationTemplateId, @Description AS Description
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @Name IS NULL OR LTRIM(RTRIM(@Name)) = N'' OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Existence checks
        -- ====================
        DECLARE @OldName        NVARCHAR(200);
        DECLARE @OldItemId      BIGINT;
        DECLARE @OldOpTemplId   BIGINT;
        DECLARE @OldDesc        NVARCHAR(500);
        DECLARE @RowExists      BIT = 0;

        SELECT @OldName      = Name,
               @OldItemId    = ItemId,
               @OldOpTemplId = OperationTemplateId,
               @OldDesc      = Description,
               @RowExists    = 1
        FROM Quality.QualitySpec WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Quality specification not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- FK existence checks
        -- ====================
        IF @ItemId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated ItemId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @OperationTemplateId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated OperationTemplateId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpec',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Audit narrative + resolved JSON (built from PRE-mutation state)
        -- ====================
        DECLARE @NewName NVARCHAR(200) = LTRIM(RTRIM(@Name));

        -- Subject: Item PartNumber [- Description] when item-linked; else spec name.
        -- PN prefix present only when ItemId (NEW) resolves.
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        IF @ItemId IS NOT NULL
            SELECT @PartNumber = PartNumber, @ItemDesc = Description
            FROM Parts.Item WHERE Id = @ItemId;

        DECLARE @Subject NVARCHAR(600) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber
                      + CASE WHEN @ItemDesc IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END
                      + N' ' + Audit.ufn_MidDot() + N' '
                 ELSE N'' END;

        -- Field diffs: Field "old"->"new" (only changed fields)
        DECLARE @Diffs NVARCHAR(MAX) = STUFF(
            CONCAT(
                CASE WHEN ISNULL(@OldName, N'') <> ISNULL(@NewName, N'')
                     THEN N', Name "' + ISNULL(@OldName, N'') + N'"' + NCHAR(8594) + N'"' + ISNULL(@NewName, N'') + N'"'
                     ELSE N'' END,
                CASE WHEN ISNULL(@OldDesc, N'') <> ISNULL(@Description, N'')
                     THEN N', Description "' + ISNULL(@OldDesc, N'') + N'"' + NCHAR(8594) + N'"' + ISNULL(@Description, N'') + N'"'
                     ELSE N'' END
            ),
            1, 2, N''  -- strip leading ", "
        );

        IF @Diffs IS NULL OR @Diffs = N''
            SET @Diffs = N'no header field changes';

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N'Quality Spec "' + @NewName + N'" ' +
            Audit.ufn_MidDot() + N' Updated ' + @Diffs;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Resolved-FK OldValue (pre-mutation state)
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                @OldName AS Name,
                @OldDesc AS Description,
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                 FROM Parts.Item i WHERE i.Id = @OldItemId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Item,
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                 FROM Parts.OperationTemplate ot WHERE ot.Id = @OldOpTemplId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS OperationTemplate
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- Resolved-FK NewValue (post-mutation intent)
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                @NewName AS Name,
                @Description AS Description,
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                 FROM Parts.Item i WHERE i.Id = @ItemId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS Item,
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                 FROM Parts.OperationTemplate ot WHERE ot.Id = @OperationTemplateId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))            AS OperationTemplate
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Quality.QualitySpec SET
            Name                = @NewName,
            ItemId              = @ItemId,
            OperationTemplateId = @OperationTemplateId,
            Description         = @Description
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpec',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Quality specification updated successfully.';
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
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'QualitySpec',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;

        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
