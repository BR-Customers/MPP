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
    LowLimit DECIMAL(10,4), HighLimit DECIMAL(10,4));
GO

DECLARE @Item  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE');
DECLARE @NoTol BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE-NOTOL');
DECLARE @NoCfg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-JUDGE-NOCFG');

INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.2000;
UPDATE #J SET Label = N'inside' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.0000;
UPDATE #J SET Label = N'onLow' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.5000;
UPDATE #J SET Label = N'onHigh' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 17.9999;
UPDATE #J SET Label = N'justUnder' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = 18.5001;
UPDATE #J SET Label = N'justOver' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByWeight', @Weight = -0.0500;
UPDATE #J SET Label = N'negative' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @NoCfg, @ClosureMethod = N'ByWeight', @Weight = 18.2000;
UPDATE #J SET Label = N'noConfig' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Item, @ClosureMethod = N'ByVision', @Weight = 18.2000;
UPDATE #J SET Label = N'otherMethod' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
    EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @NoTol, @ClosureMethod = N'ByWeight', @Weight = 18.2000;
UPDATE #J SET Label = N'noTolerance' WHERE Label IS NULL;
INSERT INTO #J (Verdict, Message, Weight, TargetWeight, ToleranceWeight, LowLimit, HighLimit)
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
