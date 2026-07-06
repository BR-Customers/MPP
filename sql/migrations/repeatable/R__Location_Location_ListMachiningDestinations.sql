-- ============================================================
-- Repeatable:  R__Location_Location_ListMachiningDestinations.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-06
-- Version:     2.0
-- Description: Arc 2 Phase 4 tail. The Machining-line destinations the Trim OUT
--              screen offers as 1:1 whole-LOT move targets (the FIFO-queue that
--              Phase 5 Machining IN reads).
--
--              LINE-DEPOSIT MODEL (2026-07-06, executes the first half of the
--              2026-06-30 "check LOTs into the LINE" note): Trim OUT deposits the
--              whole LOT at the LINE, not at a specific receiving cell. A Machining
--              line is a WorkCenter-tier (HierarchyLevel 3) 'ProductionLine'
--              Location (e.g. MA1-5GOF '5G0 Front'); its terminals (Machining In,
--              Machining Out, Assembly ...) are Cell-tier (HierarchyLevel 4) child
--              Locations. Each terminal's session zone resolves to this LINE
--              (Terminal_GetByIpAddress projects ParentLocationId AS ZoneLocationId),
--              so Machining IN already reads the line's FIFO via
--              Lots.Lot_GetWipQueueByLocation(zoneLocationId). Depositing at the
--              line puts the LOT exactly where Machining IN looks.
--
--              Item eligibility is recorded at the line tier (v_EffectiveItemLocation
--              rows sit at the ProductionLine), so TrimOut_Record's ancestor-walk
--              eligibility gate passes when the destination is the line.
--
--              Filter: non-deprecated WorkCenter-tier (HierarchyLevel 3)
--              'ProductionLine' Locations that HAVE at least one non-deprecated
--              'Machining In%' receiving cell -- i.e. lines a Trim LOT can be
--              machined on. This deliberately EXCLUDES the Machining-In cells
--              themselves, label Printers, Assembly / Machining-Out terminals,
--              Die Cast terminals, InspectionLines, and machines. Ordered by Code.
--
--              PriorArt: v1.0 (2026-06-19) returned the HL4 'Machining In' cells;
--              that split the deposit location (cell) from the read location (line)
--              and produced an always-empty Machining-IN FIFO.
--
--              Read proc: NO @Status/@Message, NO OUTPUT params; empty rowset =
--              no machining lines configured (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Location_ListMachiningDestinations
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.Id,
        l.Code,
        l.Name,
        area.Code AS AreaCode,
        area.Name AS AreaName
    FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt            ON lt.Id  = ltd.LocationTypeId
    -- Area parent (the line's parent) for the label.
    LEFT JOIN Location.Location area ON area.Id = l.ParentLocationId
    WHERE lt.HierarchyLevel = 3                  -- WorkCenter tier (the LINE)
      AND ltd.Code = N'ProductionLine'           -- production lines only (not InspectionLine)
      AND l.DeprecatedAt IS NULL
      AND EXISTS (                               -- must have a Machining-IN receiving cell
          SELECT 1
          FROM Location.Location c
          WHERE c.ParentLocationId = l.Id
            AND c.DeprecatedAt IS NULL
            AND c.Name LIKE N'Machining In%')
    ORDER BY l.Code;
END;
GO
