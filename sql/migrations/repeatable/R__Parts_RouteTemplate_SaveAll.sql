-- =============================================
-- Procedure:   Parts.RouteTemplate_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-05-20
-- Version:     1.0
--
-- Description:
--   Bundled save for a Draft RouteTemplate and its RouteStep children
--   in a single atomic call. Update-only — the Draft RouteTemplate row
--   must already exist (created via _CreateNewVersion or _Create).
--
--   Reconciles RouteStep children against @StepsJson:
--     - existing steps whose Id is NOT in incoming   -> hard DELETE
--     - rows in incoming whose Id matches a child    -> UPDATE
--     - rows in incoming with NULL Id                 -> INSERT
--   SequenceNumber of every active child after the save equals its
--   1-based RowIndex in the submitted array.
--
--   Hard-delete is appropriate for RouteStep because:
--     - RouteStep has no DeprecatedAt column
--     - Production tables reference RouteTemplate.Id, not RouteStep.Id
--     - The parent Route's audit row captures OldValue + NewValue
--       snapshots of the full step list, so historical reconstruction
--       does not require step-level soft-delete.
--
--   The proc explicitly rejects Published / Deprecated rows. Once a
--   route is Published, _CreateNewVersion is the path to revisions.
--
-- Parameters (input):
--   @Id BIGINT             - Required. RouteTemplate.Id of an active Draft.
--   @Name NVARCHAR(200)    - Header Name. Required.
--   @EffectiveFrom DATETIME2(3) - Header EffectiveFrom. Required.
--   @AppUserId BIGINT      - User performing the save. Required for audit.
--   @StepsJson NVARCHAR(MAX) = N'[]'
--                          - JSON array of step deltas. Each element:
--                            {Id|null, OperationTemplateId, IsRequired, Description|null}.
--                            Empty array is valid (zero-step Draft, but
--                            Publish will then reject it).
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId echoes @Id on success.
--
-- Dependencies:
--   Tables: Parts.RouteTemplate, Parts.RouteStep, Parts.OperationTemplate
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-05-20 - 1.0 - Initial version (Phase 5 Routes versioning).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_SaveAll
    @Id            BIGINT,
    @Name          NVARCHAR(200),
    @EffectiveFrom DATETIME2(3),
    @AppUserId     BIGINT,
    @StepsJson     NVARCHAR(MAX) = N'[]'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @Id;

    DECLARE @ExistingPublishedAt  DATETIME2(3);
    DECLARE @ExistingDeprecatedAt DATETIME2(3);
    DECLARE @RowExists            BIT = 0;
    DECLARE @BadRow               INT;
    DECLARE @BadRowStr            NVARCHAR(10);
    DECLARE @CountSteps           INT;
    DECLARE @CountStepsStr        NVARCHAR(10);
    DECLARE @OldValue             NVARCHAR(MAX);
    DECLARE @NewValue             NVARCHAR(MAX);

    DECLARE @ProcName NVARCHAR(200) = N'Parts.RouteTemplate_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id            AS Id,
                @Name          AS Name,
                @EffectiveFrom AS EffectiveFrom,
                JSON_QUERY(ISNULL(@StepsJson, N'[]')) AS Steps
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Incoming TABLE (
        RowIndex            INT PRIMARY KEY,
        Id                  BIGINT        NULL,
        OperationTemplateId BIGINT        NULL,
        IsRequired          BIT           NULL,
        Description         NVARCHAR(500) NULL
    );

    BEGIN TRY
        -- ====================
        -- Tier 1: required-param validation
        -- ====================
        IF @Id IS NULL OR @Name IS NULL OR @EffectiveFrom IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Target row must exist as an active Draft
        -- ====================
        SELECT @ExistingPublishedAt  = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt,
               @RowExists            = 1
        FROM Parts.RouteTemplate WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'RouteTemplate not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'RouteTemplate is deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot edit a Published route. Create a new version first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Parse @StepsJson into @Incoming
        -- ====================
        INSERT INTO @Incoming (RowIndex, Id, OperationTemplateId, IsRequired, Description)
        SELECT
            CAST([key] AS INT) + 1                                              AS RowIndex,
            TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT)                     AS Id,
            TRY_CAST(JSON_VALUE([value], '$.OperationTemplateId') AS BIGINT)    AS OperationTemplateId,
            ISNULL(TRY_CAST(JSON_VALUE([value], '$.IsRequired') AS BIT), 1)     AS IsRequired,
            JSON_VALUE([value], '$.Description')                                AS Description
        FROM OPENJSON(ISNULL(@StepsJson, N'[]'));

        -- Every incoming row must carry a non-NULL OperationTemplateId
        IF EXISTS (SELECT 1 FROM @Incoming WHERE OperationTemplateId IS NULL)
        BEGIN
            SELECT TOP 1 @BadRow = RowIndex
            FROM @Incoming
            WHERE OperationTemplateId IS NULL
            ORDER BY RowIndex;
            SET @BadRowStr = CAST(@BadRow AS NVARCHAR(10));
            SET @Message = N'Step at row ' + @BadRowStr + N' is missing OperationTemplateId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Every OperationTemplateId must resolve to an active row
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE NOT EXISTS (
                SELECT 1 FROM Parts.OperationTemplate ot
                WHERE ot.Id = i.OperationTemplateId
                  AND ot.DeprecatedAt IS NULL
            )
        )
        BEGIN
            SELECT TOP 1 @BadRow = RowIndex
            FROM @Incoming i
            WHERE NOT EXISTS (
                SELECT 1 FROM Parts.OperationTemplate ot
                WHERE ot.Id = i.OperationTemplateId
                  AND ot.DeprecatedAt IS NULL
            )
            ORDER BY RowIndex;
            SET @BadRowStr = CAST(@BadRow AS NVARCHAR(10));
            SET @Message = N'Step at row ' + @BadRowStr + N' references an unknown or deprecated OperationTemplate.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Every incoming row with a non-NULL Id must currently belong to this Route
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE i.Id IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM Parts.RouteStep rs
                  WHERE rs.Id = i.Id
                    AND rs.RouteTemplateId = @Id
              )
        )
        BEGIN
            SET @Message = N'One or more submitted steps reference an Id that does not belong to this RouteTemplate.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Capture OldValue snapshot before mutation
        -- ====================
        SET @OldValue = (
            SELECT
                (SELECT Id, ItemId, VersionNumber, Name, EffectiveFrom,
                        PublishedAt, DeprecatedAt
                 FROM Parts.RouteTemplate WHERE Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)                        AS Header,
                JSON_QUERY(ISNULL((
                    SELECT Id, SequenceNumber, OperationTemplateId,
                           IsRequired, Description
                    FROM Parts.RouteStep
                    WHERE RouteTemplateId = @Id
                    ORDER BY SequenceNumber
                    FOR JSON PATH
                ), N'[]'))                                                    AS Steps
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- ====================
        -- Mutation (atomic): header → delete-missing → update-matched → insert-new
        -- ====================
        BEGIN TRANSACTION;

        UPDATE Parts.RouteTemplate
        SET Name          = @Name,
            EffectiveFrom = @EffectiveFrom
        WHERE Id = @Id;

        -- Hard-delete existing steps whose Id is NOT in incoming
        DELETE rs
        FROM Parts.RouteStep rs
        WHERE rs.RouteTemplateId = @Id
          AND NOT EXISTS (
              SELECT 1 FROM @Incoming i WHERE i.Id IS NOT NULL AND i.Id = rs.Id
          );

        -- Update Id-matched steps with new fields + SequenceNumber from RowIndex
        UPDATE rs
        SET OperationTemplateId = i.OperationTemplateId,
            IsRequired          = i.IsRequired,
            Description         = i.Description,
            SequenceNumber      = i.RowIndex
        FROM Parts.RouteStep rs
        INNER JOIN @Incoming i ON i.Id = rs.Id
        WHERE rs.RouteTemplateId = @Id;

        -- Insert new steps (Id IS NULL in incoming)
        INSERT INTO Parts.RouteStep
            (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
        SELECT
            @Id, i.OperationTemplateId, i.RowIndex, i.IsRequired, i.Description
        FROM @Incoming i
        WHERE i.Id IS NULL;

        -- Capture NewValue snapshot
        SET @NewValue = (
            SELECT
                (SELECT Id, ItemId, VersionNumber, Name, EffectiveFrom,
                        PublishedAt, DeprecatedAt
                 FROM Parts.RouteTemplate WHERE Id = @Id
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)                        AS Header,
                JSON_QUERY(ISNULL((
                    SELECT Id, SequenceNumber, OperationTemplateId,
                           IsRequired, Description
                    FROM Parts.RouteStep
                    WHERE RouteTemplateId = @Id
                    ORDER BY SequenceNumber
                    FOR JSON PATH
                ), N'[]'))                                                    AS Steps
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Route',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'RouteTemplate saved with step reconciliation.',
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SELECT @CountSteps = COUNT(*) FROM @Incoming;
        SET @CountStepsStr = CAST(@CountSteps AS NVARCHAR(10));
        SET @Message = N'Route saved with ' + @CountStepsStr + N' step(s).';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RETURN;
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
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Route',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
