-- ============================================================
-- Migration:   0075_defectcode_scale_adjustment.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-10
-- Description: Plant testing feedback. Adds one Trim Shop scrap reason,
--              'Scale Adjustment' (code 260), to Quality.DefectCode.
--
--              CODE NUMBER. The FRS Appendix E set runs 100-256. 146 -- the
--              obvious next number after the Trim block (140-145) -- is
--              already 'Chatter' under MachiningAssembly. The only free
--              numbers inside the FRS range are 155, 193, 196 and 251, each
--              sitting mid-band where Flexware could still fill it. So MPP
--              additions start at 260, above the FRS maximum, where ours stay
--              distinguishable from theirs forever.
--
--              CLASSIFICATION. An ordinary scrap reason, exactly like the six
--              Trim codes it joins: OperationCategory Trim, IsExcused = 0,
--              IsNonRejectScrap = 0, charged to TrimShop. It counts against
--              reject percentage. (If MPP later decides a scale
--              reconciliation should be excluded from that percentage, the
--              change is IsNonRejectScrap = 1 and nothing else.)
--
--              APPLIED IN TWO PLACES, following the 0048 / 0067 precedent. A
--              database reset runs migrations BEFORE seeds, so this migration
--              alone would no-op on a fresh build; seed 030 carries the same
--              row for that path. THIS file is what fixes Dev and Prod in
--              place, where the defect codes already exist and seeds are not
--              re-run. Keep the two in step if the row ever changes.
--
--              Additive. Idempotent-guarded; no explicit transaction (repo
--              convention -- see 0067). ASCII-only.
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0075_defectcode_scale_adjustment')
BEGIN
    PRINT 'Migration 0075 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Quality.DefectCode 260 -- Scale Adjustment (Trim Shop)
-- ============================================================
DECLARE @Trim BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');

IF @Trim IS NULL
    RAISERROR(N'Parts.OperationCategory ''Trim'' is missing -- cannot scope the new defect code.', 16, 1);
GO

DECLARE @Trim BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'Trim');

INSERT INTO Quality.DefectCode (Code, Description, OperationCategoryId, IsExcused)
SELECT N'260', N'Scale Adjustment', @Trim, 0
WHERE NOT EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = N'260');
GO

-- ============================================================
-- 2. Charge-to party -- TrimShop, matching its OperationCategory
--
-- Guarded on the column, so this migration still applies cleanly to a
-- database that predates 0067. Only fills a NULL: if someone has already
-- classified the row by hand, that decision wins.
-- ============================================================
IF COL_LENGTH(N'Quality.DefectCode', N'ChargeToPartyId') IS NOT NULL
BEGIN
    DECLARE @cpTrimShop BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'TrimShop');

    UPDATE Quality.DefectCode
       SET ChargeToPartyId = @cpTrimShop
     WHERE Code = N'260' AND ChargeToPartyId IS NULL AND @cpTrimShop IS NOT NULL;
END
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0075_defectcode_scale_adjustment')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0075_defectcode_scale_adjustment',
        N'Trim Shop scrap reason 260 Scale Adjustment -- charged to TrimShop, counts against reject percentage. Opens the MPP-additions code band at 260, above the FRS Appendix E maximum of 256.'
    );
GO

PRINT 'Migration 0075 completed: defect code 260 Scale Adjustment.';
GO
