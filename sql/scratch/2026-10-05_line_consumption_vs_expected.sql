-- =============================================================================
-- LINE CONSUMPTION vs REFUSALS -- per component, for one line over a fixed
-- period. READ-ONLY: no writes, no transaction, safe against production.
--
--   Run through the wrapper, which saves each section to its own file:
--     .\sql\scripts\Invoke-LineConsumptionCheck.ps1 -From "2026-10-01" -To "2026-10-05"
--   Or standalone (SSMS / sqlcmd) with the DECLAREs below edited by hand.
--
-- WHAT THIS CAN AND CANNOT SAY
--   Workorder.Assembly_CompleteTray consumes exactly BOM x tray qty or nothing
--   at all, so "BOM x what MES produced" always equals what MES consumed. The
--   only trace INSIDE MES of consumption that physically happened and was not
--   recorded is a refused tray (an Audit.FailureLog row; everything rolled back).
--
--   A refusal row carries NO tray identity -- only part, qty, line, station,
--   operator. Operators stack trays and push several through in quick
--   succession (many refusals = many trays), and a tray is also re-presented
--   until it goes through (many refusals = one tray). The data cannot tell
--   those apart, so this script does NOT estimate lost trays. It reports:
--
--     Consumed        -- what MES recorded. Fact.
--     RefusalCeiling  -- every stock refusal x BOM, as if each one were a
--                        separate tray built anyway. An UPPER BOUND only; the
--                        true unrecorded consumption is between 0 and this.
--
--   Section 4 is the raw timeline (trays closed and refusals interleaved) so
--   the pattern can be read by eye rather than guessed by a rule.
--
-- Stock is one pool at the LINE, so quantities are never split by station;
-- station appears in the timeline as attribution only. Displayed times EASTERN.
-- =============================================================================
SET NOCOUNT ON;

-- ---- Parameters -------------------------------------------------------------
DECLARE @LineCode    NVARCHAR(50) = N'MA2-6MACH';
DECLARE @FromEastern DATETIME2(3) = '2026-10-01 00:00';   -- inclusive
DECLARE @ToEastern   DATETIME2(3) = '2026-10-05 00:00';   -- exclusive
DECLARE @TZ          NVARCHAR(50) = N'Eastern Standard Time';

DECLARE @LineId BIGINT = (SELECT Id FROM Location.Location
                          WHERE Code = @LineCode AND DeprecatedAt IS NULL);
IF @LineId IS NULL
BEGIN
    PRINT '*** UNKNOWN LINE CODE -- check it against Location.Location.Code. Stopping.';
    RETURN;
END

DECLARE @FromUtc DATETIME2(3) = CAST(@FromEastern AT TIME ZONE @TZ AT TIME ZONE 'UTC' AS DATETIME2(3));
DECLARE @ToUtc   DATETIME2(3) = CAST(@ToEastern   AT TIME ZONE @TZ AT TIME ZONE 'UTC' AS DATETIME2(3));

-- ---- The line subtree (deprecated locations included: they still own events) --
DECLARE @Scope TABLE (LocationId BIGINT PRIMARY KEY);
WITH tree AS (
    SELECT Id FROM Location.Location WHERE Id = @LineId
    UNION ALL
    SELECT c.Id FROM Location.Location c INNER JOIN tree t ON c.ParentLocationId = t.Id
)
INSERT INTO @Scope SELECT Id FROM tree;

-- ---- Actual: what MES consumed -----------------------------------------------
DECLARE @Actual TABLE (ConsumedItemId BIGINT PRIMARY KEY, Qty INT, FirstAt DATETIME2(3), LastAt DATETIME2(3));
INSERT INTO @Actual
SELECT ce.ConsumedItemId, SUM(ce.PieceCount), MIN(ce.ConsumedAt), MAX(ce.ConsumedAt)
FROM Workorder.ConsumptionEvent ce
WHERE ce.ConsumedAt >= @FromUtc AND ce.ConsumedAt < @ToUtc
  AND ce.LocationId IN (SELECT LocationId FROM @Scope)
GROUP BY ce.ConsumedItemId;

-- ---- Refused trays, stock reasons only ----------------------------------------
-- @CellLocationId in the JSON is the line id in the line-resident model.
DECLARE @Refusal TABLE (
    FailureId BIGINT PRIMARY KEY, AttemptedAt DATETIME2(3), AppUserId BIGINT,
    TerminalId BIGINT, FgItemId BIGINT, TrayQty INT, ClosureMethod NVARCHAR(20),
    Reason NVARCHAR(500));
