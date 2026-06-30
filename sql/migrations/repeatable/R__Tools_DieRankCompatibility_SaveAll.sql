-- =============================================
-- Procedure:   Tools.DieRankCompatibility_SaveAll
-- Author:      Blue Ridge Automation
-- Created:     2026-06-22
-- Version:     1.0
--
-- Description:
--   Bundled SaveAll for the cross-rank merge-compatibility matrix.
--   Takes a JSON array of rank pairs and reconciles them against
--   Tools.DieRankCompatibility in ONE transaction with ONE audit entry,
--   so the Die Ranks admin popup can persist a multi-cell edit on a
--   single Save click.
--
--   Reconciliation model: UPSERT-ONLY (never delete).
--     - canonical pair exists -> UPDATE CanMix (only when it differs)
--     - canonical pair absent  -> INSERT
--     - existing rows not in the payload -> left untouched
--   CanMix is stored exactly as sent (including 0). Omitting a pair does
--   NOT clear it; a pair changes only by being present in the payload.
--
--   Every pair is canonicalised to (smaller Id, larger Id) so (A, B) and
--   (B, A) resolve to the same stored row (CK_DieRankCompatibility_Canonical
--   enforces RankAId <= RankBId at the storage level).
--
-- Parameters (input):
--   @RowsJson  NVARCHAR(MAX) - [{ "RankAId": <bigint>, "RankBId": <bigint>, "CanMix": <0|1> }, ...]
--   @AppUserId BIGINT        - Required for audit.
--
-- Result set: Status (BIT), Message (NVARCHAR), NewId (BIGINT = row count in payload).
--
-- FDS-11-011: no OUTPUT params; single SELECT @Status,@Message,@NewId on
-- every exit path. All rejecting validations run BEFORE BEGIN TRANSACTION
-- (proc returns a status row and may be captured via INSERT-EXEC, so a
-- ROLLBACK outside CATCH would throw Msg 3915).
--
-- Change Log:
--   2026-06-22 - 1.0 - Initial (die rank compatibility matrix SaveAll).
-- =============================================
CREATE OR ALTER PROCEDURE Tools.DieRankCompatibility_SaveAll
    @RowsJson  NVARCHAR(MAX),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = 0;

    DECLARE @ProcName NVARCHAR(200) = N'Tools.DieRankCompatibility_SaveAll';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT JSON_QUERY(ISNULL(@RowsJson, N'[]')) AS Rows
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Canonicalised desired-state rows (LoId <= HiId).
    DECLARE @Incoming TABLE (
        RowIndex INT PRIMARY KEY,
        LoId     BIGINT NULL,
        HiId     BIGINT NULL,
        CanMix   BIT    NULL
    );

    BEGIN TRY
        IF @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'DieRankCompatibility',
                @EntityId=NULL, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Parse + canonicalise. NULL RankAId/RankBId collapses to a NULL
        -- Lo or Hi (caught below). CanMix accepts 0/1 or true/false.
        INSERT INTO @Incoming (RowIndex, LoId, HiId, CanMix)
        SELECT RowIndex,
               CASE WHEN RawA <= RawB THEN RawA ELSE RawB END,
               CASE WHEN RawA <= RawB THEN RawB ELSE RawA END,
               CanMix
        FROM (
            SELECT CAST([key] AS INT) + 1 AS RowIndex,
                   TRY_CAST(JSON_VALUE([value], '$.RankAId') AS BIGINT) AS RawA,
                   TRY_CAST(JSON_VALUE([value], '$.RankBId') AS BIGINT) AS RawB,
                   CASE WHEN JSON_VALUE([value], '$.CanMix') IN (N'1', N'true')  THEN 1
                        WHEN JSON_VALUE([value], '$.CanMix') IN (N'0', N'false') THEN 0
                        ELSE NULL END                                   AS CanMix
            FROM OPENJSON(ISNULL(@RowsJson, N'[]'))
        ) src;

        DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @Incoming);
        SET @NewId = @TotalRows;

        -- Validation: each row has both rank Ids and a valid CanMix
        IF EXISTS (SELECT 1 FROM @Incoming
                   WHERE LoId IS NULL OR HiId IS NULL OR CanMix IS NULL)
        BEGIN
            SET @Message = N'One or more rows are missing RankAId, RankBId, or a valid CanMix.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'DieRankCompatibility',
                @EntityId=NULL, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: no duplicate canonical pair within the payload
        IF EXISTS (SELECT 1 FROM @Incoming GROUP BY LoId, HiId HAVING COUNT(*) > 1)
        BEGIN
            SET @Message = N'Duplicate rank pair in submitted rows.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'DieRankCompatibility',
                @EntityId=NULL, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- Validation: every referenced rank exists and is active
        IF EXISTS (
            SELECT 1 FROM @Incoming i
            WHERE NOT EXISTS (SELECT 1 FROM Tools.DieRank r
                              WHERE r.Id = i.LoId AND r.DeprecatedAt IS NULL)
               OR NOT EXISTS (SELECT 1 FROM Tools.DieRank r
                              WHERE r.Id = i.HiId AND r.DeprecatedAt IS NULL))
        BEGIN
            SET @Message = N'One or more rank Ids are invalid or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'DieRankCompatibility',
                @EntityId=NULL, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId; RETURN;
        END

        -- ===== Audit narrative (built from PRE-mutation state) =====
        DECLARE @Changes TABLE (
            ChangeKind NCHAR(1)      NOT NULL,
            SortKey    INT           NOT NULL,
            PairLabel  NVARCHAR(100) NOT NULL,
            OldCanMix  BIT           NULL,
            NewCanMix  BIT           NULL
        );

        -- '+' : pair not yet stored (will INSERT)
        INSERT INTO @Changes (ChangeKind, SortKey, PairLabel, NewCanMix)
        SELECT N'+', ROW_NUMBER() OVER (ORDER BY rA.SortOrder, rB.SortOrder),
               rA.Code + NCHAR(215) + rB.Code, i.CanMix
        FROM @Incoming i
        INNER JOIN Tools.DieRank rA ON rA.Id = i.LoId
        INNER JOIN Tools.DieRank rB ON rB.Id = i.HiId
        WHERE NOT EXISTS (SELECT 1 FROM Tools.DieRankCompatibility drc
                          WHERE drc.RankAId = i.LoId AND drc.RankBId = i.HiId);

        -- '~' : pair stored with a different CanMix (will UPDATE)
        INSERT INTO @Changes (ChangeKind, SortKey, PairLabel, OldCanMix, NewCanMix)
        SELECT N'~', ROW_NUMBER() OVER (ORDER BY rA.SortOrder, rB.SortOrder),
               rA.Code + NCHAR(215) + rB.Code, drc.CanMix, i.CanMix
        FROM @Incoming i
        INNER JOIN Tools.DieRankCompatibility drc
               ON drc.RankAId = i.LoId AND drc.RankBId = i.HiId
        INNER JOIN Tools.DieRank rA ON rA.Id = i.LoId
        INNER JOIN Tools.DieRank rB ON rB.Id = i.HiId
        WHERE drc.CanMix <> i.CanMix;

        DECLARE @AddSpec NVARCHAR(MAX);
        SELECT @AddSpec = STRING_AGG(
                   CAST(N'+' + PairLabel + N'=' + CAST(NewCanMix AS NVARCHAR(1))
                        AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY SortKey)
        FROM @Changes WHERE ChangeKind = N'+';

        DECLARE @UpdSpec NVARCHAR(MAX);
        SELECT @UpdSpec = STRING_AGG(
                   CAST(N'~' + PairLabel + N' ' + CAST(OldCanMix AS NVARCHAR(1))
                        + NCHAR(8594) + CAST(NewCanMix AS NVARCHAR(1))
                        AS NVARCHAR(MAX)), N'; ')
                   WITHIN GROUP (ORDER BY SortKey)
        FROM @Changes WHERE ChangeKind = N'~';

        DECLARE @ActionParts NVARCHAR(MAX) = N'';
        IF NULLIF(@AddSpec, N'') IS NOT NULL SET @ActionParts += @AddSpec + N'; ';
        IF NULLIF(@UpdSpec, N'') IS NOT NULL SET @ActionParts += @UpdSpec + N'; ';
        -- strip trailing '; ' (DATALENGTH/2 = char count incl. trailing space)
        IF DATALENGTH(@ActionParts) >= 4
            SET @ActionParts = LEFT(@ActionParts, DATALENGTH(@ActionParts)/2 - 2);
        IF @ActionParts = N'' SET @ActionParts = N'No-op save';

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            N'Die Rank Matrix ' + Audit.ufn_MidDot() + N' Compatibility ' +
            Audit.ufn_MidDot() + N' ' + @ActionParts + N'; ' +
            CAST(@TotalRows AS NVARCHAR(10)) + N' rows';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        -- Resolved-name JSON: OLD = current rows for the affected pairs,
        -- NEW = the incoming desired pairs.
        DECLARE @OldValueResolved NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT rA.Id, rA.Code FROM Tools.DieRank rA
                               WHERE rA.Id = drc.RankAId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS RankA,
                   JSON_QUERY((SELECT rB.Id, rB.Code FROM Tools.DieRank rB
                               WHERE rB.Id = drc.RankBId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS RankB,
                   drc.CanMix
            FROM Tools.DieRankCompatibility drc
            INNER JOIN @Incoming i ON i.LoId = drc.RankAId AND i.HiId = drc.RankBId
            ORDER BY drc.RankAId, drc.RankBId
            FOR JSON PATH);

        DECLARE @NewValueResolved NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT rA.Id, rA.Code FROM Tools.DieRank rA
                               WHERE rA.Id = i.LoId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS RankA,
                   JSON_QUERY((SELECT rB.Id, rB.Code FROM Tools.DieRank rB
                               WHERE rB.Id = i.HiId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS RankB,
                   i.CanMix
            FROM @Incoming i
            ORDER BY i.LoId, i.HiId
            FOR JSON PATH);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE drc
        SET CanMix = i.CanMix, UpdatedAt = SYSUTCDATETIME()
        FROM Tools.DieRankCompatibility drc
        INNER JOIN @Incoming i ON i.LoId = drc.RankAId AND i.HiId = drc.RankBId
        WHERE drc.CanMix <> i.CanMix;

        INSERT INTO Tools.DieRankCompatibility (RankAId, RankBId, CanMix, CreatedAt)
        SELECT i.LoId, i.HiId, i.CanMix, SYSUTCDATETIME()
        FROM @Incoming i
        WHERE NOT EXISTS (SELECT 1 FROM Tools.DieRankCompatibility drc
                          WHERE drc.RankAId = i.LoId AND drc.RankBId = i.HiId);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId=@AppUserId, @LogEntityTypeCode=N'DieRankCompatibility',
            @EntityId=NULL, @LogEventTypeCode=N'Updated', @LogSeverityCode=N'Info',
            @Description=@Activity, @OldValue=@OldValueResolved, @NewValue=@NewValueResolved;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Compatibility saved. ' + CAST(@TotalRows AS NVARCHAR(10)) + N' row(s) in payload.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();
        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId=@AppUserId, @LogEntityTypeCode=N'DieRankCompatibility',
                @EntityId=NULL, @LogEventTypeCode=N'Updated',
                @FailureReason=@Message, @ProcedureName=@ProcName,
                @AttemptedParameters=@Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
