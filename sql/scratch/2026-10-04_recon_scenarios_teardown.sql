-- ============================================================
-- 2026-10-04_recon_scenarios_teardown.sql
--
-- Removes everything 2026-10-04_recon_scenarios_seed.sql put on MPP_MES_Dev,
-- INCLUDING whatever the reconciliation screen wrote while the scenarios were
-- being driven -- headers, moves, counter anchors, compensating rows, count
-- corrections and any LOT minted from paper.
--
-- SCOPE, and why it is two scopes and not one.
--   (a) BY LOT -- every row that references a 777000xx LOT. That covers the
--       seeded baskets, the credits and corrections against them, and any LOT a
--       reconciliation minted (the walkthrough names the new LTTs 77700031 and
--       77700032 for exactly this reason -- a LOT created under some other
--       number is NOT caught here and has to be removed by hand).
--   (b) BY SHIFT x PRESS x DIE -- the rows that carry no LotId: cavity-attributed
--       scrap (RejectEvent.LotId is nullable since 0084), counter anchors, and
--       the reconciliation headers and their move records. Safe at this scope
--       because every one of the five shift x press combinations was verified
--       EMPTY before the seed ran.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH.
--   Audit rows (Audit.OperationLog, Audit.ConfigLog, Audit.FailureLog,
--   Lots.LotEventLog). They are an append-only record of things that really did
--   happen on this gateway, and deleting audit history to tidy up a test is a
--   worse habit than leaving a few rows behind. They reference nothing that is
--   deleted below, so nothing breaks.
--
-- Tools.Tool.ShotCount is restored from dbo.ReconScenarioSeedState, which is
-- then dropped.
--
-- USAGE -- @Commit = 0 (the committed default) executes every delete inside a
-- transaction and ROLLS BACK, printing the counts, so the blast radius is
-- readable before it lands. Read the counts, then set @Commit = 1 below and
-- re-run. Leave it at 0 in the repo.
--   sqlcmd -S localhost -d MPP_MES_Dev -E -C -i sql\scratch\2026-10-04_recon_scenarios_teardown.sql
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @Commit BIT = 0;    -- 0 = preview + ROLLBACK, 1 = COMMIT

IF OBJECT_ID('dbo.ReconScenarioSeedState') IS NULL
    PRINT N'WARNING: dbo.ReconScenarioSeedState is missing, so Tools.Tool.ShotCount CANNOT be restored. Rows will still be removed. Original values were DMO125 13894, DM0144 2068, DMO126 1408, DMO145 1368.';

-- ------------------------------------------------------------
-- the five shift x press x die combinations the scenarios used
-- ------------------------------------------------------------
DECLARE @Scope TABLE (ShiftId BIGINT, CellLocationId BIGINT, ToolId BIGINT);
INSERT INTO @Scope (ShiftId, CellLocationId, ToolId)
SELECT s.Id, loc.Id, t.Id
FROM (VALUES ('2026-10-04', N'Weekend First',  N'DC1-M11',  N'DMO125'),   -- scenario 1
             ('2026-10-04', N'Weekend First',  N'DC2-M202', N'DM0144'),   -- scenario 2
             ('2026-10-04', N'Weekend Second', N'DC1-M11',  N'DMO125'),   -- scenario 1, the trim ProductionEvent's shift
             ('2026-10-01', N'First Shift',    N'DC3-M305', N'DMO126'),   -- scenario 3a
             ('2026-09-24', N'Third Shift',    N'DC3-M304', N'DMO145')    -- scenario 3b
     ) v (Dt, Sched, Press, Die)
INNER JOIN Oee.ShiftSchedule ss ON ss.Name = v.Sched
INNER JOIN Oee.Shift s ON s.ShiftScheduleId = ss.Id AND CAST(s.ActualStart AS DATE) = CAST(v.Dt AS DATE)
INNER JOIN Location.Location loc ON loc.Code = v.Press
INNER JOIN Tools.Tool t ON t.Code = v.Die;

DECLARE @Lots TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Lots (Id) SELECT Id FROM Lots.Lot WHERE LotName LIKE N'777000%';

DECLARE @Hdr TABLE (Id BIGINT PRIMARY KEY);
INSERT INTO @Hdr (Id)
SELECT r.Id FROM Workorder.DieCastShiftReconciliation r
INNER JOIN @Scope sc ON sc.ShiftId = r.ShiftId AND sc.CellLocationId = r.CellLocationId AND sc.ToolId = r.ToolId;

