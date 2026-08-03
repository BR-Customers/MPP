# Shift Boundary Ticker → Reconcile-to-Now — Design Spec

**Date:** 2026-07-31
**Author:** Blue Ridge Automation
**Status:** Implemented 2026-07-31 (proc + tests + ticker wiring + dev seed). OI-38 logged for the local-time divergence.
**Arc / Phase:** Arc 2 (Plant Floor) — OEE / Shift lifecycle (Phase 8 foundation).
**Affects:** `ignition/.../timer/ShiftBoundaryTicker/handleTimerEvent.py`, `BlueRidge.Oee.Shift` (`code.py`), new `R__Oee_Shift_Reconcile.sql`, new NQ `oee/Shift_Reconcile`, new `sql/tests/0046_Shift_Reconcile/*`, new `sql/scratch/seed_shifts.sql`. Reads only (no schema change) against `Oee.Shift` + `Oee.ShiftSchedule`.

---

## 1. Problem

`Oee.Shift` runtime instances have ragged boundaries that do not line up with the schedule, and whole shifts go missing.

Root cause, traced through the code:

- `ShiftBoundaryTicker` (a gateway timer, therefore gated by gateway uptime) calls `BlueRidge.Oee.Shift.tickShiftBoundary(system.date.now())`.
- `tickShiftBoundary` starts/ends shifts with `actualStart = nowLocal` / `actualEnd = nowLocal` — **the wall-clock instant the tick runs**, never the schedule's boundary time.
- `Shift_Start` stores whatever it is handed (`@Start = ISNULL(@ActualStart, SYSUTCDATETIME())`).

Consequences:

1. **Ragged timestamps.** Boundaries land at detection time, not `07:00 / 15:00 / 23:00`. When the gateway is awake and ticking every ~60 s, they land within a minute of schedule (the clean-looking rows). When it is asleep at the boundary, the transition is stamped whenever it next wakes (`07:51`, `10:20`, …).
2. **Missing shifts.** `tickShiftBoundary` handles at most **one** boundary per tick (end open + start active). Any boundary that falls entirely inside a downtime window is skipped — the prior shift stays open across it (e.g. Second Shift open `15:01 07/30 → 07:51 07/31`, swallowing the overnight Third Shift), and multiple missed boundaries collapse into a single jump.

Observed in dev because the gateway runs on a 2-hour trial (not 24/7); the same failure occurs in production on any gateway restart/crash across a boundary.

### 1.1 Not a bug we are fixing here: local-vs-UTC storage

The **entire shift subsystem already operates consistently in local (Eastern) time**: `Shift_GetActive` compares `CAST(@Moment AS TIME(0))` directly against the schedule's local `StartTime`/`EndTime`, the ticker feeds it `system.date.now()` (local), `Shift_Start` stores that local value, and the die-cast picker displays the raw value with no timezone conversion. This is internally consistent but **diverges from the project's store-UTC convention** (CLAUDE.md § SQL design). 

**Decision:** keep this fix in local time (consistent with `getActive` and every existing row); do **not** bundle a UTC migration. The divergence is logged as an Open Item for a deliberate, separately-scoped future change. See §7.

---

## 2. Locked decisions

| # | Decision | Choice |
|---|---|---|
| D1 | What `ActualStart`/`ActualEnd` mean | **Snap to the scheduled boundary** (`07:00:00 / 15:00:00 / 23:00:00`), regardless of when the tick fires. Shifts are always exact schedule windows; robust to restarts. |
| D2 | Missed boundaries when the gateway was down | **Backfill the full timeline** — reconstruct every missed shift instance at its scheduled boundaries so there are no holes. |
| D3 | Backfill guardrail | **7 days.** If the last recorded shift is older than 7 days, skip backfill and just open the currently-active shift (documented gap). |
| D4 | Timezone scope | **Keep local**, flag the store-UTC divergence as an OI (see §1.1, §7). |
| D5 | Existing history | **Never rewrite a closed shift.** Reconcile only adjusts the still-open shift and fills genuinely-uncovered time. Closed shifts already carry committed event attribution (`DowntimeEvent.ShiftId`, die-cast shift-output `ShiftId`) by ID, so their time windows must not move. |

---

## 3. Architecture

Move all boundary logic out of Python and into one SQL proc (per CLAUDE.md § "No business logic in Python").

```
ShiftBoundaryTicker (timer, 60s)
        │  system.date.now()  (local Eastern)
        ▼
BlueRidge.Oee.Shift.reconcile(nowLocal)     ← thin wrapper (Core script)
        │
        ▼
NQ  oee/Shift_Reconcile   (type: Query — returns a status row)
        │
        ▼
Oee.Shift_Reconcile  @NowLocal, @MaxBackfillDays=7, @AppUserId, @TerminalLocationId
    → owns snap + close + backfill + open, atomically & idempotently
```

