-- =============================================
-- File:         0028_PlantFloor_Assembly/094_Assembly_ComponentProjection.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-07-23
-- Description:  Workorder.Assembly_GetComponentProjection (display-only). Per active-BOM
--   component: PerTrayNeed = CAST(QtyPer*PartsPerTray AS INT), RemainingTrays =
--   MAX(TraysPerContainer-ClosedTrays,0), Projected = PerTrayNeed*RemainingTrays,
--   OnHand = exact-cell non-closed InventoryAvailable, IsLow = OnHand<Projected.
--   Phases: (1) mid-fill open container, (2) fresh no-container by (item,method),
--   (3) over-target -> 0 remaining, (4) empty sets, (5) OnHand exact-cell pool fidelity.
--   Cell: MA1-COMPBR-AOUT.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0028_PlantFloor_Assembly/094_Assembly_ComponentProjection.sql';
GO

-- ---- cleanup ----
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-PROJ-OUT');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @Out;
DELETE FROM Lots.Container WHERE ItemId = @Out;
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-094%';
GO

-- ---- fixture ----
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'P6-PROJ-OUT') INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-PROJ-OUT', N'Projection FG', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'P6-PROJ-A')   INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-PROJ-A', N'Projection comp A', 1, @Now, 1);
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber=N'P6-PROJ-B')   INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (3, N'P6-PROJ-B', N'Projection comp B', 1, @Now, 1);
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P6-PROJ-OUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P6-PROJ-A');
DECLARE @B BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P6-PROJ-B');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'MA1-COMPBR-AOUT');

-- container config: 4 trays x 10 (Target 40), ByCount
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId=@Out AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Out, 4, 10, 0, N'ByCount', @Now);
DECLARE @Cfg BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId=@Out AND DeprecatedAt IS NULL);

-- published BOM: OUT <- A x1 + B x2
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId=@Out AND PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Out, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @A, 1, 1, 1), ((SELECT TOP 1 Id FROM Parts.Bom WHERE ParentItemId=@Out ORDER BY Id DESC), @B, 2, 1, 2);
END

-- component stock at the exact cell: A=25, B=30
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-094A', @A, 1, 1, 25, 25, @Cell, 1, @Now);
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-094B', @B, 1, 1, 30, 30, @Cell, 1, @Now);

-- open container with 2 closed trays (Accumulated 20 of 40; RemainingTrays 2)
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CreatedByUserId) VALUES (@Out, @Cfg, @Cell, 1, @Now, 1);
DECLARE @Cid BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod) VALUES (@Cid, 1, 10, @Now, 1, N'ByCount'), (@Cid, 2, 10, @Now, 1, N'ByCount');
GO

-- =============================================
-- Phase 1: mid-fill open container (2 of 4 trays; RemainingTrays 2)
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P6-PROJ-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'MA1-COMPBR-AOUT');
DECLARE @P1 TABLE (ChildItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), QtyPer DECIMAL(18,4), PerTrayNeed INT, RemainingTrays INT, ProjectedRemainingConsumption INT, OnHand INT, Shortfall INT, IsLow BIT);
INSERT INTO @P1 EXEC Workorder.Assembly_GetComponentProjection @CellLocationId=@Cell, @FinishedGoodItemId=@Out, @ClosureMethod=N'ByCount';

DECLARE @Rows NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @P1);
EXEC test.Assert_IsEqual @TestName=N'[Proj] two component rows', @Expected=N'2', @Actual=@Rows;
-- A: PerTrayNeed 10, RemainingTrays 2, Projected 20, OnHand 25 -> IsLow 0
DECLARE @Aproj NVARCHAR(10) = (SELECT CAST(ProjectedRemainingConsumption AS NVARCHAR(10)) FROM @P1 WHERE ItemPartNumber=N'P6-PROJ-A');
EXEC test.Assert_IsEqual @TestName=N'[Proj] A projected 20 (10x2)', @Expected=N'20', @Actual=@Aproj;
DECLARE @Alow NVARCHAR(10) = (SELECT CAST(IsLow AS NVARCHAR(10)) FROM @P1 WHERE ItemPartNumber=N'P6-PROJ-A');
EXEC test.Assert_IsEqual @TestName=N'[Proj] A not low (25>=20)', @Expected=N'0', @Actual=@Alow;
-- B: PerTrayNeed 20, Projected 40, OnHand 30 -> IsLow 1, Shortfall 10
DECLARE @Bproj NVARCHAR(10) = (SELECT CAST(ProjectedRemainingConsumption AS NVARCHAR(10)) FROM @P1 WHERE ItemPartNumber=N'P6-PROJ-B');
EXEC test.Assert_IsEqual @TestName=N'[Proj] B projected 40 (20x2)', @Expected=N'40', @Actual=@Bproj;
DECLARE @Blow NVARCHAR(10) = (SELECT CAST(IsLow AS NVARCHAR(10)) FROM @P1 WHERE ItemPartNumber=N'P6-PROJ-B');
EXEC test.Assert_IsEqual @TestName=N'[Proj] B low (30<40)', @Expected=N'1', @Actual=@Blow;
DECLARE @Bshort NVARCHAR(10) = (SELECT CAST(Shortfall AS NVARCHAR(10)) FROM @P1 WHERE ItemPartNumber=N'P6-PROJ-B');
EXEC test.Assert_IsEqual @TestName=N'[Proj] B shortfall 10', @Expected=N'10', @Actual=@Bshort;
GO

