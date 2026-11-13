-- Perf DB: load Lots.ShippingLabel (60,000 rows, 3 failed+unacknowledged) once, then measure the banner read.
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS (SELECT 1 FROM Lots.ShippingLabel)
BEGIN
    -- throwaway DB: containers are not needed for this read, so do not check the container FK on the synthetic rows
    ALTER TABLE Lots.ShippingLabel NOCHECK CONSTRAINT FK_ShippingLabel_Container;
    DECLARE @Lt BIGINT = (SELECT TOP 1 Id FROM Lots.LabelTypeCode ORDER BY Id);
    DECLARE @Loc BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'INSP-SORT-T1');
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    ;WITH N AS (SELECT TOP (60000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT INTO Lots.ShippingLabel (ContainerId, AimShipperId, LabelTypeCodeId, TerminalLocationId, CreatedAt, PrintedAt, PrintAttempts,
                                    LastPrintError, LastPrintErrorCondition, PrintFailedAt, BannerAcknowledgedAt)
    SELECT 1 + (n % 30000), N'AIM' + CAST(n AS NVARCHAR(20)), @Lt, @Loc, DATEADD(MINUTE, -n * 10, @Now),
           CASE WHEN n % 200 = 1 THEN NULL ELSE DATEADD(MINUTE, -n * 10 + 1, @Now) END,           -- a few never printed
           1,
           CASE WHEN n % 150 = 0 THEN N'printer offline' END,
           CASE WHEN n % 150 = 0 THEN N'PrinterOffline' END,
           CASE WHEN n % 150 = 0 THEN DATEADD(MINUTE, -n * 10 + 2, @Now) END,                      -- ~400 historic failures
           CASE WHEN n % 150 = 0 AND n > 450 THEN DATEADD(MINUTE, -n * 10 + 3, @Now) END           -- acknowledged, except the newest 3
    FROM N;
    UPDATE STATISTICS Lots.ShippingLabel WITH FULLSCAN;
END
SELECT COUNT(*) AS Labels,
       SUM(CASE WHEN PrintFailedAt IS NOT NULL THEN 1 ELSE 0 END) AS EverFailed,
       SUM(CASE WHEN PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL THEN 1 ELSE 0 END) AS FailedUnacked
FROM Lots.ShippingLabel;
