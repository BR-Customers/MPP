-- =============================================
-- File:         0119_ContainerAsLot/040_trace_hold_readers.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Container-as-LOT spec 7.3 / 7.6: trace, hold and LOT->container readers
--               on a NEW-shape container (Container.LotId, 2 trays of 4, no tray LOTs).
--               Each reader's result is captured into a global temp table shaped from
--               sys.dm_exec_describe_first_result_set_for_object, so the test does not
--               restate every column list. Old-shape coverage stays in 0029 / 0055 /
--               0068 / 0113 / 0114.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/040_trace_hold_readers.sql';
GO

-- capture helper: (re)creates ##R118 shaped like @Proc's first result set
CREATE OR ALTER PROCEDURE dbo.T118_Shape @Proc NVARCHAR(200)
AS
BEGIN
    IF OBJECT_ID('tempdb..##R118') IS NOT NULL DROP TABLE ##R118;
    DECLARE @cols NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(QUOTENAME(name) + N' ' + system_type_name + N' NULL' AS NVARCHAR(MAX)), N', ')
               WITHIN GROUP (ORDER BY column_ordinal)
        FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(@Proc), 0));
    EXEC (N'CREATE TABLE ##R118 (' + @cols + N')');
END;
GO

-- ---- fixture ----
DECLARE @Loc  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Item BIGINT = (SELECT TOP 1 ItemId FROM Parts.ContainerConfig WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Cfg  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Done BIGINT = (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Complete');
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'T118-040-N', @Item, @Mfg, @Good, 8, @Loc, 1),
       (N'T118-040-SRC', @Item, @Mfg, @Good, 0, @Loc, 1);
DECLARE @N   BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-040-N');
DECLARE @Src BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-040-SRC');
INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId) VALUES (@Src, @N, 3, 8, 1);
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth) VALUES (@N, @N, 0), (@Src, @Src, 0), (@Src, @N, 1);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CompletedAt, CreatedByUserId, LotId)
VALUES (@Item, @Cfg, @Loc, @Done, SYSUTCDATETIME(), 1, @N);
DECLARE @CN BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.ContainerTray (ContainerId, TrayPosition, PartsClosedCount, ClosedAt, FinishedGoodLotId, ClosedAtTerminalId)
VALUES (@CN, 1, 4, SYSUTCDATETIME(), NULL, @Loc), (@CN, 2, 4, SYSUTCDATETIME(), NULL, @Loc);
INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId)
VALUES (@CN, N'T118-040-SHIP', (SELECT TOP 1 Id FROM Lots.LabelTypeCode ORDER BY Id));
-- a scale press logged against the container LOT (ScaleEPrintWatcher v2: lotId = container LOT,
-- containerTrayId in the payload)
INSERT INTO Audit.InterfaceLog (LoggedAt, SystemName, Direction, LogEventTypeId, Description, RequestPayload, IsHighFidelity, LocationId, LotId)
VALUES (SYSUTCDATETIME(), N'PLC:T118', N'In', (SELECT Id FROM Audit.LogEventType WHERE Code = N'InterfaceCall'), N'T118 press',
        N'{"v":1,"net":1.0,"verdict":"Ok","containerTrayId":' + CAST((SELECT Id FROM Lots.ContainerTray WHERE ContainerId = @CN AND TrayPosition = 2) AS NVARCHAR(20)) + N'}',
        0, @Loc, @N);
GO

DECLARE @N   BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-040-N');
DECLARE @Src BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'T118-040-SRC');
DECLARE @CN  BIGINT = (SELECT Id FROM Lots.Container WHERE LotId = @N);
DECLARE @Loc BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @CNs NVARCHAR(20) = CAST(@CN AS NVARCHAR(20));
DECLARE @c BIT;

