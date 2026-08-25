# Guard `Open` LOTs on the Write Side — Design

**Date:** 2026-08-20
**Trigger:** production incident on `MPP_MES_Prod` — LOT `000000003` checked into Trim Shop 1 and then invisible on every trim screen.
**Status:** Draft for review. Design settled; no open questions.

---

## 1. The incident

An operator checked a basket into Trim Shop 1. The move and the `TrimIn` event both recorded, but the LOT never appeared on any trim screen.

| | |
|---|---|
| LOT | `000000003`, part `12234-6MA -0000` |
| Born | 14:03 at `DC1-M11`, Tool 1 / Cavity 5, 1 `DieCastContribution` |
| Status | **`Open`** — never released |
| Moved | `DC1-M11` → `TRIM1` at 15:10 |
| Events | `TrimIn` at 15:10 |

`Lots.Lot_GetWipQueueByLocation` — the proc behind every WIP screen — excludes it deliberately:

```sql
INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
                                AND sc.Code NOT IN (N'Closed', N'Open')
```

That exclusion is **correct**. `Open` is the die-cast per-cavity accumulator status from migration `0045`: a basket still being filled at the press is not WIP and must not be pickable downstream.

Recovered by releasing it (`Lots.DieCastLot_Release @LotId=3, @StorageLocationId=<TRIM1-STORE>, @AppUserId=6`) → `Open`→`Good`, 200 pieces intact, and it immediately appeared on Trim OUT with next step `TrimOut` (seq 3).

---

## 2. Root cause

**The read side knows about `Open`. The write side does not.**

The canonical guard, `Lots.Lot_AssertNotBlocked`:

```sql
IF @Blocks = 1 OR @StatusCode = N'Closed'
```

`Open` carries **`BlocksProduction = 0`** (verified in `Lots.LotStatusCode`: only `Hold` and `Scrap` set it), and it is not `Closed`. So every write path lets an `Open` basket through:

| Proc | Blocks `Hold`/`Scrap` | Blocks `Closed` | Blocks `Open` |
|---|---|---|---|
| `ProductionEvent_Record` (recorded the `TrimIn`) | ✓ | ✓ | **✗** |
| `TrimOut_Record` | ✓ | ✓ | **✗** |
| `MachiningIn_RecordPick` | ✓ | ✓ | **✗** |
| `MachiningOut_Mint` | ✓ | ✓ | **✗** |
| `Assembly_CompleteTray`, `Assembly_ScanIn` | ✓ | ✓ | **✗** |
| `Lot_MoveTo`, `Lot_MoveToValidated` | ✓ | ✓ | **✗** |
| `Lot_Split`, `Lot_Update`, `Lot_UpdateAttribute`, `Lot_RectifyPieceCount` | ✓ | ✓ | **✗** |
| `LotGenealogy_RecordConsumption`, `RejectEvent_Record`, `LotPause_Place` | ✓ | ✓ | **✗** |

An accumulating basket can therefore be trimmed, moved, split, machined, paused or consumed into an assembly — while remaining invisible to every queue. **Write permits, read hides, the LOT falls into a hole** with no screen that can recover it.

This was introduced by migration `0045` when `Open` was added: the read side was taught the new status, the write guards were not.

---

## 3. Design

**Extend the canonical rule from two terminal states to three:**

```sql
-- before
IF @Blocks = 1 OR @StatusCode = N'Closed'
-- after
IF @Blocks = 1 OR @StatusCode IN (N'Closed', N'Open')
```

Applied in `Lots.Lot_AssertNotBlocked` **and every inlined mirror of it**. The mirrors exist because of the INSERT-EXEC constraint documented in CLAUDE.md — a proc captured via `INSERT … EXEC` cannot `EXEC` a sibling status-row proc, so each inlines the check. All copies must move together or the guard is only half-applied.

### Rejected alternative — set `BlocksProduction = 1` on the `Open` row

A one-row change that every existing guard would pick up for free. Rejected because `BlocksProduction` means *"this LOT is held or scrapped"*, and the flag is read for more than gating:

- it drives operator-facing "blocked/on hold" messaging, so an accumulating basket would be reported to the operator as a **problem** rather than as normal in-progress work;
- it changes the meaning of a shared flag for every present and future consumer, not just the eight write paths that need it.

The explicit status check says exactly what is meant and changes nothing else.

### Files to change (16)

Canonical: `R__Lots_Lot_AssertNotBlocked.sql`

Inlined mirrors: `R__Lots_LotGenealogy_RecordConsumption.sql`, `R__Lots_LotPause_Place.sql`,
`R__Lots_Lot_MoveTo.sql`, `R__Lots_Lot_MoveToValidated.sql`, `R__Lots_Lot_RectifyPieceCount.sql`,
`R__Lots_Lot_Split.sql`, `R__Lots_Lot_Update.sql`, `R__Lots_Lot_UpdateAttribute.sql`,
`R__Workorder_Assembly_CompleteTray.sql`, `R__Workorder_Assembly_ScanIn.sql`,
`R__Workorder_MachiningIn_RecordPick.sql`, `R__Workorder_MachiningOut_Mint.sql`,
`R__Workorder_ProductionEvent_Record.sql`, `R__Workorder_RejectEvent_Record.sql`,
`R__Workorder_TrimOut_Record.sql`

