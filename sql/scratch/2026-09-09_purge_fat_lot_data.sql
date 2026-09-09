-- =============================================
-- Script:      2026-09-09_purge_fat_lot_data.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-09
-- Purpose:     Permanently delete the FAT dummy LOT content from MPP_MES_Prod
--              ahead of go-live. Scope: everything created BEFORE 2026-09-09
--              Eastern.
--
-- *** THIS DELETES PRODUCTION DATA AND CANNOT BE UNDONE. TAKE A BACKUP. ***
--
-- SAFETY MODEL
--   @Commit defaults to 0. The deletes still RUN -- inside a transaction that is
--   then ROLLED BACK. That is deliberate: a dry run that skipped the statements
--   would prove nothing, whereas this actually exercises every FK in order and
--   reports true row counts. Read the counts, then set @Commit = 1 and re-run.
--
-- CUTOFF AND TIME ZONE
--   Rows are stored UTC (repo convention). "Before 2026-09-09" is read as
--   Eastern local midnight and converted via AT TIME ZONE, so it lands on
--   2026-09-09 04:00 UTC while EDT is in effect -- not 00:00 UTC, which would
--   have spared four hours of FAT data.
--
-- SCOPE -- what counts as "LOT content"
--   * Every Lots.Lot row created before the cutoff, and all 21 tables that
--     foreign-key to it, transitively (ContainerSerialHistory sits four levels
--     down). Delete order is deepest-first; the order below was derived from
--     sys.foreign_keys, not written from memory.
--   * Containers OPENED before the cutoff, plus their trays, serials, serial
--     history and shipping labels. Containers do NOT foreign-key to Lots.Lot,
--     so deleting only LOT rows would strand a container holding no trays and a
--     shipping label pointing at it -- worse than leaving it alone.
--   * Lots.Lot.ParentLotId is self-referencing and is NULLed before the parents
--     are removed. Lots.LotGenealogyClosure carries a self-row per LOT, so it
--     must go before Lots.Lot (Msg 547 otherwise).
--
-- DELIBERATELY NOT DELETED
--   * Lots.AimShipperIdPool rows. A shipper id consumed during FAT may already
--     have been transmitted to Honda's AIM, so recycling it is not ours to do.
--     The container reference is NULLed (that is what unblocks the delete) but
--     the row stays marked consumed. Review these with MPP before go-live --
--     they are listed in the report below.
--   * Audit.ConfigLog / Audit.OperationLog and anything else without an FK to
--     Lots.Lot. Those are the audit trail; they SHOULD outlive the rows.
--   * Parts, tools, locations, users, label templates -- configuration, not LOT
--     content.
--
-- Usage:
--   sqlcmd -S 172.17.10.148 -U Ignition -P $pw -d MPP_MES_Prod -C -i <this file>
-- =============================================

-- sqlcmd defaults QUOTED_IDENTIFIER OFF. Lots.Lot carries a filtered index (B8),
-- and SQL Server refuses DML against a filtered index unless QUOTED_IDENTIFIER is
-- ON -- Msg 1934. Set it here so the script does not depend on the caller passing
-- sqlcmd's -I flag.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ---------------- configuration ----------------
DECLARE @CutoffEt DATETIME2(3) = '2026-09-09T00:00:00';   -- Eastern local midnight
DECLARE @Commit   BIT          = 0;                        -- 0 = preview+rollback, 1 = COMMIT
-- -----------------------------------------------

