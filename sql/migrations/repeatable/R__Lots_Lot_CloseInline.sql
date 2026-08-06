-- ============================================================
-- Repeatable:  R__Lots_Lot_CloseInline.sql
-- Author:      Blue Ridge Automation
-- Version:     1.0
-- Description: SILENT close helper (FAT #21). Transitions a LOT Good (1) -> Closed (4)
--              inline: status flip + LotStatusHistory row + 'LotStatusChanged' audit.
--              MIRRORS Lots.Lot_UpdateStatus's mutation block, but emits NO result set
--              so it can be EXEC'd from INSERT-EXEC-captured orchestrating procs
--              (Lots.Container_Complete, Quality.Hold_Release) which cannot EXEC the
--              status-row Lot_UpdateStatus. Runs inside the CALLER's transaction: it
--              declares no transaction and never ROLLBACKs. Good-only guard: if the LOT
--              is missing or not currently Good (Hold/Scrap/already Closed) it returns
--              silently, so callers may pass any candidate LOT without pre-filtering.
--              No OUTPUT params (FDS-11-011).
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Lot_CloseInline
    @LotId              BIGINT,
    @Reason             NVARCHAR(500),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @GoodStatusId BIGINT = 1, @ClosedStatusId BIGINT = 4;

    -- Good-only guard: skip missing / Hold / Scrap / already-Closed LOTs.
    DECLARE @Cur BIGINT = (SELECT LotStatusId FROM Lots.Lot WHERE Id = @LotId);
    IF @Cur IS NULL OR @Cur <> @GoodStatusId
        RETURN;

    DECLARE @LotName NVARCHAR(50) = (SELECT LotName FROM Lots.Lot WHERE Id = @LotId);

    DECLARE @OldValue NVARCHAR(MAX) = (
        SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @GoodStatusId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @NewValue NVARCHAR(MAX) = (
        SELECT JSON_QUERY((SELECT sc.Id, sc.Code, sc.Name FROM Lots.LotStatusCode sc WHERE sc.Id = @ClosedStatusId
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS Status
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(
        @LotName + N' ' + Audit.ufn_MidDot() + N' Status ' + Audit.ufn_MidDot()
        + N' Good' + NCHAR(8594) + N'Closed'
        + CASE WHEN @Reason IS NOT NULL THEN N' (' + @Reason + N')' ELSE N'' END);

    UPDATE Lots.Lot
    SET LotStatusId = @ClosedStatusId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
    WHERE Id = @LotId;

    INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
    VALUES (@LotId, @GoodStatusId, @ClosedStatusId, @Reason, @AppUserId, @TerminalLocationId, SYSUTCDATETIME());

    EXEC Audit.Audit_LogOperation
        @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId, @LocationId = NULL,
        @LogEntityTypeCode = N'Lot', @EntityId = @LotId, @LogEventTypeCode = N'LotStatusChanged',
        @LogSeverityCode = N'Info', @Description = @Activity, @OldValue = @OldValue, @NewValue = @NewValue;
END;
GO
