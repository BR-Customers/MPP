-- ============================================================
-- Repeatable:  R__Workorder_DieCastEntry_Restamp.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.1
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
--              ---- WHAT IT REFUSES, AND WHY (1.1, code review 2026-09-24) ----
--              Version 1.0 returned SILENTLY in four cases: malformed JSON, an
--              entity row that does not exist, an entityType that is neither
--              Contribution nor Reject, and a current ShiftId that is NULL. The
--              last three were all swallowed by the IS NOT NULL filter, and
--              because a worker emits no result set a five-element payload that
--              resolved to zero rows was indistinguishable from an empty one --
--              the enclosing Save reported success either way. That is exactly
--              the failure this feature exists to prevent (a team lead's
--              decision disappearing with nobody watching), arriving through
--              the front door. Departure from the plan's SQL, approved by the
--              owner 2026-09-24. Three things changed:
--                1. Malformed JSON RAISERRORs (severity 16). A payload that is
--                   not JSON is a bug in the caller, never a no-op.
--                2. The entityType -> Audit.LogEntityType mapping is EXPLICIT.
--                   1.0's CASE ... ELSE @RejectTypeId typed every unrecognised
--                   string as a Reject, and the row was saved only by the
--                   coincidence that the Reject LEFT JOIN then failed and the
--                   IS NOT NULL filter dropped it. Loosen that filter later and
--                   the proc would start writing DieCastReconciliationMove rows
--                   under the WRONG entity type -- which is precisely what the
--                   Oee.ShiftOverride_Restamp exclusion keys on, so the
--                   exclusion would break silently.
--                3. The payload is DEDUPLICATED on (EntityTypeId, EntityId).
--                   Naming the same row twice with two different toShiftIds gave
--                   a non-deterministic UPDATE and TWO move rows, one of which
--                   durably recorded a move that never happened. Structural
--                   here (GROUP BY + a table-variable PK); callers are not
--                   trusted for it.
--              A row that still resolves to nothing -- unknown id, unknown type,
--              NULL current shift -- is dropped here, so the CALLER verifies its
--              payload landed. Workorder.DieCastShiftReconciliation_Save does
--              exactly that after this EXEC and fails the transaction if any
--              element neither moved nor was already on its target shift.
--
--              NOT changed, deliberately: the IS NOT NULL filter still excludes
--              a contribution whose ShiftId is NULL (whether a shiftless row
--              should be re-fileable at all is an open question, and
--              Workorder.DieCastReconciliationMove.FromShiftId is NOT NULL in
--              migration 0097 regardless); and an element already ON its target
--              shift is still skipped, which is the feature's idempotency.
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
--   None of its own -- no TRY/CATCH, no ROLLBACK. The malformed-payload
--   RAISERROR is correct here and a TRY/CATCH around it would not be: the error
--   propagates to the caller's CATCH, which is the only legal ROLLBACK site.
--
-- Change Log:
--   2026-09-22 - 1.0 - Initial version (die cast shift reconciliation, sec 3.5).
--   2026-09-24 - 1.1 - Hardening (code review; approved departure from the
--                      plan's SQL): malformed JSON RAISERRORs, the entity-type
--                      mapping is explicit with no ELSE, and the payload is
--                      deduplicated on (EntityTypeId, EntityId). See header
--                      "WHAT IT REFUSES, AND WHY".
-- ============================================================
CREATE OR ALTER PROCEDURE Workorder.DieCastEntry_Restamp
    @ReconciliationId   BIGINT,
    @MovesJson          NVARCHAR(MAX),
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Nothing to move is a legitimate call (the Save only EXECs this when it has
    -- moves, but a caller may pass NULL). A payload that is not JSON is not:
    -- severity 16 so it reaches the caller's CATCH and rolls the save back.
    IF @MovesJson IS NULL RETURN;
    IF ISJSON(@MovesJson) <> 1
    BEGIN
        RAISERROR(N'DieCastEntry_Restamp: @MovesJson is not valid JSON. Nothing was moved.', 16, 1);
        RETURN;
    END

    DECLARE @ContribTypeId BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DieCastContribution');
    DECLARE @RejectTypeId  BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'RejectEvent');

    -- The PK is the dedup made structural: at most one move per entity row, so
    -- neither the UPDATEs below nor the DieCastReconciliationMove insert can be
    -- fed a row twice. The GROUP BY is what keeps it from ever having to throw.
    DECLARE @M TABLE (EntityTypeId BIGINT NOT NULL, EntityId BIGINT NOT NULL,
                      FromShiftId BIGINT NOT NULL, ToShiftId BIGINT NOT NULL,
                      PRIMARY KEY (EntityTypeId, EntityId));
    INSERT INTO @M (EntityTypeId, EntityId, FromShiftId, ToShiftId)
    SELECT j.EntityTypeId, j.EntityId, j.FromShiftId, MIN(j.ToShiftId)
    FROM (
        -- EXPLICIT mapping: an entityType that is neither of the two known codes
        -- maps to NULL and is dropped by the filter below. No ELSE -- 1.0's ELSE
        -- typed an unrecognised string as a Reject (see header note 2).
        SELECT CASE WHEN p.entityType = N'Contribution' THEN @ContribTypeId
                    WHEN p.entityType = N'Reject'       THEN @RejectTypeId
               END                            AS EntityTypeId,
               p.entityId                     AS EntityId,
               COALESCE(c.ShiftId, r.ShiftId) AS FromShiftId,
               p.toShiftId                    AS ToShiftId
        FROM OPENJSON(@MovesJson) WITH (entityType NVARCHAR(20) N'$.entityType', entityId BIGINT N'$.entityId',
                                        toShiftId BIGINT N'$.toShiftId') p
        LEFT JOIN Workorder.DieCastContribution c ON p.entityType = N'Contribution' AND c.Id = p.entityId
        LEFT JOIN Workorder.RejectEvent         r ON p.entityType = N'Reject'       AND r.Id = p.entityId
    ) j
    WHERE j.EntityTypeId IS NOT NULL      -- unknown entityType
      AND j.EntityId     IS NOT NULL
      AND j.FromShiftId  IS NOT NULL      -- unknown row, or a NULL current shift (deliberate, see header)
      AND j.ToShiftId    IS NOT NULL
      AND j.FromShiftId <> j.ToShiftId    -- already on target: the idempotent skip
    GROUP BY j.EntityTypeId, j.EntityId, j.FromShiftId;

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
