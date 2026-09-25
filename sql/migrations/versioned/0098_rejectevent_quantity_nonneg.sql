-- ============================================================
-- Migration:   0098_rejectevent_quantity_nonneg.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-25
-- Description: CK_RejectEvent_QuantityNonNeg -- a negative reject quantity is
--              legal only on a row a shift reconciliation wrote.
--
--              Migration 0097 gave Workorder.RejectEvent a ReconciliationId and
--              relaxed the sibling rule on Workorder.DieCastContribution to
--              CK_DieCastContribution_DeltaNonNeg = (PieceDelta >= 0 OR
--              ReconciliationId IS NOT NULL). Workorder.DieCastScrap_Write
--              writes a scrap quantity "as given: only the reconciliation
--              passes one" -- but RejectEvent.Quantity carried NO CHECK at all,
--              so a sign error in the reconciliation's scrap-gap arithmetic had
--              nothing structural catching it. This mirrors the contribution
--              rule onto the scrap side so the two halves of a reconciliation
--              are guarded the same way.
--
--              Live paths stay strictly positive and are unaffected:
--              Workorder.RejectEvent_Record refuses @Quantity <= 0, and
--              TrimOut_Record / TrimPartial_Record / MachiningOut_Mint each
--              refuse a scrap line with Quantity <= 0. This constraint is the
--              backstop for the paths that do NOT validate -- the die cast
--              JSON writers, which pass their line quantities through.
--
--              WITH CHECK, deliberately. A NOCHECK constraint is untrusted:
--              it still rejects new bad rows but the optimizer ignores it and
--              sys.check_constraints.is_not_trusted flags it forever, which is
--              a constraint in name only. Workorder.RejectEvent is partitioned
--              ON ps_MonthlyUtc(RecordedAt) and is NOT registered in
--              Audit.PartitionRetention, so it is never purged and only grows:
--              the validation scan is as cheap as it will ever be today. The
--              ALTER takes a Sch-M lock on the whole table for the length of
--              one scan, so it belongs in the deployment window with the plant
--              idle, not against a running shift.
--
--              The pre-check below scans the same predicate first, so a
--              violating row aborts the migration with a count and a pointer
--              instead of failing inside the ALTER.
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0098_rejectevent_quantity_nonneg')
BEGIN PRINT 'Migration 0098 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. gate: refuse to run if any existing row would violate the rule ----
IF EXISTS (SELECT 1 FROM Workorder.RejectEvent WHERE Quantity < 0 AND ReconciliationId IS NULL)
BEGIN
    DECLARE @Bad INT = (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE Quantity < 0 AND ReconciliationId IS NULL);
    DECLARE @MinId BIGINT = (SELECT MIN(Id) FROM Workorder.RejectEvent WHERE Quantity < 0 AND ReconciliationId IS NULL);
    DECLARE @GateMsg NVARCHAR(2044) = LEFT(
        N'Migration 0098 aborted: ' + CAST(@Bad AS NVARCHAR(20))
        + N' Workorder.RejectEvent row(s) have a negative Quantity with no ReconciliationId (first Id '
        + CAST(ISNULL(@MinId, 0) AS NVARCHAR(20))
        + N'). A negative reject is only meaningful as a reconciliation''s compensating row. Establish what wrote these'
        + N' -- query: SELECT Id, LotId, ToolId, ShiftId, DefectCodeId, Quantity, Remarks, RecordedAt FROM Workorder.RejectEvent'
        + N' WHERE Quantity < 0 AND ReconciliationId IS NULL; -- correct or attribute them, then re-run.', 2044);
    RAISERROR(@GateMsg, 16, 1);
    RETURN;
END
GO

-- ---- 2. the CHECK (mirrors CK_DieCastContribution_DeltaNonNeg, migration 0097) ----
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RejectEvent_QuantityNonNeg')
    ALTER TABLE Workorder.RejectEvent DROP CONSTRAINT CK_RejectEvent_QuantityNonNeg;
GO
ALTER TABLE Workorder.RejectEvent WITH CHECK ADD CONSTRAINT CK_RejectEvent_QuantityNonNeg
    CHECK (Quantity >= 0 OR ReconciliationId IS NOT NULL);
GO

-- ---- 3. record ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0098_rejectevent_quantity_nonneg')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0098_rejectevent_quantity_nonneg',
            N'CK_RejectEvent_QuantityNonNeg: a negative RejectEvent.Quantity is legal only on a reconciliation row, mirroring CK_DieCastContribution_DeltaNonNeg. Added WITH CHECK after a pre-flight gate for existing violations.');
GO
PRINT 'Migration 0098 (rejectevent_quantity_nonneg) applied.';
GO