**No migration.** Repeatables only — no schema change, no data change.

### What must NOT change — verified

The die-cast lifecycle procs are the ones that legitimately manipulate `Open` baskets:

- **Writes:** `DieCastLot_Open`, `DieCastLot_Release`, `DieCastLot_Void`, `DieCastShiftOutput_Record`
- **Reads:** `Lot_GetOpenByTool`, `Lot_GetShiftCavityTally`, `DieCast_GetShiftOutputBreakdown`, `Lot_GetWipQueueByLocation`

**Checked: none of the four write procs calls any guarded sibling.** Each is fully self-contained (the same INSERT-EXEC constraint forces them to inline everything), so adding the guard elsewhere cannot break the die-cast lifecycle. None of them currently carries a `BlocksProduction`/`Closed` check, so there is nothing in them to edit.

> `R__Parts_Bom_Deprecate.sql` also matches a grep for `N'Open'`, but that is inside a commented-out Arc-2 TODO about `Workorder.WorkOrder.Status` — unrelated, leave it.

### Message wording

`Closed` and `Open` are both non-blocking-by-flag but rejected, and they need different operator guidance:

| Status | Message |
|---|---|
| `Closed` | (unchanged) |
| `Open` | `LOT <name> is still an open die-cast basket. Release it at the die cast station before it can be used here.` |

The message must name the remedy. The whole cost of this bug was that the LOT vanished with no indication of what to do; a rejection that just says "blocked" would repeat that.

---

## 4. Tests

New `sql/tests/0045_DieCast_Lifecycle/070_open_lot_write_guard.sql`:

- `ProductionEvent_Record` against an `Open` LOT → `Status = 0`, message names release
- `Lot_MoveToValidated` against an `Open` LOT → `Status = 0`
- `TrimOut_Record`, `MachiningIn_RecordPick`, `Assembly_ScanIn`, `Lot_Split` against an `Open` LOT → `Status = 0`
- **regression:** `DieCastShiftOutput_Record` against the same `Open` LOT → `Status = 1` (accumulating still works)
- **regression:** `DieCastLot_Release` against the same `Open` LOT → `Status = 1`, status becomes `Good`
- **regression:** all of the above against a `Good` LOT → unchanged behaviour
- end-to-end: release an `Open` LOT, then confirm it appears in `Lot_GetWipQueueByLocation`

The two regression groups matter more than the new rejections — the risk in this change is over-blocking the die-cast lifecycle, not under-blocking.

---

## 5. Detection and remediation

A healthy `Open` LOT sits at a die-cast machine with no production events. A **stuck** one has left the machine or already carries events:

```sql
SELECT l.Id, l.LotName, loc.Code AS AtLoc, ltd.Code AS LocKind, l.PieceCount,
       (SELECT COUNT(*) FROM Workorder.ProductionEvent pe WHERE pe.LotId = l.Id) AS Events
FROM Lots.Lot l
JOIN Lots.LotStatusCode sc            ON sc.Id  = l.LotStatusId AND sc.Code = N'Open'
JOIN Location.Location loc            ON loc.Id = l.CurrentLocationId
JOIN Location.LocationTypeDefinition ltd ON ltd.Id = loc.LocationTypeDefinitionId
WHERE ltd.Code <> N'DieCastMachine'
   OR EXISTS (SELECT 1 FROM Workorder.ProductionEvent pe WHERE pe.LotId = l.Id);
```

Run against every environment before deploying the guard — a LOT already in this state cannot be fixed by the guard and needs releasing by hand.

**As of 2026-08-20:** `MPP_MES_Prod` returns nothing (LOT 3 recovered; the 12 remaining `Open` LOTs on `DC1-M10` are healthy accumulators with 0 events). `MPP_MES_Dev` has no `Open` LOTs at all.

**Recovery for a stuck LOT** is `Lots.DieCastLot_Release` with an **explicit** `@StorageLocationId`. The default is `WHSE`, which would teleport the basket to the warehouse — pass the location where the basket physically is.

---

## 6. Rollout

1. Apply the 16 repeatables + new test to `MPP_MES_Test`, full suite green.
2. Run the §5 detection query against Dev and Prod; hand-release anything it finds.
3. `Update-Prod.ps1 -Preview`, then apply to Prod (repeatables re-apply on every run).
4. `scan.ps1` — no Ignition resources change, but the gateway caches proc results.

No downtime, no data migration, reversible by reverting the repeatables.

---

## Revision History

| Date | Rev | Change |
|---|---|---|
| 2026-08-20 | 1.0 | Initial, from the prod LOT `000000003` incident. |
