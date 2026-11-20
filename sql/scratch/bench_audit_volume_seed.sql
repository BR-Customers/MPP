-- ============================================================
-- Script:      sql/scratch/bench_audit_volume_seed.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-11-04
-- Purpose:     Second-stage year-scale seed for the read sweep: the event / audit
--              tables that grow WITH production but that bench_lot_volume_seed.sql
--              leaves at Dev size. Run AFTER bench_lot_volume_seed.sql on the same
--              database; it reads the seeded containers / trays.
--                Audit.OperationLog  TrayClosed per tray; ContainerOpened + ContainerCompleted per container
--                Audit.InterfaceLog  2 PLC rows per tray (request at close, response 1 s later)
--                Workorder.RejectEvent  ~10 per line per shift (qty 1-5, random defect)
--                Oee.DowntimeEvent      ~6 per line per shift (5-45 min, random reason)
--                Audit.FailureLog       ~1 per line per shift
--   SAFETY: refuses unless DB_NAME() starts with MPP_MES_Bench. No USE.
--   ASCII only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF DB_NAME() NOT LIKE N'MPP_MES_Bench%'
BEGIN
    RAISERROR(N'bench_audit_volume_seed.sql runs only on an MPP_MES_Bench* database.', 16, 1);
    SET NOEXEC ON;
END
GO
IF EXISTS (SELECT 1 FROM Audit.OperationLog WHERE Description LIKE N'BENCHA%')
BEGIN
    RAISERROR(N'Audit bench rows already present.', 16, 1);
    SET NOEXEC ON;
END
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' operation log');
DECLARE @Info BIGINT = (SELECT Id FROM Audit.LogSeverity WHERE Code = N'Info');
DECLARE @TrayClosed BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'TrayClosed');
DECLARE @Opened BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ContainerOpened');
DECLARE @Completed BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'ContainerCompleted');
DECLARE @EntTray BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ContainerTray');
DECLARE @EntCtr BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'Container');

INSERT INTO Audit.OperationLog (LoggedAt, UserId, TerminalLocationId, LocationId, LogSeverityId, LogEventTypeId, LogEntityTypeId, EntityId, Description, NewValue)
SELECT t.ClosedAt, 1, c.StationLocationId, c.CurrentLocationId, @Info, @TrayClosed, @EntTray, t.Id,
       CONCAT(N'BENCHA Container #', c.Id, N' tray ', t.TrayPosition, N' - Assembly - Completed (', t.PartsClosedCount, N' pcs)'),
       CONCAT(N'{"ContainerId":', c.Id, N',"TrayPosition":', t.TrayPosition, N',"PartsClosedCount":', t.PartsClosedCount,
              N',"ClosureMethod":"ByVision","ContainerFull":false,"Station":{"Id":', ISNULL(c.StationLocationId, 0), N'}}')
FROM Lots.ContainerTray t JOIN Lots.Container c ON c.Id = t.ContainerId
WHERE t.ClosedAt IS NOT NULL;
PRINT CONCAT(N'  TrayClosed rows: ', @@ROWCOUNT);

INSERT INTO Audit.OperationLog (LoggedAt, UserId, TerminalLocationId, LocationId, LogSeverityId, LogEventTypeId, LogEntityTypeId, EntityId, Description, NewValue)
SELECT c.OpenedAt, 1, c.StationLocationId, c.CurrentLocationId, @Info, @Opened, @EntCtr, c.Id,
       CONCAT(N'BENCHA Container ', c.Id, N' - Opened'), NULL
FROM Lots.Container c WHERE c.CompletedAt IS NOT NULL
UNION ALL
SELECT c.CompletedAt, 1, c.StationLocationId, c.CurrentLocationId, @Info, @Completed, @EntCtr, c.Id,
       CONCAT(N'BENCHA Container #', c.Id, N' - AIM SERIAL - Completed'),
       CONCAT(N'{"ContainerId":', c.Id, N',"AccumulatedParts":96}')
FROM Lots.Container c WHERE c.CompletedAt IS NOT NULL;
PRINT CONCAT(N'  container rows: ', @@ROWCOUNT);
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' interface log');
DECLARE @Hs BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'PlcHandshake');
INSERT INTO Audit.InterfaceLog (LoggedAt, SystemName, Direction, LogEventTypeId, Description, RequestPayload, ResponsePayload, IsHighFidelity, LocationId, ItemId, LotId)
SELECT DATEADD(SECOND, k.k, t.ClosedAt), N'PLC:BENCH-CAM', CASE WHEN k.k = 0 THEN N'In' ELSE N'Out' END, @Hs,
       CASE WHEN k.k = 0 THEN N'Inspection complete -> tray PASSED' ELSE N'ByVision tray close' END,
       CONCAT(N'{"v":1,"verdict":"Ok","slots":[1,1,1,1],"containerTrayId":', t.Id, N'}'),
       CASE WHEN k.k = 1 THEN N'{"Status":1,"Message":"Tray completed"}' END,
       0, c.StationLocationId, c.ItemId, CASE WHEN k.k = 1 THEN COALESCE(t.FinishedGoodLotId, c.LotId) END
