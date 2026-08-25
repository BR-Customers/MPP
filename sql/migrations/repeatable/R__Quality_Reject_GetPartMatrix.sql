-- =============================================
-- Repeatable:  R__Quality_Reject_GetPartMatrix.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-006 Rejects -- Part Matrix, ROOT query. One row per part
--              that saw any reject activity in the window.
--
--              The legacy report is a cross-tab: parts as COLUMNS, eight per
--              page, fifteen pages. SQL cannot return a variable column set
--              without dynamic SQL, so the data is emitted LONG and the
--              ReportMill layout nests per-part blocks under it (confirmed with
--              Jacques 2026-08-25).
--
--              This is the parent of two child queries, each taking the parent
--              row's ItemId:
--                Quality.Reject_GetPartMatrixByParty   -- party breakdown
--                Quality.Reject_GetPartMatrixDefects   -- defect breakdown
--
--              TotalRejects EXCLUDES non-reject scrap, matching the Plant
--              Summary. The legacy prints Trial/Test Parts in their own rows
--              below the percentages for the same reason.
--
--              One result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Reject_GetPartMatrix
    @FromEt DATE = NULL,
    @ToEt   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FromUtc DATETIME2(3) = NULL, @ToUtc DATETIME2(3) = NULL;
    IF @FromEt IS NOT NULL
        SET @FromUtc = CAST(CAST(@FromEt AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @ToEt IS NOT NULL
        SET @ToUtc = CAST(CAST(DATEADD(DAY, 1, @ToEt) AS DATETIME2(3))
            AT TIME ZONE 'Eastern Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    SELECT
        i.Id                AS ItemId,
        i.PartNumber        AS ItemPartNumber,
        i.Description       AS ItemDescription,
        SUM(CASE WHEN dc.IsNonRejectScrap = 0 THEN CAST(re.Quantity AS BIGINT) ELSE 0 END) AS TotalRejects,
        SUM(CASE WHEN dc.IsNonRejectScrap = 1 THEN CAST(re.Quantity AS BIGINT) ELSE 0 END) AS TotalNonRejectScrap
    FROM Workorder.RejectEvent re
    INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
    INNER JOIN Lots.Lot           l  ON l.Id  = re.LotId
    INNER JOIN Parts.Item         i  ON i.Id  = l.ItemId
    WHERE (@FromUtc IS NULL OR re.RecordedAt >= @FromUtc)
      AND (@ToUtc   IS NULL OR re.RecordedAt <  @ToUtc)
    GROUP BY i.Id, i.PartNumber, i.Description
    ORDER BY i.PartNumber;
END
GO
