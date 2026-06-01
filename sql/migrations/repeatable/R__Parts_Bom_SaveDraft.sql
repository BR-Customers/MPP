-- =============================================
-- Procedure:   Parts.Bom_SaveDraft
-- Author:      Blue Ridge Automation
-- Created:     2026-05-26
-- Version:     1.1
--
-- Description:
--   Bundled save for a Draft Bom: updates EffectiveFrom and reconciles
--   BomLine children in one atomic call. Mirrors the instance-editor
--   variant of the bundled-save pattern established by
--   Location.Location_SaveAll. BomLine has no DeprecatedAt; line
--   reconciliation is physical DELETE / UPDATE / INSERT with SortOrder
--   derived from incoming array index (1-based).
--
--   The target Bom must be Draft (PublishedAt IS NULL AND DeprecatedAt
--   IS NULL). Published / Deprecated rows reject with friendly Message.
--
--   Line validation (in order):
--     1. Every incoming row carries ChildItemId, QtyPer, UomId.
--     2. No row may self-reference (ChildItemId = ParentItemId).
--     3. Every ChildItemId resolves to an active Parts.Item.
--     4. Every UomId resolves to an active Parts.Uom.
--     5. Every incoming row with a non-NULL Id resolves to a BomLine
--        already attached to this Bom (cross-link check).
--   Per spec §6.2 / Q A2: within-batch duplicate ChildItemId on the same
--   Bom is allowed by default (two-of-component-X with different QtyPer
--   is a legal data shape under the data model). This proc does NOT
--   reject duplicates; the UI may guard.
--
-- Parameters (input):
--   @Id            BIGINT          - The Draft Bom's Id. Required.
--   @EffectiveFrom DATETIME2(3)    - Required.
--   @LinesJson     NVARCHAR(MAX)   - JSON array; default '[]'.
--                                    Each element: {Id|null, ChildItemId,
--                                    QtyPer, UomId}.
--   @AppUserId     BIGINT          - Required for audit.
--
-- Result set:
--   Single row: Status (BIT), Message (NVARCHAR), NewId (BIGINT echoed).
--
-- Change Log:
--   2026-05-26 - 1.0 - Initial.
--   2026-05-29 - 1.1 - Audit-readability convention (Slice 3 BOMs):
--                       SUBJECT . CATEGORY . ACTION narrative Description with
--                       +Line/-Line/~Line specifics (child PartNumber + qty,
--                       3-per-op cap + overflow counters) + resolved-FK
--                       OldValue (pre-edit draft lines) / NewValue (post-edit
--                       draft lines) JSON (ChildItem + Uom sub-objects).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Bom_SaveDraft
    @Id            BIGINT,
    @EffectiveFrom DATETIME2(3),
    @LinesJson     NVARCHAR(MAX)  = N'[]',
    @AppUserId     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT            = 0;
    DECLARE @Message NVARCHAR(500)  = N'Unknown error';
    DECLARE @NewId   BIGINT         = @Id;        -- echo

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Bom_SaveDraft';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id            AS Id,
                @EffectiveFrom AS EffectiveFrom,
                JSON_QUERY(ISNULL(@LinesJson, N'[]')) AS Lines
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @ParentItemId        BIGINT       = NULL;
    DECLARE @ExistingPublishedAt DATETIME2(3) = NULL;
    DECLARE @ExistingDeprecatedAt DATETIME2(3) = NULL;
    DECLARE @BadId               BIGINT       = NULL;
    DECLARE @OldValue            NVARCHAR(MAX);
    DECLARE @NewValue            NVARCHAR(MAX);

    -- Incoming line buffer (1-based RowIndex = SortOrder)
    DECLARE @Incoming TABLE (
        RowIndex     INT PRIMARY KEY,
        Id           BIGINT         NULL,
        ChildItemId  BIGINT         NULL,
        QtyPer       DECIMAL(10,4)  NULL,
        UomId        BIGINT         NULL
    );

    BEGIN TRY
        IF @Id IS NULL OR @EffectiveFrom IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @ParentItemId        = ParentItemId,
               @ExistingPublishedAt = PublishedAt,
               @ExistingDeprecatedAt = DeprecatedAt
        FROM Parts.Bom WHERE Id = @Id;

        IF @ParentItemId IS NULL
        BEGIN
            SET @Message = N'BOM not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ExistingDeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot edit a deprecated BOM.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @ExistingPublishedAt IS NOT NULL
        BEGIN
            SET @Message = N'Cannot edit a published BOM. Create a new version to modify.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Parse @LinesJson
        INSERT INTO @Incoming (RowIndex, Id, ChildItemId, QtyPer, UomId)
        SELECT
            CAST([key] AS INT) + 1                                              AS RowIndex,
            TRY_CAST(JSON_VALUE([value], '$.Id')           AS BIGINT)            AS Id,
            TRY_CAST(JSON_VALUE([value], '$.ChildItemId')  AS BIGINT)            AS ChildItemId,
            TRY_CAST(JSON_VALUE([value], '$.QtyPer')       AS DECIMAL(10,4))     AS QtyPer,
            TRY_CAST(JSON_VALUE([value], '$.UomId')        AS BIGINT)            AS UomId
        FROM OPENJSON(ISNULL(@LinesJson, N'[]'));

        -- Required fields per row
        IF EXISTS (SELECT 1 FROM @Incoming WHERE ChildItemId IS NULL OR QtyPer IS NULL OR UomId IS NULL)
        BEGIN
            SET @Message = N'One or more BOM lines are missing ChildItemId, QtyPer, or UomId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Self-reference guard: every ChildItemId must differ from parent Item
        IF EXISTS (SELECT 1 FROM @Incoming WHERE ChildItemId = @ParentItemId)
        BEGIN
            SET @Message = N'A BOM cannot contain its parent Item as a component (self-reference).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- QtyPer must be positive
        IF EXISTS (SELECT 1 FROM @Incoming WHERE QtyPer <= 0)
        BEGIN
            SET @Message = N'QtyPer must be greater than zero.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- All ChildItemId resolve
        SELECT TOP 1 @BadId = i.ChildItemId
        FROM @Incoming i
        WHERE NOT EXISTS (
            SELECT 1 FROM Parts.Item it
            WHERE it.Id = i.ChildItemId AND it.DeprecatedAt IS NULL
        );
        IF @BadId IS NOT NULL
        BEGIN
            SET @Message = N'Invalid or deprecated ChildItemId: ' + CAST(@BadId AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- All UomId resolve
        SET @BadId = NULL;
        SELECT TOP 1 @BadId = i.UomId
        FROM @Incoming i
        WHERE NOT EXISTS (
            SELECT 1 FROM Parts.Uom u
            WHERE u.Id = i.UomId AND u.DeprecatedAt IS NULL
        );
        IF @BadId IS NOT NULL
        BEGIN
            SET @Message = N'Invalid or deprecated UomId: ' + CAST(@BadId AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Cross-link: every incoming non-NULL Id must belong to this Bom
        SET @BadId = NULL;
        SELECT TOP 1 @BadId = i.Id
        FROM @Incoming i
        WHERE i.Id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM Parts.BomLine bl
              WHERE bl.Id = i.Id AND bl.BomId = @Id
          );
        IF @BadId IS NOT NULL
        BEGIN
            SET @Message = N'BomLine ' + CAST(@BadId AS NVARCHAR(20)) + N' does not belong to this BOM.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====

        -- Subject resolution (convention SUBJECT): parent Item PartNumber [- Description]
        DECLARE @PartNumber    NVARCHAR(50);
        DECLARE @ItemDesc      NVARCHAR(500);
        DECLARE @VersionNumber INT;

        SELECT @PartNumber = i.PartNumber, @ItemDesc = i.Description, @VersionNumber = b.VersionNumber
        FROM Parts.Bom b
        INNER JOIN Parts.Item i ON i.Id = b.ParentItemId
        WHERE b.Id = @Id;

        DECLARE @Subject NVARCHAR(600) =
            @PartNumber + CASE WHEN @ItemDesc IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ItemDesc ELSE N'' END;

        -- Change-set classification (drives Activity prose). Compare pre-mutation
        -- BomLine state against @Incoming:
        --   ADD    : incoming Id IS NULL (brand-new line)
        --   REMOVE : existing line whose Id is not in incoming
        --   UPDATE : Id-matched line whose ChildItemId / QtyPer / UomId differs
        DECLARE @Changes TABLE (
            ChangeKind   NCHAR(1) NOT NULL,  -- '+' / '-' / '~'
            SortKey      INT NOT NULL,
            ChildPart    NVARCHAR(50) NULL,
            OldQty       DECIMAL(10,4) NULL,
            NewQty       DECIMAL(10,4) NULL
        );

        -- ADDS: incoming rows with NULL Id (resolve ChildItemId -> PartNumber)
        INSERT INTO @Changes (ChangeKind, SortKey, ChildPart, NewQty)
        SELECT N'+',
               ROW_NUMBER() OVER (ORDER BY i.RowIndex),
               ci.PartNumber, i.QtyPer
        FROM @Incoming i
        INNER JOIN Parts.Item ci ON ci.Id = i.ChildItemId
        WHERE i.Id IS NULL;

        -- REMOVES: existing lines whose Id is not present in incoming
        INSERT INTO @Changes (ChangeKind, SortKey, ChildPart, OldQty)
        SELECT N'-',
               ROW_NUMBER() OVER (ORDER BY bl.SortOrder),
               ci.PartNumber, bl.QtyPer
        FROM Parts.BomLine bl
        INNER JOIN Parts.Item ci ON ci.Id = bl.ChildItemId
        WHERE bl.BomId = @Id
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = bl.Id);

        -- UPDATES: Id-matched lines where ChildItemId / QtyPer / UomId differs.
        -- Child PartNumber rendered is the NEW ChildItemId (post-edit identity).
        INSERT INTO @Changes (ChangeKind, SortKey, ChildPart, OldQty, NewQty)
        SELECT N'~',
               ROW_NUMBER() OVER (ORDER BY bl.SortOrder),
               ci.PartNumber, bl.QtyPer, i.QtyPer
        FROM Parts.BomLine bl
        INNER JOIN @Incoming i   ON i.Id = bl.Id
        INNER JOIN Parts.Item ci ON ci.Id = i.ChildItemId
        WHERE bl.BomId = @Id
          AND (bl.ChildItemId <> i.ChildItemId
               OR bl.QtyPer <> i.QtyPer
               OR bl.UomId <> i.UomId);

        -- ----- Compose the Activity prose (cap 3 per op + overflow counters) -----
        DECLARE @AddSpecifics    NVARCHAR(MAX) = N'';
        DECLARE @AddOverflow     INT = 0;
        DECLARE @RemoveSpecifics NVARCHAR(MAX) = N'';
        DECLARE @RemoveOverflow  INT = 0;
        DECLARE @UpdateSpecifics NVARCHAR(MAX) = N'';
        DECLARE @UpdateOverflow  INT = 0;

        -- Adds: "+Line <PartNumber> qty <NewQty>"
        ;WITH ranked AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
            FROM @Changes WHERE ChangeKind = N'+'
        )
        SELECT @AddSpecifics = STRING_AGG(
            N'+Line ' + ChildPart + N' qty ' + CAST(CAST(NewQty AS DECIMAL(10,4)) AS NVARCHAR(20)),
            N', '
        ) WITHIN GROUP (ORDER BY rn)
        FROM ranked WHERE rn <= 3;
        SELECT @AddOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'+';
        IF @AddOverflow < 0 SET @AddOverflow = 0;

        -- Removes: "-Line <PartNumber>"
        ;WITH ranked AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
            FROM @Changes WHERE ChangeKind = N'-'
        )
        SELECT @RemoveSpecifics = STRING_AGG(N'-Line ' + ChildPart, N', ')
                                  WITHIN GROUP (ORDER BY rn)
        FROM ranked WHERE rn <= 3;
        SELECT @RemoveOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'-';
        IF @RemoveOverflow < 0 SET @RemoveOverflow = 0;

        -- Updates: "~Line <PartNumber> qty <OldQty>→<NewQty>"
        ;WITH ranked AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
            FROM @Changes WHERE ChangeKind = N'~'
        )
        SELECT @UpdateSpecifics = STRING_AGG(
            N'~Line ' + ChildPart + N' qty ' +
            CAST(CAST(OldQty AS DECIMAL(10,4)) AS NVARCHAR(20)) + NCHAR(8594) +
            CAST(CAST(NewQty AS DECIMAL(10,4)) AS NVARCHAR(20)),
            N', '
        ) WITHIN GROUP (ORDER BY rn)
        FROM ranked WHERE rn <= 3;
        SELECT @UpdateOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'~';
        IF @UpdateOverflow < 0 SET @UpdateOverflow = 0;

        -- Assemble: adds; removes; updates  (each group separated by "; ")
        DECLARE @ActionParts NVARCHAR(MAX) = N'';

        IF NULLIF(@AddSpecifics, N'') IS NOT NULL
            SET @ActionParts = @ActionParts + @AddSpecifics +
                               CASE WHEN @AddOverflow > 0 THEN N', +' + CAST(@AddOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                               N'; ';

        IF NULLIF(@RemoveSpecifics, N'') IS NOT NULL
            SET @ActionParts = @ActionParts + @RemoveSpecifics +
                               CASE WHEN @RemoveOverflow > 0 THEN N', -' + CAST(@RemoveOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                               N'; ';

        IF NULLIF(@UpdateSpecifics, N'') IS NOT NULL
            SET @ActionParts = @ActionParts + @UpdateSpecifics +
                               CASE WHEN @UpdateOverflow > 0 THEN N', ~' + CAST(@UpdateOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                               N'; ';

        -- Strip trailing "; " (DATALENGTH: LEN() ignores trailing spaces and
        -- would eat one real char off the last specific)
        IF DATALENGTH(@ActionParts) >= 4
            SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts) / 2 - 2);

        IF @ActionParts = N''
            SET @ActionParts = N'No line changes';

        -- Total active draft line count = the post-mutation count (incoming rows)
        DECLARE @TotalLines INT = (SELECT COUNT(*) FROM @Incoming);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @Subject + N' ' + Audit.ufn_MidDot() + N' BOM v' + CAST(@VersionNumber AS NVARCHAR(10)) +
            N' (Draft) ' + Audit.ufn_MidDot() + N' ' + @ActionParts +
            N'; ' + CAST(@TotalLines AS NVARCHAR(10)) + N' lines';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- OldValue: pre-edit draft lines with resolved ChildItem + Uom
        SET @OldValue = (
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

        -- ----- Mutation (atomic) -----
        BEGIN TRANSACTION;

        UPDATE Parts.Bom
        SET EffectiveFrom = @EffectiveFrom
        WHERE Id = @Id;

        -- DELETE rows missing from incoming
        DELETE bl
        FROM Parts.BomLine bl
        WHERE bl.BomId = @Id
          AND NOT EXISTS (
              SELECT 1 FROM @Incoming i
              WHERE i.Id = bl.Id
          );

        -- UPDATE rows with matching Id
        UPDATE bl
        SET ChildItemId = i.ChildItemId,
            QtyPer      = i.QtyPer,
            UomId       = i.UomId,
            SortOrder   = i.RowIndex
        FROM Parts.BomLine bl
        INNER JOIN @Incoming i ON i.Id = bl.Id
        WHERE bl.BomId = @Id;

        -- INSERT rows with NULL Id
        INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder)
        SELECT @Id, i.ChildItemId, i.QtyPer, i.UomId, i.RowIndex
        FROM @Incoming i
        WHERE i.Id IS NULL;

        -- Capture post-mutation state: post-edit draft lines with resolved ChildItem + Uom
        SET @NewValue = (
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

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Bom',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        DECLARE @LineCount INT = (SELECT COUNT(*) FROM Parts.BomLine WHERE BomId = @Id);
        SET @Status  = 1;
        SET @Message = N'Saved draft with ' + CAST(@LineCount AS NVARCHAR(10)) + N' line(s).';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Bom',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
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
