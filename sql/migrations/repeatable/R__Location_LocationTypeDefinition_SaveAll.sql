-- =============================================
-- Procedure:   Location.LocationTypeDefinition_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-05-13
-- Version:     1.1
--
-- Description:
--   Bundled save for a LocationTypeDefinition and its child
--   LocationAttributeDefinition rows in a single atomic call.
--
--   Create mode (@Id IS NULL):
--     Inserts a new LocationTypeDefinition under @LocationTypeId,
--     then inserts every row in @AttributesJson as a child
--     LocationAttributeDefinition with SortOrder derived from the
--     array index (1-based).
--
--   Update mode (@Id IS NOT NULL):
--     Verifies Code and LocationTypeId match the existing row
--     (both are immutable post-create), updates Name / Icon /
--     Description on the parent, and reconciles children against
--     @AttributesJson:
--       - active children whose Id is NOT in incoming -> DEPRECATE
--       - rows in incoming whose Id matches an active child -> UPDATE
--       - rows in incoming with NULL Id -> INSERT
--     SortOrder of all active children after the save matches the
--     submitted JSON array order.
--
--   The whole operation runs under a single transaction; any
--   validation or DB failure rolls everything back. The filtered
--   UNIQUE index on (LocationTypeDefinitionId, AttributeName)
--   WHERE DeprecatedAt IS NULL is the safety net for racing saves.
--
-- Parameters (input):
--   @Id BIGINT = NULL                 - NULL = create new; non-NULL = update existing.
--   @LocationTypeId BIGINT            - FK to LocationType. Required on create;
--                                       must match existing row on update (immutable).
--   @Code NVARCHAR(50)                - Definition code. Required on create
--                                       (globally unique among active rows);
--                                       must match existing row on update (immutable).
--   @Name NVARCHAR(200)               - Display name. Required.
--   @Icon NVARCHAR(200) = NULL        - Perspective icon path (e.g. 'mpp/die_cast').
--   @Description NVARCHAR(500) = NULL - Optional description.
--   @AppUserId BIGINT                 - User performing the action. Required for audit.
--   @AttributesJson NVARCHAR(MAX) = N'[]'
--                                     - JSON array of attribute deltas. Each element:
--                                       {Id|null, AttributeName, DataType, IsRequired,
--                                        DefaultValue|null, Uom|null, Description|null}.
--                                       Empty array means "no children" (valid in
--                                       both create and update modes).
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure.
--   NewId is the LocationTypeDefinition.Id (newly assigned on create,
--   echoed back on update).
--
-- Dependencies:
--   Tables: Location.LocationTypeDefinition, Location.LocationAttributeDefinition,
--           Location.LocationType
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--   Indexes: UX_LocationAttributeDefinition_ActiveName (migration 0014)
--
-- Error Handling:
--   - Validation / business-rule failures: @Status=0, @Message set,
--     Audit_LogFailure, RETURN. No transaction in flight.
--   - CATCH handler: rollback, @Status=0, @Message captured from
--     ERROR_MESSAGE(), Audit_LogFailure (nested try/catch), RAISERROR.
--
-- Change Log:
--   2026-05-13 - 1.0 - Initial version
--   2026-05-29 - 1.1 - Audit-readability convention (Slice 7 LocationTypeEditor):
--                       SUBJECT . ACTION Description with +Attribute / -Attribute /
--                       ~Attribute classification (3-per-op cap + overflow), resolved
--                       header LocationTypeId -> {Id, Name} FK sub-object, BIT diffs
--                       rendered as words. Narrative + JSON built from PRE-mutation state.
-- =============================================
CREATE OR ALTER PROCEDURE Location.LocationTypeDefinition_SaveAll
    @Id              BIGINT          = NULL,
    @LocationTypeId  BIGINT,
    @Code            NVARCHAR(50),
    @Name            NVARCHAR(200),
    @Icon            NVARCHAR(200)   = NULL,
    @Description     NVARCHAR(500)   = NULL,
    @AppUserId       BIGINT,
    @AttributesJson  NVARCHAR(MAX)   = N'[]'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ====================
    -- Result + working variables
    -- ====================
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @Id;     -- echo on update; overwritten on create

    DECLARE @IsCreate  BIT           = CASE WHEN @Id IS NULL THEN 1 ELSE 0 END;
    DECLARE @EventCode NVARCHAR(50)  = CASE WHEN @IsCreate = 1 THEN N'Created' ELSE N'Updated' END;

    DECLARE @ExistingLocationTypeId BIGINT;
    DECLARE @ExistingCode           NVARCHAR(50);
    DECLARE @BadRow                 INT;
    DECLARE @BadRowStr              NVARCHAR(10);
    DECLARE @DupName                NVARCHAR(100);
    DECLARE @CountAttrs             INT;
    DECLARE @CountAttrsStr          NVARCHAR(10);
    DECLARE @OldValue               NVARCHAR(MAX);
    DECLARE @NewValue               NVARCHAR(MAX);

    -- Audit narrative (convention SUBJECT . ACTION) ----------------------
    DECLARE @TierName NVARCHAR(100);
    DECLARE @Subject  NVARCHAR(400);
    DECLARE @Activity NVARCHAR(500);

    DECLARE @ProcName NVARCHAR(200) = N'Location.LocationTypeDefinition_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id              AS Id,
                @LocationTypeId  AS LocationTypeId,
                @Code            AS Code,
                @Name            AS Name,
                @Icon            AS Icon,
                @Description     AS Description,
                JSON_QUERY(ISNULL(@AttributesJson, N'[]')) AS Attributes
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Incoming attribute deltas, parsed once up front and reused throughout.
    DECLARE @Incoming TABLE (
        RowIndex      INT PRIMARY KEY,
        Id            BIGINT        NULL,
        AttributeName NVARCHAR(100) NULL,
        DataType      NVARCHAR(50)  NULL,
        IsRequired    BIT           NULL,
        DefaultValue  NVARCHAR(255) NULL,
        Uom           NVARCHAR(20)  NULL,
        Description   NVARCHAR(500) NULL
    );

    BEGIN TRY
        -- ====================
        -- Tier 1: Parameter validation
        -- ====================
        IF @LocationTypeId IS NULL OR @Code IS NULL OR @Name IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.LocationType WHERE Id = @LocationTypeId)
        BEGIN
            SET @Message = N'Invalid LocationTypeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Parse @AttributesJson into @Incoming (single statement; OPENJSON
        -- throws on invalid JSON syntax, caught by the outer CATCH below).
        -- ====================
        INSERT INTO @Incoming (RowIndex, Id, AttributeName, DataType, IsRequired,
                               DefaultValue, Uom, Description)
        SELECT
            CAST([key] AS INT) + 1                                                AS RowIndex,
            TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT)                       AS Id,
            JSON_VALUE([value], '$.AttributeName')                                AS AttributeName,
            JSON_VALUE([value], '$.DataType')                                     AS DataType,
            ISNULL(TRY_CAST(JSON_VALUE([value], '$.IsRequired') AS BIT), 0)       AS IsRequired,
            JSON_VALUE([value], '$.DefaultValue')                                 AS DefaultValue,
            JSON_VALUE([value], '$.Uom')                                          AS Uom,
            JSON_VALUE([value], '$.Description')                                  AS Description
        FROM OPENJSON(ISNULL(@AttributesJson, N'[]'));

        -- Every incoming row must carry AttributeName and DataType
        IF EXISTS (SELECT 1 FROM @Incoming WHERE AttributeName IS NULL OR DataType IS NULL)
        BEGIN
            SELECT TOP 1 @BadRow = RowIndex
            FROM @Incoming
            WHERE AttributeName IS NULL OR DataType IS NULL
            ORDER BY RowIndex;
            SET @BadRowStr = CAST(@BadRow AS NVARCHAR(10));
            SET @Message = N'Attribute at index ' + @BadRowStr + N' is missing AttributeName or DataType.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- No two incoming rows may share an AttributeName (after final reconciliation,
        -- the active set IS the submitted batch — duplicates would violate the
        -- filtered UNIQUE index from migration 0014).
        IF EXISTS (
            SELECT AttributeName FROM @Incoming
            WHERE AttributeName IS NOT NULL
            GROUP BY AttributeName HAVING COUNT(*) > 1
        )
        BEGIN
            SELECT TOP 1 @DupName = AttributeName
            FROM @Incoming
            WHERE AttributeName IS NOT NULL
            GROUP BY AttributeName HAVING COUNT(*) > 1;
            SET @Message = N'Duplicate AttributeName in batch: ' + @DupName + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Branch: CREATE vs UPDATE
        -- ====================
        IF @IsCreate = 1
        BEGIN
            -- Create-mode: Code must be globally unique among active LocationTypeDefinitions
            IF EXISTS (SELECT 1 FROM Location.LocationTypeDefinition
                       WHERE Code = @Code AND DeprecatedAt IS NULL)
            BEGIN
                SET @Message = N'A LocationTypeDefinition with this Code already exists.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'LocationTypeDef',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Created',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- All incoming attributes must be "new" in create mode (no Id)
            IF EXISTS (SELECT 1 FROM @Incoming WHERE Id IS NOT NULL)
            BEGIN
                SET @Message = N'Cannot specify attribute Ids when creating a new definition.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'LocationTypeDef',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Created',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- ===== Audit narrative + resolved JSON (built from PRE-mutation state) =====
            -- Subject + tier name (convention SUBJECT). Tier name resolves the
            -- LocationTypeId FK; category is implied by the Subject, so omitted.
            SELECT @TierName = Name FROM Location.LocationType WHERE Id = @LocationTypeId;

            SET @Subject = N'Location Type Definition "' + @Name + N'" ('
                         + ISNULL(@TierName, N'?') + N' tier)';

            -- Create: every incoming attribute is an add (+Attribute <Name>),
            -- capped at 3 with overflow.
            DECLARE @CreateAdds     NVARCHAR(MAX) = N'';
            DECLARE @CreateOverflow INT = 0;

            ;WITH ranked AS (
                SELECT AttributeName, ROW_NUMBER() OVER (ORDER BY RowIndex) AS rn
                FROM @Incoming
            )
            SELECT @CreateAdds = STRING_AGG(N'+Attribute ' + AttributeName, N', ')
                                 WITHIN GROUP (ORDER BY rn)
            FROM ranked WHERE rn <= 3;
            SELECT @CreateOverflow = COUNT(*) - 3 FROM @Incoming;
            IF @CreateOverflow < 0 SET @CreateOverflow = 0;

            DECLARE @CreateAction NVARCHAR(MAX) = N'Created';
            IF NULLIF(@CreateAdds, N'') IS NOT NULL
                SET @CreateAction = @CreateAction + N'; ' + @CreateAdds +
                    CASE WHEN @CreateOverflow > 0
                         THEN N', +' + CAST(@CreateOverflow AS NVARCHAR(10)) + N' more'
                         ELSE N'' END;

            SET @Activity = Audit.ufn_TruncateActivity(
                @Subject + N' ' + Audit.ufn_MidDot() + N' ' + @CreateAction);

            -- NewValue: post-state intent with resolved tier FK sub-object.
            SET @NewValue = (
                SELECT
                    JSON_QUERY((SELECT lt.Id, lt.Name
                                FROM Location.LocationType lt WHERE lt.Id = @LocationTypeId
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS LocationType,
                    @Code        AS Code,
                    @Name        AS Name,
                    @Icon        AS Icon,
                    @Description AS [Description],
                    JSON_QUERY((
                        SELECT i.AttributeName, i.DataType, i.IsRequired,
                               i.DefaultValue, i.Uom, i.RowIndex AS SortOrder, i.[Description]
                        FROM @Incoming i
                        ORDER BY i.RowIndex
                        FOR JSON PATH
                    )) AS Attributes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            -- ----- Mutation (atomic) -----
            BEGIN TRANSACTION;

            INSERT INTO Location.LocationTypeDefinition
                (LocationTypeId, Code, Name, Icon, Description, CreatedAt)
            VALUES
                (@LocationTypeId, @Code, @Name, @Icon, @Description, SYSUTCDATETIME());

            SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

            INSERT INTO Location.LocationAttributeDefinition
                (LocationTypeDefinitionId, AttributeName, DataType, IsRequired,
                 DefaultValue, Uom, SortOrder, Description, CreatedAt)
            SELECT
                @NewId, i.AttributeName, i.DataType, i.IsRequired,
                i.DefaultValue, i.Uom, i.RowIndex, i.Description, SYSUTCDATETIME()
            FROM @Incoming i;

            EXEC Audit.Audit_LogConfigChange
                @AppUserId         = @AppUserId,
                @LogEntityTypeCode = N'LocationTypeDef',
                @EntityId          = @NewId,
                @LogEventTypeCode  = N'Created',
                @LogSeverityCode   = N'Info',
                @Description       = @Activity,
                @OldValue          = NULL,
                @NewValue          = @NewValue;

            COMMIT TRANSACTION;

            SET @Status = 1;
            SELECT @CountAttrs = COUNT(*) FROM @Incoming;
            SET @CountAttrsStr = CAST(@CountAttrs AS NVARCHAR(10));
            SET @Message = N'Created definition with ' + @CountAttrsStr + N' attribute(s).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        ELSE
        BEGIN
            -- Update-mode: target must exist active, Code + LocationTypeId immutable
            SELECT @ExistingLocationTypeId = LocationTypeId,
                   @ExistingCode           = Code
            FROM Location.LocationTypeDefinition
            WHERE Id = @Id AND DeprecatedAt IS NULL;

            IF @ExistingLocationTypeId IS NULL
            BEGIN
                SET @Message = N'LocationTypeDefinition not found or is deprecated.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'LocationTypeDef',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            IF @ExistingCode <> @Code
            BEGIN
                SET @Message = N'Code is immutable on update. Existing: ' + @ExistingCode + N', submitted: ' + @Code + N'.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'LocationTypeDef',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            IF @ExistingLocationTypeId <> @LocationTypeId
            BEGIN
                SET @Message = N'LocationTypeId is immutable on update.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'LocationTypeDef',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- Every incoming row with a non-NULL Id must resolve to an active child
            -- of THIS definition. Catches stale Ids and cross-definition Id mixups.
            IF EXISTS (
                SELECT 1 FROM @Incoming i
                WHERE i.Id IS NOT NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM Location.LocationAttributeDefinition lad
                      WHERE lad.Id = i.Id
                        AND lad.LocationTypeDefinitionId = @Id
                        AND lad.DeprecatedAt IS NULL
                  )
            )
            BEGIN
                SET @Message = N'One or more submitted attributes reference an unknown or deprecated row.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'LocationTypeDef',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- ===== Audit narrative (built from PRE-mutation state) =====
            -- Subject + tier name. On update the Name may have changed; the
            -- Subject uses the submitted @Name (the post-save display name).
            SELECT @TierName = Name FROM Location.LocationType WHERE Id = @ExistingLocationTypeId;

            SET @Subject = N'Location Type Definition "' + @Name + N'"';

            -- Change-set classification: +Attribute (insert), -Attribute
            -- (deprecate-by-omit), ~Attribute (rename of an Id-matched child).
            DECLARE @Changes TABLE (
                ChangeKind  NCHAR(1)      NOT NULL,  -- '+' / '-' / '~'
                SortKey     INT           NOT NULL,
                OldName     NVARCHAR(100) NULL,
                NewName     NVARCHAR(100) NULL
            );

            -- ADDS: incoming Id IS NULL
            INSERT INTO @Changes (ChangeKind, SortKey, NewName)
            SELECT N'+', i.RowIndex, i.AttributeName
            FROM @Incoming i
            WHERE i.Id IS NULL;

            -- REMOVES: active child whose Id is not in incoming (deprecate-by-omit)
            INSERT INTO @Changes (ChangeKind, SortKey, OldName)
            SELECT N'-', ROW_NUMBER() OVER (ORDER BY lad.SortOrder), lad.AttributeName
            FROM Location.LocationAttributeDefinition lad
            WHERE lad.LocationTypeDefinitionId = @Id
              AND lad.DeprecatedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = lad.Id);

            -- RENAMES: Id-matched child whose AttributeName changed (~old -> new).
            -- Only the rename is surfaced in prose; other field edits on a
            -- matched row do not flip the ~ specific.
            INSERT INTO @Changes (ChangeKind, SortKey, OldName, NewName)
            SELECT N'~', ROW_NUMBER() OVER (ORDER BY lad.SortOrder),
                   lad.AttributeName, i.AttributeName
            FROM @Incoming i
            INNER JOIN Location.LocationAttributeDefinition lad
                ON lad.Id = i.Id
               AND lad.LocationTypeDefinitionId = @Id
               AND lad.DeprecatedAt IS NULL
            WHERE lad.AttributeName <> i.AttributeName;

            -- Per-operation prose, capped at 3 each with overflow.
            DECLARE @AddSpecifics    NVARCHAR(MAX) = N'';
            DECLARE @AddOverflow     INT = 0;
            DECLARE @RemoveSpecifics NVARCHAR(MAX) = N'';
            DECLARE @RemoveOverflow  INT = 0;
            DECLARE @RenameSpecifics NVARCHAR(MAX) = N'';
            DECLARE @RenameOverflow  INT = 0;

            ;WITH ranked AS (
                SELECT NewName, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
                FROM @Changes WHERE ChangeKind = N'+'
            )
            SELECT @AddSpecifics = STRING_AGG(N'+Attribute ' + NewName, N'; ')
                                   WITHIN GROUP (ORDER BY rn)
            FROM ranked WHERE rn <= 3;
            SELECT @AddOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'+';
            IF @AddOverflow < 0 SET @AddOverflow = 0;

            ;WITH ranked AS (
                SELECT OldName, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
                FROM @Changes WHERE ChangeKind = N'-'
            )
            SELECT @RemoveSpecifics = STRING_AGG(N'-Attribute ' + OldName, N'; ')
                                      WITHIN GROUP (ORDER BY rn)
            FROM ranked WHERE rn <= 3;
            SELECT @RemoveOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'-';
            IF @RemoveOverflow < 0 SET @RemoveOverflow = 0;

            ;WITH ranked AS (
                SELECT OldName, NewName, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
                FROM @Changes WHERE ChangeKind = N'~'
            )
            SELECT @RenameSpecifics = STRING_AGG(
                       N'~Attribute ' + OldName + N' ' + NCHAR(8594) + N' ' + NewName, N'; ')
                       WITHIN GROUP (ORDER BY rn)
            FROM ranked WHERE rn <= 3;
            SELECT @RenameOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'~';
            IF @RenameOverflow < 0 SET @RenameOverflow = 0;

            DECLARE @ActionParts NVARCHAR(MAX) = N'';

            IF NULLIF(@AddSpecifics, N'') IS NOT NULL
                SET @ActionParts = @ActionParts + @AddSpecifics +
                    CASE WHEN @AddOverflow > 0
                         THEN N'; +' + CAST(@AddOverflow AS NVARCHAR(10)) + N' more'
                         ELSE N'' END + N'; ';

            IF NULLIF(@RemoveSpecifics, N'') IS NOT NULL
                SET @ActionParts = @ActionParts + @RemoveSpecifics +
                    CASE WHEN @RemoveOverflow > 0
                         THEN N'; -' + CAST(@RemoveOverflow AS NVARCHAR(10)) + N' more'
                         ELSE N'' END + N'; ';

            IF NULLIF(@RenameSpecifics, N'') IS NOT NULL
                SET @ActionParts = @ActionParts + @RenameSpecifics +
                    CASE WHEN @RenameOverflow > 0
                         THEN N'; ~' + CAST(@RenameOverflow AS NVARCHAR(10)) + N' more'
                         ELSE N'' END + N'; ';

            -- Strip trailing "; " (DATALENGTH/2 - 2; NEVER LEN, which eats a
            -- real trailing character off the last specific).
            IF DATALENGTH(@ActionParts) >= 4
                SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts) / 2 - 2);

            IF @ActionParts = N''
                SET @ActionParts = N'Updated (no attribute changes)';

            SET @Activity = Audit.ufn_TruncateActivity(
                @Subject + N' ' + Audit.ufn_MidDot() + N' ' + @ActionParts);

            -- Capture pre-mutation state for audit diff, with resolved tier FK.
            SET @OldValue = (
                SELECT
                    JSON_QUERY((SELECT lt.Id, lt.Name
                                FROM Location.LocationType lt WHERE lt.Id = @ExistingLocationTypeId
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS LocationType,
                    JSON_QUERY((SELECT Id, Code, Name, Icon, [Description]
                                FROM Location.LocationTypeDefinition WHERE Id = @Id
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Definition,
                    JSON_QUERY((
                        SELECT Id, AttributeName, DataType, IsRequired, DefaultValue,
                               Uom, SortOrder, [Description]
                        FROM Location.LocationAttributeDefinition
                        WHERE LocationTypeDefinitionId = @Id AND DeprecatedAt IS NULL
                        ORDER BY SortOrder
                        FOR JSON PATH
                    )) AS Attributes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            -- ----- Mutation (atomic): order matters ------------------------
            -- 1. UPDATE parent meta
            -- 2. DEPRECATE active children not in incoming
            -- 3. UPDATE incoming Id-matched children (set fields + SortOrder=RowIndex)
            -- 4. INSERT incoming new children (Id IS NULL, SortOrder=RowIndex)
            BEGIN TRANSACTION;

            UPDATE Location.LocationTypeDefinition
            SET Name        = @Name,
                Icon        = @Icon,
                Description = @Description
            WHERE Id = @Id;

            UPDATE lad
            SET DeprecatedAt = SYSUTCDATETIME()
            FROM Location.LocationAttributeDefinition lad
            WHERE lad.LocationTypeDefinitionId = @Id
              AND lad.DeprecatedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = lad.Id);

            UPDATE lad
            SET AttributeName = i.AttributeName,
                DataType      = i.DataType,
                IsRequired    = i.IsRequired,
                DefaultValue  = i.DefaultValue,
                Uom           = i.Uom,
                SortOrder     = i.RowIndex,
                Description   = i.Description
            FROM Location.LocationAttributeDefinition lad
            INNER JOIN @Incoming i ON i.Id = lad.Id
            WHERE lad.LocationTypeDefinitionId = @Id
              AND lad.DeprecatedAt IS NULL;

            INSERT INTO Location.LocationAttributeDefinition
                (LocationTypeDefinitionId, AttributeName, DataType, IsRequired,
                 DefaultValue, Uom, SortOrder, Description, CreatedAt)
            SELECT
                @Id, i.AttributeName, i.DataType, i.IsRequired,
                i.DefaultValue, i.Uom, i.RowIndex, i.Description, SYSUTCDATETIME()
            FROM @Incoming i
            WHERE i.Id IS NULL;

            -- Capture post-mutation state for audit diff, with resolved tier FK.
            SET @NewValue = (
                SELECT
                    JSON_QUERY((SELECT lt.Id, lt.Name
                                FROM Location.LocationType lt WHERE lt.Id = @ExistingLocationTypeId
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS LocationType,
                    JSON_QUERY((SELECT Id, Code, Name, Icon, [Description]
                                FROM Location.LocationTypeDefinition WHERE Id = @Id
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Definition,
                    JSON_QUERY((
                        SELECT Id, AttributeName, DataType, IsRequired, DefaultValue,
                               Uom, SortOrder, [Description]
                        FROM Location.LocationAttributeDefinition
                        WHERE LocationTypeDefinitionId = @Id AND DeprecatedAt IS NULL
                        ORDER BY SortOrder
                        FOR JSON PATH
                    )) AS Attributes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            EXEC Audit.Audit_LogConfigChange
                @AppUserId         = @AppUserId,
                @LogEntityTypeCode = N'LocationTypeDef',
                @EntityId          = @Id,
                @LogEventTypeCode  = N'Updated',
                @LogSeverityCode   = N'Info',
                @Description       = @Activity,
                @OldValue          = @OldValue,
                @NewValue          = @NewValue;

            COMMIT TRANSACTION;

            SET @Status = 1;
            SELECT @CountAttrs = COUNT(*) FROM @Incoming;
            SET @CountAttrsStr = CAST(@CountAttrs AS NVARCHAR(10));
            SET @Message = N'Saved definition with ' + @CountAttrsStr + N' attribute(s).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
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
                @LogEntityTypeCode   = N'LocationTypeDef',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow; don't mask the original exception
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
