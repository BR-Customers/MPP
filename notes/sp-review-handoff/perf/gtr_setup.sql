-- Perf DB fixture for Assembly_GetTraysRemaining: P-INSP-TP (9,000 received LOTs, 40 open at the station, ~1,700 closed there).
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Pt BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-INSP-TP');
IF @Pt IS NULL RAISERROR(N'run load_perf_insp.sql first', 16, 1);
DECLARE @FgType BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'PERF-GTR-FG')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId) VALUES (@FgType, N'PERF-GTR-FG', N'perf finished good', 1, @Now, 1);
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'PERF-GTR-FG');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Pt AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Pt, 4, 24, 0, N'ByCount', @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Fg AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt) VALUES (@Fg, 4, 10, 0, N'ByCount', @Now);
IF NOT EXISTS (SELECT 1 FROM Parts.Bom WHERE ParentItemId = @Fg)
BEGIN
    INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, CreatedByUserId, CreatedAt) VALUES (@Fg, 1, @Now, @Now, 1, @Now);
    INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) VALUES (SCOPE_IDENTITY(), @Pt, 2, 1, 1);
END
SELECT (SELECT ItemTypeId FROM Parts.Item WHERE Id = @Pt) AS PtItemTypeId, (SELECT Id FROM Parts.ItemType WHERE Code = N'PassThrough') AS PassThroughTypeId,
       (SELECT COUNT(*) FROM Lots.Lot WHERE ItemId = @Pt AND CurrentLocationId = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1')) AS LotsAtStation;
