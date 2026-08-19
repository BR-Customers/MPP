-- =============================================
-- Migration:   0060_lot_attribute_change_reason.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-19
-- Description: Backlog 5.3 - "Rectify LOT counts in Lot Detail when entered wrong,
--              with a mandatory reason."
--
--              Lots.LotAttributeChange is the append-only log of LOT header
--              corrections (today: PieceCount). It records WHAT changed but not
--              WHY, so an after-the-fact piece-count correction is unexplainable
--              from the LOT timeline. Add a nullable Reason so the operator's
--              mandatory justification is stored next to the Old/New values and
--              can be rendered by Lots.Lot_GetAttributeHistory.
--
--              NULLable, not NOT NULL: the column is retrofitted onto existing
--              rows, and Lots.Lot_UpdateAttribute (the internal Lot_Split helper)
--              legitimately has no operator reason. The MANDATORY-ness lives in
--              Lots.Lot_RectifyPieceCount, which rejects a blank reason before
--              BEGIN TRANSACTION.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF COL_LENGTH(N'Lots.LotAttributeChange', N'Reason') IS NULL
    ALTER TABLE Lots.LotAttributeChange ADD Reason NVARCHAR(500) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0060_lot_attribute_change_reason')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0060_lot_attribute_change_reason',
        N'Add Lots.LotAttributeChange.Reason (NVARCHAR(500) NULL) - operator justification for a LOT piece-count rectification (backlog 5.3).');
GO

PRINT 'Migration 0060 (lot_attribute_change_reason) applied.';
GO
