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

-- ---- fixture cleanup (re-runnable; anchored on the DRT namespace) ----
DELETE FROM Lots.ContainerTray WHERE ClosureMethod = N'DRT-TEST';
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId   IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'DRT%');
DELETE FROM Lots.LotGenealogyClosure WHERE DescendantLotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'DRT%');
DELETE FROM Lots.Lot     WHERE LotName LIKE N'DRT%';
DELETE FROM Tools.Tool   WHERE Code = N'DRT-DIE';
DELETE FROM Tools.DieRank WHERE Code = N'DRT-A';
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
EXEC test.EndTestFile;
GO