INSERT INTO @Refusal
SELECT fl.Id, fl.AttemptedAt, fl.AppUserId,
       TRY_CAST(JSON_VALUE(fl.AttemptedParameters, '$.TerminalLocationId') AS BIGINT),
       TRY_CAST(JSON_VALUE(fl.AttemptedParameters, '$.FinishedGoodItemId') AS BIGINT),
       TRY_CAST(JSON_VALUE(fl.AttemptedParameters, '$.PieceCount') AS INT),
       JSON_VALUE(fl.AttemptedParameters, '$.ClosureMethod'),
       fl.FailureReason
FROM Audit.FailureLog fl
WHERE fl.AttemptedAt >= @FromUtc AND fl.AttemptedAt < @ToUtc
  AND fl.ProcedureName = N'Workorder.Assembly_CompleteTray'
  AND (fl.FailureReason LIKE N'%Insufficient component stock%'
       OR fl.FailureReason LIKE N'%drained mid-consume%')
  AND TRY_CAST(JSON_VALUE(fl.AttemptedParameters, '$.CellLocationId') AS BIGINT)
      IN (SELECT LocationId FROM @Scope);

-- ---- Ceiling per component = every refusal x the CURRENT published BOM --------
-- (the BOM in force at the time of the refusal is not recorded on the failure row)
DECLARE @Ceiling TABLE (ConsumedItemId BIGINT PRIMARY KEY, Qty INT, Refusals INT);
INSERT INTO @Ceiling
SELECT bl.ChildItemId, SUM(CAST(bl.QtyPer * r.TrayQty AS INT)), COUNT(*)
FROM @Refusal r
CROSS APPLY (SELECT TOP 1 bm.Id FROM Parts.Bom bm
             WHERE bm.ParentItemId = r.FgItemId AND bm.PublishedAt IS NOT NULL AND bm.DeprecatedAt IS NULL
             ORDER BY bm.VersionNumber DESC) bom
INNER JOIN Parts.BomLine bl ON bl.BomId = bom.Id
GROUP BY bl.ChildItemId;

-- =============================================================================
PRINT '';
PRINT '=== 1. Window ==============================================================';
SELECT @LineCode AS Line, @FromEastern AS FromEastern, @ToEastern AS ToEastern,
       (SELECT COUNT(DISTINCT ce.TrayId) FROM Workorder.ConsumptionEvent ce
        WHERE ce.ConsumedAt >= @FromUtc AND ce.ConsumedAt < @ToUtc
          AND ce.LocationId IN (SELECT LocationId FROM @Scope) AND ce.TrayId IS NOT NULL) AS TraysClosed,
       (SELECT COUNT(*) FROM @Refusal) AS StockRefusals;

