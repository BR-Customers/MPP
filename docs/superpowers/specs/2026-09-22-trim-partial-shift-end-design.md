# Trim Partial Checkpoint at Shift End -- Design Spec

**Date:** 2026-09-22
**Status:** Design, awaiting Jacques's review
**Migration:** next free number at build time (`0096` or later -- the die cast shift reconciliation
and the part-type recategorization release may claim numbers first; re-check)
**Builds on:** `2026-06-15-arc2-phase4-movement-trim-sql-design.md` (Trim IN/OUT),
`2026-08-05-trim-out-multi-reason-scrap-design.md` (defect-coded scrap lines),
`2026-08-19-shift-override-attribution-design.md` (equipment-aware shift resolver).

---

## 1. Why

A trim LOT is credited in full to whichever shift presses **Trim OUT**. Many LOTs are trimmed in a
shift and they are fine; the problem is the **one LOT on the press at shift end**. If 2nd shift
trims 700 of a 953-piece LOT and 3rd shift finishes it, 3rd shift is credited 953 and 2nd shift 0.
The legacy Trim Shop Detail Report counted Good / No Good per **part x process x shift**, and the
MES cannot produce that today.

The shot blast presses need this. The tumblers will never use it: their LOT sizes and flow mean a
LOT does not straddle a shift. That is an artifact of current production, so the capability is
**optional**, per LOT, and nothing depends on it being used.

## 2. Decisions locked

| # | Decision |
|---|---|
| D1 | **Checkpoint on the LOT, no split.** A partial writes a mid-LOT `ProductionEvent`; the LOT stays whole, stays at its press, and its FIFO position is undisturbed. |
| D2 | **Optional.** A button, *Record partial trim -- shift end*. No prompt, no shift-end sweep, no dashboard signal when it is not used. |
| D3 | **The operator types the total trimmed so far on this LOT** -- a cumulative count, which is what `ProductionEvent.ShotCount` already stores. |
| D4 | **Trim OUT is unchanged** for the operator: it still enters the LOT's full count. The difference between checkpoints is the credit. |
| D5 | **Reuse the `TrimIn` operation template** for the partial checkpoint. No new template. |
| D6 | **Forced shift selection.** The partial popup has a shift picker with **nothing preselected**; Save is disabled until a shift is chosen. (The die cast shift-picker defect came from preselecting the current shift.) |
| D7 | Credit is **both** per shift / trim shop and per operator; both come from the same row. Trim is tracked at the **shop** (`TRIM1` / `TRIM2`); the presses were retired 2026-07-30, so there is no per-press location to credit. |

## 3. The model

### 3.1 What a partial writes

One `Workorder.ProductionEvent`:

| Column | Value |
|---|---|
| `LotId` | the LOT |
| `OperationTemplateId` | the active `TrimIn` template, resolved by route role (`TrimIn`), never by code |
| `ShotCount` | **cumulative** pieces trimmed so far on this LOT |
| `ScrapCount` | this event's scrap total (per-event, as Trim OUT since v1.3) |
| `ShiftId` | **new column**, the shift the operator picked |
| `AppUserId`, `TerminalLocationId` | as usual |

Plus one `Workorder.RejectEvent` per scrap line (stamped `ItemId` + `CellLocationId` +
`TerminalLocationId`, as Trim OUT v1.4, **and `ShiftId`** -- the existing 0084 column, so trim scrap
files under a shift too), decrementing `Lot.PieceCount` once by the total.

The LOT does **not** move.

### 3.2 Credit

Per LOT, over its **trim checkpoints only** (template `OperationType` in `TrimIn`, `TrimOut`),
ordered by `EventAt, Id`:

```
TrimmedThisEvent = ShotCount - ISNULL(LAG(ShotCount) OVER (PARTITION BY LotId ORDER BY EventAt, Id), 0)
```

