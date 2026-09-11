-- ============================================================
-- Repeatable:  R__Lots_Container_GetOpenByCell.sql
-- Author:      Blue Ridge Automation
-- Version:     1.1
-- Description: Returns the OPEN container(s) at a Cell (Arc 2 Phase 6 assembly read),
--              with the config target + accumulated closed-tray parts so the Assembly
--              views can show fill progress + gate completion. Read proc: no OUTPUT
--              params, empty set = none open. OpenedAt CAST to ET DATETIME2(3) (raw
--              datetimeoffset breaks the Ignition JDBC read).
--              v1.1 (2026-09-11, migration 0078): open boxes belong to a STATION.
--              Two optional filters, both defaulting to NULL = no filter (so the
--              existing single-argument callers are unchanged):
--                @StationLocationId -- that station's own boxes PLUS unowned ones
--                  (StationLocationId NULL: every pre-0078 box, and any box a
--                  non-terminal caller opened). An unowned box is claimable by
--                  whichever station fills it next (Assembly_CompleteTray v1.4).
--                @ClosureMethod -- boxes whose pack-out uses that method, so a
--                  ByVision cell never picks up a ByCount (METTs) box and vice versa.
--              Adds StationLocationId + StationCode (the owning terminal) at the end
--              of the row.
-- ============================================================

CREATE OR ALTER PROCEDURE Lots.Container_GetOpenByCell
    @CellLocationId    BIGINT,
    @StationLocationId BIGINT       = NULL,
    @ClosureMethod     NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ct.Id,
        ct.ItemId,
        i.PartNumber                                   AS ItemPartNumber,
        i.Description                                  AS ItemDescription,
        ct.ContainerConfigId,
        cc.TraysPerContainer,
        cc.PartsPerTray,
        cc.IsSerialized,
        cc.ClosureMethod,
        (cc.TraysPerContainer * cc.PartsPerTray)       AS TargetParts,
        ISNULL((SELECT SUM(t.PartsClosedCount) FROM Lots.ContainerTray t
                WHERE t.ContainerId = ct.Id AND t.ClosedAt IS NOT NULL), 0) AS AccumulatedParts,
        (SELECT COUNT(*) FROM Lots.ContainerTray t WHERE t.ContainerId = ct.Id AND t.ClosedAt IS NOT NULL) AS ClosedTrays,
        CAST(ct.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3)) AS OpenedAt,
        ct.StationLocationId,
        st.Code                                        AS StationCode
    FROM Lots.Container ct
    INNER JOIN Parts.Item i ON i.Id = ct.ItemId
    INNER JOIN Parts.ContainerConfig cc ON cc.Id = ct.ContainerConfigId
    LEFT JOIN Location.Location st ON st.Id = ct.StationLocationId
    WHERE ct.CurrentLocationId = @CellLocationId
      AND ct.ContainerStatusCodeId = 1   -- Open
      AND (@StationLocationId IS NULL
           OR ct.StationLocationId = @StationLocationId
           OR ct.StationLocationId IS NULL)
      AND (@ClosureMethod IS NULL OR cc.ClosureMethod = @ClosureMethod)
    ORDER BY ct.OpenedAt;
END;
GO
