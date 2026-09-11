-- =============================================
-- File:         0028_PlantFloor_Assembly/098_Assembly_CompleteTray_station_scoped.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-11
-- Description:  Migration 0078 / Assembly_CompleteTray v1.4 / Container_GetOpenByCell
--               v1.1. An open box belongs to the STATION (terminal) filling it.
--
--               The real case: line MA2-6MACH carries METTs Assembly Out A and B
--               (MA2-6MACH-AOUT1 / -AOUT2), both ByCount, each with its own printer,
--               running the SAME part numbers at the same time into separate boxes,
--               and each switching between several part boxes. Keyed by line (pre-
--               0078) both terminals' trays of one part landed in one container.
--
--               Covers: two stations / same part -> two boxes; switching parts keeps
--               the first box open; a station's next tray goes back to ITS box; the
--               full-box guard is per station; an unowned (pre-0078) open box is
--               CLAIMED, not stranded; a non-terminal @TerminalLocationId keeps the
--               pre-0078 line-wide behaviour; the station / closure filters on
--               Container_GetOpenByCell, and its unfiltered call is unchanged.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/098_Assembly_CompleteTray_station_scoped.sql';
GO

-- ---- cleanup (FK-safe) ----
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG1');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG2');
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (@F1, @F2);
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId IN (@F1, @F2);
DELETE FROM Lots.Container WHERE ItemId IN (@F1, @F2);
DELETE FROM Lots.Lot WHERE ItemId IN (@F1, @F2) OR LotName LIKE N'STG-098%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ST-FG1') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ST-FG1', N'0078 station test FG 1', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ST-FG2') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ST-FG2', N'0078 station test FG 2', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P6-ST-C')   INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-ST-C',   N'0078 station test component', 1, @Now, 1);
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG1');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG2');
DECLARE @C  BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-C');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH');

-- 2 trays x 5 parts, ByCount
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @F1 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@F1, 2, 5, 0, N'ByCount', @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @F2 AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@F2, 2, 5, 0, N'ByCount', @Now);

-- 1-line BOMs: each FG <- component x1 (the METTs shape: one machined part per FG)
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @F1 AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@F1, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @C, 1, 1, 1);
END
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @F2 AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@F2, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @C, 1, 1, 1);
END

-- eligible at the LINE (terminals zone up to it)
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @F1 AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@F1, @Line, 0, @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @F2 AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt) VALUES (@F2, @Line, 0, @Now);

-- shared component stock at the line (both METTs terminals draw from it)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
    VALUES (N'STG-098C', @C, 1, 1, 1000, 1000, @Line, 1, @Now);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT Id, Id, 0 FROM Lots.Lot WHERE LotName = N'STG-098C';
GO

-- =============================================
-- The scenario, in one batch so container ids carry through
-- =============================================
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG1');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG2');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT1');
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA2-6MACH-AOUT2');
DECLARE @Cfg2 BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @F2 AND DeprecatedAt IS NULL);
DECLARE @Cfg1 BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @F1 AND DeprecatedAt IS NULL);

DECLARE @R TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT,
                  ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
DECLARE @C1 BIGINT, @C2 BIGINT, @C3 BIGINT, @C4 BIGINT, @C5 BIGINT, @Got BIGINT;
DECLARE @S NVARCHAR(10), @X NVARCHAR(50), @Msg NVARCHAR(500);

-- 1. METTs A, part 1 -> a box owned by A
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F1, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @T1;
SELECT @S = CAST(Status AS NVARCHAR(10)), @C1 = ContainerId FROM @R; DELETE FROM @R;
EXEC test.Assert_IsEqual @TestName = N'[Station] A part-1 tray succeeds', @Expected = N'1', @Actual = @S;
SET @X = (SELECT CAST(StationLocationId AS NVARCHAR(50)) FROM Lots.Container WHERE Id = @C1);
SET @Msg = CAST(@T1 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Station] A''s new box is owned by A', @Expected = @Msg, @Actual = @X;

-- 2. METTs B, SAME part, same line, same time -> its OWN box
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F1, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @T2;
SELECT @S = CAST(Status AS NVARCHAR(10)), @C2 = ContainerId FROM @R; DELETE FROM @R;
EXEC test.Assert_IsEqual @TestName = N'[Station] B part-1 tray succeeds', @Expected = N'1', @Actual = @S;
SET @X = CASE WHEN @C2 IS NOT NULL AND @C2 <> @C1 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Station] same part on two stations -> two separate boxes', @Expected = N'1', @Actual = @X;
SET @X = (SELECT CAST(StationLocationId AS NVARCHAR(50)) FROM Lots.Container WHERE Id = @C2);
SET @Msg = CAST(@T2 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Station] B''s box is owned by B', @Expected = @Msg, @Actual = @X;