PRINT '';
PRINT '=== 2. Consumed, and the refusal CEILING, per component ====================';
PRINT '    RefusalCeiling is an upper bound, not an estimate. See the file header.';
SELECT i.PartNumber AS Component, i.Description AS ComponentName,
       ISNULL(a.Qty, 0)      AS Consumed,
       ISNULL(c.Refusals, 0) AS RefusalsNeedingThisPart,
       ISNULL(c.Qty, 0)      AS RefusalCeiling,
       ISNULL(a.Qty, 0) + ISNULL(c.Qty, 0) AS ConsumedPlusCeiling,
       CAST(a.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS FirstConsumedEastern,
       CAST(a.LastAt  AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS LastConsumedEastern
FROM Parts.Item i
LEFT JOIN @Actual  a ON a.ConsumedItemId = i.Id
LEFT JOIN @Ceiling c ON c.ConsumedItemId = i.Id
WHERE a.ConsumedItemId IS NOT NULL OR c.ConsumedItemId IS NOT NULL
ORDER BY i.PartNumber;

PRINT '';
PRINT '=== 3. Consumed, split by what it was consumed INTO ========================';
SELECT ci.PartNumber AS Component, pi.PartNumber AS ProducedPart,
       SUM(ce.PieceCount) AS Consumed,
       COUNT(DISTINCT ce.ProducedLotId) AS ProducedLots,
       COUNT(DISTINCT ce.SourceLotId)   AS SourceLots
FROM Workorder.ConsumptionEvent ce
INNER JOIN Parts.Item ci ON ci.Id = ce.ConsumedItemId
INNER JOIN Parts.Item pi ON pi.Id = ce.ProducedItemId
WHERE ce.ConsumedAt >= @FromUtc AND ce.ConsumedAt < @ToUtc
  AND ce.LocationId IN (SELECT LocationId FROM @Scope)
GROUP BY ci.PartNumber, pi.PartNumber
ORDER BY ci.PartNumber, pi.PartNumber;

PRINT '';
PRINT '=== 4. Timeline: trays closed and stock refusals, interleaved ==============';
PRINT '    One row per closed tray (CLOSED) or per refused attempt (REFUSED).';
WITH closed AS (
    -- A tray is every ConsumptionEvent sharing a TrayId; the proc writes them in
    -- one transaction, so MIN(ConsumedAt) is the moment the tray closed.
    SELECT MIN(ce.ConsumedAt) AS At, ce.TerminalLocationId AS TerminalId, ce.AppUserId,
           ce.ProducedItemId AS FgItemId, ce.ProducedLotId, ce.TrayId
    FROM Workorder.ConsumptionEvent ce
    WHERE ce.ConsumedAt >= @FromUtc AND ce.ConsumedAt < @ToUtc
      AND ce.LocationId IN (SELECT LocationId FROM @Scope) AND ce.TrayId IS NOT NULL
    GROUP BY ce.TerminalLocationId, ce.AppUserId, ce.ProducedItemId, ce.ProducedLotId, ce.TrayId
), ev AS (
    SELECT c.At, N'CLOSED' AS Kind, c.TerminalId, c.AppUserId, c.FgItemId,
           tr.PartsClosedCount AS TrayQty, tr.ClosureMethod, l.LotName AS FgLot,
           CAST(NULL AS NVARCHAR(500)) AS Reason
    FROM closed c
    LEFT JOIN Lots.ContainerTray tr ON tr.Id = c.TrayId
    LEFT JOIN Lots.Lot l            ON l.Id = c.ProducedLotId
    UNION ALL
    SELECT r.AttemptedAt, N'REFUSED', r.TerminalId, r.AppUserId, r.FgItemId,
           r.TrayQty, r.ClosureMethod, NULL, r.Reason
    FROM @Refusal r
)
SELECT CAST(ev.At AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS AtEastern,
       ev.Kind, ISNULL(t.Code, N'(no terminal)') AS Station, u.Initials AS Operator,
       fg.PartNumber AS FinishedGood, ev.TrayQty, ev.ClosureMethod, ev.FgLot,
       DATEDIFF(SECOND, LAG(ev.At) OVER (PARTITION BY ev.TerminalId ORDER BY ev.At), ev.At) AS SecSincePrevAtStation,
       ev.Reason
FROM ev
LEFT JOIN Location.Location t ON t.Id = ev.TerminalId
LEFT JOIN Location.AppUser u  ON u.Id = ev.AppUserId
LEFT JOIN Parts.Item fg       ON fg.Id = ev.FgItemId
ORDER BY ev.At, ev.Kind;

PRINT '';
PRINT '=== 5. Per hour: trays closed vs refusals ==================================';
WITH ev AS (
    SELECT MIN(ce.ConsumedAt) AS At, 1 AS IsClosed, 0 AS IsRefused
    FROM Workorder.ConsumptionEvent ce
    WHERE ce.ConsumedAt >= @FromUtc AND ce.ConsumedAt < @ToUtc
      AND ce.LocationId IN (SELECT LocationId FROM @Scope) AND ce.TrayId IS NOT NULL
    GROUP BY ce.TrayId
    UNION ALL
    SELECT r.AttemptedAt, 0, 1 FROM @Refusal r
)
SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, CAST(At AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3))), 0) AS HourEastern,
       SUM(IsClosed) AS TraysClosed, SUM(IsRefused) AS Refusals
FROM ev
GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, CAST(At AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3))), 0)
ORDER BY 1;

PRINT '';
PRINT '=== 6. Machining OUT refusals in the window (NOT in section 2) =============';
PRINT '    MachiningOut_Mint takes an operator-entered quantity. Listed raw.';
SELECT CAST(fl.AttemptedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS AttemptedEastern,
       src.LotName AS SourceLot, si.PartNumber AS Casting,
       TRY_CAST(JSON_VALUE(fl.AttemptedParameters, '$.PieceCount') AS INT) AS QtyRequested,
       fl.FailureReason
FROM Audit.FailureLog fl
INNER JOIN Lots.Lot src  ON src.Id = TRY_CAST(JSON_VALUE(fl.AttemptedParameters, '$.SourceLotId') AS BIGINT)
INNER JOIN Parts.Item si ON si.Id = src.ItemId
WHERE fl.AttemptedAt >= @FromUtc AND fl.AttemptedAt < @ToUtc
  AND fl.ProcedureName = N'Workorder.MachiningOut_Mint'
  AND (fl.FailureReason LIKE N'%available in the FIFO queue%' OR fl.FailureReason LIKE N'%No castings available%')
  AND src.CurrentLocationId IN (SELECT LocationId FROM @Scope)
ORDER BY fl.AttemptedAt;
