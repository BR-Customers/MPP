-- verify_demo_scenario.sql -- the production history 050_demo_scenario.sql leaves in MPP_MES_Demo.
SET NOCOUNT ON;
IF DB_NAME() <> N'MPP_MES_Demo' BEGIN RAISERROR('verify_demo_scenario: must run against MPP_MES_Demo', 16, 1); RETURN; END
DECLARE @r TABLE (Seq INT IDENTITY, Ok BIT, Check_ NVARCHAR(200));
DECLARE @L1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L-1');

-- a tray in a completed container traces back to a casting cast on a press cavity
INSERT @r SELECT CASE WHEN EXISTS (
    SELECT 1 FROM Lots.ContainerTray ct
    JOIN Lots.Container c ON c.Id = ct.ContainerId AND c.CompletedAt IS NOT NULL
    JOIN Lots.LotGenealogyClosure g ON g.DescendantLotId = ct.FinishedGoodLotId AND g.Depth >= 2
    JOIN Lots.Lot a ON a.Id = g.AncestorLotId AND a.ToolId IS NOT NULL AND a.ToolCavityId IS NOT NULL)
  THEN 1 ELSE 0 END, N'packed tray traces back to a press cavity';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Lots.Container WHERE CompletedAt IS NOT NULL) >= 2 THEN 1 ELSE 0 END, N'at least two completed containers';
-- castings waiting for Machining IN: trimmed (Trim OUT puts them in trim storage) and not yet
-- picked -- the Machining IN pick is what pulls a LOT from storage onto the line.
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Lots.Lot l JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
    WHERE loc.Code = N'TRIM-STORE' AND l.LotName IN (N'520100004', N'520300001')) = 2 THEN 1 ELSE 0 END, N'two trimmed castings waiting for Machining IN';
INSERT @r SELECT CASE WHEN (SELECT PieceCount FROM Lots.Lot WHERE LotName = N'520100003') = 32 THEN 1 ELSE 0 END, N'casting 520100003 part-way through Machining OUT (32 of 48)';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId JOIN Parts.Item i ON i.Id = l.ItemId
    WHERE s.Code = N'Open' AND i.PartNumber LIKE N'%-%' AND l.ToolId IS NOT NULL) >= 7 THEN 1 ELSE 0 END, N'baskets open on the presses';
INSERT @r SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM Lots.Lot l JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId JOIN Tools.Tool t ON t.Id = tc.ToolId
    JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId WHERE t.Code = N'D-240' AND tc.CavityCode = N'b' AND s.Code = N'Open') THEN 1 ELSE 0 END, N'P-03 cavity b has no basket (pending shots)';
INSERT @r SELECT CASE WHEN EXISTS (SELECT 1 FROM Workorder.RejectEvent re JOIN Tools.Tool t ON t.Id = re.ToolId WHERE t.Code = N'D-220') THEN 1 ELSE 0 END, N'die cast scrap recorded on the family die';
INSERT @r SELECT CASE WHEN (SELECT SUM(l.PieceCount) FROM Lots.Lot l JOIN Parts.Item i ON i.Id = l.ItemId JOIN Lots.LotOriginType o ON o.Id = l.LotOriginTypeId
    WHERE i.PartNumber = N'SEAL-01' AND o.Code = N'Received' AND l.CurrentLocationId = @L1) BETWEEN 12 AND 23 THEN 1 ELSE 0 END, N'seal kits one tray from the lock (12..23 left)';
INSERT @r SELECT CASE WHEN (SELECT COUNT(*) FROM Lots.Lot l JOIN Parts.Item i ON i.Id = l.ItemId JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
    WHERE i.PartNumber IN (N'HSG-410', N'HSG-440') AND loc.Code = N'TRIM') >= 2 THEN 1 ELSE 0 END, N'baskets waiting at trim';
-- the base build carries no quality state: modules 1-3 are captured without holds or super-lots
-- (Build-DemoDatabase.ps1 runs this before the opt quality scenario is loaded)
INSERT @r SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM Quality.ControlledRun) AND NOT EXISTS (SELECT 1 FROM Quality.HoldEvent)
    THEN 1 ELSE 0 END, N'no super-lot and no hold in the base build';
SELECT CASE Ok WHEN 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Check_ AS Result FROM @r ORDER BY Seq;
IF EXISTS (SELECT 1 FROM @r WHERE Ok = 0) RAISERROR('verify_demo_scenario: one or more checks FAILED', 16, 1);
