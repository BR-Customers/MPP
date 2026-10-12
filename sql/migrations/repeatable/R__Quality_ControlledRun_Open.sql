-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_Open.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: Opens a super-lot: header + members in ONE call (bundled save, as
--              Location.LocationTypeDefinition_SaveAll). All or nothing.
--
--              @MembersJson = [{"lotId":n} | {"containerId":n}, ...]. Every member is
--              re-judged here by Quality.ufn_ControlledRunResolveMembers -- the preview is
--              advice, this is the guard. ONE ineligible member refuses the whole call and
--              names up to three offenders. An empty list is legal only when
--              @AutoJoinEnabled = 1 (a super-lot opened for future production).
--
--              D5: joining sets Lots.Lot.CrtActive (in ControlledRun_ApplyMembersInternal,
--              a SILENT helper -- a status-row proc may not EXEC another status-row proc).
--
--              The run number is minted INSIDE the transaction (a rolled-back open does not
--              burn a number). The mint is an INLINED mirror of Lots.IdentifierSequence_Next
--              -- this proc is itself captured via INSERT-EXEC and nesting INSERT-EXEC is
--              illegal. Same block as the LotName mint in Lots.Lot_Create.
--
--              @SelectionFromAtEastern / @SelectionToAtEastern are WALL-CLOCK EASTERN and
--              are stored UTC. Returns Status, Message, NewId.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-super-lot-design.md
-- ============================================================

