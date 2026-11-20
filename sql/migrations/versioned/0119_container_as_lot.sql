-- ============================================================
-- Migration:   0119_container_as_lot.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-04 (as 0118; renumbered 0119 on 2026-11-16 -- prod's 0118 is
--              0118_lot_open_lot_indexes, the 2026-11-10 incident fix)
-- Description: Container-as-LOT (spec
--              docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md
--              sec 5, D1, D2, D5, D11).
--                1. Lots.Container += LotId (FK Lots.Lot). One finished-good LOT
--                   per container, minted by Workorder.Assembly_CompleteTray on
--                   the first accepted tray. NULL on every container from before
--                   this migration (their LOTs hang off the trays,
--                   ContainerTray.FinishedGoodLotId) and on a container opened
--                   before its first tray. Filtered unique: one container per LOT.
--                2. Lots.ContainerTray += ShiftId (FK Oee.Shift),
--                   ClosedAtTerminalId (FK Location.Location), MintedPieceCount.
--                   Stamped ONCE by Assembly_CompleteTray at tray close and never
--                   changed: OEE good is the trays a shift ran through the camera
--                   (D5), read from the fixed count (D11) because repack scrap /
--                   moves lower PartsClosedCount afterwards. Rework-move trays
--                   leave all three NULL so they never count as production.
--                3. IX_Lot_LocationItemCreated for the FIFO stock pick (see 3 below).
--                4. IX_Container_CompletedAt; IX_ShippingLabel_Container widened (see 4 below).
--                5. IX_ContainerTray_Container covers the per-container tray sum (see 5 below).
--                6. IX_Container_Station; 7. filtered IX_Lot_CrtActive (see below).
--   NOT here (2026-11-16 split): the Lots.Lot clustered (CreatedAt, Id) index (its own
--   change) and IX_Lot_LocationStatus / IX_Lot_ItemStatus -- "open LOTs at a location /
--   of a part" is served by 0118's filtered IX_Lot_NotClosed_Location / _Item.
--   Existing data is not rewritten (D8: readers handle both shapes).
--   ASCII only.
-- ============================================================

-- 1. Lots.Container.LotId
IF COL_LENGTH(N'Lots.Container', N'LotId') IS NULL
    ALTER TABLE Lots.Container ADD
        LotId BIGINT NULL CONSTRAINT FK_Container_Lot REFERENCES Lots.Lot(Id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND name = N'UX_Container_LotId')
    CREATE UNIQUE INDEX UX_Container_LotId
        ON Lots.Container (LotId)
        WHERE LotId IS NOT NULL;
GO

-- 2. Lots.ContainerTray stamps
IF COL_LENGTH(N'Lots.ContainerTray', N'ShiftId') IS NULL
    ALTER TABLE Lots.ContainerTray ADD
        ShiftId BIGINT NULL CONSTRAINT FK_ContainerTray_Shift REFERENCES Oee.Shift(Id);
GO
IF COL_LENGTH(N'Lots.ContainerTray', N'ClosedAtTerminalId') IS NULL
    ALTER TABLE Lots.ContainerTray ADD
        ClosedAtTerminalId BIGINT NULL CONSTRAINT FK_ContainerTray_ClosedAtTerminal REFERENCES Location.Location(Id);
GO
IF COL_LENGTH(N'Lots.ContainerTray', N'MintedPieceCount') IS NULL
    ALTER TABLE Lots.ContainerTray ADD MintedPieceCount INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_ShiftId')
    CREATE INDEX IX_ContainerTray_ShiftId
        ON Lots.ContainerTray (ShiftId)
        INCLUDE (MintedPieceCount, ClosedAtTerminalId, ContainerId)
        WHERE ShiftId IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_ClosedAt')
    -- 2026-11-20 release merge: INCLUDE also carries PartsClosedCount, so this one index serves
    -- both the super-lot time windows (here) and the scale station shift tally that migration
    -- 0124 (stored-procedure review) wanted under the SAME name; 0124 then finds it and skips.
    CREATE INDEX IX_ContainerTray_ClosedAt
        ON Lots.ContainerTray (ClosedAt)
        INCLUDE (ContainerId, ClosedAtTerminalId, PartsClosedCount);
