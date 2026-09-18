-- =============================================
-- File:         0029_PlantFloor_Hold_Sort_Shipping_Aim/082_ShippingLabel_ListRecentByCell.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-17
-- Description:  Lots.ShippingLabel_ListRecentByCell -- the pick list for the elevated
--               Assembly OUT shipping-label reprint popup.
--               Asserts:
--                 * a container AT the cell and one UNDER it both appear; one at a
--                   sibling location does not (scope is Container.CurrentLocationId);
--                 * one row per container -- the newest non-void label;
--                 * a container whose only label is void is excluded; a container
--                   whose newest label is void falls back to its older live label;
--                 * a container with status Void is excluded;
--                 * Serial = '13218001' + last 8 of the AIM serial; Quantity = closed trays;
--                 * PrintStatus Printed / Failed / Pending;
--                 * CreatedAt converted UTC -> Eastern;
--                 * newest first, @TopN honoured, @TopN NULL/0 -> 10, NULL cell -> empty.
--
--               Self-contained fixture: direct inserts only (no procs, so no audit rows).
--                 TEST-SLR-LINE  (Line, DefId 5)        <- @CellLocationId
--                   +- TEST-SLR-TERM (Terminal, DefId 7) <- descendant
--                 TEST-SLR-OTHER (Line, DefId 5)        <- outside the cell
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0029_PlantFloor_Hold_Sort_Shipping_Aim/082_ShippingLabel_ListRecentByCell.sql';
GO

-- ---- teardown any prior fixtures (children before parents) ----
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'PN-SLR-TEST';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'PN-SLR-TEST';
DELETE FROM Lots.Container       WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-SLR-TEST');
DELETE FROM Parts.ContainerConfig WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-SLR-TEST');
DELETE FROM Parts.Item           WHERE PartNumber = N'PN-SLR-TEST';
DELETE FROM Location.Location    WHERE Code = N'TEST-SLR-TERM';
DELETE FROM Location.Location    WHERE Code IN (N'TEST-SLR-LINE', N'TEST-SLR-OTHER');
GO

-- ---- build the fixture ----
DECLARE @SiteId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MPP-MAD');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (5, @SiteId, N'Test SLR Line',  N'TEST-SLR-LINE',  N'ListRecentByCell test line',    960),
       (5, @SiteId, N'Test SLR Other', N'TEST-SLR-OTHER', N'ListRecentByCell outside line', 961);
DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SLR-LINE');
DECLARE @Other BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SLR-OTHER');
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (7, @Line, N'Test SLR Terminal', N'TEST-SLR-TERM', N'ListRecentByCell test terminal', 1);
DECLARE @Term  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-SLR-TERM');

DECLARE @Item BIGINT;
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId)
VALUES ((SELECT TOP 1 Id FROM Parts.ItemType ORDER BY Id), N'PN-SLR-TEST', N'SLR test part',
        (SELECT TOP 1 Id FROM Parts.Uom ORDER BY Id), 1);
SET @Item = SCOPE_IDENTITY();
DECLARE @Cfg BIGINT;
INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, ClosureMethod) VALUES (@Item, 1, 6, N'ByCount');
SET @Cfg = SCOPE_IDENTITY();

DECLARE @Complete BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Complete');
DECLARE @VoidSt   BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Void');
DECLARE @LblType  BIGINT = (SELECT Id FROM Lots.LabelTypeCode WHERE Code = N'Container');
-- Fixed January base: EST (UTC-5), no DST ambiguity. 17:00 UTC -> 12:00 Eastern.
DECLARE @Base DATETIME2(3) = '2026-01-15T17:00:00';

-- C1: at the cell, one printed initial label, 6 parts closed.
DECLARE @C1 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, @Complete, 1);
SET @C1 = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod) VALUES (@C1, 1, 6, @Base, 1, N'ByCount');
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, CreatedAt, PrintedAt)
VALUES (@C1, N'SLRAIM0012345678', @LblType, 1, 1, @Base, @Base);

-- C2: UNDER the cell (terminal), initial label + a newer failed reprint -> one row, the reprint.
DECLARE @C2 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Term, @Complete, 1);
SET @C2 = SCOPE_IDENTITY();
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, CreatedAt, PrintedAt)
VALUES (@C2, N'SLRAIM0000000002', @LblType, 1, 1, DATEADD(MINUTE, 10, @Base), DATEADD(MINUTE, 10, @Base));
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintReasonCode, PrintedByUserId, CreatedAt, PrintFailedAt)
VALUES (@C2, N'SLRAIM0000000002', @LblType, 0, N'smudged', 1, DATEADD(MINUTE, 20, @Base), DATEADD(MINUTE, 20, @Base));
DECLARE @C2Reprint BIGINT = SCOPE_IDENTITY();

