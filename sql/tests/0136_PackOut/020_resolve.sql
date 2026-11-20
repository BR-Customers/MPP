-- =============================================
-- File: 0136_PackOut/020_resolve.sql
-- Desc: The one rule. Parts.ufn_ResolvePackOut = terminal pick, else default.
--       Parts.ufn_PackOutInForce = the open box the next tray would go into
--       (Lots.ufn_ContainerForNextTray) -> that box's own version; else the
--       resolver. Builds the TST-PO-* fixture reused by later 0136 files.
-- =============================================
SET NOCOUNT ON;
EXEC test.BeginTestFile @FileName = N'0136_PackOut/020_resolve.sql';
GO

-- ---- Fixture: line + two terminals + two finished goods ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Area BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 3 AND DeprecatedAt IS NULL ORDER BY Id);
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TST-PO-LINE')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
    VALUES (5, @Area, N'Pack-out test line', N'TST-PO-LINE', 999, @Now);
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TST-PO-T1')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
    VALUES (7, @Line, N'Pack-out test terminal 1', N'TST-PO-T1', 1, @Now);
IF NOT EXISTS (SELECT 1 FROM Location.Location WHERE Code = N'TST-PO-T2')
    INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, SortOrder, CreatedAt)
    VALUES (7, @Line, N'Pack-out test terminal 2', N'TST-PO-T2', 2, @Now);

DECLARE @Fg BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @Ea BIGINT = (SELECT TOP 1 Id FROM Parts.Uom ORDER BY Id);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'TST-PO-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@Fg, N'TST-PO-FG', N'Pack-out FG', @Ea, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'TST-PO-FG2')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@Fg, N'TST-PO-FG2', N'Pack-out FG2', @Ea, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG');
DECLARE @Item2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG2');

-- Re-runnable: clear any earlier run's pack-outs and boxes for the fixture parts.
DELETE t FROM Lots.ContainerTray t JOIN Lots.Container c ON c.Id = t.ContainerId WHERE c.ItemId IN (@Item, @Item2);
DELETE FROM Lots.Container WHERE ItemId IN (@Item, @Item2);
DELETE FROM Parts.ContainerConfig WHERE ItemId IN (@Item, @Item2);
DELETE FROM Parts.PackOut WHERE ItemId IN (@Item, @Item2);

-- Pack-outs (raw: the save proc is tested in 030). FG: Cardboard (default) 6x1 15 lb, Tote 8x4 62 lb. FG2: one default.
INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item, N'ByWeight', N'Cardboard', 1, 1);
DECLARE @Card BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item, N'ByWeight', N'Tote', 0, 1);
DECLARE @Tote BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.PackOut (ItemId, ClosureMethod, Name, IsDefault, CreatedByUserId) VALUES (@Item2, N'ByWeight', N'By Weight', 1, 1);
DECLARE @Fg2Po BIGINT = SCOPE_IDENTITY();
INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray, IsSerialized, TargetWeight, ToleranceWeight)
VALUES (@Item, N'ByWeight', @Card, 1, 1, 6, 0, 15.0, 1.35),
       (@Item, N'ByWeight', @Tote, 1, 4, 8, 0, 62.0, 1.5),
       (@Item2, N'ByWeight', @Fg2Po, 1, 2, 10, 0, 20.0, 1.0);
GO

-- ---- ufn_ResolvePackOut ----
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG');
DECLARE @Item2 BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG2');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @Tote BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND Name = N'Tote' AND DeprecatedAt IS NULL);
DECLARE @S NVARCHAR(200);

SET @S = (SELECT CONCAT(PackOutName, N'|', Source, N'|', PartsPerTray) FROM Parts.ufn_ResolvePackOut(@Item, N'ByWeight', @T1));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] no pick -> default', @Expected = N'Cardboard|Default|6', @Actual = @S;

SET @S = (SELECT CONCAT(PackOutName, N'|', Source) FROM Parts.ufn_ResolvePackOut(@Item, N'ByWeight', NULL));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] NULL terminal -> default', @Expected = N'Cardboard|Default', @Actual = @S;

INSERT INTO Location.TerminalPackOutSelection (TerminalLocationId, ItemId, ClosureMethod, PackOutId, SetByUserId)
VALUES (@T1, @Item, N'ByWeight', @Tote, 1);
SET @S = (SELECT CONCAT(PackOutName, N'|', Source, N'|', PartsPerTray, N'|', TraysPerContainer) FROM Parts.ufn_ResolvePackOut(@Item, N'ByWeight', @T1));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] pick wins', @Expected = N'Tote|Selected|8|4', @Actual = @S;

SET @S = (SELECT CONCAT(PackOutName, N'|', Source) FROM Parts.ufn_ResolvePackOut(@Item2, N'ByWeight', @T1));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] pick is per part', @Expected = N'By Weight|Default', @Actual = @S;

