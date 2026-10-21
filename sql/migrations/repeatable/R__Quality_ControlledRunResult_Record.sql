-- ============================================================
-- Repeatable:  R__Quality_ControlledRunResult_Record.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-21
-- Version:     1.4
-- Change Log:  2026-10-19 - 1.1 - 'Rework' is no longer a recordable outcome (piece 5): rework is the LOT's
--              move back into trim, and an open rework blocks release. The Rework disposition
--              code and ReworkQty column stay for history.
--              2026-10-19 - 1.2 - ReturnToSupplier on a LOT member is APPLIED when recorded (piece 5,
--              spec 5.4): inlined mirror of Lots.VendorReturn_Mark writes the Lots.VendorReturn
--              row pointing at the entry. Refused on a container member, a non-received LOT,
--              a Closed / Scrap / Open LOT, and when scrap + return exceed the LOT's pieces.
--              2026-10-20 - 1.3 - Final review: the origin + status refusal for ReturnToSupplier
--              on a LOT member reads Lots.ufn_LotReturnableToVendor (the one rule, same text as
--              VendorReturn_Mark). Per entry, origin is reported before status.
--              2026-10-21 - 1.4 - Piece 6: each entry writes 'Result recorded . <outcome> <qty>
--              [(<defect>)]' onto its member's LOT(s) (ControlledRunLotResult; a container
--              entry goes onto each tray, naming the container, so it never reads as each
--              tray losing the quantity).
-- Description: Records what the Controlled Run inspection found, as one or more
--              ENTRIES against members of an OPEN super-lot. One call may carry
--              many members (the screen sends one member's entries; "mark the
--              rest as all accepted" sends many). All or nothing.
--
--              @ResultsJson: [{"memberId":n, "dispositionCode":"Accepted" |
--              "Scrap" | "ReturnToSupplier" | "UseAsIs",
--              "quantity":n, "defectCodeId":n|null, "remarks":"..."|null}, ...]
--
--              What an entry DOES depends on the outcome and the member:
--                * Scrap on a LOT member is REAL. One Workorder.RejectEvent per
--                  entry; the LOT is decremented and, if it was Good and reaches
--                  zero, closed -- with the same audit rows the line's scrap
--                  writes. The block is an INLINED MIRROR of the subtractive path
--                  of Workorder.RejectEvent_Record (source of truth:
--                  R__Workorder_RejectEvent_Record.sql); it cannot EXEC that proc
--                  because both return a status row (FDS-11-011). A LOT on a
--                  real hold is scrapped in place (that proc's @AllowHeldLot = 1
--                  behaviour); a Closed, Scrap or Open LOT is refused. No
--                  operation type applies to an inspection, so the scrap is
--                  subtractive (additive scrap is die-cast only).
--                * Scrap on a CONTAINER member is RECORDED ONLY (RejectEventId
--                  stays NULL). Which tray the part came out of, and taking it
--                  out, belongs to the container-repack piece.
--                * ReturnToSupplier on a LOT member is REAL as well (piece 5). One
--                  Lots.VendorReturn per entry, pointing at the entry
--                  (ControlledRunResultId); the quantity leaves the LOT now
--                  (PieceCount and InventoryAvailable together) and a Good LOT
--                  that reaches zero closes. The block is an INLINED MIRROR of
--                  Lots.VendorReturn_Mark (source of truth:
--                  R__Lots_VendorReturn_Mark.sql), for the same FDS-11-011
--                  reason. Only Received / ReceivedOffsite LOTs may be returned;
--                  a container member may not (refused). Cancelling the return
--                  (Lots.VendorReturn_Cancel) voids the entry.
--                * Accepted and UseAsIs are counts.
--
--              Quantities need not add up to the member's piece count (spec D3).
--              A scrap total, or a scrap + return total, above what a LOT holds is
--              refused, because that would drive a real quantity negative.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Returns Status, Message, NewId (the first entry).
--              Spec: docs/superpowers/specs/
--              2026-10-12-controlled-run-results-and-signoff-design.md s5.1
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRunResult_Record
    @ControlledRunId    BIGINT,
    @ResultsJson        NVARCHAR(MAX),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRunResult_Record';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @ControlledRunId AS ControlledRunId, LEFT(@ResultsJson, 3000) AS ResultsJson,
               @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunNumber NVARCHAR(15), @RunStatusId BIGINT;
    SELECT @RunNumber = RunNumber, @RunStatusId = ControlledRunStatusId
    FROM Quality.ControlledRun WHERE Id = @ControlledRunId;

    DECLARE @GoodStatusId   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
    DECLARE @ClosedStatusId BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed');

    -- ---- the entries, resolved once ----
    DECLARE @E TABLE (
        Seq INT IDENTITY(1,1) PRIMARY KEY,
        MemberId BIGINT NULL, DispositionCode NVARCHAR(30) NULL, Quantity INT NULL,
        DefectCodeId BIGINT NULL, Remarks NVARCHAR(500) NULL,
        DispositionCodeId BIGINT NULL, IsMember BIT NOT NULL DEFAULT (0),
        LotId BIGINT NULL, ContainerId BIGINT NULL, DisplayName NVARCHAR(60) NULL,
        LotStatusCode NVARCHAR(20) NULL, LotStatusName NVARCHAR(100) NULL, LotPieces INT NULL,
        LotOriginCode NVARCHAR(50) NULL,
        DefectOk BIT NOT NULL DEFAULT (0), RejectEventId BIGINT NULL, ResultId BIGINT NULL);

    INSERT INTO @E (MemberId, DispositionCode, Quantity, DefectCodeId, Remarks)
    SELECT TRY_CAST(JSON_VALUE(j.value, N'$.memberId') AS BIGINT),
           LEFT(JSON_VALUE(j.value, N'$.dispositionCode'), 30),
           TRY_CAST(JSON_VALUE(j.value, N'$.quantity') AS INT),
           TRY_CAST(JSON_VALUE(j.value, N'$.defectCodeId') AS BIGINT),
           NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(j.value, N'$.remarks'), 500))), N'')
    FROM OPENJSON(CASE WHEN ISJSON(@ResultsJson) = 1 THEN @ResultsJson ELSE N'[]' END) j
    ORDER BY CAST(j.[key] AS INT);

    UPDATE e
    SET DispositionCodeId = dc.Id,
        IsMember      = CASE WHEN ms.MemberId IS NOT NULL THEN 1 ELSE 0 END,
        LotId         = ms.LotId,
        ContainerId   = ms.ContainerId,
        DisplayName   = ms.DisplayName,
        LotStatusCode = ls.Code,
        LotStatusName = ls.Name,
        LotPieces     = l.PieceCount,
        LotOriginCode = lo.Code,
        DefectOk      = CASE WHEN df.Id IS NOT NULL THEN 1 ELSE 0 END
    FROM @E e
    LEFT JOIN Quality.DispositionCode dc ON dc.Code = e.DispositionCode
    LEFT JOIN Quality.ufn_ControlledRunMemberState(@ControlledRunId) ms
           ON ms.MemberId = e.MemberId AND ms.EndedAt IS NULL
    LEFT JOIN Lots.Lot l            ON l.Id = ms.LotId
    LEFT JOIN Lots.LotStatusCode ls ON ls.Id = l.LotStatusId
    LEFT JOIN Lots.LotOriginType lo ON lo.Id = l.LotOriginTypeId
    LEFT JOIN Quality.DefectCode df ON df.Id = e.DefectCodeId AND df.DeprecatedAt IS NULL;

    DECLARE @EntryCount INT = (SELECT COUNT(*) FROM @E);

    BEGIN TRY
        -- ---- Validations: the FIRST rule that fails is the message. All of them
        --      run before BEGIN TRANSACTION (Msg 3915 rule). ----
        DECLARE @Reject NVARCHAR(500) = NULL;

        IF @ControlledRunId IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (ControlledRunId, AppUserId).';
        IF @Reject IS NULL AND NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND DeprecatedAt IS NULL)
            SET @Reject = N'User not found.';
        IF @Reject IS NULL AND @RunNumber IS NULL
            SET @Reject = N'Super-lot not found.';
        IF @Reject IS NULL AND @RunStatusId <> 1
            SET @Reject = N'Super-lot ' + @RunNumber + N' is not open.';
        IF @Reject IS NULL AND @EntryCount = 0
            SET @Reject = N'No results to record.';
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = N'Entry ' + CAST(e.Seq AS NVARCHAR(10)) + N' is not a current member of super-lot ' + @RunNumber + N'.'
            FROM @E e WHERE e.IsMember = 0 ORDER BY e.Seq;
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = e.DisplayName + N': unknown outcome ''' + ISNULL(e.DispositionCode, N'') + N'''.'
            FROM @E e WHERE e.DispositionCodeId IS NULL ORDER BY e.Seq;
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = e.DisplayName + N': rework is recorded by moving the LOT back into trim, not as a result.'
            FROM @E e WHERE (e.DispositionCode = N'Rework') ORDER BY e.Seq;
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = e.DisplayName + N': quantity must be greater than zero.'
            FROM @E e WHERE e.Quantity IS NULL OR e.Quantity <= 0 ORDER BY e.Seq;
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = e.DisplayName + N': scrap needs a defect reason.'
            FROM @E e WHERE e.DispositionCode = N'Scrap' AND e.DefectOk = 0 ORDER BY e.Seq;
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = e.DisplayName + N': defect reason not found or deprecated.'
            FROM @E e WHERE e.DefectCodeId IS NOT NULL AND e.DefectOk = 0 ORDER BY e.Seq;
        -- Scrap on a LOT member is real: mirror of RejectEvent_Record's status guard
        -- with @AllowHeldLot = 1 (Hold passes; Scrap / Closed / Open do not).
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = e.DisplayName + N' is ' + e.LotStatusName + N' and cannot be scrapped.'
            FROM @E e
            WHERE e.DispositionCode = N'Scrap' AND e.LotId IS NOT NULL
              AND e.LotStatusCode IN (N'Scrap', N'Closed', N'Open')
            ORDER BY e.Seq;
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = x.DisplayName + N': scrap of ' + CAST(x.Total AS NVARCHAR(10))
                                 + N' is more than the ' + CAST(x.LotPieces AS NVARCHAR(10)) + N' pieces it holds.'
            FROM (SELECT e.LotId, MAX(e.DisplayName) AS DisplayName, MAX(e.LotPieces) AS LotPieces, SUM(e.Quantity) AS Total
                  FROM @E e WHERE e.DispositionCode = N'Scrap' AND e.LotId IS NOT NULL
                  GROUP BY e.LotId) x
            WHERE x.Total > x.LotPieces
            ORDER BY x.LotId;
        -- Return to vendor (piece 5): mirror of Lots.VendorReturn_Mark's guards, plus
        -- the container refusal (a container is not a received LOT).
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = e.DisplayName + N': a container cannot be returned to a vendor.'
            FROM @E e WHERE (e.DispositionCode = N'ReturnToSupplier') AND (e.ContainerId IS NOT NULL) ORDER BY e.Seq;
        -- Origin + status: the shared rule (Lots.ufn_LotReturnableToVendor), whose
        -- Reason is the same refusal text Lots.VendorReturn_Mark gives.
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = rv.Reason
            FROM @E e
            CROSS APPLY Lots.ufn_LotReturnableToVendor(e.LotId) rv
            WHERE (e.DispositionCode = N'ReturnToSupplier') AND (e.LotId IS NOT NULL)
              AND (rv.CanReturnToVendor = 0)
            ORDER BY e.Seq;
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = x.DisplayName + N': ' + CASE WHEN x.ScrapTotal > 0 THEN N'scrap and return of ' ELSE N'return of ' END
                                 + CAST(x.Total AS NVARCHAR(10)) + N' is more than the ' + CAST(x.LotPieces AS NVARCHAR(10)) + N' pieces it holds.'
            FROM (SELECT e.LotId, MAX(e.DisplayName) AS DisplayName, MAX(e.LotPieces) AS LotPieces, SUM(e.Quantity) AS Total,
                         SUM(CASE WHEN e.DispositionCode = N'Scrap' THEN e.Quantity ELSE 0 END) AS ScrapTotal,
                         SUM(CASE WHEN e.DispositionCode = N'ReturnToSupplier' THEN e.Quantity ELSE 0 END) AS ReturnTotal
                  FROM @E e WHERE (e.DispositionCode IN (N'Scrap', N'ReturnToSupplier')) AND (e.LotId IS NOT NULL)
                  GROUP BY e.LotId) x
            WHERE (x.ReturnTotal > 0) AND (x.Total > x.LotPieces)
            ORDER BY x.LotId;

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @ControlledRunId, @LogEventTypeCode = N'ControlledRunResultRecorded',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- Scrap on LOT members. INLINED MIRROR of Workorder.RejectEvent_Record's
        --      subtractive path: reject row, decrement under UPDLOCK/HOLDLOCK, TOCTOU
        --      re-check, reject audit, close-at-zero when the LOT was Good. ----
        DECLARE @Seq INT, @LotId BIGINT, @Qty INT, @DefectCodeId BIGINT, @Remarks NVARCHAR(500),
                @RejectId BIGINT, @NewPieceCount INT, @CurStatusId BIGINT, @LotName NVARCHAR(50),
                @DefCode NVARCHAR(50), @ActRaw NVARCHAR(MAX), @Act NVARCHAR(500), @NewVal NVARCHAR(MAX),
                @OldVal NVARCHAR(MAX);

        DECLARE scrap_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT e.Seq, e.LotId, e.Quantity, e.DefectCodeId, e.Remarks
            FROM @E e WHERE e.DispositionCode = N'Scrap' AND e.LotId IS NOT NULL ORDER BY e.Seq;
        OPEN scrap_cur;
        FETCH NEXT FROM scrap_cur INTO @Seq, @LotId, @Qty, @DefectCodeId, @Remarks;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            INSERT INTO Workorder.RejectEvent (
                ProductionEventId, LotId, DefectCodeId, Quantity, ChargeToArea, Remarks, AppUserId, RecordedAt,
                ItemId, ToolId, ToolCavityId, ShiftId, CellLocationId, TerminalLocationId)
            SELECT NULL, l.Id, @DefectCodeId, @Qty, NULL, @Remarks, @AppUserId, SYSUTCDATETIME(),
                   l.ItemId, l.ToolId, NULL, NULL, NULL, @TerminalLocationId
            FROM Lots.Lot l WHERE l.Id = @LotId;
            SET @RejectId = CAST(SCOPE_IDENTITY() AS BIGINT);

            UPDATE l
            SET @NewPieceCount       = l.PieceCount - @Qty,
                @CurStatusId         = l.LotStatusId,
                @LotName             = l.LotName,
                l.PieceCount         = l.PieceCount - @Qty,
                l.InventoryAvailable = CASE WHEN l.InventoryAvailable - @Qty < 0 THEN 0 ELSE l.InventoryAvailable - @Qty END,
                l.UpdatedAt          = SYSUTCDATETIME(),
                l.UpdatedByUserId    = @AppUserId
            FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
            WHERE l.Id = @LotId;

            -- TOCTOU: the totals above were read unlocked. Re-check under the lock.
            IF @NewPieceCount < 0
                RAISERROR(N'SUPERLOT_QTY: scrap is more than the LOT now holds.', 16, 1);

            SET @DefCode = (SELECT Code FROM Quality.DefectCode WHERE Id = @DefectCodeId);
            SET @ActRaw  = @LotName + N' ' + Audit.ufn_MidDot() + N' Reject ' + Audit.ufn_MidDot()
                         + N' ' + CAST(@Qty AS NVARCHAR(20)) + N' pcs (' + ISNULL(@DefCode, N'?') + N')'
                         + N'; remaining ' + CAST(@NewPieceCount AS NVARCHAR(20)) + N' (super-lot ' + @RunNumber + N')';
            SET @Act     = Audit.ufn_TruncateActivity(@ActRaw);
            SET @NewVal  = (
                SELECT re.Id, re.Quantity,
                       JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name FROM Lots.Lot l
                                   WHERE l.Id = re.LotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                       JSON_QUERY((SELECT dc.Id, dc.Code, dc.Description AS Name FROM Quality.DefectCode dc
                                   WHERE dc.Id = re.DefectCodeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS DefectCode,
                       JSON_QUERY((SELECT @ControlledRunId AS Id, @RunNumber AS Code, @RunNumber AS Name
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
                FROM Workorder.RejectEvent re WHERE re.Id = @RejectId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC Audit.Audit_LogOperation
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                @LogEntityTypeCode = N'RejectEvent', @EntityId = @RejectId,
                @LogEventTypeCode = N'RejectEventRecorded', @LogSeverityCode = N'Info',
                @Description = @Act, @OldValue = NULL, @NewValue = @NewVal;

            -- Close-at-zero (mirror of Lots.Lot_UpdateStatus Good->Closed). A held LOT
            -- stays held: the hold lifecycle owns its terminal transition.
            IF @NewPieceCount = 0 AND @CurStatusId = @GoodStatusId
            BEGIN
                UPDATE Lots.Lot
                SET LotStatusId = @ClosedStatusId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @LotId;

                INSERT INTO Lots.LotStatusHistory
                    (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                VALUES
                    (@LotId, @CurStatusId, @ClosedStatusId,
                     N'Closed automatically: all pieces rejected.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

                SET @OldVal = (
                    SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @CurStatusId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                SET @NewVal = (
                    SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ClosedStatusId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                SET @ActRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
                            + N' Good' + NCHAR(8594) + N'Closed (all pieces rejected)';
                SET @Act = Audit.ufn_TruncateActivity(@ActRaw);

                EXEC Audit.Audit_LogOperation
                    @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                    @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
                    @LogEventTypeCode = N'LotStatusChanged', @LogSeverityCode = N'Info',
                    @Description = @Act, @OldValue = @OldVal, @NewValue = @NewVal;
            END

            UPDATE @E SET RejectEventId = @RejectId WHERE Seq = @Seq;
            FETCH NEXT FROM scrap_cur INTO @Seq, @LotId, @Qty, @DefectCodeId, @Remarks;
        END
        CLOSE scrap_cur; DEALLOCATE scrap_cur;

        -- ---- the entries themselves ----
        DECLARE @Ins TABLE (Id BIGINT);
        INSERT INTO Quality.ControlledRunResult
            (ControlledRunMemberId, DispositionCodeId, Quantity, DefectCodeId, RejectEventId, Remarks,
             RecordedByUserId, TerminalLocationId)
        OUTPUT inserted.Id INTO @Ins (Id)
        SELECT e.MemberId, e.DispositionCodeId, e.Quantity, e.DefectCodeId, e.RejectEventId, e.Remarks,
               @AppUserId, @TerminalLocationId
        FROM @E e ORDER BY e.Seq;
        SET @NewId = (SELECT MIN(Id) FROM @Ins);

        -- Which row is which entry: an INSERT ... SELECT ... ORDER BY assigns identity
        -- values in ORDER BY order, and @E.Seq is a gapless 1..n, so the k-th smallest
        -- new Id is entry Seq = k. The returns below point their VendorReturn at it.
        UPDATE e SET ResultId = i.Id
        FROM @E e
        INNER JOIN (SELECT Id, ROW_NUMBER() OVER (ORDER BY Id) AS Rn FROM @Ins) i ON i.Rn = e.Seq;

        -- ---- Return to vendor on LOT members. INLINED MIRROR of Lots.VendorReturn_Mark
        --      (source: R__Lots_VendorReturn_Mark.sql): decrement PieceCount and
        --      InventoryAvailable together under UPDLOCK/HOLDLOCK, record what was taken,
        --      TOCTOU re-check, VendorReturnMarked audit on the LOT, close-at-zero when
        --      the LOT was Good. Runs after the entries are inserted because
        --      Lots.VendorReturn.ControlledRunResultId is an FK to them. No RejectEvent:
        --      a return is not scrap. ----
        DECLARE @ResultId BIGINT, @InvTaken INT, @VrId BIGINT;
        DECLARE return_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT e.Seq, e.LotId, e.Quantity, e.Remarks, e.ResultId
            FROM @E e WHERE e.DispositionCode = N'ReturnToSupplier' AND e.LotId IS NOT NULL ORDER BY e.Seq;
        OPEN return_cur;
        FETCH NEXT FROM return_cur INTO @Seq, @LotId, @Qty, @Remarks, @ResultId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            UPDATE l
            SET @NewPieceCount       = l.PieceCount - @Qty,
                @InvTaken            = CASE WHEN l.InventoryAvailable < @Qty THEN l.InventoryAvailable ELSE @Qty END,
                @CurStatusId         = l.LotStatusId,
                @LotName             = l.LotName,
                l.PieceCount         = l.PieceCount - @Qty,
                l.InventoryAvailable = CASE WHEN l.InventoryAvailable - @Qty < 0 THEN 0 ELSE l.InventoryAvailable - @Qty END,
                l.UpdatedAt          = SYSUTCDATETIME(),
                l.UpdatedByUserId    = @AppUserId
            FROM Lots.Lot l WITH (UPDLOCK, HOLDLOCK)
            WHERE l.Id = @LotId;

            -- TOCTOU: the totals above were read unlocked. Re-check under the lock.
            IF @NewPieceCount < 0
                RAISERROR(N'SUPERLOT_QTY: return is more than the LOT now holds.', 16, 1);

            INSERT INTO Lots.VendorReturn
                (LotId, Quantity, PieceCountTaken, InventoryTaken, Remarks, ControlledRunResultId,
                 MarkedByUserId, MarkedAt, TerminalLocationId)
            VALUES
                (@LotId, @Qty, @Qty, @InvTaken, @Remarks, @ResultId,
                 @AppUserId, SYSUTCDATETIME(), @TerminalLocationId);
            SET @VrId = CAST(SCOPE_IDENTITY() AS BIGINT);

            SET @ActRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' Vendor return ' + Audit.ufn_MidDot()
                        + N' Marked ' + CAST(@Qty AS NVARCHAR(20)) + N' pcs; remaining ' + CAST(@NewPieceCount AS NVARCHAR(20))
                        + N' (super-lot ' + @RunNumber + N')';
            SET @Act    = Audit.ufn_TruncateActivity(@ActRaw);
            SET @NewVal = (
                SELECT vr.Id AS VendorReturnId, vr.Quantity, vr.PieceCountTaken, vr.InventoryTaken, vr.Remarks,
                       vr.ControlledRunResultId,
                       JSON_QUERY((SELECT l.Id, l.LotName AS Code, l.LotName AS Name FROM Lots.Lot l
                                   WHERE l.Id = vr.LotId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                       JSON_QUERY((SELECT @ControlledRunId AS Id, @RunNumber AS Code, @RunNumber AS Name
                                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
                FROM Lots.VendorReturn vr WHERE vr.Id = @VrId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC Audit.Audit_LogOperation
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
                @LogEventTypeCode = N'VendorReturnMarked', @LogSeverityCode = N'Info',
                @Description = @Act, @OldValue = NULL, @NewValue = @NewVal;

            -- Close-at-zero (mirror of Lots.VendorReturn_Mark / Lots.Lot_UpdateStatus
            -- Good->Closed). A held LOT stays held.
            IF @NewPieceCount = 0 AND @CurStatusId = @GoodStatusId
            BEGIN
                UPDATE Lots.Lot
                SET LotStatusId = @ClosedStatusId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
                WHERE Id = @LotId;

                INSERT INTO Lots.LotStatusHistory
                    (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
                VALUES
                    (@LotId, @CurStatusId, @ClosedStatusId,
                     N'Closed automatically: all pieces returned to the vendor.', @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

                SET @OldVal = (
                    SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @CurStatusId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                SET @NewVal = (
                    SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ClosedStatusId
                                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
                SET @ActRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
                            + N' Good' + NCHAR(8594) + N'Closed (all pieces returned to vendor)';
                SET @Act = Audit.ufn_TruncateActivity(@ActRaw);

                EXEC Audit.Audit_LogOperation
                    @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                    @LogEntityTypeCode = N'Lot', @EntityId = @LotId,
                    @LogEventTypeCode = N'LotStatusChanged', @LogSeverityCode = N'Info',
                    @Description = @Act, @OldValue = @OldVal, @NewValue = @NewVal;
            END

            FETCH NEXT FROM return_cur INTO @Seq, @LotId, @Qty, @Remarks, @ResultId;
        END
        CLOSE return_cur; DEALLOCATE return_cur;

        DECLARE @MemberCount INT = (SELECT COUNT(DISTINCT MemberId) FROM @E);
        DECLARE @Pieces INT      = (SELECT SUM(Quantity) FROM @E);
        DECLARE @Scrapped INT    = ISNULL((SELECT SUM(Quantity) FROM @E WHERE RejectEventId IS NOT NULL), 0);
        DECLARE @Returned INT    = ISNULL((SELECT SUM(Quantity) FROM @E WHERE DispositionCode = N'ReturnToSupplier' AND LotId IS NOT NULL), 0);

        SET @ActRaw = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Results ' + Audit.ufn_MidDot()
                    + N' + ' + CAST(@EntryCount AS NVARCHAR(10)) + N' entries on '
                    + CAST(@MemberCount AS NVARCHAR(10)) + N' members, ' + CAST(@Pieces AS NVARCHAR(10)) + N' pcs'
                    + CASE WHEN @Scrapped > 0 THEN N' (' + CAST(@Scrapped AS NVARCHAR(10)) + N' scrapped off LOTs)' ELSE N'' END
                    + CASE WHEN @Returned > 0 THEN N' (' + CAST(@Returned AS NVARCHAR(10)) + N' marked for return)' ELSE N'' END;
        SET @Act = Audit.ufn_TruncateActivity(@ActRaw);
        SET @NewVal = (
            SELECT @EntryCount AS EntryCount, @MemberCount AS MemberCount, @Pieces AS Pieces, @Scrapped AS ScrappedOffLots,
                   @Returned AS ReturnedOffLots,
                   JSON_QUERY((SELECT @ControlledRunId AS Id, @RunNumber AS Code, @RunNumber AS Name
                               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun,
                   JSON_QUERY((SELECT TOP 40 e.DisplayName AS Member, e.DispositionCode AS Outcome, e.Quantity
                               FROM @E e ORDER BY e.Seq FOR JSON PATH)) AS Entries
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ControlledRun', @EntityId = @ControlledRunId,
            @LogEventTypeCode = N'ControlledRunResultRecorded', @LogSeverityCode = N'Info',
            @Description = @Act, @OldValue = NULL, @NewValue = @NewVal;

        -- ---- v1.4: each entry on its member's own LOT timeline (container: each tray,
        --      the helper names the container). One call per entry: the text differs. ----
        DECLARE @EntryMemberJson NVARCHAR(MAX), @EntryText NVARCHAR(400);
        DECLARE entry_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT N'[' + CAST(e.MemberId AS NVARCHAR(20)) + N']',
                   LEFT(N'Result recorded ' + Audit.ufn_MidDot() + N' ' + dc.Name + N' ' + CAST(e.Quantity AS NVARCHAR(10))
                        + CASE WHEN df.Id IS NOT NULL THEN N' (' + df.Description + N')' ELSE N'' END, 400)
            FROM @E e
            INNER JOIN Quality.DispositionCode dc ON dc.Id = e.DispositionCodeId
            LEFT JOIN Quality.DefectCode df       ON df.Id = e.DefectCodeId
            ORDER BY e.Seq;
        OPEN entry_cur;
        FETCH NEXT FROM entry_cur INTO @EntryMemberJson, @EntryText;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Quality.ControlledRun_LogMemberLotEventsInternal
                @MemberIdsJson = @EntryMemberJson, @LogEventTypeCode = N'ControlledRunLotResult',
                @ActionText = @EntryText, @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId;
            FETCH NEXT FROM entry_cur INTO @EntryMemberJson, @EntryText;
        END
        CLOSE entry_cur; DEALLOCATE entry_cur;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = CAST(@EntryCount AS NVARCHAR(10)) + N' result' + CASE WHEN @EntryCount = 1 THEN N'' ELSE N's' END
                     + N' recorded on super-lot ' + @RunNumber + N'.'
                     + CASE WHEN @Scrapped > 0 THEN N' ' + CAST(@Scrapped AS NVARCHAR(10)) + N' scrapped.' ELSE N'' END
                     + CASE WHEN @Returned > 0 THEN N' ' + CAST(@Returned AS NVARCHAR(10)) + N' marked for return.' ELSE N'' END;
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

        -- EXPECTED: somebody else took pieces off the same LOT between the check and
        -- the write (scrap or return). Everything is rolled back; say so plainly and do not re-raise.
        DECLARE @Race BIT = CASE WHEN @ErrMsg LIKE N'SUPERLOT_QTY%' THEN 1 ELSE 0 END;
        IF @Race = 1
            SET @Message = N'A LOT changed while you were saving. Nothing was recorded - reload and try again.';

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @ControlledRunId, @LogEventTypeCode = N'ControlledRunResultRecorded',
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
