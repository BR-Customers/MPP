-- =============================================
-- File: 0049_AimIntegration/010_schema.sql
-- Desc: Migration 0049 - pool genericized, post-back columns, config columns,
--       Parts.Item.AimCustomerPartNumber.
--
-- Convention (load-bearing, unwritten elsewhere): Lots.AimShipperIdPool is
-- part-agnostic and global (Migration 0049). Any test in this suite that needs
-- an AIM pool ID must blanket-`DELETE FROM Lots.AimShipperIdPool` on entry and
-- top up its own IDs -- sql/seeds/028_seed_aim_pool_dev.sql's seeded IDs are
-- destroyed by the first pool-touching test file that runs earlier in the suite
-- and are NOT available mid-suite. This is exactly the failure mode that already
-- passed filtered and failed full once: a test that assumes the seeded pool is
-- still there. See sql/tests/0028_PlantFloor_Assembly/035_AimPool_claim_topup.sql
-- and sql/tests/0049_AimIntegration/030_postback_procs.sql for the reference
-- delete-then-insert-own-rows pattern.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/010_schema.sql';
GO

DECLARE @Gone NVARCHAR(10) =
    CASE WHEN COL_LENGTH(N'Lots.AimShipperIdPool', N'PartNumber') IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0049] AimShipperIdPool.PartNumber dropped',
    @Expected = N'1', @Actual = @Gone;

DECLARE @Cols NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.columns WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
      AND name IN (N'CustomerPartNumber', N'Quantity', N'LotNumber', N'PostedAt',
                   N'PostAttempts', N'LastPostAttemptAt', N'LastPostError'));
EXEC test.Assert_IsEqual
    @TestName = N'[0049] seven post-back columns present',
    @Expected = N'7', @Actual = @Cols;

DECLARE @OldIx NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
      AND name = N'IX_AimShipperIdPool_AvailableByPart');
EXEC test.Assert_IsEqual
    @TestName = N'[0049] per-part index dropped',
    @Expected = N'0', @Actual = @OldIx;

DECLARE @NewIx NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'Lots.AimShipperIdPool')
      AND name IN (N'IX_AimShipperIdPool_Available', N'IX_AimShipperIdPool_Unposted'));
EXEC test.Assert_IsEqual
    @TestName = N'[0049] generic + unposted indexes present',
    @Expected = N'2', @Actual = @NewIx;

DECLARE @Cfg NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10))
    FROM sys.columns WHERE object_id = OBJECT_ID(N'Lots.AimPoolConfig')
      AND name IN (N'AimBaseUrl', N'AimCompanyCode', N'AimPathToken',
                   N'PostWarningAgeMinutes', N'PostCriticalAgeMinutes'));
EXEC test.Assert_IsEqual
    @TestName = N'[0049] five AimPoolConfig columns present',
    @Expected = N'5', @Actual = @Cfg;

-- Migration 0051 (2026-08-04): the stored per-item AIM customer part is gone --
-- live AIM testing proved the value is DERIVABLE from Item.PartNumber
-- (dash-strip), so the column that had to be manually maintained is retired.
-- See Parts.ufn_AimCustomerPartNumber for the derivation + evidence.
DECLARE @ItemCol NVARCHAR(10) =
    CASE WHEN COL_LENGTH(N'Parts.Item', N'AimCustomerPartNumber') IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0051] Parts.Item.AimCustomerPartNumber dropped',
    @Expected = N'1', @Actual = @ItemCol;

DECLARE @GetProcGone NVARCHAR(10) =
    CASE WHEN OBJECT_ID(N'Parts.Item_GetAimCustomerPartNumber') IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0051] Parts.Item_GetAimCustomerPartNumber dropped',
    @Expected = N'1', @Actual = @GetProcGone;

DECLARE @SetProcGone NVARCHAR(10) =
    CASE WHEN OBJECT_ID(N'Parts.Item_SetAimCustomerPartNumber') IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0051] Parts.Item_SetAimCustomerPartNumber dropped',
    @Expected = N'1', @Actual = @SetProcGone;

-- Parts.ufn_AimCustomerPartNumber: strip dashes only, preserve embedded spaces,
-- NULL in -> NULL out. This is the evidence-backed replacement for the stored
-- column -- see the function header for the live-AIM-test table.
DECLARE @UfnDashed NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'AIM-P1-T3'));
EXEC test.Assert_IsEqual
    @TestName = N'[0051] ufn_AimCustomerPartNumber strips dashes',
    @Expected = N'AIMP1T3', @Actual = @UfnDashed;

-- The real evidence case: legacy MES material name for the verified-working part,
-- dashes stripped, embedded space preserved -> exactly the value that posted.
DECLARE @UfnSpace NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'11200-6FB -A000'));
EXEC test.Assert_IsEqual
    @TestName = N'[0051] ufn_AimCustomerPartNumber strips dashes and preserves the embedded space',
    @Expected = N'112006FB A000', @Actual = @UfnSpace;

DECLARE @UfnNull NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(NULL));
EXEC test.Assert_IsNull
    @TestName = N'[0051] ufn_AimCustomerPartNumber returns NULL for NULL input',
    @Value = @UfnNull;

