-- =============================================
-- Procedure:   Parts.RouteTemplate_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Creates the first version (VersionNumber = 1) of a RouteTemplate for
--   a given Item. The route starts empty — steps are added via
--   Parts.RouteStep_Add. For subsequent versions, use _CreateNewVersion
--   which clones the prior version's steps.
--
-- Parameters (input):
--   @ItemId BIGINT          - Required. Must be active.
--   @Name NVARCHAR(200)     - Required. Display label for this route version.
--   @EffectiveFrom DATETIME2(3) NULL - When this version becomes active.
--                                       NULL → uses SYSUTCDATETIME().
--   @AppUserId BIGINT       - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 4 Routes):
--                       SUBJECT . CATEGORY . ACTION Description +
--                       resolved-FK OldValue/NewValue JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_Create
    @ItemId        BIGINT,
    @Name          NVARCHAR(200),
    @EffectiveFrom DATETIME2(3)  = NULL,
    @AppUserId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.RouteTemplate_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ItemId AS ItemId, @Name AS Name, @EffectiveFrom AS EffectiveFrom
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ItemId IS NULL OR @Name IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @ItemId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated ItemId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Reject if a RouteTemplate for this Item already exists (use _CreateNewVersion instead)
        IF EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @ItemId)
        BEGIN
            SET @Message = N'A RouteTemplate already exists for this Item. Use _CreateNewVersion to add a new version.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @EffFrom DATETIME2(3) = ISNULL(@EffectiveFrom, SYSUTCDATETIME());

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject resolution (convention SUBJECT = parent Item PartNumber)
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);
        SELECT @PartNumber = PartNumber, @ItemDesc = Description
        FROM Parts.Item WHERE Id = @ItemId;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @PartNumber + N' ' + Audit.ufn_MidDot() +
            N' Route v1 (Draft) ' + Audit.ufn_MidDot() + N' Created');

        BEGIN TRANSACTION;

        INSERT INTO Parts.RouteTemplate
            (ItemId, VersionNumber, Name, EffectiveFrom, CreatedByUserId, CreatedAt)
        VALUES
            (@ItemId, 1, @Name, @EffFrom, @AppUserId, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- NewValue: draft snapshot with resolved parent-Item sub-object
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                rt.Id, rt.VersionNumber, rt.Name, rt.EffectiveFrom,
                rt.PublishedAt, rt.DeprecatedAt,
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                            FROM Parts.Item i WHERE i.Id = rt.ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))  AS Item
            FROM Parts.RouteTemplate rt
            WHERE rt.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Route',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'RouteTemplate created successfully.';
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
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
