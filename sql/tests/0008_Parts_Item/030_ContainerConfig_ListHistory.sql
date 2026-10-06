-- =============================================
-- File:         0008_Parts_Item/030_ContainerConfig_ListHistory.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-10-06
-- Description:
--   Tests Parts.ContainerConfig_ListHistory -- the past pack-out value sets
--   the shop-floor Pack-Out popup offers to reload.
--   Covers: an Update's replaced values appear; newest first; a set equal to
--   the current active config is left out; identical sets collapse; a
--   cleared (deprecated) pack-out appears; an item with no history returns
--   no rows; the label is ASCII.
--
--   Pre-conditions:
--     - Migration 0068 applied (Parts.ContainerConfig.ToleranceWeight)
--     - Parts.ContainerConfig_ListHistory deployed
-- =============================================

EXEC test.BeginTestFile @FileName = N'0008_Parts_Item/030_ContainerConfig_ListHistory.sql';
GO

DELETE cc FROM Parts.ContainerConfig cc
INNER JOIN Parts.Item i ON i.Id = cc.ItemId
WHERE i.PartNumber IN (N'TEST-CC-HIST', N'TEST-CC-HIST-NONE');
DELETE FROM Parts.Item WHERE PartNumber IN (N'TEST-CC-HIST', N'TEST-CC-HIST-NONE');
GO

CREATE TABLE #H (
    HistoryKey INT, ClosureMethod NVARCHAR(20), PartsPerTray INT, TraysPerContainer INT,
    TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4),
    DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50), IsSerialized BIT,
    SupersededAt DATETIME2(3), SupersededBy NVARCHAR(50), Label NVARCHAR(200));
GO

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @U TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-HIST',
    @Description = N'ListHistory host item', @UomId = 1, @AppUserId = 1;
INSERT INTO @R EXEC Parts.Item_Create @ItemTypeId = 4, @PartNumber = N'TEST-CC-HIST-NONE',
    @Description = N'ListHistory host item, never edited', @UomId = 1, @AppUserId = 1;

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-HIST');
DECLARE @None BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TEST-CC-HIST-NONE');

-- A: ByWeight 6 x 12, 18.25 +/- 0.25
INSERT INTO @R EXEC Parts.ContainerConfig_Create @ItemId = @Item, @TraysPerContainer = 12,
    @PartsPerTray = 6, @IsSerialized = 0, @ClosureMethod = N'ByWeight',
    @TargetWeight = 18.2500, @ToleranceWeight = 0.2500, @AppUserId = 1;
INSERT INTO @R EXEC Parts.ContainerConfig_Create @ItemId = @None, @TraysPerContainer = 1,
    @PartsPerTray = 60, @IsSerialized = 0, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @Cfg BIGINT = (SELECT Id FROM Parts.ContainerConfig
                       WHERE ItemId = @Item AND ClosureMethod = N'ByWeight' AND DeprecatedAt IS NULL);

-- Never updated: nothing to offer.
INSERT INTO #H EXEC Parts.ContainerConfig_ListHistory @ItemId = @Item;
DECLARE @N0 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] no history before any update', @Expected = N'0', @Actual = @N0;
DELETE FROM #H;

-- A -> B (8 x 10, 20 +/- 0.5) -> C (8 x 12)
INSERT INTO @U EXEC Parts.ContainerConfig_Update @Id = @Cfg, @TraysPerContainer = 10, @PartsPerTray = 8,
    @IsSerialized = 0, @ClosureMethod = N'ByWeight', @TargetWeight = 20.0000, @ToleranceWeight = 0.5000, @AppUserId = 1;
WAITFOR DELAY '00:00:00.020';
INSERT INTO @U EXEC Parts.ContainerConfig_Update @Id = @Cfg, @TraysPerContainer = 12, @PartsPerTray = 8,
    @IsSerialized = 0, @ClosureMethod = N'ByWeight', @TargetWeight = 20.0000, @ToleranceWeight = 0.5000, @AppUserId = 1;

INSERT INTO #H EXEC Parts.ContainerConfig_ListHistory @ItemId = @Item;
DECLARE @N1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] two replaced sets after two updates', @Expected = N'2', @Actual = @N1;