GO

-- 3. The FIFO stock pick (Assembly_CompleteTray, MachiningOut_Mint, ...: "oldest usable
--    LOT of this part at this line", TOP 1 ORDER BY CreatedAt, Id) must SEEK, not read
--    every LOT the line ever held (benchmark 2026-11-04: 105K pages per tray at a year
--    of volume when it did not).
--    Filtered to LOTs that still hold stock: a drained LOT keeps its CurrentLocationId at
--    the line, so an unfiltered (location, item, age) seek would still read through every
--    historical drained LOT of that part before reaching live stock (review I2). Every
--    stock read that should use it states the filter literally (InventoryAvailable > 0).
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_LocationItemCreated' AND has_filter = 0)
    DROP INDEX IX_Lot_LocationItemCreated ON Lots.Lot;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_LocationItemCreated')
    CREATE INDEX IX_Lot_LocationItemCreated
        ON Lots.Lot (CurrentLocationId, ItemId, CreatedAt, Id)
        INCLUDE (LotStatusId, InventoryAvailable, PieceCount, LotOriginTypeId)
        WHERE InventoryAvailable > 0;
GO

-- 4. Completed / shipped container lists read a CompletedAt window (Container had no index
--    on it: a 30-day shipped list scanned every container), and each row's live label
--    (IsVoid = 0, newest) -- the label index now covers that lookup.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND name = N'IX_Container_CompletedAt')
    CREATE INDEX IX_Container_CompletedAt ON Lots.Container (CompletedAt)
        INCLUDE (ContainerStatusCodeId, ItemId, CurrentLocationId, OpenedAt, LotId)
        WHERE CompletedAt IS NOT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
           WHERE i.object_id = OBJECT_ID(N'Lots.ShippingLabel') AND i.name = N'IX_ShippingLabel_Container'
           GROUP BY i.index_id HAVING MAX(ic.key_ordinal) = 1)
    DROP INDEX IX_ShippingLabel_Container ON Lots.ShippingLabel;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ShippingLabel') AND name = N'IX_ShippingLabel_Container')
    CREATE INDEX IX_ShippingLabel_Container ON Lots.ShippingLabel (ContainerId, IsVoid, CreatedAt, Id)
        INCLUDE (AimShipperId, PrintedAt, LastPrintErrorCondition);
GO

-- 5. "Pieces in a container" is SUM(ContainerTray.PartsClosedCount) in every container
--    reader (spec 6). The unique (ContainerId, TrayPosition) key served the seek but every
--    tray then cost a key lookup; this covers the sum and the shape tests.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_Container')
    CREATE INDEX IX_ContainerTray_Container ON Lots.ContainerTray (ContainerId)
        INCLUDE (TrayPosition, PartsClosedCount, FinishedGoodLotId, ClosedAt, MintedPieceCount, ShiftId);
GO

-- 6. A scale / assembly station's boxes (shift tally, recent boxes) are read by
--    StationLocationId, which had no index: every call scanned all containers.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Container') AND name = N'IX_Container_Station')
    CREATE INDEX IX_Container_Station ON Lots.Container (StationLocationId, CompletedAt)
        INCLUDE (ContainerStatusCodeId, ItemId, CurrentLocationId)
        WHERE StationLocationId IS NOT NULL;
GO
-- 7. CRT-tagged LOTs are few; the pending-validation backlog starts from them.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'Lots.Lot') AND name = N'IX_Lot_CrtActive')
    CREATE INDEX IX_Lot_CrtActive ON Lots.Lot (ItemId) INCLUDE (CurrentLocationId, LotStatusId)
        WHERE CrtActive = 1;
GO

IF COL_LENGTH(N'Lots.Container', N'LotId') IS NULL
   OR COL_LENGTH(N'Lots.ContainerTray', N'MintedPieceCount') IS NULL
    THROW 51000, 'Migration 0119: Container.LotId or ContainerTray stamps did not land.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0119_container_as_lot')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0119_container_as_lot',
            N'Container-as-LOT: Lots.Container += LotId; Lots.ContainerTray += ShiftId/ClosedAtTerminalId/MintedPieceCount.');
GO
PRINT 'Migration 0119 (container_as_lot) applied.';
GO
