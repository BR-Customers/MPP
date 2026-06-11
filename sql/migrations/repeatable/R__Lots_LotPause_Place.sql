-- ============================================================
-- Repeatable:  R__Lots_LotPause_Place.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-06-11
-- Version:     1.0
-- Description: Opens a LOT-pause at a Cell (OI-21 / FDS-05-038). Validates the
--              LOT + Location, enforces the B2 not-blocked guard (inline -- a
--              held/closed LOT cannot be paused), and enforces the B3 open-event
--              invariant with an explicit pre-check so the caller gets a clean
--              message instead of the raw filtered-unique violation
--              (UQ_PauseEvent_OpenLotLocation). Inserts the open PauseEvent row
--              and audits 'LotPaused'. Returns SELECT @Status, @Message, @NewId.
--
--              The same LOT MAY be paused at multiple Cells at once -- the
--              uniqueness is per (LotId, LocationId), not per LOT.
--
--              B1 context params (@AppUserId / @TerminalLocationId). No OUTPUT
--              params. The 'PauseEvent' entity routes audit to Audit.OperationLog
--              (only the 'Lot' entity goes to Lots.LotEventLog). RAISERROR (not
--              THROW) in the nested CATCH with failure logging.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.LotPause_Place
    @LotId              BIGINT,
    @LocationId         BIGINT,
    @PausedReason       NVARCHAR(500) = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.LotPause_Place';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @LocationId AS LocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LotName    NVARCHAR(50);
    DECLARE @Blocks     BIT;
    DECLARE @StatusCode NVARCHAR(20);

    BEGIN TRY
        -- ---- Tier 1: required-parameter validation ----
        IF @LotId IS NULL OR @LocationId IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LotId, LocationId, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                    @EntityId = NULL, @LogEventTypeCode = N'LotPaused',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Tier 2: referential validation + status ----
        SELECT @LotName    = l.LotName,
               @Blocks     = sc.BlocksProduction,
               @StatusCode = sc.Code
        FROM Lots.Lot l
        INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
        WHERE l.Id = @LotId;

        IF @LotName IS NULL
        BEGIN
            SET @Message = N'LOT not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = NULL, @LogEventTypeCode = N'LotPaused',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @LocationId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'Location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = NULL, @LogEventTypeCode = N'LotPaused',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- B2 not-blocked guard (inline; matches Lot_AssertNotBlocked) ----
        IF @Blocks = 1 OR @StatusCode = N'Closed'
        BEGIN
            SET @Message = N'LOT is blocked (status ' + @StatusCode + N') and cannot be paused.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = NULL, @LogEventTypeCode = N'LotPaused',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- B3 open-event invariant: clean pre-check before the filtered-unique ----
        IF EXISTS (SELECT 1 FROM Lots.PauseEvent
                   WHERE LotId = @LotId AND LocationId = @LocationId AND ResumedAt IS NULL)
        BEGIN
            SET @Message = N'An open pause already exists for this LOT at this location.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = NULL, @LogEventTypeCode = N'LotPaused',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- Mutation (atomic) ----
        DECLARE @ActivityRaw NVARCHAR(MAX) =
            @LotName + N' ' + Audit.ufn_MidDot() + N' Pause ' + Audit.ufn_MidDot()
            + N' Paused at ' + (SELECT Code FROM Location.Location WHERE Id = @LocationId)
            + CASE WHEN @PausedReason IS NOT NULL THEN N' (' + @PausedReason + N')' ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT l.Id, l.LotName AS Code FROM Lots.Lot l WHERE l.Id = @LotId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name FROM Location.Location loc WHERE loc.Id = @LocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location,
                   @PausedReason AS PausedReason
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        INSERT INTO Lots.PauseEvent (LotId, LocationId, PausedByUserId, PausedReason, PausedAt)
        VALUES (@LotId, @LocationId, @AppUserId, @PausedReason, SYSUTCDATETIME());

        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @LocationId,
            @LogEntityTypeCode  = N'PauseEvent',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'LotPaused',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'LOT paused.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'PauseEvent',
                @EntityId = NULL, @LogEventTypeCode = N'LotPaused',
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