-- GlobalTrace: container id and shipper id resolve to the container LOT
EXEC dbo.T118_Shape N'Lots.GlobalTrace_Resolve';
INSERT INTO ##R118 EXEC Lots.GlobalTrace_Resolve @SearchText = @CNs;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM ##R118 WHERE MatchType = N'Container' AND LotId = @N) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[GlobalTrace] container id -> the container LOT', @Condition = @c;
DELETE FROM ##R118;
INSERT INTO ##R118 EXEC Lots.GlobalTrace_Resolve @SearchText = N'T118-040-SHIP';
SET @c = CASE WHEN EXISTS (SELECT 1 FROM ##R118 WHERE MatchType = N'Shipper' AND LotId = @N) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[GlobalTrace] shipper id -> the container LOT', @Condition = @c;

-- Container trace detail: one source LOT
EXEC dbo.T118_Shape N'Lots.Container_GetTraceDetail';
INSERT INTO ##R118 EXEC Lots.Container_GetTraceDetail @ContainerId = @CN;
SET @c = CASE WHEN (SELECT SourceLotCount FROM ##R118) = 1 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[TraceDetail] SourceLotCount = 1 (the container LOT)', @Condition = @c;

-- Hold associations: the container LOT -> its container
EXEC dbo.T118_Shape N'Quality.Hold_ListAssociatedContainers';
INSERT INTO ##R118 EXEC Quality.Hold_ListAssociatedContainers @LotId = @N;
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 AND (SELECT ContainerId FROM ##R118) = @CN THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Hold] ListAssociatedContainers(container LOT) -> its container', @Condition = @c;

-- Shipped containers reached from the source LOT: quantity = the container's tray sum
EXEC dbo.T118_Shape N'Lots.Lot_GetShippedContainers';
INSERT INTO ##R118 EXEC Lots.Lot_GetShippedContainers @LotId = @Src;
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 AND (SELECT ContainerId FROM ##R118) = @CN AND (SELECT Quantity FROM ##R118) = 8 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Shipped] source LOT -> one container row, Quantity = 8', @Condition = @c;

-- Linked container: the container, tray fields NULL, TrayCount 2
EXEC dbo.T118_Shape N'Lots.Lot_GetLinkedContainer';
INSERT INTO ##R118 EXEC Lots.Lot_GetLinkedContainer @LotId = @N;
SET @c = CASE WHEN (SELECT COUNT(*) FROM ##R118) = 1 AND (SELECT ContainerId FROM ##R118) = @CN THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Linked] container LOT -> its container (one row)', @Condition = @c;
SET @c = CASE WHEN COL_LENGTH('tempdb..##R118', 'TrayCount') IS NOT NULL THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Linked] result carries TrayCount', @Condition = @c;
IF @c = 1
BEGIN
    SET @c = CASE WHEN EXISTS (SELECT 1 FROM ##R118 WHERE ContainerTrayId IS NULL AND TrayPosition IS NULL) THEN 1 ELSE 0 END;
    EXEC test.Assert_IsTrue @TestName = N'[Linked] tray fields NULL for a container LOT', @Condition = @c;
    DECLARE @tc INT;
    EXEC sp_executesql N'SELECT @tc = TrayCount FROM ##R118', N'@tc INT OUTPUT', @tc = @tc OUTPUT;
    SET @c = CASE WHEN @tc = 2 THEN 1 ELSE 0 END;
    EXEC test.Assert_IsTrue @TestName = N'[Linked] TrayCount = 2', @Condition = @c;
END

-- Press log: the press logged against the container LOT resolves to tray 2 via the payload
EXEC dbo.T118_Shape N'Workorder.ScaleStation_GetPressLog';
INSERT INTO ##R118 EXEC Workorder.ScaleStation_GetPressLog @TerminalLocationId = @Loc;
SET @c = CASE WHEN EXISTS (SELECT 1 FROM ##R118 WHERE LotId = @N AND ContainerId = @CN AND TrayPosition = 2) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[PressLog] container-LOT press -> container + tray 2 (payload containerTrayId)', @Condition = @c;

-- Hold release on the container LOT while the container is Complete closes it
DECLARE @HP TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @HP EXEC Quality.Hold_Place @LotId = @N, @HoldTypeCodeId = 1, @Reason = N'0119 040 hold', @AppUserId = 1;
DECLARE @He BIGINT = (SELECT NewId FROM @HP);
DECLARE @RL TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @RL EXEC Quality.Hold_Release @HoldEventId = @He, @ReleaseRemarks = N'released', @AppUserId = 1;
SET @c = CASE WHEN (SELECT Status FROM @RL) = 1
               AND EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId WHERE l.Id = @N AND sc.Code = N'Closed')
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Hold] release of the container LOT closes it (container Complete)', @Condition = @c;

DROP TABLE IF EXISTS ##R118;
GO
DROP PROCEDURE IF EXISTS dbo.T118_Shape;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
