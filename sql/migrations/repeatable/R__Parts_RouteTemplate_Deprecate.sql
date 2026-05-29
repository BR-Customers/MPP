-- =============================================
-- Procedure:   Parts.RouteTemplate_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Soft-deletes an active RouteTemplate by setting DeprecatedAt.
--
--   No dependency check is performed. Production history is preserved via
--   the immutable snapshot captured on each Lot's route at release time —
--   deprecating a RouteTemplate does not invalidate any in-flight or
--   historical production. Engineering uses this to retire stale versions
--   once a newer version has been created and validated.
--
-- Parameters (input):
--   @Id BIGINT        - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 4 Routes):
--                       SUBJECT . CATEGORY . ACTION Description +
--                       resolved-FK OldValue (removed snapshot),
--                       NewValue NULL.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.RouteTemplate_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'RouteTemplate not found or already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject + version resolution (convention SUBJECT = parent Item PartNumber)
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @VersionStr NVARCHAR(10);
        SELECT @PartNumber = i.PartNumber,
               @VersionStr = CAST(rt.VersionNumber AS NVARCHAR(10))
        FROM Parts.RouteTemplate rt
        INNER JOIN Parts.Item i ON i.Id = rt.ItemId
        WHERE rt.Id = @Id;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @PartNumber + N' ' + Audit.ufn_MidDot() +
            N' Route v' + @VersionStr + N' ' + Audit.ufn_MidDot() + N' Deprecated');

        -- OldValue: removed snapshot (header + resolved-FK steps). NewValue NULL.
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                JSON_QUERY((SELECT rt.Id, rt.ItemId, rt.VersionNumber, rt.Name, rt.EffectiveFrom,
                        rt.PublishedAt, rt.DeprecatedAt,
                        JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                                    FROM Parts.Item i WHERE i.Id = rt.ItemId
                                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))  AS Item
                 FROM Parts.RouteTemplate rt WHERE rt.Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))                      AS Header,
                JSON_QUERY(ISNULL((
                    SELECT rs.Id, rs.SequenceNumber, rs.IsRequired, rs.Description,
                           JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                                       FROM Parts.OperationTemplate ot
                                       WHERE ot.Id = rs.OperationTemplateId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTemplate
                    FROM Parts.RouteStep rs
                    WHERE rs.RouteTemplateId = @Id
                    ORDER BY rs.SequenceNumber
                    FOR JSON PATH
                ), N'[]'))                                                   AS Steps
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        BEGIN TRANSACTION;

        UPDATE Parts.RouteTemplate
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Route',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'RouteTemplate deprecated successfully.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
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
