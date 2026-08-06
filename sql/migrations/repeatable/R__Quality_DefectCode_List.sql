-- =============================================
-- Procedure:   Quality.DefectCode_List
-- Author:      Blue Ridge Automation
-- Created:     2026-04-14
-- Version:     2.0
--
-- Description:
--   Returns defect codes, optionally filtered by active status and/or
--   scope. Scope is either an explicit OperationCategoryId (config tool)
--   or an OperationTypeCode (plant floor, resolved to category in SQL).
--   A requested category ALSO returns plant-wide (NULL) codes.
--
-- Change Log:
--   2026-04-14 - 1.0 - Initial version
--   2026-05-19 - 1.1 - ORDER BY changed from (Code) to (AreaName, Code)
--   2026-08-04 - 2.0 - Scope by OperationCategory. @OperationCategoryId (config
--                       tool) OR @OperationTypeCode (plant floor, resolved to
--                       category in SQL). A requested category always ALSO
--                       returns plant-wide (NULL) codes. No filter -> all.
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_List
    @IncludeDeprecated   BIT           = 0,
    @OperationCategoryId BIGINT        = NULL,
    @OperationTypeCode   NVARCHAR(20)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- A filter is "requested" if either input was supplied. Resolve the effective
    -- category: explicit id wins; else derive from the operation-type code.
    DECLARE @FilterRequested BIT =
        CASE WHEN @OperationCategoryId IS NOT NULL OR @OperationTypeCode IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @EffCatId BIGINT = @OperationCategoryId;
    IF @EffCatId IS NULL AND @OperationTypeCode IS NOT NULL
        SELECT @EffCatId = ot.OperationCategoryId
        FROM Parts.OperationType ot
        WHERE ot.Code = @OperationTypeCode;

    SELECT
        dc.Id,
        dc.Code,
        dc.Description,
        dc.OperationCategoryId,
        oc.Name                AS CategoryName,
        dc.IsExcused,
        dc.CreatedAt,
        dc.DeprecatedAt
    FROM Quality.DefectCode dc
    LEFT JOIN Parts.OperationCategory oc ON dc.OperationCategoryId = oc.Id
    WHERE (@IncludeDeprecated = 1 OR dc.DeprecatedAt IS NULL)
      AND (@FilterRequested = 0
           OR dc.OperationCategoryId = @EffCatId       -- matches requested category
           OR dc.OperationCategoryId IS NULL)          -- plant-wide always included
    ORDER BY CASE WHEN dc.OperationCategoryId IS NULL THEN 1 ELSE 0 END, oc.Name, dc.Code;
END
GO
