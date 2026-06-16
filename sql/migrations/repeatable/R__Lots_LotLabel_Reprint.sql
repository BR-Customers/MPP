-- ============================================================
-- Repeatable:  R__Lots_LotLabel_Reprint.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Convenience wrapper over the LotLabel print flow (FDS-05-020):
--              re-prints a LOT's label with a caller-supplied (non-Initial)
--              reason. Resolves the label TYPE from the LOT's most recent prior
--              LotLabel row; if the LOT has never been labelled, defaults to
--              Primary (LabelTypeCodeId = 1). It then performs the SAME active-
--              template resolve + five-token render + append-only insert + audit
--              as Lots.LotLabel_Print, and returns the SAME 4-column shape
--              (Status, Message, NewId, ZplContent). Original LotLabel rows are
--              never modified -- the log is append-only.
--
--              The render+insert core is INLINED here (mirrors LotLabel_Print) on
--              purpose: this proc may be captured via INSERT-EXEC by callers/tests,
--              and EXEC'ing LotLabel_Print would (a) be an illegal nested INSERT-EXEC
--              and (b) pollute this proc's result set with the inner status row. If
--              the render/insert body changes in LotLabel_Print, mirror it here.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params; every exit path ends with the 4-column status row. The
--              'LotLabel' entity routes audit to Audit.OperationLog (only the
--              'Lot' entity goes to Lots.LotEventLog). RAISERROR (not THROW) in
--              the nested CATCH with failure logging.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotLabel_Reprint
    @LotId              BIGINT,
    @PrintReasonCodeId  BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL,
    @PrinterName        NVARCHAR(100) = NULL   -- Arc 2 Phase 4: persisted to LotLabel.PrinterName for the dispatcher
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;
    DECLARE @Zpl     NVARCHAR(MAX) = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.LotLabel_Reprint';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @PrintReasonCodeId AS PrintReasonCodeId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LabelTypeCodeId  BIGINT;
    DECLARE @LotName          NVARCHAR(50);
    DECLARE @ItemId           BIGINT;
    DECLARE @ItemCode         NVARCHAR(50);
    DECLARE @PieceCount       INT;
    DECLARE @LabelParentLotId BIGINT;
    DECLARE @ParentLotNumber  NVARCHAR(50);
    DECLARE @PrintedAt        NVARCHAR(19);

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @LotId IS NULL OR @PrintReasonCodeId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, PrintReasonCodeId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'LotLabel',
                    @EntityId = NULL, @LogEventTypeCode = N'LabelPrinted',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        -- ---- Tier 2: referential validation ----
        SELECT @LotName          = l.LotName,
               @ItemId           = l.ItemId,
               @PieceCount       = l.PieceCount,
               @LabelParentLotId = l.ParentLotId
        FROM Lots.Lot l
        WHERE l.Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'LotLabel',
                @EntityId = @LotId, @LogEventTypeCode = N'LabelPrinted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Lots.PrintReasonCode WHERE Id = @PrintReasonCodeId)
        BEGIN
            SET @Message = N'Print reason code not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'LotLabel',
                @EntityId = @LotId, @LogEventTypeCode = N'LabelPrinted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        -- A reprint forces a non-Initial reason (FDS-05-020 / spec sec 4.4): the
        -- 'Initial' reason is reserved for the first print via LotLabel_Print.
        IF @PrintReasonCodeId = (SELECT Id FROM Lots.PrintReasonCode WHERE Code = N'Initial')
        BEGIN
            SET @Message = N'Reprint requires a non-Initial print reason.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'LotLabel',
                @EntityId = @LotId, @LogEventTypeCode = N'LabelPrinted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        -- ---- Resolve the label TYPE: most recent prior label, else Primary (1) ----
        SET @LabelTypeCodeId = (
            SELECT TOP 1 LabelTypeCodeId FROM Lots.LotLabel
            WHERE LotId = @LotId ORDER BY PrintedAt DESC, Id DESC);
        IF @LabelTypeCodeId IS NULL
            SET @LabelTypeCodeId = 1;  -- Primary default for a never-labelled LOT

        -- Resolve the ACTIVE template body for the resolved type.
        SET @Zpl = (SELECT TOP 1 ZplBody FROM Lots.LabelTemplate
                    WHERE LabelTypeCodeId = @LabelTypeCodeId AND DeprecatedAt IS NULL);

        IF @Zpl IS NULL
        BEGIN
            SET @Message = N'No active label template for the resolved label type.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'LotLabel',
                @EntityId = @LotId, @LogEventTypeCode = N'LabelPrinted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        -- ---- Resolve label fields (mirrors LotLabel_Print) ----
        SET @ItemCode = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);
        SET @PrintedAt = CONVERT(NVARCHAR(19), SYSUTCDATETIME(), 120);
        SET @ParentLotNumber = ISNULL(
            (SELECT LotName FROM Lots.Lot WHERE Id = @LabelParentLotId), N'');

        -- ---- Render: deterministic token substitution, all five tokens ----
        SET @Zpl = REPLACE(@Zpl, N'{LotName}',         ISNULL(@LotName, N''));
        SET @Zpl = REPLACE(@Zpl, N'{ParentLotNumber}', @ParentLotNumber);
        SET @Zpl = REPLACE(@Zpl, N'{ItemCode}',        ISNULL(@ItemCode, N''));
        SET @Zpl = REPLACE(@Zpl, N'{PieceCount}',      ISNULL(CAST(@PieceCount AS NVARCHAR(20)), N''));
        SET @Zpl = REPLACE(@Zpl, N'{PrintedAt}',       @PrintedAt);

        -- ---- Mutation (atomic) ----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Label ' + Audit.ufn_MidDot()
            + N' Reprinted (' + (SELECT Code FROM Lots.LabelTypeCode WHERE Id = @LabelTypeCodeId)
            + N'/' + (SELECT Code FROM Lots.PrintReasonCode WHERE Id = @PrintReasonCodeId) + N')';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT lt.Id, lt.Code, lt.Name FROM Lots.LabelTypeCode lt WHERE lt.Id = @LabelTypeCodeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS LabelType,
                   JSON_QUERY((SELECT pr.Id, pr.Code, pr.Name FROM Lots.PrintReasonCode pr WHERE pr.Id = @PrintReasonCodeId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS PrintReason,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code FROM Lots.Lot l WHERE l.Id = @LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        INSERT INTO Lots.LotLabel
            (LotId, LabelTypeCodeId, PrintReasonCodeId, ParentLotId, ZplContent,
             PrinterName, PrintedByUserId, TerminalLocationId, PrintedAt)
        VALUES
            (@LotId, @LabelTypeCodeId, @PrintReasonCodeId, @LabelParentLotId, @Zpl,
             @PrinterName, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'LotLabel',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'LabelPrinted',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Label reprinted.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        SET @NewId   = NULL;
        SET @Zpl     = NULL;

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'LotLabel',
                @EntityId = @LotId, @LogEventTypeCode = N'LabelPrinted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
