-- =============================================
-- Procedure: Workorder.ScalePendingPress_Complete
-- Author:    Blue Ridge Automation
-- Created:   2026-11-19
-- Version:   1.1
--
-- Description:
--   Records the outcome of a pick on a claimed press: the part chosen and the
--   tray LOT the close minted, and writes the pick's audit row
--   (ScalePressPicked). Refused unless the row is Closed (claimed) and not yet
--   completed.
--
--   v1.1 (migration 0135): the pick also TEACHES this terminal the scale's
--   code -> the picked part (Workorder.ScalePartCode), in the same
--   transaction, so a closed tray and its learned mapping cannot drift apart.
--   A different part replaces the active mapping (the old one is kept,
--   deprecated); the same part changes nothing; an empty code is never
--   learned. Audited as ScalePartCodeLearned.
--
-- Parameters:
--   @Id                BIGINT - Workorder.ScalePendingPress.Id. Required.
--   @ItemId            BIGINT - the finished good the operator picked. Required.
--   @FinishedGoodLotId BIGINT - the tray LOT; NULL when the close result had none.
--   @AppUserId         BIGINT - the operator. Required.
--
-- Result: Status, Message.
--
--   Spec: docs/superpowers/specs/2026-11-19-digi-scale-feed-design.md section 7.
--   Status-row mutation (FDS-11-011): every rejecting validation runs BEFORE
--   any transaction and SELECTs the status row + RETURNs; the CATCH is the only
--   ROLLBACK site.
--
-- Change Log:
--   2026-11-20 - 1.1 - Learns the scale code -> part for the terminal (0135).
--   2026-11-19 - 1.0 - Initial version (failure rows name the terminal; Discard
--                      refuses, unaudited, when a pick claimed the press first).
-- =============================================
CREATE OR ALTER PROCEDURE Workorder.ScalePendingPress_Complete
    @Id                BIGINT,
    @ItemId            BIGINT,
    @FinishedGoodLotId BIGINT = NULL,
    @AppUserId         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Workorder.ScalePendingPress_Complete';
    DECLARE @Params   NVARCHAR(MAX) = (SELECT @Id AS Id, @ItemId AS ItemId, @FinishedGoodLotId AS FinishedGoodLotId,
                                               @AppUserId AS AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Pn NVARCHAR(50), @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);
    DECLARE @MapId BIGINT, @MapItemId BIGINT, @OldPn NVARCHAR(50), @Learn BIT = 0,
            @LearnActivity NVARCHAR(500), @LearnOld NVARCHAR(MAX), @LearnNew NVARCHAR(MAX);
    DECLARE @StatusId BIGINT, @TermId BIGINT, @TermCode NVARCHAR(50), @Net DECIMAL(10,3), @Uom NVARCHAR(10),
            @Code NVARCHAR(50), @LotId BIGINT, @PickedItemId BIGINT;
    DECLARE @Gone NVARCHAR(500) = N'This tray has already been dealt with.';

    BEGIN TRY
        IF @Id IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (Id, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TermId, @LogEventTypeCode = N'ScalePressPicked',
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
                    @EntityId = @TermId, @LogEventTypeCode = N'ScalePressPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        IF @StatusId <> 2 OR @PickedItemId IS NOT NULL
        BEGIN
            SET @Message = N'Only a claimed press can be completed, once.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TermId, @LogEventTypeCode = N'ScalePressPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @Pn = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);

        -- What the pick teaches: code -> part for this terminal (v1.1).
        SELECT @MapId = Id, @MapItemId = ItemId FROM Workorder.ScalePartCode
        WHERE TerminalLocationId = @TermId AND ScalePartCode = @Code AND DeprecatedAt IS NULL;
        IF LTRIM(RTRIM(ISNULL(@Code, N''))) <> N'' AND (@MapItemId IS NULL OR @MapItemId <> @ItemId)
            SET @Learn = 1;
        IF @Learn = 1
        BEGIN
            SET @OldPn = (SELECT PartNumber FROM Parts.Item WHERE Id = @MapItemId);
            SET @LearnActivity = Audit.ufn_TruncateActivity(@TermCode + N' ' + Audit.ufn_MidDot()
                + N' Scale part code ' + Audit.ufn_MidDot() + N' [' + @Code + N'] -> ' + @Pn
                + CASE WHEN @OldPn IS NULL THEN N'' ELSE N' (was ' + @OldPn + N')' END);
            SET @LearnOld = (SELECT @Code AS ScalePartCode,
                                    JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description FROM Parts.Item i WHERE i.Id = @MapItemId
                                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemId
                             WHERE @MapItemId IS NOT NULL FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            SET @LearnNew = (SELECT @Code AS ScalePartCode,
                                    JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description FROM Parts.Item i WHERE i.Id = @ItemId
                                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemId
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        END
        IF @Pn IS NULL
        BEGIN
            SET @Message = N'Part not found.';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TermId, @LogEventTypeCode = N'ScalePressPicked',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @Activity = Audit.ufn_TruncateActivity(@TermCode + N' ' + Audit.ufn_MidDot()
            + N' Scale held press ' + Audit.ufn_MidDot() + N' Picked ' + @Pn + N' ('
            + CAST(CAST(@Net AS DECIMAL(10,1)) AS NVARCHAR(20)) + N' ' + @Uom + N', scale said [' + @Code + N'])');
        SET @NewValue = (SELECT JSON_QUERY((SELECT i.Id, i.PartNumber, i.Description FROM Parts.Item i WHERE i.Id = @ItemId
                                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ItemId,
                                JSON_QUERY((SELECT l.Id, l.LotName FROM Lots.Lot l WHERE l.Id = @FinishedGoodLotId
                                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS FinishedGoodLotId,
                                @Net AS NetWeight, @Uom AS Uom, @Code AS ScalePartCode
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        -- ================= Mutation (atomic) =================
        BEGIN TRANSACTION;

        UPDATE Workorder.ScalePendingPress
        SET ResolvedItemId = @ItemId, FinishedGoodLotId = @FinishedGoodLotId
        WHERE Id = @Id;

        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TermId, @LocationId = @TermId,
            @LogEntityTypeCode = N'Location', @EntityId = @TermId, @LogEventTypeCode = N'ScalePressPicked',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        IF @Learn = 1
        BEGIN
            IF @MapId IS NOT NULL
                UPDATE Workorder.ScalePartCode
                SET DeprecatedAt = SYSUTCDATETIME(), DeprecatedByAppUserId = @AppUserId
                WHERE Id = @MapId;
            INSERT INTO Workorder.ScalePartCode (TerminalLocationId, ScalePartCode, ItemId, LearnedByAppUserId)
            VALUES (@TermId, @Code, @ItemId, @AppUserId);
            EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TermId, @LocationId = @TermId,
                @LogEntityTypeCode = N'Location', @EntityId = @TermId, @LogEventTypeCode = N'ScalePartCodeLearned',
                @LogSeverityCode = N'Info', @Description = @LearnActivity, @OldValue = @LearnOld, @NewValue = @LearnNew;
        END

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Tray closed as ' + @Pn + N'.';
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
                @EntityId = @TermId, @LogEventTypeCode = N'ScalePressPicked',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
