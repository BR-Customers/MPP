/* ============================================================================
   emmd_extract_automation_config.sql  --  EMMD (Flexware Execution Management)
   ----------------------------------------------------------------------------
   TARGET   Legacy "EMMD" automation-engine database on EXCSRV05.
   SCOPE    Integration / OPC / handshake configuration ONLY.  This is NOT
            master/reference data (no parts/BOM/routes live here) -- it is the
            ground-truth wiring of the PLC/OPC touchpoints and the scripts that
            run at each machine event.  Useful for:
              * cross-checking the opc_tags seed (FRS Appendix C)
              * understanding the real MIP handshake logic (Script bodies)
            The huge Log_* / emperf tables (raw event history) are EXCLUDED --
            those are a separate OEE/downtime pass.

   HOW TO RUN
     Execute against EMMD.  Emits labeled grids (#H..#N).  Everything is small
     EXCEPT #N SCRIPT (143 script bodies, up to 8000 chars each) -- paste that
     one separately, or skip it and I'll request specific scripts by name.

   100% read-only; READ UNCOMMITTED so it never blocks the live engine.
   ============================================================================ */

USE EMMD;
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ---- #H  Automation topology: Plant -> Line -> Task ---- */
SELECT '#H TOPOLOGY' AS Grid, 'Plant' AS Tier, p.PlantID AS Id, p.Name,
       CAST(NULL AS int) AS ParentId, CAST(NULL AS varchar(50)) AS ParentName, p.Active
FROM em.Plant p
UNION ALL
SELECT '#H TOPOLOGY','Line', l.LineID, l.Name, l.PlantID, p.Name, l.Active
FROM em.Line l LEFT JOIN em.Plant p ON p.PlantID = l.PlantID
UNION ALL
SELECT '#H TOPOLOGY','Task', t.TaskID, t.Name, t.LineID, l.Name, t.Active
FROM em.Task t LEFT JOIN em.Line l ON l.LineID = t.LineID
ORDER BY Tier, ParentId, Id;

/* ---- #I  Events: what each event watches (OPC item) + trigger ---- */
SELECT '#I EVENT' AS Grid, e.EventID AS Id, e.Name, e.Description,
       t.Name AS Task, l.Name AS Line,
       os.OPCServerName AS OpcServer, e.AccessPath, e.OPCItemID,
       trg.Name AS Trigger_, e.TriggerArg1, e.TriggerArg2,
       e.IsMessageHandler, e.ReactOnStartup, e.Active
FROM em.Event e
LEFT JOIN em.Task t             ON t.TaskID = e.TaskID
LEFT JOIN em.Line l             ON l.LineID = t.LineID
LEFT JOIN em.OPCServer os       ON os.OPCServerID = e.OPCServerID
LEFT JOIN em.TriggerOperation trg ON trg.TriggerOperationID = e.TriggerOperationID
ORDER BY l.Name, t.Name, e.EventID;

/* ---- #J  Actions: ordered steps per event (OPC read/write or script) ---- */
SELECT '#J ACTION' AS Grid, a.ActionID AS Id, e.Name AS Event_, a.StepNumber,
       a.Name, a.Description,
       CASE WHEN a.OPCWriteID IS NOT NULL THEN 'WRITE'
            WHEN a.OPCReadID  IS NOT NULL THEN 'READ'
            WHEN a.ScriptID   IS NOT NULL THEN 'SCRIPT'
            ELSE 'OTHER' END AS Kind,
       wr.OPCItemID AS WriteItem, rd.OPCItemID AS ReadItem, a.ScriptID, a.Active
FROM em.Action a
LEFT JOIN em.Event e    ON e.EventID = a.EventID
LEFT JOIN em.OPCWrite wr ON wr.OPCWriteID = a.OPCWriteID
LEFT JOIN em.OPCRead rd  ON rd.OPCReadID = a.OPCReadID
ORDER BY e.Name, a.StepNumber, a.ActionID;

/* ---- #K  OPC item catalog: servers + all read/write items ---- */
SELECT '#K OPC' AS Grid, 'Server' AS Kind, os.OPCServerID AS Id, os.OPCServerName AS Name,
       os.OPCServerPID AS AccessPathOrPID, CAST(NULL AS varchar(1000)) AS OPCItemID, os.OPCServerHost AS Host
FROM em.OPCServer os
UNION ALL
SELECT '#K OPC','Read', r.OPCReadID, os.OPCServerName, r.AccessPath, r.OPCItemID, NULL
FROM em.OPCRead r LEFT JOIN em.OPCServer os ON os.OPCServerID = r.OPCServerID
UNION ALL
SELECT '#K OPC','Write', w.OPCWriteID, os.OPCServerName, w.AccessPath, w.OPCItemID, NULL
FROM em.OPCWrite w LEFT JOIN em.OPCServer os ON os.OPCServerID = w.OPCServerID
ORDER BY Kind, Id;

/* ---- #L  Action data wiring: inputs + outputs (how steps pass values) ---- */
SELECT '#L ACTIONIO' AS Grid, 'Input' AS Kind, ai.ActionInputID AS Id, ai.ActionID,
       ai.Name, ai.Value, ai.ActionOutputID AS LinkedOutputId
FROM em.ActionInput ai
UNION ALL
SELECT '#L ACTIONIO','Output', ao.ActionOutputID, ao.ActionID, ao.Name, NULL, ao.EventID
FROM em.ActionOutput ao
ORDER BY Kind, ActionID, Id;

/* ---- #M  TriggerOperation code table ---- */
SELECT '#M TRIGGEROP' AS Grid, TriggerOperationID AS Id, Name, Description,
       ArgumentCount, DisplayOrder
FROM em.TriggerOperation
ORDER BY DisplayOrder, TriggerOperationID;

/* ---- #N  SCRIPT bodies  (LARGE -- 143 rows, bodies up to 8000 chars).
        Paste separately, or skip and I'll request specific ScriptIDs. ---- */
SELECT '#N SCRIPT' AS Grid, s.ScriptID AS Id, s.ScriptLanguage,
       LEN(s.ScriptBody) AS BodyLen, s.ScriptBody
FROM em.Script s
ORDER BY s.ScriptID;
GO
