-- =============================================
-- Procedure: Location.Terminal_SetPackOut
-- Author:    Blue Ridge Automation
-- Created:   2026-11-20
-- Version:   1.0
--
-- Description:
--   Sets the pack-out a terminal runs for one part + closure method (the
--   pack-out's own part and method). A tap on a pack-out button in the station
--   Pack-Out popup. Location.TerminalPackOutSelection holds one row per
--   (terminal, part, method), updated in place; the audit row is the history.
--
--   Any PIN-signed-in operator may set it; the audit row is the control
--   (Jacques, 2026-11-20, D10) -- the running-part override precedent.
--
--   Refuses:
--     - not an active terminal (LTD 7) on a line;
--     - a missing or removed pack-out;
--     - WHILE A BOX IS OPEN for that part at this terminal -- the box the next
--       tray would go into (Lots.ufn_ContainerForNextTray: the station's own
--       box, else an unowned box at the line). Finish or close it first
--       (D2). A box is never packed under two pack-outs;
--     - a no-op (already this terminal's pick).
--
--   Status-row mutation (FDS-11-011): every rejection runs before BEGIN
--   TRANSACTION; the upsert reads the row WITH (UPDLOCK, HOLDLOCK) so two
--   taps at once leave exactly one row. Audited to Audit.OperationLog
--   (PackOutSelected), entity Location = the terminal.
--
-- Parameters:
--   @TerminalLocationId BIGINT - Terminal (LTD 7). Required.
--   @PackOutId          BIGINT - the pack-out to run. Required.
--   @AppUserId          BIGINT - the signed-in operator. Required.
--
-- Result: Status BIT, Message NVARCHAR(500).
--
-- Change Log:
--   2026-11-20 - 1.0 - Initial version (named pack-outs).
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_SetPackOut
    @TerminalLocationId BIGINT,
    @PackOutId          BIGINT,
    @AppUserId          BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status BIT = 0, @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @ProcName NVARCHAR(200) = N'Location.Terminal_SetPackOut';
    DECLARE @Params NVARCHAR(MAX) = (
        SELECT @TerminalLocationId AS TerminalLocationId, @PackOutId AS PackOutId, @AppUserId AS AppUserId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @TermCode NVARCHAR(50), @LineId BIGINT;
    DECLARE @ItemId BIGINT, @Method NVARCHAR(20), @NewName NVARCHAR(50);
    DECLARE @CurPackOutId BIGINT, @OldName NVARCHAR(50), @OpenBox BIGINT, @OpenName NVARCHAR(50);
    DECLARE @PartNumber NVARCHAR(50);
    DECLARE @Activity NVARCHAR(500), @OldValue NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    BEGIN TRY
        -- ================= Pre-transaction validations =================
        IF @TerminalLocationId IS NULL OR @PackOutId IS NULL OR @AppUserId IS NULL
            SET @Message = N'Required parameter missing (TerminalLocationId, PackOutId, AppUserId).';
        ELSE
        BEGIN
            SELECT @TermCode = Code, @LineId = ParentLocationId
            FROM Location.Location
            WHERE Id = @TerminalLocationId AND LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL;

            SELECT @ItemId = ItemId, @Method = ClosureMethod, @NewName = Name
            FROM Parts.PackOut WHERE Id = @PackOutId AND DeprecatedAt IS NULL;

            IF @TermCode IS NULL OR @LineId IS NULL
                SET @Message = N'Pack-out can only be selected at a registered terminal.';
            ELSE IF @ItemId IS NULL
                SET @Message = N'Pack-out not found or removed.';
            ELSE
            BEGIN
                SELECT @CurPackOutId = s.PackOutId, @OldName = p.Name
                FROM Location.TerminalPackOutSelection s
                JOIN Parts.PackOut p ON p.Id = s.PackOutId
                WHERE s.TerminalLocationId = @TerminalLocationId AND s.ItemId = @ItemId AND s.ClosureMethod = @Method;

                SELECT @OpenBox = b.ContainerId, @OpenName = p.Name
                FROM Lots.ufn_ContainerForNextTray(@LineId, @ItemId, @TerminalLocationId) b
                JOIN Parts.ContainerConfig cc ON cc.Id = b.ContainerConfigId
                JOIN Parts.PackOut p ON p.Id = cc.PackOutId;

                IF @CurPackOutId = @PackOutId
                    SET @Message = N'''' + @NewName + N''' is already this station''s pack-out.';
                ELSE IF @OpenBox IS NOT NULL
                    SET @Message = N'Box #' + CAST(@OpenBox AS NVARCHAR(20)) + N' is open (' + @OpenName
                                 + N') -- finish or close it before changing pack-out.';
                ELSE
                    SET @Message = NULL;
            END
        END

        IF @Message IS NOT NULL
        BEGIN
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                    @EntityId = @TerminalLocationId, @LogEventTypeCode = N'PackOutSelected',
                    @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        SET @PartNumber = (SELECT PartNumber FROM Parts.Item WHERE Id = @ItemId);
        IF @OldName IS NULL
            SET @OldName = (SELECT Name FROM Parts.PackOut WHERE ItemId = @ItemId AND ClosureMethod = @Method
                            AND IsDefault = 1 AND DeprecatedAt IS NULL);
        SET @OldValue = (SELECT @CurPackOutId AS PackOutId, @OldName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @NewValue = (SELECT @PackOutId AS PackOutId, @NewName AS Name, @Method AS ClosureMethod,
                JSON_QUERY((SELECT i.Id, i.PartNumber AS Code, i.Description AS Name FROM Parts.Item i WHERE i.Id = @ItemId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Item
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Activity = Audit.ufn_TruncateActivity(@TermCode + N' ' + Audit.ufn_MidDot() + N' Pack-Out ' + Audit.ufn_MidDot()
            + N' ' + @PartNumber + N' ' + ISNULL(@OldName, N'(none)') + N' -> ' + @NewName);

        -- ================= Mutation (atomic) =================
        BEGIN TRANSACTION;

        IF EXISTS (SELECT 1 FROM Location.TerminalPackOutSelection WITH (UPDLOCK, HOLDLOCK)
                   WHERE TerminalLocationId = @TerminalLocationId AND ItemId = @ItemId AND ClosureMethod = @Method)
            UPDATE Location.TerminalPackOutSelection
            SET PackOutId = @PackOutId, SetByUserId = @AppUserId, SetAt = SYSUTCDATETIME()
            WHERE TerminalLocationId = @TerminalLocationId AND ItemId = @ItemId AND ClosureMethod = @Method;
        ELSE
            INSERT INTO Location.TerminalPackOutSelection (TerminalLocationId, ItemId, ClosureMethod, PackOutId, SetByUserId)
            VALUES (@TerminalLocationId, @ItemId, @Method, @PackOutId, @AppUserId);

        EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @TerminalLocationId,
            @LogEntityTypeCode = N'Location', @EntityId = @TerminalLocationId, @LogEventTypeCode = N'PackOutSelected',
            @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldValue, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'Running ' + @NewName + N' for ' + @PartNumber + N'.';
        SELECT @Status AS Status, @Message AS Message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(), @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        SET @Status = 0;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);
        BEGIN TRY
            EXEC Audit.Audit_LogFailure @AppUserId = @AppUserId, @LogEntityTypeCode = N'Location',
                @EntityId = @TerminalLocationId, @LogEventTypeCode = N'PackOutSelected',
                @FailureReason = @Message, @ProcedureName = @ProcName, @AttemptedParameters = @Params;
        END TRY BEGIN CATCH END CATCH
        SELECT @Status AS Status, @Message AS Message;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
