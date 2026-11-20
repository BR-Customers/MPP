-- =============================================
-- Procedure: Workorder.ScalePartCode_Deprecate
-- Author:    Blue Ridge Automation
-- Created:   2026-11-20
-- Version:   1.0
--
-- Description:
--   Removes a learned scale part code (Config Tool, PLC Devices). The next
--   press with that code at that terminal is held and asks again. The row is
--   kept, deprecated, as history. Audited as ScalePartCodeRemoved.
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 13.
--
--   Status-row mutation (FDS-11-011): every rejecting validation runs BEFORE
--   BEGIN TRANSACTION and SELECTs the status row + RETURNs; the CATCH is the
--   only ROLLBACK site.
--
-- Parameters:
--   @Id        BIGINT - Workorder.ScalePartCode.Id. Required.
--   @AppUserId BIGINT - the Config Tool user. Required.
--
-- Result: Status, Message.
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScalePartCode_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.ScalePartCode_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT @Id AS Id, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @TermId BIGINT, @TermCode NVARCHAR(50), @Code NVARCHAR(50), @ItemId BIGINT, @Pn NVARCHAR(50),
            @DeprecatedAt DATETIME2(3), @Activity NVARCHAR(500), @OldValue NVARCHAR(MAX);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = NULL, @LogEventTypeCode = N'ScalePartCodeRemoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @TermId = m.TerminalLocationId, @TermCode = l.Code, @Code = m.ScalePartCode,
               @ItemId = m.ItemId, @Pn = i.PartNumber, @DeprecatedAt = m.DeprecatedAt
        FROM Workorder.ScalePartCode m
        JOIN Location.Location l ON l.Id = m.TerminalLocationId
        JOIN Parts.Item i ON i.Id = m.ItemId
        WHERE m.Id = @Id;

        IF @TermId IS NULL OR @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'That learned code is not active (already removed or not found).';
            IF EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TermId, @LogEventTypeCode = N'ScalePartCodeRemoved',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(@TermCode + N' ' + Audit.ufn_MidDot()
            + N' Scale part code ' + Audit.ufn_MidDot() + N' Removed [' + @Code + N'] -> ' + @Pn);
        SET @OldValue = (SELECT @Code AS ScalePartCode,
                                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description FROM Parts.Item i WHERE i.Id = @ItemId
                                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemId
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ================= Mutation (atomic) =================
        BEGIN TRANSACTION;

        UPDATE Workorder.ScalePartCode
        SET DeprecatedAt = SYSUTCDATETIME(), DeprecatedByAppUserId = @AppUserId
        WHERE Id = @Id AND DeprecatedAt IS NULL;
        IF @@ROWCOUNT = 0
        BEGIN
            -- A pick replaced it between the check above and this update.
            COMMIT TRANSACTION;
            SET @Message = N'That learned code is not active (already removed or not found).';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TermId, @LocationId = @TermId,
            @LogEntityTypeCode = N'Location', @EntityId = @TermId, @LogEventTypeCode = N'ScalePartCodeRemoved',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldValue, @NewValue = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Removed: the next ' + @Code + N' press will ask for its part again.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TermId, @LogEventTypeCode = N'ScalePartCodeRemoved',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
