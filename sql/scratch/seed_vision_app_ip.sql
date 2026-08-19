-- ============================================================
-- Scratch:  seed_vision_app_ip.sql
-- Author:   Blue Ridge Automation
-- Date:     2026-08-18
-- Purpose:  FAT day-1 item 8. Load the seven vision-station IP addresses MPP
--           supplied onto their Terminal Locations as the 'VisionAppIp'
--           LocationAttribute (renamed from VisionAppUrl by migration 0059).
--           Location.Terminal_GetClosureContext composes 'http://<ip>/' from these
--           via Location.ufn_VisionAppUrl.
--
--           SCRATCH PENDING CONFIRMATION. MPP supplied LINE / STATION names, not
--           terminal codes. The mapping below was derived from the plant model and
--           is NOT yet confirmed by MPP -- promote this into sql/seeds/ only once
--           Jacques or MPP has signed off on the terminal column.
--
--           How the mapping was derived: every candidate line carries several
--           terminals, but on each line exactly ONE terminal is configured
--           CurrentClosureMethod = 'ByVision' -- which is by definition the station
--           with the camera. That disambiguates all six production lines. The Sort
--           Cage matches by name (INSP-SORT 'Sort Cage Inspection').
--
--             MPP station name          IP              -> Terminal          basis
--             ------------------------  --------------- -- ----------------  ---------------------------
--             Sort Cage                 172.17.20.37       INSP-SORT-T1      name: 'Sort Cage Inspection'
--             RPY Line 1                172.17.20.4        MA2-RPYCAM1-AOUT1 only ByVision on RPY Line 1
--             RPY Line 2                172.17.20.32       MA2-RPYCAM2-AOUT1 only ByVision on RPY Line 2
--             6NA, 6VJ Fuel Pump        172.17.21.238      MA1-FP6NA-AOUT    line 'Fuel Pump (6na 6vj)'
--             RPY, 6B2, 66V Fuel Pump   172.17.21.244      MA1-FPRPY-AOUT    line 'Fuel Pump (RPY 66v)'  <-- see note
--             6MA CH                    172.17.21.237      MA2-6MACH-AOUT3   only ByVision on 6MA Cam Holder
--             59B CH                    172.17.21.241      MA2-59B-AOUT2     only ByVision on 59b Cam holder
--
--           NOTE on 'RPY, 6B2, 66V Fuel Pump': the plant model names that line
--           'Fuel Pump (RPY 66v)' -- the 6B2 part of MPP's label is unaccounted for.
--           The only other 6B2 location, MA2-RPY6B2 ('RPY 6b2 line2'), is a cam-holder
--           line with NO ByVision terminal, so MA1-FPRPY-AOUT remains the only fuel-pump
--           line matching RPY + 66V. Confirm before promoting.
--
--           ALSO WORTH CONFIRMING -- five terminals are configured ByVision but were
--           given NO IP in MPP's list, so their vision embed stays blank:
--             MA2-5PA-AOUT, MA2-64AOP-AOUT, MA2-6FBCHOP-AOUT,
--             MA2-6MAOP-AOUT, MA2-V6OP-AOUT
--           Either MPP owes those IPs, or those stations do not actually run ByVision.
--
-- Usage:    Run against the target database, then re-open any affected terminal's
--           session. Idempotent (upserts by terminal + attribute definition).
-- ============================================================

SET NOCOUNT ON;

DECLARE @IpDefId BIGINT = (
    SELECT TOP 1 Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'VisionAppIp' AND DeprecatedAt IS NULL
    ORDER BY Id);

IF @IpDefId IS NULL
BEGIN
    RAISERROR(N'Terminal VisionAppIp attribute definition not found -- apply migration 0059 first.', 16, 1);
    RETURN;
END

DECLARE @Map TABLE (TerminalCode NVARCHAR(50) PRIMARY KEY, Ip NVARCHAR(64), StationName NVARCHAR(100));
INSERT INTO @Map (TerminalCode, Ip, StationName) VALUES
    (N'INSP-SORT-T1',      N'172.17.20.37',  N'Sort Cage'),
    (N'MA2-RPYCAM1-AOUT1', N'172.17.20.4',   N'RPY Line 1'),
    (N'MA2-RPYCAM2-AOUT1', N'172.17.20.32',  N'RPY Line 2'),
    (N'MA1-FP6NA-AOUT',    N'172.17.21.238', N'6NA, 6VJ Fuel Pump'),
    (N'MA1-FPRPY-AOUT',    N'172.17.21.244', N'RPY, 6B2, 66V Fuel Pump'),
    (N'MA2-6MACH-AOUT3',   N'172.17.21.237', N'6MA CH'),
    (N'MA2-59B-AOUT2',     N'172.17.21.241', N'59B CH');

-- Fail loudly if any mapped code is missing / deprecated, rather than silently
-- loading six of seven.
IF EXISTS (SELECT 1 FROM @Map m
           WHERE NOT EXISTS (SELECT 1 FROM Location.Location l
                             WHERE l.Code = m.TerminalCode
                               AND l.LocationTypeDefinitionId = 7
                               AND l.DeprecatedAt IS NULL))
BEGIN
    SELECT N'Unresolved terminal code -- nothing loaded' AS Error, m.TerminalCode, m.StationName, m.Ip
    FROM @Map m
    WHERE NOT EXISTS (SELECT 1 FROM Location.Location l
                      WHERE l.Code = m.TerminalCode
                        AND l.LocationTypeDefinitionId = 7
                        AND l.DeprecatedAt IS NULL);
    RETURN;
END

-- Upsert: update where a value already exists, insert where it does not.
UPDATE la
SET    la.AttributeValue = m.Ip
FROM   Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
INNER JOIN @Map m ON m.TerminalCode = l.Code
WHERE  la.LocationAttributeDefinitionId = @IpDefId;

INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
SELECT l.Id, @IpDefId, m.Ip, SYSUTCDATETIME()
FROM   @Map m
INNER JOIN Location.Location l
        ON l.Code = m.TerminalCode AND l.LocationTypeDefinitionId = 7 AND l.DeprecatedAt IS NULL
WHERE  NOT EXISTS (SELECT 1 FROM Location.LocationAttribute la
                   WHERE la.LocationId = l.Id AND la.LocationAttributeDefinitionId = @IpDefId);

-- Show what the terminals will actually serve to the ByVision embed.
SELECT m.StationName,
       l.Code                                          AS Terminal,
       la.AttributeValue                               AS StoredIp,
       Location.ufn_VisionAppUrl(la.AttributeValue)    AS ComposedUrl
FROM   @Map m
INNER JOIN Location.Location l ON l.Code = m.TerminalCode
INNER JOIN Location.LocationAttribute la
        ON la.LocationId = l.Id AND la.LocationAttributeDefinitionId = @IpDefId
ORDER BY m.StationName;
GO
