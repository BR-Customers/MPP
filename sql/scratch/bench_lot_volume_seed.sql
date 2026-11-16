-- ============================================================
-- Script:      sql/scratch/bench_lot_volume_seed.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-04
-- Purpose:     Year-scale M&A volume seed for the container-as-LOT benchmark
--              (spec docs/superpowers/specs/2026-11-04-container-as-lot-and-lot-volume-design.md
--              sec 10). Writes, by direct insert, the rows Workorder.Assembly_CompleteTray
--              writes per tray, in either shape:
--                Tray      (today, v1.6): one FG LOT per tray -- Lot, LotStatusHistory x2
--                          (Good at mint, Closed at completion), LotMovement, closure
--                          self-row + ancestors, LotEventLog LotCreated, one
--                          ConsumptionEvent AND one LotGenealogy edge per draw.
--                Container (v2.0): one FG LOT per container, the same per-LOT rows once
--                          per container, ConsumptionEvent per draw, ONE genealogy edge
--                          per (source LOT, container LOT), trays stamped ShiftId /
--                          ClosedAtTerminalId / MintedPieceCount.
--              Component stock is a synthetic pool per (line, component): 500-piece
--              LOTs drawn FIFO, each with a die-cast parent LOT, so closure depth is
--              realistic (FG -> source -> casting).
--
--   SAFETY: refuses to run unless DB_NAME() starts with MPP_MES_Bench. No USE.
--           Run with: sqlcmd -S localhost -E -C -d MPP_MES_Bench... -i <this> -v Shape=Tray Run=A Days=365
--   Rates (Jacques, 2026-11-04):
--     Run A: cam holders (MA2-59B, MA2-6MACH, MA2-RPYCAM1, MA2-RPYCAM2) a 96-pc container
--            (24 trays x 4) every 30-40 min; oil pans (MA2-64AOP, MA2-6MAOP, MA2-V6OP)
--            6-8 x 60-pc containers per shift; every other FG line a tray every 3 min.
--     Run B: every line a tray every 3 min.
--   Calendar: schedules 1-3 (Mon-Fri, 3 x 8 h), 450 productive minutes per shift.
--   ASCII only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF DB_NAME() NOT LIKE N'MPP_MES_Bench%'
BEGIN
    RAISERROR(N'bench_lot_volume_seed.sql runs only on an MPP_MES_Bench* database.', 16, 1);
    SET NOEXEC ON;
END
GO
IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName LIKE N'BENCH%')
BEGIN
    RAISERROR(N'Bench rows already present.', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @Shape NVARCHAR(10) = N'$(Shape)', @Run NCHAR(1) = N'$(Run)', @Days INT = $(Days);
IF @Shape NOT IN (N'Tray', N'Container') OR @Run NOT IN (N'A', N'B')
BEGIN
    RAISERROR(N'Shape must be Tray|Container, Run A|B.', 16, 1);
    SET NOEXEC ON;
END
IF OBJECT_ID('tempdb..#Cfg') IS NOT NULL DROP TABLE #Cfg;
SELECT @Shape AS Shape, @Run AS RunCode, @Days AS Days,
       (SELECT MAX(ActualEnd) FROM Oee.Shift WHERE ActualEnd <= CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))) AS ToEt,
       (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured') AS MfgId,
       (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good')   AS GoodId,
       (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed') AS ClosedId,
       (SELECT Id FROM Lots.ContainerStatusCode WHERE Code = N'Shipped') AS ShippedId,
       (SELECT Id FROM Audit.LogEventType WHERE Code = N'LotCreated') AS LotCreatedEvt,
       (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Lot') AS LotEntity,
       (SELECT Id FROM Audit.LogSeverity WHERE Code = N'Info') AS InfoSev
INTO #Cfg;
SELECT * FROM #Cfg;
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' step 1: shifts');
-- ---- 1. Shifts: schedules 1-3 (Mon-Fri) over the window; insert missing rows ----
DECLARE @ToEt DATETIME2(3) = (SELECT ToEt FROM #Cfg), @Days INT = (SELECT Days FROM #Cfg);
DECLARE @FromD DATE = DATEADD(DAY, -@Days, CAST(@ToEt AS DATE));
;WITH n AS (SELECT TOP (@Days + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS k FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT ss.Id, w.S, w.E, N'BENCH: shift'
FROM n
CROSS APPLY (SELECT DATEADD(DAY, n.k, @FromD) AS D) d
CROSS JOIN Oee.ShiftSchedule ss
CROSS APPLY (SELECT
    DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME), ss.StartTime), CAST(d.D AS DATETIME2(3))) AS S,
    DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME), ss.EndTime),
            CAST(DATEADD(DAY, CASE WHEN ss.EndTime <= ss.StartTime THEN 1 ELSE 0 END, d.D) AS DATETIME2(3))) AS E) w
