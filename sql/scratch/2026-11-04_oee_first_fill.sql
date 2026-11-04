-- =============================================================================
-- 2026-11-04_oee_first_fill.sql -- OEE dashboard first fill, run ONCE after the
-- release that carries migration 0117 has COMMITTED (runbook step 4).
--
-- ONE JOB: give the OEE dashboard its history -- stamp the LOTs minted before
-- 0117 with the shift they were made in, then compute the stored per-shift
-- figures for every closed shift, then record the configuration fingerprint.
--
-- Why it is needed. From 0117 on, Assembly_CompleteTray / MachiningOut_Mint stamp
-- Lots.Lot.ShiftId + MintedPieceCount on every LOT they mint, and the 15-minute
-- OeeSummaryRefresh timer keeps Oee.ShiftSummary current. Neither reaches back:
-- every LOT minted before the release has no stamp (so M&A good would read 0 for
-- all history) and Oee.ShiftSummary starts empty (so every past shift reads as
-- "no data" until something computes it).
--
-- What it does, in order:
--   1. EXEC Lots.Lot_BackfillMintStamp @Commit = @Commit. Standalone, so with
--      @Commit = 0 it performs the UPDATE inside a transaction and ROLLS BACK
--      (the proc's own rehearsal); @Commit = 1 writes and audits one summary row.
--      Read its grid: Outcome per LOT -- Stamped / NoShift / NotReconstructable.
--      NoShift and NotReconstructable stay NULL and out of "good" (the dashboard
--      never guesses). A handful is expected; MORE THAN A FEW IS A STOP-AND-ASK.
--   2. Oee.ShiftSummary_RecomputeRange over every closed shift.
--        @Commit = 0: over the 3 most recent closed shifts only, inside a
--          transaction that is rolled back -- proves the compute runs on THIS
--          database's rows without holding history-wide locks in a live plant.
--        @Commit = 1: over all history, from the earliest Oee.Shift. It commits
--          shift by shift (one short transaction each); a failure keeps what it
--          finished and the script can be re-run -- it recomputes, never doubles.
--   3. Oee.ShiftSummary_RefreshChanged once. Its FIRST run only records the
--      configuration fingerprint, so the first OeeSummaryRefresh timer tick does
--      not see "everything changed" and recompute all history a second time.
--
-- Attribution: AppUser 1 (SYS), the gateway system user the OEE timers use.
--
-- NOT IN SCOPE, deliberately:
--   * The timers. OeeSummaryRefresh / OeeSummaryNightly ship disabled; they are
--     enabled at the Gateway after this script and the imports (runbook step 7).
--   * Shifts still running. RecomputeRange skips the shift in progress; the
--     shift-close hook in BlueRidge.Oee.Shift.tickShiftBoundary computes it when
--     it closes, once Core is imported.
--
-- Run:  sqlcmd ... -i sql\scratch\2026-11-04_oee_first_fill.sql
-- ARMING: set @Commit = 1 in the WORKING TREE ONLY, run, set it back to 0.
--         Never commit this file armed.
-- =============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

DECLARE @Commit BIT = 0;          -- 0 = rehearse (roll back), 1 = write
DECLARE @AppUserId BIGINT = 1;    -- SYS

-- ---- guards, before anything runs --------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0117_oee_shift_summary')
BEGIN RAISERROR(N'0117_oee_shift_summary is not applied on %s. Execute the release first.', 16, 1, @@SERVERNAME); RETURN; END;

IF NOT EXISTS (SELECT 1 FROM Location.AppUser WHERE Id = @AppUserId AND Initials = N'SYS')
BEGIN RAISERROR(N'AppUser 1 is not SYS on this database -- stop and check before attributing anything.', 16, 1); RETURN; END;

IF OBJECT_ID(N'Lots.Lot_BackfillMintStamp') IS NULL OR OBJECT_ID(N'Oee.ShiftSummary_RecomputeRange') IS NULL
   OR OBJECT_ID(N'Oee.ShiftSummary_RefreshChanged') IS NULL
BEGIN RAISERROR(N'An OEE first-fill proc is missing -- the release did not apply its repeatables.', 16, 1); RETURN; END;

DECLARE @Closed INT = (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NOT NULL);
DECLARE @Stored INT = (SELECT COUNT(DISTINCT ShiftId) FROM Oee.ShiftSummary);
DECLARE @Stamped0 INT = (SELECT COUNT(*) FROM Lots.Lot WHERE ShiftId IS NOT NULL);
PRINT CONCAT(N'Database ', DB_NAME(), N' on ', @@SERVERNAME, N' -- @Commit = ', @Commit);
PRINT CONCAT(N'Before: closed shifts ', @Closed, N', shifts already stored ', @Stored,
             N', LOTs already stamped ', @Stamped0);

-- ---- 1. mint-stamp backfill (the proc owns its transaction) ----------------------
PRINT N'== 1. Lots.Lot_BackfillMintStamp (grid below: one row per candidate LOT)';
EXEC Lots.Lot_BackfillMintStamp @Commit = @Commit, @AppUserId = @AppUserId;

-- ---- 2 + 3. summary fill + fingerprint -------------------------------------------
DECLARE @FromUtc DATETIME2(3), @ToUtc DATETIME2(3) = DATEADD(DAY, 1, SYSUTCDATETIME());
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), ShiftsComputed INT);
DECLARE @F TABLE (Status BIT, Message NVARCHAR(500), ShiftsComputed INT, ShiftsStillStale INT);
DECLARE @St BIT, @Msg NVARCHAR(500), @T0 DATETIME2(3) = SYSUTCDATETIME();

