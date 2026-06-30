-- ============================================================
-- Repeatable:  R__Workorder_ProductionEvent_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-15
-- Version:     1.0
-- Description: Arc 2 Phase 3 (§4.1). Records ONE die-cast operator-station
--              production checkpoint as a Workorder.ProductionEvent row.
--
--              D1 (CUMULATIVE counters): @ShotCount / @ScrapCount are the
--              checkpoint's CUMULATIVE totals for the LOT (not deltas). The row
--              is stored verbatim; readers derive per-checkpoint deltas via
--              LAG() over (LotId, EventAt). A cumulative counter must be
--              monotonic non-decreasing, so a supplied value that is LESS than
--              the LOT's most recent ProductionEvent counter is REJECTED (a
--              cumulative counter cannot go backwards).
--
--              D2 (does NOT touch Lot quantities): a production checkpoint is an
--              append-only progress record; it does NOT mutate
--              Lot.InventoryAvailable / Lot.TotalInProcess. Those materialized
--              B5 columns move on consumption / reject, NOT on checkpoint
--              recording. (RejectEvent_Record is the proc that decrements them.)
--
--              Flow (FDS-11-011 + Msg-3915 rules): ALL rejecting validations run
--              BEFORE BEGIN TRANSACTION (this proc is captured via INSERT-EXEC by
--              callers/tests, so a ROLLBACK in an open caller txn would throw Msg
--              3915 — the CATCH is the only legal ROLLBACK site). The held-LOT
--              guard is INLINED (mirror of Lots.Lot_AssertNotBlocked) rather than
--              EXEC'd, for the same INSERT-EXEC reason. Single terminal result
--              row: Status, Message, NewId. @Status is BIT. No OUTPUT params.
--
--              Optional ProductionEventValue children: @FieldValuesJson is a
--              JSON array of {DataCollectionFieldId, Value, NumericValue?, UomId?}
--              captured beyond the promoted columns. NULL/empty = no children.
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.ProductionEvent_Record
    @LotId               BIGINT,
    @OperationTemplateId BIGINT,
    @ShotCount           INT            = NULL,
    @ScrapCount          INT            = NULL,
    @ScrapSourceId       BIGINT         = NULL,
    @WeightValue         DECIMAL(12,4)  = NULL,
    @WeightUomId         BIGINT         = NULL,
    @WorkOrderOperationId BIGINT        = NULL,
    @Remarks             NVARCHAR(500)  = NULL,
    @FieldValuesJson     NVARCHAR(MAX)  = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.ProductionEvent_Record';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @OperationTemplateId AS OperationTemplateId,
               @ShotCount AS ShotCount, @ScrapCount AS ScrapCount,
               @ScrapSourceId AS ScrapSourceId, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @StatusCode NVARCHAR(20);
    DECLARE @StatusName NVARCHAR(100);
    DECLARE @Blocks     BIT;

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @LotId IS NULL OR @OperationTemplateId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, OperationTemplateId, AppUserId).';
            -- FailureLog.AppUserId is NOT NULL + FK; only attribute when we have a user.
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                    @EntityId = NULL, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. FK resolution ----
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'OperationTemplate not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = NULL, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. LOT existence + held-LOT guard (INLINED mirror of Lots.Lot_AssertNotBlocked) ----
        -- Inlined (not EXEC'd) because this proc is captured via INSERT-EXEC; the
        -- not-blocked guard's own SELECT would pollute the single result set.
        SELECT @StatusCode = sc.Code,
               @StatusName = sc.Name,
               @Blocks     = sc.BlocksProduction
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @StatusCode IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- A LOT is blocked when BlocksProduction (Hold/Scrap) OR terminal Closed.
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot record production.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. Counter sanity (must be non-negative when supplied) ----
        IF (@ShotCount IS NOT NULL AND @ShotCount < 0)
           OR (@ScrapCount IS NOT NULL AND @ScrapCount < 0)
        BEGIN
            SET @Message = N'ShotCount / ScrapCount cannot be negative.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. D1 cumulative-monotonic guard ----
        -- The most recent prior checkpoint's counters for this LOT. A cumulative
        -- counter must not go backwards. Compared only when both prior and new
        -- values exist (a NULL on either side carries no monotonicity claim).
        DECLARE @PrevShot INT, @PrevScrap INT;
        SELECT TOP 1 @PrevShot = pe.ShotCount, @PrevScrap = pe.ScrapCount
        FROM Workorder.ProductionEvent pe
        WHERE pe.LotId = @LotId
        ORDER BY pe.EventAt DESC, pe.Id DESC;

        IF @PrevShot IS NOT NULL AND @ShotCount IS NOT NULL AND @ShotCount < @PrevShot
        BEGIN
            SET @Message = N'ShotCount ' + CAST(@ShotCount AS NVARCHAR(20))
                         + N' is less than the prior cumulative ShotCount '
                         + CAST(@PrevShot AS NVARCHAR(20)) + N' (cumulative counter cannot decrease).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @PrevScrap IS NOT NULL AND @ScrapCount IS NOT NULL AND @ScrapCount < @PrevScrap
        BEGIN
            SET @Message = N'ScrapCount ' + CAST(@ScrapCount AS NVARCHAR(20))
                         + N' is less than the prior cumulative ScrapCount '
                         + CAST(@PrevScrap AS NVARCHAR(20)) + N' (cumulative counter cannot decrease).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6. ScrapSource resolution (when supplied) ----
        IF @ScrapSourceId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Workorder.ScrapSource WHERE Id = @ScrapSourceId)
        BEGIN
            SET @Message = N'ScrapSource not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 7. Field-values JSON shape (when supplied) ----
        IF @FieldValuesJson IS NOT NULL AND LTRIM(RTRIM(@FieldValuesJson)) <> N''
           AND ISJSON(@FieldValuesJson) = 0
        BEGIN
            SET @Message = N'FieldValuesJson is not valid JSON.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks
        )
        VALUES (
            @LotId, @OperationTemplateId, @WorkOrderOperationId, SYSUTCDATETIME(),
            @ShotCount, @ScrapCount, @ScrapSourceId,
            @WeightValue, @WeightUomId, @AppUserId, @TerminalLocationId, @Remarks
        );

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- Optional ProductionEventValue children from the JSON array.
        IF @FieldValuesJson IS NOT NULL AND LTRIM(RTRIM(@FieldValuesJson)) <> N''
        BEGIN
            INSERT INTO Workorder.ProductionEventValue
                (ProductionEventId, DataCollectionFieldId, Value, NumericValue, UomId, CreatedAt)
            SELECT @NewId, j.DataCollectionFieldId, j.Value, j.NumericValue, j.UomId, SYSUTCDATETIME()
            FROM OPENJSON(@FieldValuesJson) WITH (
                DataCollectionFieldId BIGINT        N'$.DataCollectionFieldId',
                Value                 NVARCHAR(255)  N'$.Value',
                NumericValue          DECIMAL(18,4)  N'$.NumericValue',
                UomId                 BIGINT         N'$.UomId'
            ) j
            INNER JOIN Parts.DataCollectionField dcf ON dcf.Id = j.DataCollectionFieldId;
        END

        -- ----- Audit (resolved-FK JSON + readable Description). D2: no Lot mutation. -----
        DECLARE @LotName    NVARCHAR(50)  = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);
        DECLARE @OtCode     NVARCHAR(20)  = (SELECT Code FROM Parts.OperationTemplate WHERE Id = @OperationTemplateId);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Production ' + Audit.ufn_MidDot()
            + N' Checkpoint ' + ISNULL(@OtCode, N'?')
            + N' (Shots=' + ISNULL(CAST(@ShotCount AS NVARCHAR(20)), N'-')
            + N', Scrap=' + ISNULL(CAST(@ScrapCount AS NVARCHAR(20)), N'-') + N')';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                pe.Id, pe.ShotCount, pe.ScrapCount, pe.WeightValue,
                JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                            FROM Lots.Lot l WHERE l.Id = pe.LotId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                            FROM Parts.OperationTemplate ot WHERE ot.Id = pe.OperationTemplateId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTemplate
            FROM Workorder.ProductionEvent pe WHERE pe.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ProductionEvent',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'DieCastCheckpointRecorded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Production checkpoint recorded.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'DieCastCheckpointRecorded',
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
