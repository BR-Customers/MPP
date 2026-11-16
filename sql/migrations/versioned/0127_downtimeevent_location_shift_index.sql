-- ============================================================
-- Migration:   0127_downtimeevent_location_shift_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-16
-- Description: One narrow index so Oee.DowntimeEvent_GetByScope (v1.2) reads a
--              scope's downtime events by seek instead of scanning the whole
--              Oee.DowntimeEvent table.
--
--   WHY (stored-procedure review, 2026-11-16). The shop-floor header
--   (Views/ShopFloor/AppHeaderLarge, docked on every shop-floor page) polls
--   BlueRidge.Oee.Downtime.getByScope(scope, True, None) every 30 s per session
--   to count open downtime. The table's only indexes were the clustered PK, the
--   filtered UX_DowntimeEvent_OneOpenPerLocation (LocationId) WHERE EndedAt IS
--   NULL, and IX_DowntimeEvent_Shift (ShiftId, StartedAt). Nothing keyed
--   LocationId for closed events, so every call scanned the full table, which
--   grows with every downtime event ever recorded.
--
--   Keyed (LocationId, ShiftId): v1.2 of the proc seeks it once per scope
--   location for "this shift's events", and on LocationId alone for the
--   no-shift fallback. Open events keep using the filtered unique index.
--   DELIBERATELY NO INCLUDE COLUMNS: a scope/shift returns tens of rows, so the
--   row lookups for the output columns are cheap, and EndedAt / DurationMinutes
--   / reason are rewritten when an event ends or is edited. LocationId and
--   ShiftId are written at insert, so the index is maintained on inserts only
--   (plus the rare time edit that re-stamps ShiftId). Offline build on Standard
--   edition (downtime writes wait while it builds: well under a second at
--   ~260k rows). No result-set change. ASCII only.
--
--   NUMBERING. 0119 = container-as-LOT branch, 0120-0126 used or reserved by
--   other review PRs, so this is 0127. It depends only on Oee.DowntimeEvent
--   (0026); renumber if the PRs land in another order.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Oee.DowntimeEvent') AND name = N'IX_DowntimeEvent_Location_Shift')
    CREATE NONCLUSTERED INDEX IX_DowntimeEvent_Location_Shift
        ON Oee.DowntimeEvent (LocationId, ShiftId);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0127_downtimeevent_location_shift_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0127_downtimeevent_location_shift_index',
            N'Oee.DowntimeEvent += IX_DowntimeEvent_Location_Shift (LocationId, ShiftId; no INCLUDE) for the 30 s shop-floor downtime read Oee.DowntimeEvent_GetByScope v1.2 (stored-procedure review 2026-11-16).');
GO