-- C3: at a sibling location -> excluded.
DECLARE @C3 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Other, @Complete, 1);
SET @C3 = SCOPE_IDENTITY();
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, CreatedAt)
VALUES (@C3, N'SLRAIM0000000003', @LblType, 1, 1, DATEADD(MINUTE, 30, @Base));

-- C4: at the cell, its only label is void -> excluded.
DECLARE @C4 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, @Complete, 1);
SET @C4 = SCOPE_IDENTITY();
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, CreatedAt, IsVoid, VoidedAt)
VALUES (@C4, N'SLRAIM0000000004', @LblType, 1, 1, DATEADD(MINUTE, 40, @Base), 1, DATEADD(MINUTE, 41, @Base));

-- C5: at the cell, live label, but the CONTAINER is Void -> excluded.
DECLARE @C5 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, @VoidSt, 1);
SET @C5 = SCOPE_IDENTITY();
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, CreatedAt)
VALUES (@C5, N'SLRAIM0000000005', @LblType, 1, 1, DATEADD(MINUTE, 50, @Base));

-- C6: at the cell, older live label (pending) + NEWER void one -> one row, the older live label.
DECLARE @C6 BIGINT;
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId) VALUES (@Item, @Cfg, @Line, @Complete, 1);
SET @C6 = SCOPE_IDENTITY();
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, CreatedAt)
VALUES (@C6, N'SLRAIM0000000006', @LblType, 1, 1, DATEADD(MINUTE, 60, @Base));
DECLARE @C6Live BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, Initial, PrintedByUserId, CreatedAt, IsVoid, VoidedAt)
VALUES (@C6, N'SLRAIM0000000006', @LblType, 0, 1, DATEADD(MINUTE, 70, @Base), 1, DATEADD(MINUTE, 71, @Base));

-- ---- run the read ----
CREATE TABLE #R (
    Id BIGINT, ContainerId BIGINT, AimShipperId NVARCHAR(50), Serial NVARCHAR(16),
    ItemId BIGINT, PartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), Quantity INT,
    Initial BIT, PrintReasonCode NVARCHAR(50), PrintStatus NVARCHAR(10),
    CreatedAt DATETIME2(3), PrintedAt DATETIME2(3));
INSERT INTO #R EXEC Lots.ShippingLabel_ListRecentByCell @CellLocationId = @Line;

