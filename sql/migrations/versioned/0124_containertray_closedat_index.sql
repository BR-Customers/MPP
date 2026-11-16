-- ============================================================
-- Migration:   0124_containertray_closedat_index.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-16
-- Description: One index so the scale station's shift tally
--              (Workorder.ScaleStation_GetShiftTally) finds "trays closed this
--              shift" by seeking Lots.ContainerTray on ClosedAt instead of reading
--              every tray ever closed.
--
--   WHY (stored-procedure review, 2026-11-16). The scale station screen polls the
--   tally every 60 s and again on every press. Its tray branch is
--       SELECT COUNT(*), SUM(ct.PartsClosedCount)
--       FROM Lots.ContainerTray ct JOIN Lots.Container c ON c.Id = ct.ContainerId
--       WHERE c.StationLocationId = @T AND ct.ClosedAt >= @From AND ct.ClosedAt < @To;
--   Nothing indexes ContainerTray.ClosedAt, so the only way in is every tray of every
--   box (main: a parallel scan of the whole tray table; with the container-as-LOT
--   branch's IX_Container_Station / IX_ContainerTray_Container: a full scan of the
--   latter). Both grow with every tray ever closed. Measured at a year of boxes at six
--   stations (500k trays): 4,719 tray reads on main, 3,550 with 0119's indexes;
--   with this index and the proc's OPTIMIZE FOR hint (ScaleStation_GetShiftTally
--   v1.2), 3-4 tray reads (a seek of the shift's trays) on both.
--
--   KEY (ClosedAt) INCLUDE (ContainerId, PartsClosedCount): covers the tray branch.
--   ClosedAt is set once at close; PartsClosedCount is rewritten only by container
--   rework (MovePieces / Scrap), which is rare, so the INCLUDE costs almost nothing.
--   Not filtered: the tally's range predicate would match an IS NOT NULL filter, but
--   nearly every tray row carries ClosedAt, so a filter saves nothing.
--
--   Offline build on Standard edition (tray-close writes wait while it builds:
--   seconds at the current row count). No proc or result-set change from this file;
--   the proc's OPTIMIZE FOR hint is in R__Workorder_ScaleStation_GetShiftTally.sql
--   (v1.2), needed because the shift window is in local variables: without it the
--   optimiser guesses 9% of all trays and can keep the full scan (it did once
--   0119's IX_Container_Station existed).
--
--   NUMBERING. 0119 is the container-as-LOT branch; 0120-0123 / 0125 / 0127 are other
--   review PRs. This depends only on Lots.ContainerTray (0028), not on any of them.
--   ASCII only.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'Lots.ContainerTray') AND name = N'IX_ContainerTray_ClosedAt')
    CREATE NONCLUSTERED INDEX IX_ContainerTray_ClosedAt
        ON Lots.ContainerTray (ClosedAt)
        INCLUDE (ContainerId, PartsClosedCount);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0124_containertray_closedat_index')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0124_containertray_closedat_index',
            N'Lots.ContainerTray += IX_ContainerTray_ClosedAt (ClosedAt) INCLUDE (ContainerId, PartsClosedCount) for the scale station shift tally (stored-procedure review 2026-11-16). Pairs with ScaleStation_GetShiftTally v1.2 (OPTIMIZE FOR a one-shift window).');
GO
