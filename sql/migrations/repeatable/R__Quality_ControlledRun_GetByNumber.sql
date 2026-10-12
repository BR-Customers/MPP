-- ============================================================
-- Repeatable:  R__Quality_ControlledRun_GetByNumber.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-12
-- Version:     1.0
-- Description: READ. A super-lot by its number -- what a scanned super-lot
--              label resolves through. Same single result set as
--              Quality.ControlledRun_Get (it resolves the id and delegates, so
--              the two cannot drift). Empty set = no such super-lot.
--
--              No status row, no OUTPUT params (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.ControlledRun_GetByNumber
    @RunNumber NVARCHAR(15)
AS
BEGIN
    SET NOCOUNT ON;

    -- An unknown number leaves @Id NULL, and ControlledRun_Get returns its
    -- (correctly shaped) empty set.
    DECLARE @Id BIGINT = (SELECT Id FROM Quality.ControlledRun WHERE RunNumber = LTRIM(RTRIM(@RunNumber)));

    EXEC Quality.ControlledRun_Get @Id = @Id;
END;
GO
