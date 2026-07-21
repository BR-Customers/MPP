-- =============================================
-- Migration:   0042_operationtype_scrap_additive.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-07-21
-- Description: Scrap-semantics reference rule (Jacques 2026-07-21). Die-cast scrap
--              is ADDITIVE: bad shots are pulled at the press and never enter the
--              basket, so the LOT holds the fulfilled GOOD count and scrap is extra
--              (NOT subtracted from the LOT). Downstream scrap (Trim / Machining /
--              Assembly) stays SUBTRACTIVE: a part already in the basket is pulled,
--              so it decrements the LOT (the D3 behavior in RejectEvent_Record).
--
--              Encodes the rule in SQL (not the caller): Parts.OperationType gains
--              ScrapIsAdditive BIT NOT NULL DEFAULT 0; DieCast = 1. RejectEvent_Record
--              derives @Additive from this column for the reject's @OperationTypeCode.
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF COL_LENGTH(N'Parts.OperationType', N'ScrapIsAdditive') IS NULL
    ALTER TABLE Parts.OperationType ADD ScrapIsAdditive BIT NOT NULL
        CONSTRAINT DF_OperationType_ScrapIsAdditive DEFAULT 0;
GO

-- Die Cast is the only additive operation today (bad shots never enter the basket).
UPDATE Parts.OperationType SET ScrapIsAdditive = 1 WHERE Code = N'DieCast';
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0042_operationtype_scrap_additive')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0042_operationtype_scrap_additive',
        N'Add Parts.OperationType.ScrapIsAdditive (BIT, DEFAULT 0); DieCast=1. Die-cast scrap is additive (not subtracted from the LOT); all others subtractive.');
GO

PRINT 'Migration 0042 (operationtype_scrap_additive) applied.';
GO
