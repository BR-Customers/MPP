-- ============================================================
-- Repeatable:  R__Quality_SignatureMeaning_Get.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-10-13
-- Version:     1.0
-- Description: READ. One signature meaning by code: its name and the exact
--              statement shown to the signer. The signing procs copy this same
--              Statement onto Quality.Signature, so what the screen shows and
--              what is stored are one piece of text, not two.
--
--              No status row, no OUTPUT params (FDS-11-011). Empty set = unknown
--              code.
-- ============================================================
CREATE OR ALTER PROCEDURE Quality.SignatureMeaning_Get
    @Code NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sm.Id, sm.Code, sm.Name, sm.Statement
    FROM Quality.SignatureMeaning sm
    WHERE sm.Code = @Code;
END;
GO
