-- =============================================
-- Procedure: Location.Terminal_GetClosureContext
-- Author:    Blue Ridge Automation
-- Created:   2026-07-17
-- Version:   1.1
--
-- Change Log:
--   2026-07-17 - 1.0 - Initial version.
--   2026-08-18 - 1.1 - FAT day-1 item 8: the vision station is configured by IP, not
--                       by URL. Reads the renamed 'VisionAppIp' attribute (0063) and
--                       COMPOSES the embed URL via Location.ufn_VisionAppUrl. The
--                       result column keeps the name VisionAppUrl -- it is a URL by
--                       the time it leaves here -- so applyToSession, the session
--                       property and both assembly views are untouched.
--
-- Description:
--   Resolves a terminal's closure context in one row:
--     * CurrentClosureMethod - persisted LocationAttribute (the active mode),
--                              defaulting to ByCount when unset (a terminal that
--                              has never had a supervisor changeover). ByCount is
--                              the universal, device-free baseline (it is always
--                              in ClosureCapabilities), so the count-close UI is
--                              usable without first forcing a changeover;
--     * VisionAppUrl         - COMPOSED from the persisted 'VisionAppIp'
--                              LocationAttribute via Location.ufn_VisionAppUrl
--                              (http://<ip>/, optional :port and /path carried
--                              through, a full URL passed through unchanged, blank
--                              -> NULL). The ByVision assembly embed binds this;
--     * ClosureCapabilities  - DERIVED CSV of methods the terminal can run,
--                              from its active PLC devices'
--                              PlcDeviceType.ClosureMethodCode, ordered by
--                              ClosureMethodCode.SortOrder, always including
--                              ByCount (needs no device).
--   No OUTPUT params (Ignition JDBC). Exactly one result row.
--
-- Parameters:
--   @TerminalLocationId BIGINT - the Terminal Location.Id.
--
-- Dependencies:
--   Tables: Location.LocationAttribute, Location.LocationAttributeDefinition,
--           Location.TerminalPlcDevice, Location.PlcDeviceType,
--           Parts.ClosureMethodCode
--   Functions: Location.ufn_VisionAppUrl
-- =============================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetClosureContext
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Current NVARCHAR(20) = (
        SELECT la.AttributeValue FROM Location.LocationAttribute la
        INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
            AND lad.LocationTypeDefinitionId = 7 AND lad.AttributeName = N'CurrentClosureMethod' AND lad.DeprecatedAt IS NULL
        WHERE la.LocationId = @TerminalLocationId);

    -- Stored as a bare IP (optionally :port and/or /path); composed to a loadable URL.
    DECLARE @VisionIp NVARCHAR(400) = (
        SELECT la.AttributeValue FROM Location.LocationAttribute la
        INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
            AND lad.LocationTypeDefinitionId = 7 AND lad.AttributeName = N'VisionAppIp' AND lad.DeprecatedAt IS NULL
        WHERE la.LocationId = @TerminalLocationId);

    DECLARE @Vision NVARCHAR(400) = Location.ufn_VisionAppUrl(@VisionIp);

    -- Derived capability set: ByCount always, plus each capable device type's method.
    DECLARE @Caps NVARCHAR(100) = N'ByCount';
    SELECT @Caps = @Caps + N',' + cmc.Code
    FROM (
        SELECT DISTINCT pdt.ClosureMethodCode AS Code
        FROM Location.TerminalPlcDevice tpd
        INNER JOIN Location.PlcDeviceType pdt ON pdt.Id = tpd.PlcDeviceTypeId
        WHERE tpd.TerminalLocationId = @TerminalLocationId
          AND tpd.DeprecatedAt IS NULL
          AND pdt.ClosureMethodCode IS NOT NULL
    ) m
    INNER JOIN Parts.ClosureMethodCode cmc ON cmc.Code = m.Code AND cmc.DeprecatedAt IS NULL
    ORDER BY cmc.SortOrder;

    SELECT COALESCE(@Current, N'ByCount') AS CurrentClosureMethod, @Vision AS VisionAppUrl, @Caps AS ClosureCapabilities;
END;
GO