The baseline is 0 -- earlier die cast rows on the LOT are **not** in the partition. Each event's
credit belongs to its `ShiftId`, its `AppUserId`, and the trim shop the LOT was at (derived from
`LotMovement` at `EventAt`, per the data model's no-`LocationId` rule). Scrap credit is the
`RejectEvent` rows by their stamped `ShiftId` / `AppUserId` (Trim OUT's scrap rows carry
`ProductionEventId` NULL by design, so the rollup never joins scrap through the checkpoint).

Worked example -- 953-piece LOT at Trim Shop 2:

| Event | Shift | Op | ShotCount | Scrap | Credit |
|---|---|---|---|---|---|
| Partial | 2nd | JP | 700 | 5 | 700 good, 5 no good |
| Trim OUT | 3rd | TW | 946 | 2 | 246 good, 2 no good |

(953 - 5 scrap at the partial = 948 on the LOT; Trim OUT defaults to 948 - 2 = 946.)

A LOT can take more than one partial (a LOT spanning three shifts); each is a checkpoint.

### 3.3 Shift stamping

- `ProductionEvent.ShiftId BIGINT NULL FK -> Oee.Shift.Id` -- new. Adding a nullable column is
  metadata-only, which matters because `ProductionEvent` is born partitioned on `EventAt`.
- **Partial:** the operator's picked shift (D6). The picker lists the recent shifts
  (`BlueRidge.Oee.Shift.getRecentOptions`, the die cast picker's source) with no default.
- **Trim OUT:** stamped automatically (checkpoint and its scrap rows) from
  `Oee.ufn_ShiftIdForInstant` for the trim shop at `SYSUTCDATETIME()` -- no UI change. *(For review: Trim OUT could also force the picker; left
  automatic because it is not a shift-end action.)*
- Rows written before this migration keep `ShiftId` NULL. No backfill.

## 4. Schema

Migration `00NN_trim_partial_checkpoint.sql`:

- `ALTER TABLE Workorder.ProductionEvent ADD ShiftId BIGINT NULL` + FK to `Oee.Shift`.
- Update the `LogEventType 34 TrimCheckpointRecorded` description (currently "reserved"); no new id.
- Extended property on the new column (`R__Descriptions_ExtendedProperties.sql`).

No new tables, no new code tables.

## 5. Stored procedures

### 5.1 `Workorder.TrimPartial_Record` -- new, status row

```
@LotId BIGINT, @OperationTemplateId BIGINT, @ShotCount INT, @ScrapLinesJson NVARCHAR(MAX) = NULL,
@ShiftId BIGINT, @SourceLocationId BIGINT, @AppUserId BIGINT, @TerminalLocationId BIGINT = NULL
```

Shaped as a mirror of `TrimOut_Record` (same FDS-11-011 / Msg-3915 rules: every rejecting check
before `BEGIN TRANSACTION`, status row on every exit, `CATCH` the only `ROLLBACK`). Rejects when:

1. Required parameter missing -- `ShotCount` and `ShiftId` are **required** here.
2. Scrap JSON invalid, a line quantity <= 0, or a defect code missing/deprecated.
3. Template missing/deprecated.
4. LOT missing, or its status `BlocksProduction`.
5. The LOT is not at/under `@SourceLocationId` (checked in at this trim zone).
6. `ShiftId` does not exist.
7. `ShotCount < 0`, or `ShotCount + ScrapTotal > Lot.PieceCount`.
8. `ShotCount` is below the LOT's last trim checkpoint (the §3.2 partition).
9. Nothing to record: `ShotCount` equals the last trim checkpoint (0 when there is none) and there
   is no scrap.

Writes: the `ProductionEvent` (§3.1), the `RejectEvent` rows, the `PieceCount` decrement
(inlined mirror of the Trim OUT decrement), audit `TrimCheckpointRecorded` to `Audit.OperationLog`
with the readable Description: `<LotName> · Trim · Partial 700 trimmed, 5 scrap (2nd shift 09-21)`.
Returns the `ProductionEventId` as `NewId`.

### 5.2 `Workorder.TrimOut_Record` -- v1.5

- Stamp `ShiftId` from `Oee.ufn_ShiftIdForInstant` (§3.3).
- The D1 monotonic guard compares against the last **trim** checkpoint (§3.2 partition), not the
  LOT's last event of any operation. No live die cast writer puts a `ProductionEvent` on a LOT
  today (die cast credits go to `DieCastContribution`), so this is hardening, not a fix -- but a
  partial must never be diffed against another operation's counter.
- When the LOT carries a partial, `@ShotCount` is required (a NULL would leave the last shift's
  credit undefined).

### 5.3 Read -- `Workorder.TrimCheckpoint_GetLatestForLot` -- new

`@LotId` -> one row `ShotCount, EventAt (ET), ShiftLabel, Initials`, or empty. Drives the "already
recorded" line on the partial popup and on Trim OUT. The credit rollup read (for a future Trim Shop
Detail report) is **out of scope** here; §3.2 is its contract.

## 6. Screens

- **New popup** `Popups/TrimPartial` (new view -- file-authored): LOT, part, trim shop; *Last partial:
  700 -- 2nd shift, JP* when one exists; **Trimmed so far** on the Numpad; scrap taken from the
  Trim OUT form's current scrap lines for the same LOT (read-only in the popup, so scrap entry is
  not duplicated); the **shift picker (nothing selected)**; Save disabled until count and shift are set.
  A Save confirmation reads the filing back: *"Record 700 trimmed on 10628573 under 2nd shift,
  09-21?"*
- **TrimBody** (existing view -- Designer edit): a *Record partial trim -- shift end* button in the
  OUT actions, enabled when a LOT card is selected; opens the popup. Trim OUT shows the *Last partial*
  line when present.
- Core: NQ `workorder/TrimPartial_Record` (`type: Query`), `workorder/TrimCheckpoint_GetLatestForLot`;
  entity module `BlueRidge.Workorder.TrimPartial` (thin; `appUserId` passed by the caller).

## 7. Edge cases

- **Pieces counted trimmed at a partial, then scrapped at Trim OUT.** Trim OUT's default count
  (`PieceCount - scrap`) can fall below the partial; the monotonic guard rejects with a message
  naming the partial. The operator corrects the count; if the partial itself was wrong, that is a
  LOT Detail / supervisor matter.
- **LOT moved off the press after a partial** (hold, storage). The checkpoint stands; the next
  trim checkpoint still diffs against it.
- **Wrong shift picked.** Not correctable on this screen; it belongs to the trim follow-up of shift
  reconciliation (`notes/2026-09-17_shift-reconciliation-backfill-trim-followup.md`).

## 8. Tests -- `sql/tests/00NN_Trim_Partial/`

- Partial then Trim OUT: two checkpoints, credits 700 / 246, ShiftIds as stamped.
- Two partials then Trim OUT.
- Partial scrap decrements `PieceCount` and writes stamped `RejectEvent` rows.
- Rejections: each of §5.1 1-9.
- Trim OUT after a partial: count below the partial rejects; NULL count rejects.
- Trim OUT's guard ignores a prior non-trim `ProductionEvent` on the LOT (partition).
- Trim OUT stamps `ShiftId`.

## 9. Out of scope

- Trim Shop Detail report / credit rollup read.
- Any change at the tumblers or to Trim IN.
- Backfilling `ShiftId` on existing rows.
- Correcting a mis-filed partial (shift reconciliation, trim follow-up).
