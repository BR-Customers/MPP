-- =============================================
-- Procedure:   Lots.SerializedPart_GetBySerial
-- Description: Look up a serialized part by its serial number (validate/dedup a
--   PLC-reported serial). Read proc - empty result = not found.
-- =============================================
CREATE OR ALTER PROCEDURE Lots.SerializedPart_GetBySerial
    @SerialNumber NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, SerialNumber, ItemId, ProducingLotId, EtchedAt
    FROM Lots.SerializedPart
    WHERE SerialNumber = @SerialNumber;
END;
GO