SET @S = (SELECT CONCAT(PackOutName, N'|', Source) FROM Parts.ufn_ResolvePackOut(@Item, N'ByCount', @T1));
EXEC test.Assert_IsNull @TestName = N'[Resolve] no pack-out for the method -> no row', @Value = @S;

-- A pick on a removed pack-out is ignored (Review Focus 1).
UPDATE Parts.PackOut SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @Tote;
SET @S = (SELECT CONCAT(PackOutName, N'|', Source) FROM Parts.ufn_ResolvePackOut(@Item, N'ByWeight', @T1));
EXEC test.Assert_IsEqual @TestName = N'[Resolve] pick on a removed pack-out -> default', @Expected = N'Cardboard|Default', @Actual = @S;
UPDATE Parts.PackOut SET DeprecatedAt = NULL WHERE Id = @Tote;
GO

-- ---- ufn_ContainerForNextTray + ufn_PackOutInForce ----
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @T2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T2');
DECLARE @Card BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND Name = N'Cardboard' AND DeprecatedAt IS NULL);
DECLARE @CardV1 BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE PackOutId = @Card AND DeprecatedAt IS NULL);
DECLARE @S NVARCHAR(200);

SET @S = (SELECT CONCAT(PackOutName, N'|', Source) FROM Parts.ufn_PackOutInForce(@Item, N'ByWeight', @T1, NULL));
EXEC test.Assert_IsEqual @TestName = N'[InForce] no open box -> resolver (pick)', @Expected = N'Tote|Selected', @Actual = @S;

-- T1 (picked Tote) has its own open box on Cardboard v1; then Cardboard is edited to v2.
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId, StationLocationId)
VALUES (@Item, @CardV1, @Line, 1, 1, @T1);
DECLARE @Box BIGINT = SCOPE_IDENTITY();
UPDATE Parts.ContainerConfig SET DeprecatedAt = SYSUTCDATETIME() WHERE Id = @CardV1;
INSERT INTO Parts.ContainerConfig (ItemId, ClosureMethod, PackOutId, VersionNumber, TraysPerContainer, PartsPerTray, IsSerialized, TargetWeight, ToleranceWeight)
VALUES (@Item, N'ByWeight', @Card, 2, 1, 7, 0, 17.5, 1.35);

SET @S = (SELECT CONCAT(ContainerId, N'|', ContainerConfigId) FROM Lots.ufn_ContainerForNextTray(@Line, @Item, @T1));
DECLARE @Exp NVARCHAR(200) = CONCAT(@Box, N'|', @CardV1);
EXEC test.Assert_IsEqual @TestName = N'[NextTray] own open box', @Expected = @Exp, @Actual = @S;

SET @S = (SELECT CONCAT(PackOutName, N'|', Source, N'|', VersionNumber, N'|', PartsPerTray, N'|', OpenContainerId) FROM Parts.ufn_PackOutInForce(@Item, N'ByWeight', @T1, NULL));
SET @Exp = CONCAT(N'Cardboard|OpenBox|1|6|', @Box);
EXEC test.Assert_IsEqual @TestName = N'[InForce] open box version wins over pick and over a newer version', @Expected = @Exp, @Actual = @S;

-- T2 has no own box; T1's box is owned, so T2 resolves normally (default = Cardboard v2).
SET @S = (SELECT CONCAT(PackOutName, N'|', Source, N'|', VersionNumber, N'|', PartsPerTray) FROM Parts.ufn_PackOutInForce(@Item, N'ByWeight', @T2, NULL));
EXEC test.Assert_IsEqual @TestName = N'[InForce] another terminal ignores an owned box', @Expected = N'Cardboard|Default|2|7', @Actual = @S;

-- An UNOWNED open box at the line is the one T2's next tray would claim.
UPDATE Lots.Container SET StationLocationId = NULL WHERE Id = @Box;
SET @S = (SELECT CONCAT(Source, N'|', OpenContainerId) FROM Parts.ufn_PackOutInForce(@Item, N'ByWeight', @T2, NULL));
SET @Exp = CONCAT(N'OpenBox|', @Box);
EXEC test.Assert_IsEqual @TestName = N'[InForce] unowned open box at the line is used', @Expected = @Exp, @Actual = @S;

-- No terminal (facility fallback) with a cell: the oldest open box at the line.
SET @S = (SELECT CONCAT(Source, N'|', OpenContainerId) FROM Parts.ufn_PackOutInForce(@Item, N'ByWeight', NULL, @Line));
EXEC test.Assert_IsEqual @TestName = N'[InForce] no terminal -> oldest open box at the cell', @Expected = @Exp, @Actual = @S;

DELETE FROM Lots.Container WHERE Id = @Box;
DELETE FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1;
GO
EXEC test.EndTestFile;
GO
