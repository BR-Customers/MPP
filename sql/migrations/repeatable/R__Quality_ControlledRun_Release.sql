-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_Release.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: THE SIGNED BULK RELEASE. Releases the ticked members of an open
--              super-lot in one action, under one signature, carrying the
--              confirmation that the Controlled Run Tag was acted on and the
--              200% inspection was completed. All or nothing.
--
--              @MemberIdsJson: [n, n, ...] -- Quality.ControlledRunMember ids.
--              @AppUserId is THE SIGNER: the caller has just checked that
--              person's network password (AppUser.elevate, stateless form).
--              @InspectionConfirmed must be 1. The system never forces the
--              inspection (spec 1); it records that Quality said it was done,
--              as a FACT on the release row, not as free text.
--
--              Refused, naming the member, when a ticked member:
--                * is not a current member of THIS super-lot,
--                * has no live result, or
--                * has a Use-As-Is result and the super-lot has no deviation.
--              The last two come from Quality.ufn_ControlledRunMemberResults --
--              the same column the Sign-off tab shows, so the screen and this
--              proc cannot disagree. Quantities need not add up (spec D3).
--
--              In one transaction:
--                1. CrtActive is cleared on every tagged LOT of the ticked
--                   members -- a container's tray LOTs included, Closed or not --
--                   with ONE CrtCleared audit row PER LOT (Honda traceability:
--                   each LOT's own 20-year timeline must show its release).
--                   INLINED MIRROR of Lots.Lot_ClearCrt / Lots.Container_
--                   ValidateCrt (sources of truth: R__Lots_Lot_ClearCrt.sql,
--                   R__Lots_Container_ValidateCrt.sql).
--                2. One Quality.Signature (meaning ControlledRunRelease, the
--                   statement COPIED) and one Quality.ControlledRunRelease.
--                3. The memberships are ended (reason Released) and pointed at
--                   the release. A short count means a member left between the
--                   check and the write: SUPERLOT_RACE, everything undone.
--                4. One ControlledRunReleased audit row.
--
--              A member that is already untagged (cleared one at a time on LOT
--              Detail -- still allowed, spec D5) is released the same way and
--              simply produces no CrtCleared row.
--
--              NO AIM CALL, here or in the caller. Clearing the tags is what
--              returns a held, unposted serial to Lots.AimShipperIdPool_
--              ListUnposted, and the existing sweep posts it. A serial posted
--              before the container was tagged is not in that list and is never
--              posted twice.
--
--              Releasing does not close the super-lot: "everything is released"
--              and "the case is finished" stay separate statements.
--
--              FDS-11-011: no OUTPUT params; one result set; every rejecting
--              validation runs before BEGIN TRANSACTION; CATCH is the only
--              ROLLBACK site. Returns Status, Message, NewId (the release).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_Release
    @Id                  BIGINT,
    @MemberIdsJson       NVARCHAR(MAX),
    @InspectionConfirmed BIT,
    @Remarks             NVARCHAR(500) = NULL,
    @AppUserId           BIGINT,
    @TerminalLocationId  BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @NewId   BIGINT        = NULL;

    DECLARE @ProcName NVARCHAR(200) = N'Quality.ControlledRun_Release';
    DECLARE @Params   NVARCHAR(MAX) = (
        SELECT @Id AS Id, LEFT(@MemberIdsJson, 3000) AS MemberIdsJson, @InspectionConfirmed AS InspectionConfirmed,
               @Remarks AS Remarks, @AppUserId AS AppUserId, @TerminalLocationId AS TerminalLocationId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunNumber NVARCHAR(15), @RunStatusId BIGINT;
    SELECT @RunNumber = RunNumber, @RunStatusId = ControlledRunStatusId FROM Quality.ControlledRun WHERE Id = @Id;
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');

    DECLARE @MeaningId BIGINT, @Statement NVARCHAR(500);
    SELECT @MeaningId = Id, @Statement = Statement FROM Quality.SignatureMeaning WHERE Code = N'ControlledRunRelease';
    DECLARE @EntityTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ControlledRun');

    -- ---- the ticked members, resolved once ----
    DECLARE @T TABLE (
        MemberId BIGINT PRIMARY KEY, IsMember BIT NOT NULL DEFAULT (0), LotId BIGINT NULL, ContainerId BIGINT NULL,
        DisplayName NVARCHAR(60) NULL, BlockReason NVARCHAR(100) NULL);

    INSERT INTO @T (MemberId)
    SELECT DISTINCT TRY_CAST(j.value AS BIGINT)
    FROM OPENJSON(CASE WHEN ISJSON(@MemberIdsJson) = 1 THEN @MemberIdsJson ELSE N'[]' END) j
    WHERE TRY_CAST(j.value AS BIGINT) IS NOT NULL;

    UPDATE t
    SET IsMember = 1, LotId = ms.LotId, ContainerId = ms.ContainerId, DisplayName = ms.DisplayName,
        BlockReason = mr.ReleaseBlockReason
    FROM @T t
    INNER JOIN Quality.ufn_ControlledRunMemberState(@Id) ms   ON ms.MemberId = t.MemberId AND ms.EndedAt IS NULL
    INNER JOIN Quality.ufn_ControlledRunMemberResults(@Id) mr ON mr.MemberId = t.MemberId;

    DECLARE @Ticked INT = (SELECT COUNT(*) FROM @T);

    BEGIN TRY
        DECLARE @Reject NVARCHAR(500) = NULL;
        IF @Id IS NULL OR @AppUserId IS NULL
            SET @Reject = N'Required parameter missing (Id, AppUserId).';
        IF @Reject IS NULL AND @RunNumber IS NULL
            SET @Reject = N'Super-lot not found.';
        IF @Reject IS NULL AND @RunStatusId <> 1
            SET @Reject = N'Super-lot ' + @RunNumber + N' is not open.';
        IF @Reject IS NULL AND Quality.ufn_SignatureAllowed(@AppUserId, N'ControlledRunRelease') = 0
            SET @Reject = N'This user cannot sign a release.';
        IF @Reject IS NULL AND ISNULL(@InspectionConfirmed, 0) <> 1
            SET @Reject = N'Confirm that the 200% inspection was completed. Nothing was released.';
        IF @Reject IS NULL AND @Ticked = 0
            SET @Reject = N'Tick at least one member to release.';
        IF @Reject IS NULL AND EXISTS (SELECT 1 FROM @T WHERE IsMember = 0)
            SET @Reject = CAST((SELECT COUNT(*) FROM @T WHERE IsMember = 0) AS NVARCHAR(10))
                        + N' of the ticked members are no longer in super-lot ' + @RunNumber + N'. Reload and tick again.';
        IF @Reject IS NULL
            SELECT TOP 1 @Reject = t.DisplayName + N': ' + t.BlockReason + N'. Nothing was released.'
            FROM @T t WHERE t.BlockReason IS NOT NULL ORDER BY t.MemberId;

        IF @Reject IS NOT NULL
        BEGIN
            SET @Message = @Reject;
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunReleased',
                    @FailureReason = @Message, @ProcedureName = @ProcName,
                    @AttemptedParameters = @Params;
            SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
            RETURN;
        END

        -- ===== Mutation (atomic) =====
        BEGIN TRANSACTION;

        -- ---- 1. clear the tag. MIRROR of Lots.Lot_ClearCrt (same three columns).
        --      OUTPUT says exactly which LOTs were touched -- never re-derive. ----
        DECLARE @Cleared TABLE (LotId BIGINT NOT NULL, LotName NVARCHAR(50) NOT NULL);
        UPDATE l
        SET CrtActive = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
        OUTPUT inserted.Id, inserted.LotName INTO @Cleared (LotId, LotName)
        FROM Lots.Lot l
        WHERE l.CrtActive = 1
          AND ( l.Id IN (SELECT LotId FROM @T WHERE LotId IS NOT NULL)
             OR l.Id IN (SELECT ct.FinishedGoodLotId FROM Lots.ContainerTray ct
                         WHERE ct.ContainerId IN (SELECT ContainerId FROM @T WHERE ContainerId IS NOT NULL)) );

        DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @LotActRaw NVARCHAR(MAX), @LotAct NVARCHAR(500), @LotNew NVARCHAR(MAX);
        DECLARE cleared_cur CURSOR LOCAL FAST_FORWARD FOR SELECT LotId, LotName FROM @Cleared ORDER BY LotId;
        OPEN cleared_cur;
        FETCH NEXT FROM cleared_cur INTO @LotId, @LotName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @LotActRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot()
                           + N' Cleared (super-lot ' + @RunNumber + N' release)';
            SET @LotAct = Audit.ufn_TruncateActivity(@LotActRaw);
            SET @LotNew = (
                SELECT CAST(0 AS BIT) AS CrtActive,
                       JSON_QUERY((SELECT @LotId AS Id, @LotName AS Code, @LotName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                       JSON_QUERY((SELECT @Id AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC Audit.Audit_LogOperation
                @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
                @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'CrtCleared',
                @LogSeverityCode = N'Info', @Description = @LotAct,
                @OldValue = N'{"CrtActive":true}', @NewValue = @LotNew;
            FETCH NEXT FROM cleared_cur INTO @LotId, @LotName;
        END
        CLOSE cleared_cur; DEALLOCATE cleared_cur;

        -- ---- 2. the signature and the release it signs ----
        INSERT INTO Quality.Signature
            (SignatureMeaningId, AppUserId, Statement, LogEntityTypeId, EntityId, TerminalLocationId)
        VALUES (@MeaningId, @AppUserId, @Statement, @EntityTypeId, @Id, @TerminalLocationId);
        DECLARE @SignatureId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

        INSERT INTO Quality.ControlledRunRelease
            (ControlledRunId, SignatureId, InspectionConfirmed, MemberCount, Remarks, ReleasedByUserId, TerminalLocationId)
        VALUES (@Id, @SignatureId, 1, @Ticked, @Remarks, @AppUserId, @TerminalLocationId);
        SET @NewId = CAST(SCOPE_IDENTITY() AS BIGINT);

        -- ---- 3. end the memberships ----
        UPDATE m
        SET EndedAt = SYSUTCDATETIME(), EndedByUserId = @AppUserId,
            ControlledRunMemberEndReasonId = 4 /* Released */, ControlledRunReleaseId = @NewId
        FROM Quality.ControlledRunMember m
        WHERE m.Id IN (SELECT MemberId FROM @T) AND m.ControlledRunId = @Id AND m.EndedAt IS NULL;

        IF @@ROWCOUNT <> @Ticked
            RAISERROR(N'SUPERLOT_RACE: a member left the super-lot between the check and the write.', 16, 1);

        -- ---- 4. one audit row for the action ----
        DECLARE @LotCount INT = (SELECT COUNT(*) FROM @T WHERE LotId IS NOT NULL);
        DECLARE @ConCount INT = (SELECT COUNT(*) FROM @T WHERE ContainerId IS NOT NULL);
        DECLARE @ClearedCount INT = (SELECT COUNT(*) FROM @Cleared);
        DECLARE @Signer NVARCHAR(20) = (SELECT Initials FROM Location.AppUser WHERE Id = @AppUserId);

        DECLARE @ActivityRaw NVARCHAR(MAX) = @RunNumber + N' ' + Audit.ufn_MidDot() + N' Released ' + Audit.ufn_MidDot()
            + N' ' + CAST(@LotCount AS NVARCHAR(10)) + N' LOTs, ' + CAST(@ConCount AS NVARCHAR(10))
            + N' containers; signed by ' + ISNULL(@Signer, N'?')
            + CASE WHEN @Remarks IS NOT NULL THEN N': ' + @Remarks ELSE N'' END;
        DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
        DECLARE @NewValue NVARCHAR(MAX) = (
            SELECT @NewId AS ReleaseId, @SignatureId AS SignatureId, CAST(1 AS BIT) AS InspectionConfirmed,
                   @Ticked AS MemberCount, @ClearedCount AS LotsCleared, @Remarks AS Remarks,
                   JSON_QUERY((SELECT u.Id, u.Initials AS Code, u.DisplayName AS Name FROM Location.AppUser u
                               WHERE u.Id = @AppUserId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS SignedBy,
                   JSON_QUERY((SELECT @Id AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun,
                   JSON_QUERY((SELECT TOP 100 t.DisplayName AS Member FROM @T t ORDER BY t.MemberId FOR JSON PATH)) AS Members
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'ControlledRun', @EntityId = @Id,
            @LogEventTypeCode = N'ControlledRunReleased', @LogSeverityCode = N'Info',
            @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;

        COMMIT TRANSACTION;

        DECLARE @Left INT = (SELECT COUNT(*) FROM Quality.ControlledRunMember WHERE ControlledRunId = @Id AND EndedAt IS NULL);

        SET @Status  = 1;
        SET @Message = CAST(@Ticked AS NVARCHAR(10)) + N' member' + CASE WHEN @Ticked = 1 THEN N'' ELSE N's' END
                     + N' released from super-lot ' + @RunNumber + N'. '
                     + CASE WHEN @Left = 0 THEN N'Nothing is left in it; it can be closed.'
                            ELSE CAST(@Left AS NVARCHAR(10)) + N' still in it.' END;
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

        -- EXPECTED, not unexpected: a ticked member was removed or released by someone
        -- else between the pre-transaction check and the write. Everything is rolled
        -- back, signature included; say so plainly and do not re-raise.
        DECLARE @Race BIT = CASE WHEN @ErrMsg LIKE N'SUPERLOT_RACE%' THEN 1 ELSE 0 END;
        IF @Race = 1
            SET @Message = N'Something changed while you were releasing. Nothing was released - reload and try again.';

        BEGIN TRY
            IF @AppUserId IS NOT NULL AND EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId)
                EXEC Audit.Audit_LogFailure
                    @AppUserId = @AppUserId, @LogEntityTypeCode = N'ControlledRun',
                    @EntityId = @Id, @LogEventTypeCode = N'ControlledRunReleased',
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
