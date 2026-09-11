-- =============================================================================
-- 6MA CH Assembly Out -- container label / AIM readiness check.  READ-ONLY.
-- Run against the database the prod Gateway uses (MPP_MES_Prod). Every section
-- ends with a Verdict column; anything not 'OK' is a thing to configure before a
-- lights-out (PLC) container completion will claim an AIM serial + print.
--
-- Path being checked (PLC-triggered):
--   TrayInspectionWatcher -> Assembly.plcCompleteTray -> Assembly_CompleteTray
--   -> ContainerFull? -> Container.complete -> Lots.Container_Complete
--        (hard-fails 'AIM shipper ID pool is empty' when no unconsumed pool row;
--         claims a serial, renders the Honda ZPL, inserts ShippingLabel)
--   -> ShippingDispatcher.dispatch -> endpoint = the TERMINAL's child Printer
--        location's 'Endpoint' attribute -> LabelTransport (TCP host:port, or a
--        Windows queue visible to the GATEWAY service account)
--   -> AimPost.postOne (AimPoolConfig.AimPostingEnabled gate)
-- =============================================================================
SET NOCOUNT ON;
DECLARE @Terminal NVARCHAR(50) = N'MA2-6MACH-AOUT3';
DECLARE @Fg       NVARCHAR(50) = N'1223A-6MA -J000';

DECLARE @TerminalId BIGINT = (SELECT Id FROM Location.Location WHERE Code = @Terminal AND DeprecatedAt IS NULL);
DECLARE @CellId     BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @TerminalId);
DECLARE @FgId       BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = @Fg AND DeprecatedAt IS NULL);

-- 1. Printer the label will go to ------------------------------------------------
PRINT '--- 1. Printer (child of the terminal) + Endpoint';
SELECT p.Code, p.Name,
       ep.AttributeValue AS Endpoint, md.AttributeValue AS Model,
       CASE WHEN p.Id IS NULL THEN 'MISSING printer location under the terminal'
            WHEN NULLIF(LTRIM(RTRIM(ep.AttributeValue)), N'') IS NULL THEN 'SET Endpoint'
            WHEN ep.AttributeValue LIKE N'\\%' THEN 'OK (queue) - must be installed for the GATEWAY service account'
            WHEN ep.AttributeValue LIKE N'%:[0-9]%' THEN 'OK (raw TCP)'
            ELSE 'CHECK - bare name = a queue local to the Gateway host' END AS Verdict
FROM (SELECT @TerminalId AS TerminalId) t
LEFT JOIN Location.Location p ON p.ParentLocationId = t.TerminalId AND p.LocationTypeDefinitionId = 16 AND p.DeprecatedAt IS NULL
LEFT JOIN Location.LocationAttributeDefinition epd ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
LEFT JOIN Location.LocationAttribute ep ON ep.LocationId = p.Id AND ep.LocationAttributeDefinitionId = epd.Id
LEFT JOIN Location.LocationAttributeDefinition mdd ON mdd.LocationTypeDefinitionId = 16 AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
LEFT JOIN Location.LocationAttribute md ON md.LocationId = p.Id AND md.LocationAttributeDefinitionId = mdd.Id;

-- 2. AIM connection + posting gate ----------------------------------------------
PRINT '--- 2. AIM connection (Lots.AimPoolConfig)';
SELECT AimBaseUrl, AimCompanyCode,
       CASE WHEN AimPathToken IS NULL THEN 'NOT SET' ELSE 'set' END AS AimPathToken,
       AimPostingEnabled, TargetBufferDepth, TopupThreshold,
       CASE WHEN AimBaseUrl IS NULL OR AimCompanyCode IS NULL OR AimPathToken IS NULL THEN 'SET connection settings'
            WHEN ISNULL(AimPostingEnabled, 0) = 0 THEN 'POSTING DISABLED - no serial fetch, no post-back'
            WHEN AimCompanyCode = N'01' THEN 'OK - but 01 is the AIM TEST company'
            ELSE 'OK - company ' + AimCompanyCode + ' (confirm this is intended)' END AS Verdict
FROM Lots.AimPoolConfig;

-- 3. AIM serial pool ----------------------------------------------------------------
-- NOTE: provenance cannot be proven from the pool. AimPoolGateway.topupTick pools a
-- fetched serial WITHOUT FetchedInterfaceLogId, and AimHttp's success log does not
-- record the serial, so a genuinely fetched id and a hand-seeded 9-digit id look
-- identical. Compare the ids listed below against AIM's own counter.
PRINT '--- 3. AIM shipper-ID pool (unconsumed) - claim order is FetchedAt, Id';
SELECT COUNT(*) AS Unconsumed,
       SUM(CASE WHEN AimShipperId NOT LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN 1 ELSE 0 END) AS NotNineDigits,
       MIN(FetchedAt) AS OldestFetchedAtUtc, MAX(FetchedAt) AS NewestFetchedAtUtc,
       CASE WHEN COUNT(*) = 0 THEN 'EMPTY - Container_Complete will refuse (container left open)'
            WHEN SUM(CASE WHEN AimShipperId NOT LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN 1 ELSE 0 END) > 0
                 THEN 'CONTAINS NON-AIM-FORMAT IDS - they will be claimed and fail the AIM post'
            ELSE 'REVIEW - confirm the ids below came from the intended AIM company' END AS Verdict
