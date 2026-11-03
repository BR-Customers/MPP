-- ============================================================
-- seed_oee_history.sql
-- Four weeks of plausible plant history for the OEE dashboard
-- (/shop-floor/oee + the Area and Unit pages). ADDITIVE ONLY: it never
-- deletes or updates an existing row. Removed again by clear_oee_seed.sql.
--
-- Hard-codes USE MPP_MES_Dev (same convention as clear_demo.sql) -- sqlcmd -d
-- does NOT redirect it. Run with -I (filtered indexes on Lots.*):
--   sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/seed_oee_history.sql
--
-- @Commit = 0 (the committed default) runs EVERYTHING inside one transaction,
-- prints what it built and ROLLS BACK. Set @Commit = 1 in the working tree to
-- keep the rows -- never commit the file armed. Refuses to run twice: clear
-- first (clear_oee_seed.sql).
--
-- Range: the 28 days of CLOSED shifts ending at the last closed Oee.Shift.
-- Deterministic: every random choice is a hash of (location, shift, salt), so a
-- re-run after a clear rebuilds the same history.
--
-- What it writes, and how (the dashboard reads exactly these rows; see
-- Oee.ufn_ShiftAvailability / ufn_ShiftGood / ufn_ShiftScrap):
--   Oee.Shift             only shifts MISSING for an active schedule in the range
--                         (direct insert, ActualStart/ActualEnd = the schedule
--                         boundaries, Remarks 'OEESEED: ...'). Normally none --
--                         the gateway timer already wrote them.
--   Oee.DowntimeEvent     THROUGH THE PROCS (audit rows written):
--                         Oee.DowntimeEvent_RecordHistorical (timed entries; it
--                         resolves ShiftId itself) and
--                         Oee.DowntimeEvent_RecordApproximate (end-of-shift
--                         approximate entries, explicit @ShiftId). Mix of planned
--                         (IsExcused reasons), unplanned, a few with no reason,
--                         two bad days and a long press breakdown.
--   Lots.Lot (+ LotStatusHistory, LotGenealogyClosure self-row, LotMovement)
--                         DIRECT INSERT, historical timestamps, status Closed.
--                         Named 'OEESEED-...': one die-cast basket per press per
--                         production day, two FG trays per M&A line per shift
--                         stamped ShiftId + MintedPieceCount the way
--                         Assembly_CompleteTray v1.6 stamps them.
--   Workorder.DieCastContribution  DIRECT INSERT, one per press per shift.
--   Workorder.ProductionEvent      DIRECT INSERT, TrimOut checkpoints with a
--                         cumulative ShotCount per basket (trim good = delta).
--   Workorder.RejectEvent          DIRECT INSERT, ShiftId/ItemId/CellLocationId
--                         stamped: die cast, trim and M&A scrap charged to their
--                         own area, plus die-cast defects found at M&A.
--   Oee.ShiftSummary      refilled by Oee.ShiftSummary_RecomputeRange at the end.
-- The direct inserts skip LotCreated / reject audit rows: they are history, and
-- the procs stamp "now" and would decrement / validate live LOT state.
--
-- Tags (what clear_oee_seed.sql keys on): Remarks LIKE 'OEESEED%' on
-- DowntimeEvent / ProductionEvent / RejectEvent / Shift, and LotName LIKE
-- 'OEESEED-%' for LOTs (the LOT list; DieCastContribution hangs off them).
-- Attribution: AppUser SYS. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
USE MPP_MES_Dev;
GO

IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName LIKE N'OEESEED-%')
   OR EXISTS (SELECT 1 FROM Oee.DowntimeEvent WHERE Remarks LIKE N'OEESEED%')
BEGIN
    RAISERROR(N'OEE seed rows already present -- run sql/scratch/clear_oee_seed.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ============================================================
-- STEP 0: configuration (temp tables survive the GO batches)
-- ============================================================
DECLARE @Commit BIT = 0;   -- 0 = rehearse and roll back; 1 = keep (working tree only)

IF OBJECT_ID('tempdb..#Cfg') IS NOT NULL DROP TABLE #Cfg;
DECLARE @NowEt DATETIME2(3) = CAST(SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3));
DECLARE @ToEt  DATETIME2(3) = (SELECT MAX(ActualEnd) FROM Oee.Shift WHERE ActualEnd <= @NowEt);

SELECT @Commit                         AS [Commit],
       DATEADD(DAY, -28, @ToEt)         AS FromEt,
       @ToEt                           AS ToEt,
       (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS') AS SysUserId,
       (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured') AS ManufacturedId,
       (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Closed')       AS ClosedId,
       (SELECT TOP 1 ot.Id FROM Parts.OperationTemplate ot
          JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
         WHERE oty.Code = N'TrimOut' AND ot.PublishedAt IS NOT NULL AND ot.DeprecatedAt IS NULL
         ORDER BY ot.Id)               AS TrimOutTemplateId
INTO #Cfg;

IF EXISTS (SELECT 1 FROM #Cfg WHERE ToEt IS NULL OR SysUserId IS NULL OR ManufacturedId IS NULL
                                 OR ClosedId IS NULL OR TrimOutTemplateId IS NULL)
BEGIN
    RAISERROR(N'Missing config (closed shift, SYS user, Manufactured origin, Closed status or TrimOut template).', 16, 1);
    SET NOEXEC ON;
END

SELECT FromEt, ToEt, [Commit] FROM #Cfg;
GO

BEGIN TRANSACTION;
GO

-- ============================================================
-- STEP 1: Oee.Shift -- fill any shift missing for an active schedule.
-- Bitmask bit = weekday of the shift's START date, Mon = bit 0.
-- ============================================================
;WITH d AS (
    SELECT CAST(c.FromEt AS DATE) AS D FROM #Cfg c
    UNION ALL
    SELECT DATEADD(DAY, 1, d.D) FROM d CROSS JOIN #Cfg c WHERE d.D < CAST(c.ToEt AS DATE)
)
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT ss.Id, w.S, w.E, N'OEESEED: shift backfilled by seed_oee_history.sql'
FROM d
CROSS JOIN Oee.ShiftSchedule ss
CROSS JOIN #Cfg c
CROSS APPLY (SELECT
    DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME), ss.StartTime), CAST(d.D AS DATETIME2(3))) AS S,
    DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME), ss.EndTime),
            CAST(DATEADD(DAY, CASE WHEN ss.EndTime <= ss.StartTime THEN 1 ELSE 0 END, d.D) AS DATETIME2(3))) AS E) w
