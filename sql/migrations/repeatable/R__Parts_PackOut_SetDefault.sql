-- =============================================
-- Procedure:   Parts.PackOut_SetDefault
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Version:     1.0
--
-- Description:
--   Makes @PackOutId its part's default pack-out for its closure method (the
--   one a terminal with no pick runs). Clears the previous default in the same
--   transaction; UQ_PackOut_ActiveDefault is the backstop. Refuses a removed
--   pack-out and a no-op. Audited to Audit.ConfigLog (PackOutDefaultSet).
--   Status-row mutation (FDS-11-011).
--
-- Parameters: @PackOutId BIGINT, @AppUserId BIGINT.
-- Result: Status BIT, Message NVARCHAR(500).
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version (named pack-outs).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.PackOut_SetDefault
    @PackOutId BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Parts.PackOut_SetDefault';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @PackOutId AS PackOutId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @ItemId BIGINT, @Method NVARCHAR(20), @Name NVARCHAR(50), @IsDefault BIT, @OldDefaultId BIGINT, @OldDefaultName NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500), @OldValue NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        IF @PackOutId IS NULL OR @AppUserId IS NULL
            SET @Message = N'Required parameter missing (PackOutId, AppUserId).';
        ELSE
        BEGIN
            SELECT @ItemId = ItemId, @Method = ClosureMethod, @Name = Name, @IsDefault = IsDefault
            FROM Parts.PackOut WHERE Id = @PackOutId AND DeprecatedAt IS NULL;
            IF @ItemId IS NULL
                SET @Message = N'Pack-out not found or removed.';
            ELSE IF @IsDefault = 1
                SET @Message = N'''' + @Name + N''' is already the default.';
            ELSE
                SET @Message = NULL;
        END

        IF @Message IS NOT NULL
        BEGIN
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
                    @LogEventTypeCode = N'PackOutDefaultSet', @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @OldDefaultId = Id, @OldDefaultName = Name FROM Parts.PackOut
        WHERE ItemId = @ItemId AND ClosureMethod = @Method AND IsDefault = 1 AND DeprecatedAt IS NULL;

        BEGIN TRANSACTION;
        UPDATE Parts.PackOut SET IsDefault = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE ItemId = @ItemId AND ClosureMethod = @Method AND IsDefault = 1 AND DeprecatedAt IS NULL;
        UPDATE Parts.PackOut SET IsDefault = 1, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        WHERE Id = @PackOutId;

        SET @Activity = Audit.ufn_TruncateActivity((SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId)
            + N' ' + Audit.ufn_MidDot() + N' Pack-Out ' + Audit.ufn_MidDot() + N' Default ('
            + (SELECT Name FROM Parts.ClosureMethodCode WHERE Code = @Method) + N') '
            + ISNULL(@OldDefaultName, N'(none)') + N' -> ' + @Name);
        SET @OldValue = (SELECT @OldDefaultId AS Id, @OldDefaultName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @NewValue = (SELECT @PackOutId AS Id, @Name AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogConfigChange @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
            @LogEventTypeCode = N'PackOutDefaultSet', @LogSeverityCode = N'Info', @Description = @Activity,
            @OldValue = @OldValue, @NewValue = @NewValue;
        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'''' + @Name + N''' is now the default.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
                @LogEventTypeCode = N'PackOutDefaultSet', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