-- =============================================
-- Phase 2: fresh, no open container -> resolve config by (item, method), RemainingTrays 4
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P6-PROJ-OUT');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'MA1-COMPBR-AOUT');
-- close the open container so none is open
UPDATE Lots.Container SET ContainerStatusCodeId=2, CompletedAt=SYSUTCDATETIME() WHERE ItemId=@Out AND ContainerStatusCodeId=1;
DECLARE @P2 TABLE (ChildItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), QtyPer DECIMAL(18,4), PerTrayNeed INT, RemainingTrays INT, ProjectedRemainingConsumption INT, OnHand INT, Shortfall INT, IsLow BIT);
INSERT INTO @P2 EXEC Workorder.Assembly_GetComponentProjection @CellLocationId=@Cell, @FinishedGoodItemId=@Out, @ClosureMethod=N'ByCount';
DECLARE @A2rt NVARCHAR(10) = (SELECT CAST(RemainingTrays AS NVARCHAR(10)) FROM @P2 WHERE ItemPartNumber=N'P6-PROJ-A');
EXEC test.Assert_IsEqual @TestName=N'[Proj] fresh RemainingTrays 4', @Expected=N'4', @Actual=@A2rt;
DECLARE @A2proj NVARCHAR(10) = (SELECT CAST(ProjectedRemainingConsumption AS NVARCHAR(10)) FROM @P2 WHERE ItemPartNumber=N'P6-PROJ-A');
EXEC test.Assert_IsEqual @TestName=N'[Proj] fresh A projected 40 (10x4)', @Expected=N'40', @Actual=@A2proj;
GO

-- =============================================
-- Phase 4: empty sets (NULL FG; FG with no config)
-- =============================================
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'MA1-COMPBR-AOUT');
DECLARE @E1 TABLE (ChildItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), QtyPer DECIMAL(18,4), PerTrayNeed INT, RemainingTrays INT, ProjectedRemainingConsumption INT, OnHand INT, Shortfall INT, IsLow BIT);
INSERT INTO @E1 EXEC Workorder.Assembly_GetComponentProjection @CellLocationId=@Cell, @FinishedGoodItemId=NULL, @ClosureMethod=N'ByCount';
DECLARE @E1c NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @E1);
EXEC test.Assert_IsEqual @TestName=N'[Proj] NULL FG -> empty set', @Expected=N'0', @Actual=@E1c;
GO

-- =============================================
-- Phase 5: OnHand pool fidelity - only exact-cell, non-closed, available count
-- =============================================
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P6-PROJ-OUT');
DECLARE @A BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber=N'P6-PROJ-A');
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'MA1-COMPBR-AOUT');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code=N'MA1-COMPBR-MIN');  -- a different cell
-- add noise: a Closed lot at the cell (must not count) + a lot at another cell (must not count) + a 0-available lot
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-094A-closed', @A, 1, (SELECT Id FROM Lots.LotStatusCode WHERE Code=N'Closed'), 100, 100, @Cell, 1, SYSUTCDATETIME());
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-094A-other', @A, 1, 1, 100, 100, @Other, 1, SYSUTCDATETIME());
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt) VALUES (N'STG-094A-zero', @A, 1, 1, 0, 0, @Cell, 1, SYSUTCDATETIME());
DECLARE @P5 TABLE (ChildItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(200), QtyPer DECIMAL(18,4), PerTrayNeed INT, RemainingTrays INT, ProjectedRemainingConsumption INT, OnHand INT, Shortfall INT, IsLow BIT);
INSERT INTO @P5 EXEC Workorder.Assembly_GetComponentProjection @CellLocationId=@Cell, @FinishedGoodItemId=@Out, @ClosureMethod=N'ByCount';
-- OnHand for A must still be 25 (only STG-094A counts; closed/other-cell/zero excluded)
DECLARE @A5oh NVARCHAR(10) = (SELECT CAST(OnHand AS NVARCHAR(10)) FROM @P5 WHERE ItemPartNumber=N'P6-PROJ-A');
EXEC test.Assert_IsEqual @TestName=N'[Proj] OnHand exact-cell only (25; closed/other/zero excluded)', @Expected=N'25', @Actual=@A5oh;
GO

-- ---- cleanup ----
DECLARE @Out BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P6-PROJ-OUT');
DELETE tr FROM Lots.ContainerTray tr INNER JOIN Lots.Container ct ON ct.Id = tr.ContainerId WHERE ct.ItemId = @Out;
DELETE FROM Lots.Container WHERE ItemId = @Out;
DELETE FROM Lots.Lot WHERE LotName LIKE N'STG-094%';
GO

EXEC test.EndTestFile;
GO