- `tickShiftBoundary` is replaced by a one-line `reconcile` wrapper. (The old name/behaviour is retired; the wrapper keeps the same "never throw from a gateway timer" guard — `try/except (Exception, java.lang.Exception)`.)
- `Shift_Start`, `Shift_End`, `Shift_GetActive`, `Shift_GetOpen`, `Shift_List` are **unchanged** and remain for manual operator start/end flows and tests.
- No schema changes. Existing indexes (`IX_Shift_ActualStart`, `IX_Shift_Schedule_Start`) cover the reconcile reads.

---

## 4. Core concept — scheduled instances & reconcile-to-now

### 4.1 Scheduled instance

A concrete `(ScheduleId, StartLocal, EndLocal)` derived from a `ShiftSchedule` row for one calendar date `D`:

- Include date `D` for schedule `S` iff `S.DeprecatedAt IS NULL`, `S.EffectiveFrom <= D`, and the ISO-day bit of `D` is set in `S.DaysOfWeekBitmask`.
- `StartLocal = CAST(D AS DATETIME2(3)) + S.StartTime`
- `EndLocal   = CASE WHEN S.EndTime > S.StartTime THEN D + S.EndTime ELSE DATEADD(DAY,1,D) + S.EndTime END`

Midnight-spanning shifts are attributed to their **start** day, matching `Shift_GetActive`'s existing rule (late portion matched on `@TodayBit`). ISO-day bit derivation reuses `getActive`'s `@@DATEFIRST`-independent formula: `isoDow = (DATEPART(WEEKDAY,d) + @@DATEFIRST + 5) % 7 + 1`, `bit = POWER(2, isoDow - 1)`.

Enumeration is a recursive date CTE from `anchorDate` to `nowDate` (bounded ≤ 8 rows by D3) cross-joined to `ShiftSchedule`, filtered as above. Cheap: ≤ ~24 candidate rows.

Well-formed configs do not overlap. If two schedules cover the same slot (mis-config), pick the winner with the same deterministic rule `getActive` uses: `EffectiveFrom DESC, Id DESC`.

### 4.2 The active instance

The scheduled instance whose `[StartLocal, EndLocal)` contains `@NowLocal`. Resolved by the same day-bit + time-window logic as `Shift_GetActive`, but computing the concrete `StartLocal`/`EndLocal`:

- same-day schedule (`EndTime > StartTime`): `StartLocal = nowDate + StartTime`.
- midnight-spanning, late portion (`nowTime >= StartTime`): `StartLocal = nowDate + StartTime`.
- midnight-spanning, early-morning tail (`nowTime < EndTime`): `StartLocal = (nowDate - 1) + StartTime`.

May be **NULL** — `@NowLocal` is in an uncovered gap (e.g. Monday overnight with Third Shift = Tue–Sat, or Sunday). A gap means *no shift should be open*.

### 4.3 Reconcile algorithm (each tick)

Given `@NowLocal`, `@MaxBackfillDays = 7`:

1. Resolve `activeInstance` (§4.2) and `open` = the single row with `ActualEnd IS NULL` (B3 invariant guarantees ≤ 1).
2. **Fast path / idempotency.** If `activeInstance` is not NULL **and** `open` exists **and** `open.ShiftScheduleId = activeInstance.ScheduleId` **and** `open.ActualStart = activeInstance.StartLocal` → nothing to do. `Status=1`, all counts 0, return. (This is the every-60s steady state.)
3. **Snap the open shift.** If `open` is the active schedule but `open.ActualStart <> activeInstance.StartLocal` (ragged, e.g. `15:01`→`15:00`) → `UPDATE ActualStart = StartLocal`. Open shift only; FK-safe (no committed end, attribution is by ID).
4. **Close a stale open shift.** If `open` exists and does **not** correspond to `activeInstance` (different schedule, or its own scheduled window has already ended) → `UPDATE ActualEnd = openScheduledEnd`, where `openScheduledEnd` is `open`'s scheduled `EndLocal` derived from `open.ShiftScheduleId` applied to the date of `open.ActualStart`. This is the only mutation touching a shift that is about to become closed; it sets the end to the schedule boundary, not `now`.
5. **Backfill.** Enumerate scheduled instances with `StartLocal` in the open gap `(lastShiftEnd, activeStartLocal)` — where `lastShiftEnd` is the `ActualEnd` of the most-recent existing shift after step 4 — bounded to `StartLocal >= @NowLocal - @MaxBackfillDays`. `INSERT` each as a **complete closed shift** (`ActualStart=StartLocal`, `ActualEnd=EndLocal`), but only where `NOT EXISTS` a shift overlapping that window (never touches existing closed history — D5). If the gap exceeds `@MaxBackfillDays`, **skip backfill entirely** and proceed to step 6 (documented gap).
6. **Open the active instance.** If `activeInstance` is not NULL and there is no longer an open shift matching it → `INSERT` it open (`ActualStart=StartLocal`, `ActualEnd=NULL`). If `activeInstance` **is** NULL (uncovered gap) → leave **no** open shift.

**First-ever run** (no shift rows at all): there is no anchor, so step 5 backfills nothing; step 6 opens the currently-active instance. (No 7-day retroactive shell-creation on a virgin DB.)

