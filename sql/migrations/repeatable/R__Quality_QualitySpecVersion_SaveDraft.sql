-- =============================================
-- Procedure:   Quality.QualitySpecVersion_SaveDraft
-- Author:      Blue Ridge Automation
-- Created:     2026-05-29
-- Version:     1.1
--
-- Description:
--   Bundled attribute reconciliation for a Draft QualitySpecVersion.
--   Accepts the version's complete desired-state JSON array of
--   QualitySpecAttribute rows and atomically reconciles against the
--   current attribute set:
--     - Incoming row Id=NULL                         -> INSERT
--     - Incoming row Id matches existing attribute    -> UPDATE
--     - Existing attribute whose Id is absent          -> DELETE
--   SortOrder is assigned as the 1-based array index.
--
--   Only operates on a Draft version (PublishedAt NULL AND
--   DeprecatedAt NULL). Published or Deprecated versions are rejected.
--   @EffectiveFrom, when supplied, updates the version header; when
--   NULL the existing value is preserved.
--
-- Parameters (input):
--   @QualitySpecVersionId BIGINT          - Required. Must be a Draft.
--   @EffectiveFrom        DATETIME2(3) NULL - Optional header update.
--   @AttributesJson       NVARCHAR(MAX)   - JSON array, see body schema.
--   @AppUserId            BIGINT          - Required for audit.
--
-- Result set:
--   Single row: Status (BIT), Message (NVARCHAR), NewId (BIGINT echoes
--   @QualitySpecVersionId). Status=1 on success, 0 on failure.
--
-- Dependencies:
--   Tables: Quality.QualitySpecVersion, Quality.QualitySpecAttribute,
--           Quality.QualitySpec, Parts.Item, Parts.Uom
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--
-- Change Log:
--   2026-05-29 - 1.0 - Initial (Quality Spec Config Tool, Phase A / A3).
--   2026-05-29 - 1.1 - Within-bounds validation: reject save when an
--                       attribute's Lower>Upper or Target is outside
--                       [Lower,Upper] (mirrors eligibility Min<=Default<=Max).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.QualitySpecVersion_SaveDraft
    @QualitySpecVersionId BIGINT,
    @EffectiveFrom        DATETIME2(3)  = NULL,
    @AttributesJson       NVARCHAR(MAX) = N'[]',
    @AppUserId            BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;   -- echoes version id

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySpecVersion_SaveDraft';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @QualitySpecVersionId AS QualitySpecVersionId,
                @EffectiveFrom AS EffectiveFrom,
                JSON_QUERY(ISNULL(@AttributesJson, N'[]')) AS Attributes
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        IF @QualitySpecVersionId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @QualitySpecVersionId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        DECLARE @PublishedAt   DATETIME2(3),
                @DeprecatedAt  DATETIME2(3),
                @SpecId        BIGINT,
                @VersionNumber INT,
                @RowExists     BIT = 0;
        SELECT @PublishedAt   = PublishedAt,
               @DeprecatedAt  = DeprecatedAt,
               @SpecId        = QualitySpecId,
               @VersionNumber = VersionNumber,
               @RowExists     = 1
        FROM Quality.QualitySpecVersion
        WHERE Id = @QualitySpecVersionId;

        IF @RowExists = 0
        BEGIN
            SET @Message = N'Version not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @QualitySpecVersionId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @PublishedAt IS NOT NULL OR @DeprecatedAt IS NOT NULL
        BEGIN
            SET @Message = N'Only Draft versions can be saved.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @QualitySpecVersionId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- Shred incoming JSON into a typed buffer with a 1-based ordinal
        DECLARE @Incoming TABLE (
            Ord           INT,
            Id            BIGINT,
            AttributeName NVARCHAR(100),
            DataType      NVARCHAR(50),
            UomId         BIGINT,
            TargetValue   DECIMAL(18,6),
            LowerLimit    DECIMAL(18,6),
            UpperLimit    DECIMAL(18,6),
            IsRequired    BIT);
        INSERT INTO @Incoming
            (Ord, Id, AttributeName, DataType, UomId, TargetValue, LowerLimit, UpperLimit, IsRequired)
        SELECT
            (CAST([key] AS INT) + 1),
            TRY_CAST(JSON_VALUE([value], '$.Id')            AS BIGINT),
            JSON_VALUE([value], '$.AttributeName'),
            JSON_VALUE([value], '$.DataType'),
            TRY_CAST(JSON_VALUE([value], '$.UomId')         AS BIGINT),
            TRY_CAST(JSON_VALUE([value], '$.TargetValue')   AS DECIMAL(18,6)),
            TRY_CAST(JSON_VALUE([value], '$.LowerLimit')    AS DECIMAL(18,6)),
            TRY_CAST(JSON_VALUE([value], '$.UpperLimit')    AS DECIMAL(18,6)),
            COALESCE(TRY_CAST(JSON_VALUE([value], '$.IsRequired') AS BIT), 1)
        FROM OPENJSON(ISNULL(@AttributesJson, N'[]'));

        -- ---- Within-bounds validation (Lower <= Target <= Upper, Lower <= Upper) ----
        -- Enforced on save so a draft can never hold a target outside its own
        -- limits. Mirrors the eligibility SaveAll Min<=Default<=Max gate. Each
        -- bound is checked only when both it and the compared value are present,
        -- so partially-specified numeric attributes stay editable as drafts.
        DECLARE @ViolationCount INT = (
            SELECT COUNT(*) FROM @Incoming
            WHERE (LowerLimit IS NOT NULL AND UpperLimit IS NOT NULL AND LowerLimit > UpperLimit)
               OR (TargetValue IS NOT NULL AND LowerLimit IS NOT NULL AND TargetValue < LowerLimit)
               OR (TargetValue IS NOT NULL AND UpperLimit IS NOT NULL AND TargetValue > UpperLimit));

        IF @ViolationCount > 0
        BEGIN
            DECLARE @BadAttr NVARCHAR(100), @BadKind NVARCHAR(60);
            SELECT TOP 1
                   @BadAttr = ISNULL(AttributeName, N'(unnamed)'),
                   @BadKind = CASE
                       WHEN LowerLimit IS NOT NULL AND UpperLimit IS NOT NULL AND LowerLimit > UpperLimit
                            THEN N'lower limit is above upper limit'
                       WHEN TargetValue IS NOT NULL AND LowerLimit IS NOT NULL AND TargetValue < LowerLimit
                            THEN N'target is below lower limit'
                       ELSE N'target is above upper limit'
                   END
            FROM @Incoming
            WHERE (LowerLimit IS NOT NULL AND UpperLimit IS NOT NULL AND LowerLimit > UpperLimit)
               OR (TargetValue IS NOT NULL AND LowerLimit IS NOT NULL AND TargetValue < LowerLimit)
               OR (TargetValue IS NOT NULL AND UpperLimit IS NOT NULL AND TargetValue > UpperLimit)
            ORDER BY Ord;

            SET @Message = N'Attribute "' + @BadAttr + N'": ' + @BadKind
                + N'. Target must be within the Lower and Upper limits.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @QualitySpecVersionId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE Quality.QualitySpecVersion
            SET EffectiveFrom = ISNULL(@EffectiveFrom, EffectiveFrom)
        WHERE Id = @QualitySpecVersionId;

        -- DELETE: active attrs whose Id is not in incoming
        DELETE a FROM Quality.QualitySpecAttribute a
        WHERE a.QualitySpecVersionId = @QualitySpecVersionId
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = a.Id);

        -- UPDATE: incoming rows with a matching Id
        UPDATE a SET
            a.AttributeName = i.AttributeName,
            a.DataType      = i.DataType,
            a.UomId         = i.UomId,
            a.TargetValue   = i.TargetValue,
            a.LowerLimit    = i.LowerLimit,
            a.UpperLimit    = i.UpperLimit,
            a.IsRequired    = i.IsRequired,
            a.SortOrder     = i.Ord
        FROM Quality.QualitySpecAttribute a
        INNER JOIN @Incoming i ON i.Id = a.Id
        WHERE a.QualitySpecVersionId = @QualitySpecVersionId;

        -- INSERT: incoming rows with Id null
        INSERT INTO Quality.QualitySpecAttribute
            (QualitySpecVersionId, AttributeName, DataType, UomId,
             TargetValue, LowerLimit, UpperLimit, IsRequired, SortOrder)
        SELECT @QualitySpecVersionId, i.AttributeName, i.DataType, i.UomId,
               i.TargetValue, i.LowerLimit, i.UpperLimit, i.IsRequired, i.Ord
        FROM @Incoming i WHERE i.Id IS NULL;

        -- ===== Readable audit (SUBJECT . CATEGORY? . ACTION) =====
        DECLARE @SpecName   NVARCHAR(200), @PartNumber NVARCHAR(50);
        SELECT @SpecName   = qs.Name,
               @PartNumber = pi.PartNumber
        FROM Quality.QualitySpec qs
        LEFT JOIN Parts.Item pi ON pi.Id = qs.ItemId
        WHERE qs.Id = @SpecId;

        DECLARE @AttrTotal INT =
            (SELECT COUNT(*) FROM Quality.QualitySpecAttribute
             WHERE QualitySpecVersionId = @QualitySpecVersionId);

        DECLARE @AuditDescRaw NVARCHAR(MAX) =
            CASE WHEN @PartNumber IS NOT NULL
                 THEN @PartNumber + N' ' + Audit.ufn_MidDot() + N' '
                 ELSE N'' END
            + N'Quality Spec "' + @SpecName + N'" v' + CAST(@VersionNumber AS NVARCHAR(10))
            + N' (Draft) ' + Audit.ufn_MidDot() + N' Saved; '
            + CAST(@AttrTotal AS NVARCHAR(10)) + N' attributes';

        DECLARE @AuditDesc NVARCHAR(500) = Audit.ufn_TruncateActivity(@AuditDescRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT a.Id, a.AttributeName, a.DataType,
                   JSON_QUERY((SELECT u.Id, u.Code, u.Name
                               FROM Parts.Uom u WHERE u.Id = a.UomId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Uom,
                   a.TargetValue, a.LowerLimit, a.UpperLimit,
                   a.IsRequired, a.SortOrder
            FROM Quality.QualitySpecAttribute a
            WHERE a.QualitySpecVersionId = @QualitySpecVersionId
            ORDER BY a.SortOrder
            FOR JSON PATH);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'QualitySpecVersion',
            @EntityId          = @QualitySpecVersionId,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description        = @AuditDesc,
            @OldValue          = NULL,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @NewId   = @QualitySpecVersionId;
        SET @Message = N'Draft saved (' + CAST(@AttrTotal AS NVARCHAR(10)) + N' attributes).';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySpecVersion',
                @EntityId = @QualitySpecVersionId, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
            -- Swallow failure-log errors to avoid masking the original error
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
