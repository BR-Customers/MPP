-- =============================================
-- Procedure:   Oee.ShiftOverride_Create
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   Creates a per-equipment shift-window override for one calendar day.
--   Wins over the global Oee.ShiftSchedule window for that equipment on that
--   day (see Oee.ufn_ShiftWindowForLocation).
--
--   An override row is an ASSERTION that this equipment runs this shift over
--   this window on this date. It therefore covers three cases with one shape:
--     - EXTEND  : same StartTime, later EndTime (the stated use case).
--     - SHORTEN : same StartTime, earlier EndTime.
--     - ADD     : a date the schedule's DaysOfWeekBitmask does not include
--                 (Saturday overtime on one press). The bitmask is deliberately
--                 NOT consulted -- an override asserts the window regardless.
--
--   TIME BASIS: LOCAL (Eastern) wall clock, matching Oee.ShiftSchedule and
--   Oee.Shift (OI-38). @BusinessDate is the date the window STARTS on;
--   @EndTime < @StartTime means the window crosses midnight and ends on
--   @BusinessDate + 1. @EndTime = @StartTime is rejected (ambiguous between a
--   zero-length and a 24-hour window; also blocked by
--   CK_ShiftOverride_NonZeroWindow).
--
--   EQUIPMENT: @LocationId must be OEE equipment per Oee.ufn_ResolveOeeEquipment -- a
--   die cast press or a Machining/Assembly WorkCenter line, i.e. something
--   downtime is actually logged against. Validating this keeps an override
--   aligned with how Oee.DowntimeEvent.LocationId is already bucketed; an
--   override on a sub-cell, terminal or printer would silently never match any
--   downtime.
--
-- Parameters (input):
--   @LocationId      BIGINT        - Equipment. Required.
--   @ShiftScheduleId BIGINT        - Shift being overridden. Required.
--   @BusinessDate    DATE          - Local date the window starts on. Required.
--   @StartTime       TIME(0)       - Local start. Required.
--   @EndTime         TIME(0)       - Local end. Required, <> @StartTime.
--   @Reason          NVARCHAR(500) - Why. Optional.
--   @AppUserId       BIGINT        - Required for audit attribution.
--
-- Result set:
--   Single row: Status (BIT), Message (NVARCHAR), NewId (BIGINT).
--   (No OUTPUT params -- FDS-11-011.)
--
-- Dependencies:
--   Tables: Oee.ShiftOverride, Oee.ShiftSchedule, Location.Location
--   Funcs:  Oee.ufn_ResolveOeeEquipment, Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   All rejecting validations run BEFORE BEGIN TRANSACTION (a ROLLBACK inside a
--   proc invoked via INSERT-EXEC throws Msg 3915). CATCH is the only ROLLBACK
--   site. RAISERROR, not THROW.
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_Create
    @LocationId      BIGINT,
    @ShiftScheduleId BIGINT,
    @BusinessDate    DATE,
    @StartTime       TIME(0),
    @EndTime         TIME(0),
    @Reason          NVARCHAR(500) = NULL,
    @AppUserId       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Oee.ShiftOverride_Create';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @LocationId AS LocationId, @ShiftScheduleId AS ShiftScheduleId,
                @BusinessDate AS BusinessDate, @StartTime AS StartTime,
                @EndTime AS EndTime, @Reason AS Reason
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocCode      NVARCHAR(50);
    DECLARE @ScheduleName NVARCHAR(100);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @LocationId IS NULL OR @ShiftScheduleId IS NULL OR @BusinessDate IS NULL
           OR @StartTime IS NULL OR @EndTime IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (LocationId, ShiftScheduleId, BusinessDate, StartTime, EndTime, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                    @EntityId = NULL, @LogEventTypeCode = N'Created',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @EndTime = @StartTime
        BEGIN
            SET @Message = N'EndTime must differ from StartTime (a zero-length window is not a shift).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @LocCode = Code FROM Location.Location
        WHERE Id = @LocationId AND DeprecatedAt IS NULL;

        IF @LocCode IS NULL
        BEGIN
            SET @Message = N'Location not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @ScheduleName = Name FROM Oee.ShiftSchedule
        WHERE Id = @ShiftScheduleId AND DeprecatedAt IS NULL;

        IF @ScheduleName IS NULL
        BEGIN
            SET @Message = N'Shift schedule not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Business rules
        -- ====================
        -- The location must be OEE equipment -- a die cast press or a
        -- Machining/Assembly line, NOT a sub-cell, terminal, printer or rack.
        -- Oee.ufn_ResolveOeeEquipment is the single source of truth shared with
        -- Oee.ShiftOverride_ListEquipment (the picker), so what an operator can
        -- choose and what this proc accepts cannot drift apart.
        IF NOT EXISTS (SELECT 1 FROM Oee.ufn_ResolveOeeEquipment() e WHERE e.LocationId = @LocationId)
        BEGIN
            SET @Message = N'Location is not OEE equipment; override the press or line that downtime is logged against.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Oee.ShiftOverride
                   WHERE LocationId = @LocationId
                     AND ShiftScheduleId = @ShiftScheduleId
                     AND BusinessDate = @BusinessDate
                     AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'An override already exists for this equipment, shift and date. Edit it instead.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- OI-4 CONTIGUITY (design D1: attribution must be TOTAL and
        -- UNAMBIGUOUS). Oee.ufn_ShiftOverrideConflicts replays the day's
        -- effective windows for THIS equipment with the proposal substituted,
        -- and reports (a) a collision with another OVERRIDDEN window -- two
        -- overrides claiming the same instant, which the resolver's
        -- override-precedence rule cannot break -- and (b) coverage minutes the
        -- change would DESTROY, leaving instants attributable to no shift at
        -- all. Overlapping a plant-GLOBAL window is not a conflict: that is the
        -- ordinary extension, and override-precedence is exactly what makes it
        -- unambiguous (see that function's header).
        -- Pre-transaction, like every other rejecting validation (Msg 3915).
        DECLARE @NewGapMinutes  INT;
        DECLARE @OverlapSchName NVARCHAR(100);
        SELECT @NewGapMinutes  = c.NewGapMinutes,
               @OverlapSchName = c.OverlapScheduleName
        FROM Oee.ufn_ShiftOverrideConflicts(@LocationId, @ShiftScheduleId, @BusinessDate, @StartTime, @EndTime) c;

        IF @OverlapSchName IS NOT NULL
        BEGIN
            SET @Message = N'This window overlaps the ' + @OverlapSchName
                         + N' override already set for this equipment on this date. Adjust that override first so the shifts meet at one boundary.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF @NewGapMinutes > 0
        BEGIN
            SET @Message = N'This window would leave ' + CAST(@NewGapMinutes AS NVARCHAR(10))
                         + N' minute(s) of the day covered by no shift for this equipment. Extend the neighbouring shift first.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = NULL, @LogEventTypeCode = N'Created',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Shift Override ' + Audit.ufn_MidDot()
            + N' Created ' + @ScheduleName + N' '
            + CONVERT(NVARCHAR(8), @StartTime, 108) + N'-' + CONVERT(NVARCHAR(8), @EndTime, 108)
            + N' on ' + CONVERT(NVARCHAR(10), @BusinessDate, 23));

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT JSON_QUERY((SELECT loc.Id, loc.Code, loc.Name
                               FROM Location.Location loc WHERE loc.Id = @LocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS LocationId,
                   JSON_QUERY((SELECT ss.Id, ss.Name AS Code, ss.Name
                               FROM Oee.ShiftSchedule ss WHERE ss.Id = @ShiftScheduleId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ShiftScheduleId,
                   CONVERT(NVARCHAR(10), @BusinessDate, 23) AS BusinessDate,
                   CONVERT(NVARCHAR(8),  @StartTime, 108)   AS StartTime,
                   CONVERT(NVARCHAR(8),  @EndTime, 108)     AS EndTime,
                   @Reason                                  AS Reason
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        INSERT INTO Oee.ShiftOverride
            (LocationId, ShiftScheduleId, BusinessDate, StartTime, EndTime,
             Reason, CreatedAt, CreatedByUserId)
        VALUES
            (@LocationId, @ShiftScheduleId, @BusinessDate, @StartTime, @EndTime,
             CASE WHEN @Reason IS NULL THEN NULL ELSE LTRIM(RTRIM(@Reason)) END,
             SYSUTCDATETIME(), @AppUserId);

        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ShiftOverride',
            @EntityId          = @NewId,
            @LogEventTypeCode  = N'Created',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = NULL,
            @NewValue          = @NewValue;

        -- ATTRIBUTION RESTAMP (spec sec 4.3 / design D3). Retroactive is the
        -- NORMAL path -- nobody knows a shift ran long until after it did -- so
        -- creating the override must also move the rows already recorded inside
        -- the moved boundary, in the SAME transaction. Oee.ShiftOverride_Restamp
        -- emits no result set and owns no transaction precisely so it can be
        -- EXEC'd from here: this proc returns a status row and is itself captured
        -- via INSERT-EXEC by tests and callers, so it may not EXEC a sibling
        -- status-row proc (FDS-11-011, one result set per proc). Idempotent, and
        -- writes its own audit row summarising what moved.
        EXEC Oee.ShiftOverride_Restamp
            @ShiftOverrideId = @NewId,
            @AppUserId       = @AppUserId;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shift override created.';
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
                @EntityId            = NULL,
                @LogEventTypeCode    = N'Created',
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
