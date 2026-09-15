-- =============================================================================
-- LINE RUN AUDIT -- all-encompassing forensics for one production line over a
-- rolling window. READ-ONLY: no writes, no transaction, safe against production.
--
--   sqlcmd -S 172.17.10.148 -U Ignition -d MPP_MES_Prod -C -W -s "|"
--          -i sql\scratch\2026-09-15_line_run_audit.sql
--   (password from $env:SQLCMDPASSWORD -- never on the command line)
--   Or via the wrapper:  .\sql\scripts\Invoke-LineRunAudit.ps1
--
-- WHY THIS EXISTS (2026-09-15, line MA2-6MACH in Prod):
--   Component stock ran short during the day. Workorder.Assembly_CompleteTray
--   did its job -- it refused each tray and wrote an Audit.FailureLog row -- but
--   a refusal is only ever surfaced as a dismissible toast and is escalated to
--   nobody. Second shift had not been trained on the screen. So trays were not
--   submitted, and the damage is NOT merely a shortage:
--
--     * no finished-good LOT      -> that production is unrecorded;
--     * no ConsumptionEvent       -> component stock in MES is now OVERSTATED
--                                    by everything those trays would have eaten;
--     * no Container / tray row   -> physical boxes exist with no MES counterpart.
--
--   This script says what happened AND quantifies what is missing.
--
-- INVENTORY IS A LINE-LEVEL POOL. Every terminal on the line (-MIN, -AOUT1,
--   -AOUT2, -AOUT3) draws from the same stock, so no station can be short on its
--   own and a per-station stock figure would be meaningless. Part 4 resolves
--   stock at the LINE only; station/terminal appears in Part 3 purely as
--   attribution (who was clicking, where). Failure scoping rolls every location
--   key UP to its owning line for the same reason.
--
-- Design: docs/superpowers/specs/2026-09-15-line-run-audit-design.md
--
-- Every section ends in a Verdict column. All displayed times are EASTERN
-- (stored UTC, converted at the boundary per the house convention).
-- =============================================================================
SET NOCOUNT ON;

-- ---- Parameters -------------------------------------------------------------
DECLARE @LineCode         NVARCHAR(50) = N'MA2-6MACH';  -- 6MA Cam Holder Line 1
DECLARE @Hours            INT          = 24;            -- look-back window
DECLARE @BurstGapMinutes  INT          = 15;            -- see 3.5
DECLARE @TZ               NVARCHAR(50) = N'Eastern Standard Time';

DECLARE @LineId BIGINT = (SELECT Id FROM Location.Location
                          WHERE Code = @LineCode AND DeprecatedAt IS NULL);
IF @LineId IS NULL
BEGIN
    PRINT '*** UNKNOWN LINE CODE -- check it against Location.Location.Code. Stopping.';
    RETURN;
END

DECLARE @ToUtc   DATETIME2(3) = SYSUTCDATETIME();
DECLARE @FromUtc DATETIME2(3) = DATEADD(HOUR, -@Hours, @ToUtc);

-- ---- The line subtree -------------------------------------------------------
-- Everything at or beneath the line: cells, terminals, printers. Used to scope
-- every event query, and (rolled up) to scope failures.
-- DEPRECATED locations are deliberately INCLUDED. A station or printer retired
-- mid-window still owns the events that happened there, and excluding it would
-- silently drop them from the forensics. They are labelled in 0.2 instead.
DECLARE @Scope TABLE (
    LocationId BIGINT PRIMARY KEY, Code NVARCHAR(50), Name NVARCHAR(200),
    TypeDefId BIGINT, Depth INT, IsDeprecated BIT);

WITH tree AS (
    SELECT Id, Code, Name, LocationTypeDefinitionId, 0 AS Depth, DeprecatedAt
    FROM Location.Location WHERE Id = @LineId
    UNION ALL
    SELECT c.Id, c.Code, c.Name, c.LocationTypeDefinitionId, t.Depth + 1, c.DeprecatedAt
    FROM Location.Location c
    INNER JOIN tree t ON c.ParentLocationId = t.Id
)
INSERT INTO @Scope (LocationId, Code, Name, TypeDefId, Depth, IsDeprecated)
SELECT Id, Code, Name, LocationTypeDefinitionId, Depth,
       CASE WHEN DeprecatedAt IS NULL THEN 0 ELSE 1 END
FROM tree;

PRINT '';
PRINT '#############################################################################';
PRINT '##  LINE RUN AUDIT';
PRINT '#############################################################################';


