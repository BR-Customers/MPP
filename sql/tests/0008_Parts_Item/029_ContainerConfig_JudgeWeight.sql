-- =============================================
-- File:         0008_Parts_Item/029_ContainerConfig_JudgeWeight.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-06
-- Description:
--   Tests Parts.ContainerConfig_JudgeWeight -- the checkweigh verdict the MES
--   computes for IND570 scales read over EPrint (no PLC option card).
--   Covers: Ok inside the window, both limits inclusive, Under, Over, a
--   negative weight, NoConfig, NoTolerance (either value missing), NoWeight,
--   and that every path returns exactly one row.
--   v1.1: the scale's own UNDER / OVER / OK flags -- classified into
--   ScaleVerdict, compared into FlagsAgree, never changing Verdict. Covers
--   no flags, agreement, each disagreement, all-zero (NoTarget, not a
--   disagreement), two flags set / out-of-range / partial (Invalid), and
--   flags beside a non-comparable MES verdict (NoConfig).
--
--   Pre-conditions:
--     - Migration 0068 applied (Parts.ContainerConfig.ToleranceWeight)
--     - Parts.ContainerConfig_JudgeWeight deployed
--   Spec: docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md
-- =============================================

EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/029_ContainerConfig_JudgeWeight.sql';
GO

-- Setup: two host items -- one fully configured, one with no tolerance.
DELETE cc FROM Parts.ContainerConfig cc
INNER JOIN Parts.Item i ON i.Id = cc.ItemId
WHERE i.PartNumber IN (N'TEST-CC-JUDGE', N'TEST-CC-JUDGE-NOTOL', N'TEST-CC-JUDGE-NOCFG');
DELETE FROM Parts.Item WHERE PartNumber IN (N'TEST-CC-JUDGE', N'TEST-CC-JUDGE-NOTOL', N'TEST-CC-JUDGE-NOCFG');
GO

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-JUDGE',
    @Description = N'JudgeWeight host item', @UomId = 1, @AppUserId = 1;
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-JUDGE-NOTOL',
    @Description = N'JudgeWeight host item, no tolerance', @UomId = 1, @AppUserId = 1;
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-JUDGE-NOCFG',
    @Description = N'JudgeWeight host item, no config', @UomId = 1, @AppUserId = 1;

DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE');
DECLARE @NoTol BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE-NOTOL');

-- Window 18.0000 .. 18.5000
INSERT INTO @R EXEC Parts.ContainerConfig_Create @ItemId = @Item, @TraysPerContainer = 4,
    @PartsPerTray = 60, @IsSerialized = 0, @ClosureMethod = N'ByWeight',
    @TargetWeight = 18.2500, @ToleranceWeight = 0.2500, @AppUserId = 1;
INSERT INTO @R EXEC Parts.ContainerConfig_Create @ItemId = @NoTol, @TraysPerContainer = 4,
    @PartsPerTray = 60, @IsSerialized = 0, @ClosureMethod = N'ByWeight',
    @TargetWeight = 18.2500, @ToleranceWeight = NULL, @AppUserId = 1;
GO

CREATE TABLE #J (
    Label NVARCHAR(40) NULL,
    Verdict NVARCHAR(20), Message NVARCHAR(500), Weight DECIMAL(10,4),
    TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4),
    LowLimit DECIMAL(10,4), HighLimit DECIMAL(10,4),
    ScaleVerdict NVARCHAR(20), FlagsAgree BIT, FlagsMessage NVARCHAR(500));
GO

DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE');
DECLARE @NoTol BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE-NOTOL');
DECLARE @NoCfg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE-NOCFG');

INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000;
UPDATE #J SET Label = N'inside' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.0000;
UPDATE #J SET Label = N'onLow' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.5000;
UPDATE #J SET Label = N'onHigh' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 17.9999;
UPDATE #J SET Label = N'justUnder' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.5001;
UPDATE #J SET Label = N'justOver' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = -0.0500;
UPDATE #J SET Label = N'negative' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @NoCfg, @ClosureMethod = N'ByWeight', @Weight = 18.2000;
UPDATE #J SET Label = N'noConfig' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByVision', @Weight = 18.2000;
UPDATE #J SET Label = N'otherMethod' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @NoTol, @ClosureMethod = N'ByWeight', @Weight = 18.2000;
UPDATE #J SET Label = N'noTolerance' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = NULL;
UPDATE #J SET Label = N'noWeight' WHERE Label IS NULL;
GO

