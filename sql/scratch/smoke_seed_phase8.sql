-- =============================================================
-- smoke_seed_phase8.sql  (DEV AID, one-shot; wiped by Reset-DevDatabase)
-- Seeds data so the Phase 8 plant-floor screens show something on open:
--   * an OPEN shift (End-of-Shift screen shows "Active shift #N")
--   * 3 OPEN downtime events across 3 cells (Dashboard: total=3,
--     classified=2, unclassified=1) -- one open per cell (B3 invariant)
--   * 2 in-process LOTs at the PRIMARY cell, one of them PAUSED
--     (Shift-End Summary lists for that cell)
-- Re-runnable: clears prior open downtime at the chosen cells first.
-- =============================================================
SET NOCOUNT ON;

-- ---- pick cells -------------------------------------------------------------
DECLARE @ItemA BIGINT, @CellA BIGINT;
SELECT TOP 1 @ItemA = eil.ItemId, @CellA = eil.LocationId
FROM Parts.v_EffectiveItemLocation eil
WHERE NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.CellLocationId = eil.LocationId AND ta.ReleasedAt IS NULL)
ORDER BY eil.LocationId;

DECLARE @cells TABLE (rn INT IDENTITY(1,1), Id BIGINT);
INSERT INTO @cells (Id)
SELECT TOP 2 l.Id FROM Location.Location l
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
WHERE lt.HierarchyLevel = 4 AND l.DeprecatedAt IS NULL AND l.Id <> @CellA
ORDER BY l.Id;
DECLARE @CellB BIGINT = (SELECT Id FROM @cells WHERE rn = 1);
DECLARE @CellC BIGINT = (SELECT Id FROM @cells WHERE rn = 2);

DECLARE @SiteId BIGINT = (SELECT TOP 1 l.Id FROM Location.Location l
    INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
    INNER JOIN Location.LocationType lt ON lt.Id = ltd.LocationTypeId
    WHERE lt.HierarchyLevel = 1 AND l.DeprecatedAt IS NULL ORDER BY l.Id);

-- ---- a couple of realistic downtime reason codes (so "classified" looks real) --
IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Code = N'TOOLCHG')
    INSERT INTO Oee.DowntimeReasonCode (Code, Description, AreaLocationId, DowntimeReasonTypeId, IsExcused, CreatedByUserId)
    VALUES (N'TOOLCHG', N'Tool change', @SiteId, (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Mold'), 0, 1);
IF NOT EXISTS (SELECT 1 FROM Oee.DowntimeReasonCode WHERE Code = N'MATL')
    INSERT INTO Oee.DowntimeReasonCode (Code, Description, AreaLocationId, DowntimeReasonTypeId, IsExcused, CreatedByUserId)
    VALUES (N'MATL', N'Material shortage', @SiteId, (SELECT Id FROM Oee.DowntimeReasonType WHERE Code = N'Equipment'), 0, 1);
DECLARE @rToolchg BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'TOOLCHG');
DECLARE @rMatl    BIGINT = (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'MATL');

-- ---- open shift (single-open invariant: only if none open) -------------------
IF NOT EXISTS (SELECT 1 FROM Oee.Shift WHERE ActualEnd IS NULL)
BEGIN
    DECLARE @sched BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftSchedule WHERE DeprecatedAt IS NULL ORDER BY Id);
    IF @sched IS NULL
    BEGIN
        INSERT INTO Oee.ShiftSchedule (Name, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
        VALUES (N'Day Shift (dev)', '06:00', '14:00', 31, '2026-01-01', 1);
        SET @sched = SCOPE_IDENTITY();
    END
    DECLARE @ss TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
    INSERT INTO @ss EXEC Oee.Shift_Start @ShiftScheduleId = @sched, @ActualStart = NULL, @AppUserId = 1;
END

-- ---- clear prior open downtime at our 3 cells (re-run safety, B3) ------------
DELETE ol FROM Audit.OperationLog ol
    INNER JOIN Oee.DowntimeEvent de ON de.Id = ol.EntityId
    WHERE de.LocationId IN (@CellA, @CellB, @CellC) AND de.EndedAt IS NULL
      AND ol.LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent');
DELETE FROM Oee.DowntimeEvent WHERE LocationId IN (@CellA, @CellB, @CellC) AND EndedAt IS NULL;

-- ---- 3 open downtime events: 2 classified, 1 unclassified -------------------
DECLARE @d TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @d EXEC Oee.DowntimeEvent_Start @LocationId = @CellA, @DowntimeReasonCodeId = @rToolchg, @AppUserId = 1;
DELETE FROM @d;
INSERT INTO @d EXEC Oee.DowntimeEvent_Start @LocationId = @CellB, @DowntimeReasonCodeId = @rMatl, @AppUserId = 1;
DELETE FROM @d;
INSERT INTO @d EXEC Oee.DowntimeEvent_Start @LocationId = @CellC, @AppUserId = 1;  -- no reason (unclassified)

-- ---- 2 in-process LOTs at the primary cell, one paused ----------------------
DECLARE @origin BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @cr TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemA, @LotOriginTypeId = @origin, @CurrentLocationId = @CellA, @PieceCount = 50, @AppUserId = 1;
DECLARE @lot1 BIGINT = (SELECT NewId FROM @cr);
DELETE FROM @cr;
INSERT INTO @cr EXEC Lots.Lot_Create @ItemId = @ItemA, @LotOriginTypeId = @origin, @CurrentLocationId = @CellA, @PieceCount = 75, @AppUserId = 1;
DECLARE @p TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @p EXEC Lots.LotPause_Place @LotId = @lot1, @LocationId = @CellA, @PausedReason = N'Awaiting inspection', @AppUserId = 1;

-- ---- report what to pick ----------------------------------------------------
SELECT
    (SELECT Code FROM Location.Location WHERE Id = @CellA) AS PrimaryCell_pick_in_Summary,
    (SELECT Code FROM Location.Location WHERE Id = @CellB) AS CellB,
    (SELECT Code FROM Location.Location WHERE Id = @CellC) AS CellC,
    (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE EndedAt IS NULL) AS TotalOpenDowntime,
    (SELECT COUNT(*) FROM Oee.Shift WHERE ActualEnd IS NULL) AS OpenShifts;
