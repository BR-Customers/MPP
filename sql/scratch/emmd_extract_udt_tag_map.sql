/* ============================================================================
   emmd_extract_udt_tag_map.sql  --  EMMD (Flexware Execution Management)
   ----------------------------------------------------------------------------
   TARGET   Legacy "EMMD" automation-engine database on EXCSRV05.
   PURPOSE  Pull the ground-truth OPC touchpoint wiring in the exact shape the
            new Ignition UDT build needs:
              (1) the real OPC server identities (for OPC-UA connection planning)
              (2) every tag parsed into BasePath + Member (the UDT member catalog
                  and per-device base paths)
              (3) the Line -> Task -> Event -> Action -> tag usage chain (which
                  station uses which tag, in what step, under what trigger --
                  i.e. the handshake sequence per station)

   RELATION TO emmd_extract_automation_config.sql
            That script emits the RAW grids (#H..#N) incl. the 143 Script bodies
            (#N) -- still run #N from there to capture the handshake LOGIC.
            THIS script adds the PARSED / clustered views (#U1..#U4) that the raw
            grids don't give you.

   PARSING RULE (matches observed legacy data + opc_tags.csv)
              * AccessPath non-empty  ->  BasePath = AccessPath (the device),
                                          Member   = OPCItemID
                (TOPServer style, e.g. AccessPath '6B2_CH.MicroLogix1400',
                 item 'PartDisposition01')
              * AccessPath empty      ->  split OPCItemID on the LAST dot:
                                          BasePath = text before last dot,
                                          Member   = text after last dot
                (OmniServer style, e.g. '59B_1_FP_1.NET_DataReady'
                 -> base '59B_1_FP_1', member 'NET_DataReady')

   HOW TO RUN
     Execute against EMMD in SSMS. Emits labeled grids #U1..#U4 (all small).
     For each grid: right-click the result -> Save Results As... -> CSV, and
     drop the files in reference/legacy_mes_extract/ (byte-accurate, unlike a
     copy-paste). Then also run grid #N (Script bodies) from
     emmd_extract_automation_config.sql.

   100% read-only; READ UNCOMMITTED so it never blocks the live engine.
   ============================================================================ */

USE EMMD;
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ---------------------------------------------------------------------------
   #U1  OPC SERVER IDENTITIES
        The real server registrations behind the legacy OPC-DA bridges. Host +
        CLSID/PID tell us what physically sits under OmniServer / TOPServer so
        we can plan the Ignition OPC-UA connections that replace them.
   --------------------------------------------------------------------------- */
SELECT '#U1 SERVER' AS Grid,
       os.OPCServerID        AS Id,
       os.OPCServerName      AS ServerName,
       os.OPCServerPID       AS ServerPid,
       os.OPCServerHost      AS Host,
       os.OPCServerCLSID     AS Clsid,
       os.Description,
       os.PlantID,
       os.Active
FROM em.OPCServer os
ORDER BY os.OPCServerID;

/* ---------------------------------------------------------------------------
   #U2  UNIFIED, PARSED TAG CATALOG  (distinct)
        Every tag the engine reads, writes, or watches -- from OPCRead,
        OPCWrite, AND the Event trigger items -- deduped and split into
        BasePath + Member. This is THE feed for the UDT member catalog and the
        per-device base paths. Direction shows how the legacy engine used each.
   --------------------------------------------------------------------------- */
WITH RawTags AS (
    /* OPC reads */
    SELECT os.OPCServerName AS ServerName,
           r.AccessPath     AS AccessPath,
           r.OPCItemID      AS OpcItemId,
           'Read'           AS Direction
    FROM em.OPCRead r
    LEFT JOIN em.OPCServer os ON os.OPCServerID = r.OPCServerID

    UNION ALL
    /* OPC writes */
    SELECT os.OPCServerName, w.AccessPath, w.OPCItemID, 'Write'
    FROM em.OPCWrite w
    LEFT JOIN em.OPCServer os ON os.OPCServerID = w.OPCServerID

    UNION ALL
    /* Event trigger items (the WATCHED tags -- DataReady/PartComplete/etc.);
       only rows that actually carry an OPC item */
    SELECT os.OPCServerName, e.AccessPath, e.OPCItemID, 'Trigger'
    FROM em.Event e
    LEFT JOIN em.OPCServer os ON os.OPCServerID = e.OPCServerID
    WHERE e.OPCItemID IS NOT NULL AND LTRIM(RTRIM(e.OPCItemID)) <> ''
),
Parsed AS (
    SELECT
        ServerName,
        AccessPath,
        OpcItemId,
        Direction,
        /* BasePath */
        CASE
            WHEN AccessPath IS NOT NULL AND LTRIM(RTRIM(AccessPath)) <> ''
                THEN AccessPath
            WHEN CHARINDEX('.', OpcItemId) > 0
                THEN LEFT(OpcItemId, LEN(OpcItemId) - CHARINDEX('.', REVERSE(OpcItemId)))
            ELSE NULL
        END AS BasePath,
        /* Member */
        CASE
            WHEN AccessPath IS NOT NULL AND LTRIM(RTRIM(AccessPath)) <> ''
                THEN OpcItemId
            WHEN CHARINDEX('.', OpcItemId) > 0
                THEN RIGHT(OpcItemId, CHARINDEX('.', REVERSE(OpcItemId)) - 1)
            ELSE OpcItemId
        END AS Member
    FROM RawTags
)
SELECT '#U2 TAGCATALOG' AS Grid,
       ServerName,
       BasePath,
       Member,
       /* collapse Read/Write/Trigger duplicates of the same tag into one row
          with a combined direction flag */
       MAX(CASE WHEN Direction = 'Read'    THEN 'R' ELSE '' END)
     + MAX(CASE WHEN Direction = 'Write'   THEN 'W' ELSE '' END)
     + MAX(CASE WHEN Direction = 'Trigger' THEN 'T' ELSE '' END) AS Directions,
       MIN(AccessPath) AS AccessPath,
       MIN(OpcItemId)  AS SampleOpcItemId
