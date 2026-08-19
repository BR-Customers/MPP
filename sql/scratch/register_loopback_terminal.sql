-- ============================================================
-- Scratch:  register_loopback_terminal.sql
-- Author:   Blue Ridge Automation
-- Date:     2026-08-18
-- Purpose:  FAT day-1 item 3. Point ONE terminal's IpAddress attribute at the
--           loopback address so a Perspective session opened ON THE GATEWAY HOST
--           itself resolves to a real terminal instead of falling through to
--           FALLBACK-TERMINAL.
--
--           This is the gap behind the FAT observation "even localhost wouldn't
--           resolve". Nothing was broken: Location.Terminal_GetByIpAddress (v1.2)
--           and Location.ufn_NormalizeIpAddress correctly canonicalize every
--           loopback form Perspective reports ('[0:0:0:0:0:0:0:1]', '::1',
--           '0:0:0:0:0:0:0:1', '::ffff:127.0.0.1') to '127.0.0.1' -- but NO
--           terminal in the plant seed carries 127.0.0.1, so there is nothing to
--           match and the fallback row is the correct answer.
--
--           SCRATCH, NOT A SEED. Demo/dev convenience only. A real terminal's
--           IpAddress must be its real address; never ship 127.0.0.1 to a plant
--           terminal, because then EVERY session opened on the gateway host would
--           claim to be that terminal.
--
-- Usage:    Set @TerminalCode below, run, then reload the Perspective session.
--           Run the UNDO block at the bottom to put it back.
-- ============================================================

SET NOCOUNT ON;

DECLARE @TerminalCode NVARCHAR(50) = N'DC1-T1';   -- <<< the terminal to demo as
DECLARE @Loopback     NVARCHAR(45) = N'127.0.0.1';

DECLARE @TerminalId BIGINT = (
    SELECT Id FROM Location.Location
    WHERE Code = @TerminalCode AND LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL);

DECLARE @IpDefId BIGINT = (
    SELECT TOP 1 Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'IpAddress' AND DeprecatedAt IS NULL
    ORDER BY Id);

IF @TerminalId IS NULL
BEGIN
    RAISERROR(N'No active Terminal with Code "%s".', 16, 1, @TerminalCode);
    RETURN;
END
IF @IpDefId IS NULL
BEGIN
    RAISERROR(N'Terminal IpAddress attribute definition (LTD 7) not found.', 16, 1);
    RETURN;
END

-- Refuse to create a SECOND loopback terminal: Terminal_GetByIpAddress tie-breaks
-- duplicates by lowest LocationId, so a stray second one would silently win.
IF EXISTS (
    SELECT 1
    FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId AND l.DeprecatedAt IS NULL
    WHERE la.LocationAttributeDefinitionId = @IpDefId
      AND la.LocationId <> @TerminalId
      AND Location.ufn_NormalizeIpAddress(la.AttributeValue) = @Loopback)
BEGIN
    SELECT N'Another active terminal already holds the loopback address -- clear it first:' AS Warning,
           l.Code, l.Name, la.AttributeValue
    FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId AND l.DeprecatedAt IS NULL
    WHERE la.LocationAttributeDefinitionId = @IpDefId
      AND Location.ufn_NormalizeIpAddress(la.AttributeValue) = @Loopback;
    RETURN;
END

-- Upsert the attribute value.
IF EXISTS (SELECT 1 FROM Location.LocationAttribute
           WHERE LocationId = @TerminalId AND LocationAttributeDefinitionId = @IpDefId)
    UPDATE Location.LocationAttribute
    SET    AttributeValue = @Loopback
    WHERE  LocationId = @TerminalId AND LocationAttributeDefinitionId = @IpDefId;
ELSE
    INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue, CreatedAt)
    VALUES (@TerminalId, @IpDefId, @Loopback, SYSUTCDATETIME());

-- Prove it resolves, through the same proc the session uses, in the bracketed
-- IPv6 form Perspective actually reports for loopback.
EXEC Location.Terminal_GetByIpAddress @IpAddress = N'[0:0:0:0:0:0:0:1]';
GO

-- ============================================================
-- UNDO -- clear the loopback binding (leaves the terminal itself alone).
-- ============================================================
-- DELETE la
-- FROM Location.LocationAttribute la
-- INNER JOIN Location.LocationAttributeDefinition ad
--         ON ad.Id = la.LocationAttributeDefinitionId
--        AND ad.LocationTypeDefinitionId = 7
--        AND ad.AttributeName = N'IpAddress'
-- WHERE Location.ufn_NormalizeIpAddress(la.AttributeValue) = N'127.0.0.1';
