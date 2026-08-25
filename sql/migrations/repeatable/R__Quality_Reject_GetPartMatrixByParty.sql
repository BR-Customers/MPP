-- =============================================
-- Repeatable:  R__Quality_Reject_GetPartMatrixByParty.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-006 Part Matrix -- CHILD query, per-part party breakdown.
--              Called once per parent row with that row's ItemId (the Reporting
--              Module binds a child query's placeholders to parent-row columns).
--
--              Mirrors Quality.Reject_GetPlantSummary's attribution exactly,
--              scoped to one part: rejects attribute by DEFECT CODE
--              (ChargeToPartyId), production is that department's own output
--              FOR THIS PART. That is why the legacy shows rows like
--              "Die Cast Production 0 / Die Cast Reject 1" -- a casting defect
--              found downstream still charges Die Cast.
--
--              Non-reject scrap is excluded from the reject figures here too.
--
--              One result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Reject_GetPartMatrixByParty
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

    -- Per-part production, same three definitions as the Plant Summary.
    DECLARE @DieCastGood BIGINT = (
        SELECT ISNULL(SUM(CAST(dcc.PieceDelta AS BIGINT)), 0)
        FROM Workorder.DieCastContribution dcc
        INNER JOIN Lots.Lot l ON l.Id = dcc.LotId
        WHERE l.ItemId = @ItemId
          AND (@FromUtc IS NULL OR dcc.EventAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR dcc.EventAt <  @ToUtc));

    DECLARE @TrimGood BIGINT = (
        SELECT ISNULL(SUM(CAST(l.PieceCount AS BIGINT)), 0)
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot  ON ot.Id  = pe.OperationTemplateId
        INNER JOIN Parts.OperationType     oty ON oty.Id = ot.OperationTypeId
        INNER JOIN Lots.Lot                l   ON l.Id   = pe.LotId
        WHERE oty.Code = N'TrimOut' AND l.ItemId = @ItemId
          AND (@FromUtc IS NULL OR pe.EventAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR pe.EventAt <  @ToUtc));

    DECLARE @MachAsmGood BIGINT = (
        SELECT ISNULL(SUM(CAST(l.PieceCount AS BIGINT)), 0)
        FROM Lots.Lot l
        INNER JOIN Parts.Item     i  ON i.Id  = l.ItemId
        INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
        WHERE it.Code = N'FinishedGood' AND l.ItemId = @ItemId
          AND (@FromUtc IS NULL OR l.CreatedAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR l.CreatedAt <  @ToUtc));

    ;WITH Charged AS (
        SELECT dc.ChargeToPartyId, SUM(CAST(re.Quantity AS BIGINT)) AS RejectQty
        FROM Workorder.RejectEvent re
        INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
        INNER JOIN Lots.Lot           l  ON l.Id  = re.LotId
        WHERE l.ItemId = @ItemId
          AND dc.IsNonRejectScrap = 0
          AND (@FromUtc IS NULL OR re.RecordedAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR re.RecordedAt <  @ToUtc)
        GROUP BY dc.ChargeToPartyId
    ),
    Production AS (
        SELECT p.Id AS ChargeToPartyId,
               CASE p.Code
                   WHEN N'DieCast'     THEN @DieCastGood
                   WHEN N'TrimShop'    THEN @TrimGood
                   WHEN N'MachineShop' THEN @MachAsmGood
                   ELSE NULL
               END AS GoodPieces
        FROM Quality.ChargeToParty p
    )
    SELECT
        p.Code                 AS ChargeToPartyCode,
        p.Name                 AS ChargeToPartyName,
        pr.GoodPieces,
        ISNULL(c.RejectQty, 0) AS RejectPieces,
        CASE WHEN pr.GoodPieces IS NULL
                  OR (pr.GoodPieces + ISNULL(c.RejectQty, 0)) = 0 THEN NULL
             ELSE CAST(100.0 * ISNULL(c.RejectQty, 0)
                       / (pr.GoodPieces + ISNULL(c.RejectQty, 0)) AS DECIMAL(9, 2))
        END                    AS RejectPercent
    FROM Quality.ChargeToParty p
    INNER JOIN Production pr ON pr.ChargeToPartyId = p.Id
    LEFT  JOIN Charged    c  ON c.ChargeToPartyId  = p.Id
    ORDER BY p.SortOrder;
END
GO
