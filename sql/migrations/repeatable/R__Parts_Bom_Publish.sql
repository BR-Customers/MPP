-- =============================================
-- Procedure:   Parts.Bom_Publish
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     4.0
--
-- Description:
--   Flips a Draft BOM to Published by setting PublishedAt =
--   SYSUTCDATETIME(). One-way transition. Optionally accepts
--   @EffectiveFrom override and @LinesJson — when @LinesJson is non-NULL,
--   the proc internally invokes Bom_SaveDraft logic first (save-and-publish
--   in one round-trip).
--
--   Atomic auto-deprecation: when this version is published, any prior
--   version for the same ParentItemId that is currently Published-and-
--   not-Deprecated is stamped with DeprecatedAt = SYSUTCDATETIME() in
--   the same transaction. Enforces the versioned-entity invariant: at
--   most one Published-and-not-Deprecated BOM exists per ParentItemId.
--
--   Rejects in any of:
--     - Target Bom is missing
--     - Target Bom is Deprecated
--     - Target Bom is already Published
--     - Final line count == 0 (must have at least one BomLine to publish)
--     - EffectiveFrom is NULL (cannot publish without an effective date)
--
--   Idempotent re-publish: returns Status=0, "BOM is already published."
--
-- Parameters (input):
--   @Id            BIGINT          - Required.
--   @EffectiveFrom DATETIME2(3)    - Optional override; default NULL = keep existing.
--   @LinesJson     NVARCHAR(MAX)   - Optional bundled save payload; default NULL = no save.
--   @AppUserId     BIGINT          - Required for audit.
--
-- Result set:
--   Status (BIT), Message (NVARCHAR), NewId (BIGINT echoed).
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-26 - 3.0 - Added @EffectiveFrom + @LinesJson save-and-publish
--                      params. Added min-1-line and EffectiveFrom guards.
--                      Echo NewId in result set for entity-script convention.
--   2026-05-27 - 4.0 - Atomically auto-deprecate the prior Published version
--                      (same ParentItemId, DeprecatedAt IS NULL) when this
--                      version flips to Published. Enforces single-Published
--                      invariant per the versioned-entity workflow convention.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Bom_Publish
    @Id            BIGINT,
    @EffectiveFrom DATETIME2(3)    = NULL,
    @LinesJson     NVARCHAR(MAX)   = NULL,
    @AppUserId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @Id;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Bom_Publish';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id            AS Id,
                @EffectiveFrom AS EffectiveFrom,
                CASE WHEN @LinesJson IS NULL THEN NULL ELSE JSON_QUERY(@LinesJson) END AS Lines
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @ParentItemId        BIGINT       = NULL;
    DECLARE @ExistingPublishedAt DATETIME2(3) = NULL;
    DECLARE @ExistingDeprecatedAt DATETIME2(3) = NULL;
    DECLARE @ExistingEffectiveFrom DATETIME2(3) = NULL;
    DECLARE @VersionNumber       INT          = NULL;

    -- Incoming line buffer (only used if @LinesJson non-NULL)
    DECLARE @Incoming TABLE (
        RowIndex     INT PRIMARY KEY,
        Id           BIGINT         NULL,
        ChildItemId  BIGINT         NULL,
        QtyPer       DECIMAL(10,4)  NULL,
        UomId        BIGINT         NULL
    );

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @ParentItemId          = ParentItemId,
               @ExistingPublishedAt   = PublishedAt,
               @ExistingDeprecatedAt  = DeprecatedAt,
               @ExistingEffectiveFrom = EffectiveFrom,
               @VersionNumber         = VersionNumber
        FROM Parts.Bom WHERE Id = @Id;

        IF @ParentItemId IS NULL
        BEGIN
            SET @Message = N'BOM not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot publish a deprecated BOM.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'BOM is already published.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        DECLARE @TargetEffFrom DATETIME2(3) = COALESCE(@EffectiveFrom, @ExistingEffectiveFrom);
        IF @TargetEffFrom IS NULL
        BEGIN
            SET @Message = N'EffectiveFrom is required to publish.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Optional save-then-publish: if @LinesJson non-NULL, validate + reconcile lines first.
        IF @LinesJson IS NOT NULL
        BEGIN
            INSERT INTO @Incoming (RowIndex, Id, ChildItemId, QtyPer, UomId)
            SELECT
                CAST([key] AS INT) + 1,
                TRY_CAST(JSON_VALUE([value], '$.Id')          AS BIGINT),
                TRY_CAST(JSON_VALUE([value], '$.ChildItemId') AS BIGINT),
                TRY_CAST(JSON_VALUE([value], '$.QtyPer')      AS DECIMAL(10,4)),
                TRY_CAST(JSON_VALUE([value], '$.UomId')       AS BIGINT)
            FROM OPENJSON(@LinesJson);

            IF EXISTS (SELECT 1 FROM @Incoming WHERE ChildItemId IS NULL OR QtyPer IS NULL OR UomId IS NULL)
            BEGIN
                SET @Message = N'One or more BOM lines are missing ChildItemId, QtyPer, or UomId.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM @Incoming WHERE ChildItemId = @ParentItemId)
            BEGIN
                SET @Message = N'A BOM cannot contain its parent Item as a component (self-reference).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM @Incoming WHERE QtyPer <= 0)
            BEGIN
                SET @Message = N'QtyPer must be greater than zero.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM @Incoming i
                WHERE NOT EXISTS (
                    SELECT 1 FROM Parts.Item it
                    WHERE it.Id = i.ChildItemId AND it.DeprecatedAt IS NULL
                )
            )
            BEGIN
                SET @Message = N'One or more ChildItemId values are invalid or deprecated.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM @Incoming i
                WHERE NOT EXISTS (
                    SELECT 1 FROM Parts.Uom u
                    WHERE u.Id = i.UomId AND u.DeprecatedAt IS NULL
                )
            )
            BEGIN
                SET @Message = N'One or more UomId values are invalid or deprecated.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM @Incoming i
                WHERE i.Id IS NOT NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM Parts.BomLine bl
                      WHERE bl.Id = i.Id AND bl.BomId = @Id
                  )
            )
            BEGIN
                SET @Message = N'One or more BOM line Ids do not belong to this BOM.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message;
                RETURN;
            END
        END

        -- Pre-mutation min-1-line guard.
        -- When @LinesJson is supplied, count the resulting post-incoming
        -- shape: incoming rows minus removed ones (existing rows whose Id
        -- is not in incoming get DELETEd).
        DECLARE @ProjectedLineCount INT;
        IF @LinesJson IS NOT NULL
        BEGIN
            SET @ProjectedLineCount = (SELECT COUNT(*) FROM @Incoming);
        END
        ELSE
        BEGIN
            SET @ProjectedLineCount = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @Id);
        END

        IF @ProjectedLineCount = 0
        BEGIN
            SET @Message = N'Cannot publish a BOM with no lines.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ----- Mutation (atomic) -----
        BEGIN TRANSACTION;

        IF @LinesJson IS NOT NULL
        BEGIN
            -- Reconcile lines as part of the publish atomic
            DELETE bl
            FROM Parts.BomLine bl
            WHERE bl.BomId = @Id
              AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = bl.Id);

            UPDATE bl
            SET ChildItemId = i.ChildItemId,
                QtyPer      = i.QtyPer,
                UomId       = i.UomId,
                SortOrder   = i.RowIndex
            FROM Parts.BomLine bl
            INNER JOIN @Incoming i ON i.Id = bl.Id
            WHERE bl.BomId = @Id;

            INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
            SELECT @Id, i.ChildItemId, i.QtyPer, i.UomId, i.RowIndex
            FROM @Incoming i
            WHERE i.Id IS NULL;
        END

        -- Auto-deprecate the prior Published version for this ParentItemId.
        -- The versioned-entity workflow guarantees at most one such row at
        -- any time, but the UPDATE is set-based so a defensive cleanup of
        -- multiple stale Published rows also works correctly. Capture each
        -- auto-deprecated VersionNumber so the success message can name them.
        DECLARE @DeprecatedVersions TABLE (VersionNumber INT);

        UPDATE Parts.Bom
        SET DeprecatedAt = SYSUTCDATETIME()
        OUTPUT inserted.VersionNumber INTO @DeprecatedVersions
        WHERE ParentItemId = @ParentItemId
          AND Id <> @Id
          AND PublishedAt IS NOT NULL
          AND DeprecatedAt IS NULL;

        UPDATE Parts.Bom
        SET PublishedAt   = SYSUTCDATETIME(),
            EffectiveFrom = @TargetEffFrom
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Bom',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = N'BOM published.',
            @OldValue          = NULL,
            @NewValue          = @Params;

        COMMIT TRANSACTION;

        DECLARE @DepSuffix NVARCHAR(200) = N'';
        IF EXISTS (SELECT 1 FROM @DeprecatedVersions)
        BEGIN
            SELECT @DepSuffix = N' Deprecated ' +
                STRING_AGG(N'v' + CAST(VersionNumber AS NVARCHAR(10)), N', ') + N'.'
            FROM @DeprecatedVersions;
        END

        SET @Status  = 1;
        SET @Message = N'Published v' + CAST(@VersionNumber AS NVARCHAR(10)) + N'.' + @DepSuffix;
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
