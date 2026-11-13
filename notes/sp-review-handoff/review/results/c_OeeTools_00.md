# Review: c_OeeTools_00 (57 Oee procs; the batch list contains no Tools procs)

Scope note. All 57 files were read. The config/CRUD procs (reason codes, schedules, overrides) were read for structure and the
write paths checked for lock/ordering shape; they touch small configuration tables or are rare supervisor actions.
The dashboard and shift-summary procs depend on inline/multi-statement functions that are NOT in this batch
(`ufn_ShiftGood`, `ufn_ShiftScrap`, `ufn_ShiftDowntimeEntries`, `ufn_ShiftInputFingerprint`, `ufn_ShiftSummaryRows`,
`ufn_ShiftAvailability`, `ufn_PeriodSummaryRows`, `ufn_ScopeMeasures`). I read those too, because the verdicts below turn on them.

What I VERIFIED about the environment:
- `Workorder.ProductionEvent` is clustered on `(LotId, EventAt)` (0020:292), partitioned monthly. It gained `ShiftId` in 0096.
  I grepped every file in `sql/migrations/versioned/` for any index on `ProductionEvent` and found only that clustered index: **there is no
  index with `ShiftId` as a key**.
- `Oee.DowntimeEvent` is NOT partitioned; indexes are PK, `UX_DowntimeEvent_OneOpenPerLocation (LocationId) WHERE EndedAt IS NULL`
  and `IX_DowntimeEvent_Shift (ShiftId, StartedAt)` (0026).
- `Oee.Shift`: `IX_Shift_ActualStart`, and unique filtered `UIX_Shift_SingleOpen (ActualEnd) WHERE ActualEnd IS NULL` (0020:940).
- `Lots.Lot` has `IX_Lot_ShiftId` (0117), `IX_Lot_Active (CurrentLocationId, LotStatusId) ... WHERE LotStatusId IN (1,2)` (0020:570),
  `IX_Lot_NotClosed_Location/Item` (0118).
- `Workorder.RejectEvent` clustered `(LotId, RecordedAt)`, partitioned on RecordedAt; `IX_RejectEvent_ShiftCavity (ShiftId, ToolCavityId, RecordedAt) WHERE ShiftId IS NOT NULL` (0084).
- No `READ_COMMITTED_SNAPSHOT` / `ALLOW_SNAPSHOT_ISOLATION` anywhere under `sql/` (grep returned nothing), so reads are READ COMMITTED with shared locks.

Polling facts (grep of `ignition/`):
- Polled on EVERY plant-floor terminal (`Views/ShopFloor/AppHeaderLarge/view.json`): `Oee.Downtime.getByScope` every 30 s (line 22 -> `Oee.DowntimeEvent_GetByScope`), `Oee.Shift.getOpenOrEmpty` every 15 s (line 44 -> `Oee.Shift_GetOpen`).
- SupervisorDashboard: `Oee.Dashboard.plantAvailabilityTile` every 300 s (-> `Dashboard_GetPeriod` + `Dashboard_GetUnitSummary` on the LAST CLOSED shift); `DowntimeEvent.getOpenSummary` poll 0.
- All other `BlueRidge.Oee.Dashboard.*` / `Oee.DowntimeEvent.*` view bindings use poll 0 (on load / on token bump only).
- Gateway timers (`ignition/projects/MPP/ignition/timer/`): `ShiftBoundaryTicker` 60 s, enabled -> `Shift_Reconcile`, and after a close -> `ShiftSummary_RefreshChanged(maxShifts=2)`.
  `OeeSummaryRefresh` (15 min, -> `ShiftSummary_RefreshChanged`) and `OeeSummaryNightly` are `"enabled": false` in the repo resource.json; I cannot tell what the live gateway has.
  `DowntimePlcWatcher` 5 s is a no-op (`_WATCH = []`).

