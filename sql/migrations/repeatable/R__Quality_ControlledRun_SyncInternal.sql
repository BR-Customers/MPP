-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_SyncInternal.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.1
-- Change Log:  2026-10-12 - 1.1 - Never re-adds a unit that was REMOVED from this
--                                 super-lot by hand (final-review finding).
-- Description: SILENT INTERNAL HELPER -- not called from Ignition. For ONE open
--              super-lot, records the membership of material that is ALREADY
--              CRT-tagged:
--                (a) new production of the run's part (and line) minted since
--                    the run opened and before its window ended -- tagged at
--                    mint by Lots.ufn_CrtForMint arm 4 (D7). Runs only when the
--                    window is, or was, open.
--                (b) when IncludeDescendants = 1, CRT-active genealogy
--                    descendants of the run's current LOT members (D8).
--              Ineligible units (already in a super-lot, scrapped, closed) are
--              skipped by ControlledRun_ApplyMembersInternal, which is what
--              makes this idempotent.
--
--              No result set. Owns a BEGIN/COMMIT (legal when nested) and never
--              rolls back, so status-row procs may EXEC it: the wrapper
--              ControlledRun_SyncAutoJoin, and ControlledRun_SetAutoJoin /
--              ControlledRun_Close for their final sync.
--
--              The CRT BLOCK never waits on this: the tag was set in the mint
--              transaction. Only the member list lags, by at most one sync.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_SyncInternal
    @ControlledRunId BIGINT,
    @AppUserId       BIGINT
AS
BEGIN
    -- SILENT INTERNAL HELPER (see ControlledRun_ApplyMembersInternal). Records the
    -- membership of material the mint resolver already tagged (D7) and of CRT
    -- descendants of current members (D8). The BLOCK never waits on this: the
    -- tag was set in the mint transaction.
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ItemId BIGINT, @LocationId BIGINT, @OpenedAt DATETIME2(3), @EndedAt DATETIME2(3),
            @AutoJoin BIT, @Desc BIT, @StatusId BIGINT;
    SELECT @ItemId = SelectionItemId, @LocationId = SelectionLocationId, @OpenedAt = OpenedAt,
           @EndedAt = AutoJoinEndedAt, @AutoJoin = AutoJoinEnabled, @Desc = IncludeDescendants,
           @StatusId = ControlledRunStatusId
    FROM Quality.ControlledRun WHERE Id = @ControlledRunId;
    IF @StatusId IS NULL OR @StatusId <> 1 RETURN;

    DECLARE @Json NVARCHAR(MAX);

    -- Units Quality took OUT of this super-lot by hand. D6 leaves their tag on, so
    -- without this the very next sync would put them straight back (as AutoJoined or
    -- Descendant) and Remove would do nothing. A deliberate scan-in (AddMembers)
    -- can still bring one back.
    DECLARE @Removed TABLE (LotId BIGINT NULL, ContainerId BIGINT NULL);
    INSERT INTO @Removed (LotId, ContainerId)
    SELECT m.LotId, m.ContainerId
    FROM Quality.ControlledRunMember m
    WHERE m.ControlledRunId = @ControlledRunId AND m.ControlledRunMemberEndReasonId = 1 /* Removed */;

    BEGIN TRANSACTION;

    -- (a) new production: only while the window is, or was, open
    IF @ItemId IS NOT NULL AND (@AutoJoin = 1 OR @EndedAt IS NOT NULL)
    BEGIN
        ;WITH Descendants AS (
            SELECT @LocationId AS Id WHERE @LocationId IS NOT NULL
            UNION ALL
            SELECT c.Id FROM Location.Location c INNER JOIN Descendants d ON c.ParentLocationId = d.Id
        )
        SELECT @Json = (
            SELECT l.Id AS lotId
            FROM Lots.Lot l
            WHERE l.ItemId = @ItemId
              AND l.CrtActive = 1
              AND l.CreatedAt >= @OpenedAt
              AND (@EndedAt IS NULL OR l.CreatedAt < @EndedAt)
              AND (@LocationId IS NULL OR l.CreatedAtTerminalId IN (SELECT Id FROM Descendants))
              -- never bring back a unit Quality REMOVED from this super-lot (v1.1)
              AND NOT EXISTS (SELECT 1 FROM @Removed x WHERE x.LotId = l.Id)
              AND NOT EXISTS (SELECT 1 FROM Lots.ContainerTray t JOIN @Removed x ON x.ContainerId = t.ContainerId
                              WHERE t.FinishedGoodLotId = l.Id)
            FOR JSON PATH)
        OPTION (MAXRECURSION 8);

        IF @Json IS NOT NULL
            EXEC Quality.ControlledRun_ApplyMembersInternal
                @ControlledRunId = @ControlledRunId, @MembersJson = @Json, @JoinMethodCode = N'AutoJoined',
                @AppUserId = @AppUserId, @TerminalLocationId = NULL;
    END

    -- (b) CRT-active descendants of current LOT members
    IF @Desc = 1
    BEGIN
        SET @Json = (
            SELECT DISTINCT gc.DescendantLotId AS lotId
            FROM Quality.ControlledRunMember m
            INNER JOIN Lots.LotGenealogyClosure gc ON gc.AncestorLotId = m.LotId AND gc.Depth > 0
            INNER JOIN Lots.Lot d ON d.Id = gc.DescendantLotId
            WHERE m.ControlledRunId = @ControlledRunId AND m.EndedAt IS NULL AND m.LotId IS NOT NULL
              AND d.CrtActive = 1
              AND NOT EXISTS (SELECT 1 FROM @Removed x WHERE x.LotId = d.Id)
              AND NOT EXISTS (SELECT 1 FROM Lots.ContainerTray t JOIN @Removed x ON x.ContainerId = t.ContainerId
                              WHERE t.FinishedGoodLotId = d.Id)
            FOR JSON PATH);

        IF @Json IS NOT NULL
            EXEC Quality.ControlledRun_ApplyMembersInternal
                @ControlledRunId = @ControlledRunId, @MembersJson = @Json, @JoinMethodCode = N'Descendant',
                @AppUserId = @AppUserId, @TerminalLocationId = NULL;
    END

    COMMIT TRANSACTION;
END;
GO
