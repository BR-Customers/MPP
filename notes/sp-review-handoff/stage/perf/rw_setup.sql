-- Perf DB: 30,000 containers (mostly Complete/Shipped), 5 Open, 20 ReworkFilling (12 under the test line, 8 elsewhere).
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS (SELECT 1 FROM Lots.Container)
BEGIN
    DECLARE @Cell BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'MA1-COMPBR-AOUT');
    DECLARE @Line BIGINT = (SELECT ParentLocationId FROM Location.Location WHERE Id = @Cell);
    DECLARE @Under TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Id BIGINT NOT NULL);
    ;WITH D AS (SELECT @Line AS Id UNION ALL SELECT c.Id FROM Location.Location c JOIN D ON c.ParentLocationId = D.Id)
        INSERT @Under (Id) SELECT Id FROM D OPTION (MAXRECURSION 8);
    DECLARE @Elsewhere TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Id BIGINT NOT NULL);
    INSERT @Elsewhere (Id) SELECT TOP (40) Id FROM Location.Location WHERE Id NOT IN (SELECT Id FROM @Under) ORDER BY Id;
    DECLARE @Cfg TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, CfgId BIGINT, ItemId BIGINT);
    INSERT @Cfg (CfgId, ItemId) SELECT Id, ItemId FROM Parts.ContainerConfig ORDER BY Id;
    DECLARE @NC INT = (SELECT COUNT(*) FROM @Cfg), @NU INT = (SELECT COUNT(*) FROM @Under), @NE INT = (SELECT COUNT(*) FROM @Elsewhere);
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    ;WITH N AS (SELECT TOP (30025) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, OpenedAt, CompletedAt, CreatedByUserId)
    SELECT cf.ItemId, cf.CfgId,
           CASE WHEN n > 30005 AND n <= 30017 THEN (SELECT Id FROM @Under WHERE Seq = 1 + (n % @NU))        -- 12 rework under the line
                WHEN n > 30017 THEN (SELECT Id FROM @Elsewhere WHERE Seq = 1 + (n % @NE))                    -- 8 rework elsewhere
                ELSE (SELECT Id FROM @Under WHERE Seq = 1 + (n % @NU)) END,
           CASE WHEN n > 30005 THEN 7 WHEN n > 30000 THEN 1 WHEN n % 3 = 0 THEN 3 ELSE 2 END,
           DATEADD(MINUTE, -n * 15, @Now),
           CASE WHEN n <= 30000 THEN DATEADD(MINUTE, -n * 15 + 5, @Now) END,
           1
    FROM N CROSS APPLY (SELECT CfgId, ItemId FROM @Cfg WHERE Seq = 1 + (n % @NC)) cf;
    UPDATE STATISTICS Lots.Container WITH FULLSCAN;
END
SELECT COUNT(*) AS Containers, SUM(CASE WHEN ContainerStatusCodeId = 7 THEN 1 ELSE 0 END) AS ReworkFilling,
       SUM(CASE WHEN ContainerStatusCodeId = 1 THEN 1 ELSE 0 END) AS Open_,
       (SELECT used_page_count FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('Lots.Container') AND index_id IN (0,1)) AS TablePages
FROM Lots.Container;
