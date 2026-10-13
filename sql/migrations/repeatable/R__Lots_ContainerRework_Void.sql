-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_Void.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: Voids a container under rework that has been EMPTIED (spec D4): its good
--              parts went into other containers, its bad parts were scrapped. Refused
--              while it still holds a single piece.
--
--              In one transaction: status -> Void; the rework row is stamped; the
--              Controlled Run Tag is cleared on its (now empty) tray LOTs with one
--              CrtCleared audit row per LOT (INLINED MIRROR of Lots.Lot_ClearCrt) so no
--              empty LOT is left "tagged" and holding a super-lot open; and an open
--              super-lot membership is ended with reason ContainerVoided (5), which
--              counts as cleared. Its serial and label were voided when it was opened.
--
--              A reason is required.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-container-repack-design.md
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_Void
    @ContainerId        BIGINT,
    @Remarks            NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.ContainerRework_Void';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @Remarks AS Remarks, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Act NVARCHAR(500), @ActRaw NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    DECLARE @Cur NVARCHAR(50), @Pieces INT, @ReworkId BIGINT, @RunNumber NVARCHAR(15);
    SELECT @Cur = cs.Code FROM Lots.Container c INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    WHERE c.Id = @ContainerId;
    -- pieces = what the tray LOTs hold AND what the trays say; either being non-zero blocks
    SET @Pieces = ISNULL((SELECT SUM(CASE WHEN ISNULL(l.PieceCount, 0) > ISNULL(t.PartsClosedCount, 0)
                                          THEN ISNULL(l.PieceCount, 0) ELSE ISNULL(t.PartsClosedCount, 0) END)
                          FROM Lots.ContainerTray t LEFT JOIN Lots.Lot l ON l.Id = t.FinishedGoodLotId
                          WHERE t.ContainerId = @ContainerId), 0);
    SET @ReworkId = (SELECT MAX(Id) FROM Lots.ContainerRework WHERE ContainerId = @ContainerId);
    SET @RunNumber = (SELECT TOP 1 r.RunNumber FROM Quality.ControlledRunMember m
                      INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
                      WHERE m.ContainerId = @ContainerId AND m.EndedAt IS NULL);
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');

    BEGIN TRY
        -- ---- Validations: the FIRST rule that fails is the message. All of them
        --      run before BEGIN TRANSACTION (Msg 3915 rule). ----
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF (@ContainerId IS NULL OR @AppUserId IS NULL)
            SET @Reject = N'Required parameter missing (ContainerId, AppUserId).';
        IF @Reject IS NULL AND (NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL))
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND (@Cur IS NULL)
            SET @Reject = N'Container not found.';
        IF @Reject IS NULL AND (@Cur NOT IN (N'ReworkProcessing', N'ReworkFilling'))
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is not open for rework.';
        IF @Reject IS NULL AND (@Pieces > 0)
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' still holds ' + CAST(@Pieces AS NVARCHAR(10)) + N' pieces. Move or scrap them first.';
        IF @Reject IS NULL AND (@Remarks IS NULL)
            SET @Reject = N'A reason is required to void a container.';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerVoided',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Lots.Container SET ContainerStatusCodeId = 5 /* Void */
        WHERE Id = @ContainerId AND ContainerStatusCodeId IN (6, 7);
        IF @@ROWCOUNT = 0
            RAISERROR(N'Container was changed by someone else.', 16, 1);

        UPDATE Lots.ContainerRework
        SET VoidedAt = SYSUTCDATETIME(), VoidedByUserId = @AppUserId, VoidRemarks = @Remarks
        WHERE Id = @ReworkId;

        -- ---- clear the tag on the empty tray LOTs. MIRROR of Lots.Lot_ClearCrt. ----
        DECLARE @Cleared TABLE (LotId BIGINT NOT NULL, LotName NVARCHAR(50) NOT NULL);
        UPDATE l
        SET CrtActive = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        OUTPUT inserted.Id, inserted.LotName INTO @Cleared (LotId, LotName)
        FROM Lots.Lot l
        WHERE l.CrtActive = 1
          AND l.Id IN (SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t WHERE t.ContainerId = @ContainerId);

        DECLARE @LotId BIGINT, @LotName NVARCHAR(50);
        DECLARE cleared_cur CURSOR LOCAL FAST_FORWARD FOR SELECT LotId, LotName FROM @Cleared ORDER BY LotId;
        OPEN cleared_cur;
        FETCH NEXT FROM cleared_cur INTO @LotId, @LotName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ActRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot()
                        + N' Cleared (container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' emptied and voided)';
            SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
            SET @NewValue = (
                SELECT CAST(0 AS BIT) AS CrtActive,
                       JSON_QUERY((SELECT @LotId AS Id, @LotName AS Code, @LotName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC Audit.Audit_LogOperation
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'CrtCleared',
                @LogSeverityCode = N'Info', @Description = @Act, @OldValue = N'{"CrtActive":true}', @NewValue = @NewValue;
            FETCH NEXT FROM cleared_cur INTO @LotId, @LotName;
        END
        CLOSE cleared_cur; DEALLOCATE cleared_cur;

        -- ---- it leaves its super-lot: there is nothing left to release ----
        UPDATE Quality.ControlledRunMember
        SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @AppUserId,
            ControlledRunMemberEndReasonId = 5 /* ContainerVoided */, EndRemarks = @Remarks
        WHERE ContainerId = @ContainerId AND EndedAt IS NULL;

        SET @ActRaw = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Voided (emptied by repack)'
                    + CASE WHEN @RunNumber IS NOT NULL THEN N'; left super-lot ' + @RunNumber ELSE N'' END + N': ' + @Remarks;
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        SET @NewValue = (SELECT @ContainerId AS ContainerId, N'Void' AS Status, @Remarks AS Remarks, @RunNumber AS LeftSuperLot
                         FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
        DECLARE @OldValue NVARCHAR(MAX) = (SELECT @Cur AS Status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerVoided',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = @OldValue, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' voided.' + CASE WHEN @RunNumber IS NOT NULL THEN N' It has left super-lot ' + @RunNumber + N'.' ELSE N'' END;
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
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerVoided',
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
