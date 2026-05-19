-- =============================================
-- Procedure:   Location.Location_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-05-18
-- Version:     1.0
--
-- Description:
--   Bundled save for a Location instance and its LocationAttribute values
--   in a single atomic call. Mirrors the pattern established by
--   Location.LocationTypeDefinition_SaveAll: parent meta as params plus
--   a JSON array of attribute-VALUE rows reconciled server-side.
--
--   Create mode (@Id IS NULL):
--     Inserts a new Location under @ParentLocationId with the supplied
--     meta. Auto-assigns SortOrder to next sequential value among
--     active siblings if @SortOrder is NULL. Inserts every incoming
--     attribute row whose Value is non-empty as a Location.LocationAttribute.
--
--   Update mode (@Id IS NOT NULL):
--     Verifies ParentLocationId and LocationTypeDefinitionId match the
--     existing row (both immutable per FDS-02-002a -- changing either
--     would silently rewrite Honda-relevant track-and-trace reports
--     that join historical events to the live Location row). Updates
--     Name, Code, Description, SortOrder. Reconciles
--     Location.LocationAttribute rows for this Location:
--       - rows whose LocationAttributeDefinitionId is missing from
--         incoming, OR present with empty/NULL Value -> DELETE
--       - rows whose Id matches incoming with non-empty Value -> UPDATE
--       - incoming pairs with non-empty Value but no existing row -> INSERT
--     LocationAttribute rows are physical (no soft-delete) by design --
--     historical values are reconstructable from Audit.ConfigLog snapshots.
--
--   The whole operation runs under a single transaction; any validation
--   or DB failure rolls everything back.
--
-- Parameters (input):
--   @Id BIGINT = NULL                       - NULL = create new; non-NULL = update existing.
--   @ParentLocationId BIGINT = NULL         - FK to parent. NULL only valid for Enterprise root
--                                             (HierarchyLevel = 0). Required on create except root;
--                                             must match existing row on update (immutable).
--   @LocationTypeDefinitionId BIGINT        - FK to LocationTypeDefinition. Required on create;
--                                             must match existing row on update (immutable).
--   @Name NVARCHAR(200)                     - Display name. Required.
--   @Code NVARCHAR(50)                      - Short identifier. Required. Globally unique among active rows.
--   @Description NVARCHAR(500) = NULL       - Optional description.
--   @SortOrder INT = NULL                   - Explicit sort order within parent. NULL on create =
--                                             auto-assign MAX+1 among active siblings.
--   @AppUserId BIGINT                       - User performing the action. Required for audit.
--   @AttributeValuesJson NVARCHAR(MAX) = N'[]'
--                                           - JSON array of {LocationAttributeDefinitionId, Value}.
--                                             Empty/NULL Value means "no value" -- corresponding
--                                             LocationAttribute row (if any) is deleted on update;
--                                             no row inserted on create. Empty array means "no
--                                             attribute values" (valid).
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is the Location.Id (newly
--   assigned on create, echoed back on update).
--
-- Dependencies:
--   Tables: Location.Location, Location.LocationAttribute,
--           Location.LocationAttributeDefinition,
--           Location.LocationTypeDefinition, Location.LocationType
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   - Validation / business-rule failures: @Status=0, @Message set,
--     Audit_LogFailure, RETURN. No transaction in flight.
--   - CATCH handler: rollback, @Status=0, @Message captured from
--     ERROR_MESSAGE(), Audit_LogFailure (nested try/catch), RAISERROR.
--
-- Change Log:
--   2026-05-18 - 1.0 - Initial version
-- =============================================
CREATE OR ALTER PROCEDURE Location.Location_SaveAll
    @Id                       BIGINT          = NULL,
    @ParentLocationId         BIGINT          = NULL,
    @LocationTypeDefinitionId BIGINT,
    @Name                     NVARCHAR(200),
    @Code                     NVARCHAR(50),
    @Description              NVARCHAR(500)   = NULL,
    @SortOrder                INT             = NULL,
    @AppUserId                BIGINT,
    @AttributeValuesJson      NVARCHAR(MAX)   = N'[]'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ====================
    -- Result + working variables
    -- ====================
    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @Id;        -- echo on update; overwritten on create

    DECLARE @IsCreate  BIT           = CASE WHEN @Id IS NULL THEN 1 ELSE 0 END;
    DECLARE @EventCode NVARCHAR(50)  = CASE WHEN @IsCreate = 1 THEN N'Created' ELSE N'Updated' END;

    DECLARE @ExistingParentId         BIGINT;
    DECLARE @ExistingLocTypeDefId     BIGINT;
    DECLARE @ParentHierarchyLevel     INT;
    DECLARE @DefHierarchyLevel        INT;
    DECLARE @MissingAttrName          NVARCHAR(100);
    DECLARE @BadAttrId                BIGINT;
    DECLARE @OldValue                 NVARCHAR(MAX);
    DECLARE @NewValue                 NVARCHAR(MAX);
    DECLARE @NextSortOrder            INT;

    DECLARE @ProcName NVARCHAR(200) = N'Location.Location_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id                       AS Id,
                @ParentLocationId         AS ParentLocationId,
                @LocationTypeDefinitionId AS LocationTypeDefinitionId,
                @Code                     AS Code,
                @Name                     AS Name,
                @Description              AS Description,
                @SortOrder                AS SortOrder,
                JSON_QUERY(ISNULL(@AttributeValuesJson, N'[]')) AS AttributeValues
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Incoming attribute values, parsed once up front and reused throughout.
    -- Empty / whitespace-only Values map to NULL so a single test (Value IS NULL)
    -- captures "the user cleared this attribute."
    DECLARE @Incoming TABLE (
        RowIndex                       INT PRIMARY KEY,
        LocationAttributeDefinitionId  BIGINT       NULL,
        Value                          NVARCHAR(255) NULL
    );

    BEGIN TRY
        -- ====================
        -- Tier 1: Parameter validation
        -- ====================
        IF @LocationTypeDefinitionId IS NULL OR @Name IS NULL OR @Code IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Type definition existence + level lookup
        -- ====================
        SELECT @DefHierarchyLevel = lt.HierarchyLevel
        FROM Location.LocationTypeDefinition ltd
        INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
        WHERE ltd.Id = @LocationTypeDefinitionId AND ltd.DeprecatedAt IS NULL;

        IF @DefHierarchyLevel IS NULL
        BEGIN
            SET @Message = N'Invalid or deprecated LocationTypeDefinitionId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Parent existence + level lookup (NULL parent only valid for HierarchyLevel = 0)
        -- ====================
        IF @ParentLocationId IS NULL
        BEGIN
            IF @DefHierarchyLevel <> 0
            BEGIN
                SET @Message = N'Only Enterprise-tier locations may have NULL ParentLocationId.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = @EventCode,
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
            SET @ParentHierarchyLevel = -1;     -- sentinel; level check below is harmless
        END
        ELSE
        BEGIN
            SELECT @ParentHierarchyLevel = lt.HierarchyLevel
            FROM Location.Location l
            INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
            INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
            WHERE l.Id = @ParentLocationId AND l.DeprecatedAt IS NULL;

            IF @ParentHierarchyLevel IS NULL
            BEGIN
                SET @Message = N'Invalid or deprecated ParentLocationId.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = @EventCode,
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- FDS-02-002: child HierarchyLevel SHOULD be >= parent's
            IF @DefHierarchyLevel < @ParentHierarchyLevel
            BEGIN
                SET @Message = N'Location HierarchyLevel must be >= parent''s HierarchyLevel (FDS-02-002).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = @EventCode,
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
        END

        -- ====================
        -- Parse @AttributeValuesJson into @Incoming.
        -- Empty / whitespace Value strings collapse to NULL so a single test
        -- (Value IS NULL) captures "no value here."
        -- ====================
        INSERT INTO @Incoming (RowIndex, LocationAttributeDefinitionId, Value)
        SELECT
            CAST([key] AS INT) + 1                                                AS RowIndex,
            TRY_CAST(JSON_VALUE([value], '$.LocationAttributeDefinitionId') AS BIGINT) AS LocationAttributeDefinitionId,
            NULLIF(LTRIM(RTRIM(JSON_VALUE([value], '$.Value'))), N'')              AS Value
        FROM OPENJSON(ISNULL(@AttributeValuesJson, N'[]'));

        -- Every incoming row must carry a LocationAttributeDefinitionId
        IF EXISTS (SELECT 1 FROM @Incoming WHERE LocationAttributeDefinitionId IS NULL)
        BEGIN
            SET @Message = N'One or more attribute rows are missing LocationAttributeDefinitionId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Every incoming LocationAttributeDefinitionId must belong to this LocationTypeDefinition
        SELECT TOP 1 @BadAttrId = i.LocationAttributeDefinitionId
        FROM @Incoming i
        WHERE NOT EXISTS (
            SELECT 1 FROM Location.LocationAttributeDefinition lad
            WHERE lad.Id = i.LocationAttributeDefinitionId
              AND lad.LocationTypeDefinitionId = @LocationTypeDefinitionId
              AND lad.DeprecatedAt IS NULL
        );
        IF @BadAttrId IS NOT NULL
        BEGIN
            SET @Message = N'Attribute ' + CAST(@BadAttrId AS NVARCHAR(20))
                         + N' does not belong to this Location''s type definition (or is deprecated).';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
                @EntityId            = @Id,
                @LogEventTypeCode    = @EventCode,
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Required attributes must have a non-NULL Value in incoming
        SELECT TOP 1 @MissingAttrName = lad.AttributeName
        FROM Location.LocationAttributeDefinition lad
        WHERE lad.LocationTypeDefinitionId = @LocationTypeDefinitionId
          AND lad.DeprecatedAt IS NULL
          AND lad.IsRequired = 1
          AND NOT EXISTS (
              SELECT 1 FROM @Incoming i
              WHERE i.LocationAttributeDefinitionId = lad.Id
                AND i.Value IS NOT NULL
          )
        ORDER BY lad.SortOrder, lad.Id;
        IF @MissingAttrName IS NOT NULL
        BEGIN
            SET @Message = N'Required attribute missing a value: ' + @MissingAttrName + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'Location',
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
            -- Code uniqueness among active rows
            IF EXISTS (SELECT 1 FROM Location.Location
                       WHERE Code = @Code AND DeprecatedAt IS NULL)
            BEGIN
                SET @Message = N'A location with this Code already exists.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = NULL,
                    @LogEventTypeCode    = N'Created',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- Auto-assign SortOrder if NULL
            IF @SortOrder IS NULL
            BEGIN
                IF @ParentLocationId IS NULL
                    SELECT @NextSortOrder = ISNULL(MAX(SortOrder), 0) + 1
                    FROM Location.Location
                    WHERE ParentLocationId IS NULL AND DeprecatedAt IS NULL;
                ELSE
                    SELECT @NextSortOrder = ISNULL(MAX(SortOrder), 0) + 1
                    FROM Location.Location
                    WHERE ParentLocationId = @ParentLocationId AND DeprecatedAt IS NULL;

                SET @SortOrder = @NextSortOrder;
            END

            -- ----- Mutation (atomic) -----
            BEGIN TRANSACTION;

            INSERT INTO Location.Location
                (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder, CreatedAt)
            VALUES
                (@LocationTypeDefinitionId, @ParentLocationId, @Name, @Code, @Description, @SortOrder, SYSUTCDATETIME());

            SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

            -- Insert attribute values for non-empty incoming rows
            INSERT INTO Location.LocationAttribute
                (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
            SELECT
                @NewId, i.LocationAttributeDefinitionId, i.Value, SYSUTCDATETIME()
            FROM @Incoming i
            WHERE i.Value IS NOT NULL;

            EXEC Audit.Audit_LogConfigChange
                @AppUserId         = @AppUserId,
                @LogEntityTypeCode = N'Location',
                @EntityId          = @NewId,
                @LogEventTypeCode  = N'Created',
                @LogSeverityCode   = N'Info',
                @Description       = N'Location created with attribute values.',
                @OldValue          = NULL,
                @NewValue          = @Params;

            COMMIT TRANSACTION;

            SET @Status  = 1;
            SET @Message = N'Location created successfully.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        ELSE
        BEGIN
            -- Update-mode: target must exist active, ParentLocationId + LocationTypeDefinitionId immutable
            SELECT @ExistingParentId      = ParentLocationId,
                   @ExistingLocTypeDefId  = LocationTypeDefinitionId
            FROM Location.Location
            WHERE Id = @Id AND DeprecatedAt IS NULL;

            -- Use IS NULL guard on LocationTypeDefinitionId (always NOT NULL in DB but defensive)
            IF @ExistingLocTypeDefId IS NULL
            BEGIN
                SET @Message = N'Location not found or is deprecated.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- FDS-02-002a: ParentLocationId is immutable
            IF (@ExistingParentId IS NULL AND @ParentLocationId IS NOT NULL)
            OR (@ExistingParentId IS NOT NULL AND @ParentLocationId IS NULL)
            OR (@ExistingParentId <> @ParentLocationId)
            BEGIN
                SET @Message = N'ParentLocationId is immutable on update (FDS-02-002a). Use Deprecate + Create New to relocate.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- FDS-02-002a: LocationTypeDefinitionId is immutable
            IF @ExistingLocTypeDefId <> @LocationTypeDefinitionId
            BEGIN
                SET @Message = N'LocationTypeDefinitionId is immutable on update (FDS-02-002a).';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- Code uniqueness excluding self
            IF EXISTS (SELECT 1 FROM Location.Location
                       WHERE Code = @Code AND DeprecatedAt IS NULL AND Id <> @Id)
            BEGIN
                SET @Message = N'A location with this Code already exists.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = N'Updated',
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END

            -- Capture pre-mutation state for audit diff
            SET @OldValue = (
                SELECT
                    (SELECT Id, ParentLocationId, LocationTypeDefinitionId,
                            Code, Name, Description, SortOrder
                     FROM Location.Location WHERE Id = @Id
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Location,
                    JSON_QUERY((
                        SELECT LocationAttributeDefinitionId, AttributeValue
                        FROM Location.LocationAttribute
                        WHERE LocationId = @Id
                        FOR JSON PATH
                    )) AS Attributes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            -- ----- Mutation (atomic) -----
            -- 1. UPDATE Location meta (preserve current SortOrder if @SortOrder is NULL)
            -- 2. DELETE LocationAttribute rows missing from incoming OR with empty Value
            -- 3. UPDATE LocationAttribute rows matched by LocationAttributeDefinitionId
            -- 4. INSERT LocationAttribute rows for incoming with non-empty Value and no existing row
            BEGIN TRANSACTION;

            UPDATE Location.Location
            SET Name        = @Name,
                Code        = @Code,
                Description = @Description,
                SortOrder   = COALESCE(@SortOrder, SortOrder)
            WHERE Id = @Id;

            -- DELETE rows whose LocationAttributeDefinitionId is missing from incoming,
            -- OR present with NULL Value (operator cleared the field).
            DELETE la
            FROM Location.LocationAttribute la
            WHERE la.LocationId = @Id
              AND NOT EXISTS (
                  SELECT 1 FROM @Incoming i
                  WHERE i.LocationAttributeDefinitionId = la.LocationAttributeDefinitionId
                    AND i.Value IS NOT NULL
              );

            -- UPDATE existing rows where incoming has a non-NULL Value
            UPDATE la
            SET AttributeValue  = i.Value,
                UpdatedAt       = SYSUTCDATETIME(),
                UpdatedByUserId = @AppUserId
            FROM Location.LocationAttribute la
            INNER JOIN @Incoming i
                ON i.LocationAttributeDefinitionId = la.LocationAttributeDefinitionId
            WHERE la.LocationId = @Id
              AND i.Value IS NOT NULL;

            -- INSERT rows for incoming with non-NULL Value and no existing row
            INSERT INTO Location.LocationAttribute
                (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
            SELECT
                @Id, i.LocationAttributeDefinitionId, i.Value, SYSUTCDATETIME()
            FROM @Incoming i
            WHERE i.Value IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM Location.LocationAttribute la
                  WHERE la.LocationId = @Id
                    AND la.LocationAttributeDefinitionId = i.LocationAttributeDefinitionId
              );

            -- Capture post-mutation state for audit diff
            SET @NewValue = (
                SELECT
                    (SELECT Id, ParentLocationId, LocationTypeDefinitionId,
                            Code, Name, Description, SortOrder
                     FROM Location.Location WHERE Id = @Id
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS Location,
                    JSON_QUERY((
                        SELECT LocationAttributeDefinitionId, AttributeValue
                        FROM Location.LocationAttribute
                        WHERE LocationId = @Id
                        FOR JSON PATH
                    )) AS Attributes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            EXEC Audit.Audit_LogConfigChange
                @AppUserId         = @AppUserId,
                @LogEntityTypeCode = N'Location',
                @EntityId          = @Id,
                @LogEventTypeCode  = N'Updated',
                @LogSeverityCode   = N'Info',
                @Description       = N'Location updated with attribute reconciliation.',
                @OldValue          = @OldValue,
                @NewValue          = @NewValue;

            COMMIT TRANSACTION;

            SET @Status  = 1;
            SET @Message = N'Location saved successfully.';
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
                @LogEntityTypeCode   = N'Location',
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
