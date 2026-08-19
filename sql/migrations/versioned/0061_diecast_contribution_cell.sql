-- =============================================
-- Migration:   0061_diecast_contribution_cell.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-08-19
-- Description: Shift-override ATTRIBUTION, sec 5 / OI-2 (RESOLVED 2026-08-19 by
--              Hunter, option 2). Spec:
--              docs/superpowers/specs/2026-08-19-shift-override-attribution-design.md
--
--              PROBLEM. A per-equipment shift override is keyed to a PRESS
--              (Location.Location, design D5). Workorder.DieCastContribution
--              stores TerminalLocationId -- the entry terminal -- not the press.
--              The supervisor dashboard derives the press historically:
--                contribution -> Lots.Lot.ToolId (stamped at basket creation,
--                immutable) -> the Tools.ToolAssignment active at EventAt
--                -> CellLocationId.
--              That derivation is correct but LIVE: moving a die to another
--              press months later silently changes which override applies to a
--              past contribution, and therefore silently changes which shift a
--              past basket counted against.
--
--              FIX. Stamp the press onto the ledger row at WRITE time. The
--              attribution restamp (Oee.ShiftOverride_Restamp) then keys on a
--              plain equality instead of re-deriving through assignment history,
--              and a later die move cannot rewrite settled attribution.
--
--              NULLable, not NOT NULL:
--                * retrofitted onto existing rows, and a row whose die had NO
--                  active assignment at EventAt has no honest answer -- it stays
--                  NULL and is EXCLUDED from equipment-scoped restamps rather
--                  than being guessed at (spec sec 5, final paragraph);
--                * the writers accept it as an optional parameter and fall back
--                  to the live assignment, so an older caller still records.
--
--              BACKFILL uses the same OUTER APPLY TOP 1 derivation the
--              supervisor dashboard uses (R__Workorder_DieCastSupervisor_
--              GetShiftTotals.sql), so backfilled rows agree with every figure
--              that dashboard has ever shown. Backfilled values are the best
--              available reading of history, not a guarantee.
--
--              Also seeds the Audit.LogEventType the restamp writes under.
--              Audit.LogEntityType 'ShiftOverride' already exists (0059).
--
--              Idempotent-guarded; no explicit transaction (repo convention).
-- =============================================

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0061_diecast_contribution_cell')
BEGIN PRINT 'Migration 0061 already applied -- skipping.'; RETURN; END
GO

-- ---- 1. Column + FK ----
IF COL_LENGTH(N'Workorder.DieCastContribution', N'CellLocationId') IS NULL
BEGIN
    ALTER TABLE Workorder.DieCastContribution ADD CellLocationId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_DieCastContribution_CellLocation')
BEGIN
    ALTER TABLE Workorder.DieCastContribution
        ADD CONSTRAINT FK_DieCastContribution_CellLocation
        FOREIGN KEY (CellLocationId) REFERENCES Location.Location(Id);
END
GO

-- The restamp scans (press, EventAt window); the supervisor dashboard scans
-- (press, shift). Filtered so the NULL backfill remainder costs nothing.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_DieCastContribution_Cell'
                 AND object_id = OBJECT_ID(N'Workorder.DieCastContribution'))
BEGIN
    CREATE INDEX IX_DieCastContribution_Cell
        ON Workorder.DieCastContribution (CellLocationId, EventAt)
        INCLUDE (ShiftId, LotId)
        WHERE CellLocationId IS NOT NULL;
END
GO

-- ---- 2. Backfill: Lot.ToolId -> the ToolAssignment active AT EventAt ----
-- Mirrors R__Workorder_DieCastSupervisor_GetShiftTotals.sql's press derivation
-- verbatim (OUTER APPLY TOP 1, AssignedAt <= EventAt < ReleasedAt), so history
-- reads the same way it always has. Rows whose die had no active assignment at
-- EventAt keep CellLocationId NULL -- deliberately not guessed.
UPDATE c
SET    c.CellLocationId = ta.CellLocationId
FROM   Workorder.DieCastContribution c
INNER JOIN Lots.Lot l ON l.Id = c.LotId
OUTER APPLY (
    SELECT TOP 1 a.CellLocationId
    FROM   Tools.ToolAssignment a
    WHERE  a.ToolId = l.ToolId
      AND  a.AssignedAt <= c.EventAt
      AND  (a.ReleasedAt IS NULL OR a.ReleasedAt > c.EventAt)
    ORDER BY a.AssignedAt DESC, a.Id DESC
) ta
WHERE  c.CellLocationId IS NULL
  AND  ta.CellLocationId IS NOT NULL;
GO

DECLARE @Filled INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE CellLocationId IS NOT NULL);
DECLARE @Null   INT = (SELECT COUNT(*) FROM Workorder.DieCastContribution WHERE CellLocationId IS NULL);
PRINT 'Migration 0061 backfill: ' + CAST(@Filled AS NVARCHAR(20)) + ' contribution row(s) stamped, '
    + CAST(@Null AS NVARCHAR(20)) + ' left NULL (die had no active assignment at EventAt).';
GO

-- ---- 3. Audit seed: the event type the attribution restamp writes under ----
IF NOT EXISTS (SELECT 1 FROM Audit.LogEventType WHERE Code = N'ShiftAttributionRestamped')
BEGIN
    DECLARE @NextEventId INT = (SELECT ISNULL(MAX(Id), 0) + 1 FROM Audit.LogEventType);
    INSERT INTO Audit.LogEventType (Id, Code, Name, Description)
    VALUES (@NextEventId, N'ShiftAttributionRestamped', N'Shift Attribution Restamped',
            N'A shift override was applied and existing downtime / die-cast contribution rows were re-attributed to a different shift.');
END
GO

-- ---- 4. Record migration ----
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0061_diecast_contribution_cell')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0061_diecast_contribution_cell',
        N'Workorder.DieCastContribution.CellLocationId (BIGINT NULL, FK Location.Location) + filtered index + ToolAssignment-at-EventAt backfill; LogEventType ShiftAttributionRestamped. Shift-override attribution OI-2.');
GO

PRINT 'Migration 0061 (diecast_contribution_cell) applied.';
GO
