-- ============================================================
-- Repeatable:  R__Lots_LotLabel_Print.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Renders + records an LTT label for a LOT (FDS-05-019/024).
--              Resolves the ACTIVE Lots.LabelTemplate.ZplBody for the requested
--              @LabelTypeCodeId, substitutes the five placeholder tokens
--              ({LotName} {ParentLotNumber} {ItemCode} {PieceCount} {PrintedAt})
--              from the LOT + its Item (+ parent LOT name when the LOT is a
--              sublot), inserts the append-only Lots.LotLabel row with the
--              rendered ZplContent, audits 'LabelPrinted', and returns
--              SELECT @Status, @Message, @NewId, @Zpl AS ZplContent.
--
--              SQL-side ZPL rendering (spec decision sec 2.3 / sec 4.4): label CONTENT
--              is proc-enforced + assertable here; the gateway only DISPATCHES
--              the returned string (B17 async, later phase). Rendering is pure
--              deterministic string substitution -- no business logic.
--
--              DEFERRED: LotLabel.PrinterName is inserted NULL in Phase 2. When the
--              B17 gateway dispatcher lands, add a @PrinterName param (here AND in
--              LotLabel_Reprint) so the target printer is recorded on the row.
--
--              ParentLotId (FDS-05-024 sublot rule): set to Lot.ParentLotId so a
--              sublot label record carries its parent linkage; the parent's
--              LotName also fills the {ParentLotNumber} token. NULL / '' for a
--              primary LOT.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params; every exit path ends with the 4-column status row. The
--              'LotLabel' entity routes audit to Audit.OperationLog (only the
--              'Lot' entity goes to Lots.LotEventLog). RAISERROR (not THROW) in
--              the nested CATCH with failure logging.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotLabel_Print
    @LotId              BIGINT,
    @LabelTypeCodeId    BIGINT,
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

    DECLARE @ProcName NVARCHAR(200) = N'Lots.LotLabel_Print';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @LabelTypeCodeId AS LabelTypeCodeId,
               @PrintReasonCodeId AS PrintReasonCodeId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName         NVARCHAR(50);
    DECLARE @ItemId          BIGINT;
    DECLARE @ItemCode        NVARCHAR(50);
    DECLARE @PieceCount      INT;
    DECLARE @LabelParentLotId BIGINT;
    DECLARE @ParentLotNumber NVARCHAR(50);
    DECLARE @PrintedAt       NVARCHAR(19);

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @LotId IS NULL OR @LabelTypeCodeId IS NULL OR @PrintReasonCodeId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, LabelTypeCodeId, PrintReasonCodeId, AppUserId).';
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

        IF NOT EXISTS (SELECT 1 FROM Lots.LabelTypeCode WHERE Id = @LabelTypeCodeId)
        BEGIN
            SET @Message = N'Label type code not found.';
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

        -- Resolve the ACTIVE template body for this label type.
        SET @Zpl = (SELECT TOP 1 ZplBody FROM Lots.LabelTemplate
                    WHERE LabelTypeCodeId = @LabelTypeCodeId AND DeprecatedAt IS NULL);

        IF @Zpl IS NULL
        BEGIN
            SET @Message = N'No active label template for the requested label type.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'LotLabel',
                @EntityId = @LotId, @LogEventTypeCode = N'LabelPrinted',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        -- ---- Resolve label fields ----
        -- Item.PartNumber is the human-facing item code projected as {ItemCode}.
        SET @ItemCode = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);
        SET @PrintedAt = CONVERT(NVARCHAR(19), SYSUTCDATETIME(), 120);
        -- Parent LOT name fills {ParentLotNumber}; empty string for a primary LOT.
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
            + N' Printed (' + (SELECT Code FROM Lots.LabelTypeCode WHERE Id = @LabelTypeCodeId)
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
        SET @Message = N'Label printed.';
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
