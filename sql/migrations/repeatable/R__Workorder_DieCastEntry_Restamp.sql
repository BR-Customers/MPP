-- ============================================================
-- Repeatable:  R__Workorder_DieCastEntry_Restamp.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-22
-- Version:     1.2
-- Description: INTERNAL WORKER -- re-files recorded die cast rows against the
--              shift they belong to (spec 2026-09-21 sec 3.5, amendment A4).
--              Modelled on Oee.ShiftOverride_Restamp: the ShiftId is re-stamped
--              IN PLACE, and the durable record of where the row came from is
--              a Workorder.DieCastReconciliationMove row.
--
--              The facts do not change -- shots, pieces, LOTs and die life are
--              untouched. Only which shift is credited moves.
--
--              A contribution moved here is stamped
--              ShiftAttributionSourceId = Reconciled (1.2 / migration 0099),
--              which EXCLUDES it from Oee.ShiftOverride_Restamp from then on
--              (amendment A2): that proc re-derives the shift from EventAt, and
--              an entry made at 09:35 for the night shift would otherwise be
--              dragged back the next time an override is applied to the press.
--              The team lead's reading of the press sheet outranks the
--              time-based resolver. That stamp is now the ONLY thing saying so,
--              so the UPDATE below must always carry it.
--
--              EMITS NO RESULT SET, OWNS NO TRANSACTION, NO TRY/CATCH. The
--              caller validates every row and target shift first.
--
--              ---- WHAT IT REFUSES, AND WHY (1.1, code review 2026-09-24) ----
--              Version 1.0 returned SILENTLY in four cases: malformed JSON, an
--              entity row that does not exist, an entityType that is neither
--              Contribution nor Reject, and a current ShiftId that is NULL (the
--              last of those is no longer refused at all -- see 1.2 below). The
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
--                   IS NOT NULL filter dropped it -- and 1.2 DID loosen that
--                   filter, which would have started writing
--                   DieCastReconciliationMove rows under the WRONG entity type.
--                   (In 1.1 that also broke the Oee.ShiftOverride_Restamp
--                   exclusion, which keyed on the type; since 0099 it keys on a
--                   column instead, but a move row under the wrong type is still
--                   a durable lie about what happened.)
--                3. The payload is DEDUPLICATED on (EntityTypeId, EntityId).
--                   Naming the same row twice with two different toShiftIds gave
--                   a non-deterministic UPDATE and TWO move rows, one of which
--                   durably recorded a move that never happened. Structural
--                   here (GROUP BY + a table-variable PK); callers are not
--                   trusted for it.
--              A row that still resolves to nothing -- unknown id, unknown type
--              -- is dropped here, so the CALLER verifies its
--              payload landed. Workorder.DieCastShiftReconciliation_Save does
--              exactly that after this EXEC and fails the transaction if any
--              element neither moved nor was already on its target shift.
--
--              An element already ON its target shift is still skipped, which is
--              the feature's idempotency.
--
--              ---- A SHIFTLESS ROW CAN NOW BE RE-FILED (1.2, migration 0099) ----
--              1.1 left the IS NOT NULL filter excluding a contribution whose
--              ShiftId is NULL, noting it as an open question and that
--              Workorder.DieCastReconciliationMove.FromShiftId was NOT NULL
--              regardless. Both halves are resolved: FromShiftId is nullable, and
--              a shiftless row moves like any other, its move row recording NULL
--              for where it came from. A NULL attribution is precisely the gap
--              this feature exists to close -- Oee.ShiftOverride_Restamp
--              explicitly leaves a row it cannot resolve alone, so the system
--              does produce them, and until now nothing could ever file one.
--
--              That relaxation had a trap in it. FromShiftId IS NOT NULL was
--              doing TWO jobs: dropping a shiftless row AND dropping a row that
--              does not exist (the LEFT JOINs miss, so FromShiftId is NULL either
--              way). Only the first was meant to go, so 1.2 splits the existence
--              test out as EntityFound. Tests (3) in
--              0097_DieCast_Reconciliation/021_Workers_Lifecycle.sql -- "a row
--              that does not exist records no move" -- is what holds that line.
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
--   2026-09-25 - 1.2 - Migration 0099. (a) A contribution or reject with a NULL
--                      ShiftId can now be re-filed; the existence test is split
--                      out of the old FromShiftId IS NOT NULL so nothing else
--                      loosens with it, and the audit's FROM label LEFT-joins so
--                      a NULL origin cannot blank the whole description.
--                      (b) A moved contribution is stamped
--                      ShiftAttributionSourceId = Reconciled, which is now the
--                      single thing excluding it from Oee.ShiftOverride_Restamp.
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
    DECLARE @ReconciledSourceId BIGINT =
        (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Reconciled');

    -- The PK is the dedup made structural: at most one move per entity row, so
    -- neither the UPDATEs below nor the DieCastReconciliationMove insert can be
    -- fed a row twice. The GROUP BY is what keeps it from ever having to throw.
    -- FromShiftId is NULLABLE (1.2 / migration 0099): a row that had no shift at
    -- all is exactly the gap this feature exists to close, and NULL is how the
    -- move row says "it came from nowhere".
    DECLARE @M TABLE (EntityTypeId BIGINT NOT NULL, EntityId BIGINT NOT NULL,
                      FromShiftId BIGINT NULL, ToShiftId BIGINT NOT NULL,
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
               -- 1.2: the EXISTENCE test, split out of FromShiftId. Until now the
               -- two were the same condition -- FromShiftId IS NOT NULL dropped an
               -- unknown row AND a shiftless one -- so relaxing the shift half
               -- without this would have started writing moves, and
               -- DieCastReconciliationMove rows, for entity ids that do not exist.
               CASE WHEN c.Id IS NOT NULL OR r.Id IS NOT NULL THEN 1 ELSE 0 END AS EntityFound,
               p.toShiftId                    AS ToShiftId
        FROM OPENJSON(@MovesJson) WITH (entityType NVARCHAR(20) N'$.entityType', entityId BIGINT N'$.entityId',
                                        toShiftId BIGINT N'$.toShiftId') p
        LEFT JOIN Workorder.DieCastContribution c ON p.entityType = N'Contribution' AND c.Id = p.entityId
        LEFT JOIN Workorder.RejectEvent         r ON p.entityType = N'Reject'       AND r.Id = p.entityId
    ) j
    WHERE j.EntityTypeId IS NOT NULL      -- unknown entityType
      AND j.EntityId     IS NOT NULL
      AND j.EntityFound  = 1              -- the row it names does not exist
      AND j.ToShiftId    IS NOT NULL
      -- already on target: the idempotent skip. A shiftless row is never already
      -- there, so it always moves.
      AND (j.FromShiftId IS NULL OR j.FromShiftId <> j.ToShiftId)
    GROUP BY j.EntityTypeId, j.EntityId, j.FromShiftId;

    -- The shift AND where it came from, in ONE write (1.2 / migration 0099). A
    -- row this proc moved is the team lead's decision, and that stamp is now the
    -- only thing telling Oee.ShiftOverride_Restamp not to re-derive it.
    UPDATE c SET c.ShiftId = m.ToShiftId,
                 c.ShiftAttributionSourceId = @ReconciledSourceId
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
    -- The FROM side LEFT-joins (1.2): FromShiftId may be NULL now, and an INNER
    -- join would return no row, leave @FromLabel NULL, and silently collapse the
    -- whole @ActivityRaw concatenation below to NULL -- an audit row with no
    -- description. '(unattributed)' matches Oee.ShiftOverride_Restamp's wording
    -- for the same case.
    IF @PairCount = 1
        SELECT TOP 1
               @FromLabel = ISNULL(CONVERT(NVARCHAR(5), sf.ActualStart, 110) + N' ' + ssf.Name, N'(unattributed)'),
               @ToLabel   = CONVERT(NVARCHAR(5), st.ActualStart, 110) + N' ' + sst.Name
        FROM @M m
        LEFT  JOIN Oee.Shift sf ON sf.Id = m.FromShiftId LEFT  JOIN Oee.ShiftSchedule ssf ON ssf.Id = sf.ShiftScheduleId
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
