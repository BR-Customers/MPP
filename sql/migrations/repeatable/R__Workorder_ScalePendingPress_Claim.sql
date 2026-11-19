-- =============================================
-- Procedure: Workorder.ScalePendingPress_Claim
-- Author:    Blue Ridge Automation
-- Created:   2026-11-19
-- Version:   1.0
--
-- Description:
--   Claims a held press for the operator's pick: Pending -> Closed, stamped
--   with who and when. Conditional on the row still being Pending, as ONE
--   statement, so a double tap or two screens cannot close two trays from one
--   press. The caller then closes the tray and calls _Complete, or _Release if
--   the close fails. Not audited itself: _Complete writes the pick's audit row.
--
-- Parameters:
--   @Id        BIGINT - Workorder.ScalePendingPress.Id. Required.
--   @AppUserId BIGINT - the operator picking. Required.
--
-- Result: Status, Message.
--
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 7.
--   Status-row mutation (FDS-11-011): every rejecting validation runs BEFORE
--   any transaction and SELECTs the status row + RETURNs; the CATCH is the only
--   ROLLBACK site.
--
-- Change Log:
--   2026-11-19 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScalePendingPress_Claim
    @Id        BIGINT,
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.ScalePendingPress_Claim';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT @Id AS Id, @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @StatusId BIGINT, @TermId BIGINT, @TermCode NVARCHAR(50), @Net DECIMAL(10,3), @Uom NVARCHAR(10),
            @Code NVARCHAR(50), @LotId BIGINT, @PickedItemId BIGINT;
    DECLARE @Gone NVARCHAR(500) = N'This tray has already been dealt with.';

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @Id, @LogEventTypeCode = N'ScalePressPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SELECT @StatusId = p.StatusId, @TermId = p.TerminalLocationId, @TermCode = l.Code,
               @Net = p.NetWeight, @Uom = p.Uom, @Code = p.ScalePartCode,
               @LotId = p.FinishedGoodLotId, @PickedItemId = p.ResolvedItemId
        FROM Workorder.ScalePendingPress p
        JOIN Location.Location l ON l.Id = p.TerminalLocationId
        WHERE p.Id = @Id;
        IF @TermId IS NULL
        BEGIN
            SET @Message = N'Held press not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @Id, @LogEventTypeCode = N'ScalePressPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @StatusId <> 1
        BEGIN
            SET @Message = @Gone;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @Id, @LogEventTypeCode = N'ScalePressPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        UPDATE Workorder.ScalePendingPress
        SET StatusId = 2, ResolvedAt = SYSUTCDATETIME(), ResolvedByAppUserId = @AppUserId
        WHERE Id = @Id AND StatusId = 1;
        IF @@ROWCOUNT = 0
        BEGIN
            SET @Message = @Gone;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @Status  = 1;
        SET @Message = N'Held press claimed.';
        SELECT @Status AS Status, @Message AS Message;
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
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @Id, @LogEventTypeCode = N'ScalePressPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