FROM Lots.ContainerTray t JOIN Lots.Container c ON c.Id = t.ContainerId
CROSS JOIN (VALUES (0), (1)) k(k)
WHERE t.ClosedAt IS NOT NULL;
PRINT CONCAT(N'  interface rows: ', @@ROWCOUNT);
GO

PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' rejects + downtime + failures');
IF OBJECT_ID('tempdb..#LS') IS NOT NULL DROP TABLE #LS;
-- one row per (line, shift) that produced: container-shape trays carry ShiftId
SELECT c.CurrentLocationId AS LineId, t.ShiftId, MIN(t.ClosedAt) AS FirstAt, MAX(t.ClosedAt) AS LastAt,
       MIN(c.ItemId) AS ItemId, MIN(c.StationLocationId) AS StationId, MIN(c.LotId) AS AnyLotId
INTO #LS
FROM Lots.ContainerTray t
JOIN Lots.Container c ON c.Id = t.ContainerId
WHERE t.ShiftId IS NOT NULL
GROUP BY c.CurrentLocationId, t.ShiftId;
PRINT CONCAT(N'  line-shifts: ', @@ROWCOUNT);

IF OBJECT_ID('tempdb..#Def') IS NOT NULL DROP TABLE #Def;
SELECT ROW_NUMBER() OVER (ORDER BY Id) - 1 AS n, Id INTO #Def FROM Quality.DefectCode;
IF OBJECT_ID('tempdb..#Rsn') IS NOT NULL DROP TABLE #Rsn;
SELECT ROW_NUMBER() OVER (ORDER BY Id) - 1 AS n, Id INTO #Rsn FROM Oee.DowntimeReasonCode;
DECLARE @nDef INT = (SELECT COUNT(*) FROM #Def), @nRsn INT = (SELECT COUNT(*) FROM #Rsn);

;WITH k AS (SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k FROM sys.all_objects)
INSERT INTO Workorder.RejectEvent (LotId, DefectCodeId, Quantity, Remarks, AppUserId, RecordedAt, TerminalLocationId, ItemId, ShiftId, CellLocationId)
SELECT CASE WHEN k.k % 3 = 0 THEN ls.AnyLotId END,
       d.Id, 1 + ABS(CHECKSUM(ls.LineId, ls.ShiftId, k.k)) % 5, N'BENCHA reject', 1,
       DATEADD(SECOND, DATEDIFF(SECOND, ls.FirstAt, ls.LastAt) * k.k / 11, ls.FirstAt),
       ls.StationId, ls.ItemId, ls.ShiftId, ls.LineId
FROM #LS ls CROSS JOIN k
JOIN #Def d ON d.n = ABS(CHECKSUM(ls.ShiftId, k.k, ls.LineId)) % @nDef;
PRINT CONCAT(N'  rejects: ', @@ROWCOUNT);

;WITH k AS (SELECT TOP (6) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k FROM sys.all_objects)
INSERT INTO Oee.DowntimeEvent (LocationId, DowntimeReasonCodeId, ShiftId, StartedAt, EndedAt, DowntimeSourceCodeId, AppUserId, Remarks, DurationMinutes)
SELECT ls.LineId, r.Id, ls.ShiftId, x.StartAt, DATEADD(MINUTE, x.Mins, x.StartAt), 1, 1, N'BENCHA downtime', x.Mins
FROM #LS ls CROSS JOIN k
CROSS APPLY (SELECT DATEADD(SECOND, DATEDIFF(SECOND, ls.FirstAt, ls.LastAt) * k.k / 7, ls.FirstAt) AS StartAt,
                    5 + ABS(CHECKSUM(ls.LineId, k.k, ls.ShiftId)) % 41 AS Mins) x
JOIN #Rsn r ON r.n = ABS(CHECKSUM(k.k, ls.ShiftId)) % @nRsn;
PRINT CONCAT(N'  downtime: ', @@ROWCOUNT);

DECLARE @EntTray BIGINT = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'ContainerTray');
DECLARE @TrayClosed BIGINT = (SELECT Id FROM Audit.LogEventType WHERE Code = N'TrayClosed');
INSERT INTO Audit.FailureLog (AttemptedAt, AppUserId, LogEntityTypeId, EntityId, LogEventTypeId, FailureReason, ProcedureName, AttemptedParameters, LocationId, LotId)
SELECT ls.LastAt, 1, @EntTray, NULL, @TrayClosed, N'BENCHA Insufficient component stock at the line -- short: X (need 4, have 0).',
       N'Workorder.Assembly_CompleteTray', N'{"FinishedGoodItemId":1,"PieceCount":4}', ls.StationId, NULL
FROM #LS ls;
PRINT CONCAT(N'  failures: ', @@ROWCOUNT);
EXEC sp_updatestats;
PRINT CONCAT(CONVERT(NVARCHAR(30), SYSDATETIME(), 121), N' done');
GO
