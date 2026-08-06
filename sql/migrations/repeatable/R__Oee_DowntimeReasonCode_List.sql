-- =============================================
-- Procedure:   Oee.DowntimeReasonCode_List
-- Version:     2.1
-- Change Log:
--   2026-08-05 - 2.0 - Scope by OperationCategory. @OperationCategoryId (config
--                       tool) OR @OperationTypeCode (plant floor, resolved to
--                       category in SQL). A requested category always ALSO returns
--                       plant-wide (NULL) codes. Keeps @DowntimeReasonTypeId filter.
--   2026-08-05 - 2.1 - Add @OperationCategoryCode path: the plant-floor downtime
--                       dropdown scopes off the terminal's operation category
--                       (session.custom.terminal.operationCategoryCode), a
--                       DieCast/Trim/MachiningAssembly code resolved to its Id here.
-- =============================================
CREATE OR ALTER PROCEDURE Oee.DowntimeReasonCode_List
    @OperationCategoryId   BIGINT       = NULL,
    @OperationTypeCode     NVARCHAR(20) = NULL,
    @OperationCategoryCode NVARCHAR(50) = NULL,
    @DowntimeReasonTypeId  BIGINT       = NULL,
    @IncludeDeprecated     BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FilterRequested BIT =
        CASE WHEN @OperationCategoryId IS NOT NULL
                  OR @OperationTypeCode IS NOT NULL
                  OR @OperationCategoryCode IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @EffCatId BIGINT = @OperationCategoryId;
    IF @EffCatId IS NULL AND @OperationTypeCode IS NOT NULL
        SELECT @EffCatId = ot.OperationCategoryId
        FROM Parts.OperationType ot
        WHERE ot.Code = @OperationTypeCode;
    IF @EffCatId IS NULL AND @OperationCategoryCode IS NOT NULL
        SELECT @EffCatId = oc.Id
        FROM Parts.OperationCategory oc
        WHERE oc.Code = @OperationCategoryCode;

    SELECT
        drc.Id,
        drc.Code,
        drc.Description,
        drc.OperationCategoryId,
        oc.Name             AS CategoryName,
        drc.DowntimeReasonTypeId,
        drt.Name            AS ReasonTypeName,
        drc.DowntimeSourceCodeId,
        dsc.Name            AS SourceCodeName,
        drc.IsExcused,
        drc.CreatedAt,
        drc.DeprecatedAt
    FROM Oee.DowntimeReasonCode drc
    LEFT JOIN Parts.OperationCategory oc  ON drc.OperationCategoryId  = oc.Id
    LEFT JOIN Oee.DowntimeReasonType  drt ON drc.DowntimeReasonTypeId = drt.Id
    LEFT JOIN Oee.DowntimeSourceCode  dsc ON drc.DowntimeSourceCodeId = dsc.Id
    WHERE (@IncludeDeprecated = 1 OR drc.DeprecatedAt IS NULL)
      AND (@DowntimeReasonTypeId IS NULL OR drc.DowntimeReasonTypeId = @DowntimeReasonTypeId)
      AND (@FilterRequested = 0
           OR drc.OperationCategoryId = @EffCatId        -- matches requested category
           OR drc.OperationCategoryId IS NULL)           -- plant-wide always included
    ORDER BY CASE WHEN drc.OperationCategoryId IS NULL THEN 1 ELSE 0 END, oc.Name, drc.Code;
END
GO
