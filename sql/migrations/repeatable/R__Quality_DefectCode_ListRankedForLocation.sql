-- =============================================
-- Procedure:   Quality.DefectCode_ListRankedForLocation
-- Author:      Blue Ridge Automation
-- Created:     2026-10-12
-- Version:     1.0
--
-- Description:
--   The scrap reasons a plant-floor terminal offers, ordered by how much they
--   are actually used AT THAT LINE. Feeds the tile grid on the Scrap Entry
--   popup (Machining + Assembly terminals): the first tiles are the reasons
--   this line reaches for most, the rest sit behind "More reasons".
--
--   Scope is IDENTICAL to Quality.DefectCode_List with @OperationTypeCode: the
--   operation's category plus the plant-wide (NULL category) codes, active
--   only. The two procs must change together.
--
--   UseCount = pieces scrapped under the code in the last @WindowDays, counted
--   from Workorder.RejectEvent rows whose TerminalLocationId is @LocationId
--   itself or a terminal directly beneath it (a line's terminals are its
--   children). Rows with no terminal stamped are not counted, so a line with
--   no history yet simply falls back to the tie-break order.
--
--   Order: UseCount descending, then the operation's own codes ahead of the
--   plant-wide ones, then Code. RankOrder carries that order as a column so a
--   caller never depends on result-set ordering.
--
--   Read proc: no status row; an empty result means no codes are in scope.
--
-- Change Log:
--   2026-10-12 - 1.0 - Initial version
-- =============================================
CREATE OR ALTER PROCEDURE Quality.DefectCode_ListRankedForLocation
    @LocationId        BIGINT,
    @OperationTypeCode NVARCHAR(20) = NULL,
    @WindowDays        INT          = 90
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FilterRequested BIT = CASE WHEN @OperationTypeCode IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @EffCatId BIGINT = (SELECT ot.OperationCategoryId
                                FROM Parts.OperationType ot
                                WHERE ot.Code = @OperationTypeCode);
    DECLARE @Days  INT          = CASE WHEN @WindowDays IS NULL OR @WindowDays <= 0 THEN 90 ELSE @WindowDays END;
    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());

    ;WITH Here AS (
        SELECT l.Id
        FROM Location.Location l
        WHERE l.Id = @LocationId OR l.ParentLocationId = @LocationId
    ),
    Used AS (
        SELECT re.DefectCodeId, SUM(re.Quantity) AS UseCount
        FROM Workorder.RejectEvent re
        INNER JOIN Here h ON h.Id = re.TerminalLocationId
        WHERE re.RecordedAt >= @Since
        GROUP BY re.DefectCodeId
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY ISNULL(u.UseCount, 0) DESC,
                                    CASE WHEN dc.OperationCategoryId IS NULL THEN 1 ELSE 0 END,
                                    dc.Code)  AS RankOrder,
        dc.Id,
        dc.Code,
        dc.Description,
        dc.OperationCategoryId,
        dc.IsExcused,
        ISNULL(u.UseCount, 0)                 AS UseCount
    FROM Quality.DefectCode dc
    LEFT JOIN Used u ON u.DefectCodeId = dc.Id
    WHERE dc.DeprecatedAt IS NULL
      AND (@FilterRequested = 0
           OR dc.OperationCategoryId = @EffCatId       -- matches requested category
           OR dc.OperationCategoryId IS NULL)          -- plant-wide always included
    ORDER BY RankOrder;
END
GO