IF @Commit = 1
BEGIN
    -- ActualStart is local wall-clock (OI-38); a day's margin covers the offset.
    SET @FromUtc = (SELECT DATEADD(DAY, -1, MIN(ActualStart)) FROM Oee.Shift);
    PRINT CONCAT(N'== 2. Oee.ShiftSummary_RecomputeRange ', CONVERT(NVARCHAR(16), @FromUtc, 120),
                 N' -> ', CONVERT(NVARCHAR(16), @ToUtc, 120), N' (all history, committed shift by shift)');
    INSERT INTO @R EXEC Oee.ShiftSummary_RecomputeRange @FromUtc = @FromUtc, @ToUtc = @ToUtc, @AppUserId = @AppUserId;
    SELECT @St = Status, @Msg = Message FROM @R;
    PRINT CONCAT(N'   Status ', @St, N' -- ', @Msg, N' -- ', DATEDIFF(MILLISECOND, @T0, SYSUTCDATETIME()) / 1000.0, N' s');
    IF @St <> 1 BEGIN RAISERROR(N'RecomputeRange refused: %s. Shifts already computed are kept; fix and re-run.', 16, 1, @Msg); RETURN; END;

    PRINT N'== 3. Oee.ShiftSummary_RefreshChanged (first run records the configuration fingerprint)';
    INSERT INTO @F EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = @AppUserId;
    SELECT @St = Status, @Msg = Message FROM @F;
    PRINT CONCAT(N'   Status ', @St, N' -- ', @Msg);
    IF @St <> 1 BEGIN RAISERROR(N'RefreshChanged refused: %s', 16, 1, @Msg); RETURN; END;
END
ELSE
BEGIN
    -- Rehearsal: the 3 most recent closed shifts, inside a transaction, rolled back.
    SET @FromUtc = (SELECT DATEADD(HOUR, -12, MIN(ActualStart))
                    FROM (SELECT TOP 3 ActualStart FROM Oee.Shift WHERE ActualEnd IS NOT NULL
                          ORDER BY ActualStart DESC) s);
    IF @FromUtc IS NULL BEGIN PRINT N'No closed shift on this database -- nothing to rehearse in step 2.'; RETURN; END;
    PRINT CONCAT(N'== 2. (rehearsal) RecomputeRange from ', CONVERT(NVARCHAR(16), @FromUtc, 120),
                 N' -- the latest closed shifts only, rolled back');
    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO @R EXEC Oee.ShiftSummary_RecomputeRange @FromUtc = @FromUtc, @ToUtc = @ToUtc, @AppUserId = @AppUserId;
        SELECT @St = Status, @Msg = Message FROM @R;
        PRINT CONCAT(N'   Status ', @St, N' -- ', @Msg, N' -- ', DATEDIFF(MILLISECOND, @T0, SYSUTCDATETIME()) / 1000.0, N' s');
        DECLARE @Rows INT = (SELECT COUNT(*) FROM Oee.ShiftSummary);
        PRINT CONCAT(N'   Stored rows written (before rollback): ', @Rows);
        INSERT INTO @F EXEC Oee.ShiftSummary_RefreshChanged @AppUserId = @AppUserId;
        SELECT @St = Status, @Msg = Message FROM @F;
        PRINT CONCAT(N'== 3. (rehearsal) RefreshChanged Status ', @St, N' -- ', @Msg);
        ROLLBACK TRANSACTION;
        PRINT N'   Rolled back.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @E NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(N'Rehearsal failed and rolled back: %s', 16, 1, @E);
        RETURN;
    END CATCH
END;

-- ---- after ------------------------------------------------------------------------
DECLARE @StoredA INT = (SELECT COUNT(DISTINCT ShiftId) FROM Oee.ShiftSummary);
DECLARE @ClosedA INT = (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NOT NULL);
DECLARE @StampedA INT = (SELECT COUNT(*) FROM Lots.Lot WHERE ShiftId IS NOT NULL);
DECLARE @Fp NVARCHAR(3) = (SELECT CASE WHEN ConfigFingerprint IS NULL THEN N'no' ELSE N'yes' END
                           FROM Oee.ShiftSummaryConfig WHERE Id = 1);
PRINT CONCAT(N'After: shifts stored ', @StoredA, N' of ', @ClosedA, N' closed, LOTs stamped ', @StampedA,
             N', fingerprint recorded ', ISNULL(@Fp, N'no'));
