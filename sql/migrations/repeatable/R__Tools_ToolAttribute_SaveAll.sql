-- =============================================
-- Procedure:   Tools.ToolAttribute_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-08
-- Version:     1.0
--
-- Description:
--   Bundled SaveAll for a Tool's attribute values. Reconciles the
--   desired-state JSON array against current ToolAttribute rows:
--     - Incoming Id matches existing row -> UPDATE Value
--     - Incoming Id = NULL                -> INSERT
--     - Existing row Id not in incoming   -> hard DELETE (no DeprecatedAt)
--   Validates each Value against its definition's DataType. Audit-readable
--   Description: <Tool> . Attributes . ACTION.
--
-- Parameters (input):
--   @ToolId    BIGINT        - Required.
--   @RowsJson  NVARCHAR(MAX) - [{Id, ToolAttributeDefinitionId, Value}]
--   @AppUserId BIGINT        - Required for audit.
--
-- Result set: Status (BIT), Message (NVARCHAR), NewId (BIGINT echoes @ToolId).
--
-- Change Log:
--   2026-06-08 - 1.0 - Initial (eligibility-style config editors).
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolAttribute_SaveAll
    @ToolId    BIGINT,
    @RowsJson  NVARCHAR(MAX),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @ToolId;

    DECLARE @ProcName NVARCHAR(200) = N'Tools.ToolAttribute_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ToolId AS ToolId, JSON_QUERY(@RowsJson) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Incoming TABLE (
        RowIndex                  INT PRIMARY KEY,
        Id                        BIGINT NULL,
        ToolAttributeDefinitionId BIGINT NULL,
        Value                     NVARCHAR(500) NULL
    );

    BEGIN TRY
        IF @ToolId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        DECLARE @ToolTypeId BIGINT;
        SELECT @ToolTypeId = ToolTypeId
        FROM Tools.Tool WHERE Id = @ToolId AND DeprecatedAt IS NULL;

        IF @ToolTypeId IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        INSERT INTO @Incoming (RowIndex, Id, ToolAttributeDefinitionId, Value)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id')                        AS BIGINT),
               TRY_CAST(JSON_VALUE([value], '$.ToolAttributeDefinitionId') AS BIGINT),
               JSON_VALUE([value], '$.Value')
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));

        -- Validation: definition id present
        IF EXISTS (SELECT 1 FROM @Incoming WHERE ToolAttributeDefinitionId IS NULL)
        BEGIN
            SET @Message = N'One or more rows are missing ToolAttributeDefinitionId.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: every definition belongs to this tool's type and is active
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE NOT EXISTS (
                SELECT 1 FROM Tools.ToolAttributeDefinition d
                WHERE d.Id = i.ToolAttributeDefinitionId
                  AND d.ToolTypeId = @ToolTypeId
                  AND d.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more attribute definitions are invalid for this tool type.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: no duplicate definition in the submitted set
        IF EXISTS (SELECT ToolAttributeDefinitionId FROM @Incoming
                   GROUP BY ToolAttributeDefinitionId HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate attribute in submitted rows.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: per-DataType value conformance (first offender names the field)
        DECLARE @BadField NVARCHAR(200) = NULL;
        DECLARE @BadType  NVARCHAR(20)  = NULL;
        SELECT TOP 1 @BadField = d.Name, @BadType = d.DataType
        FROM @Incoming i
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = i.ToolAttributeDefinitionId
        WHERE (d.DataType = N'Integer' AND TRY_CAST(i.Value AS INT)            IS NULL)
           OR (d.DataType = N'Decimal' AND TRY_CAST(i.Value AS DECIMAL(38,10)) IS NULL)
           OR (d.DataType = N'Date'    AND TRY_CAST(i.Value AS DATE)           IS NULL)
           OR (d.DataType = N'Boolean' AND i.Value NOT IN (N'true', N'false'))
           OR (d.DataType = N'String'  AND i.Value IS NULL)
        ORDER BY i.RowIndex;

        IF @BadField IS NOT NULL
        BEGIN
            SET @Message = N'Value for "' + @BadField + N'" is not a valid ' + @BadType + N'.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- ===== Audit narrative (built from PRE-mutation state) =====
        DECLARE @ToolCode NVARCHAR(50), @ToolName NVARCHAR(200);
        SELECT @ToolCode = Code, @ToolName = Name FROM Tools.Tool WHERE Id = @ToolId;
        DECLARE @Subject NVARCHAR(600) =
            @ToolCode + CASE WHEN @ToolName IS NOT NULL
                             THEN N' ' + NCHAR(8212) + N' ' + @ToolName ELSE N'' END;

        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1) NOT NULL, SortKey INT NOT NULL,
            DefCode NVARCHAR(50) NOT NULL,
            OldValue NVARCHAR(500) NULL, NewValue NVARCHAR(500) NULL
        );

        INSERT INTO @Changes (ChangeKind, SortKey, DefCode, NewValue)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY d.Code), d.Code, i.Value
        FROM @Incoming i
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = i.ToolAttributeDefinitionId
        WHERE i.Id IS NULL;

        INSERT INTO @Changes (ChangeKind, SortKey, DefCode, OldValue, NewValue)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY d.Code), d.Code, ta.Value, i.Value
        FROM @Incoming i
        INNER JOIN Tools.ToolAttribute ta ON ta.Id = i.Id AND ta.ToolId = @ToolId
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = ta.ToolAttributeDefinitionId
        WHERE ISNULL(ta.Value, N'') <> ISNULL(i.Value, N'');

        INSERT INTO @Changes (ChangeKind, SortKey, DefCode, OldValue)
        SELECT N'-', ROW_NUMBER() OVER (ORDER BY d.Code), d.Code, ta.Value
        FROM Tools.ToolAttribute ta
        INNER JOIN Tools.ToolAttributeDefinition d ON d.Id = ta.ToolAttributeDefinitionId
        WHERE ta.ToolId = @ToolId
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = ta.Id);

        DECLARE @AddSpec NVARCHAR(MAX) = N'', @AddOv INT = 0;
        DECLARE @UpdSpec NVARCHAR(MAX) = N'', @UpdOv INT = 0;
        DECLARE @RemSpec NVARCHAR(MAX) = N'', @RemOv INT = 0;
        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'+')
        SELECT @AddSpec = STRING_AGG(N'+' + DefCode + N'=' + ISNULL(NewValue,N''), N', ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @AddOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'+'; IF @AddOv<0 SET @AddOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'~')
        SELECT @UpdSpec = STRING_AGG(N'~' + DefCode + N' ' + ISNULL(OldValue,N'null')
                              + NCHAR(8594) + ISNULL(NewValue,N'null'), N'; ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @UpdOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'~'; IF @UpdOv<0 SET @UpdOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'-')
        SELECT @RemSpec = STRING_AGG(N'-' + DefCode, N', ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @RemOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'-'; IF @RemOv<0 SET @RemOv=0;

        DECLARE @ActionParts NVARCHAR(MAX) = N'';
        IF NULLIF(@AddSpec,N'') IS NOT NULL
            SET @ActionParts += @AddSpec + CASE WHEN @AddOv>0 THEN N', +' + CAST(@AddOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@UpdSpec,N'') IS NOT NULL
            SET @ActionParts += @UpdSpec + CASE WHEN @UpdOv>0 THEN N'; ~' + CAST(@UpdOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@RemSpec,N'') IS NOT NULL
            SET @ActionParts += @RemSpec + CASE WHEN @RemOv>0 THEN N', -' + CAST(@RemOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF DATALENGTH(@ActionParts) >= 4 SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts)/2 - 2);
        IF @ActionParts = N'' SET @ActionParts = N'No-op save';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Attributes ' + Audit.ufn_MidDot() +
            N' ' + @ActionParts + N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows');

        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT ta.Id,
                   JSON_QUERY((SELECT d.Id, d.Code, d.Name
                               FROM Tools.ToolAttributeDefinition d
                               WHERE d.Id = ta.ToolAttributeDefinitionId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Definition,
                   ta.Value
            FROM Tools.ToolAttribute ta
            WHERE ta.ToolId = @ToolId
            ORDER BY ta.ToolAttributeDefinitionId
            FOR JSON PATH);

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT i.Id,
                   JSON_QUERY((SELECT d.Id, d.Code, d.Name
                               FROM Tools.ToolAttributeDefinition d
                               WHERE d.Id = i.ToolAttributeDefinitionId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Definition,
                   i.Value
            FROM @Incoming i
            ORDER BY i.ToolAttributeDefinitionId
            FOR JSON PATH);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        DELETE ta
        FROM Tools.ToolAttribute ta
        WHERE ta.ToolId = @ToolId
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = ta.Id);

        UPDATE ta
        SET Value = i.Value, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        FROM Tools.ToolAttribute ta
        INNER JOIN @Incoming i ON i.Id = ta.Id
        WHERE ta.ToolId = @ToolId;

        INSERT INTO Tools.ToolAttribute (ToolId, ToolAttributeDefinitionId, Value, UpdatedAt, UpdatedByUserId)
        SELECT @ToolId, i.ToolAttributeDefinitionId, i.Value, SYSUTCDATETIME(), @AppUserId
        FROM @Incoming i
        WHERE i.Id IS NULL;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
            @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldValueResolved, @NewValue=@NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Attributes saved. ' + CAST(@TotalRows AS NVARCHAR(10)) + N' row(s) in payload.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolAttribute',
                @EntityId=@ToolId, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
