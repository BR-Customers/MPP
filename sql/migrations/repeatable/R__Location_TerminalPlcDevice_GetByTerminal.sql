-- =============================================
-- Procedure:   Location.TerminalPlcDevice_GetByTerminal
-- Description: All active PLC-device mappings for a terminal, joined to type.
--   Read proc - no status row; empty result = none. Feeds onStartup /
--   session.custom.plcDevices.
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_GetByTerminal
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        d.Id,
        d.TerminalLocationId,
        d.PlcDeviceTypeId,
        t.Code                  AS DeviceTypeCode,
        t.Name                  AS DeviceTypeName,
        d.DeviceCode,
        d.UdtInstancePath,
        d.SortOrder
    FROM Location.TerminalPlcDevice d
    INNER JOIN Location.PlcDeviceType t ON t.Id = d.PlcDeviceTypeId
    WHERE d.TerminalLocationId = @TerminalLocationId
      AND d.DeprecatedAt IS NULL
    ORDER BY d.SortOrder ASC, d.Id ASC;
END;
GO
