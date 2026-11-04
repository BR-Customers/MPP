-- ============================================================
-- clear_oee_seed.sql
-- Companion teardown for seed_oee_history.sql. Removes ONLY the rows that seed
-- wrote, by its tags, then recomputes Oee.ShiftSummary over the affected shifts
-- so the dashboard shows the un-seeded state again. Touches nothing else.
--
-- Tags it keys on:
--   Lots.Lot                     LotName LIKE 'OEESEED-%'  (the LOT list)
--     + DieCastContribution / LotStatusHistory / LotGenealogyClosure / LotMovement
--       and any LOT child rows a user added to those LOTs since (notes, holds...)
--   Oee.DowntimeEvent            Remarks LIKE 'OEESEED%'
--     + their Audit.OperationLog rows (the procs wrote them)
--   Workorder.ProductionEvent    Remarks LIKE 'OEESEED%'
--   Workorder.RejectEvent        Remarks LIKE 'OEESEED%'
--   Oee.Shift                    Remarks LIKE 'OEESEED%'  (only shifts the seed backfilled)
--
-- Hard-codes USE MPP_MES_Dev (sqlcmd -d does NOT redirect it):
--   sqlcmd -S localhost -d MPP_MES_Dev -E -b -I -C -i sql/scratch/clear_oee_seed.sql
--
-- @Commit = 0 (the committed default) runs the deletes inside a transaction,
-- prints the counts and ROLLS BACK. Set @Commit = 1 in the working tree to
-- remove the rows -- never commit the file armed. Re-runnable. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
USE MPP_MES_Dev;
GO

DECLARE @Commit BIT = 0;   -- 0 = rehearse and roll back; 1 = delete (working tree only)

IF OBJECT_ID('tempdb..#L') IS NOT NULL DROP TABLE #L;
IF OBJECT_ID('tempdb..#D') IS NOT NULL DROP TABLE #D;
IF OBJECT_ID('tempdb..#Sh') IS NOT NULL DROP TABLE #Sh;
CREATE TABLE #L (Id BIGINT NOT NULL PRIMARY KEY);
INSERT INTO #L (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'OEESEED-%';
CREATE TABLE #D (Id BIGINT NOT NULL PRIMARY KEY, ShiftId BIGINT NULL);
INSERT INTO #D (Id, ShiftId) SELECT Id, ShiftId FROM Oee.DowntimeEvent WHERE Remarks LIKE N'OEESEED%';
SELECT Id INTO #Sh FROM Oee.Shift WHERE Remarks LIKE N'OEESEED%';

-- Shifts whose summary must be recomputed afterwards
DECLARE @FromUtc DATETIME2(3), @ToUtc DATETIME2(3);
SELECT @FromUtc = MIN(x.StartUtc), @ToUtc = DATEADD(MILLISECOND, 1, MAX(x.StartUtc))
FROM (
    SELECT DISTINCT s.Id, CAST(s.ActualStart AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3)) AS StartUtc
    FROM Oee.Shift s
    WHERE s.Id IN (SELECT ShiftId FROM #D)
       OR s.Id IN (SELECT ShiftId FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM #L))
       OR s.Id IN (SELECT ShiftId FROM Lots.Lot WHERE Id IN (SELECT Id FROM #L))
       OR s.Id IN (SELECT ShiftId FROM Workorder.RejectEvent WHERE Remarks LIKE N'OEESEED%')
) x;

BEGIN TRANSACTION;

DECLARE @n TABLE (Kind NVARCHAR(50), Rows INT);

DELETE FROM Workorder.RejectEvent WHERE Remarks LIKE N'OEESEED%' OR LotId IN (SELECT Id FROM #L);
INSERT INTO @n VALUES (N'RejectEvent', @@ROWCOUNT);
DELETE FROM Workorder.ProductionEventValue
WHERE ProductionEventId IN (SELECT Id FROM Workorder.ProductionEvent WHERE Remarks LIKE N'OEESEED%' OR LotId IN (SELECT Id FROM #L));
DELETE FROM Workorder.ProductionEvent WHERE Remarks LIKE N'OEESEED%' OR LotId IN (SELECT Id FROM #L);
INSERT INTO @n VALUES (N'ProductionEvent', @@ROWCOUNT);
DELETE FROM Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM #L);
INSERT INTO @n VALUES (N'DieCastContribution', @@ROWCOUNT);

-- LOT children (the seed wrote the first three; the rest only if someone touched a seeded LOT)
DELETE FROM Lots.LotStatusHistory    WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Lots.LotGenealogyClosure WHERE AncestorLotId IN (SELECT Id FROM #L) OR DescendantLotId IN (SELECT Id FROM #L);
DELETE FROM Lots.LotMovement         WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Lots.LotEventLog         WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Lots.LotNote             WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Lots.LotAttributeChange  WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Lots.LotLabel            WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Lots.PauseEvent          WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Quality.HoldEvent        WHERE LotId IN (SELECT Id FROM #L);
DELETE FROM Lots.Lot                 WHERE Id IN (SELECT Id FROM #L);
INSERT INTO @n VALUES (N'Lot', @@ROWCOUNT);

DELETE FROM Audit.OperationLog
WHERE LogEntityTypeId = (SELECT Id FROM Audit.LogEntityType WHERE Code = N'DowntimeEvent')
  AND EntityId IN (SELECT Id FROM #D);
INSERT INTO @n VALUES (N'Audit.OperationLog (downtime)', @@ROWCOUNT);
DELETE FROM Oee.DowntimeEvent WHERE Id IN (SELECT Id FROM #D);
INSERT INTO @n VALUES (N'DowntimeEvent', @@ROWCOUNT);

-- backfilled shifts go only if nothing else now hangs off them
DELETE FROM Oee.ShiftSummary WHERE ShiftId IN (SELECT Id FROM #Sh);
DELETE s FROM Oee.Shift s
WHERE s.Id IN (SELECT Id FROM #Sh)
  AND NOT EXISTS (SELECT 1 FROM Oee.DowntimeEvent x WHERE x.ShiftId = s.Id)
  AND NOT EXISTS (SELECT 1 FROM Workorder.DieCastContribution x WHERE x.ShiftId = s.Id)
  AND NOT EXISTS (SELECT 1 FROM Workorder.ProductionEvent x WHERE x.ShiftId = s.Id)
  AND NOT EXISTS (SELECT 1 FROM Workorder.RejectEvent x WHERE x.ShiftId = s.Id)
  AND NOT EXISTS (SELECT 1 FROM Lots.Lot x WHERE x.ShiftId = s.Id);
INSERT INTO @n VALUES (N'Shift (backfilled)', @@ROWCOUNT);

-- recompute the stored summary for the shifts that lost rows
IF @FromUtc IS NOT NULL
BEGIN
    DECLARE @U BIGINT = (SELECT Id FROM Location.AppUser WHERE Initials = N'SYS');
    DECLARE @RR TABLE (Status BIT, Message NVARCHAR(500), ShiftsComputed INT);
    INSERT INTO @RR EXEC Oee.ShiftSummary_RecomputeRange @FromUtc = @FromUtc, @ToUtc = @ToUtc, @AppUserId = @U;
    INSERT INTO @n SELECT N'ShiftSummary recompute: ' + Message, ShiftsComputed FROM @RR;
END

SELECT Kind, Rows FROM @n;

IF @Commit = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT N'COMMITTED -- OEE seed removed.';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'Rehearsal only (@Commit = 0) -- ROLLED BACK. Set @Commit = 1 in the working tree to delete.';
END
GO
