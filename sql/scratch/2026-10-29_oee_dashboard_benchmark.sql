-- =============================================
-- Scratch:     2026-10-29_oee_dashboard_benchmark.sql
-- Purpose:     OEE dashboard benchmark gate (plan
--              docs/superpowers/plans/2026-10-29-oee-dashboard.md Task 7,
--              spec sec 6.1): a whole-plant Week-zoom
--              Oee.Dashboard_GetUnitSummary must return in under 2 s warm on a
--              DB holding a realistic month.
--
--              THROWAWAY DB ONLY. Hard-coded to MPP_MES_Test (rebuilt by every
--              sql/tests/Run-Tests.ps1 run). Never point this at MPP_MES_Dev.
--
--              Generates, for September 2030 (clear of every test fixture):
--                3 shifts a day (06:30 / 14:30 / 22:30), 30 days = 90 shifts
--                per OEE location per shift: 6 downtime events (5-15 min),
--                  one in ten with no reason
--                per die-cast press per shift: 4 contributions of 50 + 2 rejects
--                per OEE line per shift: 4 Manufactured FG LOTs + 2 rejects
--              then times Day and Week (cold + warm) for the whole plant.
--
-- Run:  sqlcmd -S localhost -E -C -I -i sql/scratch/2026-10-29_oee_dashboard_benchmark.sql
-- v0.3 (2026-10-30): the reads pool Oee.ShiftSummary; the script fills it with a
--              month-long RecomputeRange first and times one Compute. Gates:
--              every read < 2 s warm, one Compute < 1 s (spec 6.1).
-- =============================================
USE MPP_MES_Test;
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'MPP_MES_Test'
BEGIN
    RAISERROR(N'Benchmark refuses to run outside MPP_MES_Test.', 16, 1);
    RETURN;
END

-- ---- cleanup of a previous run ----
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT Id FROM Oee.Shift WHERE Remarks = N'BENCH');
DELETE FROM Workorder.RejectEvent         WHERE Remarks = N'BENCH';
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM Lots.Lot WHERE LotName LIKE N'BENCH-%');
DELETE FROM Oee.DowntimeEvent             WHERE Remarks = N'BENCH';
DELETE FROM Lots.Lot                      WHERE LotName LIKE N'BENCH-%';
DELETE FROM Parts.Item                    WHERE PartNumber LIKE N'BENCH-%';
DELETE FROM Oee.Shift WHERE ShiftScheduleId IN (SELECT Id FROM Oee.ShiftSchedule WHERE Name LIKE N'BENCH_%');
DELETE FROM Oee.ShiftSchedule WHERE Name LIKE N'BENCH_%';

-- ---- shifts ----
INSERT INTO Oee.ShiftSchedule (Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom, CreatedByUserId)
VALUES (N'BENCH_1st', N'bench', '06:30:00', '14:30:00', 127, '2020-01-01', 1),
       (N'BENCH_2nd', N'bench', '14:30:00', '22:30:00', 127, '2020-01-01', 1),
       (N'BENCH_3rd', N'bench', '22:30:00', '06:30:00', 127, '2020-01-01', 1);

;WITH Days AS (
    SELECT TOP 30 DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1, CAST('2030-09-01' AS DATETIME2(3))) AS D
    FROM sys.all_objects
)
INSERT INTO Oee.Shift (ShiftScheduleId, ActualStart, ActualEnd, Remarks)
SELECT ss.Id,
       DATEADD(MINUTE, DATEDIFF(MINUTE, '00:00:00', ss.StartTime), d.D),
       DATEADD(MINUTE, DATEDIFF(MINUTE, '00:00:00', ss.StartTime) + 480, d.D),
       N'BENCH'
FROM Days d CROSS JOIN Oee.ShiftSchedule ss
WHERE ss.Name LIKE N'BENCH_%';

DECLARE @Shifts TABLE (ShiftId BIGINT, StartUtc DATETIME2(3));
INSERT INTO @Shifts
SELECT s.Id, CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3))
FROM Oee.Shift s WHERE s.Remarks = N'BENCH';

-- ---- downtime: 6 events per OEE location per shift ----
DECLARE @Op BIGINT = (SELECT Id FROM Oee.DowntimeSourceCode WHERE Code = N'Operator');
DECLARE @Reasons TABLE (N INT IDENTITY(0,1), Id BIGINT);
INSERT INTO @Reasons (Id) SELECT TOP 20 Id FROM Oee.DowntimeReasonCode WHERE DeprecatedAt IS NULL ORDER BY Id;
DECLARE @RCount INT = (SELECT COUNT(*) FROM @Reasons);

INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, Remarks)
SELECT u.LocationId,
       CASE WHEN (u.LocationId + k.n + sh.ShiftId) % 10 = 0 OR @RCount = 0 THEN NULL
            ELSE (SELECT r.Id FROM @Reasons r WHERE r.N = (u.LocationId + k.n) % @RCount) END,
       sh.ShiftId,
       DATEADD(MINUTE, 20 + k.n * 75, sh.StartUtc),
       DATEADD(MINUTE, 20 + k.n * 75 + 5 + (u.LocationId + k.n) % 11, sh.StartUtc),
       @Op, N'BENCH'
FROM Oee.ufn_OeeUnits() u
CROSS JOIN @Shifts sh
CROSS JOIN (VALUES (0),(1),(2),(3),(4),(5)) k (n);

-- ---- parts + one basket per press ----
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
VALUES ((SELECT Id FROM Parts.ItemType WHERE Code = N'Component'),    N'BENCH-CAST', N'bench casting', 1, SYSUTCDATETIME(), 1),
       ((SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood'), N'BENCH-FG',   N'bench FG', 1, SYSUTCDATETIME(), 1);
DECLARE @Cast BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'BENCH-CAST');
DECLARE @Fg   BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'BENCH-FG');
DECLARE @Good BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Good');
DECLARE @Mfg  BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Manufactured');
DECLARE @Src  BIGINT = (SELECT TOP 1 Id FROM Oee.ShiftAttributionSource ORDER BY Id);
DECLARE @Def  BIGINT = (SELECT TOP 1 Id FROM Quality.DefectCode WHERE DeprecatedAt IS NULL ORDER BY Id);

INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId)
SELECT N'BENCH-DC-' + u.Code, @Cast, @Mfg, @Good, 1000, 1000, u.LocationId, 1, '2030-09-01', u.LocationId
FROM Oee.ufn_OeeUnits() u WHERE u.DefinitionCode = N'DieCastMachine';

INSERT INTO Workorder.DieCastContribution (LotId, ShiftId, PieceDelta, AppUserId, EventAt, CellLocationId, ShiftAttributionSourceId)
SELECT l.Id, sh.ShiftId, 50, 1, DATEADD(MINUTE, 60 + k.n * 100, sh.StartUtc), u.LocationId, @Src
FROM Oee.ufn_OeeUnits() u
INNER JOIN Lots.Lot l ON l.LotName = N'BENCH-DC-' + u.Code
CROSS JOIN @Shifts sh
CROSS JOIN (VALUES (0),(1),(2),(3)) k (n)
WHERE u.DefinitionCode = N'DieCastMachine';

-- ---- FG LOTs: 4 per OEE line per shift ----
-- v0.3: stamped with the shift + minted quantity, as Assembly_CompleteTray v1.6 writes them
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, InventoryAvailable, CurrentLocationId, CreatedByUserId, CreatedAt, CreatedAtTerminalId, ShiftId, MintedPieceCount)
SELECT N'BENCH-FG-' + CAST(u.LocationId AS NVARCHAR(20)) + N'-' + CAST(sh.ShiftId AS NVARCHAR(20)) + N'-' + CAST(k.n AS NVARCHAR(2)),
       @Fg, @Mfg, @Good, 24, 24, u.LocationId, 1, DATEADD(MINUTE, 90 + k.n * 90, sh.StartUtc), u.LocationId, sh.ShiftId, 24
FROM Oee.ufn_OeeUnits() u
CROSS JOIN @Shifts sh
CROSS JOIN (VALUES (0),(1),(2),(3)) k (n)
WHERE u.IsStation = 0 AND u.AreaFamily = N'ma';

-- ---- rejects: 2 per unit per shift ----
INSERT INTO Workorder.RejectEvent (DefectCodeId, Quantity, AppUserId, RecordedAt, ItemId, ShiftId, CellLocationId, Remarks)
SELECT @Def, 1 + k.n, 1, DATEADD(MINUTE, 200 + k.n * 60, sh.StartUtc), @Cast, sh.ShiftId, u.LocationId, N'BENCH'
FROM Oee.ufn_OeeUnits() u
CROSS JOIN @Shifts sh
CROSS JOIN (VALUES (0),(1)) k (n)
WHERE u.IsStation = 0;

