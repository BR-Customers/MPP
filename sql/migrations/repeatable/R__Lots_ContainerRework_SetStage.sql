-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_SetStage.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: Moves a container under rework between its two stages, and optionally
--              sends it somewhere (spec D5 / D8):
--                'Filling'    -> ReworkFilling: the bad parts are out; it is REFILL-READY
--                                and can receive pieces (ContainerRework_MovePieces) or be
--                                picked up at a line (ContainerRework_Resume).
--                'Processing' -> ReworkProcessing: back to taking parts out.
--              @LocationId, when given, is where the container now is (a line, for
--              "send to line"). NULL leaves it where it is.
--
--              'Filling' also RECALLS a container that was resumed at a line and has not
--              completed yet (status Open with a resumed rework row): Quality can pull it
--              back. That same path is what returns a container to refill-ready when a
--              "complete here" is refused.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-container-repack-design.md
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_SetStage
    @ContainerId        BIGINT,
    @StageCode          NVARCHAR(20),
    @LocationId         BIGINT = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';

    DECLARE @ProcName NVARCHAR(200) = N'Lots.ContainerRework_SetStage';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerId AS ContainerId, @StageCode AS StageCode, @LocationId AS LocationId, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Act NVARCHAR(500), @ActRaw NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    DECLARE @Cur NVARCHAR(50), @Resumed BIT = 0, @LocName NVARCHAR(200), @Target BIGINT;
    SELECT @Cur = cs.Code FROM Lots.Container c INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    WHERE c.Id = @ContainerId;
    -- A resumed rework container reads Open; it is still "in rework" until it completes.
    IF @Cur = N'Open' AND EXISTS (
            SELECT 1 FROM (SELECT TOP 1 r.ResumedAt, r.VoidedAt FROM Lots.ContainerRework r
                           WHERE r.ContainerId = @ContainerId ORDER BY r.Id DESC) x
            WHERE x.ResumedAt IS NOT NULL AND x.VoidedAt IS NULL)
        SET @Resumed = 1;
    SET @LocName = (SELECT Name FROM Location.Location WHERE Id = @LocationId AND DeprecatedAt IS NULL);
    SET @Target = CASE @StageCode WHEN N'Filling' THEN 7 WHEN N'Processing' THEN 6 END;

    BEGIN TRY
        -- ---- Validations: the FIRST rule that fails is the message. All of them
        --      run before BEGIN TRANSACTION (Msg 3915 rule). ----
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF @ContainerId IS NULL OR @StageCode IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (ContainerId, StageCode, AppUserId).';
        IF @Reject IS NULL AND NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL)
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND @Cur IS NULL
            SET @Reject = N'Container not found.';
        IF @Reject IS NULL AND @Target IS NULL
            SET @Reject = N'Unknown stage ''' + @StageCode + N'''.';
        IF @Reject IS NULL AND @Cur NOT IN (N'ReworkProcessing', N'ReworkFilling') AND @Resumed = 0
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is not open for rework.';
        IF @Reject IS NULL AND @Resumed = 1 AND @StageCode <> N'Filling'
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is being filled at a line. Recall it to refill-ready first.';
        IF @Reject IS NULL AND @LocationId IS NOT NULL AND @LocName IS NULL
            SET @Reject = N'Location not found.';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkStageChanged',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        UPDATE Lots.Container
        SET ContainerStatusCodeId = @Target,
            CurrentLocationId     = ISNULL(@LocationId, CurrentLocationId),
            StationLocationId     = NULL
        WHERE Id = @ContainerId AND ContainerStatusCodeId IN (1, 6, 7);
        IF @@ROWCOUNT = 0
            RAISERROR(N'Container was changed by someone else.', 16, 1);

        -- recalled from a line: it is no longer resumed
        IF @Resumed = 1
            UPDATE r SET ResumedAt = NULL, ResumedByUserId = NULL, ResumedAtLocationId = NULL
            FROM Lots.ContainerRework r
            WHERE r.Id = (SELECT MAX(Id) FROM Lots.ContainerRework WHERE ContainerId = @ContainerId);

        SET @ActRaw = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Rework ' + Audit.ufn_MidDot()
                    + CASE WHEN @StageCode = N'Filling' THEN N' Refill-ready' ELSE N' Back to processing' END
                    + CASE WHEN @Resumed = 1 THEN N' (recalled from the line)' ELSE N'' END
                    + CASE WHEN @LocName IS NOT NULL THEN N'; sent to ' + @LocName ELSE N'' END;
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        SET @NewValue = (
            SELECT @ContainerId AS ContainerId, CASE WHEN @StageCode = N'Filling' THEN N'ReworkFilling' ELSE N'ReworkProcessing' END AS Status,
                   JSON_QUERY((SELECT lo.Id, lo.Code, lo.Name FROM Location.Location lo WHERE lo.Id = @LocationId
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS SentTo
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @OldValue NVARCHAR(MAX) = (SELECT @Cur AS Status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = @LocationId,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkStageChanged',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = @OldValue, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + CASE WHEN @StageCode = N'Filling' THEN N' is refill-ready' ELSE N' is back in processing' END + CASE WHEN @LocName IS NOT NULL THEN N' at ' + @LocName ELSE N'' END + N'.';
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
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkStageChanged',
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
