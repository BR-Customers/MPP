-- =============================================
-- Procedure:   Parts.Bom_CreateNewVersion
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.1
--
-- Description:
--   Creates a new BOM version by cloning the parent row and all its
--   BomLines. The new BOM starts as a Draft (PublishedAt = NULL) so
--   engineering can edit before publishing. The parent row is NOT
--   auto-deprecated — it stays whatever it was. A typical workflow:
--     1. _CreateNewVersion → draft clone
--     2. BomLine_Add/Update/MoveUp/MoveDown/Remove → edit the clone
--     3. _Publish on the clone
--     4. (optional) _Deprecate on the prior version if no longer needed
--
-- Parameters (input):
--   @ParentBomId BIGINT              - Source version to clone. Required.
--   @EffectiveFrom DATETIME2(3) NULL - When the new version becomes active.
--                                       NULL → uses SYSUTCDATETIME().
--   @AppUserId BIGINT                - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-05-29 - 2.1 - Audit-readability convention (Slice 3 BOMs):
--                       SUBJECT . CATEGORY . ACTION narrative Description
--                       (<PartNumber> . BOM v<N> (Draft) . Created from v<N-1>;
--                       <K> lines) + resolved-FK OldValue (prior version snapshot)
--                       / NewValue (new draft snapshot) JSON.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Bom_CreateNewVersion
    @ParentBomId   BIGINT,
    @EffectiveFrom DATETIME2(3)  = NULL,
    @AppUserId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Bom_CreateNewVersion';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ParentBomId AS ParentBomId, @EffectiveFrom AS EffectiveFrom
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @ParentBomId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @ParentBomId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @ParentItemId BIGINT = NULL;
        DECLARE @SourceVersion INT  = NULL;
        SELECT @ParentItemId = ParentItemId, @SourceVersion = VersionNumber
        FROM Parts.Bom WHERE Id = @ParentBomId;

        IF @ParentItemId IS NULL
        BEGIN
            SET @Message = N'Parent BOM not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @ParentBomId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Reject if a Draft already exists for this ParentItem (UI usually
        -- guards this; proc-level check produces friendlier message than
        -- the filtered UNIQUE index violation).
        IF EXISTS (
            SELECT 1 FROM Parts.Bom
            WHERE ParentItemId = @ParentItemId
              AND PublishedAt  IS NULL
              AND DeprecatedAt IS NULL
        )
        BEGIN
            SET @Message = N'A draft BOM already exists for this Item. Open it or discard it before creating a new version.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @ParentBomId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @EffFrom DATETIME2(3) = ISNULL(@EffectiveFrom, SYSUTCDATETIME());

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject resolution (convention SUBJECT): parent Item PartNumber [- Description]
        DECLARE @PartNumber NVARCHAR(50);
        DECLARE @ItemDesc   NVARCHAR(500);

        SELECT @PartNumber = PartNumber, @ItemDesc = Description
        FROM Parts.Item
        WHERE Id = @ParentItemId;

        DECLARE @Subject NVARCHAR(600) =
            @PartNumber + CASE WHEN @ItemDesc IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END;

        -- OldValue: prior (source) version snapshot with resolved parent Item + its lines
        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT
                b.Id, b.VersionNumber, b.EffectiveFrom, b.PublishedAt, b.DeprecatedAt,
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                 FROM Parts.Item i WHERE i.Id = b.ParentItemId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ParentItem,
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
                    WHERE bl.BomId = @ParentBomId
                    ORDER BY bl.SortOrder
                    FOR JSON PATH
                )) AS Lines
            FROM Parts.Bom b
            WHERE b.Id = @ParentBomId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        BEGIN TRANSACTION;

        DECLARE @NextVersion INT;
        SELECT @NextVersion = ISNULL(MAX(VersionNumber), 0) + 1
        FROM Parts.Bom
        WHERE ParentItemId = @ParentItemId;

        INSERT INTO Parts.Bom
            (ParentItemId, VersionNumber, EffectiveFrom, CreatedByUserId, CreatedAt)
        VALUES
            (@ParentItemId, @NextVersion, @EffFrom, @AppUserId, SYSUTCDATETIME());

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Clone BomLines from parent → new BOM
        INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
        SELECT @NewId, ChildItemId, QtyPer, UomId, SortOrder
        FROM Parts.BomLine
        WHERE BomId = @ParentBomId;

        DECLARE @LineCount INT = @@ROWCOUNT;

        -- Activity: <PartNumber> . BOM v<N> (Draft) . Created from v<N-1>; <K> lines
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N' ' + Audit.ufn_MidDot() + N' BOM v' + CAST(@NextVersion AS NVARCHAR(10)) +
            N' (Draft) ' + Audit.ufn_MidDot() + N' Created from v' + CAST(@SourceVersion AS NVARCHAR(10)) +
            N'; ' + CAST(@LineCount AS NVARCHAR(10)) + N' lines';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- NewValue: new draft snapshot with resolved parent Item + cloned lines
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                b.Id, b.VersionNumber, b.EffectiveFrom, b.PublishedAt, b.DeprecatedAt,
                JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description
                 FROM Parts.Item i WHERE i.Id = b.ParentItemId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ParentItem,
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
                    WHERE bl.BomId = @NewId
                    ORDER BY bl.SortOrder
                    FOR JSON PATH
                )) AS Lines
            FROM Parts.Bom b
            WHERE b.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Bom',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValueResolved,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'New BOM version created as Draft (' +
                       CAST(@LineCount AS NVARCHAR(10)) + N' line(s) copied).';
    SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrNum   INT            = ERROR_NUMBER();
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        IF @ErrNum IN (2601, 2627)
            SET @Message = N'A draft BOM already exists for this Item. Open it or discard it before creating a new version.';
        ELSE
            SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @ParentBomId, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;

        IF @ErrNum NOT IN (2601, 2627)
            RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
