/* ============================================================================
   mes_validate_active_workstations.sql  --  WORKSTATION-level "who is alive?"
   ----------------------------------------------------------------------------
   TARGET   Legacy "MES" database (SparkMES lineage) on EXCSRV05, SQL 2016.
   WHY      Lot/SubLot transactions only carry WorkCellID -- they cannot tell
            you which WORKSTATION (physical terminal PC) is in use. But the MES
            client keeps a heartbeat in dbo.ClientState: one row per client with
            MachineName + WorkstationID + LastReportTimestamp. THAT is the
            workstation-level signal we were missing.

   READ THIS ABOUT CURRENCY
            ClientState is small (~322 rows). The cached schema snapshot showed a
            max datetime of 2018-12-02, but that is almost certainly the max of
            StartupTimestamp (thin clients are installed once and run for years),
            NOT LastReportTimestamp. #W1 orders by LastReportTimestamp DESC so the
            TOP rows tell you immediately how current the heartbeat really is on
            THIS backup. If the top LastReportTimestamp is recent -> we finally
            have live per-station truth. If it too is years old -> the client
            heartbeat was disabled and we fall back to ClientState as a
            "last-ever-seen per station" history (still far better than nothing).

   GRIDS    #W1  ClientState heartbeat, resolved to Workstation/Cell/Line/Area
            #W2  Config Workstations that NEVER had a client (phantom config)
            #W3  (optional, heavy) SystemLog last-seen per MachineName -- a second
                 host-level source; note SystemLog froze ~2020-09, so it is a
                 PRE-2020 historical cross-check only.

   100% read-only; READ UNCOMMITTED so it never blocks the live DB.
   ============================================================================ */

USE MES;   -- confirm legacy DB name
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ---- #W1  CLIENT HEARTBEAT -> workstation, most-recently-alive first -------
        This is THE answer: each physical client PC (MachineName) mapped to the
        MES Workstation it runs as, with when it last reported in. ---- */
SELECT '#W1 CLIENTSTATE' AS Grid,
       cs.MachineName            AS ClientHost,
       ws.Name                   AS Workstation,
       ws.MachineName            AS ConfigHost,          -- host the config expects
       wc.Name                   AS WorkCell,
       pl.Name                   AS ProductionLine,
       a.Name                    AS Area,
       cs.LastReportTimestamp,
       DATEDIFF(DAY, cs.LastReportTimestamp, GETDATE()) AS DaysSinceReport,
       cs.StartupTimestamp,
       cs.LoggedOnUser,
       cs.IpAddress,
       cs.ClientVersion,
       cs.OperatingSystem
FROM dbo.ClientState cs
LEFT JOIN dbo.Workstation    ws ON ws.WorkstationID     = cs.WorkstationID
LEFT JOIN dbo.WorkCell       wc ON wc.WorkCellID        = COALESCE(cs.WorkCellID, ws.WorkCellID)
LEFT JOIN dbo.ProductionLine pl ON pl.ProductionLineID  = wc.ProductionLineID
LEFT JOIN dbo.Area           a  ON a.AreaID             = pl.AreaID
ORDER BY cs.LastReportTimestamp DESC;

/* ---- #W2  CONFIG WORKSTATIONS THAT NEVER HAD A CLIENT ----------------------
        Workstation rows with no ClientState heartbeat ever = pure config
        artifacts / phantoms (prime "not a real station" candidates). ---- */
SELECT '#W2 NOCLIENT' AS Grid,
       ws.WorkstationID, ws.Name AS Workstation, ws.MachineName AS ConfigHost,
       wc.Name AS WorkCell, pl.Name AS ProductionLine, a.Name AS Area
FROM dbo.Workstation ws
LEFT JOIN dbo.WorkCell       wc ON wc.WorkCellID       = ws.WorkCellID
LEFT JOIN dbo.ProductionLine pl ON pl.ProductionLineID = wc.ProductionLineID
LEFT JOIN dbo.Area           a  ON a.AreaID            = pl.AreaID
WHERE NOT EXISTS (SELECT 1 FROM dbo.ClientState cs WHERE cs.WorkstationID = ws.WorkstationID)
ORDER BY a.Name, pl.Name, wc.Name, ws.Name;

/* ---- #W3  (OPTIONAL / HEAVY) SystemLog last-seen per machine ---------------
        A SECOND host-level activity source: every log row carries MachineName +
        Timestamp. 71M rows -> this scans; run only if you want the pre-2020
        history. SystemLog froze ~2020-09-13, so treat as historical existence,
        not current use. Uncomment to run.
   --------------------------------------------------------------------------- */
-- SELECT '#W3 SYSLOGHOST' AS Grid,
--        sl.MachineName,
--        MAX(sl.Timestamp)  AS LastSeen,
--        COUNT(*)           AS LogRows
-- FROM dbo.SystemLog sl
-- GROUP BY sl.MachineName
-- ORDER BY LastSeen DESC;
GO
