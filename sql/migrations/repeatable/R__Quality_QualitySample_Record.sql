-- ============================================================
-- Repeatable:  R__Quality_QualitySample_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-10
-- Version:     1.0
-- Description: Arc 2 Phase 9 (FDS-08-011/012/014). Records ONE inspection
--              sample against a LOT: a Quality.QualitySample header plus one
--              Quality.QualityResult row per attribute in @ResultsJson.
--
--              @ResultsJson is a JSON array of
--                  {"qualitySpecAttributeId": <id>, "measuredValue": "<text>"}
--
--              Pass/fail semantics (FDS-08-011.2/3, reconciliation spec):
--                * Numeric attribute WITH any limit -> IsPass = TRY_CONVERT'd
--                  value within [LowerLimit, UpperLimit] (a NULL bound is open);
--                  non-convertible non-empty value -> IsPass 0. The converted
--                  DECIMAL(18,4) is stored in NumericValue (v1.9p shadow).
--                * Numeric attribute with NO limits / non-numeric attribute ->
--                  IsPass 1 when a value is present, 0 when IsRequired=1 and
--                  empty (rejected pre-txn anyway), NULL (informational) when
--                  optional and empty.
--                * Overall = Fail when any IsRequired=1 attribute has IsPass=0,
--                  else Pass. Resolved to Quality.InspectionResultCode.
--
--              NO AUTO-HOLD on Fail (FDS-08-012): the proc records the result
--              and returns it; alerting is the view's toast. Inspection of a
--              HELD lot is allowed (any LOT status, including Hold/Closed).
--
--              FDS-11-011 + Msg-3915 rules: ALL rejecting validations run
--              BEFORE BEGIN TRANSACTION (this proc is captured via INSERT-EXEC;
--              CATCH is the only legal ROLLBACK site). Single terminal row:
--              Status, Message, NewId (= new QualitySample id).
--
--              Audit: entity 'QualitySample' (57) / event 'InspectionRecorded'
--              (63) -> Audit.OperationLog (Audit_LogOperation routes only 'Lot'
--              to LotEventLog). Description:
--                  <LotName> . Inspection . <Pass|Fail> (<n>/<m> attributes)
--              NewValue carries resolved Lot + SpecVersion sub-objects.
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.QualitySample_Record
    @LotId                BIGINT,
    @QualitySpecVersionId BIGINT,
    @LocationId           BIGINT        = NULL,
    @SampleTriggerCodeId  BIGINT        = NULL,
    @ResultsJson          NVARCHAR(MAX),
    @AppUserId            BIGINT,
    @TerminalLocationId   BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.QualitySample_Record';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @QualitySpecVersionId AS QualitySpecVersionId,
               @LocationId AS LocationId, @SampleTriggerCodeId AS SampleTriggerCodeId,
               LEFT(@ResultsJson, 2000) AS ResultsJson,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @QualitySpecVersionId IS NULL OR @ResultsJson IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, QualitySpecVersionId, ResultsJson, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                    @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. ResultsJson must be a JSON array ----
        IF ISJSON(@ResultsJson) <> 1
        BEGIN
            SET @Message = N'ResultsJson is not valid JSON.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. LOT exists (ANY status -- inspection of held lots is allowed) ----
        DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. Spec version exists + is Published (not Draft, not Deprecated) ----
        IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecVersion
                       WHERE Id = @QualitySpecVersionId
                         AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'QualitySpecVersion not found or not published (Draft/Deprecated versions cannot be inspected against).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. Optional FKs resolve ----
        IF @LocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @LocationId)
        BEGIN
            SET @Message = N'LocationId not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @SampleTriggerCodeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Quality.SampleTriggerCode WHERE Id = @SampleTriggerCodeId)
        BEGIN
            SET @Message = N'SampleTriggerCodeId not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6. Shred the JSON once ----
        DECLARE @Entries TABLE (
            QualitySpecAttributeId BIGINT        NULL,
            MeasuredValue          NVARCHAR(200) NULL
        );
        INSERT INTO @Entries (QualitySpecAttributeId, MeasuredValue)
        SELECT j.qualitySpecAttributeId, j.measuredValue
        FROM OPENJSON(@ResultsJson)
        WITH (qualitySpecAttributeId BIGINT        N'$.qualitySpecAttributeId',
              measuredValue          NVARCHAR(200) N'$.measuredValue') j;

        -- ---- 7. Every entry's attribute id must belong to THIS spec version ----
        DECLARE @BadAttrId BIGINT = (
            SELECT TOP 1 e.QualitySpecAttributeId
            FROM @Entries e
            WHERE e.QualitySpecAttributeId IS NULL
               OR NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute a
                              WHERE a.Id = e.QualitySpecAttributeId
                                AND a.QualitySpecVersionId = @QualitySpecVersionId));
        IF EXISTS (SELECT 1 FROM @Entries e
                   WHERE e.QualitySpecAttributeId IS NULL
                      OR NOT EXISTS (SELECT 1 FROM Quality.QualitySpecAttribute a
                                     WHERE a.Id = e.QualitySpecAttributeId
                                       AND a.QualitySpecVersionId = @QualitySpecVersionId))
        BEGIN
            SET @Message = N'ResultsJson contains attribute id '
                         + ISNULL(CAST(@BadAttrId AS NVARCHAR(20)), N'(null)')
                         + N' that does not belong to spec version '
                         + CAST(@QualitySpecVersionId AS NVARCHAR(20)) + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 8. Every IsRequired=1 attribute of the version must be present
        --         with a non-empty MeasuredValue ----
        DECLARE @MissingAttr NVARCHAR(100) = (
            SELECT TOP 1 a.AttributeName
            FROM Quality.QualitySpecAttribute a
            LEFT JOIN @Entries e ON e.QualitySpecAttributeId = a.Id
            WHERE a.QualitySpecVersionId = @QualitySpecVersionId
              AND a.IsRequired = 1
              AND (e.QualitySpecAttributeId IS NULL
                   OR e.MeasuredValue IS NULL
                   OR LTRIM(RTRIM(e.MeasuredValue)) = N'')
            ORDER BY a.SortOrder, a.Id);
        IF @MissingAttr IS NOT NULL
        BEGIN
            SET @Message = N'Required attribute ''' + @MissingAttr + N''' is missing or has an empty value.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 9. Compute per-attribute IsPass + NumericValue (pure computation,
        --         still before the transaction) ----
        DECLARE @Results TABLE (
            QualitySpecAttributeId BIGINT        NOT NULL,
            MeasuredValue          NVARCHAR(200) NULL,
            NumericValue           DECIMAL(18,4) NULL,
            IsPass                 BIT           NULL,
            IsRequired             BIT           NOT NULL
        );
        INSERT INTO @Results (QualitySpecAttributeId, MeasuredValue, NumericValue, IsPass, IsRequired)
        SELECT
            a.Id,
            e.MeasuredValue,
            CASE WHEN a.DataType = N'Numeric'
                 THEN TRY_CONVERT(DECIMAL(18,4), LTRIM(RTRIM(e.MeasuredValue))) END,
            CASE
                -- Numeric with at least one limit: range check
                WHEN a.DataType = N'Numeric' AND (a.LowerLimit IS NOT NULL OR a.UpperLimit IS NOT NULL) THEN
                    CASE
                        WHEN e.MeasuredValue IS NULL OR LTRIM(RTRIM(e.MeasuredValue)) = N'' THEN
                            CASE WHEN a.IsRequired = 1 THEN 0 ELSE NULL END
                        WHEN TRY_CONVERT(DECIMAL(18,4), LTRIM(RTRIM(e.MeasuredValue))) IS NULL THEN 0
                        WHEN (a.LowerLimit IS NULL OR TRY_CONVERT(DECIMAL(18,4), LTRIM(RTRIM(e.MeasuredValue))) >= a.LowerLimit)
                         AND (a.UpperLimit IS NULL OR TRY_CONVERT(DECIMAL(18,4), LTRIM(RTRIM(e.MeasuredValue))) <= a.UpperLimit) THEN 1
                        ELSE 0
                    END
                -- Non-numeric (or numeric without limits): presence check
                ELSE
                    CASE
                        WHEN e.MeasuredValue IS NOT NULL AND LTRIM(RTRIM(e.MeasuredValue)) <> N'' THEN 1
                        WHEN a.IsRequired = 1 THEN 0
                        ELSE NULL
                    END
            END,
            a.IsRequired
        FROM @Entries e
        INNER JOIN Quality.QualitySpecAttribute a ON a.Id = e.QualitySpecAttributeId;

        -- ---- 10. Overall rollup (FDS-08-011.3): Fail if any required attribute failed ----
        DECLARE @OverallCode NVARCHAR(20) =
            CASE WHEN EXISTS (SELECT 1 FROM @Results WHERE IsRequired = 1 AND IsPass = 0)
                 THEN N'Fail' ELSE N'Pass' END;
        DECLARE @InspectionResultCodeId BIGINT =
            (SELECT Id FROM Quality.InspectionResultCode WHERE Code = @OverallCode);
        DECLARE @TotalCount  INT = (SELECT COUNT(*) FROM @Results);
        DECLARE @PassedCount INT = (SELECT COUNT(*) FROM @Results WHERE IsPass = 1);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        INSERT INTO Quality.QualitySample (
            LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId,
            InspectionResultCodeId, SampledByUserId, SampledAt
        )
        VALUES (
            @LotId, @QualitySpecVersionId, @LocationId, @SampleTriggerCodeId,
            @InspectionResultCodeId, @AppUserId, SYSUTCDATETIME()
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        INSERT INTO Quality.QualityResult (QualitySampleId, QualitySpecAttributeId, MeasuredValue, NumericValue, IsPass)
        SELECT @NewId, r.QualitySpecAttributeId, r.MeasuredValue, r.NumericValue, r.IsPass
        FROM @Results r;

        -- ----- Audit (resolved-FK JSON + readable Description) -----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Inspection ' + Audit.ufn_MidDot()
            + N' ' + @OverallCode + N' (' + CAST(@PassedCount AS NVARCHAR(10))
            + N'/' + CAST(@TotalCount AS NVARCHAR(10)) + N' attributes)';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                qs.Id,
                ir.Code AS Result,
                @PassedCount AS PassedAttributes,
                @TotalCount  AS TotalAttributes,
                JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                            FROM Lots.Lot l WHERE l.Id = qs.LotId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                JSON_QUERY((SELECT v.Id, s.Name, v.VersionNumber
                            FROM Quality.QualitySpecVersion v
                            INNER JOIN Quality.QualitySpec s ON s.Id = v.QualitySpecId
                            WHERE v.Id = qs.QualitySpecVersionId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS SpecVersion
            FROM Quality.QualitySample qs
            INNER JOIN Quality.InspectionResultCode ir ON ir.Id = qs.InspectionResultCodeId
            WHERE qs.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @LocationId,
            @LogEntityTypeCode  = N'QualitySample',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'InspectionRecorded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        -- NO AUTO-HOLD (FDS-08-012): a Fail result is returned, never acted on here.
        SET @Status  = 1;
        SET @Message = N'Inspection recorded: ' + @OverallCode + N' ('
                     + CAST(@PassedCount AS NVARCHAR(10)) + N'/'
                     + CAST(@TotalCount AS NVARCHAR(10)) + N' attributes passed).';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'QualitySample',
                @EntityId = NULL, @LogEventTypeCode = N'InspectionRecorded',
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
