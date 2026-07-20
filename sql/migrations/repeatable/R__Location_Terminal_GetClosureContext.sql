-- =============================================
-- Procedure: Location.Terminal_GetClosureContext
-- Author:    Blue Ridge Automation
-- Created:   2026-07-17
-- Version:   1.0
--
-- Description:
--   Resolves a terminal's closure context in one row:
--     * CurrentClosureMethod - persisted LocationAttribute (the active mode);
--     * VisionAppUrl         - persisted LocationAttribute (ByVision embed);
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

    DECLARE @Vision NVARCHAR(400) = (
        SELECT la.AttributeValue FROM Location.LocationAttribute la
        INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
            AND lad.LocationTypeDefinitionId = 7 AND lad.AttributeName = N'VisionAppUrl' AND lad.DeprecatedAt IS NULL
        WHERE la.LocationId = @TerminalLocationId);

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

    SELECT @Current AS CurrentClosureMethod, @Vision AS VisionAppUrl, @Caps AS ClosureCapabilities;
END;
GO