**B3 single-open invariant** holds at rest: close-then-open run inside one transaction yields exactly one open shift (or zero, in a gap).

---

## 5. Proc conventions & contract

- **Inlines** its close/insert/open mutations (mirroring the `Shift_Start` / `Shift_End` bodies, including their `Audit.Audit_LogOperation` `ShiftStarted` / `ShiftEnded` writes) rather than `EXEC`-ing them. Required because `Shift_Reconcile` itself returns a status row and is captured via `INSERT-EXEC` in tests — the `Lot_Split` / `Lot_Merge` inlining convention (CLAUDE.md § Ignition JDBC). Each inline block is commented as a mirror of its source-of-truth proc.
- **All rejecting validations before `BEGIN TRANSACTION`**; `ROLLBACK` only in the `CATCH` (a `ROLLBACK` inside an `INSERT-EXEC`-captured proc throws Msg 3915). `SET XACT_ABORT ON`. `RAISERROR` (not `THROW`) in `CATCH` with nested failure-logging try/catch, per `_TEMPLATE_stored_procedure.sql`.
- **No `OUTPUT` params.** Single result set on every exit path:
  `SELECT @Status AS Status, @Message AS Message, @ShiftsClosed AS ShiftsClosed, @ShiftsBackfilled AS ShiftsBackfilled, @ShiftOpened AS ShiftOpened;`
  (`@ShiftOpened` = the opened shift's Id or NULL.)
- **Audit.** Every backfilled and every opened shift emits a `ShiftStarted` op; every closed shift emits a `ShiftEnded` op — same Description shape and resolved-name JSON as the source procs. Audit writers emit no result set (safe inside the transaction).
- **NQ** `oee/Shift_Reconcile` typed **`Query`** (returns a result set), per the status-row-proc NQ-type rule.

---

## 6. Dev-testing seed (reuses the proc)

`sql/scratch/seed_shifts.sql`: clear recent `Oee.Shift` rows (respecting FK order — delete dependent `DowntimeEvent` / die-cast shift-output test rows first, or run against a shift-clean dev DB), `INSERT` **one anchor shift** ~2 days back ending on a real boundary, then `EXEC Oee.Shift_Reconcile @NowLocal = SYSDATETIME()`. The proc backfills the entire clean timeline (including the overnight Third Shift) up to now and opens the current shift. This gives realistic last-3 picker data regardless of the trial gateway, and exercises the proc end-to-end. `SYSDATETIME()` (local) is used deliberately, matching the subsystem's local-time basis.

---

## 7. Open Item — store-UTC divergence

Log an OI (register + `PROJECT_STATUS.md`): the shift subsystem stores and compares **local** time, diverging from the store-UTC convention. A future change would rewrite `Shift_GetActive` to convert schedule `TIME` → UTC per-date (DST-aware), migrate existing `Oee.Shift` rows, and audit every shift read/display. Out of scope here; called out so it is a deliberate decision, not an accident. Related to OI-36 (UTC-display read sweep).

---

## 8. Testing (TDD, `sql/tests/0046_Shift_Reconcile/`)

Seed a deterministic 3-shift schedule (First 07–15 Mon–Fri, Second 15–23 Mon–Fri, Third 23–07 Tue–Sat) and drive `Shift_Reconcile` with explicit `@NowLocal` values (never wall-clock) so cases are reproducible:

1. **Clean tick** — open shift already at exact boundary → no-op, counts 0.
2. **Idempotent** — run reconcile twice at same `@Now`; second run is a no-op, no duplicate rows.
3. **Ragged snap** — open shift `ActualStart` off by minutes → snapped to boundary, no new rows.
4. **Backfill one** — one missed boundary → prior shift closed at its `EndLocal`, one instance backfilled, current opened.
5. **Backfill full day** — gateway down across several boundaries within a day → every missed instance backfilled with exact windows, contiguous, current opened.
6. **Overnight backfill** — the reported case: down across a Second→Third→First span → Third Shift instance reconstructed `23:00→07:00`.
7. **Gap > 7 days** — last shift 10 days old → no backfill, current opened, one documented gap.
8. **Uncovered gap now** — `@Now` in Monday-overnight / Sunday window → any stale shift closed, **no** open shift left.
9. **First-ever run** — empty `Oee.Shift` → no backfill, current opened.
10. **B3 preserved** — after every case, at most one row has `ActualEnd IS NULL`.

Test teardown deletes dependent rows before `Oee.Shift` (FK order: audit → `DowntimeEvent` → `Shift`), per the Arc2 LOT-test teardown convention.

---

## 9. Out of scope

- UTC migration of the shift subsystem (§7 OI).
- Rewriting existing ragged/merged historical shifts (D5 — closed history is immutable).
- Any change to `Shift_Start` / `Shift_End` / `Shift_GetActive` behaviour (reused as-is).
- DST-correctness of local boundaries (local wall-clock is accepted; folds into the §7 OI).
