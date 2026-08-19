-- =============================================
-- Procedure:   Oee.ShiftOverride_Update
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   Edits the window / reason of an existing per-equipment shift override.
--   The KEY (LocationId, ShiftScheduleId, BusinessDate) is immutable -- moving
--   an override to different equipment or a different day is a Deprecate +
--   Create, so the audit trail shows two distinct assertions rather than one
--   row silently changing meaning.
--
--   TIME BASIS: LOCAL (Eastern) wall clock. @EndTime < @StartTime means the
--   window crosses midnight and ends on BusinessDate + 1.
--   See Oee.ufn_ShiftWindowForLocation for the full basis / DST note.
--
-- Parameters (input):
--   @Id        BIGINT        - Override to edit. Required, must be active.
--   @StartTime TIME(0)       - New local start. Required.
--   @EndTime   TIME(0)       - New local end. Required, <> @StartTime.
--   @Reason    NVARCHAR(500) - New reason. Optional (NULL clears it).
--   @AppUserId BIGINT        - Required for audit attribution.
--
-- Result set:
--   Single row: Status (BIT), Message (NVARCHAR). (No OUTPUT params -- FDS-11-011.)
--
-- Dependencies:
--   Tables: Oee.ShiftOverride, Oee.ShiftSchedule, Location.Location
--   Funcs:  Audit.ufn_MidDot, Audit.ufn_TruncateActivity
--   Procs:  Audit.Audit_LogConfigChange, Audit.Audit_LogFailure
--
-- Error Handling:
--   All rejecting validations run BEFORE BEGIN TRANSACTION (Msg 3915 under
--   INSERT-EXEC). CATCH is the only ROLLBACK site. RAISERROR, not THROW.
--
-- Change Log:
--   2026-08-19 - 1.0 - Initial version (backlog 6.1).
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_Update
    @Id        BIGINT,
    @StartTime TIME(0),
    @EndTime   TIME(0),
    @Reason    NVARCHAR(500) = NULL,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.ShiftOverride_Update';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id, @StartTime AS StartTime, @EndTime AS EndTime, @Reason AS Reason
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocCode      NVARCHAR(50);
    DECLARE @ScheduleName NVARCHAR(100);
    DECLARE @BusinessDate DATE;
    DECLARE @OldStart     TIME(0);
    DECLARE @OldEnd       TIME(0);
    DECLARE @OldReason    NVARCHAR(500);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @StartTime IS NULL OR @EndTime IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, StartTime, EndTime, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                    @EntityId = @Id, @LogEventTypeCode = N'Updated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @EndTime = @StartTime
        BEGIN
            SET @Message = N'EndTime must differ from StartTime (a zero-length window is not a shift).';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LocCode      = loc.Code,
               @ScheduleName = ss.Name,
               @BusinessDate = ov.BusinessDate,
               @OldStart     = ov.StartTime,
               @OldEnd       = ov.EndTime,
               @OldReason    = ov.Reason
        FROM Oee.ShiftOverride ov
        INNER JOIN Location.Location   loc ON loc.Id = ov.LocationId
        INNER JOIN Oee.ShiftSchedule   ss  ON ss.Id  = ov.ShiftScheduleId
        WHERE ov.Id = @Id AND ov.DeprecatedAt IS NULL;

        IF @LocCode IS NULL
        BEGIN
            SET @Message = N'Shift override not found or already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = @Id, @LogEventTypeCode = N'Updated',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ====================
        -- Mutation (atomic)
        -- ====================
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LocCode + N' ' + Audit.ufn_MidDot() + N' Shift Override ' + Audit.ufn_MidDot()
            + N' Updated ' + @ScheduleName + N' on ' + CONVERT(NVARCHAR(10), @BusinessDate, 23)
            + N' ~ ' + CONVERT(NVARCHAR(8), @OldStart, 108) + N'-' + CONVERT(NVARCHAR(8), @OldEnd, 108)
            + N' to ' + CONVERT(NVARCHAR(8), @StartTime, 108) + N'-' + CONVERT(NVARCHAR(8), @EndTime, 108));

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT CONVERT(NVARCHAR(8), @OldStart, 108) AS StartTime,
                   CONVERT(NVARCHAR(8), @OldEnd, 108)   AS EndTime,
                   @OldReason                           AS Reason
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT CONVERT(NVARCHAR(8), @StartTime, 108) AS StartTime,
                   CONVERT(NVARCHAR(8), @EndTime, 108)   AS EndTime,
                   @Reason                               AS Reason
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Oee.ShiftOverride
        SET StartTime       = @StartTime,
            EndTime         = @EndTime,
            Reason          = CASE WHEN @Reason IS NULL THEN NULL ELSE LTRIM(RTRIM(@Reason)) END,
            UpdatedAt       = SYSUTCDATETIME(),
            UpdatedByUserId = @AppUserId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ShiftOverride',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Updated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shift override updated.';
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
                @AppUserId           = @AppUserId,
                @LogEntityTypeCode   = N'ShiftOverride',
                @EntityId            = @Id,
                @LogEventTypeCode    = N'Updated',
                @FailureReason       = @Message,
                @ProcedureName       = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END
GO
