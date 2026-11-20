-- =============================================
-- File:         0119_ContainerAsLot/030_gates_label_aim.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Container-as-LOT spec 7.2 / 7.3: the ship gates, CRT validation,
--               label LOT number and die-rank trace in the NEW shape (Container.LotId)
--               and the MIXED shape (an old tray LOT + a container LOT). The old shape
--               keeps its own coverage in 0029 / 0056 / 0025.
--               Fixture: three Complete containers, built by direct insert --
--                 NEW   container LOT N (2 trays, no tray LOTs)
--                 MIXED tray LOT M1 (tray 1) + container LOT M2 (tray 2)
--                 DIE   NEW-shape container whose tray 1 drew from a casting on die
--                       rank T118-A and tray 2 from die rank T118-B.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/030_gates_label_aim.sql';
GO

-- ---- fixture ----
DECLARE @Loc    BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Item   BIGINT = (SELECT TOP 1 ItemId FROM Parts.ContainerConfig WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Cfg    BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg    BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Done   BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Complete');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'T118-030-N', @Item, @Mfg, @Good, 8, @Loc, 1),
       (N'T118-030-M1', @Item, @Mfg, @Good, 4, @Loc, 1),
       (N'T118-030-M2', @Item, @Mfg, @Good, 4, @Loc, 1),
       (N'T118-030-D', @Item, @Mfg, @Good, 8, @Loc, 1);

INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId, LotId)
VALUES (@Item, @Cfg, @Loc, @Done, SYSUTCDATETIME(), 1, (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-N')),
       (@Item, @Cfg, @Loc, @Done, SYSUTCDATETIME(), 1, (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-M2')),
       (@Item, @Cfg, @Loc, @Done, SYSUTCDATETIME(), 1, (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-D'));
DECLARE @CN BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-N'));
DECLARE @CM BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-M2'));
DECLARE @CD BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-D'));
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId)
VALUES (@CN, 1, 4, SYSUTCDATETIME(), NULL), (@CN, 2, 4, SYSUTCDATETIME(), NULL),
       (@CM, 1, 4, SYSUTCDATETIME(), (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-M1')), (@CM, 2, 4, SYSUTCDATETIME(), NULL),
       (@CD, 1, 4, SYSUTCDATETIME(), NULL), (@CD, 2, 4, SYSUTCDATETIME(), NULL);

-- die-rank fixture: two dies, two castings -> two source LOTs; tray 1 drew from die A's
INSERT INTO Tools.DieRank (Code, Name) VALUES (N'T118-A', N'0119 rank A'), (N'T118-B', N'0119 rank B');
INSERT INTO Tools.Tool (ToolTypeId, Code, Name, DieRankId, StatusCodeId, CreatedByUserId)
SELECT (SELECT Id FROM Tools.ToolType WHERE Code = N'Die'), r.Code + N'-DIE', r.Name, r.Id,
       (SELECT Id FROM Tools.ToolStatusCode WHERE Code = N'Active'), 1
FROM Tools.DieRank r WHERE r.Code IN (N'T118-A', N'T118-B');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, ToolId)
VALUES (N'T118-030-CASTA', @Item, @Mfg, @Good, 0, @Loc, 1, (SELECT Id FROM Tools.Tool WHERE Code = N'T118-A-DIE')),
       (N'T118-030-CASTB', @Item, @Mfg, @Good, 0, @Loc, 1, (SELECT Id FROM Tools.Tool WHERE Code = N'T118-B-DIE')),
       (N'T118-030-SRCA', @Item, @Mfg, @Good, 0, @Loc, 1, NULL),
       (N'T118-030-SRCB', @Item, @Mfg, @Good, 0, @Loc, 1, NULL);
DECLARE @CastA BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-CASTA');
DECLARE @CastB BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-CASTB');
DECLARE @SrcA  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-SRCA');
DECLARE @SrcB  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-SRCB');
DECLARE @DLot  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-D');
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
VALUES (@CastA, @CastA, 0), (@CastB, @CastB, 0), (@SrcA, @SrcA, 0), (@SrcB, @SrcB, 0), (@DLot, @DLot, 0),
       (@CastA, @SrcA, 1), (@CastB, @SrcB, 1),
       -- the container LOT's closure holds BOTH castings; B is reached at the same depth
       (@SrcA, @DLot, 1), (@SrcB, @DLot, 1), (@CastA, @DLot, 2), (@CastB, @DLot, 2);
INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId, PieceCount, LocationId, AppUserId, TrayId)
VALUES (@SrcB, @DLot, @CD, @Item, @Item, 4, @Loc, 1, (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CD AND TrayPosition = 2)),
       (@SrcA, @DLot, @CD, @Item, @Item, 4, @Loc, 1, (SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CD AND TrayPosition = 1));
GO

DECLARE @CN BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-N'));
DECLARE @CM BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-M2'));
DECLARE @CD BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-D'));
DECLARE @N  BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-N');
DECLARE @M2 BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-030-M2');
DECLARE @c BIT;

-- ---- label LOT number + die rank ----
DECLARE @L TABLE (PartNumber NVARCHAR(50), Description NVARCHAR(500), CountryOfOrigin NVARCHAR(50), Quantity NVARCHAR(20), MfgDate NVARCHAR(20), MfgLotNumber NVARCHAR(50), Serial NVARCHAR(50));
INSERT INTO @L EXEC Lots.Container_GetLabelData @ContainerId = @CN;
SET @c = CASE WHEN (SELECT MfgLotNumber FROM @L) = N'T118-030-N' AND (SELECT Quantity FROM @L) = N'8' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Label] new container: MfgLotNumber = container LOT, Quantity = tray sum', @Condition = @c;
DELETE FROM @L;
INSERT INTO @L EXEC Lots.Container_GetLabelData @ContainerId = @CM;
SET @c = CASE WHEN (SELECT MfgLotNumber FROM @L) = N'T118-030-M1' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Label] mixed container: MfgLotNumber = first tray LOT', @Condition = @c;

SET @c = CASE WHEN Tools.ufn_ContainerOriginDieRankCode(@CD) = N'T118-A' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[DieRank] new container: rank from the FIRST tray''s casting (A, not B)', @Condition = @c;

-- ---- CRT: pending list, ship gate, AIM unposted exclusion, validate ----
UPDATE Lots.Lot SET CrtActive = 1 WHERE Id IN (@N, @M2);

DECLARE @P TABLE (ContainerId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500), PieceCount INT, CompletedAtEt DATETIME2(3), AimShipperId NVARCHAR(50), AgeMinutes INT, PendingLotCount INT);
INSERT INTO @P EXEC Lots.Container_ListPendingValidation @ContainerId = @CN;
SET @c = CASE WHEN (SELECT COUNT(*) FROM @P) = 1 AND (SELECT PieceCount FROM @P) = 8 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CRT] new container with a CRT LOT is pending validation, pieces = tray sum', @Condition = @c;
DELETE FROM @P;
INSERT INTO @P EXEC Lots.Container_ListPendingValidation @ContainerId = @CM;
SET @c = CASE WHEN (SELECT COUNT(*) FROM @P) = 1 AND (SELECT PieceCount FROM @P) = 8 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CRT] mixed container pending when only its container LOT is CRT', @Condition = @c;

