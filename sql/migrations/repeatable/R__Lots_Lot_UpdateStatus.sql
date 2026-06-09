-- ============================================================
-- Repeatable:  R__Lots_Lot_UpdateStatus.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-09
-- Version:     1.0
-- Description: Transitions Lots.Lot.LotStatusId with an optimistic-lock check
--              (@RowVersion). Inserts a LotStatusHistory row and audits
--              'LotStatusChanged'. Rejects: stale @RowVersion, no-op
--              (new = current), and (Phase 1) any transition other than
--              Good -> Closed (Phase 2 expands the allowed transition matrix;
--              holds are Phase 7).
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params; every exit ends SELECT @Status, @Message. RAISERROR in
--              nested CATCH with failure logging.
--
--              Optimistic lock is INTENTIONALLY LENIENT (Phase 1 opt-in): the
--              check runs only when @RowVersion is supplied; a caller that omits
--              the token (passes NULL) bypasses it entirely. Phase 2+ callers
--              that read RowVersion from Lot_Get SHOULD always supply it so a
--              concurrent edit is detected. See the inline note on the check.
--
--              NOTE: this proc CHANGES status, so it does NOT call
--              Lot_AssertNotBlocked (that guard is for status-preserving
--              advancing procs like Lot_MoveTo). It validates the transition
--              against the Phase 1 allowed set instead.
--
--              *** PHASE-2 MAINTAINER WARNING ***
--              This proc is the SOLE OWNER of the LOT status-transition matrix.
--              It INTENTIONALLY omits the B2 advancing-guard (Lot_AssertNotBlocked):
--              a status change DECIDES ITS OWN LEGALITY here, it is never gated by
--              the not-blocked guard that protects status-preserving moves. The
--              Phase 1 matrix is the single line Good -> Closed (see the inline
--              "Phase 1 allowed transition matrix" check below). When you expand
--              it, add the Hold / Scrap / Closed transitions EXPLICITLY here (e.g.
--              Good -> Hold, Hold -> Good, Good/Hold -> Scrap, etc.) — do NOT push
--              that legality into a shared guard, and do NOT introduce
--              Lot_AssertNotBlocked into this path. Keep the transition matrix
--              owned by this one check so there is exactly one place that defines
--              which LOT status transitions are legal.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_UpdateStatus
    @LotId              BIGINT,
    @NewLotStatusId     BIGINT,
    @Reason             NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL,
    @RowVersion         BINARY(8)     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.Lot_UpdateStatus';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @NewLotStatusId AS NewLotStatusId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @CurrentStatusId BIGINT;
    DECLARE @CurrentRowVer   BINARY(8);
    DECLARE @CurrentCode     NVARCHAR(20);
    DECLARE @NewCode         NVARCHAR(20);

    BEGIN TRY
        IF @LotId IS NULL OR @NewLotStatusId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, NewLotStatusId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                    @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @CurrentStatusId = l.LotStatusId,
               @CurrentRowVer   = l.RowVersion,
               @CurrentCode     = sc.Code
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @CurrentStatusId IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Optimistic-lock check. INTENTIONALLY LENIENT: skipped entirely when
        -- @RowVersion IS NULL (Phase 1 opt-in). Callers that read RowVersion
        -- from Lot_Get SHOULD always supply it; omitting it bypasses the check.
        IF @RowVersion IS NOT NULL AND @RowVersion <> @CurrentRowVer
        BEGIN
            SET @Message = N'LOT was modified by another user (stale RowVersion). Reload and retry.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- No-op rejection.
        IF @NewLotStatusId = @CurrentStatusId
        BEGIN
            SET @Message = N'New status equals current status (no-op).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @NewCode = (SELECT Code FROM Lots.LotStatusCode WHERE Id = @NewLotStatusId);
        IF @NewCode IS NULL
        BEGIN
            SET @Message = N'Target status code not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- Phase 1 allowed transition matrix: only Good -> Closed.
        IF NOT (@CurrentCode = N'Good' AND @NewCode = N'Closed')
        BEGIN
            SET @Message = N'Transition ' + @CurrentCode + N' -> ' + @NewCode
                         + N' is not permitted in Phase 1 (only Good -> Closed).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @CurrentStatusId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @NewLotStatusId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
            + N' ' + @CurrentCode + NCHAR(8594) + @NewCode
            + CASE WHEN @Reason IS NOT NULL THEN N' (' + @Reason + N')' ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        BEGIN TRANSACTION;

        UPDATE Lots.Lot
        SET LotStatusId     = @NewLotStatusId,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @LotId;

        INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
        VALUES (@LotId, @CurrentStatusId, @NewLotStatusId, @Reason, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = NULL,
            @LogEntityTypeCode  = N'Lot',
            @EntityId           = @LotId,
            @LogEventTypeCode   = N'LotStatusChanged',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = @OldValue,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT status changed ' + @CurrentCode + N' -> ' + @NewCode + N'.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'Lot',
                @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
