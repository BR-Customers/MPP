-- ============================================================
-- Repeatable:  R__Quality_ControlledRunDeviation_Raise.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.1
-- Change Log:  2026-10-21 - 1.1 - Piece 6 (spec 6c): a deviation covers every member still in
--                                 the super-lot when it is signed (EndedAt IS NULL); each gets
--                                 'Deviation <DV> raised' on its LOT(s) (ControlledRunLotDeviation;
--                                 container: each tray in it now).
-- Description: Raises a SIGNED deviation on an open super-lot: a condition the
--              inspection found and Quality judged not to affect part
--              performance. This is what MPP call the nonconformance (the
--              Use-As-Is outcome). A member with a Use-As-Is result cannot be
--              released until its super-lot carries one.
--
--              @AppUserId is THE SIGNER. The caller has just checked that
--              person's network password (AppUser.elevate, stateless form); the
--              id comes straight here and is never taken from the session.
--              Quality.ufn_SignatureAllowed is asked before anything is written.
--
--              Writes, in one transaction: the Quality.Signature row (meaning
--              DeviationApproval, the meaning's statement COPIED), the
--              deviation with a DV number, one audit row.
--
--              The DV number is minted INSIDE the transaction so a refused or
--              failed raise never burns one. The mint is an INLINED MIRROR of
--              Lots.IdentifierSequence_Next (source of truth:
--              R__Lots_IdentifierSequence_Next.sql) -- this proc returns a
--              status row and cannot EXEC another that does. Same block as
--              Quality.ControlledRun_Open.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Returns Status, Message, NewId.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRunDeviation_Raise
    @ControlledRunId    BIGINT,
    @Description        NVARCHAR(1000),
    @Justification      NVARCHAR(1000),
    @DefectCodeId       BIGINT        = NULL,
    @AffectedQuantity   INT           = NULL,
    @ExternalReference  NVARCHAR(50)  = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRunDeviation_Raise';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ControlledRunId AS ControlledRunId, LEFT(@Description, 500) AS Description,
               LEFT(@Justification, 500) AS Justification, @DefectCodeId AS DefectCodeId,
               @AffectedQuantity AS AffectedQuantity, @ExternalReference AS ExternalReference,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunNumber NVARCHAR(15), @RunStatusId BIGINT;
    SELECT @RunNumber = RunNumber, @RunStatusId = ControlledRunStatusId
    FROM Quality.ControlledRun WHERE Id = @ControlledRunId;

    SET @Description       = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @Justification     = NULLIF(LTRIM(RTRIM(@Justification)), N'');
    SET @ExternalReference = NULLIF(LTRIM(RTRIM(@ExternalReference)), N'');

    DECLARE @MeaningId BIGINT, @Statement NVARCHAR(500);
    SELECT @MeaningId = Id, @Statement = Statement FROM Quality.SignatureMeaning WHERE Code = N'DeviationApproval';
    DECLARE @EntityTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ControlledRun');

    BEGIN TRY
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF @ControlledRunId IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (ControlledRunId, AppUserId).';
        IF @Reject IS NULL AND @RunNumber IS NULL
            SET @Reject = N'Super-lot not found.';
        IF @Reject IS NULL AND @RunStatusId <> 1
            SET @Reject = N'Super-lot ' + @RunNumber + N' is not open.';
        IF @Reject IS NULL AND Quality.ufn_SignatureAllowed(@AppUserId, N'DeviationApproval') = 0
            SET @Reject = N'This user cannot sign a deviation.';
        IF @Reject IS NULL AND @Description IS NULL
            SET @Reject = N'Describe what deviates.';
        IF @Reject IS NULL AND @Justification IS NULL
            SET @Reject = N'Say why it does not affect part performance.';
        IF @Reject IS NULL AND @AffectedQuantity IS NOT NULL AND @AffectedQuantity <= 0
            SET @Reject = N'Pieces affected must be greater than zero, or left blank.';
        IF @Reject IS NULL AND @DefectCodeId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Id = @DefectCodeId AND DeprecatedAt IS NULL)
            SET @Reject = N'Defect reason not found or deprecated.';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @ControlledRunId, @LogEventTypeCode = N'ControlledRunDeviationRaised',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- DV number. INLINED MIRROR of Lots.IdentifierSequence_Next. ----
        DECLARE @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT,
                @DevNumber NVARCHAR(15);
        SELECT @SeqLast = s.LastValue + 1, @SeqEnd = s.EndingValue, @SeqFormat = s.FormatString
        FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        WHERE s.Code = N'ControlledRunDeviation';

        IF @SeqLast IS NULL
            RAISERROR(N'Identifier sequence ''ControlledRunDeviation'' is not configured.', 16, 1);
        IF @SeqLast > @SeqEnd
            RAISERROR(N'Identifier sequence ''ControlledRunDeviation'' is exhausted.', 16, 1);

        UPDATE Lots.IdentifierSequence
        SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME()
        WHERE Code = N'ControlledRunDeviation';

        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0
                              THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1)
                              ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(
            SUBSTRING(@SeqFormat,
                      CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                      CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1)
            AS INT);
        SET @DevNumber = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
            THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
            ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        -- ---- the signature, then the deviation it signs ----
        INSERT INTO Quality.Signature
            (SignatureMeaningId, AppUserId, Statement, LogEntityTypeId, EntityId, TerminalLocationId)
        VALUES (@MeaningId, @AppUserId, @Statement, @EntityTypeId, @ControlledRunId, @TerminalLocationId);
        DECLARE @SignatureId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

        INSERT INTO Quality.ControlledRunDeviation
            (ControlledRunId, DeviationNumber, ExternalReference, Description, Justification, DefectCodeId,
             AffectedQuantity, SignatureId, RaisedByUserId, TerminalLocationId)
        VALUES (@ControlledRunId, @DevNumber, @ExternalReference, @Description, @Justification, @DefectCodeId,
                @AffectedQuantity, @SignatureId, @AppUserId, @TerminalLocationId);
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Deviation ' + Audit.ufn_MidDot()
            + N' + ' + @DevNumber + N': ' + @Description;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT d.DeviationNumber, d.ExternalReference, d.Description, d.Justification, d.AffectedQuantity,
                   d.SignatureId,
                   JSON_QUERY((SELECT dc.Id, dc.Code, dc.Description AS Name FROM Quality.DefectCode dc
                               WHERE dc.Id = d.DefectCodeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DefectCode,
                   JSON_QUERY((SELECT u.Id, u.Initials AS Code, u.DisplayName AS Name FROM Location.AppUser u
                               WHERE u.Id = d.RaisedByUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS SignedBy,
                   JSON_QUERY((SELECT @ControlledRunId AS Id, @RunNumber AS Code, @RunNumber AS Name
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FROM Quality.ControlledRunDeviation d WHERE d.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ControlledRun', @EntityId = @ControlledRunId,
            @LogEventTypeCode = N'ControlledRunDeviationRaised', @LogSeverityCode = N'Info',
            @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        -- v1.1: 'Deviation <DV> raised' on the LOTs of every member still in the
        -- super-lot at signing (spec 6c). Released / removed members get nothing.
        DECLARE @CoveredJson NVARCHAR(MAX) = (
            SELECT N'[' + STRING_AGG(CAST(m.Id AS NVARCHAR(MAX)), N',') + N']'
            FROM Quality.ControlledRunMember m
            WHERE m.ControlledRunId = @ControlledRunId AND m.EndedAt IS NULL);
        DECLARE @CoveredText NVARCHAR(400) = N'Deviation ' + @DevNumber + N' raised';
        IF @CoveredJson IS NOT NULL
            EXEC Quality.ControlledRun_LogMemberLotEventsInternal
                @MemberIdsJson = @CoveredJson, @LogEventTypeCode = N'ControlledRunLotDeviation',
                @ActionText = @CoveredText, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Deviation ' + @DevNumber + N' signed on super-lot ' + @RunNumber + N'.';
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
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @ControlledRunId, @LogEventTypeCode = N'ControlledRunDeviationRaised',
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