DECLARE @First NVARCHAR(40) = (SELECT CAST(PartsPerTray AS NVARCHAR(10)) + N'x' + CAST(TraysPerContainer AS NVARCHAR(10))
                               FROM #H WHERE HistoryKey = 1);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] newest replaced set is first', @Expected = N'8x10', @Actual = @First;

DECLARE @W NVARCHAR(60) = (SELECT CAST(TargetWeight AS NVARCHAR(20)) + N'/' + CAST(ToleranceWeight AS NVARCHAR(20))
                           FROM #H WHERE PartsPerTray = 6);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] weights carried from the audit snapshot',
    @Expected = N'18.2500/0.2500', @Actual = @W;

DECLARE @Lbl NVARCHAR(200) = (SELECT Label FROM #H WHERE PartsPerTray = 6);
DECLARE @LblOk NVARCHAR(10) = CASE WHEN @Lbl LIKE N'6 per tray x 12 trays, 18.25 +/- 0.25  (until %, SYS)' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[CCHist] label reads as a pack-out', @Expected = N'1', @Actual = @LblOk;

DECLARE @Ascii NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H
                               WHERE Label LIKE N'%[^ -~]%' COLLATE Latin1_General_BIN2);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] labels are ASCII', @Expected = N'0', @Actual = @Ascii;
DELETE FROM #H;

-- C -> back to A. A is now current, so it drops out; B and C remain.
WAITFOR DELAY '00:00:00.020';
INSERT INTO @U EXEC Parts.ContainerConfig_Update @Id = @Cfg, @TraysPerContainer = 12, @PartsPerTray = 6,
    @IsSerialized = 0, @ClosureMethod = N'ByWeight', @TargetWeight = 18.2500, @ToleranceWeight = 0.2500, @AppUserId = 1;
INSERT INTO #H EXEC Parts.ContainerConfig_ListHistory @ItemId = @Item;
DECLARE @Cur NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H WHERE PartsPerTray = 6);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] the current active set is not offered', @Expected = N'0', @Actual = @Cur;
DECLARE @N2 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] the other two sets remain', @Expected = N'2', @Actual = @N2;
DELETE FROM #H;

-- A -> B again, then -> C: B and A each occurred before; identical sets collapse.
WAITFOR DELAY '00:00:00.020';
INSERT INTO @U EXEC Parts.ContainerConfig_Update @Id = @Cfg, @TraysPerContainer = 10, @PartsPerTray = 8,
    @IsSerialized = 0, @ClosureMethod = N'ByWeight', @TargetWeight = 20.0000, @ToleranceWeight = 0.5000, @AppUserId = 1;
WAITFOR DELAY '00:00:00.020';
INSERT INTO @U EXEC Parts.ContainerConfig_Update @Id = @Cfg, @TraysPerContainer = 12, @PartsPerTray = 8,
    @IsSerialized = 0, @ClosureMethod = N'ByWeight', @TargetWeight = 20.0000, @ToleranceWeight = 0.5000, @AppUserId = 1;
INSERT INTO #H EXEC Parts.ContainerConfig_ListHistory @ItemId = @Item;
DECLARE @N3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] repeated sets collapse to one row each', @Expected = N'2', @Actual = @N3;
DELETE FROM #H;

-- A cleared ByCount pack-out is offered under its own method.
INSERT INTO @R EXEC Parts.ContainerConfig_Create @ItemId = @Item, @TraysPerContainer = 1,
    @PartsPerTray = 48, @IsSerialized = 0, @ClosureMethod = N'ByCount', @AppUserId = 1;
DECLARE @Cnt BIGINT = (SELECT Id FROM Parts.ContainerConfig
                       WHERE ItemId = @Item AND ClosureMethod = N'ByCount' AND DeprecatedAt IS NULL);
INSERT INTO @U EXEC Parts.ContainerConfig_Deprecate @Id = @Cnt, @AppUserId = 1;
INSERT INTO #H EXEC Parts.ContainerConfig_ListHistory @ItemId = @Item;
DECLARE @Dep NVARCHAR(40) = (SELECT TOP (1) CAST(PartsPerTray AS NVARCHAR(10)) + N'x' + CAST(TraysPerContainer AS NVARCHAR(10))
                                    + N' key ' + CAST(HistoryKey AS NVARCHAR(10))
                             FROM #H WHERE ClosureMethod = N'ByCount');
EXEC test.Assert_IsEqual @TestName = N'[CCHist] a cleared pack-out is offered, ByCount sorted first',
    @Expected = N'48x1 key 1', @Actual = @Dep;
DELETE FROM #H;

-- An item whose config was never edited, and an id that does not exist.
INSERT INTO #H EXEC Parts.ContainerConfig_ListHistory @ItemId = @None;
INSERT INTO #H EXEC Parts.ContainerConfig_ListHistory @ItemId = -1;
DECLARE @N4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM #H);
EXEC test.Assert_IsEqual @TestName = N'[CCHist] no rows for an unedited or unknown item', @Expected = N'0', @Actual = @N4;
GO

DROP TABLE #H;
DELETE cc FROM Parts.ContainerConfig cc
INNER JOIN Parts.Item i ON i.Id = cc.ItemId
WHERE i.PartNumber IN (N'TEST-CC-HIST', N'TEST-CC-HIST-NONE');
DELETE FROM Parts.Item WHERE PartNumber IN (N'TEST-CC-HIST', N'TEST-CC-HIST-NONE');
GO
EXEC test.EndTestFile;
GO
