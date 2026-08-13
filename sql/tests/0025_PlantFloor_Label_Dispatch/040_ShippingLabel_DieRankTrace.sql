-- =============================================
-- File:         0025_PlantFloor_Label_Dispatch/040_ShippingLabel_DieRankTrace.sql
-- Author:       Blue Ridge Automation
-- Description:  Brief D -- Tools.ufn_ContainerOriginDieRankCode resolves the "D/C PART
--               LEVEL" (die rank) for a container's shipping label by genealogy trace:
--               container's first closed tray -> FinishedGoodLotId -> closure ancestors
--               -> casting Lot.ToolId -> Tool.DieRankId -> DieRank.Code. Returns '' when
--               no die-rank ancestor exists (label still prints).
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0025_PlantFloor_Label_Dispatch/040_ShippingLabel_DieRankTrace.sql';
GO

-- ---- fixture cleanup (re-runnable; anchored on the DRT / DR3 namespaces) ----
DELETE FROM Lots.ContainerTray WHERE ClosureMethod IN (N'DRT-TEST', N'DR3-TEST');
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'DRT%' OR LotName LIKE N'DR3%');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'DRT%' OR LotName LIKE N'DR3%');
DELETE FROM Lots.Lot     WHERE LotName LIKE N'DRT%' OR LotName LIKE N'DR3%';
DELETE FROM Tools.Tool   WHERE Code IN (N'DRT-DIE', N'DR3-DIE', N'DR3-DIEDEEP', N'DR3-TOOLSHALLOW');
DELETE FROM Tools.DieRank WHERE Code IN (N'DRT-A', N'DR3-A', N'DR3-DEEP', N'DR3-SHALLOW');
GO

-- ---- fixture ----
DECLARE @Rank BIGINT;
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'DRT-A', N'DieRankTrace A');
SET @Rank = SCOPE_IDENTITY();

DECLARE @Die BIGINT;
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), N'DRT-DIE', N'DRT Die', @Rank,
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
SET @Die = SCOPE_IDENTITY();

DECLARE @Loc      BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Item     BIGINT = (SELECT TOP 1 Id FROM Parts.Item ORDER BY Id);
DECLARE @Cfg      BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id);
DECLARE @Good     BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @OrigMfg  BIGINT = (SELECT Id FROM Lots.LotOriginType  WHERE Code = N'Manufactured');

-- casting LOT carrying ToolId (the die)
DECLARE @CastLot BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedByUserId)
VALUES (N'DRTCAST1', @Item, @OrigMfg, @Good, 10, @Loc, @Die, 1);
SET @CastLot = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@CastLot, @CastLot, 0);

-- FG LOT + closure ancestor edge from the casting (Depth 1)
DECLARE @FgLot BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'DRTFG1', @Item, @OrigMfg, @Good, 10, @Loc, 1);
SET @FgLot = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@FgLot, @FgLot, 0), (@CastLot, @FgLot, 1);

-- container + closed tray linking the FG LOT
DECLARE @Cont BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId)
VALUES (@Item, @Cfg, @Loc, 1);
SET @Cont = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@Cont, 1, 10, SYSUTCDATETIME(), 1, N'DRT-TEST', @FgLot);

-- container with NO die-rank ancestor
DECLARE @Cont2 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId)
VALUES (@Item, @Cfg, @Loc, 1);
SET @Cont2 = SCOPE_IDENTITY();

-- ---- assert ----
DECLARE @Got NVARCHAR(20) = Tools.ufn_ContainerOriginDieRankCode(@Cont);
EXEC test.Assert_IsEqual @TestName = N'[DieRank] container resolves origin casting die rank', @Expected = N'DRT-A', @Actual = @Got;

DECLARE @Empty NVARCHAR(20) = Tools.ufn_ContainerOriginDieRankCode(@Cont2);
EXEC test.Assert_IsEqual @TestName = N'[DieRank] no die-rank ancestor -> blank', @Expected = N'', @Actual = @Empty;
GO

-- =============================================
-- Scenario 2: 3-LEVEL genealogy (casting -> subassembly -> FG, casting at Depth 2).
--   Proves the ancestor walk resolves the die rank beyond Depth 1.
-- =============================================
DECLARE @Rank3 BIGINT;
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'DR3-A', N'DieRank3 A');
SET @Rank3 = SCOPE_IDENTITY();
DECLARE @Die3 BIGINT;
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), N'DR3-DIE', N'DR3 Die', @Rank3,
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
SET @Die3 = SCOPE_IDENTITY();

