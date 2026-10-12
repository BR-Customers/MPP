-- ============================================================
-- Repeatable:  R__Quality_ControlledRunLabel_Print.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: Renders the super-lot label and logs the print request. The label
--              belongs to the SUPER-LOT, not to a member (D11): one design, FOUR copies
--              per request (^PQ4 in the one document), printed on demand only. Its
--              barcode is the run number -- scanning it on the Quality view opens the
--              super-lot. It carries no member name and no count, so any copy can go on
--              any unit and it never goes stale as the window rolls.
--
--              The body is the active Lots.LabelTemplate for label type 'ControlledRun'
--              (data, not ZPL hardcoded here). Tokens: {RunNumber} {PartNumber} {Reason}
--              {OpenedAt} {OpenedBy} {Copies}. OpenedAt is Eastern.
--
--              ZPL-SAFE FREE TEXT. The reason is typed by a person. '^' and '~' are ZPL
--              command prefixes -- left in, they end the label early or fire a printer
--              command -- and anything outside printable ASCII prints as mojibake. Those
--              characters are REPLACED, never rejected: a label that will not print
--              stops work. {Reason} is substituted LAST and has its braces replaced, so
--              nothing typed into it can be read as a token.
--
--              Printing is allowed for a closed super-lot (a reprint for the file is
--              harmless). Same four-column result as Lots.LotLabel_Print: Status,
--              Message, NewId (ControlledRunLabel.Id), ZplContent. Dispatch to the
--              printer is the caller's step (BlueRidge.Quality.ControlledRun.printLabels).
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRunLabel_Print
    @Id                 BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL,
    @PrinterName        NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;
    DECLARE @Zpl     NVARCHAR(MAX) = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRunLabel_Print';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Id AS Id, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId, @PrinterName AS PrinterName
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Copies INT = 4;   -- D11: four per request
    DECLARE @RunNumber NVARCHAR(15), @Reason NVARCHAR(500), @Part NVARCHAR(100), @OpenedAt NVARCHAR(16), @OpenedBy NVARCHAR(20);
    SELECT @RunNumber = r.RunNumber, @Reason = r.Reason, @Part = ISNULL(i.PartNumber, N''),
           @OpenedAt = CONVERT(NVARCHAR(16), CAST(r.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120),
           @OpenedBy = ISNULL(u.Initials, N'')
    FROM Quality.ControlledRun r
    LEFT JOIN Parts.Item i       ON i.Id = r.SelectionItemId
    LEFT JOIN Location.AppUser u ON u.Id = r.OpenedByUserId
    WHERE r.Id = @Id;

    BEGIN TRY
        -- ---- 1. ----
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunLabelPrinted',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        -- ---- 2. ----
        IF @RunNumber IS NULL
        BEGIN
            SET @Message = N'Super-lot not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunLabelPrinted',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        SET @Zpl = (SELECT TOP 1 t.ZplBody
                    FROM Lots.LabelTemplate t
                    INNER JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
                    WHERE c.Code = N'ControlledRun' AND t.DeprecatedAt IS NULL);
        -- ---- 3. ----
        IF @Zpl IS NULL
        BEGIN
            SET @Message = N'No active super-lot label template.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunLabelPrinted',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId, @Zpl AS ZplContent;
            RETURN;
        END

        -- ---- ZPL-safe free text (see header) ----
        DECLARE @Safe NVARCHAR(500) = LEFT(@Reason, 110);
        SET @Safe = REPLACE(REPLACE(@Safe, N'^', N' '), N'~', N' ');
        SET @Safe = REPLACE(REPLACE(@Safe, N'{', N'('), N'}', N')');
        DECLARE @p INT = PATINDEX(N'%[^ -}]%' COLLATE Latin1_General_BIN2, @Safe);
        WHILE @p > 0
        BEGIN
            SET @Safe = STUFF(@Safe, @p, 1, N'?');
            SET @p = PATINDEX(N'%[^ -}]%' COLLATE Latin1_General_BIN2, @Safe);
        END
        SET @Part = REPLACE(REPLACE(@Part, N'^', N' '), N'~', N' ');

        -- ---- Render: {Reason} LAST ----
        SET @Zpl = REPLACE(@Zpl, N'{RunNumber}',  @RunNumber);
        SET @Zpl = REPLACE(@Zpl, N'{PartNumber}', @Part);
        SET @Zpl = REPLACE(@Zpl, N'{OpenedAt}',   @OpenedAt);
        SET @Zpl = REPLACE(@Zpl, N'{OpenedBy}',   @OpenedBy);
        SET @Zpl = REPLACE(@Zpl, N'{Copies}',     CAST(@Copies AS NVARCHAR(5)));
        SET @Zpl = REPLACE(@Zpl, N'{Reason}',     @Safe);

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        INSERT INTO Quality.ControlledRunLabel
            (ControlledRunId, Copies, ZplContent, PrinterName, PrintedByUserId, TerminalLocationId)
        VALUES
            (@Id, @Copies, @Zpl, @PrinterName, @AppUserId, @TerminalLocationId);

        SET @NewId = SCOPE_IDENTITY();

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Label ' + Audit.ufn_MidDot()
            + N' Printed (' + CAST(@Copies AS NVARCHAR(5)) + N')';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @Copies AS Copies, @PrinterName AS PrinterName, @NewId AS ControlledRunLabelId,
                   JSON_QUERY((SELECT @Id AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ControlledRun',
            @EntityId           = @Id,
            @LogEventTypeCode   = N'ControlledRunLabelPrinted',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CAST(@Copies AS NVARCHAR(5)) + N' super-lot labels sent.';
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
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunLabelPrinted',
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
