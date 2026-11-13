-- Inspection-shaped synthetic load for MPP_MES_Perf (throwaway).
-- 9,000 received-origin LOTs (600 open at the station, rest Closed spread over 5 locations) + ~20k QualitySample rows.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName LIKE N'PERFR-%') RAISERROR(N'already loaded', 16, 1);

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Station BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
IF @Station IS NULL RAISERROR(N'INSP-SORT-T1 not found', 16, 1);

IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'P-INSP-TP')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'P-INSP-TP', N'Third-party pass-through part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'P-INSP-TP');

IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpec WHERE Name = N'PERFR-SPEC')
    INSERT INTO Quality.QualitySpec (Name, CreatedAt) VALUES (N'PERFR-SPEC', @Now);
DECLARE @Spec BIGINT = (SELECT Id FROM Quality.QualitySpec WHERE Name = N'PERFR-SPEC');
IF NOT EXISTS (SELECT 1 FROM Quality.QualitySpecVersion WHERE QualitySpecId = @Spec)
    INSERT INTO Quality.QualitySpecVersion (QualitySpecId, VersionNumber, EffectiveFrom, CreatedByUserId, CreatedAt)
    VALUES (@Spec, 1, @Now, 1, @Now);
DECLARE @SpecVer BIGINT = (SELECT TOP 1 Id FROM Quality.QualitySpecVersion WHERE QualitySpecId = @Spec);

-- 5 locations: the station + 4 others (deterministic)
DECLARE @Locs TABLE (Seq INT PRIMARY KEY, Id BIGINT NOT NULL);
INSERT INTO @Locs (Seq, Id) VALUES (1, @Station);
INSERT INTO @Locs (Seq, Id)
SELECT 1 + ROW_NUMBER() OVER (ORDER BY x.Id), x.Id
FROM (SELECT TOP (4) Id FROM Location.Location WHERE Id <> @Station ORDER BY ABS(CHECKSUM(Id))) x;

;WITH N AS (SELECT TOP (9000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO Lots.Lot (LotName, ItemId, LotOriginTypeId, LotStatusId, PieceCount, CurrentLocationId, VendorLotNumber,
                      CrtActive, TotalInProcess, InventoryAvailable, CreatedByUserId, CreatedAt)
SELECT N'PERFR-' + CAST(n AS NVARCHAR(12)), @Item,
       CASE WHEN n % 5 = 0 THEN 3 ELSE 2 END,                  -- Received / ReceivedOffsite
       CASE WHEN n <= 600 THEN 1 ELSE 4 END,                   -- first 600 open (Good), rest Closed
       50,
       CASE WHEN n <= 600 THEN @Station
            ELSE (SELECT Id FROM @Locs WHERE Seq = 1 + (n % 5)) END,
       N'VEND-' + CAST(n AS NVARCHAR(12)),
       0, 0, CASE WHEN n <= 600 THEN 50 ELSE 0 END, 1,
       DATEADD(MINUTE, -n * 40, @Now)
FROM N;

INSERT INTO Lots.LotMovement (LotId, FromLocationId, ToLocationId, MovedByUserId, TerminalLocationId, MovedAt)
SELECT l.Id, NULL, l.CurrentLocationId, 1, NULL, l.CreatedAt FROM Lots.Lot l WHERE l.LotName LIKE N'PERFR-%';

-- 1..3 samples per LOT (~20k); result alternates Pass(1)/Fail(2)/Conditional(3)
INSERT INTO Quality.QualitySample (LotId, QualitySpecVersionId, LocationId, SampleTriggerCodeId, InspectionResultCodeId, SampledByUserId, SampledAt)
SELECT l.Id, @SpecVer, l.CurrentLocationId, 9, 1 + ((l.Id + k.k) % 3), 1, DATEADD(MINUTE, k.k * 7, l.CreatedAt)
FROM Lots.Lot l
CROSS JOIN (VALUES (1),(2),(3)) k(k)
WHERE l.LotName LIKE N'PERFR-%' AND k.k <= 1 + (l.Id % 3);

UPDATE STATISTICS Lots.Lot WITH FULLSCAN;
UPDATE STATISTICS Lots.LotMovement WITH FULLSCAN;
UPDATE STATISTICS Quality.QualitySample WITH FULLSCAN;

SELECT (SELECT COUNT(*) FROM Lots.Lot WHERE LotName LIKE N'PERFR-%') AS ReceivedLots,
       (SELECT COUNT(*) FROM Lots.Lot WHERE LotName LIKE N'PERFR-%' AND LotStatusId <> 4) AS OpenReceived,
       (SELECT COUNT(*) FROM Quality.QualitySample) AS Samples,
       @Station AS StationId;
