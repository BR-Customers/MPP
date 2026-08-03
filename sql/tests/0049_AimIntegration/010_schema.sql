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

DECLARE @ItemCol NVARCHAR(10) =
    CASE WHEN COL_LENGTH(N'Parts.Item', N'AimCustomerPartNumber') IS NOT NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[0049] Parts.Item.AimCustomerPartNumber present',
    @Expected = N'1', @Actual = @ItemCol;

DECLARE @Defaults NVARCHAR(20) = (SELECT
    CAST(PostWarningAgeMinutes AS NVARCHAR(10)) + N'/' + CAST(PostCriticalAgeMinutes AS NVARCHAR(10))
    FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[0049] escalation defaults 30/120 on the config row',
    @Expected = N'30/120', @Actual = @Defaults;
GO

EXEC test.EndTestFile;
GO
