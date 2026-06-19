-- ============================================================
-- Repeatable:  R__Workorder_ConsumptionEvent_RecordWithBomCheck.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: Records a material consumption with a strict BOM check (Arc 2 Phase 6;
--              UJ-09 / FDS-06-011). The source LOT's Item must be a child line of the
--              producing Item's active published BOM. On a mismatch the proc rejects --
--              UNLESS @OverrideAuthorized=1 with an authorizing @OverrideAppUserId (a
--              supervisor AD elevation), in which case the consumption is written and a
--              MaterialSubstituteOverride audit captures BOTH the operator and supervisor
--              user ids. No OUTPUT params (FDS-11-011); single terminal SELECT
--              @Status,@Message,@NewId. RAISERROR in the CATCH.
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.ConsumptionEvent_RecordWithBomCheck
    @SourceLotId        BIGINT,
    @ProducingLotId     BIGINT,
    @CellLocationId     BIGINT,
    @ConsumedPieceCount INT,
    @ContainerSerialId  BIGINT = NULL,
    @OverrideAppUserId  BIGINT = NULL,
    @OverrideAuthorized BIT    = 0,
    @AppUserId          BIGINT = NULL,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @SourceItem BIGINT, @ProducingItem BIGINT, @OnBom BIT = 0,
            @SrcPart NVARCHAR(50), @ProdPart NVARCHAR(50),
            @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.ConsumptionEvent_RecordWithBomCheck';
    DECLARE @Params NVARCHAR(MAX) = (SELECT @SourceLotId AS SourceLotId, @ProducingLotId AS ProducingLotId,
        @ConsumedPieceCount AS ConsumedPieceCount, @OverrideAuthorized AS OverrideAuthorized, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ---- Tier 1 ----
        IF @SourceLotId IS NULL OR @ProducingLotId IS NULL OR @CellLocationId IS NULL OR @ConsumedPieceCount IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        IF @ConsumedPieceCount <= 0
        BEGIN
            SET @Message = N'ConsumedPieceCount must be positive.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Tier 2: resolve LOT items ----
        SELECT @SourceItem = ItemId FROM Lots.Lot WHERE Id = @SourceLotId;
        IF @SourceItem IS NULL
        BEGIN
            SET @Message = N'Source LOT not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        SELECT @ProducingItem = ItemId FROM Lots.Lot WHERE Id = @ProducingLotId;
        IF @ProducingItem IS NULL
        BEGIN
            SET @Message = N'Producing LOT not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- strict BOM check: source Item is a child line of the producing Item's active BOM ----
        IF EXISTS (SELECT 1 FROM Parts.Bom b INNER JOIN Parts.BomLine bl ON bl.BomId = b.Id
                   WHERE b.ParentItemId = @ProducingItem AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
                     AND bl.ChildItemId = @SourceItem)
            SET @OnBom = 1;

        -- ---- mismatch without authorized override -> reject ----
        IF @OnBom = 0 AND ISNULL(@OverrideAuthorized, 0) <> 1
        BEGIN
            SET @SrcPart  = (SELECT PartNumber FROM Parts.Item WHERE Id = @SourceItem);
            SET @ProdPart = (SELECT PartNumber FROM Parts.Item WHERE Id = @ProducingItem);
            SET @Message = N'Source Item ' + ISNULL(@SrcPart, N'?') + N' is not a configured component for ' + ISNULL(@ProdPart, N'?') + N' at this Cell.';
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot', @EntityId = @ProducingLotId,
                @LogEventTypeCode = N'MaterialSubstituteOverride', @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- override requires an authorizing supervisor ----
        IF @OnBom = 0 AND @OverrideAuthorized = 1 AND @OverrideAppUserId IS NULL
        BEGIN
            SET @Message = N'Override requires an authorizing supervisor (OverrideAppUserId).';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Mutation (atomic) ----
        BEGIN TRANSACTION;

        INSERT INTO Workorder.ConsumptionEvent
            (SourceLotId, ProducedLotId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TerminalLocationId, ConsumedAt)
        VALUES
            (@SourceLotId, @ProducingLotId, @SourceItem, @ProducingItem, @ConsumedPieceCount, @CellLocationId, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        SET @NewId = SCOPE_IDENTITY();

        IF @OnBom = 0 AND @OverrideAuthorized = 1
        BEGIN
            SET @SrcPart = (SELECT PartNumber FROM Parts.Item WHERE Id = @SourceItem);
            SET @Activity = Audit.ufn_TruncateActivity(N'Material ' + ISNULL(@SrcPart, N'?') + N' ' + Audit.ufn_MidDot() + N' BOM override ' + Audit.ufn_MidDot() + N' Authorized');
            SET @NewValue = (SELECT @SourceItem AS ConsumedItemId, @ProducingItem AS ProducedItemId,
                @AppUserId AS OperatorUserId, @OverrideAppUserId AS SupervisorUserId, @ConsumedPieceCount AS PieceCount
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC Audit.Audit_LogOperation
                @AppUserId = @OverrideAppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellLocationId,
                @LogEntityTypeCode = N'Lot', @EntityId = @ProducingLotId, @LogEventTypeCode = N'MaterialSubstituteOverride',
                @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;
        END

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CASE WHEN @OnBom = 1 THEN N'Consumption recorded.' ELSE N'Consumption recorded (supervisor override).' END;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId = NULL;
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