| Proc | Verdict | Risk (H/M/L) | One-line reason | Result set unchanged by fix? |
|---|---|---|---|---|
| Oee_Dashboard_GetBreakdown | OK | L | read; nothing to change (bounded by period; per-shift stored reads) | n/a |
| Oee_Dashboard_GetDowntimeByReason | OK | L | read; WHILE over <=21 shifts of an inline TVF on `IX_DowntimeEvent_Shift`, cheap | n/a |
| Oee_Dashboard_GetDowntimeEntries | OK | L | read; one shift, seek on `IX_DowntimeEvent_Shift` | n/a |
| Oee_Dashboard_GetPeriod | OK | L | read; loads all `Oee.Shift` rows (~1k/yr) with no date bound, trivial at that volume | n/a |
| Oee_Dashboard_GetScrap | WATCH | M | always computes live per shift (never the stored summary); `ufn_ShiftGood` scans `ProductionEvent` (no ShiftId index) once per shift, up to 21x at Week zoom | Yes (index/ufn change) |
| Oee_Dashboard_GetTrend | OK | L | read; bounded 9-day window, reads stored rows for closed shifts | n/a |
| Oee_Dashboard_GetUnitSummary | WATCH | L | open shift (and any unstored shift) is computed live through two multi-statement TVFs; each dashboard proc repeats it per page load | Yes |
| Oee_DowntimeEvent_End | OK | L | read; read-then-update without lock, double End is harmless (same row, same values) | n/a |
| Oee_DowntimeEvent_GetByScope | WATCH | L | polled every 30 s per terminal; catch-all `OR` on `ShiftId` / open-event with a variable | Yes |
| Oee_DowntimeEvent_GetOpenByLocation | OK | L | read; served by the filtered `UX_DowntimeEvent_OneOpenPerLocation` | n/a |
| Oee_DowntimeEvent_GetOpenSummary | OK | L | read; `EndedAt IS NULL` matches the filtered index, tiny | n/a |
| Oee_DowntimeEvent_RecordApproximate | OK | L | read; single insert + audit | n/a |
| Oee_DowntimeEvent_RecordHistorical | OK | L | read; single insert + audit | n/a |
| Oee_DowntimeEvent_RequiresReasonGate | OK | L | read; PK lookups | n/a |
| Oee_DowntimeEvent_Start | OK | L | read; `IF EXISTS` open-event check then INSERT is racy but backed by unique filtered `UX_DowntimeEvent_OneOpenPerLocation`; loser gets error 2601 via CATCH (not corruption) | n/a |
| Oee_DowntimeEvent_UpdateReason | OK | L | read; single-row update + audit | n/a |
| Oee_DowntimeEvent_UpdateTimes | OK | L | read; same open-event race as Start, same unique-index backstop | n/a |
| Oee_DowntimeEvent_Void | OK | L | read; single-row update + audit | n/a |
| Oee_DowntimeReasonCode_Assign | OK | L | read; config-sized, single-row | n/a |
| Oee_DowntimeReasonCode_BulkLoadFromSeed | OK | L | read; rare seed loader, #temp staging, one txn | n/a |
| Oee_DowntimeReasonCode_Create | OK | L | read; config table | n/a |
| Oee_DowntimeReasonCode_Deprecate | OK | L | read; `COUNT(*) FROM DowntimeEvent WHERE DowntimeReasonCodeId` (line 117) has no supporting index but is a rare admin action on a small table | n/a |
| Oee_DowntimeReasonCode_Get | OK | L | read; nothing to change | n/a |
| Oee_DowntimeReasonCode_List | OK | L | read; config table | n/a |
| Oee_DowntimeReasonCode_Update | OK | L | read; config table | n/a |
| Oee_DowntimeReasonType_List | OK | L | read; nothing to change | n/a |
| Oee_DowntimeScope_ListForTerminal | OK | L | read; Location-tree recursion (MAXRECURSION 8), config-sized | n/a |
| Oee_DowntimeSourceCode_Get | OK | L | read; nothing to change | n/a |
| Oee_DowntimeSourceCode_List | OK | L | read; nothing to change | n/a |
| Oee_EndOfShiftEntry_Submit | WATCH | L | check-then-insert ("already submitted") with no lock and no unique key; a double tap can insert the break events twice | Yes |
| Oee_Lot_GetInProcessByLocation | WATCH | L | LOTs found via `sc.Code IN (...)` code-table join (cannot use `IX_Lot_Active`/`IX_Lot_NotClosed_Location`); plus `v_LotDerivedQuantities` aggregates `ConsumptionEvent` | Yes |
| Oee_ShiftHandover_Acknowledge | OK | L | read; audit-only | n/a |
| Oee_ShiftOverride_Apply | OK | L | read; rare supervisor action; wraps Restamp | n/a |
| Oee_ShiftOverride_Create | OK | L | read; rare; inserts then Restamp in one txn | n/a |
| Oee_ShiftOverride_Deprecate | OK | L | read; rare; Restamp in txn | n/a |
| Oee_ShiftOverride_Get | OK | L | read; nothing to change | n/a |
| Oee_ShiftOverride_List | OK | L | read; admin list, small table | n/a |
| Oee_ShiftOverride_ListEquipment | OK | L | read; `LIKE '%x%'` over a few dozen config rows | n/a |
| Oee_ShiftOverride_Restamp | OK | L | read; bounded to one location and a 3-day window using `IX_DieCastContribution_Cell` / `IX_DowntimeEvent_Shift`; short txn, rare | n/a |
| Oee_ShiftOverride_Update | OK | L | read; rare; same shape as Create | n/a |
| Oee_ShiftSchedule_Create | OK | L | read; config table | n/a |
| Oee_ShiftSchedule_Deprecate | OK | L | read; config table | n/a |
| Oee_ShiftSchedule_Get | OK | L | read; nothing to change | n/a |
| Oee_ShiftSchedule_List | OK | L | read; nothing to change | n/a |
| Oee_ShiftSchedule_Update | OK | L | read; config table | n/a |
| Oee_ShiftSummary_Compute | OK | L | read; thin wrapper (see ComputeCore note) | n/a |
| Oee_ShiftSummary_ComputeCore | WATCH | L | `DELETE` of the shift's stored rows is issued BEFORE the expensive `INSERT ... SELECT` inside one txn, so X locks sit on that shift's `ShiftSummary` rows for the whole recompute | Yes |
| Oee_ShiftSummary_RecomputeRange | OK | L | read; runbook-only; loops ComputeCore with one txn per shift (the `AT TIME ZONE` on `Oee.Shift` rows is a scan of ~1k rows/yr, irrelevant) | n/a |
| Oee_ShiftSummary_RefreshChanged | WATCH | M | per shift in last 7 days evaluates `ufn_ShiftInputFingerprint`, which scans `ProductionEvent` (no ShiftId index) and `RejectEvent` (OR predicate); runs after every shift close, and every 15 min if the timer is enabled on the gateway | Yes (index and/or function change) |
| Oee_Shift_End | OK | L | read; single-row txn | n/a |
| Oee_Shift_GetActive | OK | L | read; `ShiftSchedule` config table | n/a |
| Oee_Shift_GetAvailability | OK | L | read; calls multi-statement TVF `ufn_ShiftAvailability`, admin/config screen, bounded to one shift | n/a |
| Oee_Shift_GetForInstant | OK | L | read; inline TVF, config-sized | n/a |
| Oee_Shift_GetOpen | OK | L | read; polled every 15 s per terminal but is a single-row seek on `UIX_Shift_SingleOpen` | n/a |
| Oee_Shift_List | OK | L | read; optional filters, `Oee.Shift` is small | n/a |
| Oee_Shift_Reconcile | OK | L | read; runs every 60 s but the common path exits at the "No change" test after PK/filtered-index reads; the cursor (line 208) only runs on a backfill of up to 7 days; single-open race is backed by `UIX_Shift_SingleOpen` | n/a |
| Oee_Shift_Start | OK | L | read; `IF EXISTS open shift` then INSERT backed by `UIX_Shift_SingleOpen` | n/a |

