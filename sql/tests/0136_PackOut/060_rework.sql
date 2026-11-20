-- =============================================
-- File: 0136_PackOut/060_rework.sql
-- Desc: D11 -- no rework across pack-outs. ContainerRework_ListTargets offers
--       only boxes on the SAME pack-out (any version) as the source box, and
--       ContainerRework_MovePieces refuses a different-pack-out target.
--       Uses the TST-PO-FG Cardboard / Tote pack-outs from 020_resolve.sql.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0136_PackOut/060_rework.sql';
GO

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @Card BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND Name = N'Cardboard' AND DeprecatedAt IS NULL);
DECLARE @Tote BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND Name = N'Tote' AND DeprecatedAt IS NULL);
DECLARE @CardNow BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE PackOutId = @Card AND DeprecatedAt IS NULL);
DECLARE @CardOld BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE PackOutId = @Card AND DeprecatedAt IS NOT NULL ORDER BY VersionNumber);
DECLARE @ToteNow BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE PackOutId = @Tote AND DeprecatedAt IS NULL);
DECLARE @Proc BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'ReworkProcessing');
DECLARE @Fill BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'ReworkFilling');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

-- Source: a Cardboard box (old version, opened before an edit) under rework, one tray LOT of 6.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId)
VALUES (N'TPO-RW-' + LEFT(CAST(NEWID() AS NVARCHAR(36)), 8), @Item, @Mfg, @Good, 6, 6, @Line, 1);
DECLARE @TrayLot BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @CardOld, @Line, @Proc, 1);
DECLARE @Src BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosureMethod, FinishedGoodLotId)
VALUES (@Src, 1, 6, SYSUTCDATETIME(), N'ByWeight', @TrayLot);
DECLARE @SrcTray BIGINT = SCOPE_IDENTITY();

-- Targets: a refill-ready Cardboard box on the CURRENT version, and a refill-ready Tote box.
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @CardNow, @Line, @Fill, 1);
DECLARE @ToCard BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @ToteNow, @Line, @Fill, 1);
DECLARE @ToTote BIGINT = SCOPE_IDENTITY();

CREATE TABLE #Tg (ContainerId BIGINT, CurrentLocationName NVARCHAR(200), Pieces INT, TargetParts INT, Room INT);
INSERT INTO #Tg EXEC Lots.ContainerRework_ListTargets @ContainerId = @Src;
DECLARE @S NVARCHAR(500) = (SELECT STRING_AGG(CASE WHEN ContainerId = @ToCard THEN N'card' WHEN ContainerId = @ToTote THEN N'tote' ELSE N'other' END, N',') FROM #Tg);
EXEC test.Assert_IsEqual @TestName = N'[Rework] targets: only the same pack-out (any version)', @Expected = N'card', @Actual = @S;
DROP TABLE #Tg;

DECLARE @M TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @M EXEC Lots.ContainerRework_MovePieces @FromContainerTrayId = @SrcTray, @ToContainerId = @ToTote, @Quantity = 2, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', CASE WHEN Message LIKE N'%different pack-out (Tote)%' THEN N'packout' ELSE Message END) FROM @M);
EXEC test.Assert_IsEqual @TestName = N'[Rework] move into a different pack-out refused', @Expected = N'0|packout', @Actual = @S;

-- Cleanup
DELETE FROM Lots.ContainerTray WHERE ContainerId IN (@Src, @ToCard, @ToTote);
DELETE FROM Lots.Container WHERE Id IN (@Src, @ToCard, @ToTote);
DELETE FROM Lots.Lot WHERE Id = @TrayLot;
GO
EXEC test.EndTestFile;
GO
