-- ============================================================
-- Migration:   0086_defectcode_dc_attribution_prefix.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-15
-- Description: Prefixes 'DC - ' onto the Description of every defect code
--              charged to Die Cast.
--
--              The Machining & Assembly line production sheets record ALL
--              of a line's scrap. The sheet's 'D/C Rejects' / 'M/S Rejects'
--              headings are not two places -- they are the ATTRIBUTION of
--              scrap the M&A line found, so a missed audit upstream can be
--              identified. Carrying that attribution in the label means an
--              operator picking a code on the line can see which ones charge
--              back to die cast without reading a second column.
--
--              Code numbers are NOT touched. They exist in systems outside
--              the MES and are honoured as-is.
--
--              Idempotent: the NOT LIKE guard means re-running cannot
--              double-prefix.
--
-- Change Log:
--   2026-09-15 - 1.0 - Initial version
-- ============================================================

DECLARE @cpDieCast BIGINT = (SELECT Id FROM Quality.ChargeToParty WHERE Code = N'DieCast');

IF @cpDieCast IS NULL
    RAISERROR(N'0086: ChargeToParty ''DieCast'' not found.', 16, 1);
ELSE
BEGIN
    DECLARE @n INT;

    UPDATE Quality.DefectCode
       SET Description = N'DC - ' + Description
     WHERE ChargeToPartyId = @cpDieCast
       AND Description NOT LIKE N'DC - %';

    SET @n = @@ROWCOUNT;
    PRINT '0086: ' + CAST(@n AS NVARCHAR(10)) + ' die-cast-charged description(s) prefixed.';
END
GO

-- ---- Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0086_defectcode_dc_attribution_prefix')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0086_defectcode_dc_attribution_prefix',
            N'Quality.DefectCode.Description prefixed ''DC - '' for every code charged to Die Cast, so the M&A line sheet scrap attribution is visible in the picker label. Codes unchanged.');
GO
PRINT 'Migration 0086 (defectcode_dc_attribution_prefix) applied.';