---

## WATCH details

### Oee_ShiftSummary_RefreshChanged (WATCH, M) - the main finding of this batch

R__Oee_ShiftSummary_RefreshChanged.sql
```
 80  INSERT INTO @Todo (ShiftId, ActualStart)
 81  SELECT s.Id, s.ActualStart
 82  FROM Oee.Shift s
 83  OUTER APPLY (SELECT MIN(ss.ComputedAt) AS ComputedAt, MIN(ss.InputFingerprint) AS Fp, COUNT(*) AS N
 84               FROM Oee.ShiftSummary ss WHERE ss.ShiftId = s.Id) st
 ...
 89                 OR (x.StartUtc >= @Recent
 90                     AND st.Fp <> ISNULL((SELECT f.Fingerprint FROM Oee.ufn_ShiftInputFingerprint(s.Id) f), 0x)));
```
and R__Oee_ufn_zzzz_ShiftInputFingerprint.sql
```
 70  ON re.ShiftId = @ShiftId
 71  OR (re.ShiftId IS NULL AND re.RecordedAt >= DATEADD(HOUR, -12, Sh.StartUtc) AND re.RecordedAt < DATEADD(HOUR, 36, Sh.StartUtc))
 ...
 88  AND pe.LotId IN (SELECT p2.LotId FROM Workorder.ProductionEvent p2 WHERE p2.ShiftId = @ShiftId)
```
- VERIFIED: no index with `ShiftId` as a key exists on `Workorder.ProductionEvent` (grep of all versioned migrations; only
  `CIX_ProductionEvent_LotEventAt (LotId, EventAt)`). So line 88's inner `p2.ShiftId = @ShiftId` can only be answered by scanning the
  clustered index across all monthly partitions. The same inner scan is in `R__Oee_ufn_zzz_ShiftGood.sql:56`, which every
  `ShiftSummary_ComputeCore`, every live shift read and every `Dashboard_GetScrap` call goes through.
