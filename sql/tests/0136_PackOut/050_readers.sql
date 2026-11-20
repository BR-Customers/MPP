-- =============================================
-- File: 0136_PackOut/050_readers.sql
-- Desc: Every reader follows the pack-out IN FORCE (spec 7.1a): the open
--       box's own version, else the terminal's pick, else the default.
--       Assembly_CompleteTray, ContainerConfig_GetByItemAndMethod,
--       ContainerConfig_JudgeWeight, Assembly_GetTraysRemaining,
--       ScaleStation_GetRunningPart. Review Focus 4: an edit mid-box changes
--       nothing for that box. Fixture: a pass-through (no-BOM) finished good
--       at TST-PO-LINE, filled at TST-PO-T1, from Received stock.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0136_PackOut/050_readers.sql';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @FgType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'TST-PO-RPK')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (@FgType, N'TST-PO-RPK', N'Pack-out repack FG', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-RPK');
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Fg AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@Fg, @Line, 0, @Now);

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.PackOut_Save @ItemId = @Fg, @ClosureMethod = N'ByWeight', @Name = N'Card',
    @TraysPerContainer = 2, @PartsPerTray = 6, @TargetWeight = 15.0, @ToleranceWeight = 1.0, @AppUserId = 1;
INSERT INTO @R EXEC Parts.PackOut_Save @ItemId = @Fg, @ClosureMethod = N'ByWeight', @Name = N'Tote',
    @TraysPerContainer = 3, @PartsPerTray = 8, @TargetWeight = 62.0, @ToleranceWeight = 1.5, @AppUserId = 1;

DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Rcv BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
VALUES (N'TPO-RPK-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), @Fg, @Rcv, @Good, 200, 200, @Line, 1);

CREATE TABLE #CT (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
CREATE TABLE #G (Id BIGINT, ItemId BIGINT, TraysPerContainer INT, PartsPerTray INT, IsSerialized BIT, DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50),
                 ClosureMethod NVARCHAR(20), TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4), CreatedAt DATETIME2(3), UpdatedAt DATETIME2(3),
                 DeprecatedAt DATETIME2(3), PackOutId BIGINT, PackOutName NVARCHAR(50), PackOutSource NVARCHAR(10), VersionNumber INT);
CREATE TABLE #J (Verdict NVARCHAR(20), Message NVARCHAR(500), Weight DECIMAL(10,4), TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4),
                 LowLimit DECIMAL(10,4), HighLimit DECIMAL(10,4), ScaleVerdict NVARCHAR(20), FlagsAgree BIT, FlagsMessage NVARCHAR(500), PackOutName NVARCHAR(50));
CREATE TABLE #T (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), BoxQuantity INT, PiecesPerTray INT, Available INT, TraysLeft INT, IsShort BIT, ThresholdTrays INT);
GO

-- ---- no pick, no box: default (Card v1) everywhere; the first tray opens a Card v1 box ----
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-RPK');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @S NVARCHAR(500);

DELETE FROM #G; INSERT INTO #G EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = @Fg, @ClosureMethod = N'ByWeight', @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(PackOutName, N'|', PackOutSource, N'|', PartsPerTray) FROM #G);
EXEC test.Assert_IsEqual @TestName = N'[Readers] GetByItemAndMethod no pick -> default', @Expected = N'Card|Default|6', @Actual = @S;

DELETE FROM #CT; INSERT INTO #CT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 6,
    @CellLocationId = @Line, @ClosureMethod = N'ByWeight', @AppUserId = 1, @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(ct.Status, N'|', p.Name, N'|', cc.VersionNumber, N'|', ct.ContainerFull, N'|', ct.TraysPerContainer)
          FROM #CT ct JOIN Lots.Container c ON c.Id = ct.ContainerId JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
          JOIN Parts.PackOut p ON p.Id = cc.PackOutId);
EXEC test.Assert_IsEqual @TestName = N'[Readers] CompleteTray opens a box stamped Card v1', @Expected = N'1|Card|1|0|2', @Actual = @S;
GO

-- ---- Review Focus 4: Card edited to v2 mid-box; every reader stays on the box's v1 ----
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-RPK');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @Card BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Fg AND Name = N'Card' AND DeprecatedAt IS NULL);
DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @R EXEC Parts.PackOut_Save @PackOutId = @Card, @ItemId = @Fg, @ClosureMethod = N'ByWeight', @Name = N'Card',
    @TraysPerContainer = 2, @PartsPerTray = 7, @TargetWeight = 17.5, @ToleranceWeight = 1.0, @AppUserId = 1;
