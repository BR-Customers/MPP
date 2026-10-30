-- =============================================
-- Repeatable:  R__Oee_ufn_zzz_ShiftGood.sql
-- Object:      Oee.ufn_ShiftGood
-- Author:      Blue Ridge Automation
-- Created:     2026-10-29
-- Version:     1.1
-- Description: Good pieces made in one runtime shift, by where they are booked
--              (OEE dashboard spec
--              docs/superpowers/specs/2026-10-27-oee-dashboard-design.md
--              sec 6.4). One row per (UnitLocationId, ItemId, ToolId):
--                Die Cast  SUM(Workorder.DieCastContribution.PieceDelta) for
--                          the shift, on the press (CellLocationId). ToolId is
--                          the die: the contribution's cavity's tool, else the
--                          tool assigned to the press at EventAt.
--                Trim      per-shift CHECKPOINT CREDIT: each trim checkpoint
--                          (TrimIn/TrimOut ProductionEvent with a ShotCount)
--                          is credited with its cumulative count minus the
--                          LOT's previous trim checkpoint -- the rule
--                          Workorder.TrimPartial_Record defines. Booked on the
--                          trim shop above the terminal (PlacementIsArea = 1).
--                          Rows with ShiftId NULL (rework passes) are not shift
--                          production and are excluded.
--                M&A       MintedPieceCount of Manufactured-origin FinishedGood
--                          LOTs whose Lot.ShiftId is the shift (v1.1, spec v0.3.1
--                          6.4, D18, D21), on the line above
--                          Lot.CreatedAtTerminalId. Only the mint procs stamp
--                          ShiftId, so split / merge / rework children (which
--                          also carry Manufactured origin and a fresh CreatedAt)
--                          are never new production, and later scrap that
--                          shrinks PieceCount is not charged twice. Received-
--                          origin LOTs are excluded, so a pass-through part is
--                          not counted twice (D14: no SubAssembly-only lines).
--              Placement and family come from Oee.ufn_AreaFamily.
--              No rows for an unknown shift.
--              FILE NAME IS ORDER-SENSITIVE -- 'zzz_' sorts after the 'zz_'
--              function it calls (Oee.ufn_AreaFamily).
-- Change Log:
--   2026-10-29 - 1.0 - Initial version.
--   2026-10-30 - 1.1 - M&A good = MintedPieceCount by Lot.ShiftId (the mint stamp); the
--                      per-LOT shift resolution by CreatedAt is gone (it was 9 s of a
--                      whole-plant week, and it counted split/merge/rework children).
-- =============================================
CREATE OR ALTER FUNCTION Oee.ufn_ShiftGood (@ShiftId BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH TrimCp AS (
        SELECT pe.Id, pe.LotId, pe.ShiftId, pe.TerminalLocationId, pe.ShotCount, pe.EventAt,
               LAG(pe.ShotCount) OVER (PARTITION BY pe.LotId ORDER BY pe.EventAt, pe.Id) AS PrevShotCount
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot ON ot.Id  = pe.OperationTemplateId
        INNER JOIN Parts.OperationType     oty ON oty.Id = ot.OperationTypeId
        WHERE oty.Code IN (N'TrimIn', N'TrimOut')
          AND pe.ShotCount IS NOT NULL
          AND pe.LotId IN (SELECT p2.LotId FROM Workorder.ProductionEvent p2 WHERE p2.ShiftId = @ShiftId)
    ),
    Src AS (
        -- Die cast
        SELECT af.PlacementLocationId AS UnitLocationId, af.PlacementIsArea, af.AreaFamily,
               l.ItemId, COALESCE(tc.ToolId, ta.ToolId) AS ToolId, dcc.EventAt,
               CAST(dcc.PieceDelta AS BIGINT) AS Good
        FROM Workorder.DieCastContribution dcc
        INNER JOIN Lots.Lot l ON l.Id = dcc.LotId
        LEFT  JOIN Tools.ToolCavity tc ON tc.Id = dcc.ToolCavityId
        OUTER APPLY (
            SELECT TOP 1 a.ToolId
            FROM Tools.ToolAssignment a
            WHERE a.CellLocationId = dcc.CellLocationId
              AND a.AssignedAt <= dcc.EventAt
              AND (a.ReleasedAt IS NULL OR a.ReleasedAt > dcc.EventAt)
            ORDER BY a.AssignedAt DESC
        ) ta
        CROSS APPLY Oee.ufn_AreaFamily(dcc.CellLocationId) af
        WHERE dcc.ShiftId = @ShiftId

        UNION ALL

        -- Trim: checkpoint credit
        SELECT af.PlacementLocationId, af.PlacementIsArea, af.AreaFamily,
               l.ItemId, CAST(NULL AS BIGINT), cp.EventAt,
               CAST(cp.ShotCount - ISNULL(cp.PrevShotCount, 0) AS BIGINT)
        FROM TrimCp cp
        INNER JOIN Lots.Lot l ON l.Id = cp.LotId
        CROSS APPLY Oee.ufn_AreaFamily(cp.TerminalLocationId) af
        WHERE cp.ShiftId = @ShiftId

        UNION ALL

        -- M&A: finished goods the mint stamped with this shift (D18, D21)
        SELECT af.PlacementLocationId, af.PlacementIsArea, af.AreaFamily,
               l.ItemId, CAST(NULL AS BIGINT), l.CreatedAt,
               CAST(ISNULL(l.MintedPieceCount, 0) AS BIGINT)
        FROM Lots.Lot l
        INNER JOIN Lots.LotOriginType o   ON o.Id  = l.LotOriginTypeId AND o.Code = N'Manufactured'
        INNER JOIN Parts.Item i           ON i.Id  = l.ItemId
        INNER JOIN Parts.ItemType it      ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
        CROSS APPLY Oee.ufn_AreaFamily(l.CreatedAtTerminalId) af
        WHERE l.ShiftId = @ShiftId
          AND af.AreaFamily = N'ma'
    )
    SELECT UnitLocationId, PlacementIsArea, AreaFamily, ItemId, ToolId,
           MAX(EventAt) AS LastEventAt,
           SUM(Good)    AS Good
    FROM Src
    GROUP BY UnitLocationId, PlacementIsArea, AreaFamily, ItemId, ToolId
);
GO