- VERIFIED: the `RejectEvent` join at lines 70-73 is an `OR` across a `ShiftId` equality and a `ShiftId IS NULL` + date window; I do not
  believe `IX_RejectEvent_ShiftCavity` can serve that (INFERRED, not run).
- INFERRED: the `@Todo` query could evaluate the fingerprint for every closed shift in history, not just the last 7, because the
  `x.StartUtc >= @Recent AND st.Fp <> (subquery)` conjunct is not guaranteed to short-circuit. There are ~1,100 shifts a year. Needs the
  plan to confirm.
- Not the 2026-11-10 shape: `ProductionEvent` is clustered, not a heap, so the page-lock deadlock mechanism does not carry over. The exposure here is
  scan cost plus shared locks on the hottest write table (no RCSI), at shift change when terminals are busiest.
- Fix (keeps the result set): add a partition-aligned filtered index `Workorder.ProductionEvent (ShiftId) WHERE ShiftId IS NOT NULL`
  (new versioned migration), and give the `RejectEvent` fingerprint branch two sargable seeks (`UNION ALL`) instead of one `OR`.
  Needs `ProductionEvent` row count and one actual plan before deciding; I do not know prod volume.
- Callers / frequency: `Oee.Summary.refreshChanged`. (a) `tickShiftBoundary` after `Shift_Reconcile` reports `ShiftsClosed` = ~3x/day (enabled),
  (b) `OeeSummaryRefresh` timer every 15 min (resource.json says disabled; live state unknown), (c) `OeeSummaryNightly` daily (disabled in repo).
  Also `ShiftSummary_Compute` from the Unit drill-down after an Edit.

### Oee_Dashboard_GetScrap (WATCH, M)

R__Oee_Dashboard_GetScrap.sql
```
57  FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId) p
58  CROSS APPLY Oee.ufn_ShiftScrap(p.ShiftId) s
...
66  FROM Oee.ufn_ShiftsForPeriod(@Zoom, @AnchorShiftId) p
67  CROSS APPLY Oee.ufn_ShiftGood(p.ShiftId) g
```
- VERIFIED: unlike `Dashboard_GetUnitSummary` (which reads `Oee.ShiftSummary` for closed shifts), this proc never reads the stored summary;
  it recomputes `ufn_ShiftScrap` and `ufn_ShiftGood` for every shift in the period on every call, closed or not.
- VERIFIED: `ufn_ShiftGood` contains the unindexed `ProductionEvent.ShiftId` scan (line 56), so Week zoom is up to 21 such scans per call; and
  `ufn_ShiftScrap` (lines 54-63) resolves every `ShiftId IS NULL` reject in a 48-hour window through `ufn_AreaFamily` + `ufn_ShiftIdForInstant` per row,
  repeated per shift. INFERRED: cost is dominated by those two, not by this proc's own code.
- Fix: none in this proc alone. Same index as above; reading `ShiftSummary` for closed shifts would change which numbers appear, so it is not
  a drop-in.
