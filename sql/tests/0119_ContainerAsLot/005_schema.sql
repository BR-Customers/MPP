-- =============================================
-- File:         0119_ContainerAsLot/005_schema.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-11-04
-- Description:  Migration 0119 (container-as-LOT spec sec 5): Container.LotId
--               (+ filtered unique), ContainerTray.ShiftId / ClosedAtTerminalId /
--               MintedPieceCount, and the container / tray / stock-pick indexes.
--               (The Lots.Lot clustered index moved to its own change 2026-11-16.)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0119_ContainerAsLot/005_schema.sql';
GO

DECLARE @c BIT;

SET @c = CASE WHEN EXISTS (
    SELECT 1 FROM sys.foreign_key_columns fkc
    WHERE fkc.parent_object_id = OBJECT_ID(N'Lots.Container')
      AND COL_NAME(fkc.parent_object_id, fkc.parent_column_id) = N'LotId'
      AND fkc.referenced_object_id = OBJECT_ID(N'Lots.Lot')) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] Container.LotId exists and FKs Lots.Lot', @Condition = @c;

SET @c = CASE WHEN EXISTS (
    SELECT 1 FROM sys.foreign_key_columns fkc
    WHERE fkc.parent_object_id = OBJECT_ID(N'Lots.ContainerTray')
      AND COL_NAME(fkc.parent_object_id, fkc.parent_column_id) = N'ShiftId'
      AND fkc.referenced_object_id = OBJECT_ID(N'Oee.Shift')) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] ContainerTray.ShiftId exists and FKs Oee.Shift', @Condition = @c;

SET @c = CASE WHEN EXISTS (
    SELECT 1 FROM sys.foreign_key_columns fkc
    WHERE fkc.parent_object_id = OBJECT_ID(N'Lots.ContainerTray')
      AND COL_NAME(fkc.parent_object_id, fkc.parent_column_id) = N'ClosedAtTerminalId'
      AND fkc.referenced_object_id = OBJECT_ID(N'Location.Location')) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] ContainerTray.ClosedAtTerminalId exists and FKs Location', @Condition = @c;

SET @c = CASE WHEN COL_LENGTH(N'Lots.ContainerTray', N'MintedPieceCount') IS NOT NULL THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] ContainerTray.MintedPieceCount exists', @Condition = @c;

SET @c = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_ShiftId' AND has_filter = 1)
              AND EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_ClosedAt')
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] ContainerTray ShiftId (filtered) + ClosedAt indexes exist', @Condition = @c;

-- The FIFO stock pick (TOP 1 ... ORDER BY CreatedAt, Id at a line) seeks a
-- (location, item, age) index filtered to LOTs that still hold stock.
SET @c = CASE WHEN (
    SELECT STRING_AGG(COL_NAME(ic.object_id, ic.column_id), N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
    FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    WHERE i.object_id = OBJECT_ID(N'Lots.Lot') AND i.name = N'IX_Lot_LocationItemCreated' AND ic.key_ordinal > 0) = N'CurrentLocationId,ItemId,CreatedAt,Id'
    THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] IX_Lot_LocationItemCreated (CurrentLocationId, ItemId, CreatedAt, Id) for the FIFO stock pick', @Condition = @c;

-- Shipped / completed container reads seek CompletedAt; the live label per container is covered.
SET @c = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND name = N'IX_Container_CompletedAt')
              AND EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                          WHERE i.object_id = OBJECT_ID(N'Lots.ShippingLabel') AND i.name = N'IX_ShippingLabel_Container'
                            AND ic.key_ordinal = 2 AND COL_NAME(ic.object_id, ic.column_id) = N'IsVoid')
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] IX_Container_CompletedAt + IX_ShippingLabel_Container (ContainerId, IsVoid, ...)', @Condition = @c;

SET @c = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_Container') THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] IX_ContainerTray_Container covers the per-container tray sum', @Condition = @c;

-- A station's boxes, and the (rare) CRT-tagged LOTs, are seekable.
SET @c = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND name = N'IX_Container_Station')
              AND EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_CrtActive' AND has_filter = 1)
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] IX_Container_Station + filtered IX_Lot_CrtActive', @Condition = @c;

SET @c = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND is_primary_key = 1 AND type = 2)
         THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] PK_Lot stays NONCLUSTERED', @Condition = @c;
GO

-- UX_Container_LotId: two NULLs allowed, duplicate non-NULL rejected.
DECLARE @c BIT, @err INT = 0;
DECLARE @ItemId BIGINT = (SELECT TOP 1 ItemId FROM Parts.ContainerConfig WHERE DeprecatedAt IS NULL ORDER BY Id);
DECLARE @CfgId  BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @ItemId AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @LocId  BIGINT = (SELECT TOP 1 Id FROM Location.Location ORDER BY Id);
DECLARE @Good   BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg    BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId)
VALUES (N'TEST0119-005-L1', @ItemId, @Mfg, @Good, 4, @LocId, 1);
DECLARE @LotId BIGINT = SCOPE_IDENTITY();

INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId) VALUES (@ItemId, @CfgId, @LocId, 1);
DECLARE @C1 BIGINT = SCOPE_IDENTITY();
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, CreatedByUserId) VALUES (@ItemId, @CfgId, @LocId, 1);
DECLARE @C2 BIGINT = SCOPE_IDENTITY();
SET @c = CASE WHEN (SELECT COUNT(*) FROM Lots.Container WHERE Id IN (@C1, @C2) AND LotId IS NULL) = 2 THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] two containers with NULL LotId allowed', @Condition = @c;

UPDATE Lots.Container SET LotId = @LotId WHERE Id = @C1;
BEGIN TRY
    UPDATE Lots.Container SET LotId = @LotId WHERE Id = @C2;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH;
SET @c = CASE WHEN @err IN (2601, 2627) THEN 1 ELSE 0 END;
EXEC test.Assert_IsTrue @TestName = N'[Schema] UX_Container_LotId rejects a second container on the same LOT', @Condition = @c;

DELETE FROM Lots.Container WHERE Id IN (@C1, @C2);
DELETE FROM Lots.Lot WHERE Id = @LotId;
GO

EXEC test.PrintSummary;
EXEC test.EndTestFile;
GO