SELECT (SELECT COUNT(*) FROM Oee.Shift WHERE Remarks = N'BENCH')                 AS Shifts,
       (SELECT COUNT(*) FROM Oee.ufn_OeeUnits())                                 AS OeeLocations,
       (SELECT COUNT(*) FROM Oee.DowntimeEvent WHERE Remarks = N'BENCH')         AS DowntimeEvents,
       (SELECT COUNT(*) FROM Workorder.DieCastContribution dcc INNER JOIN Lots.Lot l ON l.Id = dcc.LotId WHERE l.LotName LIKE N'BENCH-%') AS Contributions,
       (SELECT COUNT(*) FROM Lots.Lot WHERE LotName LIKE N'BENCH-FG-%')          AS FgLots,
       (SELECT COUNT(*) FROM Workorder.RejectEvent WHERE Remarks = N'BENCH')     AS Rejects;

-- ---- timing ----
DECLARE @Anchor BIGINT = (SELECT TOP 1 s.Id FROM Oee.Shift s INNER JOIN Oee.ShiftSchedule ss ON ss.Id = s.ShiftScheduleId
                          WHERE ss.Name = N'BENCH_1st' AND s.ActualStart >= '2030-09-17' ORDER BY s.ActualStart);
DECLARE @R TABLE (
    RowKind NVARCHAR(10), AreaFamily NVARCHAR(10), ProductionAreaId BIGINT, ProductionAreaName NVARCHAR(200),
    LocationId BIGINT, LocationCode NVARCHAR(50), LocationName NVARCHAR(200), ParentLocationId BIGINT,
    BaseMinutes INT, EffectiveUnplannedMinutes DECIMAL(12,2),
    DowntimeMinutes DECIMAL(12,2), PlannedDowntimeMinutes DECIMAL(12,2), UnplannedDowntimeMinutes DECIMAL(12,2),
    Availability DECIMAL(5,4), AvailabilityBand NVARCHAR(10),
    Good BIGINT, Scrap BIGINT, NonRejectScrap BIGINT, FoundDownstreamScrap BIGINT, UnplacedScrap BIGINT,
    Quality DECIMAL(5,4), QualityBand NVARCHAR(10),
    NoReasonCount INT, NoReasonMinutes DECIMAL(12,2), LastToolCode NVARCHAR(50),
    HasProduction BIT, IncludesInProgressShift BIT, SortKey INT);
DECLARE @t DATETIME2(7);
DECLARE @ms TABLE (Run NVARCHAR(30), Ms INT, RowsOut INT);

-- v0.3: fill the summary for the whole month (the deployment's first fill),
-- one shift's compute, then the reads -- which now pool stored rows.
DECLARE @rr TABLE (Status BIT, Message NVARCHAR(500), ShiftsComputed INT);
SET @t = SYSDATETIME();
INSERT INTO @rr EXEC Oee.ShiftSummary_RecomputeRange @FromUtc = '2030-08-31T00:00:00', @ToUtc = '2030-10-02T00:00:00', @AppUserId = 1;
INSERT INTO @ms SELECT N'Fill month (RecomputeRange)', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT ShiftsComputed FROM @rr);
DECLARE @st TABLE (Status BIT, Message NVARCHAR(500));
SET @t = SYSDATETIME();
INSERT INTO @st EXEC Oee.ShiftSummary_Compute @ShiftId = @Anchor, @AppUserId = 1;
INSERT INTO @ms SELECT N'Compute one shift', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM Oee.ShiftSummary WHERE ShiftId = @Anchor);

DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t = SYSDATETIME();
INSERT INTO @R EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Week', @AnchorShiftId = @Anchor;
INSERT INTO @ms SELECT N'Week cold', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM @R);
DELETE FROM @R;

SET @t = SYSDATETIME();
INSERT INTO @R EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Week', @AnchorShiftId = @Anchor;
INSERT INTO @ms SELECT N'Week warm', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM @R);
DELETE FROM @R;

SET @t = SYSDATETIME();
INSERT INTO @R EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Day', @AnchorShiftId = @Anchor;
INSERT INTO @ms SELECT N'Day warm', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM @R);
DELETE FROM @R;

SET @t = SYSDATETIME();
INSERT INTO @R EXEC Oee.Dashboard_GetUnitSummary @Zoom = N'Shift', @AnchorShiftId = @Anchor;
INSERT INTO @ms SELECT N'Shift warm', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM @R);

SELECT Run, Ms, RowsOut,
       CASE WHEN Run LIKE N'% warm' AND Ms >= 2000 THEN N'GATE MISSED (read < 2 s)'
            WHEN Run = N'Compute one shift' AND Ms >= 1000 THEN N'GATE MISSED (< 1 s)'
            ELSE N'' END AS Gate
FROM @ms;
