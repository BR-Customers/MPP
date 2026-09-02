-- =============================================
-- File:         0069_Aggregate_Reports/010_schema.sql
-- Author:       Blue Ridge Automation
-- Description:  Migration 0067 -- ChargeToParty code table, the two DefectCode
--               classification columns, and RejectEvent.TerminalLocationId.
--
--               The two classifications are ORTHOGONAL and this file pins that:
--               ChargeToParty is responsibility (chargeback), OperationCategory
--               is process (screen filtering), IsNonRejectScrap is "counted but
--               excluded from reject %", and IsExcused is the OEE quality axis.
--               Conflating any pair silently corrupts the Plant Summary.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0069_Aggregate_Reports/010_schema.sql';
GO

DECLARE @n INT;

-- ---- Structure ----
SET @n = CASE WHEN OBJECT_ID(N'Quality.ChargeToParty', N'U') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[0067] Quality.ChargeToParty exists',
    @Expected = N'1', @Actual = @n;

SET @n = CASE WHEN COL_LENGTH(N'Quality.DefectCode', N'ChargeToPartyId') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[0067] DefectCode.ChargeToPartyId exists',
    @Expected = N'1', @Actual = @n;

SET @n = CASE WHEN COL_LENGTH(N'Quality.DefectCode', N'IsNonRejectScrap') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[0067] DefectCode.IsNonRejectScrap exists',
    @Expected = N'1', @Actual = @n;

SET @n = CASE WHEN COL_LENGTH(N'Workorder.RejectEvent', N'TerminalLocationId') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[0067] RejectEvent.TerminalLocationId exists',
    @Expected = N'1', @Actual = @n;

-- OperationCategoryId must SURVIVE -- the two are orthogonal dimensions.
SET @n = CASE WHEN COL_LENGTH(N'Quality.DefectCode', N'OperationCategoryId') IS NULL THEN 0 ELSE 1 END;
EXEC test.Assert_IsEqual @TestName = N'[0067] DefectCode.OperationCategoryId still exists (orthogonal, not replaced)',
    @Expected = N'1', @Actual = @n;

-- ---- Seed ----
SELECT @n = COUNT(*) FROM Quality.ChargeToParty;
EXEC test.Assert_IsEqual @TestName = N'[0067] six charge-to parties seeded',
    @Expected = N'6', @Actual = @n;

SELECT @n = COUNT(*) FROM Quality.ChargeToParty
WHERE Code IN (N'DieCast', N'TrimShop', N'MachineShop', N'DieMaintenance',
               N'MppNonSpecific', N'SupplierNonSpecific');
EXEC test.Assert_IsEqual @TestName = N'[0067] all six expected party codes present',
    @Expected = N'6', @Actual = @n;

-- ---- Backfill: every seeded defect code resolves a party ----
-- Every count in this block is scoped to the SEED (Code NOT LIKE 'TEST%').
-- These assert what migration 0067 backfilled, and 0067 only ever touched
-- seeded rows -- but earlier suites legitimately create their own TEST-*
-- defect codes and leave them behind (0011_Quality_Spec/040 leaves
-- TEST-DEF-001/002/003), so an unscoped COUNT(*) measures whichever tests
-- happened to run first. Same idiom as 0046_Shift_Reconcile and
-- 0062_Oee_ShiftAttribution. No seeded defect code contains "TEST".
SELECT @n = COUNT(*) FROM Quality.DefectCode
WHERE ChargeToPartyId IS NULL AND Code NOT LIKE N'TEST%';
EXEC test.Assert_IsEqual @TestName = N'[0067] no seeded defect code is left without a charge-to party',
    @Expected = N'0', @Actual = @n;

-- The two buckets 0048 collapsed into NULL are split apart again.
SELECT @n = COUNT(*) FROM Quality.DefectCode dc
INNER JOIN Quality.ChargeToParty p ON p.Id = dc.ChargeToPartyId
WHERE p.Code = N'SupplierNonSpecific';
EXEC test.Assert_IsEqual @TestName = N'[0067] the six HSP codes charge to Non-Specific Supplier',
    @Expected = N'6', @Actual = @n;

SELECT @n = COUNT(*) FROM Quality.DefectCode dc
INNER JOIN Quality.ChargeToParty p ON p.Id = dc.ChargeToPartyId
WHERE p.Code = N'MppNonSpecific';
EXEC test.Assert_IsEqual @TestName = N'[0067] the seven Prod-Control/Quality-Control codes charge to Non-Specific MPP',
    @Expected = N'7', @Actual = @n;

-- ---- Non-reject scrap: exactly the five named codes ----
SELECT @n = COUNT(*) FROM Quality.DefectCode
WHERE IsNonRejectScrap = 1 AND Code NOT LIKE N'TEST%';
EXEC test.Assert_IsEqual @TestName = N'[0067] exactly five codes flagged IsNonRejectScrap',
    @Expected = N'5', @Actual = @n;

SELECT @n = COUNT(*) FROM Quality.DefectCode
WHERE IsNonRejectScrap = 1 AND Code IN (N'107', N'170', N'229', N'230', N'199');
EXEC test.Assert_IsEqual @TestName = N'[0067] the flagged codes are Test/Trial/Assembled-on-NG',
    @Expected = N'5', @Actual = @n;

-- IsNonRejectScrap and IsExcused are DIFFERENT axes: no code carries both, and
-- the excused set is untouched by this migration.
SELECT @n = COUNT(*) FROM Quality.DefectCode
WHERE IsNonRejectScrap = 1 AND IsExcused = 1 AND Code NOT LIKE N'TEST%';
EXEC test.Assert_IsEqual @TestName = N'[0067] IsNonRejectScrap and IsExcused do not overlap',
    @Expected = N'0', @Actual = @n;

SELECT @n = COUNT(*) FROM Quality.DefectCode
WHERE IsExcused = 1 AND Code NOT LIKE N'TEST%';
EXEC test.Assert_IsEqual @TestName = N'[0067] the eight IsExcused codes are unchanged',
    @Expected = N'8', @Actual = @n;
GO
