-- verify_demo_quality.sql -- the quality scenario sql/seeds_demo/opt/060_demo_quality_scenario.sql
-- leaves in MPP_MES_Demo (sales-kit module 4). Run only by Build-DemoDatabase.ps1 -WithQualityScenario.
SET NOCOUNT ON;
IF DB_NAME() <> N'MPP_MES_Demo' BEGIN RAISERROR('verify_demo_quality: must run against MPP_MES_Demo', 16, 1); RETURN; END
DECLARE @r TABLE (Seq INT IDENTITY, Ok BIT, Check_ NVARCHAR(200));
DECLARE @L1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L-1');
DECLARE @Store BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM-STORE');
DECLARE @Run BIGINT = (SELECT Id FROM Quality.ControlledRun WHERE RunNumber = N'CR000001');
DECLARE @Q TABLE (Id BIGINT, LotName NVARCHAR(50), ItemId BIGINT, ItemPartNumber NVARCHAR(50), ItemDescription NVARCHAR(500),
    PieceCount INT, LotStatusId BIGINT, LotStatusCode NVARCHAR(20), LastMovementAt DATETIME2(3),
    NextOperationTypeCode NVARCHAR(20), NextSequenceNumber INT, Role NVARCHAR(20) NULL);

INSERT @Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
    EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @Store, @OperationTypeCode = N'MachiningIn', @IncludeDescendants = 0;
UPDATE @Q SET Role = N'MachiningIn' WHERE Role IS NULL;
INSERT @Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
    EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @L1, @OperationTypeCode = N'MachiningOut', @IncludeDescendants = 1;
UPDATE @Q SET Role = N'MachiningOut' WHERE Role IS NULL;
INSERT @Q (Id, LotName, ItemId, ItemPartNumber, ItemDescription, PieceCount, LotStatusId, LotStatusCode, LastMovementAt, NextOperationTypeCode, NextSequenceNumber)
    EXEC Lots.Lot_GetWipQueueByLocation @LocationId = @L1, @OperationTypeCode = N'AssemblyOut', @IncludeDescendants = 1;
UPDATE @Q SET Role = N'AssemblyOut' WHERE Role IS NULL;

-- the problem LOT: one open hard Hold, on a casting no module 1-3 capture is about
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Quality.HoldEvent WHERE ReleasedAt IS NULL) = 1
    AND EXISTS (SELECT 1 FROM Quality.HoldEvent h JOIN Lots.Lot l ON l.Id = h.LotId JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId
                WHERE h.ReleasedAt IS NULL AND s.Code = N'Hold' AND l.ToolId IS NOT NULL
                  AND l.LotName NOT IN (N'520100001', N'520100003'))
    THEN 1 ELSE 0 END, N'one open hard Hold, on a casting outside the module 1-3 captures';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Quality.ControlledRun r JOIN Quality.ControlledRunStatusCode s ON s.Id = r.ControlledRunStatusId
    WHERE r.Id = @Run AND s.Code = N'Open' AND r.AutoJoinEnabled = 1) THEN 1 ELSE 0 END, N'CR000001 open with auto-join on';

-- members of every kind the story needs (current members: EndedAt IS NULL)
DECLARE @M TABLE (LotId BIGINT NULL, ContainerId BIGINT NULL, AddedAt DATETIME2(3));
INSERT @M SELECT LotId, ContainerId, AddedAt FROM Quality.ControlledRunMember WHERE ControlledRunId = @Run AND EndedAt IS NULL;
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM @Q q JOIN @M m ON m.LotId = q.Id JOIN Lots.Lot l ON l.Id = q.Id
    WHERE q.Role = N'MachiningIn' AND l.CrtActive = 1 AND q.LotStatusCode = N'Good') THEN 1 ELSE 0 END, N'a tagged casting (status Good) waiting for Machining IN';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM @Q q JOIN @M m ON m.LotId = q.Id JOIN Lots.Lot l ON l.Id = q.Id
    WHERE q.Role = N'MachiningOut' AND l.CrtActive = 1) THEN 1 ELSE 0 END, N'a tagged casting in the Machining OUT queue';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM @Q q JOIN @M m ON m.LotId = q.Id JOIN Lots.Lot l ON l.Id = q.Id
    WHERE q.Role = N'AssemblyOut' AND l.CrtActive = 1) THEN 1 ELSE 0 END, N'a tagged machined LOT waiting at Assembly OUT';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM @M m JOIN Lots.Lot l ON l.Id = m.LotId JOIN Quality.ControlledRun r ON r.Id = @Run
    WHERE l.CrtActive = 1 AND l.CreatedAt > r.OpenedAt AND l.ToolId IS NOT NULL) THEN 1 ELSE 0 END, N'a basket opened after the run joined by auto-join, born tagged';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Lots.Lot l JOIN Lots.LotGenealogy g ON g.ChildLotId = l.Id JOIN Lots.Lot p ON p.Id = g.ParentLotId
    JOIN Quality.ControlledRun r ON r.Id = @Run
    WHERE l.CrtActive = 1 AND l.CreatedAt > r.OpenedAt AND p.CrtActive = 1) THEN 1 ELSE 0 END, N'a LOT made from a tagged input, born tagged';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM @M m JOIN Lots.Container c ON c.Id = m.ContainerId WHERE c.CompletedAt IS NOT NULL)
    THEN 1 ELSE 0 END, N'a completed container pulled back into the run';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM @M m JOIN Lots.Lot l ON l.Id = m.LotId JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
    JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId WHERE o.Code = N'Received' AND s.Code = N'Good' AND l.PieceCount > 0)
    THEN 1 ELSE 0 END, N'an open received LOT among the members (Return to vendor offered)';

-- results part-way; nothing signed yet
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Quality.ControlledRunResult rr JOIN Quality.ControlledRunMember m ON m.Id = rr.ControlledRunMemberId
        WHERE m.ControlledRunId = @Run AND rr.VoidedAt IS NULL)
    AND EXISTS (SELECT 1 FROM Quality.ControlledRunMember m WHERE m.ControlledRunId = @Run AND m.EndedAt IS NULL
        AND NOT EXISTS (SELECT 1 FROM Quality.ControlledRunResult rr WHERE rr.ControlledRunMemberId = m.Id AND rr.VoidedAt IS NULL))
    THEN 1 ELSE 0 END, N'results recorded for some members, missing for others';
INSERT @r SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM Quality.Signature) THEN 1 ELSE 0 END, N'nothing released or deviated yet (no signatures)';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Location.AppUser WHERE Initials = N'EN' AND Pin = N'61030' AND AdAccount IS NOT NULL)
    THEN 1 ELSE 0 END, N'sample Quality user EN exists with an AD account';

SELECT CASE Ok WHEN 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Check_ AS Result FROM @r ORDER BY Seq;
IF EXISTS (SELECT 1 FROM @r WHERE Ok = 0) RAISERROR('verify_demo_quality: one or more checks FAILED', 16, 1);