DECLARE @Cnt INT = (SELECT COUNT(*) FROM #R);
EXEC test.Assert_RowCount @TestName = N'[Scope] three containers listed (C1, C2, C6)', @ExpectedCount = 3, @ActualCount = @Cnt;

DECLARE @Hit NVARCHAR(10);
SET @Hit = CASE WHEN EXISTS (SELECT 1 FROM #R WHERE ContainerId = @C1) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Scope] container AT the cell listed', @Expected = N'1', @Actual = @Hit;
SET @Hit = CASE WHEN EXISTS (SELECT 1 FROM #R WHERE ContainerId = @C2) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Scope] container UNDER the cell listed', @Expected = N'1', @Actual = @Hit;
SET @Hit = CASE WHEN EXISTS (SELECT 1 FROM #R WHERE ContainerId = @C3) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Scope] container at a sibling location excluded', @Expected = N'0', @Actual = @Hit;
SET @Hit = CASE WHEN EXISTS (SELECT 1 FROM #R WHERE ContainerId = @C4) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Void] container whose only label is void excluded', @Expected = N'0', @Actual = @Hit;
SET @Hit = CASE WHEN EXISTS (SELECT 1 FROM #R WHERE ContainerId = @C5) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Void] Void-status container excluded', @Expected = N'0', @Actual = @Hit;

DECLARE @C2Rows INT = (SELECT COUNT(*) FROM #R WHERE ContainerId = @C2);
EXEC test.Assert_RowCount @TestName = N'[Dedupe] reprinted container appears once', @ExpectedCount = 1, @ActualCount = @C2Rows;
DECLARE @C2Pick NVARCHAR(10) = CASE WHEN (SELECT Id FROM #R WHERE ContainerId = @C2) = @C2Reprint THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Dedupe] newest label row chosen', @Expected = N'1', @Actual = @C2Pick;
DECLARE @C6Pick NVARCHAR(10) = CASE WHEN (SELECT Id FROM #R WHERE ContainerId = @C6) = @C6Live THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Void] newest void label skipped, older live label chosen', @Expected = N'1', @Actual = @C6Pick;

DECLARE @Serial NVARCHAR(16) = (SELECT Serial FROM #R WHERE ContainerId = @C1);
EXEC test.Assert_IsEqual @TestName = N'[Shape] Serial = 13218001 + last 8 of AIM', @Expected = N'1321800112345678', @Actual = @Serial;
DECLARE @Qty NVARCHAR(10) = (SELECT CAST(Quantity AS NVARCHAR(10)) FROM #R WHERE ContainerId = @C1);
EXEC test.Assert_IsEqual @TestName = N'[Shape] Quantity = closed tray parts', @Expected = N'6', @Actual = @Qty;
DECLARE @Part NVARCHAR(50) = (SELECT PartNumber FROM #R WHERE ContainerId = @C1);
EXEC test.Assert_IsEqual @TestName = N'[Shape] PartNumber resolved', @Expected = N'PN-SLR-TEST', @Actual = @Part;
DECLARE @Reason NVARCHAR(50) = (SELECT PrintReasonCode FROM #R WHERE ContainerId = @C2);
EXEC test.Assert_IsEqual @TestName = N'[Shape] PrintReasonCode carried', @Expected = N'smudged', @Actual = @Reason;

DECLARE @Ps NVARCHAR(10);
SET @Ps = (SELECT PrintStatus FROM #R WHERE ContainerId = @C1);
EXEC test.Assert_IsEqual @TestName = N'[Status] PrintedAt -> Printed', @Expected = N'Printed', @Actual = @Ps;
SET @Ps = (SELECT PrintStatus FROM #R WHERE ContainerId = @C2);
EXEC test.Assert_IsEqual @TestName = N'[Status] PrintFailedAt -> Failed', @Expected = N'Failed', @Actual = @Ps;
SET @Ps = (SELECT PrintStatus FROM #R WHERE ContainerId = @C6);
EXEC test.Assert_IsEqual @TestName = N'[Status] neither -> Pending', @Expected = N'Pending', @Actual = @Ps;

DECLARE @Et NVARCHAR(30) = (SELECT CONVERT(NVARCHAR(30), CreatedAt, 126) FROM #R WHERE ContainerId = @C1);
EXEC test.Assert_IsEqual @TestName = N'[TZ] CreatedAt converted UTC -> Eastern', @Expected = N'2026-01-15T12:00:00', @Actual = @Et;

DECLARE @First NVARCHAR(10) = CASE WHEN (SELECT TOP 1 ContainerId FROM #R ORDER BY CreatedAt DESC) = @C6 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[Order] newest container first', @Expected = N'1', @Actual = @First;
DROP TABLE #R;

-- ---- TopN ----
CREATE TABLE #T (
    Id BIGINT, ContainerId BIGINT, AimShipperId NVARCHAR(50), Serial NVARCHAR(16),
    ItemId BIGINT, PartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), Quantity INT,
    Initial BIT, PrintReasonCode NVARCHAR(50), PrintStatus NVARCHAR(10),
    CreatedAt DATETIME2(3), PrintedAt DATETIME2(3));
INSERT INTO #T EXEC Lots.ShippingLabel_ListRecentByCell @CellLocationId = @Line, @TopN = 1;
SET @Cnt = (SELECT COUNT(*) FROM #T);
EXEC test.Assert_RowCount @TestName = N'[TopN] @TopN = 1 returns one row', @ExpectedCount = 1, @ActualCount = @Cnt;
SET @Hit = CASE WHEN (SELECT ContainerId FROM #T) = @C6 THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual @TestName = N'[TopN] the one row is the newest', @Expected = N'1', @Actual = @Hit;
DELETE FROM #T;

INSERT INTO #T EXEC Lots.ShippingLabel_ListRecentByCell @CellLocationId = @Line, @TopN = 0;
SET @Cnt = (SELECT COUNT(*) FROM #T);
EXEC test.Assert_RowCount @TestName = N'[TopN] @TopN = 0 falls back to 10 (all 3 rows)', @ExpectedCount = 3, @ActualCount = @Cnt;
DELETE FROM #T;

INSERT INTO #T EXEC Lots.ShippingLabel_ListRecentByCell @CellLocationId = NULL;
SET @Cnt = (SELECT COUNT(*) FROM #T);
EXEC test.Assert_RowCount @TestName = N'[Guard] NULL cell returns empty set', @ExpectedCount = 0, @ActualCount = @Cnt;
DROP TABLE #T;
GO

-- ---- teardown ----
DELETE sl FROM Lots.ShippingLabel sl INNER JOIN Lots.Container c ON c.Id = sl.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'PN-SLR-TEST';
DELETE ct FROM Lots.ContainerTray ct INNER JOIN Lots.Container c ON c.Id = ct.ContainerId INNER JOIN Parts.Item i ON i.Id = c.ItemId WHERE i.PartNumber = N'PN-SLR-TEST';
DELETE FROM Lots.Container       WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-SLR-TEST');
DELETE FROM Parts.ContainerConfig WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'PN-SLR-TEST');
DELETE FROM Parts.Item           WHERE PartNumber = N'PN-SLR-TEST';
DELETE FROM Location.Location    WHERE Code = N'TEST-SLR-TERM';
DELETE FROM Location.Location    WHERE Code IN (N'TEST-SLR-LINE', N'TEST-SLR-OTHER');
GO
EXEC test.EndTestFile;
GO