-- PRINT takes a scalar expression only -- no subqueries, hence the variables.
DECLARE @nInLots INT = (SELECT COUNT(*) FROM @Lots);
DECLARE @nInHdr  INT = (SELECT COUNT(*) FROM @Hdr);
PRINT N'--- in scope -----------------------------------------';
PRINT N'LOTs (777000xx):          ' + CAST(@nInLots AS NVARCHAR(10));
PRINT N'reconciliation headers:   ' + CAST(@nInHdr  AS NVARCHAR(10));

BEGIN TRANSACTION;

-- ---- children of the reconciliation header ----
DELETE m FROM Workorder.DieCastReconciliationMove m INNER JOIN @Hdr h ON h.Id = m.ReconciliationId;
DECLARE @nMove INT = @@ROWCOUNT;

-- ---- rows hanging off the LOTs, deepest first ----
-- LotGenealogyClosure before Lots.Lot (Msg 547 otherwise -- the self-row at
-- depth 0 that DieCastLot_Mint writes references the LOT twice).
DELETE pe FROM Workorder.ProductionEvent    pe INNER JOIN @Lots l ON l.Id = pe.LotId;      DECLARE @nPe   INT = @@ROWCOUNT;
DELETE c  FROM Workorder.DieCastContribution c INNER JOIN @Lots l ON l.Id = c.LotId;       DECLARE @nCon1 INT = @@ROWCOUNT;
DELETE r  FROM Workorder.RejectEvent         r INNER JOIN @Lots l ON l.Id = r.LotId;       DECLARE @nRej1 INT = @@ROWCOUNT;
DELETE ce FROM Workorder.ConsumptionEvent   ce INNER JOIN @Lots l ON l.Id IN (ce.SourceLotId, ce.ProducedLotId); DECLARE @nCe INT = @@ROWCOUNT;
DELETE g  FROM Lots.LotGenealogy             g INNER JOIN @Lots l ON l.Id IN (g.ParentLotId, g.ChildLotId);      DECLARE @nGen INT = @@ROWCOUNT;
DELETE gc FROM Lots.LotGenealogyClosure     gc INNER JOIN @Lots l ON l.Id IN (gc.AncestorLotId, gc.DescendantLotId); DECLARE @nClo INT = @@ROWCOUNT;
DELETE ac FROM Lots.LotAttributeChange      ac INNER JOIN @Lots l ON l.Id = ac.LotId;      DECLARE @nAttr INT = @@ROWCOUNT;
DELETE mv FROM Lots.LotMovement             mv INNER JOIN @Lots l ON l.Id = mv.LotId;      DECLARE @nMv   INT = @@ROWCOUNT;
DELETE sh FROM Lots.LotStatusHistory        sh INNER JOIN @Lots l ON l.Id = sh.LotId;      DECLARE @nSh   INT = @@ROWCOUNT;
DELETE ll FROM Lots.LotLabel                ll INNER JOIN @Lots l ON l.Id IN (ll.LotId, ll.ParentLotId);         DECLARE @nLbl INT = @@ROWCOUNT;
DELETE pv FROM Lots.PauseEvent              pv INNER JOIN @Lots l ON l.Id = pv.LotId;      DECLARE @nPv   INT = @@ROWCOUNT;
DELETE he FROM Quality.HoldEvent            he INNER JOIN @Lots l ON l.Id = he.LotId;      DECLARE @nHe   INT = @@ROWCOUNT;
DELETE qs FROM Quality.QualitySample        qs INNER JOIN @Lots l ON l.Id = qs.LotId;      DECLARE @nQs   INT = @@ROWCOUNT;
DELETE el FROM Lots.LotEventLog             el INNER JOIN @Lots l ON l.Id = el.LotId;      DECLARE @nEl   INT = @@ROWCOUNT;

-- ---- the LOT-less rows, by shift x press x die ----
DELETE r FROM Workorder.RejectEvent r
 INNER JOIN @Scope sc ON sc.ShiftId = r.ShiftId AND sc.CellLocationId = r.CellLocationId AND sc.ToolId = r.ToolId;
DECLARE @nRej2 INT = @@ROWCOUNT;