FROM Lots.AimShipperIdPool WHERE ConsumedAt IS NULL;
SELECT TOP 10 Id, AimShipperId, FetchedAt AS FetchedAtUtc
FROM Lots.AimShipperIdPool WHERE ConsumedAt IS NULL ORDER BY FetchedAt, Id;
SELECT COUNT(*) AS AimNextserialCallsOk, MAX(il.LoggedAt) AS LastOkCall
FROM Audit.InterfaceLog il
WHERE il.SystemName = N'AIM' AND il.Description = N'AIM nextserial' AND il.ErrorCondition IS NULL;

-- 4. Honda container label template -------------------------------------------------
PRINT '--- 4. Active Container (Honda shipping) label template';
SELECT COUNT(*) AS ActiveTemplates,
       CASE COUNT(*) WHEN 1 THEN 'OK' WHEN 0 THEN 'MISSING - label renders empty' ELSE 'MORE THAN ONE ACTIVE' END AS Verdict
FROM Lots.LabelTemplate lt JOIN Lots.LabelTypeCode c ON c.Id = lt.LabelTypeCodeId
WHERE c.Code = N'Container' AND lt.DeprecatedAt IS NULL;

-- 5. Finished good: label fields + pack-out -----------------------------------------
PRINT '--- 5. Finished good + ByVision pack-out';
SELECT i.PartNumber, i.Description, i.CountryOfOrigin, i.PlcId,
       Parts.ufn_AimCustomerPartNumber(i.PartNumber) AS AimCustomerPart,
       cc.PartsPerTray, cc.TraysPerContainer, cc.PartsPerTray * cc.TraysPerContainer AS PartsPerContainer,
       CASE WHEN i.Id IS NULL THEN 'FG NOT FOUND'
            WHEN cc.Id IS NULL THEN 'NO ByVision ContainerConfig'
            WHEN i.PlcId IS NULL THEN 'SET PlcId'
            ELSE 'OK' END AS Verdict
FROM (SELECT @FgId AS FgId) f
LEFT JOIN Parts.Item i ON i.Id = f.FgId
LEFT JOIN Parts.ContainerConfig cc ON cc.ItemId = i.Id AND cc.ClosureMethod = N'ByVision' AND cc.DeprecatedAt IS NULL;

-- 6. Container already open at the line ---------------------------------------------
PRINT '--- 6. Open container(s) at the line and progress';
SELECT c.Id AS ContainerId, i.PartNumber, c.OpenedAt,
       COUNT(ct.Id) AS TraysClosed, SUM(ISNULL(ct.PartsClosedCount, 0)) AS PartsClosed
FROM Lots.Container c
JOIN Parts.Item i ON i.Id = c.ItemId
JOIN Lots.ContainerStatusCode s ON s.Id = c.ContainerStatusCodeId AND s.Code = N'Open'
LEFT JOIN Lots.ContainerTray ct ON ct.ContainerId = c.Id AND ct.ClosedAt IS NOT NULL
WHERE c.CurrentLocationId = @CellId
GROUP BY c.Id, i.PartNumber, c.OpenedAt;

-- 7. Components on the line vs one tray's draw --------------------------------------
PRINT '--- 7. BOM components available at the line (one tray = PartsPerTray x QtyPer)';
DECLARE @Ppt INT = (SELECT TOP 1 PartsPerTray FROM Parts.ContainerConfig
                    WHERE ItemId = @FgId AND ClosureMethod = N'ByVision' AND DeprecatedAt IS NULL);
SELECT ch.PartNumber AS Component, bl.QtyPer, bl.QtyPer * @Ppt AS NeededPerTray,
       ISNULL(SUM(l.PieceCount), 0) AS OnHandAtLine,
       CASE WHEN ISNULL(SUM(l.PieceCount), 0) >= bl.QtyPer * @Ppt THEN 'OK' ELSE 'SHORT' END AS Verdict
FROM Parts.Bom b
JOIN Parts.BomLine bl ON bl.BomId = b.Id
JOIN Parts.Item ch ON ch.Id = bl.ChildItemId
LEFT JOIN Lots.Lot l ON l.ItemId = ch.Id AND l.PieceCount > 0
     AND l.LotStatusId IN (SELECT Id FROM Lots.LotStatusCode WHERE Code IN (N'Good', N'Open'))
     AND (l.CurrentLocationId = @CellId
          OR l.CurrentLocationId IN (SELECT Id FROM Location.Location WHERE ParentLocationId = @CellId))
WHERE b.ParentItemId = @FgId AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
GROUP BY ch.PartNumber, bl.QtyPer, bl.SortOrder
ORDER BY bl.SortOrder;

-- 8. PLC mapping ---------------------------------------------------------------------
PRINT '--- 8. Terminal -> PLC device mapping';
SELECT d.DeviceCode, d.UdtInstancePath,
       CASE WHEN d.Id IS NULL THEN 'MISSING TerminalPlcDevice row' ELSE 'OK' END AS Verdict
FROM (SELECT @TerminalId AS TerminalId) t
LEFT JOIN Location.TerminalPlcDevice d ON d.TerminalLocationId = t.TerminalId AND d.DeprecatedAt IS NULL;
