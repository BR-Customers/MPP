-- ============================================================
-- Repeatable:  R__Workorder_DieCastEntry_Restamp.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.0
-- Description: INTERNAL WORKER -- re-files recorded die cast rows against the
--              shift they belong to (spec 2026-09-21 sec 3.5, amendment A4).
--              Modelled on Oee.ShiftOverride_Restamp: the ShiftId is re-stamped
--              IN PLACE, and the durable record of where the row came from is
--              a Workorder.DieCastReconciliationMove row.
--
--              The facts do not change -- shots, pieces, LOTs and die life are
--              untouched. Only which shift is credited moves.
--
--              A row moved here is EXCLUDED from Oee.ShiftOverride_Restamp
--              from then on (amendment A2): that proc re-derives the shift
--              from EventAt, and an entry made at 09:35 for the night shift
--              would otherwise be dragged back the next time an override is
--              applied to the press. The team lead's reading of the press
--              sheet outranks the time-based resolver.
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. The
--              caller validates every row and target shift first.
--
-- Parameters (input):
--   @ReconciliationId BIGINT        - the header the moves are filed under.
--   @MovesJson        NVARCHAR(MAX) - [{"entityType":"Contribution"|"Reject",
--                                       "entityId":<id>,"toShiftId":<id>}]
--   @AppUserId        BIGINT        - audit attribution.
--
-- Result set: NONE. See header.
--
-- Error Handling:
--   None of its own -- no TRY/CATCH, no ROLLBACK. Errors propagate to the
--   caller's CATCH, which is the only legal ROLLBACK site.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 3.5).
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastEntry_Restamp
    @ReconciliationId   BIGINT,
    @MovesJson          NVARCHAR(MAX),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @MovesJson IS NULL OR ISJSON(@MovesJson) <> 1 RETURN;

    DECLARE @ContribTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DieCastContribution');
    DECLARE @RejectTypeId  BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'RejectEvent');

    DECLARE @M TABLE (EntityTypeId BIGINT, EntityId BIGINT, FromShiftId BIGINT, ToShiftId BIGINT);
    INSERT INTO @M (EntityTypeId, EntityId, FromShiftId, ToShiftId)
    SELECT CASE j.entityType WHEN N'Contribution' THEN @ContribTypeId ELSE @RejectTypeId END,
           j.entityId, COALESCE(c.ShiftId, r.ShiftId), j.toShiftId
    FROM OPENJSON(@MovesJson) WITH (entityType NVARCHAR(20) N'$.entityType', entityId BIGINT N'$.entityId',
                                    toShiftId BIGINT N'$.toShiftId') j
    LEFT JOIN Workorder.DieCastContribution c ON j.entityType = N'Contribution' AND c.Id = j.entityId
    LEFT JOIN Workorder.RejectEvent         r ON j.entityType = N'Reject'       AND r.Id = j.entityId
    WHERE COALESCE(c.ShiftId, r.ShiftId) IS NOT NULL
      AND COALESCE(c.ShiftId, r.ShiftId) <> j.toShiftId;

    UPDATE c SET c.ShiftId = m.ToShiftId
    FROM Workorder.DieCastContribution c
    INNER JOIN @M m ON m.EntityTypeId = @ContribTypeId AND m.EntityId = c.Id;

    UPDATE r SET r.ShiftId = m.ToShiftId
    FROM Workorder.RejectEvent r
    INNER JOIN @M m ON m.EntityTypeId = @RejectTypeId AND m.EntityId = r.Id;

    INSERT INTO Workorder.DieCastReconciliationMove (ReconciliationId, LogEntityTypeId, EntityId, FromShiftId, ToShiftId)
    SELECT @ReconciliationId, m.EntityTypeId, m.EntityId, m.FromShiftId, m.ToShiftId FROM @M m;

    -- ---- one audit row per apply, naming the pair when there is only one ----
    DECLARE @Total INT = (SELECT COUNT(*) FROM @M);
    IF @Total = 0 RETURN;
    DECLARE @PairCount INT = (SELECT COUNT(*) FROM (SELECT DISTINCT FromShiftId, ToShiftId FROM @M) p);
    DECLARE @FromLabel NVARCHAR(120) = NULL, @ToLabel NVARCHAR(120) = NULL;
    IF @PairCount = 1
        SELECT TOP 1
               @FromLabel = CONVERT(NVARCHAR(5), sf.ActualStart, 110) + N' ' + ssf.Name,
               @ToLabel   = CONVERT(NVARCHAR(5), st.ActualStart, 110) + N' ' + sst.Name
        FROM @M m
        INNER JOIN Oee.Shift sf ON sf.Id = m.FromShiftId INNER JOIN Oee.ShiftSchedule ssf ON ssf.Id = sf.ShiftScheduleId
        INNER JOIN Oee.Shift st ON st.Id = m.ToShiftId   INNER JOIN Oee.ShiftSchedule sst ON sst.Id = st.ShiftScheduleId;

    DECLARE @PressCode NVARCHAR(50) = (SELECT loc.Code FROM Workorder.DieCastShiftReconciliation h
                                       INNER JOIN Location.Location loc ON loc.Id = h.CellLocationId
                                       WHERE h.Id = @ReconciliationId);
    DECLARE @ActivityRaw NVARCHAR(MAX) =
        ISNULL(@PressCode, N'(unknown)') + N' ' + Audit.ufn_MidDot() + N' Die Cast ' + Audit.ufn_MidDot()
        + N' Moved ' + CAST(@Total AS NVARCHAR(10)) + N' rows'
        + CASE WHEN @PairCount = 1 THEN N' from ' + @FromLabel + N' to ' + @ToLabel
               ELSE N' across ' + CAST(@PairCount AS NVARCHAR(10)) + N' shift pairs' END;
    DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
    DECLARE @NewValue NVARCHAR(MAX) = (
        SELECT @Total AS RowsMoved, @PairCount AS DistinctShiftPairs,
               (SELECT COUNT(*) FROM @M WHERE EntityTypeId = @ContribTypeId) AS Contributions,
               (SELECT COUNT(*) FROM @M WHERE EntityTypeId = @RejectTypeId)  AS Rejects
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    EXEC Audit.Audit_LogOperation @AppUserId = @AppUserId, @TerminalLocationId = @TerminalLocationId,
        @LocationId = NULL, @LogEntityTypeCode = N'DieCastShiftReconciliation', @EntityId = @ReconciliationId,
        @LogEventTypeCode = N'DieCastEntryMoved', @LogSeverityCode = N'Warning',
        @Description = @Activity, @OldValue = NULL, @NewValue = @NewValue;
END;
GO