DELETE c FROM Workorder.DieCastContribution c
 INNER JOIN Lots.Lot l ON l.Id = c.LotId
 INNER JOIN @Scope sc ON sc.ShiftId = c.ShiftId AND sc.CellLocationId = c.CellLocationId AND sc.ToolId = l.ToolId;
DECLARE @nCon2 INT = @@ROWCOUNT;

DELETE a FROM Workorder.DieCastCounterAnchor a
 INNER JOIN @Scope sc ON sc.ShiftId = a.ShiftId AND sc.ToolId = a.ToolId
 AND ISNULL(a.CellLocationId, sc.CellLocationId) = sc.CellLocationId;
DECLARE @nAnc INT = @@ROWCOUNT;

DELETE l FROM Lots.Lot l INNER JOIN @Lots x ON x.Id = l.Id;   DECLARE @nLot INT = @@ROWCOUNT;

DELETE r FROM Workorder.DieCastShiftReconciliation r INNER JOIN @Hdr h ON h.Id = r.Id;
DECLARE @nHdr INT = @@ROWCOUNT;

-- ---- die life back to where the seed found it ----
DECLARE @nTool INT = 0;
IF OBJECT_ID('dbo.ReconScenarioSeedState') IS NOT NULL
BEGIN
    UPDATE t SET t.ShotCount = st.ShotCountBefore, t.UpdatedAt = SYSUTCDATETIME()
    FROM Tools.Tool t INNER JOIN dbo.ReconScenarioSeedState st ON st.ToolId = t.Id
    WHERE t.ShotCount <> st.ShotCountBefore;
    SET @nTool = @@ROWCOUNT;
END

PRINT N'--- deleted ------------------------------------------';
PRINT N'Lots.Lot                       ' + CAST(@nLot  AS NVARCHAR(10));
PRINT N'  LotStatusHistory             ' + CAST(@nSh   AS NVARCHAR(10));
PRINT N'  LotMovement                  ' + CAST(@nMv   AS NVARCHAR(10));
PRINT N'  LotGenealogyClosure          ' + CAST(@nClo  AS NVARCHAR(10));
PRINT N'  LotAttributeChange           ' + CAST(@nAttr AS NVARCHAR(10));
PRINT N'  LotEventLog                  ' + CAST(@nEl   AS NVARCHAR(10));
PRINT N'  LotLabel / Pause / Hold / QS  ' + CAST(@nLbl + @nPv + @nHe + @nQs AS NVARCHAR(10));
PRINT N'  Genealogy / Consumption      ' + CAST(@nGen + @nCe AS NVARCHAR(10));
PRINT N'DieCastContribution (lot+scope)' + CAST(@nCon1 + @nCon2 AS NVARCHAR(10));
PRINT N'RejectEvent (lot+scope)        ' + CAST(@nRej1 + @nRej2 AS NVARCHAR(10));
PRINT N'ProductionEvent                ' + CAST(@nPe   AS NVARCHAR(10));
PRINT N'DieCastCounterAnchor           ' + CAST(@nAnc  AS NVARCHAR(10));
PRINT N'DieCastShiftReconciliation     ' + CAST(@nHdr  AS NVARCHAR(10));
PRINT N'  its move records             ' + CAST(@nMove AS NVARCHAR(10));
PRINT N'Tools.Tool ShotCount restored  ' + CAST(@nTool AS NVARCHAR(10));

SELECT t.Code AS Die, st.ShotCountBefore, t.ShotCount AS ShotCountNow,
       CASE WHEN t.ShotCount = st.ShotCountBefore THEN N'restored' ELSE N'MISMATCH' END AS State
FROM dbo.ReconScenarioSeedState st INNER JOIN Tools.Tool t ON t.Id = st.ToolId ORDER BY t.Code;

SELECT COUNT(*) AS LotsStillNamed777000 FROM Lots.Lot WHERE LotName LIKE N'777000%';

IF @Commit = 1
BEGIN
    IF OBJECT_ID('dbo.ReconScenarioSeedState') IS NOT NULL DROP TABLE dbo.ReconScenarioSeedState;
    COMMIT TRANSACTION;
    PRINT N'COMMITTED. Dev is back to its pre-seed state (audit rows aside -- see the header).';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'ROLLED BACK (preview). Set @Commit = 1 at the top and re-run to land it.';
END
GO
