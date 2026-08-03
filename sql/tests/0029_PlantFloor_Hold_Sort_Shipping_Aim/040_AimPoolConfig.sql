-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql
-- Description:  Lots.AimPoolConfig_Get / _Update (Arc 2 Phase 7). Get returns the
--               single seeded row; Update changes the thresholds.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql';
GO

DECLARE @G TABLE (Id INT, TargetBufferDepth INT, TopupThreshold INT, AlarmWarningDepth INT, AlarmCriticalDepth INT,
    AimBaseUrl NVARCHAR(200), AimCompanyCode NVARCHAR(10), AimPathToken NVARCHAR(50),
    PostWarningAgeMinutes INT, PostCriticalAgeMinutes INT, UpdatedAtEt DATETIME2(3), UpdatedByUserId BIGINT);
INSERT INTO @G EXEC Lots.AimPoolConfig_Get;
DECLARE @Tgt NVARCHAR(10) = (SELECT CAST(TargetBufferDepth AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual @TestName = N'[AimCfg] seeded TargetBufferDepth 50', @Expected = N'50', @Actual = @Tgt;
DECLARE @Cnt NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @G);
EXEC test.Assert_IsEqual N'[AimCfg] single config row', N'1', @Cnt;

-- update
DECLARE @U TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U EXEC Lots.AimPoolConfig_Update @TargetBufferDepth = 80, @TopupThreshold = 40, @AlarmWarningDepth = 25, @AlarmCriticalDepth = 12, @AppUserId = 2;
DECLARE @US NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @U);
EXEC test.Assert_IsEqual @TestName = N'[AimCfg] update Status 1', @Expected = N'1', @Actual = @US;
DECLARE @NewTgt NVARCHAR(10) = (SELECT CAST(TargetBufferDepth AS NVARCHAR(10)) FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual @TestName = N'[AimCfg] TargetBufferDepth updated to 80', @Expected = N'80', @Actual = @NewTgt;
DECLARE @NewWarn NVARCHAR(10) = (SELECT CAST(AlarmWarningDepth AS NVARCHAR(10)) FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual @TestName = N'[AimCfg] AlarmWarningDepth updated to 25', @Expected = N'25', @Actual = @NewWarn;

-- restore defaults
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Lots.AimPoolConfig_Update @TargetBufferDepth = 50, @TopupThreshold = 30, @AlarmWarningDepth = 20, @AlarmCriticalDepth = 10, @AppUserId = 2;
GO

-- connection + escalation settings (Migration 0049)
DECLARE @CfgUser BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @U TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth = 50, @TopupThreshold = 30,
    @AlarmWarningDepth = 20, @AlarmCriticalDepth = 10,
    @AimBaseUrl = N'http://172.17.10.86:8080', @AimCompanyCode = N'01',
    @AimPathToken = N'636652666553236784',
    @PostWarningAgeMinutes = 45, @PostCriticalAgeMinutes = 90,
    @AppUserId = @CfgUser;
DECLARE @UpdOk NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @U);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPoolConfig] update accepts connection + escalation settings',
    @Expected = N'1', @Actual = @UpdOk;

-- Round-trip block writes values DIFFERENT from what the seed already loaded, so the
-- assertion can only pass if the UPDATE actually wrote them (not merely "already there").
DECLARE @U2 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U2 EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth = 50, @TopupThreshold = 30,
    @AlarmWarningDepth = 20, @AlarmCriticalDepth = 10,
    @AimBaseUrl = N'http://10.0.0.99:8080', @AimCompanyCode = N'01',
    @AimPathToken = N'999999999999999999',
    @PostWarningAgeMinutes = 45, @PostCriticalAgeMinutes = 90,
    @AppUserId = @CfgUser;

DECLARE @Round NVARCHAR(80) = (SELECT AimBaseUrl + N'/' + AimPathToken + N'/'
    + CAST(PostWarningAgeMinutes AS NVARCHAR(10))
    FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPoolConfig] connection + escalation settings round-trip',
    @Expected = N'http://10.0.0.99:8080/999999999999999999/45', @Actual = @Round;

-- Restore the values the round-trip block overwrote, back to what the seed/setup block
-- established, so this file leaves the config as it found it.
DECLARE @U3 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U3 EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth = 50, @TopupThreshold = 30,
    @AlarmWarningDepth = 20, @AlarmCriticalDepth = 10,
    @AimBaseUrl = N'http://172.17.10.86:8080', @AimCompanyCode = N'01',
    @AimPathToken = N'636652666553236784',
    @PostWarningAgeMinutes = 45, @PostCriticalAgeMinutes = 90,
    @AppUserId = @CfgUser;
GO

-- Regression: the live threshold-admin screen (AimPoolConfig view -> code.py update() ->
-- AimPoolConfig_Update NQ) calls this proc with only the four original threshold args.
-- Before the v1.2 COALESCE fix, SQL Server applied the proc's literal parameter defaults
-- for every omitted argument, which unconditionally overwrote AimBaseUrl/AimCompanyCode/
-- AimPathToken to NULL and reset both escalation ages to 30/120 on every save.
DECLARE @CfgUser2 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @U4 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U4 EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth = 55, @TopupThreshold = 33,
    @AlarmWarningDepth = 22, @AlarmCriticalDepth = 11,
    @AppUserId = @CfgUser2;
DECLARE @U4Ok NVARCHAR(10) = (SELECT CAST(Status AS NVARCHAR(10)) FROM @U4);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPoolConfig] four-arg threshold save preserves AIM connection settings',
    @Expected = N'1', @Actual = @U4Ok;

DECLARE @Preserved NVARCHAR(120) = (SELECT AimCompanyCode + N'/' + AimPathToken + N'/'
    + AimBaseUrl + N'/'
    + CAST(PostWarningAgeMinutes AS NVARCHAR(10)) + N'/'
    + CAST(PostCriticalAgeMinutes AS NVARCHAR(10))
    FROM Lots.AimPoolConfig WHERE Id = 1);
EXEC test.Assert_IsEqual
    @TestName = N'[AimPoolConfig] four-arg threshold save preserves AIM connection settings - values unchanged',
    @Expected = N'01/636652666553236784/http://172.17.10.86:8080/45/90', @Actual = @Preserved;

-- restore thresholds to the file's baseline (50/30/20/10) so this file leaves the
-- config as it found it.
DECLARE @U5 TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @U5 EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth = 50, @TopupThreshold = 30,
    @AlarmWarningDepth = 20, @AlarmCriticalDepth = 10,
    @AppUserId = @CfgUser2;
GO

EXEC test.EndTestFile;
GO