- Callers / frequency: `BlueRidge.Oee.Dashboard.scrap` from the Site/Area/Unit OEE pages, poll 0: on page open, zoom/step click.
  Not polled. A supervisor screen, a handful of calls an hour.

### Oee_Dashboard_GetUnitSummary (WATCH, L)

R__Oee_Dashboard_GetUnitSummary.sql
```
 90  FROM Oee.ufn_PeriodSummaryRows(@Zoom, @AnchorShiftId)
 ...
101  CROSS APPLY Oee.ufn_ShiftSummaryRows(s.Id) r      -- @ReadLive = 1 at Shift zoom
```
- VERIFIED (`ufn_PeriodSummaryRows`): a shift reads stored rows only when `ActualEnd IS NOT NULL` AND a `ShiftSummary` row exists; the open shift (and
  any not-yet-refreshed closed shift) falls to `ufn_ShiftSummaryRows`, a multi-statement TVF that itself calls the multi-statement
  `ufn_ShiftAvailability` (with a WHILE) and `ufn_ShiftGood`. Each OEE page calls several dashboard procs (UnitSummary, Trend, Breakdown, ...),
  and each recomputes the open shift independently.
- INFERRED: seconds, not minutes; it is bounded to one shift. Worth noting because of the 5-minute `plantAvailabilityTile` poll: that one asks for the
  last CLOSED shift, so it reads stored rows once `RefreshChanged` has run for it; it only goes live if that refresh has not happened.
- Fix: none needed unless measurement says so; if so, a single `ufn_ShiftSummaryRows` call materialised once per proc call.
- Callers / frequency: Site/Area/Unit pages (poll 0), plus `plantAvailabilityTile` every 300 s on SupervisorDashboard.

### Oee_DowntimeEvent_GetByScope (WATCH, L)

R__Oee_DowntimeEvent_GetByScope.sql
```
68    WHERE de.LocationId IN (SELECT Id FROM Scope)
69      AND (   @Shift IS NULL
70           OR de.ShiftId = @Shift
71           OR (@ShiftId IS NULL AND de.EndedAt IS NULL AND de.VoidedAt IS NULL))
```
- VERIFIED: the `OR` mixes a `ShiftId` equality (`IX_DowntimeEvent_Shift`) with an open-event test (`UX_DowntimeEvent_OneOpenPerLocation`, filtered), against
  a local variable, with no `LocationId`-leading general index. INFERRED that the plan is a clustered scan of `Oee.DowntimeEvent` with a filter, not
  two seeks; not run.
- Why it is only WATCH: `DowntimeEvent` is not partitioned and holds one row per stoppage, so the table is small today (I have no prod count).
  The reason to look is frequency, not size: this is polled every 30 s by every terminal header.
- Fix: resolve the two branches into an id list (`SELECT Id ... WHERE ShiftId = @Shift` UNION `SELECT Id ... WHERE EndedAt IS NULL AND VoidedAt IS NULL`
  when `@ShiftId IS NULL`), then join; same rows, same ORDER BY.
- Callers: `BlueRidge.Oee.Downtime.getByScope` from `AppHeaderLarge` (30 s, per terminal, every shop-floor screen); also the Downtime Manager views.

### Oee_Lot_GetInProcessByLocation (WATCH, L)

R__Oee_Lot_GetInProcessByLocation.sql
```
30    LEFT  JOIN Lots.v_LotDerivedQuantities dq ON dq.LotId = l.Id
31    OUTER APPLY (SELECT TOP 1 lm.MovedAt FROM Lots.LotMovement lm
32                 WHERE lm.LotId = l.Id AND lm.ToLocationId = @LocationId ORDER BY lm.MovedAt DESC) m
34    WHERE l.CurrentLocationId = @LocationId
35      AND sc.Code IN (N'Good', N'Hold')
```
- Same shape as root-cause (c) of the incident: the open-LOT filter goes through the `LotStatusCode` code-table join (`sc.Code IN ...`), which cannot
  match the filtered indexes (`IX_Lot_Active` is `WHERE LotStatusId IN (1,2)`, `IX_Lot_NotClosed_Location` is `<> 4`; 0118 states a code-table join cannot match). So
  the access is `IX_Lot_CurrentLocationId` plus a lookup per CLOSED LOT ever recorded at that cell.
