-- ============================================================
-- Migration:   0085_defectcode_warmup_999.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-15
-- Description: Renames defect code 'DC-999' (Warmup) to '999'.
--
--              Every defect code is a 3-digit number. The shop-floor
--              sheets (DCFM-0485 die cast, TSFM-0085 trim shop) are the
--              authority for the numbers themselves; 999 is the one
--              Blue Ridge addition, agreed with MPP. 'DC-999' was the
--              only code in the table that broke the rule -- confirmed
--              against MPP_MES_Prod on 2026-09-15, where it was the sole
--              row failing LIKE '[0-9][0-9][0-9]'.
--
--              This is a PURE RENAME. Workorder.RejectEvent.DefectCodeId
--              is an FK on DefectCode.Id, not Code, so the row's Id
--              (154 in prod) does not move and the 24 reject events
--              already booked against Warmup follow it untouched. No
--              event row is written, and no genealogy is disturbed.
--
--              Collision-checked: '999' was unused in prod.
--
--              Idempotent: no-ops if 'DC-999' is already gone, and
--              refuses to run if '999' somehow exists on a different row.
--
-- Change Log:
--   2026-09-15 - 1.0 - Initial version
-- ============================================================

-- ---- 1. Rename DC-999 -> 999 ----
IF EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = N'DC-999')
BEGIN
    IF EXISTS (SELECT 1 FROM Quality.DefectCode WHERE Code = N'999')
        RAISERROR(N'0085: cannot rename DC-999 to 999 -- code 999 already exists on another row. Resolve by hand.', 16, 1);
    ELSE
    BEGIN
        UPDATE Quality.DefectCode
           SET Code = N'999'
         WHERE Code = N'DC-999';

        PRINT '0085: DC-999 renamed to 999.';
    END
END
ELSE
    PRINT '0085: DC-999 not present -- nothing to rename.';
GO

-- ---- 2. Re-assert the Warmup classification ----
-- Mirrors 0084 section 7. Warmup is a process necessity, not a defect:
-- counted for material and yield, excluded from the reject percentage,
-- charged to Die Cast so it stays a visible departmental cost rather
-- than sitting in Unassigned.
DECLARE @ocDieCast BIGINT = (SELECT Id FROM Parts.OperationCategory WHERE Code = N'DieCast');
DECLARE @cpDieCast BIGINT = (SELECT Id FROM Quality.ChargeToParty    WHERE Code = N'DieCast');

UPDATE Quality.DefectCode
   SET OperationCategoryId = @ocDieCast,
       ChargeToPartyId     = @cpDieCast,
       IsNonRejectScrap    = 1
 WHERE Code = N'999';
GO

-- ---- 3. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0085_defectcode_warmup_999')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0085_defectcode_warmup_999',
            N'Quality.DefectCode ''DC-999'' (Warmup) renamed to ''999'' so every defect code is 3 digits. Pure rename -- RejectEvent FKs on Id, so booked Warmup rejects follow the row unchanged. Classification (DieCast category, DieCast charge, non-reject scrap) re-asserted.');
GO
PRINT 'Migration 0085 (defectcode_warmup_999) applied.';
