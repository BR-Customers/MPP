-- =============================================================================
-- 6MA CH parallel run (MES beside legacy) -- post-deploy + daily check. READ-ONLY.
-- Run against the database the prod Gateway uses (MPP_MES_Prod), in SSMS or:
--   sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -i sql\scratch\2026-09-11_6ma_parallel_run_check.sql -C -W -s "|"
--   (password from $env:SQLCMDPASSWORD -- never on the command line)
--
-- Every section ends with a Verdict column. Context:
--   notes/2026-09-11_6ma-ch-real-ladder-slcpasspulse.md
--   * Migration 0079 + Lots.Container_Complete v1.2: terminal attribute
--     SuppressAimAndLabel = 1 completes boxes with NO AIM claim and NO label.
--   * TrayInspectionWatcher SlcPassPulse books one ByVision tray per N7:10 pulse.
-- =============================================================================
SET NOCOUNT ON;
DECLARE @Terminal NVARCHAR(50) = N'MA2-6MACH-AOUT3';
DECLARE @Fg       NVARCHAR(50) = N'1223A-6MA -J000';
DECLARE @Days     INT          = 3;      -- look-back for sections 4-6

DECLARE @TerminalId BIGINT = (SELECT Id FROM Location.Location WHERE Code = @Terminal AND DeprecatedAt IS NULL);
DECLARE @CellId     BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @TerminalId);
DECLARE @FgId       BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = @Fg AND DeprecatedAt IS NULL);
DECLARE @Since      DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());

-- 1. The release landed ---------------------------------------------------------
PRINT '--- 1. Release: migrations 0078/0079 + Container_Complete v1.2';
SELECT m.MigrationId,
       CASE WHEN sv.MigrationId IS NULL THEN 'MISSING - run Deploy-ProdRelease' ELSE 'OK' END AS Verdict
FROM (VALUES (N'0078_container_station'), (N'0079_terminal_suppress_aim_label')) m(MigrationId)
LEFT JOIN dbo.SchemaVersion sv ON sv.MigrationId = m.MigrationId
UNION ALL
SELECT N'Lots.Container_Complete v1.2',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'Lots.Container_Complete')) LIKE N'%SuppressAimAndLabel%'
            THEN 'OK' ELSE 'OLD PROC - run Deploy-ProdRelease' END;

-- 2. The terminal switch -------------------------------------------------------
PRINT '--- 2. SuppressAimAndLabel on the 6MA CH terminals (1 = no AIM, no label)';
SELECT l.Code, l.Name,
       ISNULL(la.AttributeValue, N'(not set)') AS SuppressAimAndLabel,
       CASE WHEN l.Id = @TerminalId AND LOWER(ISNULL(la.AttributeValue, N'')) IN (N'1', N'true', N'yes')
                 THEN 'OK - parallel run: boxes complete without AIM/label'
            WHEN l.Id = @TerminalId
                 THEN 'OFF - a full box WILL claim AIM + print (set it in Config Tool > Plant Hierarchy)'
            WHEN LOWER(ISNULL(la.AttributeValue, N'')) IN (N'1', N'true', N'yes')
                 THEN 'ON - suppressed here too'
            ELSE 'off (normal)' END AS Verdict
FROM Location.Location l
LEFT JOIN Location.LocationAttributeDefinition lad
       ON lad.LocationTypeDefinitionId = l.LocationTypeDefinitionId AND lad.AttributeName = N'SuppressAimAndLabel' AND lad.DeprecatedAt IS NULL
LEFT JOIN Location.LocationAttribute la ON la.LocationId = l.Id AND la.LocationAttributeDefinitionId = lad.Id
WHERE l.ParentLocationId = @CellId AND l.LocationTypeDefinitionId = 7 AND l.DeprecatedAt IS NULL
ORDER BY l.Code;

-- 3. The recipe the watcher compares against N16:2 ------------------------------
PRINT '--- 3. Finished good recipe (Item.PlcId must equal the vision program, N16:2)';
SELECT i.PartNumber, i.PlcId,
       CASE WHEN i.Id IS NULL THEN 'MISSING finished good'
            WHEN i.PlcId IS NULL THEN 'SET PlcId (Config Tool > Items > Identity)'
            ELSE 'OK - expect N16:2 = ' + CAST(i.PlcId AS NVARCHAR(10)) END AS Verdict