- VERIFIED: `Lots.v_LotDerivedQuantities` (0020:657-675) is `Lots.Lot` LEFT JOIN two `GROUP BY` subqueries over ALL of `Workorder.ConsumptionEvent`.
  INFERRED (not run): the optimiser can usually push the `l.Id` join key through a GROUP BY on that column; if it does not, every call aggregates the whole table.
  `ConsumptionEvent` has the right indexes (`CIX_ConsumptionEvent_SourceLotConsumedAt`, `IX_ConsumptionEvent_ProducedLotId`).
- Per-LOT `LotMovement` seek (lines 31-33) is the same pattern as the fixed reference implementations; fine.
- Fix: repeat the literal `AND l.LotStatusId IN (1, 2)` next to the code-table filter (Good=1, Hold=2, the same literals `IX_Lot_Active` depends on), so the
  filtered index is chosen; rows are identical. Leave the view alone (it is shared; treat separately).
- Callers / frequency: `BlueRidge.Oee.DowntimeEvent.getEndOfShiftSummary` -> the End-of-Shift summary view, poll 0: once per operator per shift end, but all terminals at about the same time.

### Oee_ShiftSummary_ComputeCore (WATCH, L)

R__Oee_ShiftSummary_ComputeCore.sql
```
38    DELETE FROM Oee.ShiftSummary WHERE ShiftId = @ShiftId;
40    INSERT INTO Oee.ShiftSummary ( ... )
46    SELECT ... FROM Oee.ufn_ShiftSummaryRows(@ShiftId) r;
```
- VERIFIED: callers wrap ComputeCore in `BEGIN TRANSACTION` (Compute 61-63, RecomputeRange 64-66, RefreshChanged 103-105), so the DELETE's X locks on that
  shift's rows are held across the full evaluation of the multi-statement function. Dashboard reads of the same shift (`ufn_PeriodSummaryRows` EXISTS + join) wait on them (no RCSI).
- Narrow impact (one shift's rows) and it is bounded by compute time, which is the same cost as above. Not deadlock-shaped: it touches only `ShiftSummary`
  for writing, and reads the others.
- Fix: evaluate `ufn_ShiftSummaryRows` into a table variable first, then DELETE + INSERT from it (short lock window); rows identical.
- Callers: `refreshChanged` (shift close, timers), `compute` (Unit drill-down Edit), `recomputeRange` (runbook).

### Oee_EndOfShiftEntry_Submit (WATCH, L)

R__Oee_EndOfShiftEntry_Submit.sql
```
106   IF EXISTS (SELECT 1 FROM Oee.DowntimeEvent de ... WHERE de.ShiftId = @ShiftId AND de.AppUserId = @AppUserId AND rt.Code = N'Break')
...
135   BEGIN TRANSACTION;
137   INSERT INTO Oee.DowntimeEvent (...)
```
- VERIFIED: the duplicate check runs before `BEGIN TRANSACTION` with no `UPDLOCK, HOLDLOCK`, and there is no unique key that would stop a second set of
  Break rows. INFERRED: only a double-tap/duplicate click by the same operator can hit it; consequence is doubled break minutes for that shift.
- Fix: move the existence check inside the transaction with `WITH (UPDLOCK, HOLDLOCK)` (keeping the rejection BEFORE the txn for a first pass is fine; re-check inside) or let the
  existing guard stand and rely on the view disabling the button. Behaviour unchanged.
- Callers: `BlueRidge.Oee.DowntimeEvent.submitEndOfShift`, End-of-Shift view; once per operator per shift.

---

Other notes (no verdict change):
- `Oee_Shift_Reconcile` runs every 60 s on the gateway; its hot path (lines 73-116) is two small indexed reads and exits. OK.
- `DowntimePlcWatcher` (5 s) is inert until `_WATCH` is configured; when it is commissioned it will call `DowntimeEvent_Start`/`_GetOpenByLocation`/`_End`
  per edge only, not per tick, so those stay OK.
- The `ufn_*` files I read for context (`ShiftGood`, `ShiftScrap`, `ShiftInputFingerprint`, `ShiftSummaryRows`, `ShiftAvailability`) should be judged with the
  `ProductionEvent(ShiftId)` gap in mind by whoever owns them.

COUNTS: OK=50 WATCH=7 CANDIDATE=0
