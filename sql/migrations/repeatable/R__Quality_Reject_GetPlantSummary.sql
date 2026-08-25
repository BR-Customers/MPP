-- =============================================
-- Repeatable:  R__Quality_Reject_GetPlantSummary.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-25
-- Version:     1.0
-- Description: FDS-12-006 Rejects -- Plant Summary. Reproduces the legacy PD
--              "Reject Report Summary" Departmental Scrap block: one row per
--              charge-to party with good pieces, rejects, total and reject %.
--
--              ATTRIBUTION -- numerator and denominator come from DIFFERENT
--              places, and the legacy export proves it:
--
--                Part 121 (RPY Holder Comp No 2 In Cam) shows
--                  Die Cast Production 0 / Die Cast Reject 1
--                  Machine Shop Production 9,483 / Machine Shop Reject 0
--                  Reject Description: "DC - Broken Gate  1"
--
--                A DC-coded defect landed in the DIE CAST reject row even
--                though that part had zero die-cast production in the window,
--                and did NOT land in Machine Shop despite all of the part's
--                production being there.
--
--              So: REJECTS are attributed by DEFECT CODE (ChargeToPartyId).
--                  PRODUCTION is each department's own good output.
--              Reject % = that party's charged rejects / that party's own
--              production, which is why a party can show rejects against zero
--              production (percentage renders NULL, not a divide-by-zero).
--
--              PRODUCTION per party (Jacques, 2026-08-25):
--                Die Cast     SUM(DieCastContribution.PieceDelta) -- the only
--                             true append-only good-piece ledger we have.
--                Trim Shop    LOT piece count at the TrimOut checkpoint.
--                Machine Shop MACHINING **AND ASSEMBLY** -- the legacy row
--                             covers both, matching our MachiningAssembly
--                             OperationCategory. Good = finished-good LOT
--                             piece count.
--                The three Non-Specific / Die Maintenance parties have no
--                production of their own; they report rejects against NULL
--                production, exactly as the legacy does.
--
--              NON-REJECT SCRAP (Test/Trial/Assembled-on-NG) is EXCLUDED from
--              both the reject counts and the percentages -- it is counted, but
--              in its own block. Sibling proc: Quality.Reject_GetNonRejectScrap.
--
--              Dates are Eastern calendar days, inclusive both ends, converted
--              to a half-open UTC range here. One result set (FDS-11-011).
-- =============================================
CREATE OR ALTER PROCEDURE Quality.Reject_GetPlantSummary
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

    -- ---- Denominator: each department's own good output -------------------
    DECLARE @DieCastGood BIGINT = (
        SELECT ISNULL(SUM(CAST(dcc.PieceDelta AS BIGINT)), 0)
        FROM Workorder.DieCastContribution dcc
        WHERE (@FromUtc IS NULL OR dcc.EventAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR dcc.EventAt <  @ToUtc));

    -- Trim: the LOT's piece count as it left Trim (the TrimOut checkpoint).
    DECLARE @TrimGood BIGINT = (
        SELECT ISNULL(SUM(CAST(l.PieceCount AS BIGINT)), 0)
        FROM Workorder.ProductionEvent pe
        INNER JOIN Parts.OperationTemplate ot ON ot.Id  = pe.OperationTemplateId
        INNER JOIN Parts.OperationType     oty ON oty.Id = ot.OperationTypeId
        INNER JOIN Lots.Lot                l   ON l.Id   = pe.LotId
        WHERE oty.Code = N'TrimOut'
          AND (@FromUtc IS NULL OR pe.EventAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR pe.EventAt <  @ToUtc));

    -- Machine Shop = machining AND assembly. Good output is the finished-good
    -- LOTs those operations produced.
    DECLARE @MachAsmGood BIGINT = (
        SELECT ISNULL(SUM(CAST(l.PieceCount AS BIGINT)), 0)
        FROM Lots.Lot l
        INNER JOIN Parts.Item     i  ON i.Id  = l.ItemId
        INNER JOIN Parts.ItemType it ON it.Id = i.ItemTypeId
        WHERE it.Code = N'FinishedGood'
          AND (@FromUtc IS NULL OR l.CreatedAt >= @FromUtc)
          AND (@ToUtc   IS NULL OR l.CreatedAt <  @ToUtc));

    -- ---- Numerator: rejects charged to each party -------------------------
    ;WITH Charged AS (
        SELECT dc.ChargeToPartyId, SUM(CAST(re.Quantity AS BIGINT)) AS RejectQty
        FROM Workorder.RejectEvent re
        INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
        WHERE dc.IsNonRejectScrap = 0          -- counted in its own block, not here
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
                   ELSE NULL                    -- no production of their own
               END AS GoodPieces
        FROM Quality.ChargeToParty p
    )
    SELECT
        p.Code                                AS ChargeToPartyCode,
        p.Name                                AS ChargeToPartyName,
        pr.GoodPieces,
        ISNULL(c.RejectQty, 0)                AS RejectPieces,
        CASE WHEN pr.GoodPieces IS NULL THEN NULL
             ELSE pr.GoodPieces + ISNULL(c.RejectQty, 0) END AS TotalPieces,
        CASE WHEN pr.GoodPieces IS NULL
                  OR (pr.GoodPieces + ISNULL(c.RejectQty, 0)) = 0 THEN NULL
             ELSE CAST(100.0 * ISNULL(c.RejectQty, 0)
                       / (pr.GoodPieces + ISNULL(c.RejectQty, 0)) AS DECIMAL(9, 2))
        END                                   AS RejectPercent
    FROM Quality.ChargeToParty p
    INNER JOIN Production pr ON pr.ChargeToPartyId = p.Id
    LEFT  JOIN Charged    c  ON c.ChargeToPartyId  = p.Id
    ORDER BY p.SortOrder;
END
GO