WHERE ss.Id IN (1, 2, 3)
  AND (ss.DaysOfWeekBitmask & POWER(2, DATEDIFF(DAY, '19000101', d.D) % 7)) <> 0
  AND w.E <= @ToEt
  AND NOT EXISTS (SELECT 1 FROM Oee.Shift s WHERE s.ShiftScheduleId = ss.Id AND s.ActualStart = w.S);
PRINT CONCAT(N'  shifts inserted: ', @@ROWCOUNT);

IF OBJECT_ID('tempdb..#S') IS NOT NULL DROP TABLE #S;
SELECT s.Id AS ShiftId,
       CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc,
       ROW_NUMBER() OVER (ORDER BY s.ActualStart) AS ShiftNo
INTO #S
FROM Oee.Shift s
WHERE s.ShiftScheduleId IN (1, 2, 3)
  AND s.ActualStart >= CAST(@FromD AS DATETIME2(3)) AND s.ActualEnd <= @ToEt;
SELECT CONCAT(N'  shifts in window: ', (SELECT COUNT(*) FROM #S)) AS Info;
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' step 2: lines');
-- ---- 2. Lines: one finished good per M&A line (lowest ItemId with a config) ----
IF OBJECT_ID('tempdb..#Line') IS NOT NULL DROP TABLE #Line;
;WITH elig AS (
    SELECT l.Id AS LineId, l.Code AS LineCode, cc.ItemId, cc.PartsPerTray, cc.TraysPerContainer,
           ROW_NUMBER() OVER (PARTITION BY l.Id ORDER BY cc.ItemId, cc.Id) AS rn
    FROM Parts.ContainerConfig cc
    JOIN Parts.Item i ON i.Id = cc.ItemId
    JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
    JOIN Parts.ItemLocation il ON il.ItemId = cc.ItemId AND il.DeprecatedAt IS NULL
    JOIN Location.Location l ON l.Id = il.LocationId
    WHERE cc.DeprecatedAt IS NULL AND l.Code NOT LIKE N'6ma-CH-L2%' AND cc.PartsPerTray > 0
)
SELECT ROW_NUMBER() OVER (ORDER BY e.LineId) AS LineNum, e.LineId, e.LineCode, e.ItemId,
       COALESCE((SELECT TOP 1 t.Id FROM Location.Location t
                 JOIN Location.LocationTypeDefinition d ON d.Id = t.LocationTypeDefinitionId AND d.Code = N'Terminal'
                 WHERE t.ParentLocationId = e.LineId ORDER BY t.Id), e.LineId) AS TerminalId,
       k.Kind,
       CASE WHEN k.Kind = N'cam' THEN 4  WHEN k.Kind = N'oil' THEN 60 ELSE e.PartsPerTray END AS TrayPcs,
       CASE WHEN k.Kind = N'cam' THEN 24 WHEN k.Kind = N'oil' THEN 1  ELSE ISNULL(e.TraysPerContainer, 1) END AS Tpc
INTO #Line
FROM elig e
CROSS APPLY (SELECT CASE WHEN e.LineCode IN (N'MA2-59B', N'MA2-6MACH', N'MA2-RPYCAM1', N'MA2-RPYCAM2') THEN N'cam'
                         WHEN e.LineCode IN (N'MA2-64AOP', N'MA2-6MAOP', N'MA2-V6OP') THEN N'oil'
                         ELSE N'other' END AS Kind) k
WHERE e.rn = 1;
SELECT LineNum, LineCode, Kind, TrayPcs, Tpc FROM #Line ORDER BY LineNum;

-- BOM per line item (no BOM -> the item itself 1:1, as pass-through repack)
IF OBJECT_ID('tempdb..#Bom') IS NOT NULL DROP TABLE #Bom;
SELECT ln.LineNum, ROW_NUMBER() OVER (PARTITION BY ln.LineNum ORDER BY x.ChildItemId) AS CompNo, x.ChildItemId, x.QtyPer
INTO #Bom
FROM #Line ln
CROSS APPLY (
    SELECT bl.ChildItemId, CAST(CEILING(bl.QtyPer) AS INT) AS QtyPer
    FROM Parts.Bom b JOIN Parts.BomLine bl ON bl.BomId = b.Id
    WHERE b.Id = (SELECT TOP 1 b2.Id FROM Parts.Bom b2 WHERE b2.ParentItemId = ln.ItemId AND b2.PublishedAt IS NOT NULL AND b2.DeprecatedAt IS NULL ORDER BY b2.VersionNumber DESC)
    UNION ALL
    SELECT ln.ItemId, 1
    WHERE NOT EXISTS (SELECT 1 FROM Parts.Bom b2 WHERE b2.ParentItemId = ln.ItemId AND b2.PublishedAt IS NOT NULL AND b2.DeprecatedAt IS NULL)
) x;
SELECT CONCAT(N'  lines: ', (SELECT COUNT(*) FROM #Line), N', bom lines: ', (SELECT COUNT(*) FROM #Bom)) AS Info;
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' step 3: trays');
-- ---- 3. Trays: per line per shift, evenly over 450 productive minutes ----
--   cam (A): one container per 30-40 min (varies by shift) -> 24 trays per container
--   oil (A): 6-8 containers per shift, one 60-pc tray each
--   other, and every line in run B: a tray every 3 min (150 per shift)
DECLARE @Run NCHAR(1) = (SELECT RunCode FROM #Cfg);
IF OBJECT_ID('tempdb..#TrayPlan') IS NOT NULL DROP TABLE #TrayPlan;
SELECT ln.LineNum, s.ShiftId, s.StartUtc, s.ShiftNo,
       CASE WHEN @Run = N'A' AND ln.Kind = N'cam' THEN (450 / (30 + ABS(CHECKSUM(s.ShiftNo, ln.LineNum)) % 11)) * 24
            WHEN @Run = N'A' AND ln.Kind = N'oil' THEN 6 + ABS(CHECKSUM(s.ShiftNo, ln.LineNum)) % 3
            ELSE 150 END AS NTrays
INTO #TrayPlan
FROM #Line ln CROSS JOIN #S s;

IF OBJECT_ID('tempdb..#Tray') IS NOT NULL DROP TABLE #Tray;
CREATE TABLE #Tray (TrayKey BIGINT NOT NULL PRIMARY KEY, LineNum INT NOT NULL, ShiftId BIGINT NOT NULL,
                    ClosedAt DATETIME2(3) NOT NULL, LineSeq BIGINT NOT NULL, ContainerNo BIGINT NULL, TrayPos INT NULL);
;WITH n AS (SELECT TOP (400) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k FROM sys.all_objects)
INSERT INTO #Tray (TrayKey, LineNum, ShiftId, ClosedAt, LineSeq)
SELECT ROW_NUMBER() OVER (ORDER BY p.LineNum, p.ShiftNo, n.k),
       p.LineNum, p.ShiftId,
       DATEADD(SECOND, CAST(n.k * 27000.0 / (p.NTrays + 1) AS INT), p.StartUtc),
       ROW_NUMBER() OVER (PARTITION BY p.LineNum ORDER BY p.ShiftNo, n.k)
FROM #TrayPlan p JOIN n ON n.k <= p.NTrays;
-- containers: consecutive trays per line, Tpc per container
UPDATE t SET ContainerNo = (t.LineSeq - 1) / ln.Tpc, TrayPos = CAST((t.LineSeq - 1) % ln.Tpc AS INT) + 1
FROM #Tray t JOIN #Line ln ON ln.LineNum = t.LineNum;
SELECT CONCAT(N'  trays: ', (SELECT COUNT(*) FROM #Tray)) AS Info;

IF OBJECT_ID('tempdb..#Ctr') IS NOT NULL DROP TABLE #Ctr;
SELECT ROW_NUMBER() OVER (ORDER BY t.LineNum, t.ContainerNo) AS CtrKey, t.LineNum, t.ContainerNo,
       MIN(t.ClosedAt) AS OpenedAt, MAX(t.ClosedAt) AS CompletedAt, MIN(t.TrayKey) AS FirstTrayKey,
       COUNT(*) AS Trays
INTO #Ctr
FROM #Tray t GROUP BY t.LineNum, t.ContainerNo;
CREATE UNIQUE CLUSTERED INDEX cx ON #Ctr (LineNum, ContainerNo);
SELECT CONCAT(N'  containers: ', (SELECT COUNT(*) FROM #Ctr)) AS Info;
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' step 4: draws');
-- ---- 4. Draws: FIFO over a 500-piece pool per (line, component) ----
IF OBJECT_ID('tempdb..#Draw') IS NOT NULL DROP TABLE #Draw;
CREATE TABLE #Draw (TrayKey BIGINT NOT NULL, LineNum INT NOT NULL, CompNo INT NOT NULL, PoolIdx BIGINT NOT NULL, Take INT NOT NULL);
;WITH need AS (
    SELECT t.TrayKey, t.LineNum, b.CompNo, b.QtyPer * ln.TrayPcs AS Need,
           (t.LineSeq - 1) * b.QtyPer * ln.TrayPcs AS CumBefore
    FROM #Tray t JOIN #Line ln ON ln.LineNum = t.LineNum JOIN #Bom b ON b.LineNum = t.LineNum
)
INSERT INTO #Draw (TrayKey, LineNum, CompNo, PoolIdx, Take)
SELECT n.TrayKey, n.LineNum, n.CompNo, p.PoolIdx,
       CAST(CASE WHEN n.CumBefore + n.Need < (p.PoolIdx + 1) * 500 THEN n.CumBefore + n.Need ELSE (p.PoolIdx + 1) * 500 END
          - CASE WHEN n.CumBefore > p.PoolIdx * 500 THEN n.CumBefore ELSE p.PoolIdx * 500 END AS INT)
FROM need n
CROSS APPLY (SELECT n.CumBefore / 500 AS PoolIdx
             UNION ALL
             SELECT (n.CumBefore + n.Need - 1) / 500 WHERE (n.CumBefore + n.Need - 1) / 500 > n.CumBefore / 500) p;
SELECT CONCAT(N'  draws: ', (SELECT COUNT(*) FROM #Draw)) AS Info;

IF OBJECT_ID('tempdb..#Pool') IS NOT NULL DROP TABLE #Pool;
SELECT ROW_NUMBER() OVER (ORDER BY d.LineNum, d.CompNo, d.PoolIdx) AS PoolKey, d.LineNum, d.CompNo, d.PoolIdx,
       MIN(t.ClosedAt) AS FirstUse
INTO #Pool
FROM #Draw d JOIN #Tray t ON t.TrayKey = d.TrayKey
GROUP BY d.LineNum, d.CompNo, d.PoolIdx;
CREATE UNIQUE CLUSTERED INDEX cx ON #Pool (LineNum, CompNo, PoolIdx);
SELECT CONCAT(N'  pool LOTs: ', (SELECT COUNT(*) FROM #Pool)) AS Info;
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' step 5: pool + casting LOTs');
-- ---- 5. Id bases (explicit Ids: IDENTITY_INSERT, then reseed) ----
IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;
SELECT (SELECT ISNULL(MAX(Id), 0) FROM Lots.Lot) + 1000 AS LotBase,
       (SELECT ISNULL(MAX(Id), 0) FROM Lots.Container) + 1000 AS CtrBase,
       (SELECT ISNULL(MAX(Id), 0) FROM Lots.ContainerTray) + 1000 AS TrayBase,
       (SELECT COUNT(*) FROM #Pool) AS NPool
INTO #Base;
-- Lot Id layout: casting = LotBase + PoolKey; pool = LotBase + NPool + PoolKey;
--   FG (Tray shape) = LotBase + 2*NPool + TrayKey; FG (Container shape) = LotBase + 2*NPool + CtrKey.

DECLARE @LotBase BIGINT = (SELECT LotBase FROM #Base), @NPool BIGINT = (SELECT NPool FROM #Base);
DECLARE @ClosedId BIGINT = (SELECT ClosedId FROM #Cfg), @MfgId BIGINT = (SELECT MfgId FROM #Cfg);
SET IDENTITY_INSERT Lots.Lot ON;
-- castings (die-cast parents) then pool (source) LOTs, all consumed -> Closed
INSERT INTO Lots.Lot (Id, LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAt, InventoryAvailable)
SELECT @LotBase + p.PoolKey, CONCAT(N'BENCHC', p.PoolKey), b.ChildItemId, @MfgId, @ClosedId, 0, ln.LineId, 1, DATEADD(DAY, -3, p.FirstUse), 0
FROM #Pool p JOIN #Bom b ON b.LineNum = p.LineNum AND b.CompNo = p.CompNo JOIN #Line ln ON ln.LineNum = p.LineNum;
INSERT INTO Lots.Lot (Id, LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, CreatedByUserId, CreatedAt, InventoryAvailable)
SELECT @LotBase + @NPool + p.PoolKey, CONCAT(N'BENCHP', p.PoolKey), b.ChildItemId, @MfgId, @ClosedId, 0, ln.LineId, 1, DATEADD(DAY, -1, p.FirstUse), 0
FROM #Pool p JOIN #Bom b ON b.LineNum = p.LineNum AND b.CompNo = p.CompNo JOIN #Line ln ON ln.LineNum = p.LineNum;
SET IDENTITY_INSERT Lots.Lot OFF;
-- casting -> pool edge + closure (self rows and casting->pool)
INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, EventAt)
SELECT @LotBase + PoolKey, @LotBase + @NPool + PoolKey, 3, 500, 1, DATEADD(DAY, -1, FirstUse) FROM #Pool;
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT @LotBase + PoolKey, @LotBase + PoolKey, 0 FROM #Pool
UNION ALL SELECT @LotBase + @NPool + PoolKey, @LotBase + @NPool + PoolKey, 0 FROM #Pool
UNION ALL SELECT @LotBase + PoolKey, @LotBase + @NPool + PoolKey, 1 FROM #Pool;
PRINT CONCAT(N'  pool+casting LOTs: ', 2 * @NPool);
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' step 6: containers + FG LOTs');
-- ---- 6. Containers, FG LOTs, trays ----
DECLARE @Shape NVARCHAR(10) = (SELECT Shape FROM #Cfg);
DECLARE @LotBase BIGINT = (SELECT LotBase FROM #Base), @NPool BIGINT = (SELECT NPool FROM #Base);
DECLARE @CtrBase BIGINT = (SELECT CtrBase FROM #Base), @TrayBase BIGINT = (SELECT TrayBase FROM #Base);
DECLARE @FgBase BIGINT = @LotBase + 2 * @NPool;
DECLARE @GoodId BIGINT = (SELECT GoodId FROM #Cfg), @ClosedId BIGINT = (SELECT ClosedId FROM #Cfg),
        @MfgId BIGINT = (SELECT MfgId FROM #Cfg), @ShippedId BIGINT = (SELECT ShippedId FROM #Cfg);

SET IDENTITY_INSERT Lots.Container ON;
INSERT INTO Lots.Container (Id, ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CompletedAt, CreatedByUserId, StationLocationId)
SELECT @CtrBase + c.CtrKey, ln.ItemId,
       (SELECT TOP 1 cc.Id FROM Parts.ContainerConfig cc WHERE cc.ItemId = ln.ItemId AND cc.DeprecatedAt IS NULL ORDER BY cc.Id),
       ln.LineId, @ShippedId, c.OpenedAt, c.CompletedAt, 1, ln.TerminalId
FROM #Ctr c JOIN #Line ln ON ln.LineNum = c.LineNum;
SET IDENTITY_INSERT Lots.Container OFF;

-- FG LOTs: Tray shape = one per tray; Container shape = one per container
IF OBJECT_ID('tempdb..#Fg') IS NOT NULL DROP TABLE #Fg;
CREATE TABLE #Fg (LotId BIGINT NOT NULL PRIMARY KEY, LineNum INT NOT NULL, CreatedAt DATETIME2(3) NOT NULL,
                  CompletedAt DATETIME2(3) NOT NULL, Pcs INT NOT NULL, ShiftId BIGINT NULL);
IF @Shape = N'Tray'
    INSERT INTO #Fg SELECT @FgBase + t.TrayKey, t.LineNum, t.ClosedAt, c.CompletedAt, ln.TrayPcs, t.ShiftId
    FROM #Tray t JOIN #Line ln ON ln.LineNum = t.LineNum JOIN #Ctr c ON c.LineNum = t.LineNum AND c.ContainerNo = t.ContainerNo;
ELSE
    INSERT INTO #Fg SELECT @FgBase + c.CtrKey, c.LineNum, c.OpenedAt, c.CompletedAt, ln.TrayPcs * c.Trays, NULL
    FROM #Ctr c JOIN #Line ln ON ln.LineNum = c.LineNum;

SET IDENTITY_INSERT Lots.Lot ON;
INSERT INTO Lots.Lot (Id, LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId,
                      CreatedByUserId, CreatedAtTerminalId, CreatedAt, ShiftId, MintedPieceCount)
SELECT f.LotId, CONCAT(N'BENCHF', f.LotId - @FgBase), ln.ItemId, @MfgId, @ClosedId, f.Pcs, f.Pcs, ln.LineId,
       1, ln.TerminalId, f.CreatedAt, f.ShiftId, CASE WHEN f.ShiftId IS NULL THEN NULL ELSE f.Pcs END
FROM #Fg f JOIN #Line ln ON ln.LineNum = f.LineNum;
SET IDENTITY_INSERT Lots.Lot OFF;
SELECT CONCAT(N'  FG LOTs: ', (SELECT COUNT(*) FROM #Fg)) AS Info;

-- Container-shape columns exist only after migration 0119: dynamic SQL so the Tray-shape
-- (before) run compiles on a database without them.
IF @Shape = N'Container'
    EXEC sp_executesql N'UPDATE ct SET LotId = @FgBase + c.CtrKey
        FROM Lots.Container ct JOIN #Ctr c ON ct.Id = @CtrBase + c.CtrKey;',
        N'@FgBase BIGINT, @CtrBase BIGINT', @FgBase = @FgBase, @CtrBase = @CtrBase;

-- per-LOT birth rows (the mint) + the close at container completion
INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, ChangedAt)
SELECT LotId, NULL, @GoodId, N'Finished-good LOT minted by assembly tray completion.', 1, CreatedAt FROM #Fg
UNION ALL
SELECT LotId, @GoodId, @ClosedId, N'Closed on container completion (finished-goods packed & shipping-ready).', 1, CompletedAt FROM #Fg;
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, MovedAt)
SELECT f.LotId, NULL, ln.LineId, 1, f.CreatedAt FROM #Fg f JOIN #Line ln ON ln.LineNum = f.LineNum;
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT LotId, LotId, 0 FROM #Fg;
INSERT INTO Lots.LotEventLog (LoggedAt, UserId, TerminalLocationId, LocationId, LogSeverityId, LogEventTypeId, LogEntityTypeId, EntityId, LotId, Description)
SELECT f.CreatedAt, 1, ln.TerminalId, ln.LineId, c.InfoSev, c.LotCreatedEvt, c.LotEntity, f.LotId, f.LotId,
       CONCAT(N'BENCHF', f.LotId - @FgBase, N' - Lot - Minted by assembly')
FROM #Fg f JOIN #Line ln ON ln.LineNum = f.LineNum CROSS JOIN #Cfg c;

SET IDENTITY_INSERT Lots.ContainerTray ON;
IF @Shape = N'Tray'
    INSERT INTO Lots.ContainerTray (Id, ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod, FinishedGoodLotId)
    SELECT @TrayBase + t.TrayKey, @CtrBase + c.CtrKey, t.TrayPos, ln.TrayPcs, t.ClosedAt, 1, N'ByVision', @FgBase + t.TrayKey
    FROM #Tray t JOIN #Line ln ON ln.LineNum = t.LineNum JOIN #Ctr c ON c.LineNum = t.LineNum AND c.ContainerNo = t.ContainerNo;
ELSE
    EXEC sp_executesql N'SET IDENTITY_INSERT Lots.ContainerTray ON;
        INSERT INTO Lots.ContainerTray (Id, ContainerId, TrayPosition, PartsClosedCount, ClosedAt, ClosedByUserId, ClosureMethod,
                                        FinishedGoodLotId, ShiftId, ClosedAtTerminalId, MintedPieceCount)
        SELECT @TrayBase + t.TrayKey, @CtrBase + c.CtrKey, t.TrayPos, ln.TrayPcs, t.ClosedAt, 1, N''ByVision'',
               NULL, t.ShiftId, ln.TerminalId, ln.TrayPcs
        FROM #Tray t JOIN #Line ln ON ln.LineNum = t.LineNum JOIN #Ctr c ON c.LineNum = t.LineNum AND c.ContainerNo = t.ContainerNo;
        SET IDENTITY_INSERT Lots.ContainerTray OFF;',
        N'@TrayBase BIGINT, @CtrBase BIGINT', @TrayBase = @TrayBase, @CtrBase = @CtrBase;
SET IDENTITY_INSERT Lots.ContainerTray OFF;
SELECT CONCAT(N'  trays: ', (SELECT COUNT(*) FROM #Tray)) AS Info;
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' step 7: consumption + genealogy + closure');
-- ---- 7. Consumption, genealogy, closure ----
DECLARE @Shape NVARCHAR(10) = (SELECT Shape FROM #Cfg);
DECLARE @LotBase BIGINT = (SELECT LotBase FROM #Base), @NPool BIGINT = (SELECT NPool FROM #Base);
DECLARE @CtrBase BIGINT = (SELECT CtrBase FROM #Base), @TrayBase BIGINT = (SELECT TrayBase FROM #Base);
DECLARE @FgBase BIGINT = @LotBase + 2 * @NPool;

INSERT INTO Workorder.ConsumptionEvent (SourceLotId, ProducedLotId, ProducedContainerId, ConsumedItemId, ProducedItemId,
                                        PieceCount, LocationId, AppUserId, TerminalLocationId, TrayId, ConsumedAt)
SELECT @LotBase + @NPool + p.PoolKey,
       CASE WHEN @Shape = N'Tray' THEN @FgBase + t.TrayKey ELSE @FgBase + c.CtrKey END,
       @CtrBase + c.CtrKey, b.ChildItemId, ln.ItemId, d.Take, ln.LineId, 1, ln.TerminalId, @TrayBase + t.TrayKey, t.ClosedAt
FROM #Draw d
JOIN #Tray t ON t.TrayKey = d.TrayKey
JOIN #Line ln ON ln.LineNum = d.LineNum
JOIN #Bom b ON b.LineNum = d.LineNum AND b.CompNo = d.CompNo
JOIN #Pool p ON p.LineNum = d.LineNum AND p.CompNo = d.CompNo AND p.PoolIdx = d.PoolIdx
JOIN #Ctr c ON c.LineNum = t.LineNum AND c.ContainerNo = t.ContainerNo;
PRINT CONCAT(N'  ConsumptionEvent: ', @@ROWCOUNT);

-- genealogy: Tray = one edge per draw; Container = one edge per (source, container LOT)
IF @Shape = N'Tray'
    INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId, EventAt)
    SELECT @LotBase + @NPool + p.PoolKey, @FgBase + t.TrayKey, 3, d.Take, 1, ln.TerminalId, t.ClosedAt
    FROM #Draw d JOIN #Tray t ON t.TrayKey = d.TrayKey JOIN #Line ln ON ln.LineNum = d.LineNum
    JOIN #Pool p ON p.LineNum = d.LineNum AND p.CompNo = d.CompNo AND p.PoolIdx = d.PoolIdx;
ELSE
    INSERT INTO Lots.LotGenealogy (ParentLotId, ChildLotId, RelationshipTypeId, PieceCount, EventUserId, TerminalLocationId, EventAt)
    SELECT @LotBase + @NPool + p.PoolKey, @FgBase + c.CtrKey, 3, SUM(d.Take), 1, MIN(ln.TerminalId), MIN(t.ClosedAt)
    FROM #Draw d JOIN #Tray t ON t.TrayKey = d.TrayKey JOIN #Line ln ON ln.LineNum = d.LineNum
    JOIN #Pool p ON p.LineNum = d.LineNum AND p.CompNo = d.CompNo AND p.PoolIdx = d.PoolIdx
    JOIN #Ctr c ON c.LineNum = t.LineNum AND c.ContainerNo = t.ContainerNo
    GROUP BY p.PoolKey, c.CtrKey;
PRINT CONCAT(N'  LotGenealogy: ', @@ROWCOUNT);

-- closure: each FG LOT gets every distinct ancestor of its sources (source self at depth 1, casting at depth 2)
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT DISTINCT a.AncestorLotId, g.ChildLotId, a.Depth + 1
FROM Lots.LotGenealogy g
JOIN Lots.LotGenealogyClosure a ON a.DescendantLotId = g.ParentLotId
WHERE g.ChildLotId > @FgBase AND g.ChildLotId <= @FgBase + (SELECT COUNT(*) FROM #Fg) + 1;
PRINT CONCAT(N'  closure (FG ancestors): ', @@ROWCOUNT);

-- Lot sequence: the MESL numbers this year consumed (FG LOTs only; pool/casting LOTs stand in for
-- die-cast / machining LOTs whose numbering is separate)
UPDATE Lots.IdentifierSequence SET LastValue = LastValue + (SELECT COUNT(*) FROM #Fg) WHERE Code = N'Lot';
SELECT (SELECT COUNT(*) FROM #Fg) AS FgLotsMinted, LastValue, EndingValue FROM Lots.IdentifierSequence WHERE Code = N'Lot';
-- Statistics: a production table grows over a year and auto-update keeps up; a bulk
-- seed lands millions of rows at once, so refresh them before anything is measured.
EXEC sp_updatestats;
PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' done');
GO