-- 3. A switches to part 2 -> new box; A's part-1 box stays open with its tray
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F2, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @T1;
SELECT @S = CAST(Status AS NVARCHAR(10)), @C3 = ContainerId FROM @R; DELETE FROM @R;
EXEC test.Assert_IsEqual @TestName = N'[Station] A part-2 tray succeeds', @Expected = N'1', @Actual = @S;
SET @X = CASE WHEN @C3 NOT IN (@C1, @C2) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Station] switching parts opens that part''s own box', @Expected = N'1', @Actual = @X;
SET @X = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Lots.Container c JOIN Lots.ContainerTray t ON t.ContainerId = c.Id
          WHERE c.Id = @C1 AND c.ContainerStatusCodeId = 1);
EXEC test.Assert_IsEqual @TestName = N'[Station] the part-1 box stays open with its 1 tray', @Expected = N'1', @Actual = @X;

-- 4. A back on part 1 -> into A's box (NOT B's), which is now full
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F1, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @T1;
SELECT @S = CAST(ContainerFull AS NVARCHAR(10)), @Got = ContainerId FROM @R; DELETE FROM @R;
SET @X = CAST(@Got AS NVARCHAR(50)); SET @Msg = CAST(@C1 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Station] A''s next part-1 tray returns to A''s box', @Expected = @Msg, @Actual = @X;
EXEC test.Assert_IsEqual @TestName = N'[Station] A''s part-1 box reports full', @Expected = N'1', @Actual = @S;

-- 5. full-box guard is PER STATION: A is refused, B carries on
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F1, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @T1;
SELECT @S = CAST(Status AS NVARCHAR(10)), @Msg = Message FROM @R; DELETE FROM @R;
EXEC test.Assert_IsEqual @TestName = N'[Station] A refused onto its full box', @Expected = N'0', @Actual = @S;
SET @X = CASE WHEN @Msg LIKE N'Container is full%' THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Station] ...with the container-full message', @Expected = N'1', @Actual = @X;
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F1, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @T2;
SELECT @S = CAST(Status AS NVARCHAR(10)), @Got = ContainerId FROM @R; DELETE FROM @R;
EXEC test.Assert_IsEqual @TestName = N'[Station] B is NOT blocked by A''s full box', @Expected = N'1', @Actual = @S;
SET @X = CAST(@Got AS NVARCHAR(50)); SET @Msg = CAST(@C2 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Station] B''s tray lands in B''s own box', @Expected = @Msg, @Actual = @X;

-- 6. an UNOWNED open box (every pre-0078 container) is claimed, not stranded
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @F2, @ContainerConfigId = @Cfg2, @CellLocationId = @Line, @AppUserId = 1;
SET @C4 = (SELECT NewId FROM @O); DELETE FROM @O;
SET @X = (SELECT CASE WHEN StationLocationId IS NULL THEN N'1' ELSE N'0' END FROM Lots.Container WHERE Id = @C4);
EXEC test.Assert_IsEqual @TestName = N'[Station] fixture: Container_Open leaves the box unowned', @Expected = N'1', @Actual = @X;
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F2, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @T2;
SELECT @S = CAST(Status AS NVARCHAR(10)), @Got = ContainerId FROM @R; DELETE FROM @R;
SET @X = CAST(@Got AS NVARCHAR(50)); SET @Msg = CAST(@C4 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Station] B''s part-2 tray fills the unowned box', @Expected = @Msg, @Actual = @X;
SET @X = (SELECT CAST(StationLocationId AS NVARCHAR(50)) FROM Lots.Container WHERE Id = @C4);
SET @Msg = CAST(@T2 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Station] ...and claims it for B', @Expected = @Msg, @Actual = @X;

-- 7. a non-terminal @TerminalLocationId (the line itself) keeps pre-0078 line-wide behaviour:
--    oldest open box for (line, part), whoever owns it -> A's part-2 box C3 (older than C4)
INSERT INTO @R EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @F2, @PieceCount = 5, @CellLocationId = @Line,
    @ClosureMethod = N'ByCount', @AppUserId = 1, @TerminalLocationId = @Line;
