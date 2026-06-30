-- =============================================
-- Procedure:   Parts.DataCollectionField_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-13
-- Version:     3.0
--
-- Description:
--   Returns DataCollectionField rows ordered by Code, joined to the
--   Parts.DataCollectionFieldDataType code table so each row carries its
--   DataTypeId/Code/Name (the die-cast FieldInputRow widget driver). Mutable code
--   table; supports optional inclusion of deprecated rows.
--
-- Parameters:
--   @IncludeDeprecated BIT = 0 - When 1, includes deprecated rows.
--
-- Result set:
--   Id, Code, Name, Description, DataTypeId, DataTypeCode, DataTypeName,
--   CreatedAt, DeprecatedAt.
--
-- Dependencies:
--   Tables: Parts.DataCollectionField, Parts.DataCollectionFieldDataType (0023)
--
-- Change Log:
--   2026-04-13 - 1.0 - Initial version (OUTPUT params)
--   2026-04-14 - 2.0 - Removed OUTPUT params for Named Query compatibility
--   2026-06-16 - 3.0 - Join Parts.DataCollectionFieldDataType; return DataType
--                      Id/Code/Name (Phase 3 delta, Change 1). INNER JOIN is safe:
--                      DataTypeId is NOT NULL + FK after 0023, so every row resolves.
-- =============================================
CREATE OR ALTER PROCEDURE Parts.DataCollectionField_List
    @IncludeDeprecated BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        dcf.Id, dcf.Code, dcf.Name, dcf.Description,
        dcf.DataTypeId,
        dt.Code AS DataTypeCode,
        dt.Name AS DataTypeName,
        dcf.CreatedAt, dcf.DeprecatedAt
    FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId
    WHERE (@IncludeDeprecated = 1 OR dcf.DeprecatedAt IS NULL)
    ORDER BY dcf.Code;
END;
GO
