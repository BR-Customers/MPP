-- =============================================
-- File:         0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-09-15
-- Description:  Route-driven Machining IN claim (spec 2026-09-15). Some oil pans skip
--               the trim shop; their route runs DieCast -> MachiningIn -> AssemblyOut and
--               a released basket sits in WHSE, never in Trim Storage. Such a LOT MUST
--               surface in the Machining IN queue of an eligible line and MUST be
--               claimable from the warehouse.
--               Also guards the one hazard the old location gate was covering: an OPEN
--               die-cast basket (still being filled) must NOT appear in the queue, even
--               though DieCast is OriginMint and MachiningIn is therefore "next".
--               And pins visible-but-not-claimable: a HELD LOT stays IN the queue (the
--               screen's "On Hold" indicator counts it) but the claim still refuses it.
--               Fixture: new part TSKIP-C, published route DieCast->MachiningIn->
--               AssemblyOut, eligible at MA1-5GOF only (MA1-6MD = ineligible control);
--               three LOTs -- Good in WHSE, Open at a press, Hold in WHSE.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql';
GO

-- ---- teardown from any previous run (closure BEFORE lots: FK) ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE m  FROM Lots.LotMovement m        INNER JOIN Lots.Lot l ON l.Id = m.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE h  FROM Lots.LotStatusHistory h   INNER JOIN Lots.Lot l ON l.Id = h.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE eg FROM Lots.LotEventLog eg       INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE c  FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'TSK-030-%';
GO

-- ---- fixture: the trim-skipping part + its published route ----
DECLARE @Dev   BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'DEV');
DECLARE @TComp BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'Component');
DECLARE @EA    BIGINT = (SELECT Id FROM Parts.Uom WHERE Code = N'EA');

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'TSKIP-C')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, DefaultSubLotQty, MaxLotSize, UomId, CreatedAt, CreatedByUserId)
    VALUES (@TComp, N'TSKIP-C', N'Trim-skipping oil pan casting (test fixture)', 12, 24, @EA, SYSUTCDATETIME(), @Dev);

DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TSKIP-C');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');

-- eligible at MA1-5GOF only
IF NOT EXISTS (SELECT 1 FROM Parts.ItemLocation WHERE ItemId = @Item AND LocationId = @Line AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ItemLocation (ItemId, LocationId, IsConsumptionPoint, CreatedAt)
    VALUES (@Item, @Line, 0, SYSUTCDATETIME());

-- published v1 route: DieCast -> MachiningIn -> AssemblyOut (no trim steps)
IF NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate WHERE ItemId = @Item AND VersionNumber = 1)
    INSERT INTO Parts.RouteTemplate (ItemId, VersionNumber, Name, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt)
    VALUES (@Item, 1, N'TSKIP-C Cast->Machine Route v1', '2026-01-15', '2026-01-14', NULL, @Dev, SYSUTCDATETIME());

DECLARE @Rt BIGINT = (SELECT Id FROM Parts.RouteTemplate WHERE ItemId = @Item AND VersionNumber = 1);

DECLARE @Steps TABLE (Seq INT, Role NVARCHAR(30), Descr NVARCHAR(120));
INSERT INTO @Steps (Seq, Role, Descr) VALUES
 (1, N'DieCast',     N'Die cast'),
 (2, N'MachiningIn', N'Machining in'),
 (3, N'AssemblyOut', N'Assembly out (mints the finished good)');

INSERT INTO Parts.RouteStep (RouteTemplateId, OperationTemplateId, SequenceNumber, IsRequired, Description)
SELECT @Rt, op.Id, s.Seq, 1, s.Descr
FROM @Steps s
CROSS APPLY (
    SELECT TOP 1 o.Id FROM Parts.OperationTemplate o
    JOIN Parts.OperationType oty ON oty.Id = o.OperationTypeId
    WHERE oty.Code = s.Role AND o.DeprecatedAt IS NULL ORDER BY o.Id
) op
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteStep x WHERE x.RouteTemplateId = @Rt AND x.SequenceNumber = s.Seq);
GO

-- ---- fixture: the LOTs ----
DECLARE @Item   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TSKIP-C');
DECLARE @Whse   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'WHSE');
DECLARE @Press  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M05');
DECLARE @Origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Open   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');
DECLARE @Hold   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Hold');   -- BlocksProduction = 1

