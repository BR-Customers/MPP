-- ============================================================
-- 2026-09-29_reconcile_replay_extract.sql
--
-- READ-ONLY. SELECTs only; the working sets are table variables. No writes to
-- any table, no transaction, no temp tables, no procedure calls. Safe against
-- MPP_MES_Prod during production. Run-ReconcileReplayExtract.ps1 refuses to
-- run this file if a write keyword ever appears in it.
--
-- PURPOSE
--   Pull everything needed to REBUILD one press x die x shift-window as a SQL
--   test fixture, so the die cast shift reconciliation can be replayed against
--   real production rows instead of invented ones.
--
--   The existing evidence export (2026-09-21_diecast_on_record_window.sql,
--   sets A-I) reports what is ON RECORD. It is a summary, and it deliberately
--   carries no Workorder.ProductionEvent, Lots.LotMovement,
--   Lots.LotStatusHistory, Lots.LotAttributeChange or Lots.LotGenealogy rows.
--   Those five tables are exactly what Lots.ufn_DieCastLotCountLock reads to
--   decide whether a LOT's count is settled downstream -- which is the
--   assertion the Machine 11 replay turns on ("the eight LOTs already past
--   trim unchanged at 4,926"). Rebuilding a fixture without them means
--   INVENTING the Trim OUT rows that decide the answer, and then measuring
--   the invention. This script closes that gap and nothing else.
--
-- THE ONE NON-OBVIOUS SCOPE RULE
--   The LOT SET is resolved from the window. Every CHILD row of those LOTs is
--   then pulled WITH NO DATE BOUND AT ALL. This is deliberate: a basket cast
--   on 09-17 is trimmed days later, so the ProductionEvent that locks its
--   count falls OUTSIDE the window. Bounding the children by the same window
--   would drop precisely the rows the replay exists to test, and the fixture
--   would then assert "unchanged" for a reason that is not the real one.
--
-- TARGET SCHEMA: migration 0095 (prod's high-water mark as of 2026-09-18).
--   It references NO column added by 0096-0099 --
--     0096 Workorder.ProductionEvent.ShiftId
--     0097 RejectEvent.ApprovedByUserId / .ReconciliationId,
--          DieCastContribution.ReconciliationId,
--          DieCastCounterAnchor.ReconciliationId
--     0099 DieCastContribution.ShiftAttributionSourceId
--   Result set B probes for them and reports which exist, so the same file
--   runs unchanged against a database that has moved past 0095. It does not
--   SELECT them: a fixture describes the state BEFORE a reconciliation, and
--   those columns are all reconciliation bookkeeping.
--
-- TIME: every *Et column is Eastern wall clock. Oee.Shift.ActualStart/End are
--   ALREADY Eastern (the project's documented UTC exception, OI-38) and are
--   emitted raw; every other timestamp is UTC in the table and converted here.
--   Raw UTC is emitted ALONGSIDE the ET value wherever a fixture has to
--   reproduce the stored value exactly -- a fixture built from a converted
--   timestamp is off by the offset and every window test then lies.
--
-- OUTPUT: one CSV per result set. Send the whole folder back zipped, together
--   with a photo or scan of the paper press sheet for the same shifts.
-- ============================================================
SET NOCOUNT ON;

-- ---------- parameters (Run-ReconcileReplayExtract.ps1 rewrites these lines) ----------
DECLARE @PressCode  NVARCHAR(100) = N'DC1-M11';      -- PRESS_CODE
DECLARE @DieCode    NVARCHAR(100) = N'DMO125';       -- DIE_CODE  (N'' = every die on the press)
DECLARE @FromEtDate DATE          = '2026-09-16';    -- FROM_ET_DATE (inclusive)
DECLARE @ToEtDate   DATE          = '2026-09-19';    -- TO_ET_DATE   (inclusive)

DECLARE @FromEt DATETIME2(3) = CAST(@FromEtDate AS DATETIME2(3));
DECLARE @ToEt   DATETIME2(3) = DATEADD(DAY, 1, CAST(@ToEtDate AS DATETIME2(3)));

-- ---------- resolve the press and the die ----------
DECLARE @PressId BIGINT =
    (SELECT TOP 1 l.Id
     FROM Location.Location l
     INNER JOIN Location.LocationTypeDefinition d ON d.Id = l.LocationTypeDefinitionId
     WHERE d.Name = N'Die Cast Machine' AND l.Code = @PressCode);

DECLARE @Die TABLE (Id BIGINT PRIMARY KEY, Code NVARCHAR(100));
INSERT @Die (Id, Code)
SELECT t.Id, t.Code
FROM Tools.Tool t
WHERE (@DieCode = N'' OR t.Code = @DieCode)
  AND EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
              WHERE ta.ToolId = t.Id AND ta.CellLocationId = @PressId);

-- ---------- the LOT set: die cast baskets on those dies inside the window ----------
-- Resolved from the window. Their child rows below are NOT window-bounded.
DECLARE @Lot TABLE (Id BIGINT PRIMARY KEY);
INSERT @Lot (Id)
SELECT l.Id
FROM Lots.Lot l
INNER JOIN @Die d ON d.Id = l.ToolId
WHERE l.ToolCavityId IS NOT NULL
  AND (   CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
              >= @FromEt
          AND CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
              < @ToEt
       OR EXISTS (SELECT 1 FROM Workorder.DieCastContribution c
                  WHERE c.LotId = l.Id
                    AND CAST(c.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                        >= @FromEt
                    AND CAST(c.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                        < @ToEt)
       OR EXISTS (SELECT 1 FROM Workorder.RejectEvent r
                  WHERE r.LotId = l.Id
                    AND CAST(r.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                        >= @FromEt
                    AND CAST(r.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))
                        < @ToEt));

-- ---------- the shift set: every instance overlapping the window ----------
DECLARE @Shift TABLE (Id BIGINT PRIMARY KEY);
INSERT @Shift (Id)
SELECT s.Id
FROM Oee.Shift s
WHERE s.ActualStart < @ToEt
  AND ISNULL(s.ActualEnd, '9999-12-31') > @FromEt;


-- ============================================================
-- A. Scope -- what actually resolved. Read this set FIRST.
-- ============================================================
SELECT N'A Scope' AS [Set],
       DB_NAME()                                        AS DatabaseName,
       @PressCode                                       AS PressCode,
       @PressId                                         AS PressId,
       CASE WHEN @PressId IS NULL THEN N'PRESS NOT FOUND -- check the code'
            ELSE N'ok' END                              AS PressResolved,
       CASE WHEN @DieCode = N'' THEN N'(every die on the press)' ELSE @DieCode END AS DieCode,
       (SELECT COUNT(*) FROM @Die)                      AS DiesResolved,
       @FromEtDate                                      AS FromEtDate,
       @ToEtDate                                        AS ToEtDate,
       (SELECT COUNT(*) FROM @Shift)                    AS ShiftsInWindow,
       (SELECT COUNT(*) FROM @Lot)                      AS LotsInScope,
       (SELECT MAX(sv.Id) FROM dbo.SchemaVersion sv)    AS SchemaVersionMaxId,
       (SELECT TOP 1 sv.MigrationId FROM dbo.SchemaVersion sv ORDER BY sv.Id DESC) AS SchemaVersionLatest;

-- ============================================================
-- B. Capability -- which post-0095 columns this database has.
--    Nothing below SELECTs them; this set exists so the fixture author knows
--    which migration level produced the export.
-- ============================================================
SELECT N'B Capability' AS [Set], N'Workorder.ProductionEvent.ShiftId' AS ColumnName,
       CASE WHEN COL_LENGTH('Workorder.ProductionEvent','ShiftId') IS NULL THEN 0 ELSE 1 END AS Present,
       N'0096' AS AddedBy
UNION ALL SELECT N'B Capability', N'Workorder.RejectEvent.ApprovedByUserId',
       CASE WHEN COL_LENGTH('Workorder.RejectEvent','ApprovedByUserId') IS NULL THEN 0 ELSE 1 END, N'0097'
UNION ALL SELECT N'B Capability', N'Workorder.RejectEvent.ReconciliationId',
       CASE WHEN COL_LENGTH('Workorder.RejectEvent','ReconciliationId') IS NULL THEN 0 ELSE 1 END, N'0097'
UNION ALL SELECT N'B Capability', N'Workorder.DieCastContribution.ReconciliationId',
       CASE WHEN COL_LENGTH('Workorder.DieCastContribution','ReconciliationId') IS NULL THEN 0 ELSE 1 END, N'0097'
UNION ALL SELECT N'B Capability', N'Workorder.DieCastContribution.ShiftAttributionSourceId',
       CASE WHEN COL_LENGTH('Workorder.DieCastContribution','ShiftAttributionSourceId') IS NULL THEN 0 ELSE 1 END, N'0099';

-- ============================================================
-- C. Shifts overlapping the window. ActualStart/End are ALREADY Eastern.
-- ============================================================
SELECT N'C Shifts' AS [Set], s.Id AS ShiftId, s.ShiftScheduleId, ss.Name AS Schedule,
       s.ActualStart AS StartEt, s.ActualEnd AS EndEt,
       CASE WHEN s.ActualEnd IS NULL THEN 1 ELSE 0 END AS IsOpen,
       s.Remarks,
       s.CreatedAt AS CreatedAtUtc
FROM Oee.Shift s
INNER JOIN @Shift w            ON w.Id  = s.Id
INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
ORDER BY s.ActualStart;

-- ============================================================
-- D. Shift schedules referenced -- a fixture has to recreate these first.
-- ============================================================
SELECT N'D Schedules' AS [Set], ss.Id AS ShiftScheduleId, ss.Name, ss.Description,
       ss.StartTime, ss.EndTime, ss.DaysOfWeekBitmask, ss.EffectiveFrom,
       ss.DeprecatedAt
FROM Oee.ShiftSchedule ss
WHERE ss.Id IN (SELECT s.ShiftScheduleId FROM Oee.Shift s INNER JOIN @Shift w ON w.Id = s.Id)
ORDER BY ss.Name;

-- ============================================================
-- E. The dies, and how they were mounted on this press.
-- ============================================================
SELECT N'E Dies' AS [Set], t.Id AS ToolId, t.Code AS Die, t.Name AS DieName,
       t.ShotCount, t.ShotLimit
FROM Tools.Tool t
INNER JOIN @Die d ON d.Id = t.Id
ORDER BY t.Code;

SELECT N'F Mounts' AS [Set], ta.Id AS AssignmentId, t.Code AS Die,
       p.Code AS Press,
       ta.AssignedAt AS AssignedAtUtc,
       CAST(ta.AssignedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS AssignedEt,
       ta.ReleasedAt AS ReleasedAtUtc,
       CAST(ta.ReleasedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ReleasedEt
FROM Tools.ToolAssignment ta
INNER JOIN @Die d             ON d.Id = ta.ToolId
INNER JOIN Tools.Tool t       ON t.Id = ta.ToolId
LEFT  JOIN Location.Location p ON p.Id = ta.CellLocationId
ORDER BY t.Code, ta.AssignedAt;

-- ============================================================
-- G. Cavities on those dies -- EVERY cavity, no status filter and no date
--    filter. CreatedAt / DeprecatedAt / status are what the as-of-shift
--    cavity window is computed from, so the fixture needs the raw values.
--    (A16: there is deliberately no CreatedAt LOWER bound in the live rule.)
-- ============================================================
SELECT N'G Cavities' AS [Set], tc.Id AS ToolCavityId, t.Code AS Die,
       tc.CavityCode AS Cavity, tc.ItemId, i.PartNumber, tc.Description,
       cs.Code AS StatusCode, cs.Name AS StatusName,
       tc.CreatedAt   AS CreatedAtUtc,
       tc.UpdatedAt   AS UpdatedAtUtc,
       tc.DeprecatedAt AS DeprecatedAtUtc
FROM Tools.ToolCavity tc
INNER JOIN @Die d                        ON d.Id  = tc.ToolId
INNER JOIN Tools.Tool t                  ON t.Id  = tc.ToolId
LEFT  JOIN Tools.ToolCavityStatusCode cs ON cs.Id = tc.StatusCodeId
LEFT  JOIN Parts.Item i                  ON i.Id  = tc.ItemId
ORDER BY t.Code, i.PartNumber, tc.CavityCode;

-- ============================================================
-- H. The LOTs in scope -- the full stored row, not a summary.
-- ============================================================
SELECT N'H Lots' AS [Set], l.Id AS LotId, l.LotName, l.ItemId, i.PartNumber,
       l.ToolId, t.Code AS Die, l.ToolCavityId, tc.CavityCode AS Cavity,
       l.LotStatusId, sc.Code AS StatusCode, sc.BlocksProduction,
       l.PieceCount, l.InventoryAvailable, l.CastDate,
       l.ProducedAtLocationId, pp.Code AS ProducedAtCode,
       l.CurrentLocationId,    cl.Code AS CurrentLocationCode,
       l.CreatedAtTerminalId,  ct.Code AS CreatedAtTerminalCode,
       l.CreatedByUserId,      cu.Initials AS CreatedByInitials,
       l.CreatedAt AS CreatedAtUtc,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS CreatedEt
FROM Lots.Lot l
INNER JOIN @Lot w                ON w.Id  = l.Id
LEFT  JOIN Parts.Item i          ON i.Id  = l.ItemId
LEFT  JOIN Tools.Tool t          ON t.Id  = l.ToolId
LEFT  JOIN Tools.ToolCavity tc   ON tc.Id = l.ToolCavityId
LEFT  JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
LEFT  JOIN Location.Location pp  ON pp.Id = l.ProducedAtLocationId
LEFT  JOIN Location.Location cl  ON cl.Id = l.CurrentLocationId
LEFT  JOIN Location.Location ct  ON ct.Id = l.CreatedAtTerminalId
LEFT  JOIN Location.AppUser cu   ON cu.Id = l.CreatedByUserId
ORDER BY l.CreatedAt, l.LotName;

-- ============================================================
-- I. Piece credits for those LOTs. NO DATE BOUND -- see the scope rule.
-- ============================================================
SELECT N'I Contributions' AS [Set], c.Id AS ContributionId, c.LotId, l.LotName,
       c.ShiftId, ss.Name AS Schedule, c.CellLocationId, p.Code AS Press,
       c.ToolCavityId, tc.CavityCode AS Cavity,
       c.ShotCounterReading, c.PieceDelta,
       c.VarianceReasonId, vr.Code AS VarianceReason, c.VarianceNote,
       c.AppUserId, u.Initials AS RecordedByInitials,
       c.TerminalLocationId, tl.Code AS TerminalCode,
       c.EventAt AS EventAtUtc,
       CAST(c.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventEt
FROM Workorder.DieCastContribution c
INNER JOIN @Lot w              ON w.Id  = c.LotId
LEFT  JOIN Lots.Lot l          ON l.Id  = c.LotId
LEFT  JOIN Oee.Shift s         ON s.Id  = c.ShiftId
LEFT  JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
LEFT  JOIN Location.Location p ON p.Id  = c.CellLocationId
LEFT  JOIN Tools.ToolCavity tc ON tc.Id = c.ToolCavityId
LEFT  JOIN Workorder.DieCastVarianceReason vr ON vr.Id = c.VarianceReasonId
LEFT  JOIN Location.AppUser u  ON u.Id  = c.AppUserId
LEFT  JOIN Location.Location tl ON tl.Id = c.TerminalLocationId
ORDER BY c.EventAt, c.Id;

-- ============================================================
-- J. Scrap. Two arms, because a die cast reject may be BASKETLESS (LotId NULL,
--    identity stamped on the row since 0084) and would otherwise be missed:
--      arm 1 -- rejects against a LOT in scope
--      arm 2 -- rejects stamped with one of our dies, inside the window
--    Arm 1 is unbounded in time; arm 2 must be windowed because it has no LOT
--    to anchor it.
-- ============================================================
SELECT N'J Rejects' AS [Set], r.Id AS RejectId, r.LotId, l.LotName,
       r.ShiftId, ss.Name AS Schedule, r.CellLocationId, p.Code AS Press,
       r.ToolId, t.Code AS Die, r.ToolCavityId, tc.CavityCode AS Cavity,
       r.ItemId, i.PartNumber,
       r.DefectCodeId, dc.Code AS DefectCode, dc.IsNonRejectScrap,
       r.Quantity, r.Remarks,
       r.AppUserId, u.Initials AS RecordedByInitials,
       r.TerminalLocationId, tl.Code AS TerminalCode,
       r.RecordedAt AS RecordedAtUtc,
       CAST(r.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS RecordedEt,
       CASE WHEN r.LotId IS NULL THEN N'basketless' ELSE N'on a LOT' END AS Shape
FROM Workorder.RejectEvent r
LEFT  JOIN Lots.Lot l           ON l.Id  = r.LotId
LEFT  JOIN Oee.Shift s          ON s.Id  = r.ShiftId
LEFT  JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
LEFT  JOIN Location.Location p  ON p.Id  = r.CellLocationId
LEFT  JOIN Tools.Tool t         ON t.Id  = r.ToolId
LEFT  JOIN Tools.ToolCavity tc  ON tc.Id = r.ToolCavityId
LEFT  JOIN Parts.Item i         ON i.Id  = r.ItemId
LEFT  JOIN Quality.DefectCode dc ON dc.Id = r.DefectCodeId
LEFT  JOIN Location.AppUser u   ON u.Id  = r.AppUserId
LEFT  JOIN Location.Location tl ON tl.Id = r.TerminalLocationId
WHERE r.LotId IN (SELECT Id FROM @Lot)
   OR (r.ToolId IN (SELECT Id FROM @Die)
       AND CAST(r.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) >= @FromEt
       AND CAST(r.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) <  @ToEt)
ORDER BY r.RecordedAt, r.Id;

-- ============================================================
-- K. Counter anchors ("Fix counter") on those dies, inside the window.
-- ============================================================
SELECT N'K Anchors' AS [Set], a.Id AS AnchorId, a.ToolId, t.Code AS Die,
       a.CellLocationId, p.Code AS Press, a.ShiftId,
       a.DeclaredReading, a.ReasonId, ar.Code AS Reason, a.Note,
       a.AppUserId, u.Initials AS RecordedByInitials,
       a.EventAt AS EventAtUtc,
       CAST(a.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventEt
FROM Workorder.DieCastCounterAnchor a
INNER JOIN @Die d              ON d.Id = a.ToolId
INNER JOIN Tools.Tool t        ON t.Id = a.ToolId
LEFT  JOIN Location.Location p ON p.Id = a.CellLocationId
LEFT  JOIN Workorder.DieCastCounterAnchorReason ar ON ar.Id = a.ReasonId
LEFT  JOIN Location.AppUser u  ON u.Id = a.AppUserId
WHERE CAST(a.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) >= @FromEt
  AND CAST(a.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) <  @ToEt
ORDER BY a.EventAt;

-- ============================================================
-- THE FIVE TABLES THE EXISTING EXPORT DOES NOT CARRY.
-- All five are what Lots.ufn_DieCastLotCountLock reads. All five are
-- UNBOUNDED IN TIME for the LOTs in scope -- see the scope rule at the top.
-- ============================================================

-- ---------- L. Production events: the Trim OUT that locks a count ----------
SELECT N'L ProductionEvents' AS [Set], pe.Id AS ProductionEventId, pe.LotId, l.LotName,
       pe.OperationTemplateId, ot.Code AS TemplateCode, ot.Name AS TemplateName,
       oty.Code AS OperationTypeCode, oty.Name AS OperationTypeName,
       pe.WorkOrderOperationId, pe.ShotCount, pe.ScrapCount, pe.ScrapSourceId,
       pe.WeightValue, pe.WeightUomId,
       pe.AppUserId, u.Initials AS RecordedByInitials,
       pe.TerminalLocationId, tl.Code AS TerminalCode, pe.Remarks,
       pe.EventAt AS EventAtUtc,
       CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventEt,
       CASE WHEN oty.Code = N'DieCast' THEN 0 ELSE 1 END AS LocksTheCount
FROM Workorder.ProductionEvent pe
INNER JOIN @Lot w                     ON w.Id  = pe.LotId
LEFT  JOIN Lots.Lot l                 ON l.Id  = pe.LotId
LEFT  JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
LEFT  JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
LEFT  JOIN Location.AppUser u         ON u.Id  = pe.AppUserId
LEFT  JOIN Location.Location tl       ON tl.Id = pe.TerminalLocationId
ORDER BY pe.LotId, pe.EventAt;

-- ---------- M. Status history: release time, holds, closure ----------
SELECT N'M StatusHistory' AS [Set], h.Id AS StatusHistoryId, h.LotId, l.LotName,
       h.OldStatusId, os.Code AS OldStatus, h.NewStatusId, ns.Code AS NewStatus,
       ns.BlocksProduction AS NewStatusBlocksProduction,
       h.Reason,
       h.ChangedByUserId, u.Initials AS ChangedByInitials,
       h.TerminalLocationId, tl.Code AS TerminalCode,
       h.ChangedAt AS ChangedAtUtc,
       CAST(h.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ChangedEt
FROM Lots.LotStatusHistory h
INNER JOIN @Lot w                 ON w.Id  = h.LotId
LEFT  JOIN Lots.Lot l             ON l.Id  = h.LotId
LEFT  JOIN Lots.LotStatusCode os  ON os.Id = h.OldStatusId
LEFT  JOIN Lots.LotStatusCode ns  ON ns.Id = h.NewStatusId
LEFT  JOIN Location.AppUser u     ON u.Id  = h.ChangedByUserId
LEFT  JOIN Location.Location tl   ON tl.Id = h.TerminalLocationId
ORDER BY h.LotId, h.ChangedAt;

-- ---------- N. Attribute changes: a PieceCount correction after release ----------
SELECT N'N AttributeChanges' AS [Set], ac.Id AS AttributeChangeId, ac.LotId, l.LotName,
       ac.AttributeName, ac.OldValue, ac.NewValue, ac.Reason,
       ac.ChangedByUserId, u.Initials AS ChangedByInitials,
       ac.TerminalLocationId, tl.Code AS TerminalCode,
       ac.ChangedAt AS ChangedAtUtc,
       CAST(ac.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS ChangedEt,
       CASE WHEN ac.Reason LIKE N'Shift reconciliation #%' THEN 1 ELSE 0 END AS IsReconciliationOwn
FROM Lots.LotAttributeChange ac
INNER JOIN @Lot w               ON w.Id  = ac.LotId
LEFT  JOIN Lots.Lot l           ON l.Id  = ac.LotId
LEFT  JOIN Location.AppUser u   ON u.Id  = ac.ChangedByUserId
LEFT  JOIN Location.Location tl ON tl.Id = ac.TerminalLocationId
ORDER BY ac.LotId, ac.ChangedAt;

-- ---------- O. Movements: where each basket went ----------
SELECT N'O Movements' AS [Set], m.Id AS MovementId, m.LotId, l.LotName,
       m.FromLocationId, fl.Code AS FromCode, fl.Name AS FromName,
       m.ToLocationId,   tlo.Code AS ToCode,  tlo.Name AS ToName,
       m.MovedByUserId, u.Initials AS MovedByInitials,
       m.TerminalLocationId, tl.Code AS TerminalCode,
       m.MovedAt AS MovedAtUtc,
       CAST(m.MovedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS MovedEt
FROM Lots.LotMovement m
INNER JOIN @Lot w                ON w.Id  = m.LotId
LEFT  JOIN Lots.Lot l            ON l.Id  = m.LotId
LEFT  JOIN Location.Location fl  ON fl.Id = m.FromLocationId
LEFT  JOIN Location.Location tlo ON tlo.Id = m.ToLocationId
LEFT  JOIN Location.AppUser u    ON u.Id  = m.MovedByUserId
LEFT  JOIN Location.Location tl  ON tl.Id = m.TerminalLocationId
ORDER BY m.LotId, m.MovedAt;

-- ---------- P. Genealogy: consumed into another LOT (locks the count) ----------
SELECT N'P Genealogy' AS [Set], g.Id AS GenealogyId,
       g.ParentLotId, pl.LotName AS ParentLotName,
       g.ChildLotId,  chl.LotName AS ChildLotName,
       g.RelationshipTypeId, rt.Code AS RelationshipType,
       g.PieceCount,
       g.EventUserId, u.Initials AS EventUserInitials,
       g.EventAt AS EventAtUtc,
       CAST(g.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS EventEt,
       CASE WHEN g.ParentLotId IN (SELECT Id FROM @Lot) THEN N'our LOT is the PARENT (consumed)'
            ELSE N'our LOT is the CHILD' END AS Side
FROM Lots.LotGenealogy g
LEFT  JOIN Lots.Lot pl            ON pl.Id  = g.ParentLotId
LEFT  JOIN Lots.Lot chl           ON chl.Id = g.ChildLotId
LEFT  JOIN Lots.GenealogyRelationshipType rt ON rt.Id = g.RelationshipTypeId
LEFT  JOIN Location.AppUser u     ON u.Id   = g.EventUserId
WHERE g.ParentLotId IN (SELECT Id FROM @Lot)
   OR g.ChildLotId  IN (SELECT Id FROM @Lot)
ORDER BY g.EventAt, g.Id;

-- ============================================================
-- Q. The count lock, evaluated INLINE.
--    Lots.ufn_DieCastLotCountLock is a 0097-era repeatable and DOES NOT EXIST
--    at 0095, so this file cannot call it -- one missing function would fail
--    the whole export. The four arms below mirror that function's COALESCE
--    exactly (ProductionEvent at a non-DieCast operation; a post-release
--    PieceCount correction that is not a reconciliation's own; Closed or
--    BlocksProduction; consumed into another LOT). Sets L-P carry the raw
--    rows, so any drift between this and the live function is detectable
--    rather than hidden.
-- ============================================================
SELECT N'Q CountLock' AS [Set], l.Id AS LotId, l.LotName, l.PieceCount,
       sc.Code AS StatusCode,
       CAST(CASE WHEN x.Reason IS NULL THEN 0 ELSE 1 END AS BIT) AS IsLocked,
       x.Reason AS LockReason
FROM Lots.Lot l
INNER JOIN @Lot w                ON w.Id = l.Id
LEFT  JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
OUTER APPLY (
    SELECT CAST(COALESCE(
        (SELECT TOP 1 N'Counted at ' + oty.Name + N' '
                + CONVERT(NVARCHAR(16), CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120)
         FROM Workorder.ProductionEvent pe
         INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
         INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
         WHERE pe.LotId = l.Id AND oty.Code <> N'DieCast'
         ORDER BY pe.EventAt),
        (SELECT TOP 1 N'Count corrected '
                + CONVERT(NVARCHAR(16), CAST(ac.ChangedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)), 120)
         FROM Lots.LotAttributeChange ac
         WHERE ac.LotId = l.Id AND ac.AttributeName = N'PieceCount'
           AND ac.Reason NOT LIKE N'Shift reconciliation #%'
           AND ac.ChangedAt > ISNULL((SELECT MIN(h.ChangedAt) FROM Lots.LotStatusHistory h
                                      INNER JOIN Lots.LotStatusCode o ON o.Id = h.OldStatusId
                                      INNER JOIN Lots.LotStatusCode n ON n.Id = h.NewStatusId
                                      WHERE h.LotId = l.Id AND o.Code = N'Open' AND n.Code = N'Good'), '9999-12-31')
         ORDER BY ac.ChangedAt),
        (SELECT TOP 1 CASE WHEN s2.Code = N'Closed' THEN N'LOT is closed'
                           ELSE N'LOT is ' + s2.Name END
         FROM Lots.Lot l2 INNER JOIN Lots.LotStatusCode s2 ON s2.Id = l2.LotStatusId
         WHERE l2.Id = l.Id AND (s2.Code = N'Closed' OR s2.BlocksProduction = 1)),
        (SELECT TOP 1 N'Consumed into another LOT'
         FROM Lots.LotGenealogy g WHERE g.ParentLotId = l.Id)
    ) AS NVARCHAR(200)) AS Reason
) x
ORDER BY l.LotName;

-- ============================================================
-- REFERENCE ROWS -- so the fixture can be built without inventing an id.
-- ============================================================

SELECT N'R Items' AS [Set], i.Id AS ItemId, i.PartNumber, i.Description
FROM Parts.Item i
WHERE i.Id IN (SELECT l.ItemId FROM Lots.Lot l INNER JOIN @Lot w ON w.Id = l.Id)
   OR i.Id IN (SELECT tc.ItemId FROM Tools.ToolCavity tc INNER JOIN @Die d ON d.Id = tc.ToolId)
ORDER BY i.PartNumber;

SELECT N'S Users' AS [Set], u.Id AS AppUserId, u.Initials, u.DisplayName,
       u.AdAccount, u.IgnitionRole, u.DeprecatedAt,
       CASE WHEN u.DeprecatedAt IS NULL THEN 1 ELSE 0 END AS IsActive,
       CASE WHEN ISNULL(u.AdAccount, N'') = N'' THEN 0 ELSE 1 END AS CanElevate
FROM Location.AppUser u
ORDER BY u.Initials;

SELECT N'T DefectCodes' AS [Set], dc.Id AS DefectCodeId, dc.Code, dc.Description,
       dc.IsNonRejectScrap, dc.DeprecatedAt
FROM Quality.DefectCode dc
WHERE dc.DeprecatedAt IS NULL
   OR dc.Id IN (SELECT r.DefectCodeId FROM Workorder.RejectEvent r WHERE r.LotId IN (SELECT Id FROM @Lot))
ORDER BY dc.Code;

SELECT N'U Locations' AS [Set], loc.Id AS LocationId, loc.Code, loc.Name,
       ltd.Name AS LocationTypeDefinition, loc.DeprecatedAt
FROM Location.Location loc
LEFT JOIN Location.LocationTypeDefinition ltd ON ltd.Id = loc.LocationTypeDefinitionId
WHERE loc.Id = @PressId
   OR loc.Id IN (SELECT l.CurrentLocationId    FROM Lots.Lot l INNER JOIN @Lot w ON w.Id = l.Id)
   OR loc.Id IN (SELECT l.ProducedAtLocationId FROM Lots.Lot l INNER JOIN @Lot w ON w.Id = l.Id)
   OR loc.Id IN (SELECT m.ToLocationId   FROM Lots.LotMovement m WHERE m.LotId IN (SELECT Id FROM @Lot))
   OR loc.Id IN (SELECT m.FromLocationId FROM Lots.LotMovement m WHERE m.LotId IN (SELECT Id FROM @Lot))
ORDER BY loc.Code;

SELECT N'V LotStatusCodes' AS [Set], sc.Id AS LotStatusId, sc.Code, sc.Name, sc.BlocksProduction
FROM Lots.LotStatusCode sc
ORDER BY sc.Id;