SELECT @S = CAST(Status AS NVARCHAR(10)), @Got = ContainerId FROM @R; DELETE FROM @R;
SET @X = CAST(@Got AS NVARCHAR(50)); SET @Msg = CAST(@C3 AS NVARCHAR(50));
EXEC test.Assert_IsEqual @TestName = N'[Station] non-terminal caller is line-wide (oldest open box)', @Expected = @Msg, @Actual = @X;

-- 8. Container_GetOpenByCell filters. Add an unowned part-1 box: visible to BOTH stations.
INSERT INTO @O EXEC Lots.Container_Open @ItemId = @F1, @ContainerConfigId = @Cfg1, @CellLocationId = @Line, @AppUserId = 1;
SET @C5 = (SELECT NewId FROM @O); DELETE FROM @O;

DECLARE @L TABLE (Id BIGINT, ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
                  ContainerConfigId BIGINT, TraysPerContainer INT, PartsPerTray INT, IsSerialized BIT,
                  ClosureMethod NVARCHAR(20), TargetParts INT, AccumulatedParts INT, ClosedTrays INT,
                  OpenedAt DATETIME2(3), StationLocationId BIGINT, StationCode NVARCHAR(50));

INSERT INTO @L EXEC Lots.Container_GetOpenByCell @CellLocationId = @Line, @StationLocationId = @T1, @ClosureMethod = N'ByCount';
SET @X = CASE WHEN EXISTS (SELECT 1 FROM @L WHERE Id = @C1) AND EXISTS (SELECT 1 FROM @L WHERE Id = @C3)
               AND EXISTS (SELECT 1 FROM @L WHERE Id = @C5)
               AND NOT EXISTS (SELECT 1 FROM @L WHERE Id IN (@C2, @C4)) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Read] A sees its own boxes + unowned, never B''s', @Expected = N'1', @Actual = @X;
SET @X = (SELECT StationCode FROM @L WHERE Id = @C1);
EXEC test.Assert_IsEqual @TestName = N'[Read] StationCode is the owning terminal', @Expected = N'MA2-6MACH-AOUT1', @Actual = @X;
DELETE FROM @L;

INSERT INTO @L EXEC Lots.Container_GetOpenByCell @CellLocationId = @Line, @StationLocationId = @T2, @ClosureMethod = N'ByCount';
SET @X = CASE WHEN EXISTS (SELECT 1 FROM @L WHERE Id = @C2) AND EXISTS (SELECT 1 FROM @L WHERE Id = @C4)
               AND EXISTS (SELECT 1 FROM @L WHERE Id = @C5)
               AND NOT EXISTS (SELECT 1 FROM @L WHERE Id IN (@C1, @C3)) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Read] B sees its own boxes + unowned, never A''s', @Expected = N'1', @Actual = @X;
DELETE FROM @L;

INSERT INTO @L EXEC Lots.Container_GetOpenByCell @CellLocationId = @Line, @StationLocationId = @T1, @ClosureMethod = N'ByVision';
SET @X = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE ItemId IN (@F1, @F2));
EXEC test.Assert_IsEqual @TestName = N'[Read] closure filter: ByVision sees none of these ByCount boxes', @Expected = N'0', @Actual = @X;
DELETE FROM @L;

INSERT INTO @L EXEC Lots.Container_GetOpenByCell @CellLocationId = @Line;
SET @X = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE ItemId IN (@F1, @F2));
EXEC test.Assert_IsEqual @TestName = N'[Read] unfiltered call still returns every open box on the line', @Expected = N'5', @Actual = @X;
GO

-- ---- teardown (FK-safe) ----
DECLARE @F1 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG1');
DECLARE @F2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-ST-FG2');
DELETE FROM Workorder.ConsumptionEvent WHERE ProducedItemId IN (@F1, @F2);
DELETE g FROM Lots.LotGenealogy g INNER JOIN Lots.Lot l ON l.Id = g.ChildLotId OR l.Id = g.ParentLotId
    WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE c FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId
    WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE m FROM Lots.LotMovement m INNER JOIN Lots.Lot l ON l.Id = m.LotId WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE h FROM Lots.LotStatusHistory h INNER JOIN Lots.Lot l ON l.Id = h.LotId WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE le FROM Lots.LotEventLog le INNER JOIN Lots.Lot l ON l.Id = le.LotId WHERE l.ItemId IN (@F1, @F2) OR l.LotName LIKE N'STG-098%';
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId IN (@F1, @F2);
DELETE FROM Lots.Container WHERE ItemId IN (@F1, @F2);
DELETE FROM Lots.Lot WHERE ItemId IN (@F1, @F2) OR LotName LIKE N'STG-098%';
GO

EXEC test.EndTestFile;
