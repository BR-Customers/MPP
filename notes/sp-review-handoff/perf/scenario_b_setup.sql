-- Scenario B: realistic queue (40 open received LOTs at the station) + large inspection history (~190k samples).
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @SpecVer BIGINT = (SELECT TOP 1 Id FROM Quality.QualitySpecVersion WHERE QualitySpecId = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'PERFR-SPEC'));

UPDATE Lots.Lot SET LotStatusId = 4, InventoryAvailable = 0
WHERE LotName LIKE N'PERFR-%' AND LotStatusId <> 4 AND CAST(SUBSTRING(LotName, 7, 12) AS INT) > 40;

INSERT INTO Quality.QualitySample (LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId, InspectionResultCodeId, SampledByUserId, SampledAt)
SELECT l.Id, @SpecVer, l.CurrentLocationId, 9, 1 + ((l.Id + k.n) % 3), 1, DATEADD(MINUTE, 100 + k.n * 11, l.CreatedAt)
FROM Lots.Lot l
CROSS JOIN (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects) k
WHERE l.LotName LIKE N'PERFR-%' AND l.LotStatusId = 4;

UPDATE STATISTICS Lots.Lot WITH FULLSCAN;
UPDATE STATISTICS Quality.QualitySample WITH FULLSCAN;
SELECT (SELECT COUNT(*) FROM Lots.Lot WHERE LotName LIKE N'PERFR-%' AND LotStatusId <> 4) AS OpenReceived,
       (SELECT COUNT(*) FROM Quality.QualitySample) AS Samples,
       (SELECT used_page_count FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('Quality.QualitySample') AND index_id = 1) AS SamplePages;
