-- ============================================================
-- Migration:   0099_diecast_shift_attribution_source.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-25
-- Description: Two related changes to die cast shift attribution.
--
--              ---- 1. Oee.ShiftAttributionSource, and the column that names it
--
--              Workorder.DieCastContribution.ShiftId is a MATERIALIZED
--              attribution, not the truth. The truth is EventAt, and
--              Oee.ShiftOverride_Restamp exists to RE-DERIVE the attribution
--              from EventAt whenever a supervisor changes which shift a press
--              was running.
--
--              The die cast shift reconciliation (0097) broke that model's
--              assumption. A team lead deliberately files an entry under a
--              shift its EventAt does NOT fall in -- a night-shift entry keyed
--              at 09:35 the next morning keeps its real 09:35 stamp. That
--              ShiftId is AUTHORED, not derived, so the restamp must leave it
--              alone.
--
--              0097 expressed that as an exclusion spanning two tables:
--                  AND dc.ReconciliationId IS NULL
--                  AND NOT EXISTS (... Workorder.DieCastReconciliationMove
--                                  joined to Audit.LogEntityType ...)
--              Two correlated conditions, and any future writer that remembers
--              one but not the other silently reintroduces the bug. Worse, the
--              second one is keyed on a BARE ENTITY ID: DieCastContribution.Id
--              and RejectEvent.Id are independent IDENTITY sequences, so the
--              Audit.LogEntityType join in it is load-bearing and its absence
--              would be invisible.
--
--              This migration replaces both with ONE self-documenting column:
--              Workorder.DieCastContribution.ShiftAttributionSourceId, backed
--              by the new code table Oee.ShiftAttributionSource.
--
--              ---- WHY TWO VALUES AND NOT THREE ----
--              The obvious vocabulary is Derived / Reconciled / Override. It is
--              wrong. The question the column answers is exactly one thing:
--              "is this attribution still RE-DERIVABLE from EventAt?" A row
--              Oee.ShiftOverride_Restamp re-stamped is STILL DERIVED -- the
--              override changed the DERIVATION RULE (which shift the press was
--              running), not the AUTHORSHIP of the attribution. Stamping such a
--              row 'Override' would make the NEXT override skip it, which is
--              the opposite of what an override is for, and it would break the
--              reversibility that Oee.ShiftOverride_Apply's header calls out as
--              deliberate: "Deprecating the override and re-applying reverts
--              the equipment to the plant-global window and moves the same rows
--              back". A row stamped 'Override' could never move back.
--
--              So the vocabulary is the two states that actually differ in
--              behaviour:
--                Derived    -- resolved from EventAt; the resolver owns it and
--                              may re-derive it at any time, in either
--                              direction. This is the default.
--                Reconciled -- authored by a team lead's die cast shift
--                              reconciliation; NOT re-derivable from EventAt.
--                              The resolver never touches it.
--
--              Oee.ShiftAttributionSource lives in Oee, not Workorder: it is
--              shift-attribution vocabulary, the proc that consumes it
--              (Oee.ShiftOverride_Restamp) is in Oee, and Oee.DowntimeEvent
--              would use the same two values if it ever needs them.
--
--              Workorder.DieCastContribution is NOT partitioned (migration
--              0045 creates it on the default filegroup), so adding a NOT NULL
--              column with a default is an ordinary ALTER. It takes a Sch-M
--              lock for the length of the operation, so it belongs in the
--              deployment window, not against a running shift.
--
--              ---- 2. DieCastReconciliationMove.FromShiftId becomes nullable
--
--              0097 made it BIGINT NOT NULL, which means a contribution whose
--              ShiftId is already NULL can never be re-filed -- and a NULL
--              attribution is exactly the gap this feature exists to close.
--              Oee.ShiftOverride_Restamp explicitly handles NULL-shift
--              contributions ("A row whose instant resolves to NO shift ...
--              keeps whatever it already has"), so the system does produce
--              them; the same hole was independently hit on the trim work,
--              where Trim OUT's auto-stamped ShiftId is NULL when no Oee.Shift
--              instance covers the business date.
--
--              A NULL FromShiftId means "it had no shift before". The FK is
--              kept -- a foreign key permits NULL and still refuses a bad id.
--
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0099_diecast_shift_attribution_source')
BEGIN PRINT 'Migration 0099 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. the code table ----
IF OBJECT_ID(N'Oee.ShiftAttributionSource', N'U') IS NULL
    CREATE TABLE Oee.ShiftAttributionSource (
        Id          BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ShiftAttributionSource PRIMARY KEY,
        Code        NVARCHAR(50)  NOT NULL,
        Name        NVARCHAR(100) NOT NULL,
        Description NVARCHAR(500) NULL,
        SortOrder   INT           NOT NULL CONSTRAINT DF_SAS_SortOrder DEFAULT 0,
        CONSTRAINT UQ_ShiftAttributionSource_Code UNIQUE (Code)
    );
GO
MERGE Oee.ShiftAttributionSource AS t
USING (VALUES
    (N'Derived',    N'Derived from the event time',
     N'The ShiftId was resolved from the row''s EventAt by Oee.ufn_ShiftIdForInstant and is still re-derivable. Oee.ShiftOverride_Restamp owns rows in this state and may move them in either direction whenever a shift override is created, edited, deprecated or re-applied.', 1),
    (N'Reconciled', N'Authored by a shift reconciliation',
     N'The ShiftId was chosen by a team lead reconciling a past shift against its press sheet (Workorder.DieCastShiftReconciliation_Save). The row''s EventAt is deliberately NOT when the work happened -- a night-shift entry keyed at 09:35 the next morning keeps its 09:35 stamp -- so the attribution is not re-derivable. Oee.ShiftOverride_Restamp skips these rows.', 2)
) AS s (Code, Name, Description, SortOrder)
ON t.Code = s.Code
WHEN MATCHED THEN UPDATE SET t.Name = s.Name, t.Description = s.Description, t.SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT (Code, Name, Description, SortOrder) VALUES (s.Code, s.Name, s.Description, s.SortOrder);
GO

-- ---- 2. the column ----
-- The DEFAULT must be a constant, and Id is IDENTITY, so the constraint text is
-- built from the resolved Derived id rather than assuming it is 1.
IF COL_LENGTH('Workorder.DieCastContribution', 'ShiftAttributionSourceId') IS NULL
BEGIN
    DECLARE @DerivedId BIGINT = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Derived');
    IF @DerivedId IS NULL
    BEGIN
        RAISERROR(N'Migration 0099 aborted: Oee.ShiftAttributionSource has no Derived row to default to.', 16, 1);
        RETURN;
    END
    DECLARE @Sql NVARCHAR(MAX) =
        N'ALTER TABLE Workorder.DieCastContribution ADD ShiftAttributionSourceId BIGINT NOT NULL'
        + N' CONSTRAINT DF_DieCastContribution_ShiftAttributionSource DEFAULT ' + CAST(@DerivedId AS NVARCHAR(20))
        + N' CONSTRAINT FK_DieCastContribution_ShiftAttributionSource REFERENCES Oee.ShiftAttributionSource(Id);';
    EXEC sys.sp_executesql @Sql;
END
GO

-- ---- 3. backfill ----
-- The two conditions this column replaces, run ONCE, here, and never again:
-- a row a reconciliation WROTE (ReconciliationId) or MOVED (a
-- DieCastReconciliationMove row of the DieCastContribution entity type) is the
-- authored one. Everything else is derived and already carries the default.
UPDATE dc
SET    dc.ShiftAttributionSourceId = (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Reconciled')
FROM   Workorder.DieCastContribution dc
WHERE  dc.ShiftAttributionSourceId <> (SELECT Id FROM Oee.ShiftAttributionSource WHERE Code = N'Reconciled')
  AND (dc.ReconciliationId IS NOT NULL
       OR EXISTS (SELECT 1 FROM Workorder.DieCastReconciliationMove mv
                  INNER JOIN Audit.LogEntityType et ON et.Id = mv.LogEntityTypeId
                  WHERE et.Code = N'DieCastContribution' AND mv.EntityId = dc.Id));
GO

-- ---- 4. FromShiftId becomes nullable ----
-- No index or constraint is keyed on this column (PK is Id,
-- IX_DieCastReconciliationMove_Entity is on LogEntityTypeId + EntityId), so the
-- ALTER COLUMN is a plain metadata relaxation. FK_DCRM_FromShift is untouched
-- and still refuses an id that is not a shift.
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'Workorder.DieCastReconciliationMove')
             AND name = N'FromShiftId' AND is_nullable = 0)
    ALTER TABLE Workorder.DieCastReconciliationMove ALTER COLUMN FromShiftId BIGINT NULL;
GO

-- ---- 5. record ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0099_diecast_shift_attribution_source')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0099_diecast_shift_attribution_source',
            N'Oee.ShiftAttributionSource (Derived / Reconciled) and Workorder.DieCastContribution.ShiftAttributionSourceId: one self-documenting column replaces the two correlated conditions Oee.ShiftOverride_Restamp used to exclude reconciliation-authored rows. Backfilled from ReconciliationId + DieCastReconciliationMove. DieCastReconciliationMove.FromShiftId relaxed to NULL so a shiftless contribution can be re-filed.');
GO
PRINT 'Migration 0099 (diecast_shift_attribution_source) applied.';
GO
