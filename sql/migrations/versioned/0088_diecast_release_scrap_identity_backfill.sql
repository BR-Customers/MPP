-- ============================================================
-- Migration:   0088_diecast_release_scrap_identity_backfill.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-15
-- Description: Repairs the die-cast RELEASE scrap rows that 0084 left
--              unlabelled. Companion to R__Lots_DieCastLot_Release v2.2, which
--              stops the bleeding; this migration cleans up behind it.
--
--              WHAT WENT WRONG. 0084 made die-cast scrap a fact about
--              (Shift, Press, Tool, Cavity, Part), stamped on the reject row
--              and never derived back through the LOT. Two writers were
--              updated to stamp it. Lots.DieCastLot_Release was updated in
--              only ONE of its two INSERTs: v2.1 taught the CONTRIBUTION row
--              to carry its cavity, and the RejectEvent insert a few lines
--              below it kept the pre-0084 column list -- writing NULL for
--              ItemId, ToolId, ToolCavityId, ShiftId and CellLocationId.
--
--              WHY IT MATTERED. Workorder.DieCast_GetShiftOutputBreakdown
--              scopes PriorScrapThisShift by ShiftId + ToolCavityId, so those
--              rows are unreachable: the SHIFT SCRAP column on Reconcile Shift
--              reported 0 for scrap an operator had genuinely recorded, and no
--              amount of Compute or Refresh would ever change it -- it
--              presented as a broken refresh rather than as missing data.
--              Quality.Reject_GetPartMatrix / _SearchDetail resolve the part
--              from re.ItemId with no fallback, so the same rows also grouped
--              under '(unassigned part)' on the plant scrap matrix.
--
--              SCOPE: rows with Remarks = N'Die-cast final release scrap'
--              ONLY. That Remarks value is written by exactly one INSERT in
--              one proc, so it is an exact fingerprint for the affected class
--              and cannot reach anything else.
--
--              DELIBERATELY NOT IN SCOPE. R__Workorder_TrimOut_Record and
--              R__Workorder_MachiningOut_Mint have the SAME missing-stamp bug
--              ('Trim OUT scrap' / 'Machining OUT scrap'), so their rejects
--              also group under '(unassigned part)'. They are NOT repaired
--              here: the proc fix has to land first, or the next release
--              writes a fresh crop of unlabelled rows behind this backfill.
--              Those are die-cast-free operations, so ToolCavityId must stay
--              NULL for them and the repair is a different shape. Tracked
--              separately -- do not assume this migration handled them.
--
--              IDEMPOTENT. Every UPDATE is guarded on the target column still
--              being NULL and on the source resolving, so a re-run is a no-op
--              and a PARTIAL repair can simply be re-run.
-- ============================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---- 1. Part, die and cavity, from the basket the scrap was entered against.
-- The LOT is the authority for all three: a die-cast basket is opened against
-- one cavity of one die and never moves between them. These are recoverable
-- for every row that has a LotId, which is all of them -- release scrap is
-- entered while closing a specific basket, so LotId is never NULL here.
UPDATE re
   SET re.ItemId       = COALESCE(re.ItemId,       l.ItemId),
       re.ToolId       = COALESCE(re.ToolId,       l.ToolId),
       re.ToolCavityId = COALESCE(re.ToolCavityId, l.ToolCavityId)
FROM Workorder.RejectEvent re
INNER JOIN Lots.Lot l ON l.Id = re.LotId
WHERE re.Remarks = N'Die-cast final release scrap'
  AND (re.ItemId IS NULL OR re.ToolId IS NULL OR re.ToolCavityId IS NULL);
DECLARE @Identity INT = @@ROWCOUNT;
PRINT '0088: labelled part/die/cavity on ' + CAST(@Identity AS NVARCHAR(10)) + ' release-scrap row(s).';
GO

-- ---- 2. Shift and press, from the contribution row written beside it.
-- Both rows are written by the same proc inside ONE transaction, so they are
-- milliseconds apart; a 5-second window is slack, not a search. The shift is
-- taken from the contribution rather than derived from RecordedAt because the
-- operator SELECTS the reporting shift and may be closing out a backdated one
-- -- the recorded timestamp would silently disagree with what they reported.
-- A basket is released exactly once, so there is no second release to confuse.
--
-- The contribution row is CONDITIONAL in the proc (written only when a counter
-- reading or a positive final delta was supplied), so a release with scrap but
-- neither has no partner row. Those keep NULL ShiftId/CellLocationId: this
-- migration labels what it can prove and NEVER infers a shift, because a wrong
-- shift is worse than an absent one -- it silently moves someone's scrap onto
-- another crew's numbers.
UPDATE re
   SET re.ShiftId        = COALESCE(re.ShiftId,        c.ShiftId),
       re.CellLocationId = COALESCE(re.CellLocationId, c.CellLocationId)
FROM Workorder.RejectEvent re
CROSS APPLY (SELECT TOP 1 dc.ShiftId, dc.CellLocationId
             FROM Workorder.DieCastContribution dc
             WHERE dc.LotId = re.LotId
               AND ABS(DATEDIFF(SECOND, dc.EventAt, re.RecordedAt)) <= 5
             ORDER BY ABS(DATEDIFF(SECOND, dc.EventAt, re.RecordedAt)), dc.Id DESC) c
WHERE re.Remarks = N'Die-cast final release scrap'
  AND (re.ShiftId IS NULL OR re.CellLocationId IS NULL);
DECLARE @Paired INT = @@ROWCOUNT;
PRINT '0088: labelled shift/press on ' + CAST(@Paired AS NVARCHAR(10)) + ' release-scrap row(s).';
GO

-- ---- 3. Say plainly what could not be repaired.
-- A silent partial backfill is how the next person concludes the data was
-- clean. If this prints a non-zero count, those rows stay invisible to the
-- SHIFT SCRAP column and need a decision, not a re-run.
DECLARE @Unrepaired INT = (
    SELECT COUNT(*) FROM Workorder.RejectEvent
    WHERE Remarks = N'Die-cast final release scrap'
      AND (ItemId IS NULL OR ToolId IS NULL OR ToolCavityId IS NULL
           OR ShiftId IS NULL OR CellLocationId IS NULL));
IF @Unrepaired > 0
    PRINT '0088: WARNING -- ' + CAST(@Unrepaired AS NVARCHAR(10))
        + ' release-scrap row(s) still carry a NULL label and remain invisible'
        + ' to the SHIFT SCRAP column. Most likely a release taken with no'
        + ' counter reading and no final delta, which writes no contribution'
        + ' row to pair against. These need a decision, not a re-run.';
ELSE
    PRINT '0088: every release-scrap row is now fully labelled.';
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0088_diecast_release_scrap_identity_backfill')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0088_diecast_release_scrap_identity_backfill',
            N'Backfills ItemId/ToolId/ToolCavityId (from Lots.Lot) and ShiftId/CellLocationId (from the DieCastContribution written in the same transaction) onto Workorder.RejectEvent rows with Remarks = ''Die-cast final release scrap'', which Lots.DieCastLot_Release wrote unlabelled between 0084 and v2.2. Those rows were invisible to DieCast_GetShiftOutputBreakdown.PriorScrapThisShift, so Reconcile Shift read 0 for recorded scrap. Trim OUT / Machining OUT share the defect, NOT repaired here.');
GO
PRINT 'Migration 0088 (diecast_release_scrap_identity_backfill) applied.';
GO