WHERE ss.DeprecatedAt IS NULL
  AND ss.EffectiveFrom <= d.D
  AND (ss.DaysOfWeekBitmask & POWER(2, DATEDIFF(DAY, '19000101', d.D) % 7)) <> 0
  AND w.S >= c.FromEt AND w.E <= c.ToEt
  AND NOT EXISTS (SELECT 1 FROM Oee.Shift s WHERE s.ShiftScheduleId = ss.Id AND s.ActualStart = w.S)
OPTION (MAXRECURSION 100);
PRINT CONCAT(N'Shifts backfilled: ', @@ROWCOUNT);

-- Shifts in range. ProdDay: the 23:00 third shift belongs to the next day.
IF OBJECT_ID('tempdb..#S') IS NOT NULL DROP TABLE #S;
SELECT s.Id AS ShiftId,
       s.ActualStart AS StartEt,
       s.ActualEnd   AS EndEt,
       CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc,
       CAST(s.ActualEnd   AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS EndUtc,
       DATEDIFF(MINUTE, s.ActualStart, s.ActualEnd) AS Mins,
       CAST(DATEADD(HOUR, 2, s.ActualStart) AS DATE) AS ProdDay,
       DATEDIFF(DAY, '19000101', CAST(DATEADD(HOUR, 2, s.ActualStart) AS DATE)) % 7 AS Dow,   -- 0 = Mon
       CASE WHEN DATEPART(HOUR, s.ActualStart) >= 22 OR DATEPART(HOUR, s.ActualStart) < 5 THEN 3
            WHEN DATEPART(HOUR, s.ActualStart) >= 13 THEN 2 ELSE 1 END AS ShiftNo,
       CAST(0 AS INT) AS BadKind
INTO #S
FROM Oee.Shift s
CROSS JOIN #Cfg c
WHERE s.ActualStart >= c.FromEt AND s.ActualEnd IS NOT NULL AND s.ActualEnd <= c.ToEt;

-- Bad days: a plant-wide rough Thursday about 2.5 weeks back (BadKind 1), and die cast
-- furnace trouble with M&A starved on the Wednesday inside the last 7 days (BadKind 2),
-- so the default dashboard window has one.
DECLARE @To DATE = (SELECT CAST(ToEt AS DATE) FROM #Cfg);
DECLARE @X1 DATE = DATEADD(DAY, -18, @To), @X2 DATE = DATEADD(DAY, -6, @To);
DECLARE @Bad1 DATE = DATEADD(DAY, -((DATEDIFF(DAY, '19000101', @X1) % 7 - 3 + 7) % 7), @X1);
DECLARE @Bad2 DATE = DATEADD(DAY, -((DATEDIFF(DAY, '19000101', @X2) % 7 - 2 + 7) % 7), @X2);
UPDATE #S SET BadKind = CASE WHEN ProdDay = @Bad1 THEN 1 WHEN ProdDay = @Bad2 THEN 2 ELSE 0 END;
PRINT CONCAT(N'Bad days: ', CONVERT(NVARCHAR(10), @Bad1, 120), N' (plant-wide), ', CONVERT(NVARCHAR(10), @Bad2, 120), N' (die cast furnace)');

-- ============================================================
-- STEP 2: OEE units, their health and run pattern
-- ============================================================
IF OBJECT_ID('tempdb..#U') IS NOT NULL DROP TABLE #U;
SELECT e.LocationId, e.Code, af.AreaFamily AS Family,
       CAST(NULL AS BIGINT) AS ParentUnitId,
       CAST(0 AS BIT)       AS IsRollup,
       l.ParentLocationId,
       CAST(0 AS DECIMAL(9,4)) AS Health,
       CAST(0 AS INT)          AS Rate
INTO #U
FROM Oee.ufn_ResolveOeeEquipment() e
CROSS APPLY Oee.ufn_AreaFamily(e.LocationId) af
INNER JOIN Location.Location l ON l.Id = e.LocationId
WHERE af.AreaFamily IS NOT NULL
  AND e.Name NOT LIKE N'%(Future)%';

UPDATE u SET ParentUnitId = p.AncestorLocationId
FROM #U u
CROSS APPLY (SELECT TOP 1 a.AncestorLocationId FROM Oee.ufn_OeeAncestors(u.LocationId) a
             WHERE a.AncestorLocationId <> u.LocationId ORDER BY a.Distance) p;
UPDATE u SET IsRollup = 1 FROM #U u WHERE EXISTS (SELECT 1 FROM #U c WHERE c.ParentUnitId = u.LocationId);

UPDATE u SET
    Health = CASE u.Code WHEN N'DC1-M04'     THEN 0.55
                         WHEN N'MA2-RPYCAM2' THEN 0.50
                         WHEN N'TRIM1-P02'   THEN 0.60
                         WHEN N'MA1-5GOR'    THEN 0.65
                         ELSE 0.78 + r.r1 * 0.22 END,
    Rate   = CASE u.Family WHEN N'diecast' THEN 520 + CAST(r.r2 * 320 AS INT)
                           WHEN N'ma'      THEN 300 + CAST(r.r2 * 300 AS INT)
                           ELSE 0 END
FROM #U u
CROSS APPLY (SELECT CAST(CAST(SUBSTRING(h.h, 1, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r1,
                    CAST(CAST(SUBSTRING(h.h, 5, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r2
             FROM (SELECT HASHBYTES('SHA2_256', CONCAT(N'unit|', u.LocationId)) AS h) h) r;

-- Active unit-shifts. A station runs when its line runs (keyed on the line).
IF OBJECT_ID('tempdb..#Run') IS NOT NULL DROP TABLE #Run;
SELECT s.ShiftId, u.LocationId
INTO #Run
FROM #S s
CROSS JOIN #U u
CROSS APPLY (SELECT CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT(N'run|', COALESCE(u.ParentUnitId, u.LocationId), N'|', s.ShiftId)), 1, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r) r
CROSS APPLY (SELECT CASE WHEN s.Dow = 6 THEN 0.12
                         WHEN s.Dow = 5 THEN 0.45
                         WHEN s.ShiftNo = 3 THEN 0.70
                         ELSE 0.92 END
                    * CASE WHEN u.Code LIKE N'OS-%' THEN 0.65 ELSE 1 END AS P) p
WHERE r.r < p.P;

-- ============================================================
-- STEP 3: downtime plan, then record it through the procs
-- ============================================================
IF OBJECT_ID('tempdb..#Reason') IS NOT NULL DROP TABLE #Reason;
SELECT v.Family, v.IsPlanned, v.Wt, rc.Id AS ReasonId,
       ROW_NUMBER() OVER (PARTITION BY v.Family, v.IsPlanned ORDER BY v.Wt DESC, rc.Id) AS Rn
INTO #Reason
FROM (VALUES
    -- die cast, unplanned (Pareto order by weight)
    (N'diecast', 0, 9, N'DC-0049'), (N'diecast', 0, 8, N'DC-0072'), (N'diecast', 0, 7, N'DC-0042'),
    (N'diecast', 0, 6, N'DC-0021'), (N'diecast', 0, 5, N'DC-0078'), (N'diecast', 0, 4, N'DC-0069'),
    (N'diecast', 0, 3, N'DC-0008'), (N'diecast', 0, 2, N'DC-0079'), (N'diecast', 0, 1, N'DC-0012'),
    -- die cast, planned
    (N'diecast', 1, 5, N'DC-0043'), (N'diecast', 1, 4, N'DC-0057'), (N'diecast', 1, 3, N'DC-0046'),
    (N'diecast', 1, 2, N'DC-0017'), (N'diecast', 1, 1, N'DC-0058'),
    -- trim, unplanned
    (N'trim', 0, 7, N'TS-0219'), (N'trim', 0, 6, N'TS-0209'), (N'trim', 0, 5, N'TS-0212'),
    (N'trim', 0, 4, N'TS-0206'), (N'trim', 0, 3, N'TS-0217'), (N'trim', 0, 2, N'TS-0214'),
    (N'trim', 0, 1, N'TS-0208'),
    -- trim, planned
    (N'trim', 1, 2, N'TS-0229'), (N'trim', 1, 1, N'TS-0230'),
    -- machining & assembly, unplanned
    (N'ma', 0, 10, N'MS-0413'), (N'ma', 0, 9, N'MS-0460'), (N'ma', 0, 8, N'MS-0461'),
    (N'ma', 0, 7, N'MS-0430'), (N'ma', 0, 6, N'MS-0478'), (N'ma', 0, 5, N'MS-0402'),
    (N'ma', 0, 4, N'MS-0404'), (N'ma', 0, 3, N'MS-0428'), (N'ma', 0, 2, N'MS-0518'),
    (N'ma', 0, 1, N'MS-0657'),
    -- machining & assembly, planned
    (N'ma', 1, 5, N'MS-0435'), (N'ma', 1, 4, N'MS-0437'), (N'ma', 1, 3, N'MS-0475'),
    (N'ma', 1, 2, N'MS-0432'), (N'ma', 1, 1, N'MS-0471')
) v (Family, IsPlanned, Wt, Code)
INNER JOIN Oee.DowntimeReasonCode rc ON rc.Code = v.Code AND rc.DeprecatedAt IS NULL
WHERE rc.IsExcused = v.IsPlanned;   -- a code whose excused flag changed is dropped, never mis-classed

IF OBJECT_ID('tempdb..#Dt') IS NOT NULL DROP TABLE #Dt;
CREATE TABLE #Dt (
    LocationId BIGINT NOT NULL, ShiftId BIGINT NOT NULL, K INT NOT NULL,
    IsPlanned BIT NOT NULL, IsApprox BIT NOT NULL, NoReason BIT NOT NULL,
    StartEt DATETIME2(3) NULL, Dur INT NOT NULL, ReasonId BIGINT NULL,
    Remarks NVARCHAR(500) NOT NULL);

-- k = 1 planned, k = 2..5 unplanned. Slot k occupies [start + (k-1)*80, +80) so entries never overlap.
INSERT INTO #Dt (LocationId, ShiftId, K, IsPlanned, IsApprox, NoReason, StartEt, Dur, ReasonId, Remarks)
SELECT x.LocationId, x.ShiftId, x.K, x.IsPlanned, x.IsApprox, x.NoReason,
       DATEADD(MINUTE, (x.K - 1) * 80 + 3 + CAST(x.rS * (74 - x.Dur) AS INT), x.StartEt),
       x.Dur, x.ReasonId,
       CASE WHEN x.IsApprox = 1 THEN N'OEESEED: approximate, entered at end of shift'
            WHEN x.NoReason = 1 THEN N'OEESEED: reason not entered'
            ELSE N'OEESEED: historical entry' END
FROM (
    SELECT u.LocationId, s.ShiftId, k.K, s.StartEt,
           CAST(CASE WHEN k.K = 1 THEN 1 ELSE 0 END AS BIT) AS IsPlanned,
           CAST(CASE WHEN r.rA < 0.12 THEN 1 ELSE 0 END AS BIT) AS IsApprox,
           CAST(CASE WHEN k.K > 1 AND r.rN < 0.035 THEN 1 ELSE 0 END AS BIT) AS NoReason,
           r.rS,
           CASE WHEN k.K = 1 THEN 15 + CAST(r.rD * 30 AS INT)
                ELSE CASE WHEN d.D > 70 THEN 70 ELSE d.D END END AS Dur,
           CASE WHEN k.K > 1 AND r.rN < 0.035 THEN NULL ELSE rs.ReasonId END AS ReasonId,
           CASE WHEN k.K = 1 THEN CASE WHEN r.rP < 0.55 THEN 1 ELSE 0 END
                ELSE CASE WHEN r.rP < p.P / (k.K - 1) THEN 1 ELSE 0 END END AS Keep
    FROM #Run rn
    INNER JOIN #S s ON s.ShiftId = rn.ShiftId
    INNER JOIN #U u ON u.LocationId = rn.LocationId AND u.IsRollup = 0
    CROSS JOIN (VALUES (1), (2), (3), (4), (5)) k (K)
    CROSS APPLY (SELECT HASHBYTES('SHA2_256', CONCAT(N'dt|', u.LocationId, N'|', s.ShiftId, N'|', k.K)) AS h) hh
    CROSS APPLY (SELECT CAST(CAST(SUBSTRING(hh.h,  1, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS rP,
                        CAST(CAST(SUBSTRING(hh.h,  5, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS rD,
                        CAST(CAST(SUBSTRING(hh.h,  9, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS rS,
                        CAST(CAST(SUBSTRING(hh.h, 13, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS rA,
                        CAST(CAST(SUBSTRING(hh.h, 17, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS rN,
                        CAST(CAST(SUBSTRING(hh.h, 21, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS rR) r
    -- day-to-day swing per area (0.6x .. 1.5x), so the trend bars are not flat
    CROSS APPLY (SELECT CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT(N'day|', u.Family, N'|', s.ProdDay)), 1, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r) dd
    CROSS APPLY (SELECT CASE WHEN s.BadKind = 1 THEN 2.2 ELSE 1.0 END * (0.6 + dd.r * 0.9) AS M) bm
    CROSS APPLY (SELECT CASE WHEN ((1 - u.Health) * 1.6 + 0.30) * bm.M > 0.95 THEN 0.95
                             ELSE ((1 - u.Health) * 1.6 + 0.30) * bm.M END AS P) p
    CROSS APPLY (SELECT CAST((4 + r.rD * (16 + (1 - u.Health) * 70)) * CASE WHEN s.BadKind = 1 THEN 1.6 ELSE 1 END AS INT) AS D) d
    CROSS APPLY (SELECT COUNT(*) AS N FROM #Reason rr
                 WHERE rr.Family = u.Family AND rr.IsPlanned = CASE WHEN k.K = 1 THEN 1 ELSE 0 END) rcnt
    OUTER APPLY (SELECT rr.ReasonId FROM #Reason rr
                 WHERE rr.Family = u.Family AND rr.IsPlanned = CASE WHEN k.K = 1 THEN 1 ELSE 0 END
                   AND rr.Rn = 1 + CAST(FLOOR(POWER(CAST(r.rR AS FLOAT), 1.8) * rcnt.N) AS INT)) rs
) x
WHERE x.Keep = 1;

-- Bad day 2: die cast furnace trouble on 1st + 2nd shift (one long entry per running press,
-- replacing that shift's unplanned slots), and M&A lines starved of castings on 2nd shift.
DELETE d FROM #Dt d
INNER JOIN #S s ON s.ShiftId = d.ShiftId
INNER JOIN #U u ON u.LocationId = d.LocationId
WHERE s.BadKind = 2 AND d.IsPlanned = 0
  AND ((u.Family = N'diecast' AND s.ShiftNo IN (1, 2)) OR (u.Family = N'ma' AND s.ShiftNo = 2));

INSERT INTO #Dt (LocationId, ShiftId, K, IsPlanned, IsApprox, NoReason, StartEt, Dur, ReasonId, Remarks)
SELECT rn.LocationId, rn.ShiftId, 6, 0, 0, 0,
       DATEADD(MINUTE, 95, s.StartEt),
       CASE WHEN u.Family = N'diecast' THEN 150 + CAST(r.r * 110 AS INT) ELSE 90 + CAST(r.r * 120 AS INT) END,
       (SELECT Id FROM Oee.DowntimeReasonCode
         WHERE Code = CASE WHEN u.Family = N'diecast' THEN N'DC-0012' ELSE N'MS-0657' END AND DeprecatedAt IS NULL),
       N'OEESEED: historical entry (bad day)'
FROM #Run rn
INNER JOIN #S s ON s.ShiftId = rn.ShiftId
INNER JOIN #U u ON u.LocationId = rn.LocationId AND u.IsRollup = 0
CROSS APPLY (SELECT CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT(N'bad2|', u.LocationId, N'|', s.ShiftId)), 1, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r) r
WHERE s.BadKind = 2
  AND ((u.Family = N'diecast' AND s.ShiftNo IN (1, 2)) OR (u.Family = N'ma' AND s.ShiftNo = 2 AND r.r < 0.6));

-- DC1-M04: a hydraulic failure that takes most of one first shift, 12 days back.
DECLARE @LongDay DATE = DATEADD(DAY, -12, (SELECT CAST(ToEt AS DATE) FROM #Cfg));
DELETE d FROM #Dt d
INNER JOIN #S s ON s.ShiftId = d.ShiftId
INNER JOIN #U u ON u.LocationId = d.LocationId
WHERE u.Code = N'DC1-M04' AND s.ProdDay = @LongDay AND s.ShiftNo = 1;
INSERT INTO #Dt (LocationId, ShiftId, K, IsPlanned, IsApprox, NoReason, StartEt, Dur, ReasonId, Remarks)
SELECT u.LocationId, s.ShiftId, 7, 0, 0, 0, DATEADD(MINUTE, 70, s.StartEt), 330,
       (SELECT Id FROM Oee.DowntimeReasonCode WHERE Code = N'DC-0069' AND DeprecatedAt IS NULL),
       N'OEESEED: historical entry (press breakdown)'
FROM #S s CROSS JOIN #U u
WHERE u.Code = N'DC1-M04' AND s.ProdDay = @LongDay AND s.ShiftNo = 1;
-- the breakdown is why the press "runs" that shift at all
INSERT INTO #Run (ShiftId, LocationId)
SELECT DISTINCT d.ShiftId, d.LocationId FROM #Dt d
WHERE d.K = 7 AND NOT EXISTS (SELECT 1 FROM #Run r WHERE r.ShiftId = d.ShiftId AND r.LocationId = d.LocationId);

SELECT u.Family, COUNT(*) AS Entries,
       SUM(CASE WHEN d.IsPlanned = 1 THEN 1 ELSE 0 END) AS Planned,
       SUM(CASE WHEN d.IsApprox = 1 THEN 1 ELSE 0 END) AS Approx,
       SUM(CASE WHEN d.NoReason = 1 THEN 1 ELSE 0 END) AS NoReason,
       SUM(d.Dur) AS Minutes
FROM #Dt d INNER JOIN #U u ON u.LocationId = d.LocationId
GROUP BY u.Family;
GO

-- Record each entry through its proc (status rows captured, never shown).
IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);

DECLARE @User BIGINT = (SELECT SysUserId FROM #Cfg);
DECLARE @Loc BIGINT, @Sh BIGINT, @S DATETIME2(3), @E DATETIME2(3), @Dur INT, @Rc BIGINT, @Ap BIT, @Rm NVARCHAR(500);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT LocationId, ShiftId, StartEt, DATEADD(MINUTE, Dur, StartEt), Dur, ReasonId, IsApprox, Remarks
    FROM #Dt ORDER BY ShiftId, LocationId, K;
OPEN c;
FETCH NEXT FROM c INTO @Loc, @Sh, @S, @E, @Dur, @Rc, @Ap, @Rm;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @Ap = 1
        INSERT INTO #R (Status, Message, NewId)
        EXEC Oee.DowntimeEvent_RecordApproximate
            @ScopeLocationId = @Loc, @DurationMinutes = @Dur, @ShiftId = @Sh,
            @DowntimeReasonCodeId = @Rc, @Remarks = @Rm, @AppUserId = @User, @TerminalLocationId = NULL;
    ELSE
        INSERT INTO #R (Status, Message, NewId)
        EXEC Oee.DowntimeEvent_RecordHistorical
            @ScopeLocationId = @Loc, @StartedAtEt = @S, @EndedAtEt = @E,
            @DowntimeReasonCodeId = @Rc, @Remarks = @Rm, @AppUserId = @User, @TerminalLocationId = NULL;
    FETCH NEXT FROM c INTO @Loc, @Sh, @S, @E, @Dur, @Rc, @Ap, @Rm;
END
CLOSE c; DEALLOCATE c;

SELECT Status, COUNT(*) AS Calls, MIN(Message) AS SampleMessage FROM #R GROUP BY Status;
IF EXISTS (SELECT 1 FROM #R WHERE Status = 0)
BEGIN
    RAISERROR(N'A downtime proc refused an entry -- see the status summary above.', 16, 1);
    SET NOEXEC ON;
END
-- every seeded entry must carry the shift it was planned for (RecordHistorical resolves its own)
IF EXISTS (SELECT 1 FROM Oee.DowntimeEvent de
           INNER JOIN #R r ON r.NewId = de.Id
           WHERE de.ShiftId IS NULL)
BEGIN
    RAISERROR(N'A seeded downtime entry resolved no shift.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ============================================================
-- STEP 4: good and scrap (direct inserts -- history)
-- ============================================================
-- Downtime minutes per unit-shift (a line with stations takes its stations' average).
IF OBJECT_ID('tempdb..#DtMin') IS NOT NULL DROP TABLE #DtMin;
SELECT COALESCE(u.ParentUnitId, u.LocationId) AS UnitId, d.ShiftId,
       SUM(d.Dur) * 1.0 / COUNT(DISTINCT d.LocationId) AS Minutes
INTO #DtMin
FROM #Dt d INNER JOIN #U u ON u.LocationId = d.LocationId
WHERE u.ParentUnitId IS NULL OR EXISTS (SELECT 1 FROM #U p WHERE p.LocationId = u.ParentUnitId AND p.IsRollup = 1)
GROUP BY COALESCE(u.ParentUnitId, u.LocationId), d.ShiftId;

-- Per producing unit-shift: run fraction and the per-shift randoms.
IF OBJECT_ID('tempdb..#P') IS NOT NULL DROP TABLE #P;
SELECT rn.ShiftId, u.LocationId, u.Code, u.Family, u.Health, u.Rate, u.ParentLocationId,
       s.StartUtc, s.EndUtc, s.ProdDay, s.BadKind,
       CASE WHEN (s.Mins - ISNULL(m.Minutes, 0)) / s.Mins < 0 THEN 0
            ELSE (s.Mins - ISNULL(m.Minutes, 0)) * 1.0 / s.Mins END AS RunFrac,
       r.r1, r.r2, r.r3, r.r4
INTO #P
FROM #Run rn
INNER JOIN #S s ON s.ShiftId = rn.ShiftId
INNER JOIN #U u ON u.LocationId = rn.LocationId AND u.ParentUnitId IS NULL
LEFT  JOIN #DtMin m ON m.UnitId = u.LocationId AND m.ShiftId = rn.ShiftId
CROSS APPLY (SELECT HASHBYTES('SHA2_256', CONCAT(N'prod|', u.LocationId, N'|', s.ShiftId)) AS h) hh
CROSS APPLY (SELECT CAST(CAST(SUBSTRING(hh.h,  1, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r1,
                    CAST(CAST(SUBSTRING(hh.h,  5, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r2,
                    CAST(CAST(SUBSTRING(hh.h,  9, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r3,
                    CAST(CAST(SUBSTRING(hh.h, 13, 4) AS BIGINT) % 10000 AS DECIMAL(9,4)) / 10000 AS r4) r;

-- Defect codes per (found family, charged-to), resolved from config at run time.
IF OBJECT_ID('tempdb..#Def') IS NOT NULL DROP TABLE #Def;
SELECT v.Kind, dc.Id AS DefectCodeId,
       ROW_NUMBER() OVER (PARTITION BY v.Kind ORDER BY dc.Id) AS Rn,
       COUNT(*) OVER (PARTITION BY v.Kind) AS N
INTO #Def
FROM (VALUES (N'diecast', N'DieCast', N'DieCast'),
             (N'trim',    N'Trim',    N'TrimShop'),
             (N'ma',      N'MachiningAssembly', N'MachineShop'),
             (N'ma-dc',   N'MachiningAssembly', N'DieCast')) v (Kind, CategoryCode, PartyCode)
INNER JOIN Parts.OperationCategory oc ON oc.Code = v.CategoryCode
INNER JOIN Quality.ChargeToParty  cp ON cp.Code = v.PartyCode
INNER JOIN Quality.DefectCode     dc ON dc.OperationCategoryId = oc.Id AND dc.ChargeToPartyId = cp.Id
WHERE dc.DeprecatedAt IS NULL AND dc.IsExcused = 0 AND dc.IsNonRejectScrap = 0;
DELETE FROM #Def WHERE Rn > 8;
UPDATE #Def SET N = CASE WHEN N > 8 THEN 8 ELSE N END;

-- ---- 4a. Die cast: casting part per press, one basket LOT per press per production day ----
IF OBJECT_ID('tempdb..#PressItem') IS NOT NULL DROP TABLE #PressItem;
SELECT u.LocationId,
       COALESCE(
           (SELECT TOP 1 tc.ItemId FROM Tools.ToolAssignment ta
              JOIN Tools.ToolCavity tc ON tc.ToolId = ta.ToolId AND tc.DeprecatedAt IS NULL
             WHERE ta.CellLocationId = u.LocationId AND ta.ReleasedAt IS NULL ORDER BY tc.Id),
           el.ItemId) AS ItemId
INTO #PressItem
FROM #U u
-- mounted die's first cavity part, else a part eligible at the press's area (DC1's list when the area has none)
OUTER APPLY (SELECT TOP 1 x.ItemId FROM (
    SELECT il.ItemId, ROW_NUMBER() OVER (ORDER BY il.ItemId) AS Rn, COUNT(*) OVER () AS N
    FROM Parts.ItemLocation il
    JOIN Parts.Item i      ON i.Id = il.ItemId AND i.DeprecatedAt IS NULL
    JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'Component'
    WHERE il.DeprecatedAt IS NULL
      AND il.LocationId = CASE WHEN EXISTS (SELECT 1 FROM Parts.ItemLocation x WHERE x.LocationId = u.ParentLocationId AND x.DeprecatedAt IS NULL)
                               THEN u.ParentLocationId
                               ELSE (SELECT Id FROM Location.Location WHERE Code = N'DC1') END) x
    WHERE x.Rn = 1 + (u.LocationId * 7) % x.N) el
WHERE u.Family = N'diecast';

IF OBJECT_ID('tempdb..#DcGood') IS NOT NULL DROP TABLE #DcGood;
SELECT p.ShiftId, p.LocationId, p.Code, p.ProdDay, p.StartUtc, p.EndUtc, p.Health, p.BadKind, p.r3, p.r4,
       pi.ItemId,
       CAST(ROUND(p.Rate * p.RunFrac * (0.92 + p.r1 * 0.08), 0) AS INT) AS Good,
       CAST(ROUND(p.Rate * p.RunFrac * (0.92 + p.r1 * 0.08)
                  * (0.012 + (1 - p.Health) * 0.09 + CASE WHEN p.BadKind > 0 THEN 0.02 ELSE 0 END)
                  * (0.5 + p.r2), 0) AS INT) AS Scrap
INTO #DcGood
FROM #P p
INNER JOIN #PressItem pi ON pi.LocationId = p.LocationId
WHERE p.Family = N'diecast' AND pi.ItemId IS NOT NULL;

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId,
                      TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt,
                      CastDate, ProducedAtLocationId)
SELECT N'OEESEED-' + g.Code + N'-' + CONVERT(NVARCHAR(8), g.ProdDay, 112),
       MIN(g.ItemId), c.ManufacturedId, c.ClosedId, SUM(g.Good), g.LocationId,
       0, 0, c.SysUserId, NULL, DATEADD(MINUTE, 10, MIN(g.StartUtc)),
       g.ProdDay, g.LocationId
FROM #DcGood g CROSS JOIN #Cfg c
GROUP BY g.Code, g.ProdDay, g.LocationId, c.ManufacturedId, c.ClosedId, c.SysUserId;
PRINT CONCAT(N'Die cast basket LOTs: ', @@ROWCOUNT);

UPDATE g SET g.ItemId = l.ItemId FROM #DcGood g
INNER JOIN Lots.Lot l ON l.LotName = N'OEESEED-' + g.Code + N'-' + CONVERT(NVARCHAR(8), g.ProdDay, 112);

INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId)
SELECT l.Id, g.ShiftId, g.Good, c.SysUserId, NULL, DATEADD(MINUTE, -5, g.EndUtc), g.LocationId
FROM #DcGood g CROSS JOIN #Cfg c
INNER JOIN Lots.Lot l ON l.LotName = N'OEESEED-' + g.Code + N'-' + CONVERT(NVARCHAR(8), g.ProdDay, 112)
WHERE g.Good > 0;
PRINT CONCAT(N'Die cast contributions: ', @@ROWCOUNT);

-- die cast scrap: one or two reject rows per press-shift
INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt,
                                   ItemId, ShiftId, CellLocationId)
SELECT l.Id, df.DefectCodeId, q.Qty, N'OEESEED: historical reject', c.SysUserId,
       DATEADD(MINUTE, -20 - part.N * 90, g.EndUtc), g.ItemId, g.ShiftId, g.LocationId
FROM #DcGood g CROSS JOIN #Cfg c
INNER JOIN Lots.Lot l ON l.LotName = N'OEESEED-' + g.Code + N'-' + CONVERT(NVARCHAR(8), g.ProdDay, 112)
CROSS JOIN (VALUES (0), (1)) part (N)
CROSS APPLY (SELECT CASE WHEN part.N = 0 THEN g.Scrap - g.Scrap / 3 ELSE g.Scrap / 3 END AS Qty) q
CROSS APPLY (SELECT TOP 1 d.DefectCodeId FROM #Def d
             WHERE d.Kind = N'diecast'
               AND d.Rn = 1 + CAST(FLOOR(POWER(CAST(CASE WHEN part.N = 0 THEN g.r3 ELSE g.r4 END AS FLOAT), 1.6) * d.N) AS INT)) df
WHERE q.Qty > 0;
PRINT CONCAT(N'Die cast rejects: ', @@ROWCOUNT);

-- ---- 4b. Trim: each basket is trimmed the shift it was cast, on its press's trim press ----
IF OBJECT_ID('tempdb..#TrimMap') IS NOT NULL DROP TABLE #TrimMap;
SELECT dc.LocationId AS PressId, tp.LocationId AS TrimId
INTO #TrimMap
FROM #U dc
INNER JOIN Location.Location area ON area.Id = dc.ParentLocationId
CROSS APPLY (
    SELECT t.LocationId, ROW_NUMBER() OVER (ORDER BY t.LocationId) AS Rn, COUNT(*) OVER () AS N
    FROM #U t
    WHERE t.Family = N'trim'
      AND t.Code IN (SELECT v.C FROM (VALUES
            (N'DC1', N'TRIM1-P01'), (N'DC1', N'TRIM1-P02'),
            (N'DC2', N'TRIM2-P01'), (N'DC2', N'TRIM2-P02'), (N'DC2', N'TRIM2-P03'),
            (N'DC3', N'TRIM2-P01'), (N'DC3', N'TRIM2-P02'), (N'DC3', N'TRIM2-P03'),
            (N'DC4', N'T1-6MA-DB')) v (A, C) WHERE v.A = area.Code)
) tp
WHERE dc.Family = N'diecast' AND tp.Rn = 1 + dc.LocationId % tp.N;

IF OBJECT_ID('tempdb..#TrimGood') IS NOT NULL DROP TABLE #TrimGood;
-- Checkpoints and rejects are booked at the SHOP's terminal, as the trim terminals do: a trim
-- press carries no good or scrap (D5) -- trim quality is the shop's AreaPlacement row. The press
-- still gates whether the basket was trimmed that shift and how much (its downtime).
SELECT g.ShiftId, g.LocationId AS PressId, tm.TrimId, g.Code, g.ProdDay, g.ItemId, g.StartUtc, g.EndUtc,
       (SELECT TOP 1 t.Id FROM Location.Location t
          JOIN Location.LocationTypeDefinition d ON d.Id = t.LocationTypeDefinitionId AND d.Code = N'Terminal'
          JOIN Location.Location pr ON pr.Id = tm.TrimId
         WHERE t.ParentLocationId = pr.ParentLocationId AND t.DeprecatedAt IS NULL
         ORDER BY t.Id) AS ShopTerminalId,
       tp.Health, tp.r3, tp.RunFrac,
       CAST(ROUND(g.Good * (0.55 + 0.45 * tp.RunFrac), 0) AS INT) AS Good,
       CAST(ROUND(g.Good * (0.55 + 0.45 * tp.RunFrac) * (0.003 + (1 - tp.Health) * 0.035) * (0.5 + tp.r2), 0) AS INT) AS Scrap
INTO #TrimGood
FROM #DcGood g
INNER JOIN #TrimMap tm ON tm.PressId = g.LocationId
INNER JOIN #P tp ON tp.LocationId = tm.TrimId AND tp.ShiftId = g.ShiftId   -- the trim press ran that shift
WHERE g.Good > 0;
DELETE FROM #TrimGood WHERE ShopTerminalId IS NULL;

INSERT INTO Workorder.ProductionEvent (LotId, OperationTemplateId, EventAt, ShotCount, AppUserId, TerminalLocationId, Remarks, ShiftId)
SELECT l.Id, c.TrimOutTemplateId, DATEADD(MINUTE, -3, t.EndUtc),
       SUM(t.Good) OVER (PARTITION BY l.Id ORDER BY t.StartUtc ROWS UNBOUNDED PRECEDING),
       c.SysUserId, t.ShopTerminalId, N'OEESEED: historical trim checkpoint', t.ShiftId
FROM #TrimGood t CROSS JOIN #Cfg c
INNER JOIN Lots.Lot l ON l.LotName = N'OEESEED-' + t.Code + N'-' + CONVERT(NVARCHAR(8), t.ProdDay, 112);
PRINT CONCAT(N'Trim checkpoints: ', @@ROWCOUNT);

INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt,
                                   ItemId, ShiftId, CellLocationId)
SELECT l.Id, df.DefectCodeId, t.Scrap, N'OEESEED: historical reject', c.SysUserId,
       DATEADD(MINUTE, -15, t.EndUtc), t.ItemId, t.ShiftId, t.ShopTerminalId
FROM #TrimGood t CROSS JOIN #Cfg c
INNER JOIN Lots.Lot l ON l.LotName = N'OEESEED-' + t.Code + N'-' + CONVERT(NVARCHAR(8), t.ProdDay, 112)
CROSS APPLY (SELECT TOP 1 d.DefectCodeId FROM #Def d
             WHERE d.Kind = N'trim' AND d.Rn = 1 + CAST(FLOOR(POWER(CAST(t.r3 AS FLOAT), 1.6) * d.N) AS INT)) df
WHERE t.Scrap > 0;
PRINT CONCAT(N'Trim rejects: ', @@ROWCOUNT);

-- ---- 4c. Machining & Assembly: two FG trays per running line per shift ----
IF OBJECT_ID('tempdb..#LineFg') IS NOT NULL DROP TABLE #LineFg;
SELECT u.LocationId,
       x.ItemId,
       COALESCE((SELECT TOP 1 t.Id FROM Location.Location t
                  WHERE t.ParentLocationId = u.LocationId AND t.DeprecatedAt IS NULL
                    AND (t.Code LIKE N'%AOUT%' OR t.Code LIKE N'%ASER%')
                  ORDER BY t.Id), u.LocationId) AS MintTerminalId
INTO #LineFg
FROM #U u
CROSS APPLY (SELECT TOP 1 f.ItemId FROM (
    SELECT il.ItemId, ROW_NUMBER() OVER (ORDER BY il.ItemId) AS Rn, COUNT(*) OVER () AS N
    FROM Parts.ItemLocation il
    JOIN Parts.Item i      ON i.Id = il.ItemId AND i.DeprecatedAt IS NULL
    JOIN Parts.ItemType it ON it.Id = i.ItemTypeId AND it.Code = N'FinishedGood'
    WHERE il.LocationId = u.LocationId AND il.DeprecatedAt IS NULL) f
    WHERE f.Rn = 1 + u.LocationId % f.N) x
WHERE u.Family = N'ma' AND u.ParentUnitId IS NULL;

IF OBJECT_ID('tempdb..#MaGood') IS NOT NULL DROP TABLE #MaGood;
SELECT p.ShiftId, p.LocationId, p.Code, p.StartUtc, p.EndUtc, p.BadKind, p.r3, p.r4,
       lf.ItemId, lf.MintTerminalId,
       CAST(ROUND(p.Rate * p.RunFrac * (0.90 + p.r1 * 0.10), 0) AS INT) AS Good,
       CAST(ROUND(p.Rate * p.RunFrac * (0.90 + p.r1 * 0.10)
                  * (0.004 + (1 - p.Health) * 0.05 + CASE WHEN p.BadKind = 1 THEN 0.015 ELSE 0 END)
                  * (0.5 + p.r2), 0) AS INT) AS Scrap,
       CAST(CASE WHEN p.r4 < 0.35 THEN ROUND(p.Rate * p.RunFrac * 0.006 * (0.5 + p.r3), 0) ELSE 0 END AS INT) AS DcFound
INTO #MaGood
FROM #P p
INNER JOIN #LineFg lf ON lf.LocationId = p.LocationId
WHERE p.Family = N'ma';

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId,
                      TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAtTerminalId, CreatedAt,
                      ShiftId, MintedPieceCount)
SELECT N'OEESEED-' + g.Code + N'-' + CAST(g.ShiftId AS NVARCHAR(20)) + N'-' + CAST(t.N AS NVARCHAR(1)),
       g.ItemId, c.ManufacturedId, c.ClosedId, q.Qty, g.LocationId,
       0, 0, c.SysUserId, g.MintTerminalId, DATEADD(MINUTE, 200 * t.N, g.StartUtc),
       g.ShiftId, q.Qty
FROM #MaGood g CROSS JOIN #Cfg c
CROSS JOIN (VALUES (1), (2)) t (N)
CROSS APPLY (SELECT CASE WHEN t.N = 1 THEN g.Good - g.Good * 45 / 100 ELSE g.Good * 45 / 100 END AS Qty) q
WHERE q.Qty > 0;
PRINT CONCAT(N'FG tray LOTs: ', @@ROWCOUNT);

INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt,
                                   ItemId, ShiftId, CellLocationId)
SELECT l.Id, df.DefectCodeId, q.Qty, N'OEESEED: historical reject', c.SysUserId,
       DATEADD(MINUTE, -25 - k.N * 60, g.EndUtc), g.ItemId, g.ShiftId, g.LocationId
FROM #MaGood g CROSS JOIN #Cfg c
INNER JOIN Lots.Lot l ON l.LotName = N'OEESEED-' + g.Code + N'-' + CAST(g.ShiftId AS NVARCHAR(20)) + N'-1'
CROSS JOIN (VALUES (0, N'ma'), (1, N'ma-dc')) k (N, Kind)
CROSS APPLY (SELECT CASE WHEN k.N = 0 THEN g.Scrap ELSE g.DcFound END AS Qty) q
CROSS APPLY (SELECT TOP 1 d.DefectCodeId FROM #Def d
             WHERE d.Kind = k.Kind
               AND d.Rn = 1 + CAST(FLOOR(POWER(CAST(CASE WHEN k.N = 0 THEN g.r3 ELSE g.r4 END AS FLOAT), 1.6) * d.N) AS INT)) df
WHERE q.Qty > 0;
PRINT CONCAT(N'M&A rejects (incl. die-cast defects found at M&A): ', @@ROWCOUNT);

-- ---- 4d. LOT side rows, mirroring Lot_Create / Assembly_CompleteTray ----
INSERT INTO Lots.LotStatusHistory (LotId, OldStatusId, NewStatusId, Reason, ChangedByUserId, TerminalLocationId, ChangedAt)
SELECT l.Id, NULL, l.LotStatusId, N'OEESEED: historical LOT inserted by seed_oee_history.sql', l.CreatedByUserId, l.CreatedAtTerminalId, l.CreatedAt
FROM Lots.Lot l WHERE l.LotName LIKE N'OEESEED-%';
INSERT INTO Lots.LotGenealogyClosure (AncestorLotId, DescendantLotId, Depth)
SELECT l.Id, l.Id, 0 FROM Lots.Lot l WHERE l.LotName LIKE N'OEESEED-%';
INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
SELECT l.Id, NULL, l.CurrentLocationId, l.CreatedByUserId, l.CreatedAtTerminalId, l.CreatedAt
FROM Lots.Lot l WHERE l.LotName LIKE N'OEESEED-%';
GO

-- ============================================================
-- STEP 5: refill the stored summary over the seeded range
-- ============================================================
IF OBJECT_ID('tempdb..#RR') IS NOT NULL DROP TABLE #RR;
CREATE TABLE #RR (Status BIT, Message NVARCHAR(500), ShiftsComputed INT);
DECLARE @FromUtc DATETIME2(3) = (SELECT MIN(StartUtc) FROM #S);
DECLARE @ToUtc   DATETIME2(3) = (SELECT MAX(EndUtc) FROM #S);
DECLARE @U BIGINT = (SELECT SysUserId FROM #Cfg);
INSERT INTO #RR (Status, Message, ShiftsComputed)
EXEC Oee.ShiftSummary_RecomputeRange @FromUtc = @FromUtc, @ToUtc = @ToUtc, @AppUserId = @U;
SELECT * FROM #RR;
GO

-- ============================================================
-- Summary, then keep or roll back
-- ============================================================
SELECT N'Lots' AS Kind, COUNT(*) AS Rows FROM Lots.Lot WHERE LotName LIKE N'OEESEED-%'
UNION ALL SELECT N'DowntimeEvent', COUNT(*) FROM Oee.DowntimeEvent WHERE Remarks LIKE N'OEESEED%'
UNION ALL SELECT N'DieCastContribution', COUNT(*) FROM Workorder.DieCastContribution dcc
          INNER JOIN Lots.Lot l ON l.Id = dcc.LotId WHERE l.LotName LIKE N'OEESEED-%'
UNION ALL SELECT N'ProductionEvent', COUNT(*) FROM Workorder.ProductionEvent WHERE Remarks LIKE N'OEESEED%'
UNION ALL SELECT N'RejectEvent', COUNT(*) FROM Workorder.RejectEvent WHERE Remarks LIKE N'OEESEED%'
UNION ALL SELECT N'Shift (backfilled)', COUNT(*) FROM Oee.Shift WHERE Remarks LIKE N'OEESEED%';

IF (SELECT [Commit] FROM #Cfg) = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT N'COMMITTED.';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'Rehearsal only (@Commit = 0) -- ROLLED BACK. Set @Commit = 1 in the working tree to keep.';
END
GO