CREATE OR ALTER PROCEDURE Quality.ControlledRun_Open
    @Reason                 NVARCHAR(500),
    @AnchorLotId            BIGINT        = NULL,
    @SelectionItemId        BIGINT        = NULL,
    @SelectionLocationId    BIGINT        = NULL,
    @SelectionFromAtEastern DATETIME2(3)  = NULL,
    @SelectionToAtEastern   DATETIME2(3)  = NULL,
    @IncludeDescendants     BIT           = 0,
    @AutoJoinEnabled        BIT           = 0,
    @MembersJson            NVARCHAR(MAX) = NULL,
    @AppUserId              BIGINT,
    @TerminalLocationId     BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_Open';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Reason AS Reason, @AnchorLotId AS AnchorLotId, @SelectionItemId AS SelectionItemId,
               @SelectionLocationId AS SelectionLocationId, @SelectionFromAtEastern AS SelectionFromAtEastern,
               @SelectionToAtEastern AS SelectionToAtEastern, @IncludeDescendants AS IncludeDescendants,
               @AutoJoinEnabled AS AutoJoinEnabled, LEFT(@MembersJson, 2000) AS MembersJson,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @FromUtc DATETIME2(3) = CAST(@SelectionFromAtEastern AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @ToUtc   DATETIME2(3) = CAST(@SelectionToAtEastern   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    DECLARE @MemberCount INT, @Bad NVARCHAR(400);
    SET @IncludeDescendants = ISNULL(@IncludeDescendants, 0);
    SET @AutoJoinEnabled    = ISNULL(@AutoJoinEnabled, 0);

    BEGIN TRY
        -- ---- 1. ----
        IF @AppUserId IS NULL OR @Reason IS NULL OR LTRIM(RTRIM(@Reason)) = N''
        BEGIN
            SET @Message = N'Required parameter missing (Reason, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. ----
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. ----
        IF @AnchorLotId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Lots.Lot WHERE Id = @AnchorLotId)
        BEGIN
            SET @Message = N'Suspect LOT not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. ----
        IF @SelectionItemId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Parts.Item WHERE Id = @SelectionItemId)
        BEGIN
            SET @Message = N'Part not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. ----
        IF @SelectionLocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @SelectionLocationId)
        BEGIN
            SET @Message = N'Line or area not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 6. ----
        IF @AutoJoinEnabled = 1 AND @SelectionItemId IS NULL
        BEGIN
            SET @Message = N'Keep adding new production needs a part.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @MemberCount = COUNT(*) FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson);
        -- ---- 7. ----
        IF @MemberCount = 0 AND @AutoJoinEnabled = 0
        BEGIN
            SET @Message = N'A super-lot needs at least one member.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @Bad = STRING_AGG(x.Txt, N'; ')
        FROM (SELECT TOP 3 r.DisplayName + N' (' + r.IneligibleReason + N')' AS Txt
              FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson) r
              WHERE r.IneligibleReason IS NOT NULL
              ORDER BY r.DisplayName) x;
        -- ---- 8. ----
        IF @Bad IS NOT NULL
        BEGIN
            SET @Message = N'Cannot open: ' + @Bad;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- Mint the run number INSIDE the tran. INLINED mirror of
        -- Lots.IdentifierSequence_Next (source of truth: R__Lots_IdentifierSequence_Next.sql).
        DECLARE @SeqLast BIGINT, @SeqEnd BIGINT, @SeqFormat NVARCHAR(50), @SeqPrefix NVARCHAR(50), @SeqPad INT, @RunNumber NVARCHAR(15);
        SELECT @SeqLast = s.LastValue + 1, @SeqEnd = s.EndingValue, @SeqFormat = s.FormatString
        FROM Lots.IdentifierSequence s WITH (ROWLOCK, UPDLOCK, HOLDLOCK)
        WHERE s.Code = N'ControlledRun';

        IF @SeqLast IS NULL
            RAISERROR(N'Identifier sequence ''ControlledRun'' is not configured.', 16, 1);
        IF @SeqLast > @SeqEnd
            RAISERROR(N'Identifier sequence ''ControlledRun'' is exhausted.', 16, 1);

        UPDATE Lots.IdentifierSequence
        SET LastValue = @SeqLast, UpdatedAt = SYSUTCDATETIME()
        WHERE Code = N'ControlledRun';

        SET @SeqPrefix = CASE WHEN CHARINDEX(N'{', @SeqFormat) > 0
                              THEN LEFT(@SeqFormat, CHARINDEX(N'{', @SeqFormat) - 1)
                              ELSE @SeqFormat END;
        SET @SeqPad = TRY_CAST(
            SUBSTRING(@SeqFormat,
                      CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) + 1,
                      CHARINDEX(N'}', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - CHARINDEX(N'D', @SeqFormat, CHARINDEX(N'{', @SeqFormat)) - 1)
            AS INT);
        SET @RunNumber = CASE WHEN @SeqPad IS NULL OR @SeqPad < 1
            THEN @SeqPrefix + CAST(@SeqLast AS NVARCHAR(20))
            ELSE @SeqPrefix + RIGHT(REPLICATE(N'0', @SeqPad) + CAST(@SeqLast AS NVARCHAR(20)), @SeqPad) END;

        INSERT INTO Quality.ControlledRun
            (RunNumber, ControlledRunStatusId, Reason, AnchorLotId, SelectionItemId, SelectionLocationId,
             SelectionFromAt, SelectionToAt, IncludeDescendants, AutoJoinEnabled, OpenedByUserId, OpenedAtTerminalId)
        VALUES
            (@RunNumber, 1, LTRIM(RTRIM(@Reason)), @AnchorLotId, @SelectionItemId, @SelectionLocationId,
             @FromUtc, @ToUtc, @IncludeDescendants, @AutoJoinEnabled, @AppUserId, @TerminalLocationId);

        SET @NewId = SCOPE_IDENTITY();

        -- Members + tag + per-LOT CrtActivated audit (silent helper, runs in this tran).
        EXEC Quality.ControlledRun_ApplyMembersInternal
            @ControlledRunId = @NewId, @MembersJson = @MembersJson, @JoinMethodCode = N'Selected',
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;

        DECLARE @Lots INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @NewId AND LotId IS NOT NULL);
        DECLARE @Cons INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @NewId AND ContainerId IS NOT NULL);

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Opened: '
            + CAST(@Lots AS NVARCHAR(10)) + N' LOTs, ' + CAST(@Cons AS NVARCHAR(10)) + N' containers';
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT r.RunNumber, r.Reason, r.IncludeDescendants, r.AutoJoinEnabled, r.SelectionFromAt, r.SelectionToAt,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name FROM Lots.Lot l
                               WHERE l.Id = r.AnchorLotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS AnchorLot,
                   JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i
                               WHERE i.Id = r.SelectionItemId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item,
                   JSON_QUERY((SELECT lo.Id, lo.Code, lo.Name FROM Location.Location lo
                               WHERE lo.Id = r.SelectionLocationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   @Lots AS LotCount, @Cons AS ContainerCount
            FROM Quality.ControlledRun r WHERE r.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'ControlledRun',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'ControlledRunOpened',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        DECLARE @Total INT = @Lots + @Cons;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Super-lot ' + @RunNumber + N' opened with ' + CAST(@Total AS NVARCHAR(10)) + N' members.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
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

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = NULL, @LogEventTypeCode = N'ControlledRunOpened',
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