DECLARE @S NVARCHAR(500);

DELETE FROM #G; INSERT INTO #G EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = @Fg, @ClosureMethod = N'ByWeight', @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(PackOutSource, N'|', VersionNumber, N'|', PartsPerTray, N'|', TargetWeight) FROM #G);
EXEC test.Assert_IsEqual @TestName = N'[Readers] GetByItemAndMethod mid-box -> the box''s v1', @Expected = N'OpenBox|1|6|15.0000', @Actual = @S;

DELETE FROM #J; INSERT INTO #J EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Fg, @ClosureMethod = N'ByWeight', @Weight = 15.5, @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(Verdict, N'|', LowLimit, N'-', HighLimit, N'|', PackOutName) FROM #J);
EXEC test.Assert_IsEqual @TestName = N'[Readers] JudgeWeight mid-box judges against the box''s v1', @Expected = N'Ok|14.0000-16.0000|Card', @Actual = @S;

DELETE FROM #J; INSERT INTO #J EXEC Parts.ContainerConfig_JudgeWeight @ItemId = @Fg, @ClosureMethod = N'ByWeight', @Weight = 15.5;
SET @S = (SELECT CONCAT(Verdict, N'|', LowLimit, N'-', HighLimit) FROM #J);
EXEC test.Assert_IsEqual @TestName = N'[Readers] JudgeWeight with no terminal -> the default''s active version', @Expected = N'Under|16.5000-18.5000', @Actual = @S;

DELETE FROM #T; INSERT INTO #T EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Line, @FinishedGoodItemId = @Fg, @ClosureMethod = N'ByWeight', @TerminalLocationId = @T1;
SET @S = (SELECT CAST(PiecesPerTray AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Readers] GetTraysRemaining mid-box -> the box''s 6/tray', @Expected = N'6', @Actual = @S;

DELETE FROM #CT; INSERT INTO #CT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 7,
    @CellLocationId = @Line, @ClosureMethod = N'ByWeight', @AppUserId = 1, @TerminalLocationId = @T1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #CT);
EXEC test.Assert_IsEqual @TestName = N'[Readers] CompleteTray mid-box refuses the new version''s count', @Expected = N'0', @Actual = @S;

DELETE FROM #CT; INSERT INTO #CT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 6,
    @CellLocationId = @Line, @ClosureMethod = N'ByWeight', @AppUserId = 1, @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(Status, N'|', ContainerFull, N'|', TraysPerContainer) FROM #CT);
EXEC test.Assert_IsEqual @TestName = N'[Readers] CompleteTray mid-box fills the v1 box to full', @Expected = N'1|1|2', @Actual = @S;

-- The box ships; the next box opens on v2.
UPDATE Lots.Container SET ContainerStatusCodeId = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Complete')
WHERE ItemId = @Fg AND ContainerStatusCodeId = 1;
DELETE FROM #CT; INSERT INTO #CT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 7,
    @CellLocationId = @Line, @ClosureMethod = N'ByWeight', @AppUserId = 1, @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(ct.Status, N'|', cc.VersionNumber, N'|', cc.PartsPerTray)
          FROM #CT ct JOIN Lots.Container c ON c.Id = ct.ContainerId JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId);
EXEC test.Assert_IsEqual @TestName = N'[Readers] after the box ships the next box opens on v2', @Expected = N'1|2|7', @Actual = @S;
UPDATE Lots.Container SET ContainerStatusCodeId = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Complete')
WHERE ItemId = @Fg AND ContainerStatusCodeId = 1;
GO

-- ---- a terminal pick (Tote) with no box: every reader runs Tote; the next box is Tote ----
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-RPK');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T2');
DECLARE @Tote BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Fg AND Name = N'Tote' AND DeprecatedAt IS NULL);
DECLARE @Sel TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Sel EXEC Location.Terminal_SetPackOut @TerminalLocationId = @T1, @PackOutId = @Tote, @AppUserId = 1;
DECLARE @S NVARCHAR(500) = (SELECT CAST(Status AS NVARCHAR(1)) FROM @Sel);
EXEC test.Assert_IsEqual @TestName = N'[Readers] Tote selected with no box open', @Expected = N'1', @Actual = @S;

