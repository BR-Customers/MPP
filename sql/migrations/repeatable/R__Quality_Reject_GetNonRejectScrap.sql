-- =============================================
-- Repeatable:  R__Quality_Reject_GetNonRejectScrap.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-006 Rejects -- the legacy "Non-Reject Scrap" block:
--              Trial Parts, Test Parts, Assembled-on-to-NG-part. Counted, but
--              EXCLUDED from every reject percentage -- which is why this is a
--              sibling read rather than another row in the Plant Summary.
--
--              Membership is Quality.DefectCode.IsNonRejectScrap (migration
--              0067), NOT IsExcused -- that is the OEE quality axis and the
--              two sets deliberately never overlap.
--
--              Sibling to Quality.Reject_GetPlantSummary: one proc, one result
--              set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Reject_GetNonRejectScrap
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
        dc.Code                              AS DefectCode,
        dc.Description                       AS DefectDescription,
        -- ISNULL INSIDE the SUM, not around it: the LEFT JOIN yields NULL
        -- rows for codes with no rejects in the window, and summing those
        -- raises 'Null value is eliminated by an aggregate' on every run.
        SUM(CAST(ISNULL(re.Quantity, 0) AS BIGINT)) AS Quantity
    FROM Quality.DefectCode dc
    LEFT JOIN Workorder.RejectEvent re
           ON re.DefectCodeId = dc.Id
          AND (@FromUtc IS NULL OR re.RecordedAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR re.RecordedAt <  @ToUtc)
    WHERE dc.IsNonRejectScrap = 1
    GROUP BY dc.Code, dc.Description
    ORDER BY dc.Code;
END
GO
