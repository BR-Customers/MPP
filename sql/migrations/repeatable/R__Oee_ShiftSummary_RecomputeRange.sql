-- =============================================
-- Procedure:   Oee.ShiftSummary_RecomputeRange
-- Author:      Blue Ridge Automation
-- Created:     2026-10-30
-- Version:     1.0
--
-- Description:
--   Recomputes the stored OEE figures of every CLOSED shift that starts in
--   [@FromUtc, @ToUtc) (OEE dashboard spec
--   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.1 sec 6.8):
--   the nightly 7-day safety net, the first fill at deployment, and the
--   explicit call after a data repair. One transaction per shift via
--   Oee.ShiftSummary_ComputeCore, so a long range never holds one long lock and
--   a failure keeps the shifts already done. The shift in progress is skipped.
--
--   Oee.Shift.ActualStart is LOCAL (OI-38); it is converted to UTC for the
--   range test. Shifts are done newest first.
--
-- Parameters:
--   @FromUtc   DATETIME2(3) - required.
--   @ToUtc     DATETIME2(3) - required, after @FromUtc.
--   @AppUserId BIGINT       - required.
--
-- Result set: Status BIT, Message NVARCHAR(500), ShiftsComputed INT.
--
-- Change Log:
--   2026-10-30 - 1.0 - Initial version.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.ShiftSummary_RecomputeRange
    @FromUtc   DATETIME2(3),
    @ToUtc     DATETIME2(3),
    @AppUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  BIT           = 0;
    DECLARE @Message NVARCHAR(500) = N'Unknown error';
    DECLARE @Done    INT           = 0;

    BEGIN TRY
        IF @FromUtc IS NULL OR @ToUtc IS NULL OR @AppUserId IS NULL OR @ToUtc <= @FromUtc
        BEGIN
            SET @Message = N'FromUtc, ToUtc (after FromUtc) and AppUserId are required.';
            SELECT @Status AS Status, @Message AS Message, @Done AS ShiftsComputed;
            RETURN;
        END

        DECLARE @Todo TABLE (N INT IDENTITY(1,1) PRIMARY KEY, ShiftId BIGINT);
        INSERT INTO @Todo (ShiftId)
        SELECT s.Id
        FROM Oee.Shift s
        CROSS APPLY (SELECT CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc) x
        WHERE s.ActualEnd IS NOT NULL
          AND x.StartUtc >= @FromUtc
          AND x.StartUtc <  @ToUtc
        ORDER BY s.ActualStart DESC;

        DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Todo), @Sid BIGINT;
        WHILE @i <= @n
        BEGIN
            SET @Sid = (SELECT ShiftId FROM @Todo WHERE N = @i);
            BEGIN TRANSACTION;
            EXEC Oee.ShiftSummary_ComputeCore @ShiftId = @Sid;
            COMMIT TRANSACTION;
            SET @Done += 1;
            SET @i += 1;
        END

        SET @Status  = 1;
        SET @Message = CAST(@Done AS NVARCHAR(20)) + N' shift(s) computed.';
        SELECT @Status AS Status, @Message AS Message, @Done AS ShiftsComputed;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 AND XACT_STATE() = -1 ROLLBACK TRANSACTION;
        SET @Message = N'Oee.ShiftSummary_RecomputeRange: ' + ERROR_MESSAGE();
        SELECT @Status AS Status, @Message AS Message, @Done AS ShiftsComputed;
        DECLARE @ErrSev INT = ERROR_SEVERITY(), @ErrState INT = ERROR_STATE();
        RAISERROR(@Message, @ErrSev, @ErrState);
    END CATCH
END;
GO
