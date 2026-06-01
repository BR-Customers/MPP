-- =============================================
-- Procedure:   Parts.Item_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.3
--
-- Description:
--   Updates mutable fields of an active Item. PartNumber and ItemTypeId
--   are IMMUTABLE — to change either, deprecate the Item and create a
--   new one with the new identity.
--
--   Sets UpdatedAt = SYSUTCDATETIME() and UpdatedByUserId = @AppUserId
--   on every successful update. This is redundant with Audit.ConfigLog
--   but provides a cheap UI-side sort/filter key for "recently touched"
--   without joining the audit log.
--
--   Enforces the UnitWeight + WeightUomId pairing rule — if
--   UnitWeight is supplied, WeightUomId must be supplied too.
--
-- Parameters (input):
--   @Id BIGINT                    - Required.
--   @Description NVARCHAR(500) NULL
--   @MacolaPartNumber NVARCHAR(50) NULL
--   @DefaultSubLotQty INT NULL
--   @MaxLotSize INT NULL
--   @UomId BIGINT                 - Required.
--   @UnitWeight DECIMAL(10,4) NULL
--   @WeightUomId BIGINT NULL      - Required if UnitWeight provided.
--   @CountryOfOrigin NVARCHAR(2) NULL - ISO 3166-1 alpha-2. OI-19 (Phase E).
--   @MaxParts INT NULL            - Hard cap on pieces per container. OI-12.
--                                   Validated > 0 when supplied.
--   @AppUserId BIGINT             - Required for audit.
--
-- Result set:
--   Single row with Status (BIT), Message (NVARCHAR).
--   Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Parts.Item, Parts.Uom
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version (OUTPUT params)
--   2026-04-15 - 2.0 - SELECT result for Named Query compatibility
--   2026-04-23 - 2.1 - Phase G.3: @CountryOfOrigin added (OI-19)
--   2026-04-27 - 2.2 - OI-12 correction: @MaxParts added (moved from ContainerConfig)
--   2026-05-29 - 2.3 - Audit-readability convention (Slice 5 Item core):
--                       SUBJECT . Identity . Updated <field old->new ...>
--                       narrative Description (changed fields only) +
--                       resolved-FK Old/NewValue JSON (ItemType, Uom,
--                       WeightUom). Old values captured BEFORE the UPDATE.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.Item_Update
    @Id               BIGINT,
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

    DECLARE @ProcName NVARCHAR(200) = N'Parts.Item_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @Description AS Description,
                @MacolaPartNumber AS MacolaPartNumber,
                @DefaultSubLotQty AS DefaultSubLotQty,
                @MaxLotSize AS MaxLotSize, @UomId AS UomId,
                @UnitWeight AS UnitWeight, @WeightUomId AS WeightUomId,
                @CountryOfOrigin AS CountryOfOrigin,
                @MaxParts AS MaxParts
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- Parameter validation
        IF @Id IS NULL OR @UomId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: UnitWeight + WeightUomId must be paired
        IF @UnitWeight IS NOT NULL AND @WeightUomId IS NULL
        BEGIN
            SET @Message = N'WeightUomId is required when UnitWeight is provided.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: target must exist and be active
        IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @Id AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Item not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: UomId must exist and be active
        IF NOT EXISTS (SELECT 1 FROM Parts.Uom WHERE Id = @UomId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated UomId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: WeightUomId (if provided) must exist and be active
        IF @WeightUomId IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM Parts.Uom WHERE Id = @WeightUomId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Invalid or deprecated WeightUomId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Business rule: MaxParts, when supplied, must be positive
        IF @MaxParts IS NOT NULL AND @MaxParts <= 0
        BEGIN
            SET @Message = N'MaxParts must be greater than zero when supplied.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Capture OLD scalar values BEFORE the UPDATE (for field-diff) =====
        DECLARE @OldPartNumber       NVARCHAR(50);
        DECLARE @OldDescription      NVARCHAR(500);
        DECLARE @OldMacolaPartNumber NVARCHAR(50);
        DECLARE @OldDefaultSubLotQty INT;
        DECLARE @OldMaxLotSize       INT;
        DECLARE @OldUomId            BIGINT;
        DECLARE @OldUnitWeight       DECIMAL(10,4);
        DECLARE @OldWeightUomId      BIGINT;
        DECLARE @OldCountryOfOrigin  NVARCHAR(2);
        DECLARE @OldMaxParts         INT;

        SELECT @OldPartNumber       = PartNumber,
               @OldDescription      = Description,
               @OldMacolaPartNumber = MacolaPartNumber,
               @OldDefaultSubLotQty = DefaultSubLotQty,
               @OldMaxLotSize       = MaxLotSize,
               @OldUomId            = UomId,
               @OldUnitWeight       = UnitWeight,
               @OldWeightUomId      = WeightUomId,
               @OldCountryOfOrigin  = CountryOfOrigin,
               @OldMaxParts         = MaxParts
        FROM Parts.Item WHERE Id = @Id;

        -- Resolved-FK OldValue snapshot (pre-update state)
        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT
                i.Description,
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
            WHERE i.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- Build the field-diff Action prose: "Field old->new" tuples, changed
        -- fields only. Strings quoted; NULL rendered as literal null. UOM FKs
        -- diffed by code so the prose stays human-readable.
        DECLARE @NewUomCode       NVARCHAR(20) = (SELECT Code FROM Parts.Uom WHERE Id = @UomId);
        DECLARE @OldUomCode       NVARCHAR(20) = (SELECT Code FROM Parts.Uom WHERE Id = @OldUomId);
        DECLARE @NewWeightUomCode NVARCHAR(20) = (SELECT Code FROM Parts.Uom WHERE Id = @WeightUomId);
        DECLARE @OldWeightUomCode NVARCHAR(20) = (SELECT Code FROM Parts.Uom WHERE Id = @OldWeightUomId);

        DECLARE @Arrow NVARCHAR(3) = NCHAR(8594);

        DECLARE @Diff NVARCHAR(MAX) = STUFF(CONCAT(
            CASE WHEN ISNULL(@OldDescription, N'') <> ISNULL(@Description, N'')
                 THEN N', Description ' + ISNULL(N'"' + @OldDescription + N'"', N'null') + @Arrow + ISNULL(N'"' + @Description + N'"', N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldMacolaPartNumber, N'') <> ISNULL(@MacolaPartNumber, N'')
                 THEN N', MacolaPartNumber ' + ISNULL(N'"' + @OldMacolaPartNumber + N'"', N'null') + @Arrow + ISNULL(N'"' + @MacolaPartNumber + N'"', N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldDefaultSubLotQty, -2147483648) <> ISNULL(@DefaultSubLotQty, -2147483648)
                 THEN N', DefaultSubLotQty ' + ISNULL(CAST(@OldDefaultSubLotQty AS NVARCHAR(20)), N'null') + @Arrow + ISNULL(CAST(@DefaultSubLotQty AS NVARCHAR(20)), N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldMaxLotSize, -2147483648) <> ISNULL(@MaxLotSize, -2147483648)
                 THEN N', MaxLotSize ' + ISNULL(CAST(@OldMaxLotSize AS NVARCHAR(20)), N'null') + @Arrow + ISNULL(CAST(@MaxLotSize AS NVARCHAR(20)), N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldUomId, -1) <> ISNULL(@UomId, -1)
                 THEN N', Uom ' + ISNULL(@OldUomCode, N'null') + @Arrow + ISNULL(@NewUomCode, N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldUnitWeight, -999999) <> ISNULL(@UnitWeight, -999999)
                 THEN N', UnitWeight ' + ISNULL(CAST(@OldUnitWeight AS NVARCHAR(40)), N'null') + @Arrow + ISNULL(CAST(@UnitWeight AS NVARCHAR(40)), N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldWeightUomId, -1) <> ISNULL(@WeightUomId, -1)
                 THEN N', WeightUom ' + ISNULL(@OldWeightUomCode, N'null') + @Arrow + ISNULL(@NewWeightUomCode, N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldCountryOfOrigin, N'') <> ISNULL(@CountryOfOrigin, N'')
                 THEN N', CountryOfOrigin ' + ISNULL(N'"' + @OldCountryOfOrigin + N'"', N'null') + @Arrow + ISNULL(N'"' + @CountryOfOrigin + N'"', N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(@OldMaxParts, -2147483648) <> ISNULL(@MaxParts, -2147483648)
                 THEN N', MaxParts ' + ISNULL(CAST(@OldMaxParts AS NVARCHAR(20)), N'null') + @Arrow + ISNULL(CAST(@MaxParts AS NVARCHAR(20)), N'null')
                 ELSE N'' END
        ), 1, 2, N'');  -- strip leading ", "

        IF @Diff IS NULL OR @Diff = N''
            SET @Diff = N'no field changes';

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @OldPartNumber + N' ' + Audit.ufn_MidDot() + N' Identity ' + Audit.ufn_MidDot() +
            N' Updated ' + @Diff;

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        BEGIN TRANSACTION;

        UPDATE Parts.Item
        SET Description      = @Description,
            MacolaPartNumber = @MacolaPartNumber,
            DefaultSubLotQty = @DefaultSubLotQty,
            MaxLotSize       = @MaxLotSize,
            UomId            = @UomId,
            UnitWeight       = @UnitWeight,
            WeightUomId      = @WeightUomId,
            CountryOfOrigin  = @CountryOfOrigin,
            MaxParts         = @MaxParts,
            UpdatedAt        = SYSUTCDATETIME(),
            UpdatedByUserId  = @AppUserId
        WHERE Id = @Id;

        -- Resolved-FK NewValue snapshot (post-update state)
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT
                i.Description,
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
            WHERE i.Id = @Id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'Item',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Item updated successfully.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Item',
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
