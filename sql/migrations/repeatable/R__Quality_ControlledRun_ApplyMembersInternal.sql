-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_ApplyMembersInternal.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.1
-- Change Log:  2026-10-13 - 1.1 - Piece 2: the Closed tray LOTs of a container that
--                                 joins ARE tagged, so a completed container is
--                                 blocked at the dock. Stamps WasCompleteAtJoin.
-- Description: SILENT INTERNAL HELPER -- not called from Ignition. Adds every
--              ELIGIBLE unit in @MembersJson to a super-lot, sets
--              Lots.Lot.CrtActive where it is not already set (D5) and writes
--              one CrtActivated audit row per LOT it tagged. Ineligible units
--              are skipped silently: callers that must refuse on them check
--              Quality.ufn_ControlledRunResolveMembers BEFORE their transaction.
--
--              Shared by ControlledRun_Open, ControlledRun_AddMembers and
--              ControlledRun_SyncInternal so the tag-on-join rule exists once.
--              It emits NO result set and NEVER rolls back -- that is what lets
--              status-row procs (which may be captured via INSERT-EXEC) EXEC it,
--              the same reason the Audit.Audit_Log* writers emit nothing.
--              Call it inside the caller's transaction.
--
--              A Closed LOT named as a LOT is never tagged here (mirror of
--              Lots.Lot_SetCrt, which still refuses one: on LOT Detail "tag a
--              closed LOT" has no meaning). The ONE exception lives here and only
--              here: a tray LOT (Lots.ContainerTray.FinishedGoodLotId) of a
--              container that is joining is tagged whatever its status, because a
--              tray LOT is Closed the moment its container completes and the
--              container-level guards (Container_Ship, AimShipperIdPool_
--              ListUnposted) read the trays' CrtActive. Eligibility has already
--              kept Shipped and Void containers out of @M. Spec:
--              2026-10-12-controlled-run-completed-containers-design.md s10.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_ApplyMembersInternal
    @ControlledRunId    BIGINT,
    @MembersJson        NVARCHAR(MAX),
    @JoinMethodCode     NVARCHAR(20),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    -- SILENT INTERNAL HELPER. No result set, no status row, no ROLLBACK: it runs
    -- inside the caller's transaction and an error dooms that transaction and
    -- surfaces in the caller's CATCH. That is what lets status-row procs
    -- (which may be captured by INSERT-EXEC) share it -- the same reason the
    -- Audit.Audit_Log* writers emit nothing.
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @JoinMethodId BIGINT = (SELECT Id FROM Quality.ControlledRunJoinMethod WHERE Code = @JoinMethodCode);
    DECLARE @RunNumber NVARCHAR(15) = (SELECT RunNumber FROM Quality.ControlledRun WHERE Id = @ControlledRunId);
    IF @JoinMethodId IS NULL OR @RunNumber IS NULL
        RAISERROR(N'ControlledRun_ApplyMembersInternal: unknown run or join method.', 16, 1);

    DECLARE @M TABLE (LotId BIGINT NULL, ContainerId BIGINT NULL);
    INSERT INTO @M (LotId, ContainerId)
    SELECT r.LotId, r.ContainerId
    FROM Quality.ufn_ControlledRunResolveMembers(@MembersJson) r
    WHERE r.IneligibleReason IS NULL;

    IF NOT EXISTS (SELECT 1 FROM @M) RETURN;

    -- ---- D5: set the tag. INLINED mirror of Lots.Lot_SetCrt (source of truth:
    --      R__Lots_Lot_SetCrt.sql). A Closed LOT is tagged ONLY as the tray of a
    --      joining container (v1.1, see header). ----
    DECLARE @Tagged TABLE (LotId BIGINT NOT NULL, LotName NVARCHAR(50) NOT NULL);
    UPDATE l
    SET CrtActive = 1, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    OUTPUT inserted.Id, inserted.LotName INTO @Tagged (LotId, LotName)
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.CrtActive = 0
      AND ( (sc.Code <> N'Closed' AND l.Id IN (SELECT LotId FROM @M WHERE LotId IS NOT NULL))
         OR l.Id IN (SELECT t.FinishedGoodLotId FROM Lots.ContainerTray t
                     WHERE t.ContainerId IN (SELECT ContainerId FROM @M WHERE ContainerId IS NOT NULL)) );

    INSERT INTO Quality.ControlledRunMember
        (ControlledRunId, LotId, ContainerId, ControlledRunJoinMethodId, CrtSetByRun, WasCompleteAtJoin, AddedByUserId)
    SELECT @ControlledRunId, m.LotId, m.ContainerId, @JoinMethodId,
           CONVERT(BIT, CASE
               WHEN m.LotId IS NOT NULL AND EXISTS (SELECT 1 FROM @Tagged g WHERE g.LotId = m.LotId) THEN 1
               WHEN m.ContainerId IS NOT NULL AND EXISTS (
                    SELECT 1 FROM @Tagged g JOIN Lots.ContainerTray t ON t.FinishedGoodLotId = g.LotId
                    WHERE t.ContainerId = m.ContainerId) THEN 1
               ELSE 0 END),
           -- Once a later piece reopens a container, nothing else records that it
           -- was pulled back from finished stock. CompletedAt as well as the status,
           -- so a completed container that is on a real hold (status Hold) counts.
           CONVERT(BIT, CASE WHEN m.ContainerId IS NOT NULL AND EXISTS (
                    SELECT 1 FROM Lots.Container c JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
                    WHERE c.Id = m.ContainerId AND (cs.Code = N'Complete' OR c.CompletedAt IS NOT NULL)) THEN 1 ELSE 0 END),
           @AppUserId
    FROM @M m;

    -- ---- one CrtActivated row per LOT tagged, so each LOT's own 20-year timeline
    --      is complete without knowing it was in a super-lot ----
    DECLARE @LotId BIGINT, @LotName NVARCHAR(50), @Activity NVARCHAR(500), @ActivityRaw NVARCHAR(MAX), @NewValue NVARCHAR(MAX);
    DECLARE tagged_cur CURSOR LOCAL FAST_FORWARD FOR SELECT LotId, LotName FROM @Tagged ORDER BY LotId;
    OPEN tagged_cur;
    FETCH NEXT FROM tagged_cur INTO @LotId, @LotName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ActivityRaw = @LotName + N' ' + Audit.ufn_MidDot() + N' CRT ' + Audit.ufn_MidDot()
                         + N' Activated (super-lot ' + @RunNumber + N')';
        SET @Activity = Audit.ufn_TruncateActivity(@ActivityRaw);
        SET @NewValue = (
            SELECT CAST(1 AS BIT) AS CrtActive,
                   JSON_QUERY((SELECT @LotId AS Id, @LotName AS Code, @LotName AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Lot,
                   JSON_QUERY((SELECT @ControlledRunId AS Id, @RunNumber AS Code, @RunNumber AS Name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS ControlledRun
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC Audit.Audit_LogOperation
            @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
            @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'CrtActivated',
            @LogSeverityCode = N'Info', @Description = @Activity,
            @OldValue = N'{"CrtActive":false}', @NewValue = @NewValue;
        FETCH NEXT FROM tagged_cur INTO @LotId, @LotName;
    END
    CLOSE tagged_cur; DEALLOCATE tagged_cur;
END;
GO
