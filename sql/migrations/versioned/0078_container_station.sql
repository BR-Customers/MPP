-- ============================================================
-- Migration:   0078_container_station.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-11
-- Description: An open container belongs to the STATION (terminal) filling it,
--              not just to the line.
--
--              WHY. Lots.Container has been keyed by (CurrentLocationId = the
--              line, ItemId). That is one open box per part per LINE. The 6MA
--              cam-holder line carries three assembly-out terminals -- METTs A,
--              METTs B (both ByCount, each with its own printer) and the vision
--              cell -- and METTs A and B run the SAME part numbers at the same
--              time into physically separate boxes. Keyed by line, both
--              terminals' trays of 12231-6MAA-J000 landed in one logical
--              container, so one AIM serial and one label covered parts from
--              two boxes. Each terminal also needs several part boxes open at
--              once while the operator switches parts.
--
--              WHAT. Lots.Container.StationLocationId BIGINT NULL, FK to
--              Location.Location: the terminal that owns the box.
--                * Workorder.Assembly_CompleteTray (v1.4) finds the open box for
--                  (line, part, station); failing that it CLAIMS an unowned open
--                  box for (line, part) -- stamps its station -- so a box opened
--                  before this migration is never stranded; failing that it
--                  opens a new one owned by the station.
--                * NULL means "not owned by a station": every container that
--                  exists today, and any caller that does not pass a terminal.
--                  Those callers keep the pre-0078 line-wide behaviour.
--
--              Index: open-box lookups filter on (CurrentLocationId, ItemId,
--              StationLocationId) among OPEN rows only -- filtered on
--              ContainerStatusCodeId = 1 (Open), a fixed-seed code (0028).
--
--              No backfill: existing containers stay NULL (unowned) and are
--              claimed on their next tray.
--
--              Idempotent-guarded; no explicit transaction (repo convention,
--              see 0067). ASCII-only.
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0078_container_station')
BEGIN
    PRINT 'Migration 0078 already applied -- skipping.';
    RETURN;
END
GO

-- ============================================================
-- 1. Column + FK
-- ============================================================
IF COL_LENGTH('Lots.Container', 'StationLocationId') IS NULL
    ALTER TABLE Lots.Container ADD StationLocationId BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Container_Station')
    ALTER TABLE Lots.Container
        ADD CONSTRAINT FK_Container_Station FOREIGN KEY (StationLocationId) REFERENCES Location.Location(Id);
GO

-- ============================================================
-- 2. Open-box lookup index (filtered to Open = 1, fixed seed)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Container_OpenByCellItemStation'
                                           AND object_id = OBJECT_ID(N'Lots.Container'))
    CREATE NONCLUSTERED INDEX IX_Container_OpenByCellItemStation
        ON Lots.Container (CurrentLocationId, ItemId, StationLocationId)
        INCLUDE (OpenedAt, ContainerConfigId)
        WHERE ContainerStatusCodeId = 1;
GO

-- ============================================================
-- == Record migration ========================================
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0078_container_station')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (
        N'0078_container_station',
        N'Lots.Container.StationLocationId BIGINT NULL FK Location.Location: the terminal that owns an open box. Assembly_CompleteTray scopes the open box to (line, part, station) and claims unowned open boxes; NULL = line-wide (all pre-0078 rows and any caller without a terminal). Filtered index IX_Container_OpenByCellItemStation on open rows.'
    );
GO

PRINT 'Migration 0078 completed: Lots.Container.StationLocationId.';
GO