-- A: a released basket in the WAREHOUSE. Next pending step is MachiningIn because
-- DieCast is OriginMint (never pending) and there are no trim steps at all.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TSK-030-A', @Item, @Origin, @Good, 24, 24, @Whse, 1, SYSUTCDATETIME());
DECLARE @LotA BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotA, @LotA, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@LotA, NULL, @Whse, 1, SYSUTCDATETIME());

-- B: an OPEN basket still being filled at the press. Same route, so its next pending
-- step is ALSO MachiningIn -- only the status keeps it out of the queue.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TSK-030-OPEN', @Item, @Origin, @Open, 6, 6, @Press, 1, SYSUTCDATETIME());
DECLARE @LotO BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotO, @LotO, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@LotO, NULL, @Press, 1, SYSUTCDATETIME());

-- C: a HELD basket in the warehouse. BlocksProduction = 1, so the claim will refuse it --
-- but it MUST stay VISIBLE in the queue, because the Machining IN screen counts every row
-- whose status is not 'Good' into its "On Hold" indicator. Visible-but-not-claimable is
-- deliberate (spec D5); dropping it would silently blank that indicator.
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt)
VALUES (N'TSK-030-HOLD', @Item, @Origin, @Hold, 18, 18, @Whse, 1, SYSUTCDATETIME());
DECLARE @LotH BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@LotH, @LotH, 0);
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt) VALUES (@LotH, NULL, @Whse, 1, SYSUTCDATETIME());
GO

-- ---- assertions: the READ ----
DECLARE @LotA  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-A');
DECLARE @LotO  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-OPEN');
DECLARE @LotH  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'TSK-030-HOLD');
DECLARE @Line  BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-5GOF');
DECLARE @LineX BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-6MD');   -- TSKIP-C NOT eligible here

DECLARE @Q TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3), NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT);

-- A1: the warehouse LOT is visible at the eligible line (this is the bug being fixed)
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @Line;
DECLARE @a1 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] trim-skipping LOT in WHSE is visible at the eligible line', @Expected = N'1', @Actual = @a1;

-- A2: its next step really is MachiningIn (proves the route, not an accident of the join)
DECLARE @a2 NVARCHAR(20) = (SELECT TOP 1 ISNULL(NextOperationTypeCode, N'(none)') FROM @Q WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] queue row reports MachiningIn as the next step', @Expected = N'MachiningIn', @Actual = @a2;

-- A3: the OPEN basket is NOT in the queue (the hazard the location gate used to cover)
DECLARE @a3 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotO);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] an OPEN die-cast basket is NOT in the Machining IN queue', @Expected = N'0', @Actual = @a3;

-- A4: a HELD LOT stays VISIBLE (spec D5 -- the screen's "On Hold" indicator depends on it)
DECLARE @a4 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotH);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] a HELD LOT is still visible in the queue', @Expected = N'1', @Actual = @a4;

-- A5: eligibility still gates -- absent at a line where the part is not eligible
DELETE FROM @Q; INSERT INTO @Q EXEC Lots.Lot_GetTrimStorageQueueForLine @LineLocationId = @LineX;
DECLARE @a5 NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @Q WHERE Id = @LotA);
EXEC test.Assert_IsEqual @TestName = N'[NoTrim] LOT NOT visible at an ineligible line', @Expected = N'0', @Actual = @a5;
GO

-- ---- cleanup (closure BEFORE lots) ----
DELETE pe FROM Workorder.ProductionEvent pe INNER JOIN Lots.Lot l ON l.Id = pe.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE m  FROM Lots.LotMovement m        INNER JOIN Lots.Lot l ON l.Id = m.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE h  FROM Lots.LotStatusHistory h   INNER JOIN Lots.Lot l ON l.Id = h.LotId  WHERE l.LotName LIKE N'TSK-030-%';
DELETE eg FROM Lots.LotEventLog eg       INNER JOIN Lots.Lot l ON l.Id = eg.LotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE c  FROM Lots.LotGenealogyClosure c INNER JOIN Lots.Lot l ON l.Id = c.AncestorLotId OR l.Id = c.DescendantLotId WHERE l.LotName LIKE N'TSK-030-%';
DELETE FROM Lots.Lot WHERE LotName LIKE N'TSK-030-%';
GO

EXEC test.EndTestFile;
GO
