-- =============================================
-- Procedure:   Lots.ContainerSerial_Get
-- Author:      Blue Ridge Automation
-- Created:     2026-08-20
-- Version:     1.0
--
-- Description:
--   Returns a single ContainerSerial row by Id -- resolves which Container a
--   serialized part is currently placed in. Read-only proc; empty result
--   means not found. Sort Cage workflow uses this to resolve the source
--   Container for a scanned/entered Container Serial Id (FDS-11-011: no
--   OUTPUT params).
--
-- Parameters:
--   @Id BIGINT - PK of the ContainerSerial to retrieve. Required.
--
-- Result set:
--   Zero or one row: Id, ContainerId, ContainerTrayId, TrayPosition, SerializedPartId.
--
-- Dependencies:
--   Tables: Lots.ContainerSerial
-- =============================================
CREATE OR ALTER PROCEDURE Lots.ContainerSerial_Get
    @Id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, ContainerId, ContainerTrayId, TrayPosition, SerializedPartId
    FROM Lots.ContainerSerial
    WHERE Id = @Id;
END;
GO
