-- =============================================================================
-- AIM go-live config: company 99 (PRODUCTION), pool target 5 / top-up threshold 3.
-- Run against MPP_MES_Prod.
--
-- @Apply = 0 (default): report only -- current config, what will change, and the
--             two pool hazards below. Nothing is written.
-- @Apply = 1: calls Lots.AimPoolConfig_Update (preserve-on-omit for any NULL
--             connection param) and re-reads the row. NOT written to
--             Audit.ConfigLog -- the proc only stamps UpdatedAt / UpdatedByUserId,
--             so the "Current" block below is the only record of the old values.
--
-- What turning this on does: AimHttp reads this row on EVERY call. With
-- AimPostingEnabled = 1, the moment AimPoolTopupTimer is enabled it will fetch
-- serials from company 99 until the pool holds @TargetBufferDepth (only when the
-- pool is below @TopupThreshold). Every fetched serial is consumed from AIM's
-- production counter for good. Completing a container also posts its serial
-- synchronously (Container.complete -> AimPost.postOne).
--
-- A wrong URL / token is SAFE: nextserial fails, logs to Audit.InterfaceLog
-- (SystemName 'AIM'), and nothing is consumed.
-- =============================================================================
SET NOCOUNT ON;

DECLARE @Apply              BIT           = 0;
DECLARE @ByPin              NVARCHAR(5)   = N'';            -- YOUR PIN (audit attribution), e.g. N'04218'

DECLARE @TargetBufferDepth  INT           = 5;
DECLARE @TopupThreshold     INT           = 3;
DECLARE @AlarmWarningDepth  INT           = 2;              -- defaults 20/10 would alarm permanently on a 5-deep pool
DECLARE @AlarmCriticalDepth INT           = 1;
DECLARE @AimBaseUrl         NVARCHAR(200) = N'http://172.17.10.86:8080';
DECLARE @AimCompanyCode     NVARCHAR(10)  = N'99';
DECLARE @AimPathToken       NVARCHAR(50)  = N'636652666553236784';
DECLARE @AimPostingEnabled  BIT           = 1;

DECLARE @AppUserId BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = @ByPin AND DeprecatedAt IS NULL);

PRINT '--- Current Lots.AimPoolConfig';
SELECT TargetBufferDepth, TopupThreshold, AlarmWarningDepth, AlarmCriticalDepth,
       AimBaseUrl, AimCompanyCode,
       CASE WHEN AimPathToken IS NULL THEN 'NOT SET' WHEN AimPathToken = @AimPathToken THEN 'same' ELSE 'DIFFERENT' END AS AimPathToken,
       AimPostingEnabled, UpdatedAt
FROM Lots.AimPoolConfig;

PRINT '--- Hazard 1: unconsumed pool rows. These are claimed FIRST (FetchedAt, Id) and each';
PRINT '    one also counts toward the threshold, so the timer fetches nothing while they sit here.';
SELECT Id, AimShipperId, FetchedAt AS FetchedAtUtc,
       CASE WHEN AimShipperId NOT LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN 'NOT AIM FORMAT'
            ELSE 'confirm it came from AIM company ' + @AimCompanyCode END AS Note
FROM Lots.AimShipperIdPool WHERE ConsumedAt IS NULL ORDER BY FetchedAt, Id;

PRINT '--- Hazard 2: serials consumed but never posted. AimPostTimer (retry sweep) would';
PRINT '    POST every one of these to company ' + @AimCompanyCode + ' - including rows whose container no longer exists.';
SELECT p.Id, p.AimShipperId, p.ConsumedAt AS ConsumedAtUtc, p.ConsumedByContainerId,
       p.CustomerPartNumber, p.Quantity, p.LotNumber, p.PostAttempts, p.LastPostError,
       CASE WHEN p.ConsumedByContainerId IS NULL THEN 'ORPHAN - container deleted (FAT purge?) - must NOT be posted'
            ELSE 'owed' END AS Note
FROM Lots.AimShipperIdPool p
WHERE p.ConsumedAt IS NOT NULL AND p.PostedAt IS NULL
ORDER BY p.ConsumedAt, p.Id;

IF @Apply = 0
BEGIN
    PRINT '--- REPORT ONLY (@Apply = 0). Nothing written.';
    RETURN;
END

IF @AppUserId IS NULL
BEGIN
    RAISERROR('Set @ByPin to an active AppUser PIN (audit attribution).', 16, 1);
    RETURN;
END

PRINT '--- Applying via Lots.AimPoolConfig_Update';
EXEC Lots.AimPoolConfig_Update
    @TargetBufferDepth  = @TargetBufferDepth,
    @TopupThreshold     = @TopupThreshold,
    @AlarmWarningDepth  = @AlarmWarningDepth,
    @AlarmCriticalDepth = @AlarmCriticalDepth,
    @AimBaseUrl         = @AimBaseUrl,
    @AimCompanyCode     = @AimCompanyCode,
    @AimPathToken       = @AimPathToken,
    @AimPostingEnabled  = @AimPostingEnabled,
    @AppUserId          = @AppUserId;

PRINT '--- After';
SELECT TargetBufferDepth, TopupThreshold, AlarmWarningDepth, AlarmCriticalDepth,
       AimBaseUrl, AimCompanyCode, AimPostingEnabled, UpdatedAt, UpdatedByUserId
FROM Lots.AimPoolConfig;
