-- =============================================
-- Repeatable:  R__Quality_Reject_GetPartMatrixDefects.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-006 Part Matrix -- CHILD query, per-part defect
--              breakdown. Called once per parent row with that row's ItemId.
--
--              Reproduces the legacy "Reject Description" block, which prefixes
--              each defect with its department (DC - Broken Gate,
--              MS - Holesize). Here the prefix is a real column
--              (ChargeToPartyCode) rather than baked into the label, so the
--              layout can render it however it likes and the value stays
--              queryable.
--
--              Includes non-reject scrap rows, flagged -- the legacy prints
--              Trial/Test Parts in this same block, below the percentages.
--
--              One result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Reject_GetPartMatrixDefects
    @ItemId BIGINT,
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
        cp.Code                              AS ChargeToPartyCode,
        cp.Name                              AS ChargeToPartyName,
        dc.IsNonRejectScrap,
        SUM(CAST(re.Quantity AS BIGINT))     AS Quantity
    FROM Workorder.RejectEvent re
    INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
    INNER JOIN Lots.Lot           l  ON l.Id  = re.LotId
    LEFT  JOIN Quality.ChargeToParty cp ON cp.Id = dc.ChargeToPartyId
    WHERE l.ItemId = @ItemId
      AND (@FromUtc IS NULL OR re.RecordedAt >= @FromUtc)
      AND (@ToUtc   IS NULL OR re.RecordedAt <  @ToUtc)
    GROUP BY dc.Code, dc.Description, cp.Code, cp.Name, dc.IsNonRejectScrap
    ORDER BY dc.IsNonRejectScrap, cp.Code, dc.Code;
END
GO
