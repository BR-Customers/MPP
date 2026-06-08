-- =============================================
-- Procedure:   Tools.ToolCavity_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-08
-- Version:     1.0
--
-- Description:
--   Bundled SaveAll for a Tool's cavities. Insert + update ONLY -- cavities
--   persist (no deprecate-on-absent; end-of-life via Scrapped status). On
--   existing rows CavityNumber is immutable and a row already Scrapped may
--   not transition to another status. Audit: <Tool> . Cavities . ACTION.
--
-- Parameters: @ToolId BIGINT, @RowsJson NVARCHAR(MAX), @AppUserId BIGINT
--   RowsJson element: {Id, CavityNumber, Description, StatusCode}
-- Result set: Status (BIT), Message (NVARCHAR), NewId (echoes @ToolId).
--
-- Change Log:
--   2026-06-08 - 1.0 - Initial (eligibility-style config editors).
-- =============================================
CREATE OR ALTER PROCEDURE Tools.ToolCavity_SaveAll
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

    DECLARE @ProcName NVARCHAR(200) = N'Tools.ToolCavity_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ToolId AS ToolId, JSON_QUERY(@RowsJson) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Incoming TABLE (
        RowIndex     INT PRIMARY KEY,
        Id           BIGINT NULL,
        CavityNumber INT NULL,
        Description  NVARCHAR(500) NULL,
        StatusCode   NVARCHAR(20) NULL,
        StatusCodeId BIGINT NULL
    );

    BEGIN TRY
        IF @ToolId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        DECLARE @HasCavities BIT;
        SELECT @HasCavities = tt.HasCavities
        FROM Tools.Tool t INNER JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
        WHERE t.Id = @ToolId AND t.DeprecatedAt IS NULL;

        IF @HasCavities IS NULL
        BEGIN
            SET @Message = N'Tool not found or deprecated.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END
        IF @HasCavities = 0
        BEGIN
            SET @Message = N'This Tool''s type does not support cavities.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        INSERT INTO @Incoming (RowIndex, Id, CavityNumber, Description, StatusCode)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT),
               TRY_CAST(JSON_VALUE([value], '$.CavityNumber') AS INT),
               JSON_VALUE([value], '$.Description'),
               JSON_VALUE([value], '$.StatusCode')
        FROM OPENJSON(ISNULL(@RowsJson, N'[]'));

        -- Resolve StatusCode -> StatusCodeId; default missing to 'Active'
        UPDATE i SET StatusCode = N'Active' FROM @Incoming i WHERE i.StatusCode IS NULL OR i.StatusCode = N'';
        UPDATE i SET StatusCodeId = sc.Id
        FROM @Incoming i INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Code = i.StatusCode;

        IF EXISTS (SELECT 1 FROM @Incoming WHERE StatusCodeId IS NULL)
        BEGIN
            SET @Message = N'One or more rows have an invalid cavity status.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT 1 FROM @Incoming WHERE CavityNumber IS NULL OR CavityNumber < 1)
        BEGIN
            SET @Message = N'CavityNumber must be >= 1 on every row.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        IF EXISTS (SELECT CavityNumber FROM @Incoming GROUP BY CavityNumber HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate cavity number in submitted rows.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Existing rows referenced by Id must belong to this tool (and be active)
        IF EXISTS (
            SELECT 1 FROM @Incoming i WHERE i.Id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM Tools.ToolCavity c WHERE c.Id = i.Id AND c.ToolId = @ToolId AND c.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more cavity rows do not belong to this tool.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- CavityNumber immutable on existing rows
        IF EXISTS (
            SELECT 1 FROM @Incoming i INNER JOIN Tools.ToolCavity c ON c.Id = i.Id
            WHERE i.Id IS NOT NULL AND c.CavityNumber <> i.CavityNumber)
        BEGIN
            SET @Message = N'Cavity number is immutable on existing cavities.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- No transition OUT of Scrapped
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            INNER JOIN Tools.ToolCavity c ON c.Id = i.Id
            INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
            WHERE i.Id IS NOT NULL AND sc.Code = N'Scrapped' AND i.StatusCode <> N'Scrapped')
        BEGIN
            SET @Message = N'A scrapped cavity cannot change status.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- New cavity number must not collide with an existing active cavity
        IF EXISTS (
            SELECT 1 FROM @Incoming i WHERE i.Id IS NULL
            AND EXISTS (SELECT 1 FROM Tools.ToolCavity c
                        WHERE c.ToolId = @ToolId AND c.CavityNumber = i.CavityNumber AND c.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'A cavity with this number already exists on the tool.';
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- ===== Audit narrative (PRE-mutation) =====
        DECLARE @ToolCode NVARCHAR(50), @ToolName NVARCHAR(200);
        SELECT @ToolCode = Code, @ToolName = Name FROM Tools.Tool WHERE Id = @ToolId;
        DECLARE @Subject NVARCHAR(600) =
            @ToolCode + CASE WHEN @ToolName IS NOT NULL THEN N' ' + NCHAR(8212) + N' ' + @ToolName ELSE N'' END;

        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1) NOT NULL, SortKey INT NOT NULL,
            CavityNumber INT NOT NULL,
            OldStatus NVARCHAR(20) NULL, NewStatus NVARCHAR(20) NULL,
            OldDesc NVARCHAR(500) NULL, NewDesc NVARCHAR(500) NULL
        );

        INSERT INTO @Changes (ChangeKind, SortKey, CavityNumber, NewStatus, NewDesc)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY i.CavityNumber), i.CavityNumber, i.StatusCode, i.Description
        FROM @Incoming i WHERE i.Id IS NULL;

        INSERT INTO @Changes (ChangeKind, SortKey, CavityNumber, OldStatus, NewStatus, OldDesc, NewDesc)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY c.CavityNumber), c.CavityNumber,
               oldsc.Code, i.StatusCode, c.Description, i.Description
        FROM @Incoming i
        INNER JOIN Tools.ToolCavity c ON c.Id = i.Id
        INNER JOIN Tools.ToolCavityStatusCode oldsc ON oldsc.Id = c.StatusCodeId
        WHERE oldsc.Code <> i.StatusCode OR ISNULL(c.Description,N'') <> ISNULL(i.Description,N'');

        DECLARE @AddSpec NVARCHAR(MAX)=N'', @AddOv INT=0, @UpdSpec NVARCHAR(MAX)=N'', @UpdOv INT=0;
        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'+')
        SELECT @AddSpec = STRING_AGG(N'+#' + CAST(CavityNumber AS NVARCHAR) + N' (' + ISNULL(NewStatus,N'Active') + N')', N', ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @AddOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'+'; IF @AddOv<0 SET @AddOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'~')
        SELECT @UpdSpec = STRING_AGG(N'~#' + CAST(CavityNumber AS NVARCHAR) + N' ' + ISNULL(OldStatus,N'null') + NCHAR(8594) + ISNULL(NewStatus,N'null'), N'; ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @UpdOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'~'; IF @UpdOv<0 SET @UpdOv=0;

        DECLARE @ActionParts NVARCHAR(MAX) = N'';
        IF NULLIF(@AddSpec,N'') IS NOT NULL
            SET @ActionParts += @AddSpec + CASE WHEN @AddOv>0 THEN N', +' + CAST(@AddOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF NULLIF(@UpdSpec,N'') IS NOT NULL
            SET @ActionParts += @UpdSpec + CASE WHEN @UpdOv>0 THEN N'; ~' + CAST(@UpdOv AS NVARCHAR) + N' more' ELSE N'' END + N'; ';
        IF DATALENGTH(@ActionParts) >= 4 SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts)/2 - 2);
        IF @ActionParts = N'' SET @ActionParts = N'No-op save';

        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @Subject + N' ' + Audit.ufn_MidDot() + N' Cavities ' + Audit.ufn_MidDot() +
            N' ' + @ActionParts + N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows');

        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT c.Id, c.CavityNumber, sc.Code AS Status, c.Description
            FROM Tools.ToolCavity c INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
            WHERE c.ToolId = @ToolId AND c.DeprecatedAt IS NULL
            ORDER BY c.CavityNumber FOR JSON PATH);
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT i.Id, i.CavityNumber, i.StatusCode AS Status, i.Description
            FROM @Incoming i ORDER BY i.CavityNumber FOR JSON PATH);

        -- ===== Mutation (atomic) -- insert + update only =====
        BEGIN TRANSACTION;

        UPDATE c
        SET StatusCodeId = i.StatusCodeId, Description = i.Description,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        FROM Tools.ToolCavity c INNER JOIN @Incoming i ON i.Id = c.Id
        WHERE c.ToolId = @ToolId AND c.DeprecatedAt IS NULL;

        INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, Description, CreatedAt, CreatedByUserId)
        SELECT @ToolId, i.CavityNumber, i.StatusCodeId, i.Description, SYSUTCDATETIME(), @AppUserId
        FROM @Incoming i WHERE i.Id IS NULL;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity',
            @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldValueResolved, @NewValue=@NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Cavities saved. ' + CAST(@TotalRows AS NVARCHAR(10)) + N' row(s) in payload.';
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
            EXEC Audit.Audit_LogFailure @AppUserId=@AppUserId, @LogEntityTypeCode=N'ToolCavity', @EntityId=@ToolId, @LogEventTypeCode=N'Updated', @FailureReason=@Message, @ProcedureName=@ProcName, @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
