-- =============================================
-- Procedure:   Parts.RouteTemplate_Publish
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.2
--
-- Description:
--   Flips a Draft RouteTemplate to Published by setting PublishedAt =
--   SYSUTCDATETIME(). Optionally overrides EffectiveFrom and Name in
--   the same transaction (Item Master Routes tab Publish surface lets
--   engineering tweak the publish-as-of date or rename at the last step).
--   One-way transition — once a route is published, it becomes immutable
--   (RouteStep mutations reject). To change a published route, use
--   _CreateNewVersion which creates a Draft clone.
--
--   Atomic auto-deprecation: when this version is published, any prior
--   version for the same ItemId that is currently Published-and-not-
--   Deprecated is stamped DeprecatedAt = SYSUTCDATETIME() in the same
--   transaction. Enforces the versioned-entity invariant: at most one
--   Published-and-not-Deprecated RouteTemplate exists per ItemId (same
--   model as Parts.Bom_Publish).
--
--   Rejects if the route is already published, deprecated, or has zero
--   RouteStep rows (a published route with no steps is nonsensical).
--
-- Parameters (input):
--   @Id BIGINT                       - RouteTemplate.Id. Required.
--   @AppUserId BIGINT                - Required for audit.
--   @EffectiveFrom DATETIME2(3) NULL - Optional override applied before
--                                       PublishedAt is set. NULL preserves
--                                       the row's existing EffectiveFrom.
--   @Name NVARCHAR(200) NULL         - Optional Name override. NULL
--                                       preserves the row's existing Name.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-20 - 3.0 - Added optional @EffectiveFrom + @Name overrides
--                      and a zero-steps guard.
--   2026-05-29 - 3.1 - Audit-readability convention (Slice 4 Routes):
--                       SUBJECT . CATEGORY . ACTION Description +
--                       resolved-FK OldValue (pre-publish) / NewValue
--                       (published) snapshots.
--   2026-06-30 - 3.2 - Atomically auto-deprecate the prior Published version
--                       (same ItemId, DeprecatedAt IS NULL) on publish, matching
--                       Parts.Bom_Publish v4.0. Replaces the prior informational
--                       "supersedes" clause with real single-Published enforcement;
--                       success message names the deprecated version(s).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.RouteTemplate_Publish
    @Id            BIGINT,
    @AppUserId     BIGINT,
    @EffectiveFrom DATETIME2(3)  = NULL,
    @Name          NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.RouteTemplate_Publish';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id            AS Id,
                @EffectiveFrom AS EffectiveFrom,
                @Name          AS Name
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @ExistingPublishedAt DATETIME2(3);
        DECLARE @ExistingDeprecatedAt DATETIME2(3);
        DECLARE @RowExists BIT = 0;

        SELECT @ExistingPublishedAt = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt,
               @RowExists = 1
        FROM Parts.RouteTemplate WHERE Id = @Id;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'RouteTemplate not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot publish a deprecated RouteTemplate.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'RouteTemplate is already published.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Zero-steps guard: a published route with no steps is nonsensical.
        IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @Id)
        BEGIN
            SET @Message = N'Cannot publish: route has no steps.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Route',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject + version resolution (convention SUBJECT = parent Item PartNumber)
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemId     BIGINT;
        DECLARE @VersionStr NVARCHAR(10);
        SELECT @ItemId = rt.ItemId,
               @PartNumber = i.PartNumber,
               @VersionStr = CAST(rt.VersionNumber AS NVARCHAR(10))
        FROM Parts.RouteTemplate rt
        INNER JOIN Parts.Item i ON i.Id = rt.ItemId
        WHERE rt.Id = @Id;

        -- Prior Published-and-not-Deprecated version(s) for this Item are
        -- auto-deprecated when this version publishes (single-Published invariant,
        -- mirrors Parts.Bom_Publish v4.0). Captured during the in-transaction
        -- UPDATE below so the narrative + success message can name them.
        DECLARE @DeprecatedVersions TABLE (VersionNumber INT);

        -- OldValue: pre-publish header + resolved-FK steps
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

        -- Single-Published invariant: deprecate any prior Published-and-not-
        -- Deprecated version for this Item as this version flips to Published.
        -- Set-based, so it also defensively cleans up stale multi-Published rows.
        UPDATE Parts.RouteTemplate
        SET DeprecatedAt = SYSUTCDATETIME()
        OUTPUT inserted.VersionNumber INTO @DeprecatedVersions
        WHERE ItemId = @ItemId
          AND Id <> @Id
          AND PublishedAt IS NOT NULL
          AND DeprecatedAt IS NULL;

        -- Apply optional overrides in the same UPDATE that flips PublishedAt.
        -- ISNULL preserves the existing column value when the override is NULL.
        UPDATE Parts.RouteTemplate
        SET PublishedAt   = SYSUTCDATETIME(),
            EffectiveFrom = ISNULL(@EffectiveFrom, EffectiveFrom),
            Name          = ISNULL(@Name, Name)
        WHERE Id = @Id;

        -- "(deprecated v<N>[, v<M>])" clause for the audit narrative.
        DECLARE @DepClause NVARCHAR(200) = N'';
        IF EXISTS (SELECT 1 FROM @DeprecatedVersions)
        BEGIN
            SELECT @DepClause = N' (deprecated ' +
                STRING_AGG(N'v' + CAST(VersionNumber AS NVARCHAR(10)), N', ')
                    WITHIN GROUP (ORDER BY VersionNumber) + N')'
            FROM @DeprecatedVersions;
        END

        DECLARE @StepCount INT =
            (SELECT COUNT(*) FROM Parts.RouteStep WHERE RouteTemplateId = @Id);

        -- Effective date now applied to the row (override already resolved above).
        DECLARE @EffApplied DATETIME2(3);
        SELECT @EffApplied = EffectiveFrom FROM Parts.RouteTemplate WHERE Id = @Id;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @PartNumber + N' ' + Audit.ufn_MidDot() +
            N' Route v' + @VersionStr + N' ' + Audit.ufn_MidDot() +
            N' Published' + @DepClause +
            N'; ' + CAST(@StepCount AS NVARCHAR(10)) + N' steps' +
            CASE WHEN @EffApplied IS NOT NULL
                 THEN N'; effective ' + CONVERT(NVARCHAR(10), @EffApplied, 23) ELSE N'' END);

        -- NewValue: published header + resolved-FK steps
        DECLARE @NewValue NVARCHAR(MAX) = (
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

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Route',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        DECLARE @DepSuffix NVARCHAR(200) = N'';
        IF EXISTS (SELECT 1 FROM @DeprecatedVersions)
        BEGIN
            SELECT @DepSuffix = N' Deprecated ' +
                STRING_AGG(N'v' + CAST(VersionNumber AS NVARCHAR(10)), N', ') + N'.'
            FROM @DeprecatedVersions;
        END
        SET @Message = N'Published v' + @VersionStr + N'.' + @DepSuffix;
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
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
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
