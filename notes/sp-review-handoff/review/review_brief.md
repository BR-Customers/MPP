# Stored-procedure performance + concurrency review: reviewer brief

You are one of 12 parallel READ-ONLY reviewers for a SQL Server 2022 manufacturing system (an Ignition/Perspective MES; DB schemas
Location, Parts, Lots, Workorder, Quality, Oee, Tools, Audit). Repo root: `C:/Users/MalachiSpencer/Downloads/Active Development/MPP`.
Each proc is a file in `sql/migrations/repeatable/` named `R__<Schema>_<Name>.sql`.

## Hard rules
Read-only. Do NOT edit or create any file except your one report. Do NOT run git, sqlcmd, or anything against any database.
Do NOT propose behaviour changes: any fix must keep the result set (columns, order, rows) identical.

## Why we are doing this
On 2026-11-10 production stalled because two plant-floor queue-read procs scanned the `Lots.Lot` table (a HEAP: its PK is
NONCLUSTERED) in parallel plans with page locks, and deadlocked, undetected, against `Workorder.Assembly_CompleteTray` (insert new
LOT, then decrement source LOT). Root causes found: (a) a catch-all predicate
`(@IncludeDescendants = 1 AND col IN (...)) OR (@IncludeDescendants = 0 AND col = @x)` that no index can serve; (b) aggregating ALL of
`Lots.LotMovement` (`GROUP BY LotId`) on every call; (c) filtering open LOTs through a code-table join that cannot use the filtered
indexes. The fixed reference implementations are `R__Lots_Lot_GetWipQueueByLocation.sql` (v3.3) and
`R__Lots_Lot_GetTrimStorageQueueForLine.sql` (v2.1): resolve the location scope into a table variable first, then find open LOTs by
seek on `IX_Lot_NotClosed_Location` / `IX_Lot_NotClosed_Item` (filtered `LotStatusId <> 4`, migration 0118), then per-LOT seeks for
last movement.

Table facts: `Lots.Lot` is a heap (~41k rows prod, ~2.4k open); `Lots.LotMovement` is partitioned monthly, clustered
`(LotId, MovedAt)` (~46k rows); `Quality.QualitySample` has `IX_QualitySample_LotId_SampledAt`; event/audit/log tables are
partitioned by date and grow without bound. Table and index definitions live in `sql/migrations/versioned/*.sql`: grep them, do not
guess that an index exists.

## What to look for
Performance: catch-all OR predicates on indexed columns; non-sargable predicates (function/CAST on a column); aggregating or ranking
a whole large table with no per-key filter; scans of `Lots.Lot` / `Lots.LotMovement` / event / log / audit tables that grow;
per-row scalar subqueries or functions in hot reads; cursors / WHILE loops over rows where a set operation works; multi-statement
TVFs; implicit conversions (VARCHAR vs NVARCHAR); `SELECT *`; repeated identical subqueries; date-range reads with no date bound.

Concurrency / collisions: read-then-write without UPDLOCK/HOLDLOCK (check-then-insert races, `IF NOT EXISTS ... INSERT`,
`MAX(Id)+1`); transactions that touch tables in an order that differs from sibling procs (deadlock risk, especially anything touching
`Lots.Lot` together with `LotMovement` / `ProductionEvent` / `Container*`); long transactions; reads that take shared locks on hot
write tables while writers run; lock-escalation risk (bulk UPDATE/DELETE without batching).

Do NOT flag: style, naming, comments, micro-optimisations on small configuration tables (Location, Parts config, code tables), or
anything that cannot matter at the volumes above.

## Project rules a fix must respect (do not propose violating them)
Read procs return ONE result set and no OUTPUT params. Mutation procs end every exit path with `SELECT @Status, @Message, @NewId`.
A proc captured via INSERT-EXEC must not EXEC another status-row proc and must not ROLLBACK inside a caller's transaction, so
orchestrating procs inline their sub-mutations and run all rejecting validations BEFORE `BEGIN TRANSACTION`.
`Lots.ufn_NextPendingRouteStep` is shared by 8 callers; treat it as its own change, not part of a caller's.

## Verdicts (be conservative: you are reading code, not measuring)
- OK = read in full, nothing worth changing.
- WATCH = suspicious but needs a query plan / measurement or more context to decide.
- CANDIDATE = a concrete defect or clear inefficiency at the volumes above that is worth its own change.
Every WATCH/CANDIDATE MUST quote the exact line(s) with line numbers, and state what you VERIFIED vs INFERRED (for example
"verified in 0020 that Lots.Lot has no clustered index"; "inferred, not run"). Do not claim a deadlock or a prod bug you have not
traced; say "same shape as ..." instead. For each CANDIDATE also grep `ignition/` and `sql/` for callers and state how often it
probably runs (terminal-refresh polling vs admin screen vs rare).

## Report format (markdown file)
First a table with ONE ROW PER PROC IN YOUR BATCH (every one, in the batch's order):

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |

(For OK rows the reason is "read; nothing to change".) Then, for each WATCH/CANDIDATE only, a short section: quoted line(s) with
line numbers, verified vs inferred, proposed fix in 1-3 sentences, callers and run frequency. End with one line exactly like:
`COUNTS: OK=n WATCH=n CANDIDATE=n`.
Your final chat reply must be SHORT: the counts and the names of the CANDIDATE and WATCH procs only (the file has the detail).
