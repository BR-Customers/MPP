-- ============================================================
-- Migration:   0102_shippinglabel_print_error_condition.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-10-01
-- Description: Lots.ShippingLabel gains LastPrintErrorCondition -- the taxonomy
--              NAME of the last dispatch failure, beside the raw text already
--              in LastPrintError.
--
--              WHY. The 2026-09-29 failure taxonomy (spec section 6.3) exists
--              because each condition sends a diagnosis to a different machine:
--              EndpointUnresolved is configuration, DispatchFailed is the
--              service or the firewall, QueueRejected means the bridge ANSWERED
--              and the queue name is wrong. LabelTransport.operatorGuidance
--              turns each one into an instruction an operator can act on, and
--              it keys on the CONDITION, not on the error text.
--
--              Until now the condition was computed inside
--              LabelTransport._dispatchLogParams and written ONLY to
--              Audit.InterfaceLog.ErrorCondition. The async dispatch worker
--              persisted the raw socket message on the label row and nothing
--              else, so by the time the print-failure banner read the row the
--              name of the fault was gone -- and operatorGuidance fell through
--              to its generic "tell a supervisor and read them this message"
--              branch for EVERY async failure. The condition has to survive to
--              the terminal for the taxonomy to reach the person standing at
--              the printer.
--
--              WHY FREE TEXT, NOT A CODE TABLE. The repo rule is that
--              enum/status columns are code-table backed with an FK. The
--              precedent that wins here is Audit.InterfaceLog.ErrorCondition,
--              which is NVARCHAR(200) with no FK and is the SAME vocabulary
--              written by the SAME call -- the condition is produced by
--              LabelTransport.classifyOutcome, which is Gateway-side Jython, so
--              an FK could only be enforced by having the Gateway look the code
--              up before every write and would put the two columns out of step
--              on any value either side did not recognise. One owner
--              (classifyOutcome), two columns, same string. If the taxonomy
--              ever needs to be reportable by code, both columns move to a code
--              table together.
--
--              DEPLOYMENT. ADD <col> NULL with NO default is a metadata-only
--              change: SQL Server updates the catalog and does not touch a
--              single page, so there is no table rewrite and no Sch-M lock held
--              for the length of a scan. This does NOT need a window with the
--              presses idle -- unlike 0099's ADD ... NOT NULL ... DEFAULT on
--              Workorder.DieCastContribution, which rewrites the table on
--              Standard Edition. Lots.ShippingLabel is also not partitioned.
--
--              APPLY WITH. R__Lots_ShippingLabel_MarkDispatch (v1.1, writes the
--              column) and R__Lots_ShippingLabel_GetForBanner (v1.1, returns
--              it) in the same window. The read proc adding a column changes
--              the result-set shape, so anything capturing it via INSERT-EXEC
--              must be updated in step.
--
--              Spec: docs/superpowers/specs/
--              2026-09-29-zebra-bridge-service-and-print-traceability-design.md
--              sections 6.3 and 10.3.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0102_shippinglabel_print_error_condition')
BEGIN PRINT 'Migration 0102 already applied -- skipping.'; RETURN; END
GO

IF COL_LENGTH(N'[Lots].[ShippingLabel]', N'LastPrintErrorCondition') IS NULL
    ALTER TABLE Lots.ShippingLabel
        ADD LastPrintErrorCondition NVARCHAR(50) NULL;
GO

-- Guarded like 0079/0101: the top-of-file RETURN only exits its OWN batch.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0102_shippinglabel_print_error_condition')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0102_shippinglabel_print_error_condition',
            N'Lots.ShippingLabel.LastPrintErrorCondition NVARCHAR(50) NULL: the taxonomy name of the last dispatch failure, so the print-failure banner can word an instruction instead of the generic fallback. Metadata-only ADD. Apply with MarkDispatch v1.1 + GetForBanner v1.1.');
GO
PRINT 'Migration 0102 (shippinglabel_print_error_condition) applied.';
GO