DECLARE @CutoffUtc DATETIME2(3) =
    CAST(@CutoffEt AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

PRINT '';
PRINT '================================================================';
PRINT '  PURGE FAT LOT CONTENT  ->  ' + DB_NAME() + '  on  ' + @@SERVERNAME;
PRINT '  Cutoff (ET) : ' + CONVERT(NVARCHAR(30), @CutoffEt, 126);
PRINT '  Cutoff (UTC): ' + CONVERT(NVARCHAR(30), @CutoffUtc, 126);
PRINT '  Mode        : ' + CASE WHEN @Commit = 1 THEN 'COMMIT - PERMANENT' ELSE 'PREVIEW - will ROLLBACK' END;
PRINT '================================================================';
PRINT '';

-- ---------------- scope sets ----------------
IF OBJECT_ID('tempdb..#FatLot')       IS NOT NULL DROP TABLE #FatLot;
IF OBJECT_ID('tempdb..#FatContainer') IS NOT NULL DROP TABLE #FatContainer;
IF OBJECT_ID('tempdb..#FatTray')      IS NOT NULL DROP TABLE #FatTray;
IF OBJECT_ID('tempdb..#FatSerial')    IS NOT NULL DROP TABLE #FatSerial;
IF OBJECT_ID('tempdb..#FatSample')    IS NOT NULL DROP TABLE #FatSample;
IF OBJECT_ID('tempdb..#FatProdEvent') IS NOT NULL DROP TABLE #FatProdEvent;

CREATE TABLE #FatLot       (Id BIGINT PRIMARY KEY);
CREATE TABLE #FatContainer (Id BIGINT PRIMARY KEY);
CREATE TABLE #FatTray      (Id BIGINT PRIMARY KEY);
CREATE TABLE #FatSerial    (Id BIGINT PRIMARY KEY);
CREATE TABLE #FatSample    (Id BIGINT PRIMARY KEY);
CREATE TABLE #FatProdEvent (Id BIGINT PRIMARY KEY);

INSERT INTO #FatLot (Id)       SELECT Id FROM Lots.Lot       WHERE CreatedAt < @CutoffUtc;
INSERT INTO #FatContainer (Id) SELECT Id FROM Lots.Container WHERE OpenedAt  < @CutoffUtc;

INSERT INTO #FatTray (Id)
    SELECT Id FROM Lots.ContainerTray
    WHERE ContainerId IN (SELECT Id FROM #FatContainer)
       OR FinishedGoodLotId IN (SELECT Id FROM #FatLot);

INSERT INTO #FatSerial (Id)
    SELECT Id FROM Lots.SerializedPart WHERE ProducingLotId IN (SELECT Id FROM #FatLot);

INSERT INTO #FatSample (Id)
    SELECT Id FROM Quality.QualitySample WHERE LotId IN (SELECT Id FROM #FatLot);

INSERT INTO #FatProdEvent (Id)
    SELECT Id FROM Workorder.ProductionEvent WHERE LotId IN (SELECT Id FROM #FatLot);

PRINT '--- Scope ------------------------------------------------------';
SELECT
    (SELECT COUNT(*) FROM #FatLot)       AS Lots,
    (SELECT COUNT(*) FROM #FatContainer) AS Containers,
    (SELECT COUNT(*) FROM #FatTray)      AS Trays,
    (SELECT COUNT(*) FROM #FatSerial)    AS SerializedParts,
    (SELECT COUNT(*) FROM #FatSample)    AS QualitySamples,
    (SELECT COUNT(*) FROM #FatProdEvent) AS ProductionEvents;

PRINT '';
PRINT '--- Survivors (created ON/AFTER the cutoff - these are KEPT) ----';
SELECT COUNT(*) AS LotsKept FROM Lots.Lot WHERE CreatedAt >= @CutoffUtc;

PRINT '';
PRINT '--- AIM shipper ids touched by FAT containers (NOT recycled) ---';
SELECT p.Id, p.AimShipperId, p.ConsumedAt, p.PostedAt, p.LotNumber
FROM   Lots.AimShipperIdPool p
WHERE  p.ConsumedByContainerId IN (SELECT Id FROM #FatContainer);

-- =============================================
-- PRE-FLIGHT GUARDS -- added 2026-09-09 after the prod inventory showed this
-- database is LIVE: 13 real LOTs were created on 2026-09-09 by operators JH
-- (08464) and TCD (08356), several still Open at DC1-M11. The FAT rows stop at
-- 2026-08-20, so there is a 19-day gap and nothing should cross the cutoff --
-- but "should" is not good enough against live traceability data. If anything
-- kept depends on anything deleted, ABORT rather than corrupt genealogy.
-- =============================================
PRINT '';
PRINT '--- Pre-flight: does anything KEPT depend on anything DELETED? --';

DECLARE @x_parent   INT = (SELECT COUNT(*) FROM Lots.Lot
                            WHERE Id NOT IN (SELECT Id FROM #FatLot)
                              AND ParentLotId IN (SELECT Id FROM #FatLot));
-- "exactly one side is FAT" -- T-SQL cannot compare two predicates directly,
-- so each side is projected to 1/0 first.
DECLARE @x_gene     INT = (SELECT COUNT(*) FROM Lots.LotGenealogy
                            WHERE CASE WHEN ParentLotId IN (SELECT Id FROM #FatLot) THEN 1 ELSE 0 END
                               <> CASE WHEN ChildLotId  IN (SELECT Id FROM #FatLot) THEN 1 ELSE 0 END);
DECLARE @x_closure  INT = (SELECT COUNT(*) FROM Lots.LotGenealogyClosure
                            WHERE CASE WHEN AncestorLotId   IN (SELECT Id FROM #FatLot) THEN 1 ELSE 0 END
                               <> CASE WHEN DescendantLotId IN (SELECT Id FROM #FatLot) THEN 1 ELSE 0 END);
DECLARE @x_consume  INT = (SELECT COUNT(*) FROM Workorder.ConsumptionEvent
                            WHERE CASE WHEN SourceLotId   IN (SELECT Id FROM #FatLot) THEN 1 ELSE 0 END
                               <> CASE WHEN ProducedLotId IN (SELECT Id FROM #FatLot) THEN 1 ELSE 0 END);
DECLARE @x_tray     INT = (SELECT COUNT(*) FROM Lots.ContainerTray
                            WHERE ContainerId IN (SELECT Id FROM #FatContainer)
                              AND FinishedGoodLotId IS NOT NULL
                              AND FinishedGoodLotId NOT IN (SELECT Id FROM #FatLot));
DECLARE @x_serial   INT = (SELECT COUNT(*) FROM Lots.ContainerSerial
                            WHERE ContainerId IN (SELECT Id FROM #FatContainer)
                              AND SerializedPartId IS NOT NULL
                              AND SerializedPartId NOT IN (SELECT Id FROM #FatSerial));

SELECT @x_parent  AS KeptLot_HasFatParent,
       @x_gene    AS Genealogy_CrossesCutoff,
       @x_closure AS Closure_CrossesCutoff,
       @x_consume AS Consumption_CrossesCutoff,
       @x_tray    AS FatContainer_HoldsKeptLotTray,
       @x_serial  AS FatContainer_HoldsKeptSerial;

IF (@x_parent + @x_gene + @x_closure + @x_consume + @x_tray + @x_serial) > 0
BEGIN
    RAISERROR('ABORT: kept data depends on data this script would delete (see counts above). Deleting would corrupt live traceability. Nothing was changed.', 16, 1);
    RETURN;
END
PRINT '  OK - no dependency crosses the cutoff.';

-- Shipping labels are externally visible (Honda AIM). List them explicitly so
-- the decision to remove them is made with eyes open, not as a side effect.
PRINT '';
-- Provenance decides whether these matter, not the id string. A shipper id that
-- genuinely came from Honda has a FetchedInterfaceLogId (the logged AIM call);
-- one that was genuinely transmitted back has a PostedAt. Both NULL on every row
-- means nothing ever left or entered this plant, so deleting the label is local
-- housekeeping. Any non-NULL means STOP and talk to MPP before committing.
PRINT '--- Shipping labels that WILL be deleted, with AIM provenance ---';
SELECT sl.Id,
       sl.AimShipperId,
       sl.ContainerId,
       sl.IsVoid,
       sl.PrintedAt,
       p.FetchedInterfaceLogId,                 -- non-NULL => really came from AIM
       p.PostedAt,                              -- non-NULL => really sent to Honda
       p.PostAttempts
FROM   Lots.ShippingLabel sl
LEFT  JOIN Lots.AimShipperIdPool p ON p.AimShipperId = sl.AimShipperId
WHERE  sl.ContainerId IN (SELECT Id FROM #FatContainer)
ORDER BY sl.Id;

DECLARE @realAim INT = (
    SELECT COUNT(*)
    FROM   Lots.ShippingLabel sl
    JOIN   Lots.AimShipperIdPool p ON p.AimShipperId = sl.AimShipperId
    WHERE  sl.ContainerId IN (SELECT Id FROM #FatContainer)
      AND (p.FetchedInterfaceLogId IS NOT NULL OR p.PostedAt IS NOT NULL));

IF @realAim > 0
BEGIN
    PRINT '';
    RAISERROR('ABORT: %d shipping label(s) carry an AIM shipper id that was really fetched from or posted to Honda. Deleting them would destroy the local record of an externally-known shipment. Nothing was changed - review with MPP first.', 16, 1, @realAim);
    RETURN;
END
PRINT '  OK - no shipping label carries a genuinely fetched or posted AIM id.';

-- ---------------- the delete ----------------
DECLARE @rows TABLE (Seq INT IDENTITY(1,1), TableName SYSNAME, RowsDeleted INT);

BEGIN TRANSACTION;

-- depth 4
DELETE Lots.ContainerSerialHistory
 WHERE ContainerSerialId IN (SELECT Id FROM Lots.ContainerSerial
                              WHERE ContainerTrayId IN (SELECT Id FROM #FatTray)
                                 OR ContainerId     IN (SELECT Id FROM #FatContainer)
                                 OR SerializedPartId IN (SELECT Id FROM #FatSerial))
    OR OldContainerId IN (SELECT Id FROM #FatContainer)
    OR NewContainerId IN (SELECT Id FROM #FatContainer);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.ContainerSerialHistory', @@ROWCOUNT);

-- depth 3
DELETE Lots.ContainerSerial
 WHERE ContainerTrayId   IN (SELECT Id FROM #FatTray)
    OR ContainerId       IN (SELECT Id FROM #FatContainer)
    OR SerializedPartId  IN (SELECT Id FROM #FatSerial);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.ContainerSerial', @@ROWCOUNT);

DELETE Quality.QualityAttachment WHERE QualitySampleId IN (SELECT Id FROM #FatSample);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Quality.QualityAttachment', @@ROWCOUNT);

DELETE Quality.QualityResult WHERE QualitySampleId IN (SELECT Id FROM #FatSample);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Quality.QualityResult', @@ROWCOUNT);

DELETE Workorder.ProductionEventValue WHERE ProductionEventId IN (SELECT Id FROM #FatProdEvent);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Workorder.ProductionEventValue', @@ROWCOUNT);

DELETE Workorder.RejectEvent
 WHERE LotId IN (SELECT Id FROM #FatLot)
    OR ProductionEventId IN (SELECT Id FROM #FatProdEvent);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Workorder.RejectEvent', @@ROWCOUNT);

-- depth 2
DELETE Lots.ShippingLabel WHERE ContainerId IN (SELECT Id FROM #FatContainer);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.ShippingLabel', @@ROWCOUNT);

DELETE Lots.ContainerTray WHERE Id IN (SELECT Id FROM #FatTray);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.ContainerTray', @@ROWCOUNT);

DELETE Quality.HoldEvent
 WHERE LotId       IN (SELECT Id FROM #FatLot)
    OR ContainerId IN (SELECT Id FROM #FatContainer);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Quality.HoldEvent', @@ROWCOUNT);

DELETE Quality.QualitySample WHERE Id IN (SELECT Id FROM #FatSample);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Quality.QualitySample', @@ROWCOUNT);

DELETE Workorder.ProductionEvent WHERE Id IN (SELECT Id FROM #FatProdEvent);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Workorder.ProductionEvent', @@ROWCOUNT);

DELETE Workorder.ConsumptionEvent
 WHERE SourceLotId   IN (SELECT Id FROM #FatLot)
    OR ProducedLotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Workorder.ConsumptionEvent', @@ROWCOUNT);

DELETE Workorder.DieCastContribution WHERE LotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Workorder.DieCastContribution', @@ROWCOUNT);

DELETE Lots.LotAttributeChange WHERE LotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.LotAttributeChange', @@ROWCOUNT);

DELETE Lots.LotEventLog WHERE LotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.LotEventLog', @@ROWCOUNT);

DELETE Lots.LotGenealogy
 WHERE ParentLotId IN (SELECT Id FROM #FatLot)
    OR ChildLotId  IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.LotGenealogy', @@ROWCOUNT);

DELETE Lots.LotGenealogyClosure
 WHERE AncestorLotId   IN (SELECT Id FROM #FatLot)
    OR DescendantLotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.LotGenealogyClosure', @@ROWCOUNT);

DELETE Lots.LotLabel
 WHERE LotId       IN (SELECT Id FROM #FatLot)
    OR ParentLotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.LotLabel', @@ROWCOUNT);

DELETE Lots.LotMovement WHERE LotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.LotMovement', @@ROWCOUNT);

DELETE Lots.LotStatusHistory WHERE LotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.LotStatusHistory', @@ROWCOUNT);

DELETE Lots.PauseEvent WHERE LotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.PauseEvent', @@ROWCOUNT);

DELETE Lots.SerializedPart WHERE Id IN (SELECT Id FROM #FatSerial);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.SerializedPart', @@ROWCOUNT);

-- Release the FK only; the pool row stays marked consumed (see header).
UPDATE Lots.AimShipperIdPool
   SET ConsumedByContainerId = NULL
 WHERE ConsumedByContainerId IN (SELECT Id FROM #FatContainer);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.AimShipperIdPool (FK NULLed)', @@ROWCOUNT);

DELETE Lots.Container WHERE Id IN (SELECT Id FROM #FatContainer);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.Container', @@ROWCOUNT);

-- depth 1 -- self-reference first, then the LOTs themselves
UPDATE Lots.Lot SET ParentLotId = NULL WHERE ParentLotId IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.Lot (ParentLotId NULLed)', @@ROWCOUNT);

DELETE Lots.Lot WHERE Id IN (SELECT Id FROM #FatLot);
INSERT INTO @rows (TableName, RowsDeleted) VALUES (N'Lots.Lot', @@ROWCOUNT);

-- ---------------- report + residue check ----------------
PRINT '';
PRINT '--- Rows deleted ----------------------------------------------';
SELECT Seq, TableName, RowsDeleted FROM @rows ORDER BY Seq;

DECLARE @residue INT = (SELECT COUNT(*) FROM Lots.Lot WHERE Id IN (SELECT Id FROM #FatLot));
PRINT '';
PRINT '--- Residue check (must be 0) ---------------------------------';
SELECT @residue AS FatLotsRemaining,
       (SELECT COUNT(*) FROM Lots.Lot) AS LotsRemainingTotal,
       (SELECT COUNT(*) FROM Lots.Container) AS ContainersRemainingTotal;

IF @residue <> 0
BEGIN
    ROLLBACK TRANSACTION;
    RAISERROR('Residue check failed: FAT lots still present. Rolled back, nothing changed.', 16, 1);
    RETURN;
END

IF @Commit = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT '';
    PRINT '*** COMMITTED. The rows above are permanently gone. ***';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT '';
    PRINT 'PREVIEW ONLY - rolled back, nothing changed.';
    PRINT 'The counts above are what a real run would delete.';
    PRINT 'Set @Commit = 1 at the top and re-run to make it permanent.';
END
GO