FROM Parsed
GROUP BY ServerName, BasePath, Member
ORDER BY ServerName, BasePath, Member;

/* ---------------------------------------------------------------------------
   #U3  DEVICE-INSTANCE ROLL-UP
        One row per (Server, BasePath) = a physical device instance, with its
        member count and the comma-list of members. Lets us eyeball which
        base paths share a member signature -> the UDT "types".
   --------------------------------------------------------------------------- */
WITH RawTags AS (
    SELECT os.OPCServerName AS ServerName, r.AccessPath AS AccessPath, r.OPCItemID AS OpcItemId
    FROM em.OPCRead r LEFT JOIN em.OPCServer os ON os.OPCServerID = r.OPCServerID
    UNION ALL
    SELECT os.OPCServerName, w.AccessPath, w.OPCItemID
    FROM em.OPCWrite w LEFT JOIN em.OPCServer os ON os.OPCServerID = w.OPCServerID
    UNION ALL
    SELECT os.OPCServerName, e.AccessPath, e.OPCItemID
    FROM em.Event e LEFT JOIN em.OPCServer os ON os.OPCServerID = e.OPCServerID
    WHERE e.OPCItemID IS NOT NULL AND LTRIM(RTRIM(e.OPCItemID)) <> ''
),
Parsed AS (
    SELECT ServerName,
        CASE
            WHEN AccessPath IS NOT NULL AND LTRIM(RTRIM(AccessPath)) <> '' THEN AccessPath
            WHEN CHARINDEX('.', OpcItemId) > 0
                THEN LEFT(OpcItemId, LEN(OpcItemId) - CHARINDEX('.', REVERSE(OpcItemId)))
            ELSE NULL
        END AS BasePath,
        CASE
            WHEN AccessPath IS NOT NULL AND LTRIM(RTRIM(AccessPath)) <> '' THEN OpcItemId
            WHEN CHARINDEX('.', OpcItemId) > 0
                THEN RIGHT(OpcItemId, CHARINDEX('.', REVERSE(OpcItemId)) - 1)
            ELSE OpcItemId
        END AS Member
    FROM RawTags
),
Distinct1 AS (
    SELECT DISTINCT ServerName, BasePath, Member FROM Parsed
)
SELECT '#U3 DEVICE' AS Grid,
       ServerName,
       BasePath,
       COUNT(*) AS MemberCount,
       STUFF((
           SELECT ', ' + d2.Member
           FROM Distinct1 d2
           WHERE d2.ServerName = d1.ServerName
             AND ((d2.BasePath IS NULL AND d1.BasePath IS NULL) OR d2.BasePath = d1.BasePath)
           ORDER BY d2.Member
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS Members
FROM Distinct1 d1
GROUP BY ServerName, BasePath
ORDER BY ServerName, BasePath;

/* ---------------------------------------------------------------------------
   #U4  STATION USAGE / HANDSHAKE CHAIN
        Line -> Task -> Event -> Action, with the resolved tag and trigger, in
        step order. This ties every tag to a physical station and reconstructs
        the handshake SEQUENCE (what the watcher logic must replay). Pair with
        the Script bodies (#N in emmd_extract_automation_config.sql) for the
        full logic.
   --------------------------------------------------------------------------- */
SELECT '#U4 CHAIN' AS Grid,
       l.Name              AS Line,
       t.Name              AS Task,
       e.Name              AS Event_,
       e.EventID,
       trg.Name            AS EventTrigger,
       e.TriggerArg1,
       e.TriggerArg2,
       eos.OPCServerName   AS EventServer,
       e.AccessPath        AS EventAccessPath,
       e.OPCItemID         AS EventItem,
       e.ReactOnStartup,
       a.StepNumber        AS Step,
       a.Name              AS Action,
       CASE WHEN a.OPCWriteID IS NOT NULL THEN 'WRITE'
            WHEN a.OPCReadID  IS NOT NULL THEN 'READ'
            WHEN a.ScriptID   IS NOT NULL THEN 'SCRIPT'
            ELSE 'OTHER' END AS Kind,
       COALESCE(wos.OPCServerName, ros.OPCServerName) AS ActionServer,
       COALESCE(w.AccessPath, r.AccessPath)           AS ActionAccessPath,
       COALESCE(w.OPCItemID,  r.OPCItemID)            AS ActionItem,
       a.ScriptID,
       a.Active
FROM em.Event e
LEFT JOIN em.Task t              ON t.TaskID = e.TaskID
LEFT JOIN em.Line l              ON l.LineID = t.LineID
LEFT JOIN em.OPCServer eos       ON eos.OPCServerID = e.OPCServerID
LEFT JOIN em.TriggerOperation trg ON trg.TriggerOperationID = e.TriggerOperationID
LEFT JOIN em.Action a            ON a.EventID = e.EventID
LEFT JOIN em.OPCWrite w          ON w.OPCWriteID = a.OPCWriteID
LEFT JOIN em.OPCServer wos       ON wos.OPCServerID = w.OPCServerID
LEFT JOIN em.OPCRead r           ON r.OPCReadID = a.OPCReadID
LEFT JOIN em.OPCServer ros       ON ros.OPCServerID = r.OPCServerID
ORDER BY l.Name, t.Name, e.EventID, a.StepNumber, a.ActionID;
GO
