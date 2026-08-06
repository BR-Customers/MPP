-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_BulkLoadFromSeed
-- Author:      Blue Ridge Automation
-- Created:     2026-04-15
-- Version:     1.0
--
-- Description:
--   One-time (idempotent) bulk loader for the 353-row
--   downtime_reason_codes.csv seed data. The caller (Perspective
--   bulk-load screen or deployment engineer) converts the CSV to a
--   JSON array and supplies it along with the three Area-location Ids
--   that map to the DeptCode values DC, MS, TS.
--
--   Per-row Code is generated from DeptCode + zero-padded ReasonId:
--     DeptCode + '-' + RIGHT('0000' + CAST(ReasonId AS NVARCHAR), 4)
--     e.g. {"ReasonId":3, "DeptCode":"DC"} => Code 'DC-0003'.
--
--   Rows with:
--     - Unknown DeptCode (not DC/MS/TS)
--     - Missing ReasonId / ReasonDesc / DeptCode
--   are rejected and returned in RejectedRowsJson. Rows whose generated
--   Code already exists are skipped (idempotent re-run).
--
--   Rows with missing / unknown TypeId are still inserted — with
--   DowntimeReasonTypeId = NULL — and engineering backfills the type
--   via _Update before go-live (Phase 8 Q-B decision).
--
--   DowntimeSourceCodeId is always NULL on initial load; the CSV
--   carries no source column (Phase 8 Q-3 decision).
--
-- Expected JSON row shape:
--   [{"ReasonId":1, "ReasonDesc":"Scheduled Downtime",
--     "DeptCode":"DC", "TypeId":6, "Excused":0}, ...]
--
-- Parameters (input):
--   @RowsJson NVARCHAR(MAX) - JSON array of CSV rows. Required.
--   @DcOperationCategoryId BIGINT - Area Location.Id for DeptCode 'DC'. Required.
--   @MsOperationCategoryId BIGINT - Area Location.Id for DeptCode 'MS'. Required.
--   @TsOperationCategoryId BIGINT - Area Location.Id for DeptCode 'TS'. Required.
--   @AppUserId BIGINT - User performing the load. Required for audit.
--
-- Result set:
--   Single row:
--     Status BIT              - 1 on success (even if some rows rejected), 0 on pre-flight failure.
--     Message NVARCHAR(500)   - Human-readable summary.
--     InsertedCount INT       - Rows actually inserted.
--     SkippedCount  INT       - Rows whose Code already existed (idempotent re-run).
--     RejectedCount INT       - Rows rejected due to unknown DeptCode or missing required fields.
--     RejectedRowsJson NVARCHAR(MAX) - Rejected rows with per-row RejectionReason.
--
-- Dependencies:
--   Tables: Oee.DowntimeReasonCode, Oee.DowntimeReasonType,
--           Location.Location, Location.AppUser
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Change Log:
--   2026-04-15 - 1.0 - Initial version
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_BulkLoadFromSeed
    @RowsJson           NVARCHAR(MAX),
    @DcOperationCategoryId   BIGINT,
    @MsOperationCategoryId   BIGINT,
    @TsOperationCategoryId   BIGINT,
    @AppUserId          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status            BIT           = 0;
    DECLARE @Message           NVARCHAR(500) = N'Unknown error';
    DECLARE @InsertedCount     INT           = 0;
    DECLARE @SkippedCount      INT           = 0;
    DECLARE @RejectedCount     INT           = 0;
    DECLARE @RejectedRowsJson  NVARCHAR(MAX) = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.DowntimeReasonCode_BulkLoadFromSeed';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @DcOperationCategoryId AS DcOperationCategoryId,
                @MsOperationCategoryId AS MsOperationCategoryId,
                @TsOperationCategoryId AS TsOperationCategoryId,
                ISNULL(LEN(@RowsJson), 0) AS RowsJsonLength
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @RowsJson IS NULL OR @AppUserId IS NULL
           OR @DcOperationCategoryId IS NULL OR @MsOperationCategoryId IS NULL OR @TsOperationCategoryId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   @InsertedCount AS InsertedCount, @SkippedCount AS SkippedCount,
                   @RejectedCount AS RejectedCount, @RejectedRowsJson AS RejectedRowsJson;
            RETURN;
        END

        IF ISJSON(@RowsJson) = 0
        BEGIN
            SET @Message = N'RowsJson is not valid JSON.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   @InsertedCount AS InsertedCount, @SkippedCount AS SkippedCount,
                   @RejectedCount AS RejectedCount, @RejectedRowsJson AS RejectedRowsJson;
            RETURN;
        END

        -- ====================
        -- FK existence checks for the three area mappings
        -- ====================
        IF NOT EXISTS (SELECT 1 FROM Parts.OperationCategory
                       WHERE Id = @DcOperationCategoryId AND DeprecatedAt IS NULL)
           OR NOT EXISTS (SELECT 1 FROM Parts.OperationCategory
                          WHERE Id = @MsOperationCategoryId AND DeprecatedAt IS NULL)
           OR NOT EXISTS (SELECT 1 FROM Parts.OperationCategory
                          WHERE Id = @TsOperationCategoryId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'One or more OperationCategory Ids are invalid or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   @InsertedCount AS InsertedCount, @SkippedCount AS SkippedCount,
                   @RejectedCount AS RejectedCount, @RejectedRowsJson AS RejectedRowsJson;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'Invalid AppUserId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'DowntimeReasonCode',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message,
                   @InsertedCount AS InsertedCount, @SkippedCount AS SkippedCount,
                   @RejectedCount AS RejectedCount, @RejectedRowsJson AS RejectedRowsJson;
            RETURN;
        END

        -- ====================
        -- Stage JSON into a working temp table
        -- ====================
        CREATE TABLE #Staging (
            RowIndex        INT            NOT NULL,
            ReasonId        INT            NULL,
            ReasonDesc      NVARCHAR(500)  NULL,
            DeptCode        NVARCHAR(10)   NULL,
            TypeId          INT            NULL,
            Excused         BIT            NULL,
            GeneratedCode   NVARCHAR(20)   NULL,
            OperationCategoryId  BIGINT         NULL,
            IsValid         BIT            NOT NULL DEFAULT 0,
            RejectionReason NVARCHAR(200)  NULL
        );

        INSERT INTO #Staging (RowIndex, ReasonId, ReasonDesc, DeptCode, TypeId, Excused)
        SELECT [key] AS RowIndex,
               TRY_CAST(JSON_VALUE(value, '$.ReasonId')   AS INT),
               JSON_VALUE(value, '$.ReasonDesc'),
               UPPER(LTRIM(RTRIM(JSON_VALUE(value, '$.DeptCode')))),
               TRY_CAST(JSON_VALUE(value, '$.TypeId')     AS INT),
               ISNULL(TRY_CAST(JSON_VALUE(value, '$.Excused') AS BIT), 0)
        FROM OPENJSON(@RowsJson);

        -- ====================
        -- Classify rows: valid / rejected
        -- ====================
        UPDATE #Staging
        SET RejectionReason = CASE
                WHEN ReasonId   IS NULL                 THEN N'Missing or non-integer ReasonId'
                WHEN ReasonDesc IS NULL
                  OR LTRIM(RTRIM(ReasonDesc)) = N''     THEN N'Missing ReasonDesc'
                WHEN DeptCode   IS NULL                 THEN N'Missing DeptCode'
                WHEN DeptCode NOT IN (N'DC', N'MS', N'TS') THEN N'Unknown DeptCode (expected DC, MS, or TS)'
                ELSE NULL
            END
        WHERE IsValid = 0;

        UPDATE #Staging SET IsValid = 1 WHERE RejectionReason IS NULL;

        -- Resolve OperationCategoryId + GeneratedCode on valid rows
        UPDATE #Staging
        SET OperationCategoryId = CASE DeptCode
                                WHEN N'DC' THEN @DcOperationCategoryId
                                WHEN N'MS' THEN @MsOperationCategoryId
                                WHEN N'TS' THEN @TsOperationCategoryId
                             END,
            GeneratedCode  = DeptCode + N'-' + RIGHT(N'0000' + CAST(ReasonId AS NVARCHAR(10)), 4)
        WHERE IsValid = 1;

        -- Null out TypeId references that don't resolve to a seeded type row
        -- (CSV rows with missing TypeDesc / out-of-range TypeId)
        UPDATE s
        SET s.TypeId = NULL
        FROM #Staging s
        WHERE s.IsValid = 1
          AND s.TypeId IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonType t WHERE t.Id = s.TypeId);

        -- ====================
        -- Compute skipped count BEFORE insert (idempotent-rerun path)
        -- ====================
        SELECT @SkippedCount = COUNT(*)
        FROM #Staging s
        WHERE s.IsValid = 1
          AND EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode d
                      WHERE d.Code = s.GeneratedCode);

        -- ====================
        -- Atomic insert of valid, non-duplicate rows
        -- ====================
        BEGIN TRANSACTION;

        INSERT INTO Oee.DowntimeReasonCode
            (Code, Description, OperationCategoryId, DowntimeReasonTypeId,
             DowntimeSourceCodeId, IsExcused, CreatedAt, CreatedByUserId)
        SELECT s.GeneratedCode, LTRIM(RTRIM(s.ReasonDesc)), s.OperationCategoryId, s.TypeId,
               NULL, ISNULL(s.Excused, 0), SYSUTCDATETIME(), @AppUserId
        FROM #Staging s
        WHERE s.IsValid = 1
          AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode d
                          WHERE d.Code = s.GeneratedCode);

        SET @InsertedCount = @@ROWCOUNT;

        -- Build rejected-rows payload for the caller
        SELECT @RejectedCount = COUNT(*) FROM #Staging WHERE IsValid = 0;

        IF @RejectedCount > 0
        BEGIN
            SET @RejectedRowsJson =
                (SELECT RowIndex, ReasonId, ReasonDesc, DeptCode, RejectionReason
                 FROM #Staging
                 WHERE IsValid = 0
                 FOR JSON PATH);
        END

        -- Summary audit entry — one row, not 353
        SET @Message = N'Bulk load complete: ' + CAST(@InsertedCount AS NVARCHAR(10))
                    + N' inserted, ' + CAST(@SkippedCount AS NVARCHAR(10))
                    + N' skipped, ' + CAST(@RejectedCount AS NVARCHAR(10)) + N' rejected.';

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'DowntimeReasonCode',
            @EntityId          = NULL,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = N'Bulk load from seed CSV.',
            @OldValue          = NULL,
            @NewValue          = @Message;

        COMMIT TRANSACTION;

        DROP TABLE #Staging;

        SET @Status = 1;
        SELECT @Status AS Status, @Message AS Message,
               @InsertedCount AS InsertedCount, @SkippedCount AS SkippedCount,
               @RejectedCount AS RejectedCount, @RejectedRowsJson AS RejectedRowsJson;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#Staging') IS NOT NULL
            DROP TABLE #Staging;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @InsertedCount = 0;
        SET @SkippedCount  = 0;
        SET @RejectedCount = 0;
        SET @RejectedRowsJson = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'DowntimeReasonCode',
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message,
               @InsertedCount AS InsertedCount, @SkippedCount AS SkippedCount,
               @RejectedCount AS RejectedCount, @RejectedRowsJson AS RejectedRowsJson;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
