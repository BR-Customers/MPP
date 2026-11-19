-- =============================================
-- Procedure: Workorder.ScalePendingPress_Hold
-- Author:    Blue Ridge Automation
-- Created:   2026-11-19
-- Version:   1.0
--
-- Description:
--   Holds one good scale press whose part code matched no active MES part
--   (Workorder.ScalePendingPress, migration 0134) until the operator picks the
--   part on the scale station screen. Called by BlueRidge.Workorder.ScaleDigiWatcher
--   in gateway scope with the SYS user.
--
--   Refuses a missing parameter, a location that is not a terminal (LTD 7), and
--   a terminal that already has a Pending press (at most one; a second press at
--   that scale waits until the first is picked or discarded). The filtered
--   unique index enforces the same rule against a race; that collision returns
--   the same refusal instead of an error.
--
-- Parameters:
--   @TerminalLocationId BIGINT        - the scale's terminal. Required.
--   @NetWeight          DECIMAL(10,3) - net weight the scale sent. Required.
--   @Uom                NVARCHAR(10)  - unit the scale sent. Required.
--   @ScalePartCode      NVARCHAR(50)  - the <Part> code as sent. Required (may be empty text).
--   @AppUserId          BIGINT        - SYS from gateway scope. Required.
--
-- Result: Status, Message, NewId (the ScalePendingPress.Id).
--
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 7.
--   Status-row mutation (FDS-11-011): every rejecting validation runs BEFORE
--   any transaction and SELECTs the status row + RETURNs; the CATCH is the only
--   ROLLBACK site.
--
-- Change Log:
--   2026-11-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScalePendingPress_Hold
    @TerminalLocationId BIGINT,
    @NetWeight          DECIMAL(10,3),
    @Uom                NVARCHAR(10),
    @ScalePartCode      NVARCHAR(50),
    @AppUserId          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.ScalePendingPress_Hold';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @TerminalLocationId AS TerminalLocationId, @NetWeight AS NetWeight, @Uom AS Uom,
               @ScalePartCode AS ScalePartCode, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @TermCode NVARCHAR(50), @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);
    DECLARE @Waiting NVARCHAR(500) = N'A tray is already waiting for its part at this scale. Choose its part on the screen first.';

    BEGIN TRY
        IF @TerminalLocationId IS NULL OR @NetWeight IS NULL OR @Uom IS NULL OR @ScalePartCode IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (TerminalLocationId, NetWeight, Uom, ScalePartCode, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScalePressHeld',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @TermCode = Code FROM Location.Location
        WHERE Id = @TerminalLocationId AND LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL;
        IF @TermCode IS NULL
        BEGIN
            SET @Message = N'Terminal not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScalePressHeld',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM Workorder.ScalePendingPress WHERE TerminalLocationId = @TerminalLocationId AND StatusId = 1)
        BEGIN
            SET @Message = @Waiting;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScalePressHeld',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(@TermCode + N' ' + Audit.ufn_MidDot()
            + N' Scale held press ' + Audit.ufn_MidDot() + N' Held '
            + CAST(CAST(@NetWeight AS DECIMAL(10,1)) AS NVARCHAR(20)) + N' ' + @Uom
            + N', scale part [' + @ScalePartCode + N'] matches no part');
        SET @NewValue = (SELECT @NetWeight AS NetWeight, @Uom AS Uom, @ScalePartCode AS ScalePartCode
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ================= Mutation (atomic) =================
        BEGIN TRANSACTION;

        INSERT INTO Workorder.ScalePendingPress (TerminalLocationId, ReceivedAt, NetWeight, Uom, ScalePartCode, StatusId)
        VALUES (@TerminalLocationId, SYSUTCDATETIME(), @NetWeight, @Uom, LTRIM(RTRIM(@ScalePartCode)), 1);
        SET @NewId = SCOPE_IDENTITY();

        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @TerminalLocationId,
            @LogEntityTypeCode = N'Location', @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScalePressHeld',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tray held until its part is chosen.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        DECLARE @ErrNum INT = ERROR_NUMBER();
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrState INT = ERROR_STATE();
        SET @Status  = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        -- Two presses racing past the pre-check: the filtered unique index wins.
        IF @ErrNum IN (2601, 2627)
        BEGIN
            SET @Message = @Waiting;
            SET @NewId = NULL;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'ScalePressHeld',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