FROM (SELECT @FgId AS FgId) f
LEFT JOIN Parts.Item i ON i.Id = f.FgId;

-- 4. Boxes at the vision terminal: none should carry a label or an AIM serial ----
PRINT '--- 4. Containers at the vision terminal (last @Days days, ET)';
SELECT c.Id AS ContainerId,
       CASE c.ContainerStatusCodeId WHEN 1 THEN 'Open' WHEN 2 THEN 'Complete' ELSE CAST(c.ContainerStatusCodeId AS NVARCHAR(10)) END AS Status,
       CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS OpenedET,
       CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS CompletedET,
       (SELECT COUNT(*) FROM Lots.ContainerTray t WHERE t.ContainerId = c.Id AND t.ClosedAt IS NOT NULL) AS Trays,
       (SELECT ISNULL(SUM(t.PartsClosedCount), 0) FROM Lots.ContainerTray t WHERE t.ContainerId = c.Id AND t.ClosedAt IS NOT NULL) AS Parts,
       (SELECT COUNT(*) FROM Lots.ShippingLabel s WHERE s.ContainerId = c.Id) AS LabelRows,
       (SELECT TOP 1 p.AimShipperId FROM Lots.AimShipperIdPool p WHERE p.ConsumedByContainerId = c.Id) AS AimSerial,
       CASE WHEN c.ContainerStatusCodeId = 1 THEN 'open - filling'
            WHEN EXISTS (SELECT 1 FROM Lots.ShippingLabel s WHERE s.ContainerId = c.Id)
              OR EXISTS (SELECT 1 FROM Lots.AimShipperIdPool p WHERE p.ConsumedByContainerId = c.Id)
                 THEN 'LABELLED/AIM - completed with the switch OFF'
            ELSE 'OK - suppressed (MES record only)' END AS Verdict
FROM Lots.Container c
WHERE (c.StationLocationId = @TerminalId
       OR (c.StationLocationId IS NULL AND c.CurrentLocationId = @CellId AND c.ItemId = @FgId))
  AND (c.ContainerStatusCodeId = 1 OR c.CompletedAt >= @Since)
ORDER BY c.Id DESC;

-- 5. AIM pool: nothing consumed by this terminal's boxes --------------------------
PRINT '--- 5. AIM serials consumed by containers at the vision terminal (last @Days days)';
SELECT COUNT(*) AS SerialsConsumed,
       CASE WHEN COUNT(*) = 0 THEN 'OK - none' ELSE 'CHECK - serials were claimed (see section 4)' END AS Verdict
FROM Lots.AimShipperIdPool p
INNER JOIN Lots.Container c ON c.Id = p.ConsumedByContainerId
WHERE p.ConsumedAt >= @Since
  AND (c.StationLocationId = @TerminalId OR (c.StationLocationId IS NULL AND c.CurrentLocationId = @CellId AND c.ItemId = @FgId));

-- 6. What the PLC watcher did --------------------------------------------------
PRINT '--- 6. InterfaceLog PLC:6MA_CH (last 40, ET)';
SELECT TOP 40
       CAST(il.LoggedAt AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(0)) AS LoggedET,
       il.Description,
       LEFT(ISNULL(il.RequestPayload, N''), 120)  AS Request,
       LEFT(ISNULL(il.ErrorDescription, N''), 160) AS Error
FROM Audit.InterfaceLog il
WHERE il.SystemName = N'PLC:6MA_CH' AND il.LoggedAt >= @Since
ORDER BY il.Id DESC;

PRINT '--- 6b. Watcher outcomes by kind (last @Days days)';
SELECT il.Description, COUNT(*) AS N,
       CASE WHEN il.Description LIKE N'ByVision tray close' THEN 'good tray booked'
            WHEN il.Description LIKE N'%NOT booked (vision program mismatch)%' THEN 'master tray / override / changeover'
            WHEN il.Description LIKE N'%write suppressed%' THEN 'DisableWriteback: legacy and MES recipes differ'
            WHEN il.Description LIKE N'%NOT booked%' THEN 'CHECK'
            ELSE '' END AS Meaning
FROM Audit.InterfaceLog il
WHERE il.SystemName = N'PLC:6MA_CH' AND il.LoggedAt >= @Since
GROUP BY il.Description
ORDER BY N DESC;