DECLARE @V NVARCHAR(20);

SET @V = (SELECT Verdict FROM #J WHERE Label = N'inside');
EXEC test.Assert_IsEqual @TestName = N'[Judge] inside the window is Ok', @Expected = N'Ok', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'onLow');
EXEC test.Assert_IsEqual @TestName = N'[Judge] exactly on the low limit is Ok (inclusive)', @Expected = N'Ok', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'onHigh');
EXEC test.Assert_IsEqual @TestName = N'[Judge] exactly on the high limit is Ok (inclusive)', @Expected = N'Ok', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'justUnder');
EXEC test.Assert_IsEqual @TestName = N'[Judge] one ten-thousandth below the low limit is Under', @Expected = N'Under', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'justOver');
EXEC test.Assert_IsEqual @TestName = N'[Judge] one ten-thousandth above the high limit is Over', @Expected = N'Over', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'negative');
EXEC test.Assert_IsEqual @TestName = N'[Judge] a negative weight is Under', @Expected = N'Under', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'noConfig');
EXEC test.Assert_IsEqual @TestName = N'[Judge] an item with no config is NoConfig', @Expected = N'NoConfig', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'otherMethod');
EXEC test.Assert_IsEqual @TestName = N'[Judge] a config for another closure method does not count', @Expected = N'NoConfig', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'noTolerance');
EXEC test.Assert_IsEqual @TestName = N'[Judge] a NULL tolerance is NoTolerance, never a zero-width window', @Expected = N'NoTolerance', @Actual = @V;

