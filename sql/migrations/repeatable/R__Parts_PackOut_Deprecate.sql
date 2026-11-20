-- =============================================
-- Procedure:   Parts.PackOut_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-11-20
-- Version:     1.0
--
-- Description:
--   Removes a named pack-out: retires the header and its active version and
--   deletes every terminal pick on it (those terminals run the default again).
--   Boxes already opened on it keep their version row untouched.
--
--   Refuses the DEFAULT while the part has other active pack-outs for the
--   method -- make another one the default first -- so "a part with pack-outs
--   always has a default" holds without a silent auto-promotion. The only
--   pack-out may be removed (the part then has none for the method, as
--   clearing a method did before 0136).
--
--   Status-row mutation (FDS-11-011). Audited (PackOutDeprecated).
--
-- Parameters: @PackOutId BIGINT, @AppUserId BIGINT.
-- Result: Status BIT, Message NVARCHAR(500).
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version (named pack-outs).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.PackOut_Deprecate
    @PackOutId BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Parts.PackOut_Deprecate';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @PackOutId AS PackOutId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @ItemId BIGINT, @Method NVARCHAR(20), @Name NVARCHAR(50), @IsDefault BIT, @Picks INT;
    DECLARE @Activity NVARCHAR(500), @OldValue NVARCHAR(MAX);

    BEGIN TRY
        IF @PackOutId IS NULL OR @AppUserId IS NULL
            SET @Message = N'Required parameter missing (PackOutId, AppUserId).';
        ELSE
        BEGIN
            SELECT @ItemId = ItemId, @Method = ClosureMethod, @Name = Name, @IsDefault = IsDefault
            FROM Parts.PackOut WHERE Id = @PackOutId AND DeprecatedAt IS NULL;
            IF @ItemId IS NULL
                SET @Message = N'Pack-out not found or already removed.';
            ELSE IF @IsDefault = 1 AND EXISTS (SELECT 1 FROM Parts.PackOut WHERE ItemId = @ItemId AND ClosureMethod = @Method
                                               AND DeprecatedAt IS NULL AND Id <> @PackOutId)
                SET @Message = N'''' + @Name + N''' is the default. Make another pack-out the default before removing this one.';
            ELSE
                SET @Message = NULL;
        END

        IF @Message IS NOT NULL
        BEGIN
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
                    @LogEventTypeCode = N'PackOutDeprecated', @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @OldValue = (SELECT p.Id, p.Name, p.ClosureMethod, p.IsDefault,
                JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = p.ItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                JSON_QUERY((SELECT cc.Id, cc.VersionNumber, cc.TraysPerContainer, cc.PartsPerTray, cc.TargetWeight, cc.ToleranceWeight
                            FROM Parts.ContainerConfig cc WHERE cc.PackOutId = p.Id AND cc.DeprecatedAt IS NULL FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Version
            FROM Parts.PackOut p WHERE p.Id = @PackOutId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        DELETE FROM Location.TerminalPackOutSelection WHERE PackOutId = @PackOutId;
        SET @Picks = @@ROWCOUNT;
        UPDATE Parts.ContainerConfig SET DeprecatedAt = SYSUTCDATETIME() WHERE PackOutId = @PackOutId AND DeprecatedAt IS NULL;
        UPDATE Parts.PackOut SET DeprecatedAt = SYSUTCDATETIME(), DeprecatedByUserId = @AppUserId, IsDefault = 0
        WHERE Id = @PackOutId;

        SET @Activity = Audit.ufn_TruncateActivity((SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId)
            + N' ' + Audit.ufn_MidDot() + N' Pack-Out ' + Audit.ufn_MidDot() + N' ' + @Name + N' ('
            + (SELECT Name FROM Parts.ClosureMethodCode WHERE Code = @Method) + N') Deprecated'
            + CASE WHEN @Picks > 0 THEN N'; ' + CAST(@Picks AS NVARCHAR(10)) + N' terminal pick(s) cleared' ELSE N'' END);
        EXEC Audit.Audit_LogConfigChange @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
            @LogEventTypeCode = N'PackOutDeprecated', @LogSeverityCode = N'Info', @Description = @Activity,
            @OldValue = @OldValue, @NewValue = NULL;
        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Pack-out ''' + @Name + N''' removed.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'PackOut', @EntityId = @PackOutId,
                @LogEventTypeCode = N'PackOutDeprecated', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