DECLARE @Loc3     BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Item3    BIGINT = (SELECT TOP 1 Id FROM Parts.Item ORDER BY Id);
DECLARE @Cfg3     BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id);
DECLARE @Good3    BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @OrigMfg3 BIGINT = (SELECT Id FROM Lots.LotOriginType  WHERE Code = N'Manufactured');

DECLARE @C3 BIGINT, @S3 BIGINT, @F3 BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedByUserId)
VALUES (N'DR3CAST', @Item3, @OrigMfg3, @Good3, 10, @Loc3, @Die3, 1);
SET @C3 = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'DR3SUB', @Item3, @OrigMfg3, @Good3, 10, @Loc3, 1);
SET @S3 = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'DR3FG', @Item3, @OrigMfg3, @Good3, 10, @Loc3, 1);
SET @F3 = SCOPE_IDENTITY();
-- self rows + edges: C3->S3 (1), S3->F3 (1), C3->F3 (2)
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
VALUES (@C3,@C3,0),(@S3,@S3,0),(@F3,@F3,0),(@C3,@S3,1),(@S3,@F3,1),(@C3,@F3,2);

DECLARE @Cont3 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId)
VALUES (@Item3, @Cfg3, @Loc3, 1);
SET @Cont3 = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@Cont3, 1, 10, SYSUTCDATETIME(), 1, N'DR3-TEST', @F3);

DECLARE @Got3 NVARCHAR(20) = Tools.ufn_ContainerOriginDieRankCode(@Cont3);
EXEC test.Assert_IsEqual @TestName = N'[DieRank] 3-level chain resolves casting die rank at Depth 2', @Expected = N'DR3-A', @Actual = @Got3;
GO

-- =============================================
-- Scenario 3: DEEPEST-ANCESTOR discriminator. Two tool-bearing ancestors with DISTINCT
--   die ranks at different depths (deep casting at Depth 2, a shallower tool-bearing LOT
--   at Depth 1). The origin casting (deepest) must win -- proves ORDER BY Depth DESC
--   (ASC would return the shallow rank).
-- =============================================
DECLARE @RankDeep BIGINT, @RankShallow BIGINT;
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'DR3-DEEP', N'DieRank3 Deep');
SET @RankDeep = SCOPE_IDENTITY();
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'DR3-SHALLOW', N'DieRank3 Shallow');
SET @RankShallow = SCOPE_IDENTITY();
DECLARE @DieDeep BIGINT, @ToolShallow BIGINT;
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), N'DR3-DIEDEEP', N'DR3 Deep Die', @RankDeep,
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
SET @DieDeep = SCOPE_IDENTITY();
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
VALUES ((SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), N'DR3-TOOLSHALLOW', N'DR3 Shallow Tool', @RankShallow,
        (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1);
SET @ToolShallow = SCOPE_IDENTITY();

DECLARE @LocD  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @ItemD BIGINT = (SELECT TOP 1 Id FROM Parts.Item ORDER BY Id);
DECLARE @CfgD  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig ORDER BY Id);
DECLARE @GoodD BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @OrigD BIGINT = (SELECT Id FROM Lots.LotOriginType  WHERE Code = N'Manufactured');

DECLARE @CD BIGINT, @MD BIGINT, @FD BIGINT;
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedByUserId)
VALUES (N'DR3DEEPCAST', @ItemD, @OrigD, @GoodD, 10, @LocD, @DieDeep, 1);
SET @CD = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, ToolId, CreatedByUserId)
VALUES (N'DR3SHAL', @ItemD, @OrigD, @GoodD, 10, @LocD, @ToolShallow, 1);
SET @MD = SCOPE_IDENTITY();
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'DR3FG2', @ItemD, @OrigD, @GoodD, 10, @LocD, 1);
SET @FD = SCOPE_IDENTITY();
-- edges: CD->MD (1), MD->FD (1), CD->FD (2)
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
VALUES (@CD,@CD,0),(@MD,@MD,0),(@FD,@FD,0),(@CD,@MD,1),(@MD,@FD,1),(@CD,@FD,2);

DECLARE @ContD BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId)
VALUES (@ItemD, @CfgD, @LocD, 1);
SET @ContD = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
VALUES (@ContD, 1, 10, SYSUTCDATETIME(), 1, N'DR3-TEST', @FD);

DECLARE @GotDeep NVARCHAR(20) = Tools.ufn_ContainerOriginDieRankCode(@ContD);
EXEC test.Assert_IsEqual @TestName = N'[DieRank] deepest tool-bearing ancestor (origin casting) wins', @Expected = N'DR3-DEEP', @Actual = @GotDeep;
GO
EXEC test.EndTestFile;
GO
