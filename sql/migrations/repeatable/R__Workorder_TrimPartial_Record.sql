-- ============================================================
-- Repeatable:  R__Workorder_TrimPartial_Record.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: Trim partial checkpoint at shift end
--              (docs/superpowers/specs/2026-09-22-trim-partial-shift-end-design.md).
--              Writes ONE cumulative Workorder.ProductionEvent on the LOT with the
--              route's TrimIn template and the shift the OPERATOR PICKED (never
--              defaulted -- the die cast shift-picker defect came from a preselected
--              shift). The LOT does NOT move: its FIFO position is untouched and
--              Trim OUT later closes it exactly as today. Credit per shift is
--              ShotCount minus the previous TRIM checkpoint on the LOT.
--
--              Optional by design: the tumblers never call it.
--
--              Scrap: one RejectEvent per line, stamped ItemId + CellLocationId +
--              ShiftId (0084 identity), ProductionEventId NULL (mirror of Trim OUT
--              v1.4); the LOT is decremented once by the total, as Trim OUT does.
--
--              Flow (FDS-11-011 + Msg-3915): every rejecting check runs BEFORE
--              BEGIN TRANSACTION; each check only runs while @Message IS NULL, and a
--              single exit logs the failure and returns the status row. CATCH is
--              the only ROLLBACK site. No OUTPUT params; NewId = ProductionEventId.
--              Audit 'TrimCheckpointRecorded' (LogEventType 34).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.TrimPartial_Record
    @LotId               BIGINT,
    @OperationTemplateId BIGINT,
    @ShotCount           INT,
    @ScrapLinesJson      NVARCHAR(MAX) = NULL,   -- [{"defectCodeId":<bigint>,"quantity":<int>}, ...]
    @ShiftId             BIGINT,
    @SourceLocationId    BIGINT,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = NULL;
    DECLARE @NewId   BIGINT        = NULL;   -- ProductionEventId

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.TrimPartial_Record';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @LotId AS LotId, @OperationTemplateId AS OperationTemplateId,
               @ShotCount AS ShotCount, LEFT(@ScrapLinesJson, 2000) AS ScrapLinesJson,
               @ShiftId AS ShiftId, @SourceLocationId AS SourceLocationId,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @FromLocationId BIGINT;
    DECLARE @ItemId         BIGINT;
    DECLARE @LotName        NVARCHAR(50);
    DECLARE @LotPieceCount  INT;
    DECLARE @StatusCode     NVARCHAR(20);
    DECLARE @StatusName     NVARCHAR(100);
    DECLARE @Blocks         BIT;
    DECLARE @PrevShot       INT;
    DECLARE @ScrapTotal     INT = 0;
    DECLARE @Scrap TABLE (DefectCodeId BIGINT, Quantity INT);

    BEGIN TRY
        -- ---- 1. Required parameters (ShotCount + ShiftId are required here) ----
        IF @LotId IS NULL OR @OperationTemplateId IS NULL OR @ShotCount IS NULL
           OR @ShiftId IS NULL OR @SourceLocationId IS NULL OR @AppUserId IS NULL
            SET @Message = N'Required parameter missing (LotId, OperationTemplateId, ShotCount, ShiftId, SourceLocationId, AppUserId).';

        -- ---- 2. Scrap lines ----
        IF @Message IS NULL AND @ScrapLinesJson IS NOT NULL AND ISJSON(@ScrapLinesJson) <> 1
            SET @Message = N'ScrapLinesJson is not valid JSON.';

        IF @Message IS NULL AND @ScrapLinesJson IS NOT NULL
        BEGIN
            INSERT INTO @Scrap (DefectCodeId, Quantity)
            SELECT j.defectCodeId, j.quantity
            FROM OPENJSON(@ScrapLinesJson)
                 WITH (defectCodeId BIGINT N'$.defectCodeId', quantity INT N'$.quantity') j;
            SET @ScrapTotal = ISNULL((SELECT SUM(Quantity) FROM @Scrap), 0);
        END

        IF @Message IS NULL AND EXISTS (SELECT 1 FROM @Scrap WHERE Quantity IS NULL OR Quantity <= 0)
            SET @Message = N'Each scrap line quantity must be positive.';

        IF @Message IS NULL AND EXISTS (
            SELECT 1 FROM @Scrap s
            WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode dc
                              WHERE dc.Id = s.DefectCodeId AND dc.DeprecatedAt IS NULL))
            SET @Message = N'One or more scrap defect codes are invalid or deprecated.';

        -- ---- 3. Template ----
        IF @Message IS NULL AND NOT EXISTS (SELECT 1 FROM Parts.OperationTemplate
                                            WHERE Id = @OperationTemplateId AND DeprecatedAt IS NULL)
            SET @Message = N'OperationTemplate not found or deprecated.';

        -- ---- 4. LOT existence + not-blocked (mirror of TrimOut_Record step 3) ----
        IF @Message IS NULL
            SELECT @FromLocationId = l.CurrentLocationId,
                   @ItemId         = l.ItemId,
                   @LotName        = l.LotName,
                   @LotPieceCount  = l.PieceCount,
                   @StatusCode     = sc.Code,
                   @StatusName     = sc.Name,
                   @Blocks         = sc.BlocksProduction
            FROM Lots.Lot l
            INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
            WHERE l.Id = @LotId;

        IF @Message IS NULL AND @StatusCode IS NULL
            SET @Message = N'LOT not found.';

        IF @Message IS NULL AND (@Blocks = 1 OR @StatusCode IN (N'Closed', N'Open'))
            SET @Message = N'LOT is ' + @StatusName + N' (status ' + @StatusCode + N') and cannot record a partial trim.';

        -- ---- 5. The LOT is checked in at this trim zone (mirror of TrimOut step 3b) ----
        IF @Message IS NULL AND NOT EXISTS (
            SELECT 1 FROM Location.ufn_AncestorLocationIds(@FromLocationId)
            WHERE LocationId = @SourceLocationId)
            SET @Message = N'LOT is not at this Trim station (currently at '
                         + ISNULL((SELECT Name FROM Location.Location WHERE Id = @FromLocationId), N'an unknown location')
                         + N').';

        -- ---- 6. Shift ----
        IF @Message IS NULL AND NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE Id = @ShiftId)
            SET @Message = N'Shift not found.';

        -- ---- 7. Counts ----
        IF @Message IS NULL AND @ShotCount < 0
            SET @Message = N'Trimmed count cannot be negative.';

        IF @Message IS NULL AND (@ShotCount + @ScrapTotal) > @LotPieceCount
            SET @Message = N'Trimmed ' + CAST(@ShotCount AS NVARCHAR(20))
                         + N' + scrap ' + CAST(@ScrapTotal AS NVARCHAR(20))
                         + N' exceeds the LOT piece count ' + CAST(@LotPieceCount AS NVARCHAR(20)) + N'.';

        -- ---- 8. Cumulative: never below the LOT's last TRIM checkpoint ----
        IF @Message IS NULL
            SELECT TOP 1 @PrevShot = pe.ShotCount
            FROM Workorder.ProductionEvent pe
            INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
            INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
            WHERE pe.LotId = @LotId AND pe.ShotCount IS NOT NULL
              AND oty.Code IN (N'TrimIn', N'TrimOut')
            ORDER BY pe.EventAt DESC, pe.Id DESC;

        IF @Message IS NULL AND @PrevShot IS NOT NULL AND @ShotCount < @PrevShot
            SET @Message = N'Trimmed so far (' + CAST(@ShotCount AS NVARCHAR(20))
                         + N') is less than the ' + CAST(@PrevShot AS NVARCHAR(20))
                         + N' already recorded on this LOT.';

        -- ---- 9. Nothing to record ----
        IF @Message IS NULL AND @ShotCount = ISNULL(@PrevShot, 0) AND @ScrapTotal = 0
            SET @Message = N'Nothing to record: no pieces trimmed since the last count and no scrap.';

        -- ---- single rejection exit (no transaction open) ----
        IF @Message IS NOT NULL
        BEGIN
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                    @EntityId = @LotId, @LogEventTypeCode = N'TrimCheckpointRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        DECLARE @ShiftLabel NVARCHAR(200) = (
            SELECT ss.Name + N' ' + FORMAT(s.ActualStart, N'MM-dd')
            FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
            WHERE s.Id = @ShiftId);

        BEGIN TRANSACTION;

        -- (a) the checkpoint (mirror of the Trim OUT inline insert, + ShiftId)
        INSERT INTO Workorder.ProductionEvent (
            LotId, OperationTemplateId, WorkOrderOperationId, EventAt,
            ShotCount, ScrapCount, ScrapSourceId,
            WeightValue, WeightUomId, AppUserId, TerminalLocationId, Remarks, ShiftId
        )
        VALUES (
            @LotId, @OperationTemplateId, NULL, SYSUTCDATETIME(),
            @ShotCount, @ScrapTotal, NULL,
            NULL, NULL, @AppUserId, @TerminalLocationId, N'Partial trim - shift end', @ShiftId
        );
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- (b) scrap rows, stamped with their own identity + the picked shift
        IF EXISTS (SELECT 1 FROM @Scrap)
            INSERT INTO Workorder.RejectEvent
                (ProductionEventId, LotId, ItemId, CellLocationId, ShiftId, DefectCodeId, Quantity,
                 ChargeToArea, Remarks, AppUserId, TerminalLocationId, RecordedAt)
            SELECT NULL, @LotId, @ItemId, @SourceLocationId, @ShiftId, s.DefectCodeId, s.Quantity,
                   NULL, N'Trim partial scrap', @AppUserId, @TerminalLocationId, SYSUTCDATETIME()
            FROM @Scrap s;

        -- (c) scrap comes out of the LOT (mirror of the Trim OUT decrement; never negative, guard 7)
        IF @ScrapTotal > 0
            UPDATE Lots.Lot
            SET PieceCount         = PieceCount - @ScrapTotal,
                InventoryAvailable = InventoryAvailable - @ScrapTotal,
                UpdatedAt          = SYSUTCDATETIME(),
                UpdatedByUserId    = @AppUserId
            WHERE Id = @LotId;

        -- (d) audit
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
            @LotName + N' ' + Audit.ufn_MidDot() + N' Trim ' + Audit.ufn_MidDot()
            + N' Partial ' + CAST(@ShotCount AS NVARCHAR(20)) + N' trimmed, '
            + CAST(@ScrapTotal AS NVARCHAR(20)) + N' scrap (' + ISNULL(@ShiftLabel, N'shift ?') + N')');

        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT
                pe.Id, pe.ShotCount, pe.ScrapCount,
                JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                            FROM Lots.Lot l WHERE l.Id = pe.LotId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                JSON_QUERY((SELECT s.Id, ss.Name AS Code, @ShiftLabel AS Name
                            FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
                            WHERE s.Id = pe.ShiftId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Shift,
                JSON_QUERY((SELECT ot.Id, ot.Code, ot.Name
                            FROM Parts.OperationTemplate ot WHERE ot.Id = pe.OperationTemplateId
                            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS OperationTemplate
            FROM Workorder.ProductionEvent pe WHERE pe.Id = @NewId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId          = @AppUserId,
            @TerminalLocationId = @TerminalLocationId,
            @LocationId         = @FromLocationId,
            @LogEntityTypeCode  = N'ProductionEvent',
            @EntityId           = @NewId,
            @LogEventTypeCode   = N'TrimCheckpointRecorded',
            @LogSeverityCode    = N'Info',
            @Description        = @Activity,
            @OldValue           = NULL,
            @NewValue           = @NewValue;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Partial trim recorded: ' + CAST(@ShotCount AS NVARCHAR(20))
                     + N' trimmed so far on ' + @LotName + N'.';
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

        BEGIN TRY
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'ProductionEvent',
                @EntityId = @LotId, @LogEventTypeCode = N'TrimCheckpointRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
        RAISERROR(@ErrMsg, @ErrSev, @ErrState);
    END CATCH
END;
GO
