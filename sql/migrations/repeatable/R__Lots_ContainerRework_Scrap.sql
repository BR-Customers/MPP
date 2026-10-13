-- ============================================================
-- Repeatable:  R__Lots_ContainerRework_Scrap.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: REAL scrap out of a tray of a container under rework (spec 5). This is
--              what piece 3 could only record: a bad part found in a finished container.
--
--              Writes one Workorder.RejectEvent against the tray's finished-good LOT and
--              takes the pieces off that LOT and off Lots.ContainerTray.PartsClosedCount.
--              The LOT stays Closed throughout (spec D5) -- which is why this is its own
--              proc and not Workorder.RejectEvent_Record, whose guard rightly refuses a
--              Closed LOT everywhere else. The reject row and its audit MIRROR that proc
--              (source of truth: R__Workorder_RejectEvent_Record.sql).
--
--              SERIALIZED part: one serial per call (@ContainerSerialId, @Quantity = 1).
--              The serial stays on Lots.ContainerSerial marked RemovedAt, so the record
--              that it was packed in this container survives. NOT serialized: a quantity.
--
--              SUPER-LOT: when the container is a member of an OPEN super-lot the scrap is
--              also an inspection result. @ControlledRunResultId applies a scrap that was
--              only RECORDED on the Results tab (same member, same defect, same quantity,
--              live, not yet applied) by pointing it at the new RejectEvent. Without it a
--              new, already-applied result entry is written. Either way the Results tab
--              and the container agree.
--              With @ControlledRunResultId, @DefectCodeId and @Quantity may be left NULL:
--              they are taken from the recorded scrap.
--
--              Returns Status, Message, NewId (the RejectEvent).
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-container-repack-design.md
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.ContainerRework_Scrap
    @ContainerTrayId        BIGINT,
    @DefectCodeId           BIGINT        = NULL,
    @Quantity               INT           = NULL,
    @ContainerSerialId      BIGINT        = NULL,
    @ControlledRunResultId  BIGINT        = NULL,
    @Remarks                NVARCHAR(500) = NULL,
    @AppUserId              BIGINT,
    @TerminalLocationId     BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Lots.ContainerRework_Scrap';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ContainerTrayId AS ContainerTrayId, @DefectCodeId AS DefectCodeId, @Quantity AS Quantity, @ContainerSerialId AS ContainerSerialId, @ControlledRunResultId AS ControlledRunResultId, @Remarks AS Remarks, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Act NVARCHAR(500), @ActRaw NVARCHAR(MAX), @NewValue NVARCHAR(MAX);

    -- Applying a recorded scrap: the defect and the quantity are the recorded ones unless
    -- the caller states them (in which case they must match, checked below).
    IF @ControlledRunResultId IS NOT NULL
        SELECT @DefectCodeId = ISNULL(@DefectCodeId, rr.DefectCodeId), @Quantity = ISNULL(@Quantity, rr.Quantity)
        FROM Quality.ControlledRunResult rr WHERE rr.Id = @ControlledRunResultId;

    DECLARE @ContainerId BIGINT, @TrayLotId BIGINT, @TrayPieces INT, @TrayPos INT, @ConStatus NVARCHAR(50),
            @IsSerialized BIT, @ItemId BIGINT, @LotName NVARCHAR(50), @LotPieces INT, @LotCrt BIT,
            @SerialContainerId BIGINT, @SerialTrayId BIGINT, @SerialRemoved DATETIME2(3), @SerialNumber NVARCHAR(100);
    SELECT @ContainerId = t.ContainerId, @TrayLotId = t.FinishedGoodLotId, @TrayPieces = ISNULL(t.PartsClosedCount, 0),
           @TrayPos = t.TrayPosition, @ConStatus = cs.Code, @IsSerialized = ISNULL(cc.IsSerialized, 0), @ItemId = c.ItemId
    FROM Lots.ContainerTray t
    INNER JOIN Lots.Container c            ON c.Id = t.ContainerId
    INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
    LEFT JOIN Parts.ContainerConfig cc     ON cc.Id = c.ContainerConfigId
    WHERE t.Id = @ContainerTrayId;
    SELECT @LotName = l.LotName, @LotPieces = l.PieceCount, @LotCrt = l.CrtActive FROM Lots.Lot l WHERE l.Id = @TrayLotId;
    SELECT @SerialContainerId = s.ContainerId, @SerialTrayId = s.ContainerTrayId, @SerialRemoved = s.RemovedAt,
           @SerialNumber = sp.SerialNumber
    FROM Lots.ContainerSerial s LEFT JOIN Lots.SerializedPart sp ON sp.Id = s.SerializedPartId
    WHERE s.Id = @ContainerSerialId;

    DECLARE @MemberId BIGINT, @RunId BIGINT, @RunNumber NVARCHAR(15), @DefCode NVARCHAR(50);
    SELECT TOP 1 @MemberId = m.Id, @RunId = r.Id, @RunNumber = r.RunNumber
    FROM Quality.ControlledRunMember m INNER JOIN Quality.ControlledRun r ON r.Id = m.ControlledRunId
    WHERE m.ContainerId = @ContainerId AND m.EndedAt IS NULL AND r.ControlledRunStatusId = 1;
    SET @DefCode = (SELECT Code FROM Quality.DefectCode WHERE Id = @DefectCodeId AND DeprecatedAt IS NULL);
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
    DECLARE @ScrapDispositionId BIGINT = (SELECT Id FROM Quality.DispositionCode WHERE Code = N'Scrap');

    BEGIN TRY
        -- ---- Validations: the FIRST rule that fails is the message. All of them
        --      run before BEGIN TRANSACTION (Msg 3915 rule). ----
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF (@ContainerTrayId IS NULL OR @DefectCodeId IS NULL OR @AppUserId IS NULL)
            SET @Reject = N'Required parameter missing (ContainerTrayId, DefectCodeId, AppUserId).';
        IF @Reject IS NULL AND (NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL))
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND (@ContainerId IS NULL)
            SET @Reject = N'Tray not found.';
        IF @Reject IS NULL AND (@TrayLotId IS NULL OR @LotName IS NULL)
            SET @Reject = N'That tray has no LOT behind it and cannot be reworked here.';
        IF @Reject IS NULL AND (@ConStatus NOT IN (N'ReworkProcessing', N'ReworkFilling'))
            SET @Reject = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' is not open for rework.';
        IF @Reject IS NULL AND (@Quantity IS NULL OR @Quantity <= 0)
            SET @Reject = N'Quantity must be greater than zero.';
        IF @Reject IS NULL AND (@IsSerialized = 1 AND @ContainerSerialId IS NULL)
            SET @Reject = N'This part is serialized: pick the serial.';
        IF @Reject IS NULL AND (@IsSerialized = 1 AND @Quantity <> 1)
            SET @Reject = N'A serialized part is handled one serial at a time.';
        IF @Reject IS NULL AND (@IsSerialized = 0 AND @ContainerSerialId IS NOT NULL)
            SET @Reject = N'This part is not serialized: give a quantity, not a serial.';
        IF @Reject IS NULL AND (@ContainerSerialId IS NOT NULL AND (@SerialContainerId IS NULL OR @SerialContainerId <> @ContainerId OR @SerialRemoved IS NOT NULL OR (@SerialTrayId IS NOT NULL AND @SerialTrayId <> @ContainerTrayId)))
            SET @Reject = N'That serial is not in this tray.';
        IF @Reject IS NULL AND (@Quantity > LEAST(@LotPieces, @TrayPieces))
            SET @Reject = N'Tray ' + CAST(@TrayPos AS NVARCHAR(10)) + N' of container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' holds ' + CAST(LEAST(@LotPieces, @TrayPieces) AS NVARCHAR(10)) + N' pieces; ' + CAST(@Quantity AS NVARCHAR(10)) + N' is too many.';
        IF @Reject IS NULL AND (@DefCode IS NULL)
            SET @Reject = N'Defect reason not found or deprecated.';
        IF @Reject IS NULL AND (@ControlledRunResultId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Quality.ControlledRunResult rr WHERE rr.Id = @ControlledRunResultId AND rr.ControlledRunMemberId = @MemberId AND rr.DispositionCodeId = @ScrapDispositionId AND rr.VoidedAt IS NULL AND rr.RejectEventId IS NULL AND rr.DefectCodeId = @DefectCodeId AND rr.Quantity = @Quantity))
            SET @Reject = N'That recorded scrap does not match (same container, same defect, same quantity, not yet applied).';

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkScrapped',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- take the pieces off the CLOSED tray LOT and the tray, under a lock. The
        --      LOT is not reopened (spec D5); the container's rework status is the gate.
        --      The checks above read unlocked, so re-check here. ----
        DECLARE @NewLotPieces INT, @NewTrayPieces INT;
        UPDATE l
        SET @NewLotPieces = l.PieceCount - @Quantity, l.PieceCount = l.PieceCount - @Quantity,
            l.UpdatedAt = SYSUTCDATETIME(), l.UpdatedByUserId = @AppUserId
        FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK) WHERE l.Id = @TrayLotId;
        UPDATE t
        SET @NewTrayPieces = t.PartsClosedCount - @Quantity, t.PartsClosedCount = t.PartsClosedCount - @Quantity
        FROM Lots.ContainerTray t WITH (UPDLOCK, HOLDLOCK) WHERE t.Id = @ContainerTrayId;
        IF @NewLotPieces < 0 OR @NewTrayPieces < 0
            RAISERROR(N'REWORK_RACE: the tray no longer holds that many pieces.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM Lots.Container WHERE Id = @ContainerId AND ContainerStatusCodeId IN (6, 7))
            RAISERROR(N'REWORK_RACE: the container is no longer open for rework.', 16, 1);

        -- ---- the reject row. MIRROR of Workorder.RejectEvent_Record's INSERT. ----
        INSERT INTO Workorder.RejectEvent (
            ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt,
            ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId, TerminalLocationId)
        SELECT NULL, l.Id, @DefectCodeId, @Quantity, NULL, @Remarks, @AppUserId, SYSUTCDATETIME(),
               l.ItemId, l.ToolId, NULL, NULL, NULL, @TerminalLocationId
        FROM Lots.Lot l WHERE l.Id = @TrayLotId;
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        IF @ContainerSerialId IS NOT NULL
            UPDATE Lots.ContainerSerial SET RemovedAt = SYSUTCDATETIME(), RemovedRejectEventId = @NewId
            WHERE Id = @ContainerSerialId;

        -- ---- super-lot result entry: apply the recorded one, or write an applied one ----
        IF @MemberId IS NOT NULL AND @ControlledRunResultId IS NOT NULL
            UPDATE Quality.ControlledRunResult SET RejectEventId = @NewId
            WHERE Id = @ControlledRunResultId AND RejectEventId IS NULL;
        ELSE IF @MemberId IS NOT NULL
            INSERT INTO Quality.ControlledRunResult
                (ControlledRunMemberId, DispositionCodeId, Quantity, DefectCodeId, RejectEventId, Remarks,
                 RecordedByUserId, TerminalLocationId)
            VALUES (@MemberId, @ScrapDispositionId, @Quantity, @DefectCodeId, @NewId, @Remarks, @AppUserId, @TerminalLocationId);

        SET @ActRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' Reject ' + Audit.ufn_MidDot()
                    + N' ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs (' + @DefCode + N'); remaining '
                    + CAST(@NewLotPieces AS NVARCHAR(20)) + N' (container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' rework)';
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        SET @NewValue = (
            SELECT re.Id, re.Quantity, @SerialNumber AS SerialNumber,
                   JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name FROM Lots.Lot l
                               WHERE l.Id = re.LotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT dc.Id, dc.Code, dc.Description AS Name FROM Quality.DefectCode dc
                               WHERE dc.Id = re.DefectCodeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DefectCode
            FROM Workorder.RejectEvent re WHERE re.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'RejectEvent', @EntityId = @NewId, @LogEventTypeCode = N'RejectEventRecorded',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = NULL, @NewValue = @NewValue;

        SET @ActRaw = N'Container ' + CAST(@ContainerId AS NVARCHAR(20)) + N' ' + Audit.ufn_MidDot() + N' Rework ' + Audit.ufn_MidDot()
                    + N' - ' + CAST(@Quantity AS NVARCHAR(20)) + N' scrapped from tray ' + CAST(@TrayPos AS NVARCHAR(10))
                    + N' (' + @DefCode + N')' + CASE WHEN @SerialNumber IS NOT NULL THEN N', serial ' + @SerialNumber ELSE N'' END
                    + CASE WHEN @RunNumber IS NOT NULL THEN N'; super-lot ' + @RunNumber ELSE N'' END;
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Container', @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkScrapped',
            @LogSeverityCode = N'Info', @Description = @Act, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CAST(@Quantity AS NVARCHAR(10)) + N' scrapped from tray ' + CAST(@TrayPos AS NVARCHAR(10)) + N' of container ' + CAST(@ContainerId AS NVARCHAR(20)) + N'; ' + CAST(@NewTrayPieces AS NVARCHAR(10)) + N' left in the tray.';
        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev   INT            = ERROR_SEVERITY();
        DECLARE @ErrState INT            = ERROR_STATE();

        SET @Status  = 0;
        SET @NewId   = NULL;
        SET @Message = N'Unexpected error: ' + LEFT(@ErrMsg, 400);

        -- EXPECTED: the pre-transaction checks read unlocked; something changed in between.
        -- Everything is rolled back; say so plainly and do not re-raise.
        DECLARE @Race BIT = CASE WHEN @ErrMsg LIKE N'REWORK_RACE%' THEN 1 ELSE 0 END;
        IF @Race = 1
            SET @Message = N'The container changed while you were saving. Nothing was scrapped - reload and try again.';

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ContainerRework',
                    @EntityId = @ContainerId, @LogEventTypeCode = N'ContainerReworkScrapped',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        IF @Race = 0
            RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
