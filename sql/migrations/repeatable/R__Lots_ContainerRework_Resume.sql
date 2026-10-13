-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_Resume.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: Makes a REFILL-READY container the open container at a cell (spec D8):
--              ReworkFilling -> Open, located at @CellLocationId, owned by no station.
--              From here it is an ordinary open container. Workorder.Assembly_
--              CompleteTray fills the OLDEST open container of the part at the cell
--              first (ORDER BY OpenedAt, which this proc does not touch), so the line
--              carries on into this one and its own newer container waits. The existing
--              Lots.Container_Complete then claims a NEW serial and label. Neither of
--              those procs is modified.
--
--              Called by the operator who picks the container on the line's inventory
--              card (PIN attribution, no elevation), and by "Complete here" at Quality.
--              The latest Lots.ContainerRework row records who resumed it and where; that
--              is what marks an Open container as "still being reworked" until it
--              completes.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-container-repack-design.md
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_Resume
    @ContainerId        BIGINT,
    @CellLocationId     BIGINT,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.ContainerRework_Resume';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @CellLocationId AS CellLocationId, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Act NVARCHAR(500), @ActRaw NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    DECLARE @Cur NVARCHAR(50), @CellName NVARCHAR(200), @ReworkId BIGINT;
    SELECT @Cur = cs.Code FROM Lots.Container c INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    WHERE c.Id = @ContainerId;
    SET @CellName = (SELECT Name FROM Location.Location WHERE Id = @CellLocationId AND DeprecatedAt IS NULL);
    SET @ReworkId = (SELECT MAX(Id) FROM Lots.ContainerRework WHERE ContainerId = @ContainerId);

    BEGIN TRY
        -- ---- Validations: the FIRST rule that fails is the message. All of them
        --      run before BEGIN TRANSACTION (Msg 3915 rule). ----
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF @ContainerId IS NULL OR @CellLocationId IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (ContainerId, CellLocationId, AppUserId).';
        IF @Reject IS NULL AND NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL)
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND @Cur IS NULL
            SET @Reject = N'Container not found.';
        IF @Reject IS NULL AND @Cur = N'ReworkProcessing'
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is not refill-ready yet.';
        IF @Reject IS NULL AND @Cur <> N'ReworkFilling' OR @ReworkId IS NULL
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is not waiting to be refilled.';
        IF @Reject IS NULL AND @CellName IS NULL
            SET @Reject = N'Location not found.';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkResumed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Lots.Container
        SET ContainerStatusCodeId = 1 /* Open */, CurrentLocationId = @CellLocationId, StationLocationId = NULL
        WHERE Id = @ContainerId AND ContainerStatusCodeId = 7 /* ReworkFilling */;
        IF @@ROWCOUNT = 0
            RAISERROR(N'REWORK_RACE: the container was picked up by someone else.', 16, 1);

        UPDATE Lots.ContainerRework
        SET ResumedAt = SYSUTCDATETIME(), ResumedByUserId = @AppUserId, ResumedAtLocationId = @CellLocationId
        WHERE Id = @ReworkId;

        SET @ActRaw = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Rework ' + Audit.ufn_MidDot()
                    + N' Resumed as the open container at ' + @CellName;
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        SET @NewValue = (
            SELECT @ContainerId AS ContainerId, N'Open' AS Status,
                   JSON_QUERY((SELECT lo.Id, lo.Code, lo.Name FROM Location.Location lo WHERE lo.Id = @CellLocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Location
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @CellLocationId,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkResumed',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = N'{"Status":"ReworkFilling"}', @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is now the open container at ' + @CellName + N'.';
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

        -- EXPECTED: the pre-transaction checks read unlocked; something changed in between.
        -- Everything is rolled back; say so plainly and do not re-raise.
        DECLARE @Race BIT = CASE WHEN @ErrMsg LIKE N'REWORK_RACE%' THEN 1 ELSE 0 END;
        IF @Race = 1
            SET @Message = N'Someone else just picked up that container. Nothing was changed - reload.';

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkResumed',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message;
        IF @Race = 0
            RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