DECLARE @S TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId)
VALUES (@CN, N'T118-030-SLN', (SELECT TOP 1 Id FROM Lots.LabelTypeCode ORDER BY Id)),
       (@CM, N'T118-030-SLM', (SELECT TOP 1 Id FROM Lots.LabelTypeCode ORDER BY Id));
DECLARE @SlN BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'T118-030-SLN');
DECLARE @SlM BIGINT = (SELECT Id FROM Lots.ShippingLabel WHERE AimShipperId = N'T118-030-SLM');
INSERT INTO @S EXEC Lots.Container_Ship @ShippingLabelId = @SlN, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @S) = 0 AND (SELECT Message FROM @S) LIKE N'%Controlled Run Tag%' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Ship] new container with a CRT LOT refused', @Condition = @c;
DELETE FROM @S;
INSERT INTO @S EXEC Lots.Container_Ship @ShippingLabelId = @SlM, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @S) = 0 AND (SELECT Message FROM @S) LIKE N'%Controlled Run Tag%' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Ship] mixed container refused on its container LOT''s CRT', @Condition = @c;

-- AIM: a consumed, unposted serial on the new container is held back while CRT
INSERT INTO Lots.AimShipperIdPool (AimShipperId, ConsumedByContainerId, ConsumedAt)
VALUES (N'T118-030-AIM', @CN, SYSUTCDATETIME());
DECLARE @U TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT, CustomerPartNumber NVARCHAR(50), Quantity INT, LotNumber NVARCHAR(50),
                  PostAttempts INT, LastPostError NVARCHAR(MAX), ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @U EXEC Lots.AimShipperIdPool_ListUnposted @Top = 100000;
SET @c = CASE WHEN NOT EXISTS (SELECT 1 FROM @U WHERE AimShipperId = N'T118-030-AIM') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[AIM] ListUnposted holds back the new container''s serial while its LOT is CRT', @Condition = @c;

DECLARE @V TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @V EXEC Lots.Container_ValidateCrt @ContainerId = @CN, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @V) = 1 AND (SELECT CrtActive FROM Lots.Lot WHERE Id = @N) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CRT] ValidateCrt clears the container LOT', @Condition = @c;
DELETE FROM @V;
INSERT INTO @V EXEC Lots.Container_ValidateCrt @ContainerId = @CM, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @V) = 1 AND (SELECT CrtActive FROM Lots.Lot WHERE Id = @M2) = 0 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[CRT] ValidateCrt clears a mixed container''s container LOT', @Condition = @c;

-- ---- held LOT blocks the ship (new shape), named ----
DECLARE @HR TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HR EXEC Quality.Hold_Place @LotId = @N, @HoldTypeCodeId = 1, @Reason = N'0119 030 hold', @AppUserId = 1;
DELETE FROM @S;
INSERT INTO @S EXEC Lots.Container_Ship @ShippingLabelId = @SlN, @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @S) = 0 AND (SELECT Message FROM @S) LIKE N'%T118-030-N%on hold%' THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Ship] new container refused while its LOT is held, naming the LOT', @Condition = @c;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
