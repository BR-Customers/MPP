-- =============================================
-- Procedure:   Tools.ToolCavity_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-08
-- Version:     1.2
--
-- Description:
--   Bundled SaveAll for a Tool's cavities. Insert + update ONLY -- cavities
--   persist (no deprecate-on-absent; end-of-life via Scrapped status). On
--   existing rows CavityNumber is immutable. Status is freely editable in
--   BOTH directions, including back out of Scrapped -- see the change log for
--   why the one-way lock was removed. Audit: <Tool> . Cavities . ACTION.
--
-- Parameters: @ToolId BIGINT, @RowsJson NVARCHAR(MAX), @AppUserId BIGINT
--   RowsJson element: {Id, CavityNumber, Description, StatusCode, ItemId}
--   ItemId is OPTIONAL and NULLable -- the configured cavity-to-part map for
--   family dies (0072). Omit it or send null on a die whose cavities all cut
--   the same part; the part is then derived from the LOT as before.
-- Result set: Status (BIT), Message (NVARCHAR), NewId (echoes @ToolId).
--
-- Change Log:
--   2026-06-08 - 1.0 - Initial (eligibility-style config editors).
--   2026-09-09 - 1.1 - ItemId accepted, validated (must exist and not be
--                      deprecated in Parts.Item), persisted on insert+update,
--                      and carried in the audit narrative / Old+New JSON with
--                      the part number resolved per the audit convention.
--   2026-09-10 - 1.2 - Removed the one-way 'no transition OUT of Scrapped'
--                      lock. It assumed Scrapped is terminal, but the floor
--                      treats it as a working state: a cavity gets scrapped,
--                      the die goes out for repair, and it comes back
--                      producing. With no way back, the only recovery was a
--                      new cavity row -- which UQ_ToolCavity_ActiveToolCavity
--                      forbids on the same number -- or a hand-edit in SSMS.
--                      Deliberately replaced with NOTHING: no elevation, no
--                      confirmation. The audit trail already records who
--                      changed a cavity's status and when, which is the
--                      accountability that matters here.
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
        StatusCodeId BIGINT NULL,
        ItemId       BIGINT NULL
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

        INSERT INTO @Incoming (RowIndex, Id, CavityNumber, Description, StatusCode, ItemId)
        SELECT CAST([key] AS INT) + 1,
               TRY_CAST(JSON_VALUE([value], '$.Id') AS BIGINT),
               TRY_CAST(JSON_VALUE([value], '$.CavityNumber') AS INT),
               JSON_VALUE([value], '$.Description'),
               JSON_VALUE([value], '$.StatusCode'),
               TRY_CAST(JSON_VALUE([value], '$.ItemId') AS BIGINT)
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

        -- ItemId (0072) is optional; when supplied it must resolve to a live part.
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE i.ItemId IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM Parts.Item it
                              WHERE it.Id = i.ItemId AND it.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more rows reference a part that does not exist or is deprecated.';
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
            OldDesc NVARCHAR(500) NULL, NewDesc NVARCHAR(500) NULL,
            OldItem NVARCHAR(50) NULL, NewItem NVARCHAR(50) NULL
        );

        INSERT INTO @Changes (ChangeKind, SortKey, CavityNumber, NewStatus, NewDesc, NewItem)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY i.CavityNumber), i.CavityNumber, i.StatusCode, i.Description, nit.PartNumber
        FROM @Incoming i
        LEFT JOIN Parts.Item nit ON nit.Id = i.ItemId
        WHERE i.Id IS NULL;

        INSERT INTO @Changes (ChangeKind, SortKey, CavityNumber, OldStatus, NewStatus, OldDesc, NewDesc, OldItem, NewItem)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY c.CavityNumber), c.CavityNumber,
               oldsc.Code, i.StatusCode, c.Description, i.Description,
               oit.PartNumber, nit.PartNumber
        FROM @Incoming i
        INNER JOIN Tools.ToolCavity c ON c.Id = i.Id AND c.DeprecatedAt IS NULL
        INNER JOIN Tools.ToolCavityStatusCode oldsc ON oldsc.Id = c.StatusCodeId
        LEFT  JOIN Parts.Item oit ON oit.Id = c.ItemId
        LEFT  JOIN Parts.Item nit ON nit.Id = i.ItemId
        WHERE oldsc.Code <> i.StatusCode
           OR ISNULL(c.Description,N'') <> ISNULL(i.Description,N'')
           OR ISNULL(c.ItemId,-1) <> ISNULL(i.ItemId,-1);

        DECLARE @AddSpec NVARCHAR(MAX)=N'', @AddOv INT=0, @UpdSpec NVARCHAR(MAX)=N'', @UpdOv INT=0;
        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'+')
        SELECT @AddSpec = STRING_AGG(N'+#' + CAST(CavityNumber AS NVARCHAR) + N' (' + ISNULL(NewStatus,N'Active') + N')', N', ')
                          WITHIN GROUP (ORDER BY rn) FROM r WHERE rn <= 3;
        SELECT @AddOv = COUNT(*) - 3 FROM @Changes WHERE ChangeKind=N'+'; IF @AddOv<0 SET @AddOv=0;

        ;WITH r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) rn FROM @Changes WHERE ChangeKind=N'~')
        SELECT @UpdSpec = STRING_AGG(N'~#' + CAST(CavityNumber AS NVARCHAR) + N' ' +
                              CASE WHEN ISNULL(OldStatus,N'') <> ISNULL(NewStatus,N'')
                                   THEN ISNULL(OldStatus,N'null') + NCHAR(8594) + ISNULL(NewStatus,N'null')
                                   WHEN ISNULL(OldItem,N'') <> ISNULL(NewItem,N'')
                                   THEN N'part ' + ISNULL(OldItem,N'none') + NCHAR(8594) + ISNULL(NewItem,N'none')
                                   ELSE N'desc' END, N'; ')
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
            SELECT c.Id, c.CavityNumber, sc.Code AS Status, c.Description,
                   it.Id AS 'Item.Id', it.PartNumber AS 'Item.PartNumber'
            FROM Tools.ToolCavity c
            INNER JOIN Tools.ToolCavityStatusCode sc ON sc.Id = c.StatusCodeId
            LEFT  JOIN Parts.Item it ON it.Id = c.ItemId
            WHERE c.ToolId = @ToolId AND c.DeprecatedAt IS NULL
            ORDER BY c.CavityNumber FOR JSON PATH);
        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT i.Id, i.CavityNumber, i.StatusCode AS Status, i.Description,
                   it.Id AS 'Item.Id', it.PartNumber AS 'Item.PartNumber'
            FROM @Incoming i
            LEFT JOIN Parts.Item it ON it.Id = i.ItemId
            ORDER BY i.CavityNumber FOR JSON PATH);

        -- ===== Mutation (atomic) -- insert + update only =====
        BEGIN TRANSACTION;

        UPDATE c
        SET StatusCodeId = i.StatusCodeId, Description = i.Description, ItemId = i.ItemId,
            UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        FROM Tools.ToolCavity c INNER JOIN @Incoming i ON i.Id = c.Id
        WHERE c.ToolId = @ToolId AND c.DeprecatedAt IS NULL;

        INSERT INTO Tools.ToolCavity (ToolId, CavityNumber, StatusCodeId, Description, ItemId, CreatedAt, CreatedByUserId)
        SELECT @ToolId, i.CavityNumber, i.StatusCodeId, i.Description, i.ItemId, SYSUTCDATETIME(), @AppUserId
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