-- =============================================================================
-- PART 0 -- CONTEXT
-- =============================================================================
PRINT '';
PRINT '=== 0.1 Run parameters and window ==========================================';
SELECT @LineCode AS LineCode, @LineId AS LineId,
       (SELECT Name FROM Location.Location WHERE Id = @LineId) AS LineName,
       @Hours AS WindowHours,
       CAST(@FromUtc AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS FromEastern,
       CAST(@ToUtc   AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS ToEastern,
       DB_NAME() AS Database_, @@SERVERNAME AS Server_;

PRINT '';
PRINT '=== 0.2 The line subtree (stations draw from ONE shared stock pool) ========';
SELECT REPLICATE(N'    ', s.Depth) + s.Code AS Location, s.Name,
       ltd.Code AS LocationType, s.LocationId,
       CASE WHEN s.IsDeprecated = 1      THEN 'DEPRECATED - kept in scope so its historic events still surface'
            WHEN s.Depth = 0             THEN 'LINE - inventory is held HERE'
            WHEN ltd.Code = N'Printer'   THEN 'printer'
            ELSE 'station - attribution only, holds no stock of its own' END AS Verdict
FROM @Scope s
LEFT JOIN Location.LocationTypeDefinition ltd ON ltd.Id = s.TypeDefId
ORDER BY s.Depth, s.Code;

PRINT '';
PRINT '=== 0.3 Database migration level (what is actually deployed here) ==========';
SELECT TOP 8 sv.MigrationId,
       CAST(sv.AppliedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS AppliedEastern
FROM dbo.SchemaVersion sv
ORDER BY sv.AppliedAt DESC, sv.MigrationId DESC;

SELECT COUNT(*) AS MigrationsApplied,
       'Compare against sql/migrations/versioned/ at the commit you are reading' AS Verdict
FROM dbo.SchemaVersion;

PRINT '';
PRINT '=== 0.4 Shifts overlapping the window ======================================';
SELECT sch.Name AS Shift,
       CAST(sh.ActualStart AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS StartEastern,
       CAST(sh.ActualEnd   AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS EndEastern,
       CASE WHEN sh.ActualEnd IS NULL THEN 'OPEN - running now' ELSE 'closed' END AS Verdict
FROM Oee.Shift sh
INNER JOIN Oee.ShiftSchedule sch ON sch.Id = sh.ShiftScheduleId
WHERE sh.ActualStart < @ToUtc AND ISNULL(sh.ActualEnd, @ToUtc) >= @FromUtc
ORDER BY sh.ActualStart;

PRINT '';
PRINT '=== 0.5 Operators who touched this line in the window ======================';
-- Everyone who created a LOT, moved one, recorded an event or consumed stock.
-- Operators who ONLY ever failed appear in 3.4, not here -- that contrast is
-- itself a finding.
WITH touched AS (
    SELECT l.CreatedByUserId AS UserId FROM Lots.Lot l
     WHERE l.CreatedAt BETWEEN @FromUtc AND @ToUtc
       AND (l.CurrentLocationId   IN (SELECT LocationId FROM @Scope)
            OR l.CreatedAtTerminalId IN (SELECT LocationId FROM @Scope))
    UNION ALL
    SELECT m.MovedByUserId FROM Lots.LotMovement m
     WHERE m.MovedAt BETWEEN @FromUtc AND @ToUtc
       AND (m.ToLocationId   IN (SELECT LocationId FROM @Scope)
            OR m.FromLocationId IN (SELECT LocationId FROM @Scope))
    UNION ALL
    SELECT pe.AppUserId FROM Workorder.ProductionEvent pe
     WHERE pe.EventAt BETWEEN @FromUtc AND @ToUtc
       AND pe.TerminalLocationId IN (SELECT LocationId FROM @Scope)
    UNION ALL
    SELECT ce.AppUserId FROM Workorder.ConsumptionEvent ce
     WHERE ce.ConsumedAt BETWEEN @FromUtc AND @ToUtc
       AND ce.LocationId IN (SELECT LocationId FROM @Scope)
)
SELECT u.Initials, u.DisplayName, ISNULL(u.AdAccount, N'(no AD account)') AS AdAccount,
       COUNT(*) AS RecordedActions,
       CASE WHEN u.DeprecatedAt IS NOT NULL THEN 'DEPRECATED user still transacting'
            ELSE 'active' END AS Verdict
FROM touched t
INNER JOIN Location.AppUser u ON u.Id = t.UserId
GROUP BY u.Initials, u.DisplayName, u.AdAccount, u.DeprecatedAt
ORDER BY COUNT(*) DESC;


-- =============================================================================
-- PART 1 -- WHAT GOT RECORDED
-- =============================================================================
PRINT '';
PRINT '=== 1.1 LOTs created at or beneath the line ================================';
SELECT l.LotName, i.PartNumber, i.Description AS Part,
       ot.Code AS Origin, sc.Code AS Status,
       l.PieceCount, l.InventoryAvailable,
       loc.Code AS AtLocation, ISNULL(term.Code, N'(none)') AS CreatedAtTerminal,
       u.Initials AS ByOperator,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS CreatedEastern
FROM Lots.Lot l
INNER JOIN Parts.Item i          ON i.Id   = l.ItemId
INNER JOIN Lots.LotOriginType ot ON ot.Id  = l.LotOriginTypeId
INNER JOIN Lots.LotStatusCode sc ON sc.Id  = l.LotStatusId
INNER JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
INNER JOIN Location.AppUser u    ON u.Id   = l.CreatedByUserId
LEFT  JOIN Location.Location term ON term.Id = l.CreatedAtTerminalId
WHERE l.CreatedAt BETWEEN @FromUtc AND @ToUtc
  AND (l.CurrentLocationId IN (SELECT LocationId FROM @Scope)
       OR l.CreatedAtTerminalId IN (SELECT LocationId FROM @Scope))
ORDER BY l.CreatedAt;

PRINT '';
PRINT '=== 1.2 LOT movements in and out of the line ===============================';
SELECT CAST(m.MovedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS MovedEastern,
       l.LotName, i.PartNumber, l.PieceCount,
       ISNULL(f.Code, N'(new)') AS FromLocation, t.Code AS ToLocation,
       u.Initials AS ByOperator,
       CASE WHEN m.ToLocationId IN (SELECT LocationId FROM @Scope)
             AND ISNULL(m.FromLocationId, -1) NOT IN (SELECT LocationId FROM @Scope) THEN 'IN  - stock arrived'
            WHEN m.FromLocationId IN (SELECT LocationId FROM @Scope)
             AND m.ToLocationId  NOT IN (SELECT LocationId FROM @Scope) THEN 'OUT - stock left'
            ELSE 'internal' END AS Verdict
FROM Lots.LotMovement m
INNER JOIN Lots.Lot l        ON l.Id  = m.LotId
INNER JOIN Parts.Item i      ON i.Id  = l.ItemId
INNER JOIN Location.Location t ON t.Id = m.ToLocationId
INNER JOIN Location.AppUser u ON u.Id = m.MovedByUserId
LEFT  JOIN Location.Location f ON f.Id = m.FromLocationId
WHERE m.MovedAt BETWEEN @FromUtc AND @ToUtc
  AND (m.ToLocationId IN (SELECT LocationId FROM @Scope)
       OR m.FromLocationId IN (SELECT LocationId FROM @Scope))
ORDER BY m.MovedAt;

PRINT '';
PRINT '=== 1.3 Operation checkpoints recorded at the line =========================';
SELECT CAST(pe.EventAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS EventEastern,
       l.LotName, i.PartNumber, ot.Code AS OperationType, otpl.Code AS Template,
       pe.ShotCount, pe.ScrapCount, term.Code AS AtTerminal, u.Initials AS ByOperator
FROM Workorder.ProductionEvent pe
INNER JOIN Lots.Lot l                  ON l.Id    = pe.LotId
INNER JOIN Parts.Item i                ON i.Id    = l.ItemId
INNER JOIN Parts.OperationTemplate otpl ON otpl.Id = pe.OperationTemplateId
INNER JOIN Parts.OperationType ot      ON ot.Id   = otpl.OperationTypeId
INNER JOIN Location.AppUser u          ON u.Id    = pe.AppUserId
LEFT  JOIN Location.Location term      ON term.Id = pe.TerminalLocationId
WHERE pe.EventAt BETWEEN @FromUtc AND @ToUtc
  AND (pe.TerminalLocationId IN (SELECT LocationId FROM @Scope)
       OR l.CurrentLocationId IN (SELECT LocationId FROM @Scope))
ORDER BY pe.EventAt;

PRINT '';
PRINT '=== 1.4 Trays closed (each = one finished-good LOT minted) =================';
SELECT CAST(tr.ClosedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS ClosedEastern,
       i.PartNumber AS FinishedGood, tr.PartsClosedCount AS PartsInTray,
       tr.TrayPosition, tr.ClosureMethod, c.Id AS ContainerId,
       ISNULL(st.Code, N'(unowned box)') AS Station, u.Initials AS ByOperator
FROM Lots.ContainerTray tr
INNER JOIN Lots.Container c   ON c.Id = tr.ContainerId
INNER JOIN Parts.Item i       ON i.Id = c.ItemId
LEFT  JOIN Location.AppUser u ON u.Id = tr.ClosedByUserId
LEFT  JOIN Location.Location st ON st.Id = c.StationLocationId
WHERE tr.ClosedAt BETWEEN @FromUtc AND @ToUtc
  AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
ORDER BY tr.ClosedAt;

PRINT '';
PRINT '=== 1.5 Containers opened / completed ======================================';
SELECT c.Id AS ContainerId, i.PartNumber AS FinishedGood, cs.Code AS Status,
       CAST(c.OpenedAt    AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS OpenedEastern,
       CAST(c.CompletedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS CompletedEastern,
       ISNULL(st.Code, N'(unowned)') AS Station,
       (SELECT COUNT(*) FROM Lots.ContainerTray x WHERE x.ContainerId = c.Id AND x.ClosedAt IS NOT NULL) AS TraysClosed,
       (SELECT ISNULL(SUM(x.PartsClosedCount),0) FROM Lots.ContainerTray x WHERE x.ContainerId = c.Id AND x.ClosedAt IS NOT NULL) AS PartsAccumulated,
       CASE WHEN cs.Code = N'Open' AND c.OpenedAt < DATEADD(HOUR, -12, @ToUtc)
                 THEN 'STALE - open over 12h, may be an abandoned box'
            WHEN cs.Code = N'Open' THEN 'open'
            ELSE 'closed out' END AS Verdict
FROM Lots.Container c
INNER JOIN Parts.Item i             ON i.Id  = c.ItemId
INNER JOIN Lots.ContainerStatusCode cs ON cs.Id = c.ContainerStatusCodeId
LEFT  JOIN Location.Location st     ON st.Id = c.StationLocationId
WHERE c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
  AND (c.OpenedAt BETWEEN @FromUtc AND @ToUtc
       OR c.CompletedAt BETWEEN @FromUtc AND @ToUtc
       OR c.ContainerStatusCodeId = 1)
ORDER BY c.OpenedAt;

PRINT '';
PRINT '=== 1.6 Rejects recorded against LOTs at the line ==========================';
-- Base columns only: RejectEvent gained ItemId/ToolId/ShiftId in migration 0084,
-- which may not be deployed here. Resolving the part through the LOT works in
-- both states.
SELECT CAST(re.RecordedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS RecordedEastern,
       l.LotName, i.PartNumber, dc.Code AS DefectCode, dc.Description AS Defect,
       re.Quantity, re.ChargeToArea, u.Initials AS ByOperator, re.Remarks
FROM Workorder.RejectEvent re
INNER JOIN Lots.Lot l          ON l.Id  = re.LotId
INNER JOIN Parts.Item i        ON i.Id  = l.ItemId
INNER JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId
INNER JOIN Location.AppUser u  ON u.Id  = re.AppUserId
WHERE re.RecordedAt BETWEEN @FromUtc AND @ToUtc
  AND l.CurrentLocationId IN (SELECT LocationId FROM @Scope)
ORDER BY re.RecordedAt;


-- =============================================================================
-- PART 2 -- PART CONSUMPTION
-- =============================================================================
PRINT '';
PRINT '=== 2.1 Consumption ledger (source LOT -> produced LOT) ====================';
SELECT CAST(ce.ConsumedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS ConsumedEastern,
       src.LotName AS SourceLot, ci.PartNumber AS ComponentPart, ce.PieceCount AS QtyConsumed,
       ISNULL(prod.LotName, N'(container only)') AS ProducedLot, pi.PartNumber AS ProducedPart,
       loc.Code AS AtLocation, u.Initials AS ByOperator
FROM Workorder.ConsumptionEvent ce
INNER JOIN Parts.Item ci         ON ci.Id  = ce.ConsumedItemId
INNER JOIN Parts.Item pi         ON pi.Id  = ce.ProducedItemId
INNER JOIN Location.Location loc ON loc.Id = ce.LocationId
INNER JOIN Location.AppUser u    ON u.Id   = ce.AppUserId
LEFT  JOIN Lots.Lot src          ON src.Id = ce.SourceLotId
LEFT  JOIN Lots.Lot prod         ON prod.Id = ce.ProducedLotId
WHERE ce.ConsumedAt BETWEEN @FromUtc AND @ToUtc
  AND ce.LocationId IN (SELECT LocationId FROM @Scope)
ORDER BY ce.ConsumedAt;

PRINT '';
PRINT '=== 2.2 Consumption roll-up per component part =============================';
SELECT ci.PartNumber AS ComponentPart, ci.Description AS Component,
       COUNT(*) AS ConsumeEvents, SUM(ce.PieceCount) AS TotalConsumed,
       COUNT(DISTINCT ce.SourceLotId) AS SourceLots,
       COUNT(DISTINCT ce.ProducedLotId) AS ProducedLots,
       'Compare against 4.1 need-vs-have -- this is what DID get eaten' AS Verdict
FROM Workorder.ConsumptionEvent ce
INNER JOIN Parts.Item ci ON ci.Id = ce.ConsumedItemId
WHERE ce.ConsumedAt BETWEEN @FromUtc AND @ToUtc
  AND ce.LocationId IN (SELECT LocationId FROM @Scope)
GROUP BY ci.PartNumber, ci.Description
ORDER BY SUM(ce.PieceCount) DESC;

PRINT '';
PRINT '=== 2.3 INTEGRITY: ConsumptionEvent vs LotGenealogy edges ==================';
PRINT '    Every consume writes BOTH a ConsumptionEvent row and a Consumption';
PRINT '    genealogy edge (RelationshipTypeId = 3). A row here means one of the';
PRINT '    two is missing -- a half-written consume, and a hole in Honda trace.';
PRINT '    EXPECT ZERO ROWS.';
SELECT 'ConsumptionEvent with no genealogy edge' AS Problem,
       ce.Id AS EventId, src.LotName AS SourceLot, prod.LotName AS ProducedLot,
       CAST(ce.ConsumedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS AtEastern,
       'INVESTIGATE - genealogy hole' AS Verdict
FROM Workorder.ConsumptionEvent ce
LEFT  JOIN Lots.Lot src  ON src.Id  = ce.SourceLotId
LEFT  JOIN Lots.Lot prod ON prod.Id = ce.ProducedLotId
WHERE ce.ConsumedAt BETWEEN @FromUtc AND @ToUtc
  AND ce.LocationId IN (SELECT LocationId FROM @Scope)
  AND ce.ProducedLotId IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM Lots.LotGenealogy g
                  WHERE g.ParentLotId = ce.SourceLotId
                    AND g.ChildLotId  = ce.ProducedLotId
                    AND g.RelationshipTypeId = 3)
UNION ALL
SELECT 'Genealogy edge with no ConsumptionEvent',
       g.Id, p.LotName, c.LotName,
       CAST(g.EventAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)),
       'INVESTIGATE - ledger hole'
FROM Lots.LotGenealogy g
INNER JOIN Lots.Lot p ON p.Id = g.ParentLotId
INNER JOIN Lots.Lot c ON c.Id = g.ChildLotId
WHERE g.EventAt BETWEEN @FromUtc AND @ToUtc
  AND g.RelationshipTypeId = 3
  AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
  AND NOT EXISTS (SELECT 1 FROM Workorder.ConsumptionEvent ce2
                  WHERE ce2.SourceLotId = g.ParentLotId
                    AND ce2.ProducedLotId = g.ChildLotId);


-- =============================================================================
-- PART 3 -- FAILURES  (the headline)
-- =============================================================================
-- Audit.FailureLog carries NO LocationId, so a failure is scoped to the line by
-- resolving every location key in its AttemptedParameters JSON and asking
-- whether any of them lands in the line subtree. Fallback: the LotId's current
-- location, for procs that pass no location at all.
--
-- Note Assembly_CompleteTray's parameter is named @CellLocationId but in the
-- line-resident model it IS the line id. The name is historic; the value is the
-- line.
DECLARE @Fail TABLE (
    FailureId    BIGINT PRIMARY KEY,
    AttemptedAt  DATETIME2(3),
    UserInitials NVARCHAR(10),
    UserName     NVARCHAR(200),
    ProcName     NVARCHAR(200),
    Reason       NVARCHAR(500),
    Params       NVARCHAR(MAX),
    TerminalId   BIGINT,
    TerminalCode NVARCHAR(50),
    ItemId       BIGINT,
    PieceCount   INT,
    Family       NVARCHAR(60));

INSERT INTO @Fail
SELECT f.Id, f.AttemptedAt, u.Initials, u.DisplayName, f.ProcedureName,
       f.FailureReason, f.AttemptedParameters,
       term.Id, term.Code,
       TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.FinishedGoodItemId') AS BIGINT),
       TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.PieceCount') AS INT),
       CASE
         WHEN f.FailureReason LIKE N'%Insufficient component stock%' THEN N'STOCK - short at the line'
         WHEN f.FailureReason LIKE N'%drained mid-consume%'          THEN N'STOCK - drained mid-consume'
         WHEN f.FailureReason LIKE N'%Container is full%'            THEN N'FLOW - box full, not completed'
         WHEN f.FailureReason LIKE N'%No active BOM%'                THEN N'CONFIG - no published BOM'
         WHEN f.FailureReason LIKE N'%pack-out%'                     THEN N'CONFIG - no pack-out'
         WHEN f.FailureReason LIKE N'%not eligible%'                 THEN N'CONFIG - part not eligible here'
         WHEN f.FailureReason LIKE N'%template%'                     THEN N'CONFIG - operation template'
         WHEN f.FailureReason LIKE N'%Tray parts count%'             THEN N'INPUT - tray count mismatch'
         WHEN f.FailureReason LIKE N'%Unexpected error%'             THEN N'ERROR - unhandled'
         ELSE N'OTHER'
       END
FROM Audit.FailureLog f
INNER JOIN Location.AppUser u ON u.Id = f.AppUserId
LEFT  JOIN Location.Location term
       ON term.Id = TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.TerminalLocationId') AS BIGINT)
WHERE f.AttemptedAt BETWEEN @FromUtc AND @ToUtc
  AND (
        EXISTS (
            SELECT 1
            FROM (VALUES
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.TerminalLocationId')        AS BIGINT)),
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.CellLocationId')            AS BIGINT)),
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.LineLocationId')            AS BIGINT)),
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.DestinationCellLocationId') AS BIGINT)),
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.SourceLocationId')          AS BIGINT)),
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.CurrentLocationId')         AS BIGINT)),
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.ToLocationId')              AS BIGINT)),
                    (TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.ProducedAtLocationId')      AS BIGINT))
                 ) v(LocId)
            INNER JOIN @Scope s ON s.LocationId = v.LocId)
     OR EXISTS (
            SELECT 1 FROM Lots.Lot l
            INNER JOIN @Scope s2 ON s2.LocationId = l.CurrentLocationId
            WHERE l.Id = TRY_CAST(JSON_VALUE(f.AttemptedParameters, '$.LotId') AS BIGINT))
      );

PRINT '';
PRINT '=== 3.1 Every failure at this line, chronological ==========================';
SELECT CAST(f.AttemptedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS AttemptedEastern,
       f.UserInitials AS Operator, ISNULL(f.TerminalCode, N'(no terminal)') AS Station,
       f.Family, ISNULL(i.PartNumber, N'-') AS Part, ISNULL(f.PieceCount, 0) AS QtyAttempted,
       f.ProcName, f.Reason
FROM @Fail f
LEFT JOIN Parts.Item i ON i.Id = f.ItemId
ORDER BY f.AttemptedAt;

PRINT '';
PRINT '=== 3.2 Failures by reason family ==========================================';
SELECT f.Family, COUNT(*) AS Attempts,
       COUNT(DISTINCT f.UserInitials) AS Operators,
       COUNT(DISTINCT f.TerminalCode) AS Stations,
       SUM(ISNULL(f.PieceCount, 0)) AS PartsAttempted,
       CAST(MIN(f.AttemptedAt) AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS FirstEastern,
       CAST(MAX(f.AttemptedAt) AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS LastEastern,
       CASE WHEN f.Family LIKE N'STOCK%'
                 THEN 'PRODUCTION WAS REFUSED - parts built, nothing recorded'
            WHEN f.Family LIKE N'CONFIG%'
                 THEN 'NOT a stock problem - the line was misconfigured'
            ELSE 'review' END AS Verdict
FROM @Fail f
GROUP BY f.Family
ORDER BY COUNT(*) DESC;

PRINT '';
PRINT '=== 3.3 Failures by HOUR vs trays actually closed ==========================';
PRINT '    An hour with failures and ZERO trays closed is an hour of production';
PRINT '    that physically happened and was never recorded. This is the shift';
PRINT '    pattern -- read it against 0.4.';
WITH hrs AS (
    SELECT DISTINCT DATEADD(HOUR, DATEDIFF(HOUR, 0, AttemptedAt), 0) AS HrUtc FROM @Fail
    UNION
    SELECT DISTINCT DATEADD(HOUR, DATEDIFF(HOUR, 0, tr.ClosedAt), 0)
    FROM Lots.ContainerTray tr
    INNER JOIN Lots.Container c ON c.Id = tr.ContainerId
    WHERE tr.ClosedAt BETWEEN @FromUtc AND @ToUtc
      AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
)
SELECT CAST(h.HrUtc AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS HourEastern,
       ISNULL(fa.Fails, 0)    AS FailedAttempts,
       ISNULL(fa.StockFails, 0) AS OfWhichStock,
       ISNULL(tc.Trays, 0)    AS TraysClosed,
       ISNULL(tc.Parts, 0)    AS PartsRecorded,
       CASE WHEN ISNULL(fa.Fails,0) > 0 AND ISNULL(tc.Trays,0) = 0
                 THEN 'BLIND HOUR - attempts failed, nothing recorded'
            WHEN ISNULL(fa.Fails,0) > 0
                 THEN 'degraded - some trays got through'
            ELSE 'clean' END AS Verdict
FROM hrs h
LEFT JOIN (SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, AttemptedAt), 0) AS HrUtc,
                  COUNT(*) AS Fails,
                  SUM(CASE WHEN Family LIKE N'STOCK%' THEN 1 ELSE 0 END) AS StockFails
           FROM @Fail GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, AttemptedAt), 0)) fa
       ON fa.HrUtc = h.HrUtc
LEFT JOIN (SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, tr.ClosedAt), 0) AS HrUtc,
                  COUNT(*) AS Trays, SUM(tr.PartsClosedCount) AS Parts
           FROM Lots.ContainerTray tr
           INNER JOIN Lots.Container c ON c.Id = tr.ContainerId
           WHERE tr.ClosedAt BETWEEN @FromUtc AND @ToUtc
             AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
           GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, tr.ClosedAt), 0)) tc
       ON tc.HrUtc = h.HrUtc
ORDER BY h.HrUtc;

PRINT '';
PRINT '=== 3.4 Failures by operator and station (attribution) =====================';
PRINT '    Station is attribution ONLY -- stock is pooled at the line, so no';
PRINT '    station is short on its own. A high count against one operator is a';
PRINT '    TRAINING signal, not a stock signal.';
SELECT f.UserInitials AS Operator, f.UserName,
       ISNULL(f.TerminalCode, N'(no terminal)') AS Station,
       COUNT(*) AS FailedAttempts,
       SUM(CASE WHEN f.Family LIKE N'STOCK%' THEN 1 ELSE 0 END) AS StockRefusals,
       succ.Successes AS TraysTheyClosed,
       CASE WHEN ISNULL(succ.Successes, 0) = 0
                 THEN 'NEVER succeeded here - likely did not understand the refusal'
            ELSE 'hit refusals but also completed trays' END AS Verdict
FROM @Fail f
OUTER APPLY (
    SELECT COUNT(*) AS Successes
    FROM Lots.ContainerTray tr
    INNER JOIN Lots.Container c ON c.Id = tr.ContainerId
    INNER JOIN Location.AppUser cu ON cu.Id = tr.ClosedByUserId
    WHERE tr.ClosedAt BETWEEN @FromUtc AND @ToUtc
      AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
      AND cu.Initials = f.UserInitials) succ
GROUP BY f.UserInitials, f.UserName, f.TerminalCode, succ.Successes
ORDER BY COUNT(*) DESC;

PRINT '';
PRINT '=== 3.5 Attempt bursts and abandonment -- *** ESTIMATE, NOT A COUNT *** ====';
PRINT '    Consecutive failures at the same station for the same part, with gaps';
PRINT '    under the burst threshold, are treated as ONE intended tray. A burst';
PRINT '    never followed by a success is production that was physically built';
PRINT '    and never recorded.';
PRINT '';
PRINT '    ASSUMPTION: the operator did not retry successfully at another';
PRINT '    station. If they did, this OVERSTATES the loss. Do not quote this';
PRINT '    figure to Honda -- it sizes the problem, it does not certify it.';
WITH ordered AS (
    SELECT f.*,
           LAG(f.AttemptedAt) OVER (PARTITION BY f.TerminalCode, f.ItemId ORDER BY f.AttemptedAt) AS PrevAt
    FROM @Fail f WHERE f.Family LIKE N'STOCK%'
), flagged AS (
    SELECT *, CASE WHEN PrevAt IS NULL
                     OR DATEDIFF(MINUTE, PrevAt, AttemptedAt) > @BurstGapMinutes
                   THEN 1 ELSE 0 END AS NewBurst
    FROM ordered
), bursts AS (
    SELECT *, SUM(NewBurst) OVER (PARTITION BY TerminalCode, ItemId
                                  ORDER BY AttemptedAt ROWS UNBOUNDED PRECEDING) AS BurstNo
    FROM flagged
), agg AS (
    -- Collapse to one row per burst FIRST. The next-success lookup is applied
    -- to the collapsed row, not to each attempt -- correlating it before the
    -- aggregate would split every burst back into single rows.
    SELECT TerminalCode, ItemId, BurstNo,
           COUNT(*)           AS AttemptsInBurst,
           MAX(PieceCount)    AS TrayQtyAttempted,
           MIN(AttemptedAt)   AS FirstAt,
           MAX(AttemptedAt)   AS LastAt
    FROM bursts
    GROUP BY TerminalCode, ItemId, BurstNo
)
SELECT ISNULL(a.TerminalCode, N'(no terminal)') AS Station,
       ISNULL(i.PartNumber, N'-') AS Part,
       a.BurstNo AS Burst,
       a.AttemptsInBurst,
       ISNULL(a.TrayQtyAttempted, 0) AS TrayQtyAttempted,
       CAST(a.FirstAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS FirstEastern,
       CAST(a.LastAt  AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS LastEastern,
       nxt.MinutesToNextSuccess,
       CASE WHEN nxt.MinutesToNextSuccess IS NULL
                 THEN 'ABANDONED - est. ' + CAST(ISNULL(a.TrayQtyAttempted, 0) AS NVARCHAR(10)) + ' parts UNRECORDED'
            WHEN nxt.MinutesToNextSuccess <= 60
                 THEN 'recovered after ' + CAST(nxt.MinutesToNextSuccess AS NVARCHAR(10)) + ' min'
            ELSE 'recovered late (' + CAST(nxt.MinutesToNextSuccess AS NVARCHAR(10)) + ' min)' END AS Verdict
FROM agg a
LEFT JOIN Parts.Item i ON i.Id = a.ItemId
OUTER APPLY (
    SELECT TOP 1 DATEDIFF(MINUTE, a.LastAt, tr.ClosedAt) AS MinutesToNextSuccess
    FROM Lots.ContainerTray tr
    INNER JOIN Lots.Container c ON c.Id = tr.ContainerId
    WHERE c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
      AND c.ItemId = a.ItemId
      AND tr.ClosedAt > a.LastAt
      AND tr.ClosedAt <= @ToUtc
    ORDER BY tr.ClosedAt) nxt
ORDER BY a.FirstAt;

PRINT '';
PRINT '=== 3.6 Is it STILL failing right now? ====================================';
SELECT COUNT(*) AS FailuresLast60Min,
       CAST(MAX(f.AttemptedAt) AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS MostRecentEastern,
       CASE WHEN COUNT(*) = 0 THEN 'CLEAR - nothing failing in the last hour'
            ELSE '*** STILL FAILING - go look at the line ***' END AS Verdict
FROM @Fail f
WHERE f.AttemptedAt >= DATEADD(MINUTE, -60, @ToUtc);


-- =============================================================================
-- PART 4 -- THE INVENTORY GAP
-- =============================================================================
PRINT '';
PRINT '=== 4.1 Shortfall parsed out of each refusal ===============================';
PRINT '    The proc already names the short component and the numbers:';
PRINT '    "short: <PART> (need N, have M)". This is fact, not inference.';
WITH frags AS (
    SELECT f.FailureId, f.AttemptedAt, f.UserInitials, f.TerminalCode,
           LTRIM(RTRIM(sp.value)) AS Frag
    FROM @Fail f
    CROSS APPLY STRING_SPLIT(
        REPLACE(f.Reason, N'Insufficient component stock at the line -- short: ', N''), N';') sp
    WHERE f.Family = N'STOCK - short at the line'
), parsed AS (
    SELECT FailureId, AttemptedAt, UserInitials, TerminalCode, Frag,
           LTRIM(RTRIM(LEFT(Frag, NULLIF(CHARINDEX(N' (need ', Frag), 0) - 1))) AS PartNumber,
           TRY_CAST(SUBSTRING(Frag,
                     CHARINDEX(N'(need ', Frag) + 6,
                     NULLIF(CHARINDEX(N', have ', Frag), 0) - (CHARINDEX(N'(need ', Frag) + 6)) AS INT) AS Needed,
           TRY_CAST(REPLACE(REPLACE(SUBSTRING(Frag,
                     CHARINDEX(N', have ', Frag) + 7, 20), N')', N''), N'.', N'') AS INT) AS OnHand
    FROM frags
    WHERE CHARINDEX(N' (need ', Frag) > 0 AND CHARINDEX(N', have ', Frag) > 0
)
SELECT CAST(p.AttemptedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS AttemptedEastern,
       p.UserInitials AS Operator, ISNULL(p.TerminalCode, N'(none)') AS Station,
       p.PartNumber AS ShortComponent, p.Needed, p.OnHand,
       p.Needed - p.OnHand AS Shortfall,
       CASE WHEN p.OnHand = 0 THEN 'EMPTY - no stock of this component at the line at all'
            ELSE 'partial - some stock, not enough for the tray' END AS Verdict
FROM parsed p
ORDER BY p.AttemptedAt, p.PartNumber;

PRINT '';
PRINT '=== 4.2 Worst shortfall per component ======================================';
WITH frags AS (
    SELECT f.FailureId, f.AttemptedAt, LTRIM(RTRIM(sp.value)) AS Frag
    FROM @Fail f
    CROSS APPLY STRING_SPLIT(
        REPLACE(f.Reason, N'Insufficient component stock at the line -- short: ', N''), N';') sp
    WHERE f.Family = N'STOCK - short at the line'
), parsed AS (
    SELECT FailureId, AttemptedAt,
           LTRIM(RTRIM(LEFT(Frag, NULLIF(CHARINDEX(N' (need ', Frag), 0) - 1))) AS PartNumber,
           TRY_CAST(SUBSTRING(Frag, CHARINDEX(N'(need ', Frag) + 6,
                     NULLIF(CHARINDEX(N', have ', Frag), 0) - (CHARINDEX(N'(need ', Frag) + 6)) AS INT) AS Needed,
           TRY_CAST(REPLACE(REPLACE(SUBSTRING(Frag, CHARINDEX(N', have ', Frag) + 7, 20), N')', N''), N'.', N'') AS INT) AS OnHand
    FROM frags
    WHERE CHARINDEX(N' (need ', Frag) > 0 AND CHARINDEX(N', have ', Frag) > 0
)
SELECT p.PartNumber AS ShortComponent, i.Description AS Component,
       COUNT(*) AS TimesBlockedATray,
       MAX(p.Needed - p.OnHand) AS WorstShortfall,
       MIN(p.OnHand) AS LowestOnHand,
       CAST(MIN(p.AttemptedAt) AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS FirstBlockedEastern,
       CAST(MAX(p.AttemptedAt) AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS LastBlockedEastern,
       'THIS is the part that stopped the line' AS Verdict
FROM parsed p
LEFT JOIN Parts.Item i ON i.PartNumber = p.PartNumber AND i.DeprecatedAt IS NULL
GROUP BY p.PartNumber, i.Description
ORDER BY COUNT(*) DESC;

PRINT '';
PRINT '=== 4.3 Component stock at the LINE right now vs one tray''s need ==========';
PRINT '    Stock is a single pool held at the line. Mirrors the proc''s own FIFO';
PRINT '    availability read: excludes Closed/Open, and excludes blocking';
PRINT '    statuses (Hold/Scrap).';
SELECT fg.PartNumber AS FinishedGood, ci.PartNumber AS Component, ci.Description AS ComponentName,
       bl.QtyPer, cc.PartsPerTray,
       CAST(bl.QtyPer * cc.PartsPerTray AS INT) AS NeedPerTray,
       ISNULL(av.Avail, 0) AS AvailableAtLine,
       CASE WHEN cc.PartsPerTray IS NULL OR bl.QtyPer = 0 THEN NULL
            ELSE ISNULL(av.Avail, 0) / NULLIF(CAST(bl.QtyPer * cc.PartsPerTray AS INT), 0) END AS TraysCovered,
       CASE WHEN cc.Id IS NULL THEN 'NO PACK-OUT CONFIGURED - cannot size a tray (see 5.1)'
            WHEN ISNULL(av.Avail, 0) = 0 THEN '*** EMPTY - next tray WILL be refused ***'
            WHEN ISNULL(av.Avail, 0) < CAST(bl.QtyPer * cc.PartsPerTray AS INT)
                 THEN '*** SHORT - next tray WILL be refused ***'
            WHEN ISNULL(av.Avail, 0) < CAST(bl.QtyPer * cc.PartsPerTray AS INT) * 3
                 THEN 'LOW - under 3 trays of cover'
            ELSE 'ok' END AS Verdict
FROM Parts.Item fg
INNER JOIN Parts.Bom b       ON b.ParentItemId = fg.Id
                            AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
INNER JOIN Parts.BomLine bl  ON bl.BomId = b.Id
INNER JOIN Parts.Item ci     ON ci.Id = bl.ChildItemId
LEFT  JOIN Parts.ContainerConfig cc ON cc.ItemId = fg.Id AND cc.DeprecatedAt IS NULL
OUTER APPLY (
    SELECT SUM(l.InventoryAvailable) AS Avail
    FROM Lots.Lot l
    INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
    WHERE l.ItemId = bl.ChildItemId
      AND l.CurrentLocationId = @LineId
      AND sc.Code NOT IN (N'Closed', N'Open')
      AND sc.BlocksProduction = 0) av
WHERE EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e
              WHERE e.ItemId = fg.Id AND e.LocationId IN (SELECT LocationId FROM @Scope))
ORDER BY fg.PartNumber, ci.PartNumber;

PRINT '';
PRINT '=== 4.4 Per-part stock flow across the window ==============================';
SELECT i.PartNumber, i.Description AS Part,
       ISNULL(inb.Qty, 0)  AS ReceivedIn,
       ISNULL(cons.Qty, 0) AS ConsumedOut,
       ISNULL(made.Qty, 0) AS ProducedHere,
       ISNULL(now_.Avail, 0) AS AvailableNow,
       CASE WHEN ISNULL(cons.Qty,0) = 0 AND ISNULL(inb.Qty,0) > 0
                 THEN 'RECEIVED BUT NEVER CONSUMED - stock arrived, no trays ate it'
            WHEN ISNULL(now_.Avail,0) = 0 AND ISNULL(cons.Qty,0) > 0 THEN 'drained to zero'
            ELSE 'flowing' END AS Verdict
FROM Parts.Item i
OUTER APPLY (SELECT SUM(l.PieceCount) AS Qty FROM Lots.LotMovement m
             INNER JOIN Lots.Lot l ON l.Id = m.LotId
             WHERE l.ItemId = i.Id AND m.MovedAt BETWEEN @FromUtc AND @ToUtc
               AND m.ToLocationId IN (SELECT LocationId FROM @Scope)
               AND ISNULL(m.FromLocationId, -1) NOT IN (SELECT LocationId FROM @Scope)) inb
OUTER APPLY (SELECT SUM(ce.PieceCount) AS Qty FROM Workorder.ConsumptionEvent ce
             WHERE ce.ConsumedItemId = i.Id AND ce.ConsumedAt BETWEEN @FromUtc AND @ToUtc
               AND ce.LocationId IN (SELECT LocationId FROM @Scope)) cons
OUTER APPLY (SELECT SUM(l.PieceCount) AS Qty FROM Lots.Lot l
             WHERE l.ItemId = i.Id AND l.CreatedAt BETWEEN @FromUtc AND @ToUtc
               AND l.CurrentLocationId IN (SELECT LocationId FROM @Scope)) made
OUTER APPLY (SELECT SUM(l.InventoryAvailable) AS Avail FROM Lots.Lot l
             INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
             WHERE l.ItemId = i.Id AND l.CurrentLocationId = @LineId
               AND sc.Code NOT IN (N'Closed', N'Open') AND sc.BlocksProduction = 0) now_
WHERE ISNULL(inb.Qty,0) + ISNULL(cons.Qty,0) + ISNULL(made.Qty,0) + ISNULL(now_.Avail,0) > 0
ORDER BY i.PartNumber;

PRINT '';
PRINT '=== 4.5 INTEGRITY: PieceCount vs InventoryAvailable divergence =============';
PRINT '    B5 materialized quantities that disagree. NOTE: neither';
PRINT '    Lot_RectifyPieceCount nor Lot_Update can repair this -- both no-op';
PRINT '    reject when @PieceCount already equals the current value, so there is';
PRINT '    NO audited repair path today. Report it, do not hand-UPDATE it.';
SELECT l.LotName, i.PartNumber, sc.Code AS Status,
       l.PieceCount, l.InventoryAvailable, l.TotalInProcess,
       l.PieceCount - l.InventoryAvailable AS Divergence,
       loc.Code AS AtLocation,
       CASE WHEN l.InventoryAvailable < 0 THEN '*** NEGATIVE - corrupt ***'
            ELSE 'divergent - no audited repair path (see header)' END AS Verdict
FROM Lots.Lot l
INNER JOIN Parts.Item i          ON i.Id   = l.ItemId
INNER JOIN Lots.LotStatusCode sc ON sc.Id  = l.LotStatusId
INNER JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
WHERE l.CurrentLocationId IN (SELECT LocationId FROM @Scope)
  AND sc.Code NOT IN (N'Closed')
  AND (l.InventoryAvailable <> l.PieceCount OR l.InventoryAvailable < 0)
ORDER BY l.InventoryAvailable, l.LotName;

PRINT '';
PRINT '=== 4.6 Stranded / stale open LOTs sitting at the line =====================';
SELECT l.LotName, i.PartNumber, sc.Code AS Status, l.PieceCount, l.InventoryAvailable,
       loc.Code AS AtLocation,
       CAST(l.CreatedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS CreatedEastern,
       DATEDIFF(HOUR, l.CreatedAt, @ToUtc) AS AgeHours,
       CASE WHEN DATEDIFF(HOUR, l.CreatedAt, @ToUtc) > 72 THEN 'STALE - over 3 days at the line'
            WHEN sc.BlocksProduction = 1 THEN 'BLOCKED - held/scrap, invisible to the FIFO consume'
            ELSE 'live' END AS Verdict
FROM Lots.Lot l
INNER JOIN Parts.Item i          ON i.Id   = l.ItemId
INNER JOIN Lots.LotStatusCode sc ON sc.Id  = l.LotStatusId
INNER JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
WHERE l.CurrentLocationId IN (SELECT LocationId FROM @Scope)
  AND sc.Code NOT IN (N'Closed')
  AND (DATEDIFF(HOUR, l.CreatedAt, @ToUtc) > 72 OR sc.BlocksProduction = 1)
ORDER BY l.CreatedAt;


-- =============================================================================
-- PART 5 -- COULD THE LINE EVEN HAVE WORKED?
-- =============================================================================
PRINT '';
PRINT '=== 5.1 Config readiness for every finished good this line runs ===========';
PRINT '    A red row here means the refusals were a CONFIG failure, not a stock';
PRINT '    failure -- a different fix entirely.';
SELECT fg.PartNumber AS FinishedGood, fg.Description AS Part,
       CASE WHEN b.Id IS NULL THEN 'NO PUBLISHED BOM' ELSE 'v' + CAST(b.VersionNumber AS NVARCHAR(10)) END AS Bom,
       ISNULL(bl.Lines, 0) AS BomLines,
       CASE WHEN cc.Id IS NULL THEN 'NONE' ELSE cc.ClosureMethod END AS PackOut,
       cc.PartsPerTray, cc.TraysPerContainer,
       CASE WHEN b.Id IS NULL      THEN '*** BLOCKER - Assembly_CompleteTray refuses every tray ***'
            WHEN ISNULL(bl.Lines,0) = 0 THEN '*** BLOCKER - BOM has no lines: nothing is consumed ***'
            WHEN cc.Id IS NULL     THEN '*** BLOCKER - no pack-out configured at this line ***'
            ELSE 'ok' END AS Verdict
FROM Parts.Item fg
LEFT JOIN Parts.Bom b ON b.ParentItemId = fg.Id
                     AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
LEFT JOIN (SELECT BomId, COUNT(*) AS Lines FROM Parts.BomLine GROUP BY BomId) bl ON bl.BomId = b.Id
LEFT JOIN Parts.ContainerConfig cc ON cc.ItemId = fg.Id AND cc.DeprecatedAt IS NULL
WHERE fg.DeprecatedAt IS NULL
  AND EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e
              WHERE e.ItemId = fg.Id AND e.LocationId IN (SELECT LocationId FROM @Scope))
  -- Narrow to things this line actually PACKS OUT, without trusting ItemType:
  -- a real finished good has a BOM, or a pack-out, or a container history here.
  -- Deliberately an OR-union so an FG whose BOM is missing entirely -- the very
  -- case this section exists to catch -- still appears.
  AND (EXISTS (SELECT 1 FROM Parts.Bom b2 WHERE b2.ParentItemId = fg.Id)
       OR cc.Id IS NOT NULL
       OR EXISTS (SELECT 1 FROM Lots.Container c2
                  WHERE c2.ItemId = fg.Id
                    AND c2.CurrentLocationId IN (SELECT LocationId FROM @Scope)))
ORDER BY fg.PartNumber;

PRINT '';
PRINT '=== 5.2 BOM children with no stock-holding eligibility at this line ========';
PRINT '    A component that cannot legally sit at the line can never be staged,';
PRINT '    so its FIFO availability is permanently zero. EXPECT ZERO ROWS.';
SELECT fg.PartNumber AS FinishedGood, ci.PartNumber AS Component, ci.Description AS ComponentName,
       '*** Component is not eligible at this line - it can never be staged ***' AS Verdict
FROM Parts.Item fg
INNER JOIN Parts.Bom b      ON b.ParentItemId = fg.Id
                           AND b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL
INNER JOIN Parts.BomLine bl ON bl.BomId = b.Id
INNER JOIN Parts.Item ci    ON ci.Id = bl.ChildItemId
WHERE EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e
              WHERE e.ItemId = fg.Id AND e.LocationId IN (SELECT LocationId FROM @Scope))
  AND NOT EXISTS (SELECT 1 FROM Parts.v_EffectiveItemLocation e2
                  WHERE e2.ItemId = ci.Id
                    AND e2.LocationId IN (SELECT LocationId FROM Location.ufn_AncestorLocationIds(@LineId)))
ORDER BY fg.PartNumber, ci.PartNumber;

PRINT '';
PRINT '=== 5.3 Open containers already at or past full ============================';
PRINT '    An over-full open box refuses every further tray until someone presses';
PRINT '    Complete -- the same silent refusal, a different cause.';
SELECT c.Id AS ContainerId, i.PartNumber AS FinishedGood,
       ISNULL(st.Code, N'(unowned)') AS Station,
       acc.PartsAccumulated, cc.PartsPerTray * cc.TraysPerContainer AS FullTarget,
       CAST(c.OpenedAt AT TIME ZONE 'UTC' AT TIME ZONE @TZ AS DATETIME2(3)) AS OpenedEastern,
       CASE WHEN acc.PartsAccumulated >= cc.PartsPerTray * cc.TraysPerContainer
                 THEN '*** FULL - blocking every further tray at this station ***'
            ELSE 'has room' END AS Verdict
FROM Lots.Container c
INNER JOIN Parts.Item i ON i.Id = c.ItemId
INNER JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId
LEFT  JOIN Location.Location st ON st.Id = c.StationLocationId
CROSS APPLY (SELECT ISNULL(SUM(PartsClosedCount), 0) AS PartsAccumulated
             FROM Lots.ContainerTray x WHERE x.ContainerId = c.Id AND x.ClosedAt IS NOT NULL) acc
WHERE c.ContainerStatusCodeId = 1
  AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope)
  AND cc.PartsPerTray IS NOT NULL AND cc.TraysPerContainer IS NOT NULL
ORDER BY acc.PartsAccumulated DESC;


-- =============================================================================
-- PART 6 -- VERDICT ROLL-UP
-- =============================================================================
PRINT '';
PRINT '=== 6.1 THE SUMMARY =======================================================';
DECLARE @Fails       INT = (SELECT COUNT(*) FROM @Fail);
DECLARE @StockFails  INT = (SELECT COUNT(*) FROM @Fail WHERE Family LIKE N'STOCK%');
DECLARE @ConfigFails INT = (SELECT COUNT(*) FROM @Fail WHERE Family LIKE N'CONFIG%');
DECLARE @Recent      INT = (SELECT COUNT(*) FROM @Fail WHERE AttemptedAt >= DATEADD(MINUTE, -60, @ToUtc));
DECLARE @Trays       INT = (SELECT COUNT(*) FROM Lots.ContainerTray tr
                            INNER JOIN Lots.Container c ON c.Id = tr.ContainerId
                            WHERE tr.ClosedAt BETWEEN @FromUtc AND @ToUtc
                              AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope));
DECLARE @PartsMade   INT = (SELECT ISNULL(SUM(tr.PartsClosedCount), 0) FROM Lots.ContainerTray tr
                            INNER JOIN Lots.Container c ON c.Id = tr.ContainerId
                            WHERE tr.ClosedAt BETWEEN @FromUtc AND @ToUtc
                              AND c.CurrentLocationId IN (SELECT LocationId FROM @Scope));

SELECT @LineCode AS Line, @Hours AS WindowHours,
       @Trays AS TraysRecorded, @PartsMade AS PartsRecorded,
       @Fails AS FailedAttempts, @StockFails AS StockRefusals, @ConfigFails AS ConfigRefusals,
       CASE WHEN @Fails = 0 THEN 'CLEAN - nothing was refused on this line'
            WHEN @ConfigFails > @StockFails
                 THEN 'CONFIG PROBLEM - fix the setup, stock is not the story'
            WHEN @StockFails > 0 AND @Trays = 0
                 THEN '*** TOTAL LOSS - every attempt refused, NOTHING recorded all window ***'
            WHEN @StockFails > 0
                 THEN '*** STOCK SHORTAGE - production happened that MES never recorded ***'
            ELSE 'MIXED - read part 3' END AS Verdict,
       CASE WHEN @Recent > 0 THEN '*** STILL FAILING NOW (' + CAST(@Recent AS NVARCHAR(10)) + ' in last 60 min) ***'
            ELSE 'not currently failing' END AS RightNow;

PRINT '';
PRINT '=== 6.2 What to do with this ==============================================';
SELECT 1 AS Step, 'Read 4.2 - it names the component that stopped the line.' AS Action
UNION ALL SELECT 2, 'Read 3.3 - blind hours are production physically made and never recorded.'
UNION ALL SELECT 3, 'Read 3.5 - the ESTIMATE of how many parts that is. Do not quote it to Honda.'
UNION ALL SELECT 4, 'Read 4.3 - whether the line is about to refuse the NEXT tray too.'
UNION ALL SELECT 5, 'Read 5.1/5.2 - if anything is red there, this was config, not stock.'
UNION ALL SELECT 6, 'Component stock in MES is now OVERSTATED by everything the refused trays would have eaten. Reconcile before trusting 4.3.'
ORDER BY 1;

PRINT '';
PRINT '#############################################################################';
PRINT '##  END OF AUDIT';
PRINT '#############################################################################';
