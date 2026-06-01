-- =============================================
-- Procedure:   Parts.Bom_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     3.1
--
-- Description:
--   Soft-deletes an active Bom by setting DeprecatedAt.
--
--   Production history is preserved via the immutable snapshot captured
--   on each Lot's BOM at release time -- deprecating a Bom does not
--   invalidate any in-flight or historical production. Engineering uses
--   this to retire stale versions once a newer version has been created
--   and validated.
--
--   Idempotent: returns Status=1 + "Already deprecated." when target is
--   already deprecated. Rejects Draft rows (use Bom_DiscardDraft instead).
--
--   Active-WO guard: stubbed for Arc 2 — when Workorder schema lands,
--   reject if any active WorkOrder references this Bom.
--
-- Parameters (input):
--   @Id BIGINT        - Required.
--   @AppUserId BIGINT - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-26 - 3.0 - Idempotent already-deprecated path returns
--                      Status=1; Draft rejection; Arc 2 WO guard stub.
--   2026-05-29 - 3.1 - Audit-readability convention (Slice 3 BOMs):
--                       SUBJECT . CATEGORY . ACTION narrative Description
--                       (<PartNumber> . BOM v<N> . Deprecated) + resolved-FK
--                       OldValue (snapshot being removed, parent Item resolved);
--                       NewValue set to NULL per removal semantics.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Bom_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Bom_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @VersionNumber       INT          = NULL;
    DECLARE @ExistingPublishedAt DATETIME2(3) = NULL;
    DECLARE @ExistingDeprecatedAt DATETIME2(3) = NULL;

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
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
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Idempotent — already deprecated
        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Status  = 1;
            SET @Message = N'Already deprecated.';
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Draft rows can't be deprecated — use DiscardDraft
        IF @ExistingPublishedAt IS NULL
        BEGIN
            SET @Message = N'Cannot deprecate a draft BOM. Use Discard Draft instead.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- TODO Arc 2: reject if any active WorkOrder references this Bom
        -- IF EXISTS (SELECT 1 FROM Workorder.WorkOrder
        --            WHERE BomId = @Id AND Status IN (N'Open', N'InProgress'))
        -- BEGIN
        --     SET @Message = N'Cannot deprecate: BOM is referenced by an active Work Order.';
        --     ... reject ...
        -- END

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

        -- Activity: <PartNumber> . BOM v<N> . Deprecated
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N' ' + Audit.ufn_MidDot() + N' BOM v' + CAST(@VersionNumber AS NVARCHAR(10)) +
            N' ' + Audit.ufn_MidDot() + N' Deprecated';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- OldValue: the snapshot being removed (header + lines), parent Item resolved.
        -- NewValue NULL per removal semantics.
        DECLARE @OldValue NVARCHAR(MAX) = (
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

        UPDATE Parts.Bom
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Bom',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Deprecated v' + CAST(@VersionNumber AS NVARCHAR(10)) + N'.';
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
