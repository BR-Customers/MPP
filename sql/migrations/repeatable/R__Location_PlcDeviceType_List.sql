-- =============================================
-- Procedure:   Location.PlcDeviceType_List
-- Description: The fixed-seed PLC UDT device types (Scale/SerializedMip/
--   NonSerializedMip/TrayInspection) for the mapping-editor dropdown. Read proc.
-- =============================================
CREATE OR ALTER PROCEDURE Location.PlcDeviceType_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Code, Name
    FROM Location.PlcDeviceType
    ORDER BY Id ASC;
END;
GO
