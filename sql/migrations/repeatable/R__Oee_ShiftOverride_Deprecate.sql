-- =============================================
-- Procedure:   Oee.ShiftOverride_Deprecate
-- Author:      Blue Ridge Automation
-- Created:     2026-08-19
-- Version:     1.0
--
-- Description:
--   Soft-deletes a per-equipment shift override (DeprecatedAt convention -- no
--   hard delete). Once deprecated the equipment falls back to the global
--   Oee.ShiftSchedule window for that day, and the row remains queryable so a
--   past OEE figure can still be explained.
--
--   Idempotent from the caller's view: re-deprecating an already-deprecated
--   override is a rejection (status row), not an exception.
--
-- Parameters (input):
--   @Id        BIGINT - Override to deprecate. Required.
--   @AppUserId BIGINT - Required for audit attribution.
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
CREATE OR ALTER PROCEDURE Oee.ShiftOverride_Deprecate
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Oee.ShiftOverride_Deprecate';
    DECLARE @Params   NVARCHAR(MAX) =
        (SELECT @Id AS Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @LocCode      NVARCHAR(50);
    DECLARE @ScheduleName NVARCHAR(100);
    DECLARE @BusinessDate DATE;
    DECLARE @OldStart     TIME(0);
    DECLARE @OldEnd       TIME(0);

    BEGIN TRY
        -- ====================
        -- Parameter validation
        -- ====================
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                    @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @LocCode      = loc.Code,
               @ScheduleName = ss.Name,
               @BusinessDate = ov.BusinessDate,
               @OldStart     = ov.StartTime,
               @OldEnd       = ov.EndTime
        FROM Oee.ShiftOverride ov
        INNER JOIN Location.Location loc ON loc.Id = ov.LocationId
        INNER JOIN Oee.ShiftSchedule ss  ON ss.Id  = ov.ShiftScheduleId
        WHERE ov.Id = @Id AND ov.DeprecatedAt IS NULL;

        IF @LocCode IS NULL
        BEGIN
            SET @Message = N'Shift override not found or already deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ShiftOverride',
                @EntityId = @Id, @LogEventTypeCode = N'Deprecated',
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
            + N' Deprecated ' + @ScheduleName + N' '
            + CONVERT(NVARCHAR(8), @OldStart, 108) + N'-' + CONVERT(NVARCHAR(8), @OldEnd, 108)
            + N' on ' + CONVERT(NVARCHAR(10), @BusinessDate, 23));

        DECLARE @OldValue NVARCHAR(MAX) = (
            SELECT CONVERT(NVARCHAR(10), @BusinessDate, 23) AS BusinessDate,
                   CONVERT(NVARCHAR(8),  @OldStart, 108)    AS StartTime,
                   CONVERT(NVARCHAR(8),  @OldEnd, 108)      AS EndTime
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        UPDATE Oee.ShiftOverride
        SET DeprecatedAt       = SYSUTCDATETIME(),
            DeprecatedByUserId = @AppUserId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogConfigChange
            @AppUserId         = @AppUserId,
            @LogEntityTypeCode = N'ShiftOverride',
            @EntityId          = @Id,
            @LogEventTypeCode  = N'Deprecated',
            @LogSeverityCode   = N'Info',
            @Description       = @Activity,
            @OldValue          = @OldValue,
            @NewValue          = NULL;

        -- ATTRIBUTION RESTAMP (spec sec 4.3 / design D3) -- mirrors
        -- Oee.ShiftOverride_Create's block. Runs AFTER the DeprecatedAt UPDATE
        -- above, deliberately: Oee.ufn_ShiftIdForInstant reads only ACTIVE
        -- overrides, so by this point the equipment has already reverted to the
        -- plant-global window and the restamp moves the affected rows BACK. This
        -- is what makes an override reversible -- deprecating it restores the
        -- original attribution rather than freezing the rewritten one.
        EXEC Oee.ShiftOverride_Restamp
            @ShiftOverrideId = @Id,
            @AppUserId       = @AppUserId;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Shift override deprecated.';
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
                @LogEventTypeCode    = N'Deprecated',
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
