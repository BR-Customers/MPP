-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql
-- Description:  Lots.AimPoolConfig_Get / _Update (Arc 2 Phase 7). Get returns the
--               single seeded row; Update changes the thresholds.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/040_AimPoolConfig.sql';
GO

DECLARE @G TABLE (Id INT, TargetBufferDepth INT, TopupThreshold INT, AlarmWarningDepth INT, AlarmCriticalDepth INT, UpdatedAt DATETIME2(3), UpdatedByUserId BIGINT);
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

EXEC test.EndTestFile;
GO
