-- =============================================
-- Procedure:   Parts.OperationTemplateField_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-08
-- Version:     1.0
--
-- Description:
--   Bundled SaveAll for an OperationTemplate's data-collection fields.
--   Reconciles desired-state JSON against active junction rows:
--     - Id matches active row        -> UPDATE IsRequired
--     - Id = NULL, no pairing         -> INSERT
--     - Id = NULL, deprecated pairing -> REACTIVATE (most-recent only)
--     - Id = NULL, active pairing      -> reject (edit the row by Id instead)
--     - Active row not in incoming    -> DEPRECATE
--   Audit: <Template Code vN - Name> . Fields . ACTION.
--
-- Parameters: @OperationTemplateId BIGINT, @RowsJson NVARCHAR(MAX), @AppUserId BIGINT
--   RowsJson element: {Id, DataCollectionFieldId, IsRequired}
-- Result set: Status (BIT), Message (NVARCHAR), NewId (echoes @OperationTemplateId).
--
-- Change Log:
--   2026-06-08 - 1.0 - Initial (eligibility-style config editors).
-- =============================================
CREATE OR ALTER PROCEDURE Parts.OperationTemplateField_SaveAll
    @OperationTemplateId BIGINT,
    @RowsJson            NVARCHAR(MAX),
    @AppUserId           BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = @OperationTemplateId;

    DECLARE @ProcName NVARCHAR(200) = N'Parts.OperationTemplateField_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @OperationTemplateId AS OperationTemplateId, JSON_QUERY(@RowsJson) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Incoming TABLE (
        RowIndex              INT PRIMARY KEY,
        Id                    BIGINT NULL,
        DataCollectionFieldId BIGINT NULL,
        IsRequired            BIT NULL
    );

    BEGIN TRY
        IF @OperationTemplateId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Operation template not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        INSERT INTO @Incoming (RowIndex, Id, DataCollectionFieldId, IsRequired)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT),
               TRY_CAST(JSON_VALUE([value], '$.DataCollectionFieldId') AS BIGINT),
               COALESCE(TRY_CAST(JSON_VALUE([value], '$.IsRequired') AS BIT), 1)
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));

        IF EXISTS (SELECT 1 FROM @Incoming WHERE DataCollectionFieldId IS NULL)
        BEGIN
            SET @Message = N'One or more rows are missing DataCollectionFieldId.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT 1 FROM @Incoming i WHERE NOT EXISTS (
            SELECT 1 FROM Parts.DataCollectionField f WHERE f.Id = i.DataCollectionFieldId AND f.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more data collection fields are invalid or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT DataCollectionFieldId FROM @Incoming GROUP BY DataCollectionFieldId HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate field in submitted rows.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Reject an Id=NULL incoming row whose field is already actively attached.
        -- To change an existing field, edit its row (which carries its Id).
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE i.Id IS NULL
              AND EXISTS (SELECT 1 FROM Parts.OperationTemplateField j
                          WHERE j.OperationTemplateId = @OperationTemplateId
                            AND j.DataCollectionFieldId = i.DataCollectionFieldId
                            AND j.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'Field already attached to this template.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- ===== Audit narrative (PRE-mutation) =====
        DECLARE @TCode NVARCHAR(50), @TVer INT, @TName NVARCHAR(200);
        SELECT @TCode = Code, @TVer = VersionNumber, @TName = Name
        FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId;
        DECLARE @Subject NVARCHAR(600) =
            @TCode + N' v' + CAST(@TVer AS NVARCHAR(10))
            + CASE WHEN @TName IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @TName ELSE N'' END;

        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1) NOT NULL, SortKey INT NOT NULL,
            FieldCode NVARCHAR(50) NOT NULL,
            OldRequired BIT NULL, NewRequired BIT NULL
        );

        -- ADDS (Id NULL, no existing pairing)
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, NewRequired)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, i.IsRequired
        FROM @Incoming i INNER JOIN Parts.DataCollectionField f ON f.Id = i.DataCollectionFieldId
        WHERE i.Id IS NULL
          AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField j
                          WHERE j.OperationTemplateId = @OperationTemplateId AND j.DataCollectionFieldId = i.DataCollectionFieldId);
        -- ADDS via reactivation render as + too (only the most-recent deprecated row, matching FIX 1)
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, NewRequired)
        SELECT N'+', 100 + ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, i.IsRequired
        FROM @Incoming i
        INNER JOIN Parts.OperationTemplateField j
            ON j.OperationTemplateId = @OperationTemplateId AND j.DataCollectionFieldId = i.DataCollectionFieldId AND j.DeprecatedAt IS NOT NULL
        INNER JOIN Parts.DataCollectionField f ON f.Id = i.DataCollectionFieldId
        WHERE i.Id IS NULL
          AND j.Id = (SELECT MAX(j2.Id) FROM Parts.OperationTemplateField j2
                      WHERE j2.OperationTemplateId = @OperationTemplateId
                        AND j2.DataCollectionFieldId = j.DataCollectionFieldId
                        AND j2.DeprecatedAt IS NOT NULL);

        -- UPDATES (Id matched, IsRequired differs)
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, OldRequired, NewRequired)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, j.IsRequired, i.IsRequired
        FROM @Incoming i
        INNER JOIN Parts.OperationTemplateField j ON j.Id = i.Id AND j.OperationTemplateId = @OperationTemplateId
        INNER JOIN Parts.DataCollectionField f ON f.Id = j.DataCollectionFieldId
        WHERE j.DeprecatedAt IS NULL AND j.IsRequired <> i.IsRequired;

        -- REMOVES (active row not in incoming)
        INSERT INTO @Changes (ChangeKind, SortKey, FieldCode, OldRequired)
        SELECT N'-', ROW_NUMBER() OVER (ORDER BY f.Code), f.Code, j.IsRequired
        FROM Parts.OperationTemplateField j INNER JOIN Parts.DataCollectionField f ON f.Id = j.DataCollectionFieldId
        WHERE j.OperationTemplateId = @OperationTemplateId AND j.DeprecatedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = j.Id);

        DECLARE @AddSpec NVARCHAR(MAX)=N'', @AddOv INT=0, @UpdSpec NVARCHAR(MAX)=N'', @UpdOv INT=0, @RemSpec NVARCHAR(MAX)=N'', @RemOv INT=0;
        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'+')
        SELECT @AddSpec = STRING_AGG(N'+' + FieldCode, N', ') WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @AddOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'+'; IF @AddOv<0 SET @AddOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'~')
        SELECT @UpdSpec = STRING_AGG(N'~' + FieldCode + N' IsRequired '
                              + CASE WHEN OldRequired=1 THEN N'true' ELSE N'false' END + NCHAR(8594)
                              + CASE WHEN NewRequired=1 THEN N'true' ELSE N'false' END, N'; ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @UpdOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'~'; IF @UpdOv<0 SET @UpdOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'-')
        SELECT @RemSpec = STRING_AGG(N'-' + FieldCode, N', ') WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
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
            @Subject + N' ' + Audit.ufn_MidDot() + N' Fields ' + Audit.ufn_MidDot() +
            N' ' + @ActionParts + N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows');

        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT j.Id,
                   JSON_QUERY((SELECT f.Id, f.Code, f.Name FROM Parts.DataCollectionField f
                               WHERE f.Id = j.DataCollectionFieldId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Field,
                   j.IsRequired
            FROM Parts.OperationTemplateField j
            WHERE j.OperationTemplateId = @OperationTemplateId AND j.DeprecatedAt IS NULL
            ORDER BY j.DataCollectionFieldId FOR JSON PATH);
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT i.Id,
                   JSON_QUERY((SELECT f.Id, f.Code, f.Name FROM Parts.DataCollectionField f
                               WHERE f.Id = i.DataCollectionFieldId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Field,
                   i.IsRequired
            FROM @Incoming i ORDER BY i.DataCollectionFieldId FOR JSON PATH);

        -- ===== Mutation (atomic, 4-step) =====
        BEGIN TRANSACTION;

        UPDATE Parts.OperationTemplateField
        SET DeprecatedAt = SYSUTCDATETIME()
        WHERE OperationTemplateId = @OperationTemplateId AND DeprecatedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = Parts.OperationTemplateField.Id);

        UPDATE j SET IsRequired = i.IsRequired
        FROM Parts.OperationTemplateField j INNER JOIN @Incoming i ON i.Id = j.Id
        WHERE j.OperationTemplateId = @OperationTemplateId AND j.DeprecatedAt IS NULL;

        UPDATE j SET DeprecatedAt = NULL, IsRequired = i.IsRequired
        FROM Parts.OperationTemplateField j
        INNER JOIN @Incoming i ON i.Id IS NULL AND i.DataCollectionFieldId = j.DataCollectionFieldId
        WHERE j.OperationTemplateId = @OperationTemplateId
          AND j.DeprecatedAt IS NOT NULL
          AND j.Id = (SELECT MAX(j2.Id) FROM Parts.OperationTemplateField j2
                      WHERE j2.OperationTemplateId = @OperationTemplateId
                        AND j2.DataCollectionFieldId = j.DataCollectionFieldId
                        AND j2.DeprecatedAt IS NOT NULL);

        INSERT INTO Parts.OperationTemplateField (OperationTemplateId, DataCollectionFieldId, IsRequired, CreatedAt)
        SELECT @OperationTemplateId, i.DataCollectionFieldId, i.IsRequired, SYSUTCDATETIME()
        FROM @Incoming i
        WHERE i.Id IS NULL
          AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplateField j
                          WHERE j.OperationTemplateId = @OperationTemplateId AND j.DataCollectionFieldId = i.DataCollectionFieldId);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField',
            @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldValueResolved, @NewValue=@NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Fields saved. ' + CAST(@TotalRows AS NVARCHAR(10)) + N' row(s) in payload.';
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
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'OpTemplateField', @EntityId=@OperationTemplateId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
