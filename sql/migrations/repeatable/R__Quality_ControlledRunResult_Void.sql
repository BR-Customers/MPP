-- ============================================================
-- Repeatable:  R__Quality_ControlledRunResult_Void.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-19
-- Version:     1.1
-- Change Log:  2026-10-19 - 1.1 - Refuses an APPLIED return: a ReturnToSupplier entry that a
--                                 Lots.VendorReturn (not cancelled) points at. Cancelling the
--                                 return voids the entry in the same transaction (piece 5).
-- Description: Voids ONE inspection result entry: the correction for a wrong
--              entry (spec D4). The row is never edited or deleted -- it is
--              stamped VoidedAt / VoidedByUserId / VoidRemarks once, stops
--              counting, and the right numbers are entered again.
--
--              Refused when:
--                * the entry is already voided,
--                * the super-lot is no longer open, or the member has left it
--                  (released, removed) -- the record is then closed history,
--                * the entry TOOK PIECES OFF A LOT (RejectEventId IS NOT NULL).
--                  Voiding it here would leave the LOT short with nothing to
--                  show why. That correction is to the LOT's piece count.
--                * the entry is an applied vendor return (a Lots.VendorReturn not
--                  cancelled points at it). Lots.VendorReturn_Cancel restores the
--                  pieces and voids the entry together.
--
--              A reason is required.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Returns Status, Message.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRunResult_Void
    @ResultId           BIGINT,
    @Remarks            NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRunResult_Void';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ResultId AS ResultId, @Remarks AS Remarks, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @Found BIT = 0, @RunId BIGINT, @RunNumber NVARCHAR(15), @RunStatusId BIGINT, @MemberId BIGINT,
            @MemberEndedAt DATETIME2(3), @VoidedAt DATETIME2(3), @RejectEventId BIGINT, @Qty INT,
            @DispName NVARCHAR(100), @DisplayName NVARCHAR(60), @HasReturn BIT = 0;

    SELECT @Found = 1, @MemberId = rr.ControlledRunMemberId, @VoidedAt = rr.VoidedAt,
           @RejectEventId = rr.RejectEventId, @Qty = rr.Quantity, @DispName = dc.Name,
           @RunId = m.ControlledRunId, @MemberEndedAt = m.EndedAt
    FROM Quality.ControlledRunResult rr
    INNER JOIN Quality.DispositionCode dc     ON dc.Id = rr.DispositionCodeId
    INNER JOIN Quality.ControlledRunMember m  ON m.Id = rr.ControlledRunMemberId
    WHERE rr.Id = @ResultId;
    SELECT @RunNumber = RunNumber, @RunStatusId = ControlledRunStatusId FROM Quality.ControlledRun WHERE Id = @RunId;
    SELECT @DisplayName = ms.DisplayName FROM Quality.ufn_ControlledRunMemberState(@RunId) ms WHERE ms.MemberId = @MemberId;
    IF EXISTS (SELECT 1 FROM Lots.VendorReturn WHERE ControlledRunResultId = @ResultId AND CancelledAt IS NULL)
        SET @HasReturn = 1;
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');

    BEGIN TRY
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF @ResultId IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (ResultId, AppUserId).';
        IF @Reject IS NULL AND NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL)
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND @Found = 0
            SET @Reject = N'Result entry not found.';
        IF @Reject IS NULL AND @VoidedAt IS NOT NULL
            SET @Reject = N'This entry is already voided.';
        IF @Reject IS NULL AND @RunStatusId <> 1
            SET @Reject = N'Super-lot ' + @RunNumber + N' is not open.';
        IF @Reject IS NULL AND @MemberEndedAt IS NOT NULL
            SET @Reject = @DisplayName + N' is no longer in the super-lot.';
        IF @Reject IS NULL AND @RejectEventId IS NOT NULL
            SET @Reject = N'These pieces were already taken off ' + @DisplayName + N'. Correct the LOT''s piece count instead.';
        IF @Reject IS NULL AND (@HasReturn = 1)
            SET @Reject = N'These pieces were marked for return to the vendor from ' + @DisplayName + N'. Cancel the return instead.';
        IF @Reject IS NULL AND @Remarks IS NULL
            SET @Reject = N'A reason is required to void an entry.';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunResultVoided',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Quality.ControlledRunResult
        SET VoidedAt = SYSUTCDATETIME(), VoidedByUserId = @AppUserId, VoidRemarks = @Remarks
        WHERE Id = @ResultId AND VoidedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM Lots.VendorReturn WHERE ControlledRunResultId = @ResultId AND CancelledAt IS NULL);

        IF @@ROWCOUNT = 0
            RAISERROR(N'This entry was voided by someone else, or its pieces were marked for return.', 16, 1);

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Results ' + Audit.ufn_MidDot()
            + N' - ' + @DisplayName + N' ' + @DispName + N' ' + CAST(@Qty AS NVARCHAR(10)) + N' voided: ' + @Remarks;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @ResultId AS ResultId, @DisplayName AS Member, @DispName AS Outcome, @Qty AS Quantity, @Remarks AS VoidRemarks,
                   JSON_QUERY((SELECT @RunId AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ControlledRun', @EntityId = @RunId,
            @LogEventTypeCode = N'ControlledRunResultVoided', @LogSeverityCode = N'Info',
            @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = @DispName + N' ' + CAST(@Qty AS NVARCHAR(10)) + N' on ' + @DisplayName + N' voided.';
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
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @RunId, @LogEventTypeCode = N'ControlledRunResultVoided',
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
