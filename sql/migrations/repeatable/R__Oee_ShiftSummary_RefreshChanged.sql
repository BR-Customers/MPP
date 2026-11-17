-- =============================================
-- Procedure:   Oee.ShiftSummary_RefreshChanged
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.1 (2026-11-05; found in the container-as-LOT year-scale bench, landed alone 2026-11-16) - Volume: the input fingerprint runs only over the last 7 days' shifts, ONE SHIFT AT A TIME (as a set the inline function lost its seeks); a no-change tick at a year of history was ~30 s.
-- Version:     1.0
--
-- Description:
--   Keeps Oee.ShiftSummary current (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 6.8,
--   D19, D22). Called every 15 minutes by the OeeSummaryRefresh gateway timer,
--   and by the shift ticker right after it closes a shift. In order:
--     1. Configuration fingerprint (Oee.ufn_ShiftSummaryConfigFingerprint).
--        When it differs from Oee.ShiftSummaryConfig, store it and stamp
--        ConfigChangedAt = now: every stored shift computed before that is
--        stale. The very first run (stored fingerprint NULL) only records it --
--        the deployment fills the table with RecomputeRange first.
--     2. Stale CLOSED shifts:
--          (a) closed, with no stored rows             -- the shift-close compute
--          (b) started in the last 7 days (or later) and the stored
--              InputFingerprint differs from Oee.ufn_ShiftInputFingerprint
--                                                      -- a late edit
--          (c) stored before ConfigChangedAt           -- a configuration change
--     3. Recompute up to @MaxShifts of them, newest first, one transaction per
--        shift (Oee.ShiftSummary_ComputeCore). The rest wait for the next run.
--   An edit older than 7 days reaches the summary only through a configuration
--   change, the nightly sweep's window, or an explicit RecomputeRange (spec 10).
--
-- Parameters:
--   @AppUserId BIGINT - required (the gateway passes the SYS user).
--   @MaxShifts INT    - work bound per run; default 60.
--
-- Result set: Status BIT, Message NVARCHAR(500), ShiftsComputed INT,
--             ShiftsStillStale INT.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftSummary_RefreshChanged
    @AppUserId BIGINT,
    @MaxShifts INT = 60
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @Done    INT           = 0;
    DECLARE @Stale   INT           = 0;

    BEGIN TRY
        IF @AppUserId IS NULL OR @MaxShifts IS NULL OR @MaxShifts < 1
        BEGIN
            SET @Message = N'AppUserId and a positive MaxShifts are required.';
            SELECT @Status AS Status, @Message AS Message, @Done AS ShiftsComputed, @Stale AS ShiftsStillStale;
            RETURN;
        END

        DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

        -- ---- 1. configuration ----
        DECLARE @Cfg VARBINARY(32) = (SELECT Fingerprint FROM Oee.ufn_ShiftSummaryConfigFingerprint());
        DECLARE @Stored VARBINARY(32), @ChangedAt DATETIME2(3);
        SELECT @Stored = ConfigFingerprint, @ChangedAt = ConfigChangedAt FROM Oee.ShiftSummaryConfig WHERE Id = 1;

        IF @Stored IS NULL
            UPDATE Oee.ShiftSummaryConfig SET ConfigFingerprint = @Cfg, CheckedAt = @Now WHERE Id = 1;
        ELSE IF @Stored <> @Cfg
        BEGIN
            UPDATE Oee.ShiftSummaryConfig SET ConfigFingerprint = @Cfg, ConfigChangedAt = @Now, CheckedAt = @Now WHERE Id = 1;
            SET @ChangedAt = @Now;
        END
        ELSE
            UPDATE Oee.ShiftSummaryConfig SET CheckedAt = @Now WHERE Id = 1;

        -- ---- 2. stale closed shifts ----
        DECLARE @Recent DATETIME2(3) = DATEADD(DAY, -7, @Now);
        DECLARE @Todo TABLE (ShiftId BIGINT PRIMARY KEY, ActualStart DATETIME2(3));

        -- Volume (2026-11-05): two passes. The cheap tests (never computed, config changed)
        -- run over every closed shift; the input FINGERPRINT runs only over the last 7 days.
        -- In one OR predicate the optimizer evaluated the fingerprint for every shift of the
        -- year (~780 x 38 ms = a 30 s tick with nothing to do, every 15 minutes).
        INSERT INTO @Todo (ShiftId, ActualStart)
        SELECT s.Id, s.ActualStart
        FROM Oee.Shift s
        OUTER APPLY (SELECT MIN(ss.ComputedAt) AS ComputedAt, COUNT(*) AS N
                     FROM Oee.ShiftSummary ss WHERE ss.ShiftId = s.Id) st
        WHERE s.ActualEnd IS NOT NULL
          AND (st.N = 0 OR (@ChangedAt IS NOT NULL AND st.ComputedAt < @ChangedAt));

        DECLARE @RecentShifts TABLE (ShiftId BIGINT PRIMARY KEY, ActualStart DATETIME2(3));
        INSERT INTO @RecentShifts (ShiftId, ActualStart)
        SELECT s.Id, s.ActualStart
        FROM Oee.Shift s
        WHERE s.ActualEnd IS NOT NULL
          AND CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) >= @Recent
          AND NOT EXISTS (SELECT 1 FROM @Todo t WHERE t.ShiftId = s.Id);

        -- One shift at a time: inlined over a SET of shifts, ufn_ShiftInputFingerprint
        -- expands into one large join and loses its per-shift seeks (19 shifts: 28.8 s as a
        -- set, ~61 ms each one by one, benchmark 2026-11-05).
        DECLARE @rs BIGINT, @rsStart DATETIME2(3), @StoredFp VARBINARY(32), @NowFp VARBINARY(32);
        DECLARE recent_cur CURSOR LOCAL FAST_FORWARD FOR SELECT ShiftId, ActualStart FROM @RecentShifts;
        OPEN recent_cur;
        FETCH NEXT FROM recent_cur INTO @rs, @rsStart;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @StoredFp = (SELECT MIN(ss.InputFingerprint) FROM Oee.ShiftSummary ss WHERE ss.ShiftId = @rs);
            SET @NowFp = ISNULL((SELECT f.Fingerprint FROM Oee.ufn_ShiftInputFingerprint(@rs) f), 0x);
            IF @StoredFp <> @NowFp
                INSERT INTO @Todo (ShiftId, ActualStart) VALUES (@rs, @rsStart);
            FETCH NEXT FROM recent_cur INTO @rs, @rsStart;
        END
        CLOSE recent_cur; DEALLOCATE recent_cur;

        SET @Stale = (SELECT COUNT(*) FROM @Todo);

        -- ---- 3. recompute, newest first, bounded ----
        DECLARE @Pick TABLE (N INT IDENTITY(1,1) PRIMARY KEY, ShiftId BIGINT);
        INSERT INTO @Pick (ShiftId)
        SELECT TOP (@MaxShifts) ShiftId FROM @Todo ORDER BY ActualStart DESC, ShiftId DESC;

        DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Pick), @Sid BIGINT;
        WHILE @i <= @n
        BEGIN
            SET @Sid = (SELECT ShiftId FROM @Pick WHERE N = @i);
            BEGIN TRANSACTION;
            EXEC Oee.ShiftSummary_ComputeCore @ShiftId = @Sid;
            COMMIT TRANSACTION;
            SET @Done += 1;
            SET @i += 1;
        END

        SET @Stale  -= @Done;
        SET @Status  = 1;
        SET @Message = CAST(@Done AS NVARCHAR(20)) + N' shift(s) recomputed; '
                     + CAST(@Stale AS NVARCHAR(20)) + N' still stale.';
        SELECT @Status AS Status, @Message AS Message, @Done AS ShiftsComputed, @Stale AS ShiftsStillStale;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 AND XACT_STATE() = -1 ROLLBACK TRANSACTION;
        SET @Message = N'Oee.ShiftSummary_RefreshChanged: ' + ERROR_MESSAGE();
        SELECT @Status AS Status, @Message AS Message, @Done AS ShiftsComputed, @Stale AS ShiftsStillStale;
        DECLARE @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        RAISERROR(@Message, @ErrSev, @ErrState);
    END CATCH
END;
GO
