-- ============================================================
-- Repeatable:  R__Workorder_RejectEvent_RecordByPartFifo.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-06
-- Version:     1.0
-- Description: Scrap by PART at a line, consumed FIFO. The Scrap Entry popup
--              on the Assembly + Machining terminals names a part and a
--              quantity; this proc charges that quantity to the part's LOTs at
--              @LocationId, oldest arrival first, spilling into the next LOT
--              when one runs out. ONE Workorder.RejectEvent row + ONE audit op
--              per LOT touched, all in one transaction. A LOT driven to zero
--              pieces is closed in the same transaction.
--
--              Stock predicate -- IDENTICAL to
--              Lots.Lot_GetScrappablePartsByLocation; the two MUST change
--              together:
--                * Lot.CurrentLocationId = @LocationId, Lot.ItemId = @ItemId
--                * LotStatusCode = 'Good' (held LOTs are skipped, never
--                  scrapped FIFO)
--                * per-LOT quantity = the lesser of PieceCount and
--                  InventoryAvailable, > 0
--              FIFO order = latest LotMovement into @LocationId (falling back
--              to Lot.CreatedAt), then Lot.Id -- the same order as
--              Lots.Lot_GetLineInventoryByPart.
--
--              SHORT = REFUSE. When @Quantity exceeds the part's scrappable
--              total NOTHING is recorded. The popup offers "submit Y instead";
--              that is a convenience, this is the guard.
--
--              Subtractive scrap only. An operation whose scrap is additive
--              (die cast, Parts.OperationType.ScrapIsAdditive = 1) is refused:
--              that scrap is a fact about a cavity and goes through
--              Workorder.RejectEvent_Record.
--
--              The per-LOT block (reject insert, B5 decrement, reject audit,
--              close-at-zero) is an INLINED mirror of
--              Workorder.RejectEvent_Record -- source of truth
--              R__Workorder_RejectEvent_Record.sql. Inlined, not EXEC'd, per
--              the INSERT-EXEC / single-result-set rule (FDS-11-011). All
--              rejecting validations run BEFORE BEGIN TRANSACTION (Msg 3915);
--              the CATCH is the only ROLLBACK site.
--
--              @TerminalLocationId is audit-only. @NewId is the FIRST
--              RejectEvent row written (the oldest LOT's).
--              Single terminal row: Status, Message, NewId. @Status BIT.
-- ============================================================

CREATE OR ALTER PROCEDURE Workorder.RejectEvent_RecordByPartFifo
    @ItemId              BIGINT,
    @LocationId          BIGINT,
    @DefectCodeId        BIGINT,
    @Quantity            INT,
    @Remarks             NVARCHAR(500)  = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT         = NULL,  -- audit-only
    @OperationTypeCode   NVARCHAR(20)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Workorder.RejectEvent_RecordByPartFifo';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ItemId AS ItemId, @LocationId AS LocationId, @DefectCodeId AS DefectCodeId,
               @Quantity AS Quantity, @AppUserId AS AppUserId,
               @TerminalLocationId AS TerminalLocationId, @OperationTypeCode AS OperationTypeCode
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @GoodStatusId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');

    DECLARE @Additive BIT = ISNULL(
        (SELECT ScrapIsAdditive FROM Parts.OperationType WHERE Code = @OperationTypeCode), 0);

    DECLARE @PartNumber NVARCHAR(50);
    DECLARE @Available  INT;

    -- The FIFO plan: one row per LOT the scrap will touch, in consumption order.
    DECLARE @Alloc TABLE (
        Seq           INT IDENTITY(1,1) PRIMARY KEY,
        LotId         BIGINT        NOT NULL,
        LotName       NVARCHAR(50)  NOT NULL,
        ToolId        BIGINT        NULL,
        Take          INT           NOT NULL
    );

    BEGIN TRY
        -- ---- 1. Required parameters ----
        IF @ItemId IS NULL OR @LocationId IS NULL OR @DefectCodeId IS NULL
           OR @Quantity IS NULL OR @AppUserId IS NULL
        BEGIN
            SET @Message = N'Required parameter missing (ItemId, LocationId, DefectCodeId, Quantity, AppUserId).';
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                    @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 2. FK resolution ----
        IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
        BEGIN
            SET @Message = N'AppUser not found.';
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 3. Quantity sanity ----
        IF @Quantity <= 0
        BEGIN
            SET @Message = N'Quantity must be greater than zero.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 4. Subtractive only ----
        IF @Additive = 1
        BEGIN
            SET @Message = N'Scrap at this operation is recorded against a cavity, not consumed from line inventory.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        SELECT @PartNumber = PartNumber FROM Parts.Item WHERE Id = @ItemId;
        IF @PartNumber IS NULL
        BEGIN
            SET @Message = N'Part not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Id = @LocationId)
        BEGIN
            SET @Message = N'Location not found.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Id = @DefectCodeId AND DeprecatedAt IS NULL)
        BEGIN
            SET @Message = N'DefectCode not found or deprecated.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ---- 5. Enough scrappable stock (SHORT = REFUSE) ----
        -- Stock predicate: mirror of Lots.Lot_GetScrappablePartsByLocation.
        SELECT @Available = ISNULL(SUM(CASE WHEN l.PieceCount < l.InventoryAvailable
                                            THEN l.PieceCount ELSE l.InventoryAvailable END), 0)
        FROM Lots.Lot l
        WHERE l.CurrentLocationId = @LocationId
          AND l.ItemId = @ItemId
          AND l.LotStatusId = @GoodStatusId
          AND l.PieceCount > 0
          AND l.InventoryAvailable > 0;

        IF @Quantity > @Available
        BEGIN
            SET @Message = N'Only ' + CAST(@Available AS NVARCHAR(20)) + N' of ' + @PartNumber
                         + N' on hand at this line; ' + CAST(@Quantity - @Available AS NVARCHAR(20))
                         + N' short. Nothing was recorded.';
            EXEC Audit.Audit_LogFailure
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
                @FailureReason = @Message, @ProcedureName = @ProcName,
                @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- Build the FIFO plan under UPDLOCK/HOLDLOCK on the part's LOT rows, so
        -- the quantities planned here are the quantities decremented below.
        ;WITH LastArrival AS (
            SELECT m.LotId, MAX(m.MovedAt) AS ArrivedAtUtc
            FROM Lots.LotMovement m
            WHERE m.ToLocationId = @LocationId
            GROUP BY m.LotId
        ),
        Stock AS (
            SELECT l.Id AS LotId, l.LotName, l.ToolId,
                   CASE WHEN l.PieceCount < l.InventoryAvailable
                        THEN l.PieceCount ELSE l.InventoryAvailable END AS Avail,
                   COALESCE(la.ArrivedAtUtc, l.CreatedAt)               AS ArrivedAtUtc
            FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
            LEFT JOIN LastArrival la ON la.LotId = l.Id
            WHERE l.CurrentLocationId = @LocationId
              AND l.ItemId = @ItemId
              AND l.LotStatusId = @GoodStatusId
              AND l.PieceCount > 0
              AND l.InventoryAvailable > 0
        ),
        Running AS (
            SELECT s.*,
                   SUM(s.Avail) OVER (ORDER BY s.ArrivedAtUtc, s.LotId
                                      ROWS UNBOUNDED PRECEDING) - s.Avail AS TakenBefore
            FROM Stock s
        )
        INSERT INTO @Alloc (LotId, LotName, ToolId, Take)
        SELECT r.LotId, r.LotName, r.ToolId,
               CASE WHEN r.TakenBefore + r.Avail <= @Quantity
                    THEN r.Avail ELSE @Quantity - r.TakenBefore END
        FROM Running r
        WHERE r.TakenBefore < @Quantity
        ORDER BY r.ArrivedAtUtc, r.LotId;

        -- Concurrency guard (TOCTOU): step 5 read the total UNLOCKED. Re-check
        -- under the lock. RAISERROR -> CATCH (the only legal ROLLBACK site).
        IF ISNULL((SELECT SUM(Take) FROM @Alloc), 0) <> @Quantity
            RAISERROR(N'Line inventory changed while the scrap was being recorded. Reload and retry.', 16, 1);

        DECLARE @DefCode NVARCHAR(50) = (SELECT Code FROM Quality.DefectCode WHERE Id = @DefectCodeId);

        DECLARE @Seq INT = 1, @MaxSeq INT = (SELECT MAX(Seq) FROM @Alloc);
        DECLARE @LotCount INT = @MaxSeq, @ClosedCount INT = 0;
        DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @ToolId BIGINT, @Take INT;
        DECLARE @RejectId BIGINT, @NewPieceCount INT;
        DECLARE @ActivityRaw NVARCHAR(MAX), @Activity NVARCHAR(500), @NewValue NVARCHAR(MAX);
        DECLARE @CloseOld NVARCHAR(MAX), @CloseNew NVARCHAR(MAX);
        DECLARE @CloseRaw NVARCHAR(MAX), @CloseActivity NVARCHAR(500);

        WHILE @Seq <= @MaxSeq
        BEGIN
            SELECT @LotId = LotId, @LotName = LotName, @ToolId = ToolId, @Take = Take
            FROM @Alloc WHERE Seq = @Seq;

            -- ----- Reject row (mirror of RejectEvent_Record; identity STAMPED) -----
            INSERT INTO Workorder.RejectEvent (
                ProductionEventId, LotId, DefectCodeId, Quantity,
                ChargeToArea, Remarks, AppUserId, RecordedAt,
                ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId
            )
            VALUES (
                NULL, @LotId, @DefectCodeId, @Take,
                NULL, @Remarks, @AppUserId, SYSUTCDATETIME(),
                @ItemId, @ToolId, NULL, NULL, NULL
            );
            SET @RejectId = CAST(SCOPE_IDENTITY() AS BIGINT);
            IF @NewId IS NULL SET @NewId = @RejectId;

            -- ----- D3 decrement of the materialized B5 quantities -----
            UPDATE l
            SET @NewPieceCount      = l.PieceCount - @Take,
                l.PieceCount        = l.PieceCount - @Take,
                l.InventoryAvailable= l.InventoryAvailable - @Take,
                l.UpdatedAt         = SYSUTCDATETIME(),
                l.UpdatedByUserId   = @AppUserId
            FROM Lots.Lot l
            WHERE l.Id = @LotId;

            -- ----- Reject audit -----
            SET @ActivityRaw =
                @LotName + N' ' + Audit.ufn_MidDot() + N' Reject ' + Audit.ufn_MidDot()
                + N' ' + CAST(@Take AS NVARCHAR(20)) + N' pcs (' + ISNULL(@DefCode, N'?') + N')'
                + N'; remaining ' + CAST(@NewPieceCount AS NVARCHAR(20))
                + CASE WHEN @LotCount > 1
                       THEN N'; FIFO ' + CAST(@Seq AS NVARCHAR(10)) + N' of ' + CAST(@LotCount AS NVARCHAR(10))
                            + N' for ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs of ' + @PartNumber
                       ELSE N'' END;
            SET @Activity = Audit.ufn_TruncateActivity(@ActivityRaw);

            SET @NewValue = (
                SELECT
                    re.Id, re.Quantity,
                    JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name
                                FROM Lots.Lot l WHERE l.Id = re.LotId
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                    JSON_QUERY((SELECT dc.Id, dc.Code, dc.Description AS Name
                                FROM Quality.DefectCode dc WHERE dc.Id = re.DefectCodeId
                                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DefectCode
                FROM Workorder.RejectEvent re WHERE re.Id = @RejectId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC Audit.Audit_LogOperation
                @AppUserId          = @AppUserId,
                @TerminalLocationId = @TerminalLocationId,
                @LocationId         = NULL,
                @LogEntityTypeCode  = N'RejectEvent',
                @EntityId           = @RejectId,
                @LogEventTypeCode   = N'RejectEventRecorded',
                @LogSeverityCode    = N'Info',
                @Description        = @Activity,
                @OldValue           = NULL,
                @NewValue           = @NewValue;

            -- ----- D3 close-at-zero (mirror of Lots.Lot_UpdateStatus Good->Closed) -----
            IF @NewPieceCount = 0
            BEGIN
                UPDATE Lots.Lot
                SET LotStatusId     = @ClosedStatusId,
                    UpdatedAt       = SYSUTCDATETIME(),
                    UpdatedByUserId = @AppUserId
                WHERE Id = @LotId;

                INSERT INTO Lots.LotStatusHistory
                    (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                VALUES
                    (@LotId, @GoodStatusId, @ClosedStatusId,
                     N'Closed automatically: all pieces rejected.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

                SET @CloseOld = (
                    SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @GoodStatusId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                SET @CloseNew = (
                    SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ClosedStatusId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

                SET @CloseRaw =
                    @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
                    + N' Good' + NCHAR(8594) + N'Closed (all pieces rejected)';
                SET @CloseActivity = Audit.ufn_TruncateActivity(@CloseRaw);

                EXEC Audit.Audit_LogOperation
                    @AppUserId          = @AppUserId,
                    @TerminalLocationId = @TerminalLocationId,
                    @LocationId         = NULL,
                    @LogEntityTypeCode  = N'Lot',
                    @EntityId           = @LotId,
                    @LogEventTypeCode   = N'LotStatusChanged',
                    @LogSeverityCode    = N'Info',
                    @Description        = @CloseActivity,
                    @OldValue           = @CloseOld,
                    @NewValue           = @CloseNew;

                SET @ClosedCount += 1;
            END

            SET @Seq += 1;
        END

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Scrap recorded: ' + CAST(@Quantity AS NVARCHAR(20)) + N' pcs of ' + @PartNumber
                     + N' from ' + CAST(@LotCount AS NVARCHAR(10))
                     + CASE WHEN @LotCount = 1 THEN N' LOT' ELSE N' LOTs' END
                     + CASE WHEN @ClosedCount > 0
                            THEN N' (' + CAST(@ClosedCount AS NVARCHAR(10)) + N' closed at zero)'
                            ELSE N'' END
                     + N'.';
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
                @AppUserId = @AppUserId, @LogEntityTypeCode = N'RejectEvent',
                @EntityId = NULL, @LogEventTypeCode = N'RejectEventRecorded',
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