DELETE FROM #G; INSERT INTO #G EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = @Fg, @ClosureMethod = N'ByWeight', @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(PackOutName, N'|', PackOutSource, N'|', PartsPerTray, N'|', TargetWeight) FROM #G);
EXEC test.Assert_IsEqual @TestName = N'[Readers] GetByItemAndMethod -> the pick', @Expected = N'Tote|Selected|8|62.0000', @Actual = @S;

DELETE FROM #G; INSERT INTO #G EXEC Parts.ContainerConfig_GetByItemAndMethod @ItemId = @Fg, @ClosureMethod = N'ByWeight', @TerminalLocationId = @T2;
SET @S = (SELECT CONCAT(PackOutName, N'|', PackOutSource) FROM #G);
EXEC test.Assert_IsEqual @TestName = N'[Readers] another terminal keeps the default', @Expected = N'Card|Default', @Actual = @S;

DELETE FROM #T; INSERT INTO #T EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId = @Line, @FinishedGoodItemId = @Fg, @ClosureMethod = N'ByWeight', @TerminalLocationId = @T1;
SET @S = (SELECT CAST(PiecesPerTray AS NVARCHAR(10)) FROM #T);
EXEC test.Assert_IsEqual @TestName = N'[Readers] GetTraysRemaining -> the pick''s 8/tray', @Expected = N'8', @Actual = @S;

DELETE FROM #CT; INSERT INTO #CT EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 8,
    @CellLocationId = @Line, @ClosureMethod = N'ByWeight', @AppUserId = 1, @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(ct.Status, N'|', p.Name, N'|', ct.TraysPerContainer)
          FROM #CT ct JOIN Lots.Container c ON c.Id = ct.ContainerId JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
          JOIN Parts.PackOut p ON p.Id = cc.PackOutId);
EXEC test.Assert_IsEqual @TestName = N'[Readers] CompleteTray opens a Tote box', @Expected = N'1|Tote|3', @Actual = @S;

CREATE TABLE #RP (ItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), Source NVARCHAR(20),
                  PartsPerTray INT, TraysPerContainer INT, TargetWeight DECIMAL(10,4), ToleranceWeight DECIMAL(10,4),
                  LowLimit DECIMAL(10,4), HighLimit DECIMAL(10,4), EligibleCount INT, Message NVARCHAR(500),
                  OverrideItemId BIGINT, OverrideSetBy NVARCHAR(50), OverrideSetAtEt DATETIME2(3),
                  OpenContainerId BIGINT, OpenTraysClosed INT, OpenPartsClosed INT,
                  PackOutId BIGINT, PackOutName NVARCHAR(50), PackOutSource NVARCHAR(10));
INSERT INTO #RP EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @T1;
SET @S = (SELECT CONCAT(PartNumber, N'|', PackOutName, N'|', PackOutSource, N'|', PartsPerTray, N'|', LowLimit) FROM #RP);
EXEC test.Assert_IsEqual @TestName = N'[Readers] GetRunningPart -> the open Tote box', @Expected = N'TST-PO-RPK|Tote|OpenBox|8|60.5000', @Actual = @S;
DELETE FROM #RP; INSERT INTO #RP EXEC Workorder.ScaleStation_GetRunningPart @TerminalLocationId = @T2;
SET @S = (SELECT CONCAT(PartNumber, N'|', PackOutName, N'|', PackOutSource, N'|', PartsPerTray) FROM #RP);
EXEC test.Assert_IsEqual @TestName = N'[Readers] GetRunningPart at another terminal -> default v2', @Expected = N'TST-PO-RPK|Card|Default|7', @Actual = @S;
DROP TABLE #RP;
GO

-- ---- cleanup ----
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-RPK');
DELETE ce FROM Workorder.ConsumptionEvent ce WHERE ce.ProducedItemId = @Fg OR ce.ConsumedItemId = @Fg;
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId WHERE l.ItemId = @Fg;
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.ItemId = @Fg;
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId = @Fg;
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId = @Fg;
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @Fg;
DELETE FROM Lots.Container WHERE ItemId = @Fg;
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId = @Fg;
DELETE FROM Lots.Lot WHERE ItemId = @Fg;
DELETE FROM Location.TerminalPackOutSelection WHERE ItemId = @Fg;
DROP TABLE #CT; DROP TABLE #G; DROP TABLE #J; DROP TABLE #T;
GO
EXEC test.EndTestFile;
GO
