/* ============================================================================
   mes_validate_active_workcells.sql  --  "what is ACTUALLY in use?"
   ----------------------------------------------------------------------------
   TARGET   Legacy "MES" database (SparkMES lineage) on EXCSRV05, SQL 2016.
   PURPOSE  The MES location tree (Area -> Line -> WorkCell -> Workstation) is
            NOT pruned -- decommissioned cells, dev boxes, and duplicate scan
            points linger forever (e.g. 5A2 "Line 1" shows 13 Workstations;
            physically it is far fewer). There is NO IsActive/IsDeleted flag on
            the location tables, so config alone cannot tell you what is live.

            The TRUTH is in the transactional tables, which carry WorkCellID +
            a Timestamp. This script ranks every WorkCell by RECENT material
            movement so you can see what is genuinely in use vs dormant.

   GRANULARITY
            Transactions are logged at WorkCell level (no WorkstationID exists
            on any transaction table). So this validates CELLS. Workstation
            count within a live cell is a separate "how many real scan points"
            question (answer via Machine host + floor walk) -- and in the new
            model those workstations collapse into role-terminals anyway.

   SIGNAL QUALITY (from mes_tables row-count + max-timestamp scan, 2026-07)
            LIVE, current to 2025:  Lot, LotTransaction (max 2025-07-20),
                                    SubLotTransaction (max 2025-12-14)
            DORMANT since 2020-09:  SerializedItemTransaction, VisionSystemEventLog,
                                    SystemLog  -> DO NOT trust for "currency".
            Hence this script uses LotTransaction + SubLotTransaction only.

   HOW TO RUN
            Execute against MES in SSMS. Adjust @SinceMonths for the window.
            Emits 4 grids (#V1..#V4). Save each grid As... CSV into
            reference/legacy_mes_extract/ if you want to feed it back.

   100% read-only; READ UNCOMMITTED so it never blocks the live DB.
   ============================================================================ */

USE MES;   -- confirm legacy DB name
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @SinceMonths int = 12;                 -- <-- activity window
DECLARE @Since datetime = DATEADD(MONTH, -@SinceMonths, GETDATE());

/* ---------------------------------------------------------------------------
   Unified recent-activity per WorkCell, from the two LIVE transaction tables.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#act') IS NOT NULL DROP TABLE #act;
CREATE TABLE #act (WorkCellID int, Src varchar(12), Ts datetime);

INSERT INTO #act (WorkCellID, Src, Ts)
SELECT lt.WorkCellID, 'LotTx', lt.Timestamp
FROM dbo.LotTransaction lt
WHERE lt.Timestamp >= @Since AND lt.WorkCellID IS NOT NULL
UNION ALL
SELECT st.WorkCellID, 'SubLotTx', st.Timestamp
FROM dbo.SubLotTransaction st
WHERE st.Timestamp >= @Since AND st.WorkCellID IS NOT NULL;

/* distinct set of live WorkCellIDs (aggregation over EXISTS is illegal, so we
   materialize the flag here and reference this set below) */
IF OBJECT_ID('tempdb..#live') IS NOT NULL DROP TABLE #live;
SELECT DISTINCT WorkCellID INTO #live FROM #act;

/* ---- #V1  LIVE work cells (had activity in the window), ranked ---- */
SELECT '#V1 LIVE' AS Grid,
       a.Name  AS Area, pl.Name AS ProductionLine, wc.Name AS WorkCell,
       wc.WorkCellID,
       COUNT(*)            AS TxCount,
       MAX(x.Ts)           AS LastActivity,
       DATEDIFF(DAY, MAX(x.Ts), GETDATE()) AS DaysSince
FROM #act x
JOIN dbo.WorkCell        wc ON wc.WorkCellID       = x.WorkCellID
JOIN dbo.ProductionLine  pl ON pl.ProductionLineID = wc.ProductionLineID
JOIN dbo.Area            a  ON a.AreaID            = pl.AreaID
GROUP BY a.Name, pl.Name, wc.Name, wc.WorkCellID
ORDER BY TxCount DESC;

/* ---- #V2  DORMANT work cells (exist in config, ZERO activity in window) ---
        These are the decommission / never-used candidates. ---- */
SELECT '#V2 DORMANT' AS Grid,
       a.Name AS Area, pl.Name AS ProductionLine, wc.Name AS WorkCell,
       wc.WorkCellID
FROM dbo.WorkCell wc
JOIN dbo.ProductionLine pl ON pl.ProductionLineID = wc.ProductionLineID
JOIN dbo.Area           a  ON a.AreaID            = pl.AreaID
WHERE NOT EXISTS (SELECT 1 FROM #live l WHERE l.WorkCellID = wc.WorkCellID)
ORDER BY a.Name, pl.Name, wc.Name;

/* ---- #V3  Roll-up: live vs dormant cell counts per ProductionLine ----
        Live flag is materialized per cell in the derived table `c`, so the
        outer SUM aggregates a plain column (no aggregate-over-subquery). ---- */
SELECT '#V3 LINEROLLUP' AS Grid,
       a.Name AS Area, pl.Name AS ProductionLine,
       SUM(c.IsLive)     AS LiveCells,
       SUM(1 - c.IsLive) AS DormantCells,
       COUNT(*)          AS TotalCells
FROM (
    SELECT wc.WorkCellID, wc.ProductionLineID,
           CASE WHEN l.WorkCellID IS NULL THEN 0 ELSE 1 END AS IsLive
    FROM dbo.WorkCell wc
    LEFT JOIN #live l ON l.WorkCellID = wc.WorkCellID
) c
JOIN dbo.ProductionLine pl ON pl.ProductionLineID = c.ProductionLineID
JOIN dbo.Area           a  ON a.AreaID            = pl.AreaID
GROUP BY a.Name, pl.Name
ORDER BY a.Name, pl.Name;

/* ---- #V4  Workstations under LIVE cells, with host (the collapse worksheet).
        Shows, per live cell, how many Workstation rows exist and their hosts
        so you can judge real scan-point count vs modeling artifacts. ---- */
SELECT '#V4 WSUNDERLIVE' AS Grid,
       a.Name AS Area, wc.Name AS WorkCell, ws.Name AS Workstation, ws.MachineName AS Host
FROM dbo.Workstation ws
JOIN dbo.WorkCell        wc ON wc.WorkCellID       = ws.WorkCellID
JOIN dbo.ProductionLine  pl ON pl.ProductionLineID = wc.ProductionLineID
JOIN dbo.Area            a  ON a.AreaID            = pl.AreaID
WHERE EXISTS (SELECT 1 FROM #live l WHERE l.WorkCellID = wc.WorkCellID)
ORDER BY a.Name, wc.Name, ws.Name;

DROP TABLE #act;
DROP TABLE #live;
GO
