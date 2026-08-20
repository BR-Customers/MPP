-- =============================================
-- Procedure:   Oee.ShiftOverride_Apply
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   Public, re-runnable entry point for the attribution restamp (spec sec 4.3,
--   docs/superpowers/specs/2026-08-19-shift-override-attribution-design.md).
--
--   Oee.ShiftOverride_Create / _Update / _Deprecate already invoke the restamp
--   inside their own transaction, so the normal path needs no second call. This
--   proc exists so the restamp can be re-run deliberately -- after a shift
--   instance is backfilled by Oee.Shift_Reconcile, after a data repair, or to
--   verify that a day's attribution is settled. It is IDEMPOTENT: re-running
--   immediately after an apply moves nothing.
--
--   All the work is in Oee.ShiftOverride_Restamp, which emits no result set and
--   owns no transaction (see its header for why). This proc supplies the
--   transaction and the status row.
--
--   MESSAGE. Oee.ShiftOverride_Restamp cannot hand back a count -- it must emit
--   no result set, and OUTPUT parameters are forbidden project-wide
--   (FDS-11-011). The count therefore comes back the same way it goes to the
--   auditors: this proc reads the Audit.ConfigLog row the restamp just wrote and
--   surfaces its Description. One source of truth for "what moved", no second
--   count that could disagree with the audit trail.
--
--   OI-1 (deferred, design D4): there is deliberately NO cutoff on how far back
--   an override may be applied. When a lock point is wanted it is ONE rejecting
--   validation, right here, before BEGIN TRANSACTION.
--
-- Parameters (input):
--   @ShiftOverrideId BIGINT - the override to (re-)apply. Deprecated overrides
--                             are legal and are how a restamp is REVERSED.
--   @AppUserId       BIGINT - required for audit attribution.
--
-- Result set:
--   Single row: Status (BIT), Message (NVARCHAR), NewId (BIGINT, always NULL --
--   this proc mints nothing). No OUTPUT params (FDS-11-011).
--
-- Dependencies:
--   Tables: Oee.ShiftOverride, Location.AppUser, Audit.ConfigLog,
--           Audit.LogEntityType, Audit.LogEventType
--   Procs:  Oee.ShiftOverride_Restamp, Audit.Audit_LogFailure
--
-- Error Handling:
--   All rejecting validations run BEFORE BEGIN TRANSACTION -- a ROLLBACK inside
--   a proc invoked via INSERT-EXEC throws Msg 3915, so CATCH is the only legal
--   ROLLBACK site. RAISERROR, not THROW.
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (shift-override attribution, sec 4.3).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_Apply
    @ShiftOverrideId BIGINT,
    @AppUserId       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.ShiftOverride_Apply';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @ShiftOverrideId AS ShiftOverrideId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @ShiftOverrideId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ShiftOverrideId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                    @EntityId = @ShiftOverrideId, @LogEventTypeCode = N'ShiftAttributionRestamped',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Referential validation
        -- ====================
        -- Deprecated rows are DELIBERATELY accepted: re-applying a deprecated
        -- override is how a restamp is undone.
        IF NOT EXISTS (SELECT 1 FROM Oee.ShiftOverride WHERE Id = @ShiftOverrideId)
        BEGIN
            SET @Message = N'Shift override not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = @ShiftOverrideId, @LogEventTypeCode = N'ShiftAttributionRestamped',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        BEGIN TRANSACTION;

        EXEC Oee.ShiftOverride_Restamp
            @ShiftOverrideId = @ShiftOverrideId,
            @AppUserId       = @AppUserId;

        COMMIT TRANSACTION;

        -- The restamp's own audit row is the single source of truth for what
        -- moved (see header). Read it back for the operator-facing message.
        DECLARE @Summary NVARCHAR(1000) = (
            SELECT TOP 1 cl.Description
            FROM   Audit.ConfigLog cl
            INNER JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId
            INNER JOIN Audit.LogEventType  ev ON ev.Id = cl.LogEventTypeId
            WHERE  cl.EntityId = @ShiftOverrideId
              AND  et.Code = N'ShiftOverride'
              AND  ev.Code = N'ShiftAttributionRestamped'
            ORDER BY cl.Id DESC);

        SET @Status  = 1;
        SET @Message = ISNULL(@Summary, N'Shift attribution applied.');
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
            EXEC Audit.Audit_LogFailure
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'ShiftOverride',
                @EntityId            = @ShiftOverrideId,
                @LogEventTypeCode    = N'ShiftAttributionRestamped',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
