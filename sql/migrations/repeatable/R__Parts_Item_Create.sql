-- =============================================
-- Procedure:   Parts.Item_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.3
--
-- Description:
--   Creates a new Item row. Validates ItemTypeId, UomId, and
--   WeightUomId FKs; enforces PartNumber uniqueness. Requires
--   WeightUomId when UnitWeight is provided (the two must be
--   paired — weight without UOM is ambiguous).
--
--   Sets CreatedByUserId = @AppUserId.
--
-- Parameters (input):
--   @PartNumber NVARCHAR(50)       - Required. Unique.
--   @ItemTypeId BIGINT             - FK → Parts.ItemType. Required.
--   @Description NVARCHAR(500) NULL
--   @MacolaPartNumber NVARCHAR(50) NULL
--   @DefaultSubLotQty INT NULL
--   @MaxLotSize INT NULL
--   @UomId BIGINT                  - FK → Parts.Uom. Required.
--   @UnitWeight DECIMAL(10,4) NULL
--   @WeightUomId BIGINT NULL       - FK → Parts.Uom. Required if UnitWeight provided.
--   @CountryOfOrigin NVARCHAR(2) NULL - ISO 3166-1 alpha-2. OI-19 (Phase E).
--   @MaxParts INT NULL             - Hard cap on pieces per container of this Part. OI-12.
--                                    Validated > 0 when supplied.
--   @AppUserId BIGINT              - User performing action. Required.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   Status=1 on success, 0 on failure. NewId is NULL on failure.
--
-- Dependencies:
--   Tables: Parts.Item, Parts.ItemType, Parts.Uom
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   Three-tier: validation, business rule, CATCH with RAISERROR.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.3: @CountryOfOrigin added (OI-19)
--   2026-04-27 - 2.2 - OI-12 correction: @MaxParts added (moved from ContainerConfig)
--   2026-05-29 - 2.3 - Audit-readability convention (Slice 5 Item core):
--                       SUBJECT . CATEGORY . ACTION narrative Description +
--                       resolved-FK NewValue JSON (ItemType {Id, Name},
--                       Uom {Id, Code, Name}).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_Create
    @PartNumber       NVARCHAR(50),
    @ItemTypeId       BIGINT,
    @Description      NVARCHAR(500)  = NULL,
    @MacolaPartNumber NVARCHAR(50)   = NULL,
    @DefaultSubLotQty INT            = NULL,
    @MaxLotSize       INT            = NULL,
    @UomId            BIGINT,
    @UnitWeight       DECIMAL(10,4)  = NULL,
    @WeightUomId      BIGINT         = NULL,
    @CountryOfOrigin  NVARCHAR(2)    = NULL,
    @MaxParts         INT            = NULL,
    @AppUserId        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Item_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @PartNumber       AS PartNumber,
                @ItemTypeId       AS ItemTypeId,
                @Description      AS Description,
                @MacolaPartNumber AS MacolaPartNumber,
                @DefaultSubLotQty AS DefaultSubLotQty,
                @MaxLotSize       AS MaxLotSize,
                @UomId            AS UomId,
                @UnitWeight       AS UnitWeight,
                @WeightUomId      AS WeightUomId,
                @CountryOfOrigin  AS CountryOfOrigin,
                @MaxParts         AS MaxParts
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Parameter validation
        IF @PartNumber IS NULL OR @ItemTypeId IS NULL OR @UomId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: UnitWeight + WeightUomId must be paired
        IF @UnitWeight IS NOT NULL AND @WeightUomId IS NULL
        BEGIN
            SET @Message = N'WeightUomId is required when UnitWeight is provided.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: ItemTypeId must exist and be active
        IF NOT EXISTS (SELECT 1 FROM Parts.ItemType WHERE Id = @ItemTypeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated ItemTypeId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: UomId must exist and be active
        IF NOT EXISTS (SELECT 1 FROM Parts.Uom WHERE Id = @UomId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated UomId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: WeightUomId (if provided) must exist and be active
        IF @WeightUomId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Parts.Uom WHERE Id = @WeightUomId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated WeightUomId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: PartNumber unique (table has a UNIQUE constraint across
        -- all rows including deprecated — check both so the message is friendly)
        IF EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = @PartNumber)
        BEGIN
            SET @Message = N'An Item with this PartNumber already exists.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Business rule: MaxParts, when supplied, must be positive
        IF @MaxParts IS NOT NULL AND @MaxParts <= 0
        BEGIN
            SET @Message = N'MaxParts must be greater than zero when supplied.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        INSERT INTO Parts.Item
            (ItemTypeId, PartNumber, Description, MacolaPartNumber,
             DefaultSubLotQty, MaxLotSize, UomId, UnitWeight, WeightUomId,
             CountryOfOrigin, MaxParts, CreatedAt, CreatedByUserId)
        VALUES
            (@ItemTypeId, @PartNumber, @Description, @MacolaPartNumber,
             @DefaultSubLotQty, @MaxLotSize, @UomId, @UnitWeight, @WeightUomId,
             @CountryOfOrigin, @MaxParts, SYSUTCDATETIME(), @AppUserId);

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ===== Audit narrative + resolved JSON =====

        -- Subject: <PartNumber> — <Description> (<ItemTypeName>)
        DECLARE @ItemTypeName NVARCHAR(200) =
            (SELECT Name FROM Parts.ItemType WHERE Id = @ItemTypeId);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @PartNumber
            + CASE WHEN @Description IS NOT NULL
                   THEN N' ' + NCHAR(8212) + N' ' + @Description ELSE N'' END
            + CASE WHEN @ItemTypeName IS NOT NULL
                   THEN N' (' + @ItemTypeName + N')' ELSE N'' END
            + N' ' + Audit.ufn_MidDot() + N' Created';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Resolved-FK NewValue snapshot (post-create state)
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                i.Id,
                i.PartNumber,
                i.Description,
                JSON_QUERY((SELECT it.Id, it.Name
                            FROM Parts.ItemType it WHERE it.Id = i.ItemTypeId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))     AS ItemType,
                i.MacolaPartNumber,
                i.DefaultSubLotQty,
                i.MaxLotSize,
                JSON_QUERY((SELECT u.Id, u.Code, u.Name
                            FROM Parts.Uom u WHERE u.Id = i.UomId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))     AS Uom,
                i.UnitWeight,
                JSON_QUERY((SELECT wu.Id, wu.Code, wu.Name
                            FROM Parts.Uom wu WHERE wu.Id = i.WeightUomId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))     AS WeightUom,
                i.CountryOfOrigin,
                i.MaxParts
            FROM Parts.Item i
            WHERE i.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Item',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Item created successfully.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
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
