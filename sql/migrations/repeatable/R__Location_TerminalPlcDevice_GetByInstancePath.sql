-- =============================================
-- Procedure:   Location.TerminalPlcDevice_GetByInstancePath
-- Description: Active PLC-device mapping(s) for a UDT instance path -- the
--   reverse of _GetByTerminal. A gateway watcher fires on a trigger member,
--   derives the instance path, and resolves which terminal + device type drives
--   it (so it can pass @TerminalLocationId to the handshake procs and pick the
--   right watcher). Read proc - no status row; empty result = unmapped instance.
-- =============================================
CREATE OR ALTER PROCEDURE Location.TerminalPlcDevice_GetByInstancePath
    @UdtInstancePath NVARCHAR(400)
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
    WHERE d.UdtInstancePath = @UdtInstancePath
      AND d.DeprecatedAt IS NULL
    ORDER BY d.SortOrder ASC, d.Id ASC;
END;
GO
