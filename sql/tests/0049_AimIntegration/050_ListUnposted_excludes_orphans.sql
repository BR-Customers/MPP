-- =============================================
-- File: 0049_AimIntegration/050_ListUnposted_excludes_orphans.sql
-- Desc: A consumed-but-unposted serial whose container no longer exists is NOT
--       owed to AIM and must never reach the retry sweep.
--
--       The shape is real: the 2026-09-09 prod FAT purge deleted the FAT
--       containers and NULLed Lots.AimShipperIdPool.ConsumedByContainerId on
--       their seven synthetic serials (999000001-007), leaving them consumed,
--       PostedAt NULL, with their frozen Quantity / LotNumber intact. ListUnposted
--       is the single query behind AimPost.retryTick (AimPostTimer), the owed-to-
--       AIM backlog screen and alarmTick's age escalation; before v1.4 it
--       returned those rows, so enabling the timer against a live company code
--       would POST serials AIM never issued, with FAT data, to Honda.
--
--       Control: a container-bound owed row is still listed, so the proc is not
--       merely returning nothing.
-- =============================================
EXEC test.BeginTestFile @FileName = N'0049_AimIntegration/050_ListUnposted_excludes_orphans.sql';
GO

-- Cleanup (idempotent, run before AND after). The pool is global and
-- part-agnostic; a blanket clear keeps this file's rows the only ones in play.
DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-ORPHAN-FK');
GO

DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM Parts.Item WHERE PartNumber = N'AIM-ORPHAN-FK')
    INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedAt, CreatedByUserId)
    VALUES (3, N'AIM-ORPHAN-FK', N'AIM orphan-serial fixture part', 1, @Now, 1);
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-ORPHAN-FK');
IF NOT EXISTS (SELECT 1 FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)
    INSERT INTO Parts.ContainerConfig (ItemId, TraysPerContainer, PartsPerTray, IsSerialized, ClosureMethod, CreatedAt)
    VALUES (@Item, 1, 15, 0, N'ByCount', @Now);
DECLARE @Config BIGINT = (SELECT TOP 1 Id FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL);
DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
DECLARE @O TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO @O EXEC Lots.Container_Open
    @ItemId = @Item, @ContainerConfigId = @Config, @CellLocationId = @Cell, @AppUserId = 1;
DECLARE @ContainerId BIGINT = (SELECT NewId FROM @O);

-- Orphan: exactly what the FAT purge left behind (older, so it would sort first).
INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId,
     CustomerPartNumber, Quantity, LotNumber, PostAttempts)
VALUES
    (N'999000001', DATEADD(DAY, -20, @Now), DATEADD(DAY, -20, @Now), NULL, 1,
     N'1223A6MA J000', 4, N'MESL0000001', 1);
DECLARE @OrphanId BIGINT = SCOPE_IDENTITY();

-- Owed and bound to a live container.
INSERT INTO Lots.AimShipperIdPool
    (AimShipperId, FetchedAt, ConsumedAt, ConsumedByContainerId, ConsumedByUserId,
     CustomerPartNumber, Quantity, LotNumber)
VALUES
    (N'000900301', @Now, @Now, @ContainerId, 1, N'1223A6MA J000', 4, N'000900301');
DECLARE @BoundId BIGINT = SCOPE_IDENTITY();

DECLARE @L TABLE (Id BIGINT, AimShipperId NVARCHAR(50), ContainerId BIGINT,
                  CustomerPartNumber NVARCHAR(50), Quantity INT, LotNumber NVARCHAR(50),
                  PostAttempts INT, LastPostError NVARCHAR(500),
                  ConsumedAtEt DATETIME2(3), LastPostAttemptAtEt DATETIME2(3), AgeMinutes INT);
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 50;

DECLARE @Orphan NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @OrphanId);
EXEC test.Assert_IsEqual
    @TestName = N'[Orphan] serial whose container was deleted is NOT listed as owed',
    @Expected = N'0', @Actual = @Orphan;

DECLARE @Bound NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @L WHERE Id = @BoundId);
EXEC test.Assert_IsEqual
    @TestName = N'[Orphan] control: a container-bound owed serial is still listed',
    @Expected = N'1', @Actual = @Bound;

-- alarmTick reads ListUnposted(@Top = 1) for the OLDEST owed row. The orphan is
-- older, so without the exclusion it would drive the backlog-age alarm forever.
DELETE FROM @L;
INSERT INTO @L EXEC Lots.AimShipperIdPool_ListUnposted @Top = 1;
DECLARE @Oldest NVARCHAR(50) = (SELECT AimShipperId FROM @L);
EXEC test.Assert_IsEqual
    @TestName = N'[Orphan] oldest owed row (backlog-age alarm input) is the bound serial',
    @Expected = N'000900301', @Actual = @Oldest;

-- The row itself is untouched: still consumed, still unposted. Excluding it from
-- the sweep must not recycle or rewrite a serial Honda may have seen.
DECLARE @Kept NVARCHAR(10) = CASE WHEN EXISTS (
    SELECT 1 FROM Lots.AimShipperIdPool
    WHERE Id = @OrphanId AND ConsumedAt IS NOT NULL AND PostedAt IS NULL) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[Orphan] orphan row is left consumed and unposted (not recycled)',
    @Expected = N'1', @Actual = @Kept;
GO

DELETE FROM Lots.AimShipperIdPool;
DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber = N'AIM-ORPHAN-FK');
GO

EXEC test.EndTestFile;