SET @V = (SELECT Verdict FROM #J WHERE Label = N'noWeight');
EXEC test.Assert_IsEqual @TestName = N'[Judge] a NULL weight is NoWeight', @Expected = N'NoWeight', @Actual = @V;

DECLARE @Limits NVARCHAR(60) = (SELECT CAST(LowLimit AS NVARCHAR(20)) + N'/' + CAST(HighLimit AS NVARCHAR(20))
                                FROM #J WHERE Label = N'inside');
EXEC test.Assert_IsEqual @TestName = N'[Judge] limits are Target -/+ Tolerance',
    @Expected = N'18.0000/18.5000', @Actual = @Limits;

DECLARE @Rows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #J);
EXEC test.Assert_IsEqual @TestName = N'[Judge] every call returned exactly one row',
    @Expected = N'10', @Actual = @Rows;

DECLARE @Blank NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #J WHERE ISNULL(Message, N'') = N'');
EXEC test.Assert_IsEqual @TestName = N'[Judge] every verdict carries a message',
    @Expected = N'0', @Actual = @Blank;
GO

-- ---- v1.1: the scale's own flags -------------------------------------------
TRUNCATE TABLE #J;
GO

DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE');
DECLARE @NoCfg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE-NOCFG');

INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000,
         @ScaleUnder = 0, @ScaleOver = 0, @ScaleOk = 1;
UPDATE #J SET Label = N'agreeOk' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 17.0000,
         @ScaleUnder = 1, @ScaleOver = 0, @ScaleOk = 0;
UPDATE #J SET Label = N'agreeUnder' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 19.0000,
         @ScaleUnder = 0, @ScaleOver = 1, @ScaleOk = 0;
UPDATE #J SET Label = N'agreeOver' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.0000,
         @ScaleUnder = 1, @ScaleOver = 0, @ScaleOk = 0;
UPDATE #J SET Label = N'scaleUnderMesOk' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 19.0000,
         @ScaleUnder = 0, @ScaleOver = 0, @ScaleOk = 1;
UPDATE #J SET Label = N'scaleOkMesOver' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000,
         @ScaleUnder = 0, @ScaleOver = 0, @ScaleOk = 0;
UPDATE #J SET Label = N'noTarget' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000,
         @ScaleUnder = 1, @ScaleOver = 0, @ScaleOk = 1;
UPDATE #J SET Label = N'twoFlags' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000,
         @ScaleUnder = 0, @ScaleOver = 0, @ScaleOk = 2;
UPDATE #J SET Label = N'outOfRange' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000,
         @ScaleUnder = NULL, @ScaleOver = 0, @ScaleOk = 1;
UPDATE #J SET Label = N'partial' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @NoCfg, @ClosureMethod = N'ByWeight', @Weight = 18.2000,
         @ScaleUnder = 0, @ScaleOver = 0, @ScaleOk = 1;
UPDATE #J SET Label = N'noConfigWithFlags' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit, ScaleVerdict, FlagsAgree, FlagsMessage)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000;
UPDATE #J SET Label = N'noFlags' WHERE Label IS NULL;
GO

-- One string per case: "<Verdict>|<ScaleVerdict>|<FlagsAgree>|<msg or nomsg>"
DECLARE @S NVARCHAR(100);
DECLARE @Shape TABLE (Label NVARCHAR(40), S NVARCHAR(100));
INSERT INTO @Shape SELECT Label, Verdict + N'|' + ISNULL(ScaleVerdict, N'-') + N'|'
    + ISNULL(CAST(FlagsAgree AS NVARCHAR(1)), N'-') + N'|'
    + CASE WHEN FlagsMessage IS NULL THEN N'nomsg' ELSE N'msg' END FROM #J;

SET @S = (SELECT S FROM @Shape WHERE Label = N'agreeOk');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] OK flag on an Ok tray agrees, no message', @Expected = N'Ok|Ok|1|nomsg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'agreeUnder');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] UNDER flag on an Under tray agrees', @Expected = N'Under|Under|1|nomsg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'agreeOver');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] OVER flag on an Over tray agrees', @Expected = N'Over|Over|1|nomsg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'scaleUnderMesOk');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] scale Under vs MES Ok (on the low limit) disagrees; MES verdict stays Ok', @Expected = N'Ok|Under|0|msg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'scaleOkMesOver');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] scale Ok vs MES Over disagrees; MES verdict stays Over', @Expected = N'Over|Ok|0|msg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'noTarget');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] all-zero flags are NoTarget, not a disagreement', @Expected = N'Ok|NoTarget|-|msg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'twoFlags');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] two flags set is Invalid, not compared', @Expected = N'Ok|Invalid|-|msg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'outOfRange');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] a flag value other than 0/1 is Invalid', @Expected = N'Ok|Invalid|-|msg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'partial');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] only some of the three flags supplied is Invalid', @Expected = N'Ok|Invalid|-|msg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'noConfigWithFlags');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] flags beside a NoConfig verdict are classified but not compared', @Expected = N'NoConfig|Ok|-|nomsg', @Actual = @S;
SET @S = (SELECT S FROM @Shape WHERE Label = N'noFlags');
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] no flags supplied leaves every scale column NULL', @Expected = N'Ok|-|-|nomsg', @Actual = @S;

DECLARE @Msg NVARCHAR(500) = (SELECT FlagsMessage FROM #J WHERE Label = N'scaleUnderMesOk');
DECLARE @HasLimits NVARCHAR(5) = CASE WHEN @Msg LIKE N'%18.0000 to 18.5000%' AND @Msg LIKE N'%Target Table%' THEN N'yes' ELSE N'no' END;
EXEC test.Assert_IsEqual @TestName = N'[Judge flags] a disagreement message names the MES window and the Target Table', @Expected = N'yes', @Actual = @HasLimits;
GO

DROP TABLE #J;
DELETE cc FROM Parts.ContainerConfig cc
INNER JOIN Parts.Item i ON i.Id = cc.ItemId
WHERE i.PartNumber IN (N'TEST-CC-JUDGE', N'TEST-CC-JUDGE-NOTOL', N'TEST-CC-JUDGE-NOCFG');
DELETE FROM Parts.Item WHERE PartNumber IN (N'TEST-CC-JUDGE', N'TEST-CC-JUDGE-NOTOL', N'TEST-CC-JUDGE-NOCFG');
GO

-- Device-type row the watcher routes on (migration 0105).
DECLARE @E NVARCHAR(20) = (SELECT ClosureMethodCode FROM Location.PlcDeviceType WHERE Code = N'ScaleStationEPrint');
EXEC test.Assert_IsEqual @TestName = N'[Judge] ScaleStationEPrint -> ByWeight', @Expected = N'ByWeight', @Actual = @E;
GO
