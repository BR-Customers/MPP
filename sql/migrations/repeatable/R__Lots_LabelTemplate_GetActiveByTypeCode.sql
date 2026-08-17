-- ============================================================
-- Repeatable:  R__Lots_LabelTemplate_GetActiveByTypeCode.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-07-28
-- Version:     1.0
-- Description: Returns the ACTIVE Lots.LabelTemplate.ZplBody for a LabelTypeCode
--              Code, so a Python renderer can fetch a configurable template instead
--              of carrying a hard-coded constant (design 2026-07-28 sec 3.8).
--              Read proc; empty rowset = no active template for that code.
-- ============================================================
CREATE OR ALTER PROCEDURE Lots.LabelTemplate_GetActiveByTypeCode
    @LabelTypeCode NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabelTypeCode IS NULL
        RETURN;

    SELECT TOP 1 t.Id AS Id, t.ZplBody AS ZplBody
    FROM Lots.LabelTemplate t
    INNER JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
    WHERE c.Code = @LabelTypeCode
      AND t.DeprecatedAt IS NULL
    ORDER BY t.Id DESC;
END;
GO