-- ------------------------------------------------------------
-- v1.1: the -AEP / -ISP variant suffix.
-- MPP gives one part number to two different parts in two cases, so they are
-- stored suffixed. The suffix is a Blue Ridge convention AIM has never seen and
-- must not reach the wire -- unstripped it would send '193206A0 A510AEP' and draw
-- a "Blanket not found", the same failure class the function header records.
-- ------------------------------------------------------------
DECLARE @UfnAep NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'19320-6A0 -A510-AEP'));
EXEC test.Assert_IsEqual
    @TestName = N'[0055] ufn_AimCustomerPartNumber strips the -AEP variant suffix',
    @Expected = N'193206A0 A510', @Actual = @UfnAep;

DECLARE @UfnIsp NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'19320-6A0 -A510-ISP'));
EXEC test.Assert_IsEqual
    @TestName = N'[0055] ufn_AimCustomerPartNumber strips the -ISP variant suffix',
    @Expected = N'193206A0 A510', @Actual = @UfnIsp;

-- Both variants must collapse to the SAME Honda part number -- that is the whole
-- point of the suffix being ours and not Honda's.
DECLARE @UfnSame NVARCHAR(10) = CASE WHEN @UfnAep = @UfnIsp THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0055] -AEP and -ISP variants derive the same AIM customer part',
    @Expected = N'1', @Actual = @UfnSame;

-- The other split pair, whose embedded space sits before the suffix.
DECLARE @UfnWp NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'19410-6A0 -A000-ISP'));
EXEC test.Assert_IsEqual
    @TestName = N'[0055] variant strip preserves the embedded space (water passage)',
    @Expected = N'194106A0 A000', @Actual = @UfnWp;

-- REGRESSION GUARD. The strip is anchored on the dash and runs BEFORE dash
-- removal, so a part number merely CONTAINING or ENDING IN those letters without
-- the dash boundary must come through untouched.
DECLARE @UfnBareAep NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'12345-6AEP'));
EXEC test.Assert_IsEqual
    @TestName = N'[0055] a bare AEP ending (no dash boundary) is NOT stripped',
    @Expected = N'123456AEP', @Actual = @UfnBareAep;

DECLARE @UfnMidAep NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'11200-AEP -A000'));
EXEC test.Assert_IsEqual
    @TestName = N'[0055] AEP in the middle of a part number is NOT stripped',
    @Expected = N'11200AEP A000', @Actual = @UfnMidAep;

-- THE EVIDENCE CASE, re-asserted after the v1.1 change: the part that actually
-- posted to live AIM (serial 000000034, 2026-08-05) must still derive byte-identically.
DECLARE @UfnProven NVARCHAR(50) = (SELECT Parts.ufn_AimCustomerPartNumber(N'11200-6FB -A000'));
EXEC test.Assert_IsEqual
    @TestName = N'[0055] v1.1 does not disturb the proven live-AIM value',
    @Expected = N'112006FB A000', @Actual = @UfnProven;

-- All four split variants, asserted over a literal list rather than Parts.Item:
-- this test DB is built from migrations + sql/seeds only, and the MPP part list
-- lives in sql/scratch/, so a query over Parts.Item would find nothing here and
-- pass trivially. The literals make the guard real regardless of what is loaded.
DECLARE @V TABLE (Pn NVARCHAR(50), Expected NVARCHAR(50));
INSERT INTO @V (Pn, Expected) VALUES
 (N'19320-6A0 -A510-AEP', N'193206A0 A510'),
 (N'19320-6A0 -A510-ISP', N'193206A0 A510'),
 (N'19410-6A0 -A000-AEP', N'194106A0 A000'),
 (N'19410-6A0 -A000-ISP', N'194106A0 A000');

DECLARE @Wrong NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @V
    WHERE Parts.ufn_AimCustomerPartNumber(Pn) <> Expected);
EXEC test.Assert_IsEqual
    @TestName = N'[0055] all four AEP/ISP variants derive their Honda part number',
    @Expected = N'0', @Actual = @Wrong;

DECLARE @Leaked NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @V
    WHERE Parts.ufn_AimCustomerPartNumber(Pn) LIKE N'%AEP'
       OR Parts.ufn_AimCustomerPartNumber(Pn) LIKE N'%ISP');
EXEC test.Assert_IsEqual
    @TestName = N'[0055] no variant leaks its suffix into the value sent to AIM',
    @Expected = N'0', @Actual = @Leaked;

DECLARE @Defaults NVARCHAR(20) = (SELECT
    CAST(PostWarningAgeMinutes AS NVARCHAR(10)) + N'/' + CAST(PostCriticalAgeMinutes AS NVARCHAR(10))
    FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] escalation defaults 30/120 on the config row',
    @Expected = N'30/120', @Actual = @Defaults;

-- Migration 0050: the transport-layer gate. AIM calls consume serials that can
-- never be handed back, so the integration must ship inert until deliberately
-- enabled per environment -- assert both that the column exists and that its
-- seeded value on the Id=1 row is 0 (off).
DECLARE @GateCol NVARCHAR(10) =
    CASE WHEN COL_LENGTH(N'Lots.AimPoolConfig', N'AimPostingEnabled') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0050] AimPoolConfig.AimPostingEnabled column present',
    @Expected = N'1', @Actual = @GateCol;

DECLARE @GateVal NVARCHAR(10) = (SELECT CAST(AimPostingEnabled AS NVARCHAR(10))
    FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[0050] AimPostingEnabled seeded 0 (off) on the config row',
    @Expected = N'0', @Actual = @GateVal;
GO

EXEC test.EndTestFile;
GO
